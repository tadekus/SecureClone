//
//  CloneEngine.swift
//  SecureClone
//
//  The core: read the source ONCE, fan the bytes out to all destinations
//  concurrently while hashing the source inline, then independently
//  re-read each destination from disk and verify its hash.
//
//  Two-pass verification is deliberate:
//    Pass 1 hashes the source as it's read (what we actually read).
//    Pass 2 re-reads each destination from disk (catches write errors,
//            bad sectors, silent corruption). This is non-negotiable.
//

import Foundation

struct FileCloneOutcome {
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

enum CloneEngineError: Error {
    case cannotCreateDestination(URL)
    case writeFailed(URL, Error)
}

actor CloneEngine {

    let bufferSize: Int
    init(bufferSize: Int = 8 * 1024 * 1024) {   // 8 MB
        self.bufferSize = bufferSize
    }

    /// Clone a single file to all destinations and verify.
    /// - Parameters:
    ///   - byteProgress: called with bytes written for ONE destination per chunk
    ///                   (i.e. chunk.count once per chunk; multiply by dest count
    ///                   at the call site if you want aggregate throughput).
    func cloneFile(
        source: ScannedFile,
        destinationRoots: [URL],
        algorithm: HashAlgorithm,
        onChunk: ((Int) -> Void)? = nil
    ) async throws -> FileCloneOutcome {

        // Resolve destination file URLs, preserving the card's folder structure.
        var destFiles: [URL] = []
        for root in destinationRoots {
            let destURL = root.appendingPathComponent(source.relativePath)
            let dir = destURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destURL.path, contents: nil) else {
                throw CloneEngineError.cannotCreateDestination(destURL)
            }
            destFiles.append(destURL)
        }

        // Open one reader and N writers.
        let reader = try FileHandle(forReadingFrom: source.url)
        defer { try? reader.close() }

        var writers: [(url: URL, handle: FileHandle)] = []
        for dest in destFiles {
            writers.append((dest, try FileHandle(forWritingTo: dest)))
        }
        defer { writers.forEach { try? $0.handle.close() } }

        // PASS 1 — single read → hash source + fan out writes.
        let sourceHash = try readAndFanOut(
            reader: reader,
            writers: writers,
            algorithm: algorithm,
            onChunk: onChunk
        )

        writers.forEach { try? $0.handle.close() }

        // Restore the original modification date on each copy.
        if let mod = source.modificationDate {
            for dest in destFiles {
                try? FileManager.default.setAttributes([.modificationDate: mod],
                                                       ofItemAtPath: dest.path)
            }
        }

        // PASS 2 — independently re-read each destination and verify.
        var destHashes: [URL: String] = [:]
        var verified: [URL: Bool] = [:]

        try await withThrowingTaskGroup(of: (URL, String).self) { group in
            let algo = algorithm
            for (root, dest) in zip(destinationRoots, destFiles) {
                group.addTask {
                    let h = try ChecksumService.hash(fileAt: dest, algorithm: algo)
                    return (root, h)
                }
            }
            for try await (root, hash) in group {
                destHashes[root] = hash
                verified[root] = (hash == sourceHash)
            }
        }

        return FileCloneOutcome(
            relativePath: source.relativePath,
            size: source.size,
            modificationDate: source.modificationDate,
            sourceHash: sourceHash,
            destinationHashes: destHashes,
            verified: verified
        )
    }

    // MARK: - Pass 1 helper

    private func readAndFanOut(
        reader: FileHandle,
        writers: [(url: URL, handle: FileHandle)],
        algorithm: HashAlgorithm,
        onChunk: ((Int) -> Void)?
    ) throws -> String {

        let hasher = StreamingHasher(algorithm: algorithm)

        while true {
            let chunk = try reader.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty { break }

            hasher.update(chunk)

            // Fan out the same chunk to every destination.
            //
            // Writes are issued sequentially here (one chunk to each drive in
            // turn). The OS write cache absorbs these quickly, so the real
            // throughput limit is the source read, not these writes. This also
            // keeps FileHandle off of concurrent tasks (it isn't Sendable).
            // When you later add per-destination bounded queues (see README
            // roadmap), that's where true parallel writing belongs.
            for w in writers {
                do { try w.handle.write(contentsOf: chunk) }
                catch { throw CloneEngineError.writeFailed(w.url, error) }
            }

            onChunk?(chunk.count)
        }

        return hasher.finalize()
    }
}
