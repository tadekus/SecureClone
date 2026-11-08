//
//  StreamingHasher.swift
//  SecureClone
//
//  Hashes a sequence of in-memory chunks (used during the single read pass,
//  where we hash the source as we read it). Mirrors ChecksumService but for
//  incremental updates rather than reading a file from disk.
//

import Foundation
import CryptoKit

final class StreamingHasher {
    private let algorithm: HashAlgorithm

    private var md5: Insecure.MD5?
    private var sha: SHA256?
    private var xxh: XXH64?
    private var extraMD5: Insecure.MD5?       // second, independent digest (Thorough)

    init(algorithm: HashAlgorithm, alsoMD5: Bool = false) {
        self.algorithm = algorithm
        switch algorithm {
        case .md5:    md5 = Insecure.MD5()
        case .sha256: sha = SHA256()
        case .xxh64:  xxh = XXH64()
        }
        if alsoMD5 && algorithm != .md5 { extraMD5 = Insecure.MD5() }
    }

    func update(_ ptr: UnsafeRawPointer, _ count: Int) {
        let buf = UnsafeRawBufferPointer(start: ptr, count: count)
        switch algorithm {
        case .md5:    md5?.update(bufferPointer: buf)
        case .sha256: sha?.update(bufferPointer: buf)
        case .xxh64:  xxh?.update(ptr, count)
        }
        extraMD5?.update(bufferPointer: buf)
    }

    func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            if let b = raw.baseAddress, raw.count > 0 { update(b, raw.count) }
        }
    }

    func update(_ chunk: Chunk) { update(chunk.base, chunk.count) }

    /// Hex of the second digest, if one was requested.
    func finalizeMD5() -> String? {
        extraMD5?.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func finalize() -> String {
        switch algorithm {
        case .md5:
            return (md5?.finalize().map { String(format: "%02x", $0) }.joined()) ?? ""
        case .sha256:
            return (sha?.finalize().map { String(format: "%02x", $0) }.joined()) ?? ""
        case .xxh64:
            return xxh?.hexDigest() ?? ""
        }
    }
}
