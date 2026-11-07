//
//  WAVReader.swift
//  SecureClone
//
//  RIFF/WAVE header reader for production audio. Walks the chunk list once
//  (never touching the audio payload) and returns:
//    • format      — "Linear PCM, 24 bit little-endian signed integer, 4 channels, 48000 Hz"
//    • duration    — from the data chunk size / byte rate
//    • timecode    — from the Broadcast WAV `bext` chunk (TimeReference = samples
//                    since midnight) at the frame rate found in the `iXML` chunk
//                    (<TIMECODE_RATE>, <TIMECODE_FLAG>), falling back to 25 fps.
//  Handles RF64 (>4 GB) data sizes via the ds64 chunk.
//

import Foundation

struct WAVDetails {
    var channels: Int = 0
    var sampleRate: Int = 0
    var bitDepth: Int = 0
    var dataBytes: UInt64 = 0
    var timeReferenceSamples: UInt64? = nil     // bext
    var timecodeFPS: Double? = nil              // iXML
    var dropFrame = false                       // iXML

    var byteRate: Int { channels * sampleRate * bitDepth / 8 }
    var durationSeconds: Double? {
        byteRate > 0 && dataBytes > 0 ? Double(dataBytes) / Double(byteRate) : nil
    }
    var formatDescription: String? {
        guard sampleRate > 0 else { return nil }
        return "Linear PCM, \(bitDepth) bit little-endian signed integer, \(channels) channels, \(sampleRate) Hz"
    }

    /// (start, end) timecode strings, if the file carries a bext TimeReference.
    func timecode(defaultFPS: Double = 25) -> (start: String, end: String?)? {
        guard let ref = timeReferenceSamples, sampleRate > 0 else { return nil }
        let fps = timecodeFPS ?? defaultFPS
        let base = Timecode.roundedBase(fps)
        let startSec = Double(ref) / Double(sampleRate)
        let startFrames = Int64((startSec * fps).rounded(.down))
        let start = Timecode.string(frames: startFrames, base: base, dropFrame: dropFrame)
        var end: String? = nil
        if let d = durationSeconds {
            let endFrames = Int64(((startSec + d) * fps).rounded(.down))
            end = Timecode.string(frames: endFrames, base: base, dropFrame: dropFrame)
        }
        return (start, end)
    }
}

enum WAVReader {

    static func read(_ url: URL, headerBytes: Int = 512 * 1024) -> WAVDetails? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: headerBytes), head.count >= 12,
              (head[0..<4] == Data("RIFF".utf8) || head[0..<4] == Data("RF64".utf8)),
              head[8..<12] == Data("WAVE".utf8) else { return nil }

        var d = WAVDetails()
        var rf64DataSize: UInt64? = nil
        var i = 12
        while i + 8 <= head.count {
            let id = String(decoding: head[i..<i+4], as: UTF8.self)
            let size = Int(le32(head, i + 4))
            let body = i + 8
            switch id {
            case "fmt " where body + 16 <= head.count:
                d.channels   = Int(le16(head, body + 2))
                d.sampleRate = Int(le32(head, body + 4))
                d.bitDepth   = Int(le16(head, body + 14))
            case "ds64" where body + 16 <= head.count:
                rf64DataSize = le64(head, body + 8)
            case "bext" where body + 350 <= head.count:
                // Description(256) Originator(32) OriginatorReference(32)
                // OriginationDate(10) OriginationTime(8) TimeReferenceLow(4) TimeReferenceHigh(4)
                let lo = UInt64(le32(head, body + 342))
                let hi = UInt64(le32(head, body + 346))
                d.timeReferenceSamples = (hi << 32) | lo
            case "iXML":
                let end = min(head.count, body + size)
                if end > body, let xml = String(data: head[body..<end], encoding: .utf8) {
                    parseIXML(xml, into: &d)
                }
            case "data":
                d.dataBytes = rf64DataSize ?? UInt64(size)
                return d                        // audio payload follows; nothing else to read
            default:
                break
            }
            i = body + size + (size & 1)
        }
        return d.sampleRate > 0 ? d : nil
    }

    // MARK: - iXML

    private static func parseIXML(_ xml: String, into d: inout WAVDetails) {
        // <TIMECODE_RATE>24/1</TIMECODE_RATE>, 25/1, 30000/1001, 24000/1001 …
        if let rate = tag("TIMECODE_RATE", in: xml) {
            let p = rate.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 2, p[1] > 0 { d.timecodeFPS = p[0] / p[1] }
            else if p.count == 1 { d.timecodeFPS = p[0] }
        }
        if let flag = tag("TIMECODE_FLAG", in: xml) {
            d.dropFrame = flag.uppercased().contains("DF") && !flag.uppercased().contains("NDF")
        }
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Little-endian helpers

    private static func le16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
    }
    private static func le32(_ d: Data, _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(d[d.startIndex + o + k]) << (8 * UInt32(k)) }
        return v
    }
    private static func le64(_ d: Data, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(d[d.startIndex + o + k]) << (8 * UInt64(k)) }
        return v
    }
}
