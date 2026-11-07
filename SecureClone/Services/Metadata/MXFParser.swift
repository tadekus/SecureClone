//
//  MXFParser.swift
//  SecureClone
//
//  Minimal SMPTE 377 MXF header reader. Reads only the header partition
//  (a few MB at most) and walks its KLV local sets for the standard
//  structural metadata every MXF carries:
//    • Timecode component → start TC, fps base, drop-frame, duration
//    • Picture descriptor  → stored width/height, sample rate, essence coding
//    • Identification      → company / product (e.g. "ARRI", "ALEXA 35")
//    • Material package    → clip name
//  Camera-specific values (EI, shutter, ND, LUT) live in vendor-private sets
//  and come from the ALE sidecar instead.
//

import Foundation

struct MXFInfo {
    var clipName: String?
    var width: Int?
    var height: Int?
    var fps: Double?
    var startFrames: Int64?
    var tcBase: Int?
    var dropFrame = false
    var durationFrames: Int64?
    var company: String?
    var product: String?
    var version: String?
    var essenceCodingUL: [UInt8]?

    var codecLabel: String? {
        guard let ul = essenceCodingUL, ul.count == 16 else {
            if company?.uppercased().contains("ARRI") == true { return "ARRIRAW" }
            return nil
        }
        // ProRes: 06 0E 2B 34 04 01 01 0D 04 01 02 02 03 06 xx 00
        let proResPrefix: [UInt8] = [0x06,0x0E,0x2B,0x34,0x04,0x01,0x01,0x0D,0x04,0x01,0x02,0x02,0x03,0x06]
        if Array(ul[0..<14]) == proResPrefix {
            switch ul[14] {
            case 0x01: return "ProRes 422 Proxy"
            case 0x02: return "ProRes 422 LT"
            case 0x03: return "ProRes 422"
            case 0x04: return "ProRes 422 HQ"
            case 0x05: return "ProRes 4444"
            case 0x06: return "ProRes 4444 XQ"
            default:   return "ProRes"
            }
        }
        if company?.uppercased().contains("ARRI") == true { return "ARRIRAW" }
        return nil
    }
}

enum MXFParser {

    private static let partitionPrefix: [UInt8] = [0x06,0x0E,0x2B,0x34,0x02,0x05,0x01,0x01,0x0D,0x01,0x02,0x01,0x01]
    private static let localSetPrefix: [UInt8]  = [0x06,0x0E,0x2B,0x34,0x02,0x53,0x01,0x01,0x0D,0x01,0x01,0x01,0x01,0x01]

    static func parse(fileAt url: URL, maxHeaderBytes: Int = 8 * 1024 * 1024) -> MXFInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxHeaderBytes), data.count > 64 else { return nil }
        let bytes = [UInt8](data)

        // Locate the header partition pack (run-in of up to 64 KB is allowed).
        guard let pp = find(partitionPrefix, in: bytes, from: 0, limit: min(bytes.count, 65536 + 16)) else { return nil }
        var pos = pp
        guard let kl0 = readKL(bytes, at: pos) else { return nil }
        let (len, hdr) = kl0
        let valueStart = pos + hdr
        // Partition pack: ... HeaderByteCount at offset 40 (8 bytes).
        var headerByteCount = 0
        if valueStart + 48 <= bytes.count {
            headerByteCount = Int(be64(bytes, valueStart + 40))
        }
        pos = valueStart + len
        let end = headerByteCount > 0 ? min(bytes.count, pos + headerByteCount) : bytes.count

        var info = MXFInfo()
        var gotTimecode = false

        while pos + 17 <= end {
            guard let kl = readKL(bytes, at: pos) else { break }
            let (vlen, khdr) = kl
            let key = Array(bytes[pos..<pos+16])
            let vstart = pos + khdr
            let vend = min(end, vstart + vlen)
            if vend <= vstart { pos = vend; continue }

            if Array(key[0..<14]) == localSetPrefix {
                let setID = key[14]
                let tags = parseLocalSet(bytes, from: vstart, to: vend)
                switch setID {
                case 0x36:  // Material Package
                    if let v = tags[0x4402] { info.clipName = utf16(v) }
                case 0x14:  // Timecode Component
                    if !gotTimecode {
                        if let v = tags[0x1501], v.count == 8 { info.startFrames = Int64(bitPattern: be64(v, 0)) }
                        if let v = tags[0x1502], v.count == 2 { info.tcBase = Int(be16(v, 0)) }
                        if let v = tags[0x1503], v.count == 1 { info.dropFrame = v[0] != 0 }
                        if let v = tags[0x0202], v.count == 8 { info.durationFrames = Int64(bitPattern: be64(v, 0)) }
                        gotTimecode = info.startFrames != nil
                    }
                case 0x27, 0x28, 0x29:  // Generic / CDCI / RGBA picture descriptor
                    if let v = tags[0x3203], v.count == 4 { info.width  = Int(be32(v, 0)) }
                    if let v = tags[0x3202], v.count == 4 { info.height = Int(be32(v, 0)) }
                    if let v = tags[0x3001], v.count == 8 {
                        let num = Double(be32(v, 0)), den = Double(be32(v, 4))
                        if den > 0 { info.fps = num / den }
                    }
                    if let v = tags[0x3201], v.count == 16 { info.essenceCodingUL = v }
                case 0x30:  // Identification
                    if info.company == nil {
                        if let v = tags[0x3C01] { info.company = utf16(v) }
                        if let v = tags[0x3C02] { info.product = utf16(v) }
                        if let v = tags[0x3C04] { info.version = utf16(v) }
                    }
                default: break
                }
            }
            pos = vend
        }
        return (info.width != nil || info.startFrames != nil || info.company != nil) ? info : nil
    }

    // MARK: - KLV helpers

    /// Returns (valueLength, headerLength = 16 + BER length bytes).
    private static func readKL(_ b: [UInt8], at pos: Int) -> (Int, Int)? {
        guard pos + 17 <= b.count else { return nil }
        let l0 = b[pos + 16]
        if l0 < 0x80 { return (Int(l0), 17) }
        let n = Int(l0 & 0x7F)
        guard n >= 1, n <= 8, pos + 17 + n <= b.count else { return nil }
        var v = 0
        for i in 0..<n { v = (v << 8) | Int(b[pos + 17 + i]) }
        return (v, 17 + n)
    }

    /// Local set with 2-byte tag / 2-byte length items.
    private static func parseLocalSet(_ b: [UInt8], from: Int, to: Int) -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        var p = from
        while p + 4 <= to {
            let tag = be16(b, p)
            let len = Int(be16(b, p + 2))
            p += 4
            guard p + len <= to else { break }
            out[tag] = Array(b[p..<p+len])
            p += len
        }
        return out
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int, limit: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        let last = min(limit, hay.count) - needle.count
        while i <= last {
            if hay[i] == needle[0] && Array(hay[i..<i+needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    private static func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o+1]) }
    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o+1]) << 16 | UInt32(b[o+2]) << 8 | UInt32(b[o+3])
    }
    private static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[o+i]) }
        return v
    }
    private static func utf16(_ v: [UInt8]) -> String? {
        guard v.count >= 2 else { return nil }
        let s = String(data: Data(v), encoding: .utf16BigEndian)
        return s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    /// Apply parsed MXF info onto a ClipMetadata (only fills missing fields).
    static func apply(_ i: MXFInfo, to m: inout ClipMetadata) {
        if m.resolution == nil, let w = i.width, let h = i.height { m.resolution = "\(w)x\(h)" }
        if m.fps == nil, let f = i.fps { m.fps = Timecode.fpsString(f) }
        let base = i.tcBase ?? i.fps.map(Timecode.roundedBase) ?? 0
        if m.tcStart == nil, let s = i.startFrames, base > 0 {
            m.tcStart = Timecode.string(frames: s, base: base, dropFrame: i.dropFrame)
            if let d = i.durationFrames, m.tcEnd == nil {
                m.tcEnd = Timecode.string(frames: s + d, base: base, dropFrame: i.dropFrame)
            }
        }
        if m.durationSeconds == nil, let d = i.durationFrames, let f = i.fps ?? (base > 0 ? Double(base) : nil), f > 0 {
            m.durationSeconds = Double(d) / f
        }
        if m.codec == nil { m.codec = i.codecLabel }
    }
}
