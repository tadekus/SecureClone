//
//  CloneEngine.swift
//  SecureClone
//
//  Pipelined copy: the source is read ONCE on a dedicated reader thread,
//  hashed inline, and each chunk is pushed into a bounded queue per
//  destination. Each destination has its own writer thread draining its
//  queue, so the card reader, the hasher and every drive all work at the
//  same time. A slow drive only slows itself (its queue fills and the
//  reader pauses for it); fast drives are never held back by it.
//
//  Verification is a separate phase: each destination is re-read from disk
//  independently and in parallel with the others. Two-pass verification is
//  deliberate — a hash of the in-memory buffer would miss write errors, bad
//  sectors and silent corruption. The re-read is non-negotiable.
//

import Foundation
import Darwin

struct FileCloneOutcome: Sendable {
    let relativePath: String
    let size: Int64
    let modificationDate: Date?
    let sourceHash: String
    let destinationHashes: [URL: String]
    let verified: [URL: Bool]
    var copyStartedAt: Date? = nil
    var copySeconds: Double = 0
    var verifySeconds: Double = 0

    var copyMBps: Double { copySeconds > 0 ? Double(size) / copySeconds / 1_000_000 : 0 }

    /// True when every destination's hash matched the source.
    var allVerified: Bool {
        !verified.isEmpty && verified.values.allSatisfy { $0 }
    }
}

enum CloneEngineError: LocalizedError {
    case cannotCreateDestination(URL)
    case writeFailed(URL, Error)
    case readFailed(URL, Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotCreateDestination(let u): return "Cannot create \(u.path)"
        case .writeFailed(let u, let e):      return "Write failed on \(u.lastPathComponent): \(e.localizedDescription)"
        case .readFailed(let u, let e):       return "Read failed on \(u.lastPathComponent): \(e.localizedDescription)"
        case .cancelled:                      return "Stopped by user"
        }
    }
}

/// Result of the copy phase for one file (before verification).
struct CopiedFile: Sendable {
    let source: ScannedFile
    let sourceHash: String
    let destinationFiles: [URL: URL]   // destination root -> written file
    var startedAt: Date = Date()
    var seconds: Double = 0            // wall time for this file's copy (0 = skipped/resumed)

    var mbps: Double { seconds > 0 ? Double(source.size) / seconds / 1_000_000 : 0 }
}

final class CloneEngine: @unchecked Sendable {

    let bufferSize: Int
    let queueDepth: Int

    /// - bufferSize: chunk size. 8 MB is a good match for USB-C SSDs.
    /// - queueDepth: chunks buffered per destination (8 × 8 MB = 64 MB each).
    ///   Deeper = more tolerance for a bursty drive, at the cost of RAM.
    init(bufferSize: Int = 8 * 1024 * 1024, queueDepth: Int = 12) {
        self.bufferSize = bufferSize
        self.queueDepth = queueDepth
    }

    // MARK: - Phase 1: pipelined copy

    /// Copy one file to all destinations with the reader/writer pipeline.
    /// Returns the source hash and where each copy was written.
    func copyFile(
        source: ScannedFile,
        destinationRoots: [URL],
        algorithm: HashAlgorithm,
        control: CloneControl? = nil,
        onChunk: (@Sendable (Int) -> Void)? = nil
    ) throws -> CopiedFile {
        let startedAt = Date()

        // Resolve destination file URLs, preserving the card's folder structure.
        var destFiles: [URL: URL] = [:]
        for root in destinationRoots {
            let destURL = root.appendingPathComponent(source.relativePath)
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            destFiles[root] = destURL
        }

        // Open the source: cache bypassed (we read each byte exactly once).
        let srcFD = open(source.url.path, O_RDONLY)
        guard srcFD >= 0 else {
            throw CloneEngineError.readFailed(source.url, posixError())
        }
        defer { close(srcFD) }
        _ = fcntl(srcFD, F_NOCACHE, 1)
        _ = fcntl(srcFD, F_RDAHEAD, 1)

        // Open every destination: cache bypassed, pre-allocated to final size
        // (one contiguous allocation instead of cluster-by-cluster growth —
        // matters on ExFAT).
        var destFDs: [URL: Int32] = [:]
        for (root, destURL) in destFiles {
            let fd = open(destURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else {
                for f in destFDs.values { close(f) }
                throw CloneEngineError.cannotCreateDestination(destURL)
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            if source.size > 0 {
                var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE,
                                     fst_offset: 0, fst_length: off_t(source.size), fst_bytesalloc: 0)
                if fcntl(fd, F_PREALLOCATE, &store) == -1 {
                    store.fst_flags = UInt32(F_ALLOCATEALL)
                    _ = fcntl(fd, F_PREALLOCATE, &store)
                }
            }
            destFDs[root] = fd
        }

        // Buffer pool shared by the reader, the hasher and every writer.
        let consumers = destFiles.count + 1
        let pool = BufferPool(bufferSize: bufferSize, count: queueDepth * consumers + 2)

        // One queue + one writer thread per destination.
        var queues: [URL: ChunkQueue] = [:]
        let group = DispatchGroup()
        let writerErrors = ErrorBox()
        for (root, destURL) in destFiles {
            let q = ChunkQueue(capacity: queueDepth)
            queues[root] = q
            let fd = destFDs[root]!
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                while let chunk = q.pop() {
                    var off = 0
                    while off < chunk.count {
                        let n = write(fd, chunk.base.advanced(by: off), chunk.count - off)
                        if n < 0 {
                            if errno == EINTR { continue }
                            let e = CloneEngineError.writeFailed(destURL, posixError())
                            q.fail(e); writerErrors.set(e); return
                        }
                        off += n
                    }
                }
                if fsync(fd) != 0 {       // data is already on disk (NOCACHE); this is cheap
                    let e = CloneEngineError.writeFailed(destURL, posixError())
                    q.fail(e); writerErrors.set(e)
                }
            }
        }

        // Hasher: its own thread and queue, so hashing never serializes
        // with reading or writing.
        let hashQueue = ChunkQueue(capacity: queueDepth)
        let hasher = StreamingHasher(algorithm: algorithm)
        let hashGroup = DispatchGroup()
        hashGroup.enter()
        Thread.detachNewThread {
            defer { hashGroup.leave() }
            while let chunk = hashQueue.pop() { hasher.update(chunk) }
        }

        // Reader: this thread. Read once into a pooled buffer, hand the same
        // chunk to the hasher and every writer.
        var readError: Error? = nil
        var wasCancelled = false
        while true {
            if let c = control, !c.checkpoint() { wasCancelled = true; break }
            guard let buf = pool.acquire() else { break }
            var got = 0
            while got < bufferSize {
                let n = read(srcFD, buf.advanced(by: got), bufferSize - got)
                if n < 0 {
                    if errno == EINTR { continue }
                    readError = CloneEngineError.readFailed(source.url, posixError()); break
                }
                if n == 0 { break }          // EOF
                got += n
            }
            let chunk = Chunk(base: buf, count: got, pool: pool)
            if readError != nil || got == 0 { break }
            hashQueue.push(chunk)
            var anyAlive = false
            for q in queues.values where q.push(chunk) { anyAlive = true }
            if !anyAlive { break }           // every writer has failed
            onChunk?(got)
        }

        // Signal end-of-file and wait for the hasher and all writers to finish.
        hashQueue.close()
        queues.values.forEach { $0.close() }
        hashGroup.wait()
        group.wait()
        for fd in destFDs.values { close(fd) }
        pool.close()

        // A cancelled or failed file must never be left half-written: a later
        // resume could mistake it for a finished copy.
        if wasCancelled || readError != nil || writerErrors.get() != nil {
            for destURL in destFiles.values { try? FileManager.default.removeItem(at: destURL) }
        }
        if wasCancelled { throw CloneEngineError.cancelled }
        if let e = readError { throw e }
        if let e = writerErrors.get() { throw e }

        // Restore the original modification date on each copy.
        if let mod = source.modificationDate {
            for destURL in destFiles.values {
                try? FileManager.default.setAttributes([.modificationDate: mod], ofItemAtPath: destURL.path)
            }
        }

        return CopiedFile(source: source, sourceHash: hasher.finalize(), destinationFiles: destFiles,
                          startedAt: startedAt, seconds: Date().timeIntervalSince(startedAt))
    }


    // MARK: - Phase 2: parallel verification

    /// Re-read every copy from disk and compare to the source hash.
    /// All destinations are verified concurrently, each sequentially through
    /// its own files (sequential reads are what drives are fastest at).
    func verify(
        copied: [CopiedFile],
        destinationRoots: [URL],
        algorithm: HashAlgorithm,
        control: CloneControl? = nil,
        onFileVerified: (@Sendable (URL, String, Bool) -> Void)? = nil,  // (root, relPath, ok)
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) -> [FileCloneOutcome] {

        // root -> relativePath -> hash
        let results = ResultBox()
        let group = DispatchGroup()

        for root in destinationRoots {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for c in copied {
                    if let ctl = control, !ctl.checkpoint() { break }   // pause / stop
                    guard let destURL = c.destinationFiles[root] else { continue }
                    let hash = (try? ChecksumService.hash(fileAt: destURL, algorithm: algorithm)) ?? "READ-ERROR"
                    let ok = (hash == c.sourceHash)
                    results.set(root: root, path: c.source.relativePath, hash: hash)
                    onFileVerified?(root, c.source.relativePath, ok)
                    onBytes?(c.source.size)
                }
            }
        }
        group.wait()

        return copied.map { c in
            var hashes: [URL: String] = [:]
            var ok: [URL: Bool] = [:]
            for root in destinationRoots {
                let h = results.get(root: root, path: c.source.relativePath) ?? "MISSING"
                hashes[root] = h
                ok[root] = (h == c.sourceHash)
            }
            return FileCloneOutcome(relativePath: c.source.relativePath,
                                    size: c.source.size,
                                    modificationDate: c.source.modificationDate,
                                    sourceHash: c.sourceHash,
                                    destinationHashes: hashes,
                                    verified: ok,
                                    copyStartedAt: c.seconds > 0 ? c.startedAt : nil,
                                    copySeconds: c.seconds)
        }
    }
}

/// The current errno as an Error (free function: usable from detached threads).
private func posixError() -> Error {
    let code = errno
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                   userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
}

// MARK: - Tiny thread-safe boxes

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var err: Error?
    func set(_ e: Error) { lock.lock(); if err == nil { err = e }; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return err }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [URL: [String: String]] = [:]
    func set(root: URL, path: String, hash: String) {
        lock.lock(); map[root, default: [:]][path] = hash; lock.unlock()
    }
    func get(root: URL, path: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return map[root]?[path]
    }
}
