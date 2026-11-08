//
//  ChecksumService.swift
//  SecureClone
//
//  Streaming hash computation. Files are read in chunks so a 200 GB R3D
//  is never loaded into RAM. xxHash64 is the film-industry default.
//
//  xxHash64 is implemented in XXH64.swift (no external dependency).
//

import Foundation
import CryptoKit
import Darwin

enum HashAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case xxh64  = "xxHash64"
    case md5    = "MD5"
    case sha256 = "SHA-256"

    var id: String { rawValue }

    /// Tag used in the MHL element name.
    var mhlElement: String {
        switch self {
        case .xxh64:  return "xxhash64"
        case .md5:    return "md5"
        case .sha256: return "sha256"
        }
    }
}

struct ChecksumService {

    static let defaultBufferSize = 8 * 1024 * 1024  // 8 MB

    /// Hash a file from disk with the given algorithm.
    static func hash(fileAt url: URL,
                     algorithm: HashAlgorithm,
                     bufferSize: Int = defaultBufferSize,
                     progress: ((Double) -> Void)? = nil) throws -> String {
        switch algorithm {
        case .xxh64:  return try xxh64(fileAt: url, bufferSize: bufferSize, progress: progress)
        case .md5:    return try cryptoHash(Insecure.MD5(), fileAt: url, bufferSize: bufferSize, progress: progress)
        case .sha256: return try cryptoHash(SHA256(),       fileAt: url, bufferSize: bufferSize, progress: progress)
        }
    }

    // MARK: - CryptoKit (MD5 / SHA-256)

    private static func cryptoHash<H: HashFunction>(_ hasher: H,
                                                    fileAt url: URL,
                                                    bufferSize: Int,
                                                    progress: ((Double) -> Void)?) throws -> String {
        var hasher = hasher
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)   // read the disk, not the cache

        let total = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var processed = 0

        while autoreleasepool(invoking: {
            let data = (try? handle.read(upToCount: bufferSize)) ?? nil
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            processed += data.count
            if total > 0 { progress?(Double(processed) / Double(total)) }
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - xxHash64

    static func xxh64(fileAt url: URL,
                      bufferSize: Int = defaultBufferSize,
                      progress: ((Double) -> Void)? = nil) throws -> String {
        var hasher = XXH64()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)   // read the disk, not the cache

        let total = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var processed = 0

        while autoreleasepool(invoking: {
            let data = (try? handle.read(upToCount: bufferSize)) ?? nil
            guard let data, !data.isEmpty else { return false }
            hasher.update(data)
            processed += data.count
            if total > 0 { progress?(Double(processed) / Double(total)) }
            return true
        }) {}

        return hasher.hexDigest()
    }
}
