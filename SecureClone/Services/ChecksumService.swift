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

/// How much proof a job produces before a card is called safe to wipe.
enum VerificationMode: String, CaseIterable, Identifiable, Sendable {
    case quick    = "Quick"
    case standard = "Standard"
    case thorough = "Thorough"
    case paranoid = "Paranoid"
    var id: String { rawValue }

    var summary: String {
        switch self {
        case .quick:    return "Copy only — no checksums, never \"safe to wipe\""
        case .standard: return "Hash while reading, re-read every drive and compare"
        case .thorough: return "Standard + re-read the card, second hash (MD5)"
        case .paranoid: return "Thorough + byte-by-byte compare of every copy"
        }
    }
    var hashes: Bool { self != .quick }
    var rereadsSource: Bool { self == .thorough || self == .paranoid }
    var secondHash: Bool { self == .thorough || self == .paranoid }
    var byteCompare: Bool { self == .paranoid }
}

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

    /// Hash a file with the primary algorithm and, optionally, MD5 as a second
    /// independent digest, in one pass (Thorough / Paranoid modes).
    static func hashDual(fileAt url: URL, algorithm: HashAlgorithm, withMD5: Bool,
                         bufferSize: Int = defaultBufferSize,
                         onBytes: ((Int) -> Void)? = nil) throws -> (primary: String, md5: String?) {
        let hasher = StreamingHasher(algorithm: algorithm, alsoMD5: withMD5 && algorithm != .md5)
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var p: UnsafeMutableRawPointer? = nil
        guard posix_memalign(&p, 16384, bufferSize) == 0, let buf = p else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer { free(buf) }
        while true {
            let n = read(fd, buf, bufferSize)
            if n < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if n == 0 { break }
            hasher.update(buf, n)
            onBytes?(n)
        }
        return (hasher.finalize(), hasher.finalizeMD5())
    }

    /// Byte-by-byte comparison of two files (Paranoid mode). Returns the
    /// offset of the first difference, or nil when identical.
    static func byteCompare(_ a: URL, _ b: URL, bufferSize: Int = defaultBufferSize,
                            onBytes: ((Int) -> Void)? = nil) throws -> Int64? {
        let fa = open(a.path, O_RDONLY), fb = open(b.path, O_RDONLY)
        guard fa >= 0, fb >= 0 else { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fa); close(fb) }
        _ = fcntl(fa, F_NOCACHE, 1); _ = fcntl(fb, F_NOCACHE, 1)
        var pa: UnsafeMutableRawPointer? = nil, pb: UnsafeMutableRawPointer? = nil
        guard posix_memalign(&pa, 16384, bufferSize) == 0, let ba = pa,
              posix_memalign(&pb, 16384, bufferSize) == 0, let bb = pb else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer { free(ba); free(bb) }
        var offset: Int64 = 0
        while true {
            let na = readFully(fa, ba, bufferSize), nb = readFully(fb, bb, bufferSize)
            if na < 0 || nb < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            if na != nb { return offset + Int64(min(na, nb)) }
            if na == 0 { return nil }
            if memcmp(ba, bb, na) != 0 {
                let a8 = ba.assumingMemoryBound(to: UInt8.self), b8 = bb.assumingMemoryBound(to: UInt8.self)
                for i in 0..<na where a8[i] != b8[i] { return offset + Int64(i) }
                return offset
            }
            offset += Int64(na)
            onBytes?(na)
        }
    }

    private static func readFully(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ size: Int) -> Int {
        var got = 0
        while got < size {
            let n = read(fd, buf.advanced(by: got), size - got)
            if n < 0 { if errno == EINTR { continue }; return -1 }
            if n == 0 { break }
            got += n
        }
        return got
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
