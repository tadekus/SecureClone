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

struct FileCloneOutcome: Sendable {
    let relativePath: String
    let size: Int64
    let modificationDate: Date?
    let sourceHash: String
    let destinationHashes: [URL: String]
    let verified: [URL: Bool]

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
}

final class CloneEngine: @unchecked Sendable {

    let bufferSize: Int
    let queueDepth: Int

    /// - bufferSize: chunk size. 8 MB is a good match for USB-C SSDs.
    /// - queueDepth: chunks buffered per destination (8 × 8 MB = 64 MB each).
    ///   Deeper = more tolerance for a bursty drive, at the cost of RAM.
    init(bufferSize: Int = 8 * 1024 * 1024, queueDepth: Int = 8) {
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

        // Resolve destination file URLs, preserving the card's folder structure.
        var destFiles: [URL: URL] = [:]
        for root in destinationRoots {
            let destURL = root.appendingPathComponent(source.relativePath)
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destURL.path, contents: nil) else {
                throw CloneEngineError.cannotCreateDestination(destURL)
            }
            destFiles[root] = destURL
        }

        // One queue + one writer thread per destination.
        var queues: [URL: ChunkQueue] = [:]
        let group = DispatchGroup()
        let writerErrors = ErrorBox()

        for (root, destURL) in destFiles {
            let q = ChunkQueue(capacity: queueDepth)
            queues[root] = q
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                do {
                    let handle = try FileHandle(forWritingTo: destURL)
                    defer { try? handle.close() }
                    while let chunk = q.pop() {
                        try handle.write(contentsOf: chunk)
                    }
                    try handle.synchronize()   // flush to the physical disk
                } catch {
                    let wrapped = CloneEngineError.writeFailed(destURL, error)
                    q.fail(wrapped)
                    writerErrors.set(wrapped)
                }
            }
        }

        // Reader: this thread. Read once, hash, fan out.
        let hasher = StreamingHasher(algorithm: algorithm)
        var readError: Error? = nil
        var wasCancelled = false
        do {
            let reader = try FileHandle(forReadingFrom: source.url)
            defer { try? reader.close() }
            while true {
                // Pause blocks here; cancel breaks out.
                if let c = control, !c.checkpoint() { wasCancelled = true; break }

                let chunk = try autoreleasepool { try reader.read(upToCount: bufferSize) ?? Data() }
                if chunk.isEmpty { break }
                hasher.update(chunk)
                var anyAlive = false
                for q in queues.values where q.push(chunk) { anyAlive = true }
                if !anyAlive { break }      // every writer has failed
                onChunk?(chunk.count)
            }
        } catch {
            readError = CloneEngineError.readFailed(source.url, error)
        }

        // Signal end-of-file and wait for all writers to flush.
        queues.values.forEach { $0.close() }
        group.wait()

        // A cancelled or failed file must never be left half-written: a later
        // resume could mistake it for a finished copy.
        if wasCancelled || readError != nil || writerErrors.get() != nil {
            for destURL in destFiles.values {
                try? FileManager.default.removeItem(at: destURL)
            }
        }
        if wasCancelled { throw CloneEngineError.cancelled }
        if let e = readError { throw e }
        if let e = writerErrors.get() { throw e }

        // Restore the original modification date on each copy.
        if let mod = source.modificationDate {
            for destURL in destFiles.values {
                try? FileManager.default.setAttributes([.modificationDate: mod],
                                                       ofItemAtPath: destURL.path)
            }
        }

        return CopiedFile(source: source,
                          sourceHash: hasher.finalize(),
                          destinationFiles: destFiles)
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
                                    verified: ok)
        }
    }
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
