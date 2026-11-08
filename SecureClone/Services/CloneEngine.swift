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
    // Thorough / Paranoid extras
    var sourceHashMD5: String? = nil           // second digest of the source (inline)
    var sourceRereadHash: String? = nil        // source hashed again after the copy
    var sourceRereadOK: Bool? = nil
    var destinationMD5: [URL: String] = [:]
    var byteCompareOK: [URL: Bool] = [:]
    var mode: VerificationMode = .standard

    var copyMBps: Double { copySeconds > 0 ? Double(size) / copySeconds / 1_000_000 : 0 }

    /// True when every check the mode requires passed on every destination.
    var allVerified: Bool {
        guard mode.hashes, !verified.isEmpty, verified.values.allSatisfy({ $0 }) else { return false }
        if mode.rereadsSource && sourceRereadOK != true { return false }
        if mode.byteCompare && !(byteCompareOK.count == verified.count && byteCompareOK.values.allSatisfy { $0 }) { return false }
        return true
    }
}

enum CloneEngineError: LocalizedError {
    case cannotCreateDestination(URL)
    case writeFailed(URL, Error)
    case readFailed(URL, Error)
    case cancelled
    case sourceChanged(URL, String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateDestination(let u): return "Cannot create \(u.path)"
        case .writeFailed(let u, let e):      return "Write failed on \(u.lastPathComponent): \(e.localizedDescription)"
        case .readFailed(let u, let e):       return "Read failed on \(u.lastPathComponent): \(e.localizedDescription)"
        case .cancelled:                      return "Stopped by user"
        case .sourceChanged(let u, let why):  return "Source changed during copy (\(u.lastPathComponent)): \(why)"
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
    var sourceHashMD5: String? = nil

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
        mode: VerificationMode = .standard,
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

        // Source stability, part 1: what we are about to read.
        var st0 = stat()
        guard fstat(srcFD, &st0) == 0 else { throw CloneEngineError.readFailed(source.url, posixError()) }
        guard Int64(st0.st_size) == source.size else {
            throw CloneEngineError.sourceChanged(source.url, "size is \(st0.st_size), scanned \(source.size)")
        }

        // Open every destination: cache bypassed, pre-allocated to final size
        // (one contiguous allocation instead of cluster-by-cluster growth —
        // matters on ExFAT).
        // Written under a temporary name; renamed to the real name only once
        // flushed to the medium, so a crash can never leave a plausible partial.
        var destFDs: [URL: Int32] = [:]
        var tempFiles: [URL: URL] = [:]
        for (root, destURL) in destFiles {
            let tmp = Self.partialURL(for: destURL)
            tempFiles[root] = tmp
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else {
                for f in destFDs.values { close(f) }
                for t in tempFiles.values { try? FileManager.default.removeItem(at: t) }
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
                // Push the data past the drive's own volatile cache onto the
                // medium (F_FULLFSYNC); plain fsync only reaches the drive.
                if let e = CloneEngine.flushToMedium(fd, url: destURL) {
                    q.fail(e); writerErrors.set(e)
                }
            }
        }

        // Hasher: its own thread and queue, so hashing never serializes
        // with reading or writing.
        let hashQueue = ChunkQueue(capacity: queueDepth)
        let hasher = StreamingHasher(algorithm: algorithm, alsoMD5: mode.secondHash)
        let hashGroup = DispatchGroup()
        hashGroup.enter()
        Thread.detachNewThread {
            defer { hashGroup.leave() }
            while let chunk = hashQueue.pop() { if mode.hashes { hasher.update(chunk) } }
        }

        // Reader: this thread. Read once into a pooled buffer, hand the same
        // chunk to the hasher and every writer.
        var readError: Error? = nil
        var wasCancelled = false
        var totalRead: Int64 = 0
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
            totalRead += Int64(got)
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
            for t in tempFiles.values { try? FileManager.default.removeItem(at: t) }
        }
        if wasCancelled { throw CloneEngineError.cancelled }
        if let e = readError { throw e }
        if let e = writerErrors.get() { throw e }

        // Source stability, part 2: we read exactly what we were told existed,
        // and the file did not change underneath us meanwhile.
        var st1 = stat()
        guard fstat(srcFD, &st1) == 0 else { throw CloneEngineError.readFailed(source.url, posixError()) }
        if totalRead != source.size {
            for t in tempFiles.values { try? FileManager.default.removeItem(at: t) }
            throw CloneEngineError.sourceChanged(source.url, "read \(totalRead) of \(source.size) bytes")
        }
        if st1.st_size != st0.st_size || st1.st_mtimespec.tv_sec != st0.st_mtimespec.tv_sec
            || st1.st_mtimespec.tv_nsec != st0.st_mtimespec.tv_nsec || st1.st_ino != st0.st_ino {
            for t in tempFiles.values { try? FileManager.default.removeItem(at: t) }
            throw CloneEngineError.sourceChanged(source.url, "size or modification time changed while reading")
        }

        // Restore the original modification date, then publish atomically.
        for (root, destURL) in destFiles {
            guard let tmp = tempFiles[root] else { continue }
            if let mod = source.modificationDate {
                try? FileManager.default.setAttributes([.modificationDate: mod], ofItemAtPath: tmp.path)
            }
            if rename(tmp.path, destURL.path) != 0 {
                let e = CloneEngineError.writeFailed(destURL, posixError())
                for t in tempFiles.values { try? FileManager.default.removeItem(at: t) }
                throw e
            }
            Self.syncDirectory(destURL.deletingLastPathComponent())
        }

        return CopiedFile(source: source, sourceHash: mode.hashes ? hasher.finalize() : "",
                          destinationFiles: destFiles,
                          startedAt: startedAt, seconds: Date().timeIntervalSince(startedAt),
                          sourceHashMD5: hasher.finalizeMD5())
    }

    /// Temporary name used while a file is being written.
    static func partialURL(for final: URL) -> URL {
        final.deletingLastPathComponent().appendingPathComponent("." + final.lastPathComponent + ".sc-partial")
    }

    /// F_FULLFSYNC where supported (APFS, HFS+), fsync elsewhere (ExFAT returns ENOTSUP).
    static func flushToMedium(_ fd: Int32, url: URL) -> Error? {
        if fcntl(fd, F_FULLFSYNC) == 0 { return nil }
        if errno != ENOTSUP && errno != EOPNOTSUPP && errno != EINVAL {
            return CloneEngineError.writeFailed(url, posixError())
        }
        return fsync(fd) == 0 ? nil : CloneEngineError.writeFailed(url, posixError())
    }

    /// Make a just-created name durable by syncing its directory.
    static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }

    /// Remove leftover partials under a folder (after a crash or stop).
    static func removePartials(under root: URL) -> Int {
        var n = 0
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsPackageDescendants]) else { return 0 }
        for case let u as URL in en where u.lastPathComponent.hasSuffix(".sc-partial") {
            if (try? FileManager.default.removeItem(at: u)) != nil { n += 1 }
        }
        return n
    }


    // MARK: - Phase 2: parallel verification

    /// Re-read every copy from disk and compare to the source hash.
    /// All destinations are verified concurrently, each sequentially through
    /// its own files. Thorough/Paranoid add: the source re-read on its own
    /// thread with a second digest, and a byte-by-byte compare per copy.
    func verify(
        copied: [CopiedFile],
        destinationRoots: [URL],
        algorithm: HashAlgorithm,
        mode: VerificationMode = .standard,
        control: CloneControl? = nil,
        onFileVerified: (@Sendable (URL, String, Bool) -> Void)? = nil,  // (root, relPath, ok)
        onBytes: (@Sendable (Int64) -> Void)? = nil
    ) -> [FileCloneOutcome] {

        let results = ResultBox()          // root -> relPath -> primary hash
        let md5s = ResultBox()             // root -> relPath -> md5
        let reread = ResultBox()           // "source" -> relPath -> primary (and md5 under "source-md5")
        let bytesOK = ResultBox()          // root -> relPath -> "ok"/"diff@offset"
        let group = DispatchGroup()
        let sourceKey = URL(fileURLWithPath: "/__source__")
        let sourceMD5Key = URL(fileURLWithPath: "/__source_md5__")

        guard mode.hashes else {
            // Quick: nothing to verify; report copies as unverified.
            return copied.map { c in
                var hashes: [URL: String] = [:], ok: [URL: Bool] = [:]
                for root in destinationRoots { hashes[root] = ""; ok[root] = false }
                var o = FileCloneOutcome(relativePath: c.source.relativePath, size: c.source.size,
                                         modificationDate: c.source.modificationDate, sourceHash: "",
                                         destinationHashes: hashes, verified: ok,
                                         copyStartedAt: c.seconds > 0 ? c.startedAt : nil, copySeconds: c.seconds)
                o.mode = mode
                return o
            }
        }

        for root in destinationRoots {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for c in copied {
                    if let ctl = control, !ctl.checkpoint() { break }
                    guard let destURL = c.destinationFiles[root] else { continue }
                    let r = try? ChecksumService.hashDual(fileAt: destURL, algorithm: algorithm,
                                                          withMD5: mode.secondHash,
                                                          onBytes: { onBytes?(Int64($0)) })
                    let hash = r?.primary ?? "READ-ERROR"
                    results.set(root: root, path: c.source.relativePath, hash: hash)
                    if let m = r?.md5 { md5s.set(root: root, path: c.source.relativePath, hash: m) }
                    let ok = (hash == c.sourceHash)
                    if mode.byteCompare && ok {
                        if let diff = try? ChecksumService.byteCompare(c.source.url, destURL,
                                                                       onBytes: { onBytes?(Int64($0)) }) {
                            bytesOK.set(root: root, path: c.source.relativePath, hash: diff.map { "diff@\($0)" } ?? "ok")
                        } else {
                            bytesOK.set(root: root, path: c.source.relativePath, hash: "error")
                        }
                    }
                    onFileVerified?(root, c.source.relativePath, ok)
                }
            }
        }

        if mode.rereadsSource {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for c in copied {
                    if let ctl = control, !ctl.checkpoint() { break }
                    let r = try? ChecksumService.hashDual(fileAt: c.source.url, algorithm: algorithm,
                                                          withMD5: mode.secondHash,
                                                          onBytes: { onBytes?(Int64($0)) })
                    reread.set(root: sourceKey, path: c.source.relativePath, hash: r?.primary ?? "READ-ERROR")
                    if let m = r?.md5 { reread.set(root: sourceMD5Key, path: c.source.relativePath, hash: m) }
                }
            }
        }
        group.wait()

        return copied.map { c in
            var hashes: [URL: String] = [:]
            var ok: [URL: Bool] = [:]
            var dm: [URL: String] = [:]
            var bc: [URL: Bool] = [:]
            for root in destinationRoots {
                let h = results.get(root: root, path: c.source.relativePath) ?? "MISSING"
                hashes[root] = h
                ok[root] = (h == c.sourceHash)
                if let m = md5s.get(root: root, path: c.source.relativePath) {
                    dm[root] = m
                    if let sm = c.sourceHashMD5, sm != m { ok[root] = false }
                }
                if mode.byteCompare {
                    bc[root] = (bytesOK.get(root: root, path: c.source.relativePath) == "ok")
                }
            }
            var o = FileCloneOutcome(relativePath: c.source.relativePath, size: c.source.size,
                                     modificationDate: c.source.modificationDate, sourceHash: c.sourceHash,
                                     destinationHashes: hashes, verified: ok,
                                     copyStartedAt: c.seconds > 0 ? c.startedAt : nil, copySeconds: c.seconds)
            o.mode = mode
            o.sourceHashMD5 = c.sourceHashMD5
            o.destinationMD5 = dm
            o.byteCompareOK = bc
            if mode.rereadsSource {
                let rh = reread.get(root: sourceKey, path: c.source.relativePath)
                o.sourceRereadHash = rh
                var good = (rh == c.sourceHash)
                if let sm = c.sourceHashMD5, let rm = reread.get(root: sourceMD5Key, path: c.source.relativePath), sm != rm { good = false }
                o.sourceRereadOK = good
            }
            return o
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
