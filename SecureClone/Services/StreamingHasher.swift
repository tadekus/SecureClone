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

    init(algorithm: HashAlgorithm) {
        self.algorithm = algorithm
        switch algorithm {
        case .md5:    md5 = Insecure.MD5()
        case .sha256: sha = SHA256()
        case .xxh64:  xxh = XXH64()
        }
    }

    func update(_ data: Data) {
        switch algorithm {
        case .md5:    md5?.update(data: data)
        case .sha256: sha?.update(data: data)
        case .xxh64:  xxh?.update(data)
        }
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
