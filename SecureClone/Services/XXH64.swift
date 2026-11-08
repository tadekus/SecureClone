//
//  XXH64.swift
//  SecureClone
//
//  Streaming xxHash64 (seed 0), implemented directly so hashing keeps up
//  with fast SSDs. Works on raw buffers — no per-chunk array copies — and
//  uses wrapping UInt64 arithmetic, which the optimizer turns into a tight
//  loop (multiple GB/s on Apple Silicon).
//
//  Validated against the reference vectors:
//    ""    → ef46db3751d8e999      "a" → d24ec4f1a98c6e5b
//    "abc" → 44bc2cf5ad770999
//

import Foundation

struct XXH64 {
    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261

    private var v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64
    private var total: UInt64 = 0
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var buffered = 0
    private let seed: UInt64

    init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }
    @inline(__always) private static func read64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt64.self))
    }
    @inline(__always) private static func read32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
        UInt32(littleEndian: p.loadUnaligned(fromByteOffset: o, as: UInt32.self))
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 { update(base, raw.count) }
        }
    }

    mutating func update(_ ptr: UnsafeRawPointer, _ count: Int) {
        total &+= UInt64(count)
        var p = ptr
        var remaining = count

        // Top up a partial 32-byte block first.
        if buffered > 0 {
            let need = 32 - buffered
            let take = min(need, remaining)
            buffer.withUnsafeMutableBytes { b in
                b.baseAddress!.advanced(by: buffered).copyMemory(from: p, byteCount: take)
            }
            buffered += take
            p = p.advanced(by: take)
            remaining -= take
            if buffered == 32 {
                buffer.withUnsafeBytes { b in process32(b.baseAddress!) }
                buffered = 0
            }
        }

        // Full 32-byte stripes straight from the input.
        var a = v1, b = v2, c = v3, d = v4
        while remaining >= 32 {
            a = Self.round(a, Self.read64(p, 0))
            b = Self.round(b, Self.read64(p, 8))
            c = Self.round(c, Self.read64(p, 16))
            d = Self.round(d, Self.read64(p, 24))
            p = p.advanced(by: 32)
            remaining -= 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d

        // Stash the tail.
        if remaining > 0 {
            buffer.withUnsafeMutableBytes { bb in
                bb.baseAddress!.copyMemory(from: p, byteCount: remaining)
            }
            buffered = remaining
        }
    }

    private mutating func process32(_ p: UnsafeRawPointer) {
        v1 = Self.round(v1, Self.read64(p, 0))
        v2 = Self.round(v2, Self.read64(p, 8))
        v3 = Self.round(v3, Self.read64(p, 16))
        v4 = Self.round(v4, Self.read64(p, 24))
    }

    func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1); h = Self.merge(h, v2); h = Self.merge(h, v3); h = Self.merge(h, v4)
        } else {
            h = seed &+ Self.p5
        }
        h &+= total

        buffer.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            var i = 0
            while i + 8 <= buffered {
                h ^= Self.round(0, Self.read64(p, i))
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= buffered {
                h ^= UInt64(Self.read32(p, i)) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < buffered {
                h ^= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }
        h ^= h >> 33; h &*= Self.p2
        h ^= h >> 29; h &*= Self.p3
        h ^= h >> 32
        return h
    }

    /// 16 lowercase hex digits (canonical big-endian representation).
    func hexDigest() -> String {
        let h = digest()
        var s = String(h, radix: 16)
        if s.count < 16 { s = String(repeating: "0", count: 16 - s.count) + s }
        return s
    }
}
