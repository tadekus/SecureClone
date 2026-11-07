//
//  ALEParser.swift
//  SecureClone
//
//  Reads Avid Log Exchange (.ale) files that ARRI (and other) cameras write
//  alongside the clips. These carry the camera's own per-clip metadata —
//  EI, shutter angle, ND, sensor fps, timecode, LUT — far more reliably than
//  anything reverse-engineered from the essence files.
//
//  ALE format:
//    Heading
//    FIELD_DELIM<TAB>TABS
//    VIDEO_FORMAT<TAB>...
//    FPS<TAB>24
//
//    Column
//    Name<TAB>Tracks<TAB>Start<TAB>End<TAB>Duration<TAB>...
//
//    Data
//    A_0071C019_...<TAB>V<TAB>22:34:24:17<TAB>...
//
//  Column names vary by camera/firmware, so matching is keyword-based on
//  normalized names ("Exposure_index", "Exposure Index", "EI" all match).
//

import Foundation

struct ALEClip {
    var name: String
    var fields: [String: String]        // normalized column name -> value
    var fps: Double?                    // from the header FPS line

    private func first(where test: (String) -> Bool) -> String? {
        for (k, v) in fields where test(k) {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }

    var start: String?        { first { $0 == "start" || $0 == "starttc" || $0 == "tcstart" } }
    var end: String?          { first { $0 == "end" || $0 == "endtc" || $0 == "tcend" } }
    var duration: String?     { first { $0 == "duration" } }
    var sensorFPS: String?    { first { $0.contains("sensorfps") || $0.contains("sensorframerate") || $0 == "projectfps" }
                                ?? first { $0 == "fps" } }
    var exposureIndex: String? { first { $0.contains("exposureindex") || $0 == "ei" || $0 == "iso" || $0 == "asa" } }
    var shutterAngle: String? { first { $0.contains("shutterangle") || $0 == "shutter" } }
    var ndFilter: String?     { first { $0.contains("ndfilter") || $0 == "nd" || $0.contains("ndvalue") } }
    var lut: String?          { first { $0.contains("lut") || $0.contains("lookname") || $0 == "look" } }
    var width: String?        { first { $0.contains("imagewidth") || $0 == "width" || $0.contains("activewidth") } }
    var height: String?       { first { $0.contains("imageheight") || $0 == "height" || $0.contains("activeheight") } }
    var codec: String?        { first { $0 == "codec" || $0.contains("compression") || $0.contains("recordingformat") || $0 == "format" } }
    var resolution: String?   { first { $0 == "resolution" || $0.contains("imagesize") } }
}

enum ALEParser {

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func parse(fileAt url: URL) -> [ALEClip] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8)
                 ?? String(data: data, encoding: .isoLatin1)
                 ?? ""
        guard !text.isEmpty else { return [] }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")

        var fps: Double? = nil
        var columns: [String] = []
        var clips: [ALEClip] = []
        var mode = 0   // 0 header, 1 expecting column line, 2 data

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if mode == 0 {
                if line.uppercased().hasPrefix("FPS") {
                    let parts = line.split(separator: "\t")
                    if parts.count >= 2 { fps = Double(parts[1].trimmingCharacters(in: .whitespaces)) }
                } else if line.caseInsensitiveCompare("Column") == .orderedSame {
                    mode = 1
                }
            } else if mode == 1 {
                if line.isEmpty { continue }
                if line.caseInsensitiveCompare("Data") == .orderedSame { mode = 2; continue }
                if columns.isEmpty {
                    columns = raw.components(separatedBy: "\t").map(normalize)
                }
            } else {
                if line.isEmpty { continue }
                let values = raw.components(separatedBy: "\t")
                var fields: [String: String] = [:]
                for (i, col) in columns.enumerated() where i < values.count {
                    fields[col] = values[i]
                }
                let name = fields["name"] ?? values.first ?? ""
                guard !name.isEmpty else { continue }
                clips.append(ALEClip(name: name, fields: fields, fps: fps))
            }
        }
        return clips
    }

    /// Parse every ALE under `root` (non-recursive list given) and index by clip name.
    static func index(aleFiles: [URL]) -> [String: ALEClip] {
        var out: [String: ALEClip] = [:]
        for u in aleFiles {
            for c in parse(fileAt: u) {
                // Key by name without extension, upper-cased, so "A_0071C019…" matches
                // the MXF file "A_0071C019….mxf".
                let key = (c.name as NSString).deletingPathExtension.uppercased()
                out[key] = c
            }
        }
        return out
    }

    /// Apply an ALE record onto a ClipMetadata (ALE wins on every field it has).
    static func apply(_ a: ALEClip, to m: inout ClipMetadata) {
        if let v = a.sensorFPS, let d = Double(v) { m.fps = Timecode.fpsString(d) }
        else if let f = a.fps { m.fps = Timecode.fpsString(f) }
        if let v = a.exposureIndex { m.exposureIndex = v }
        if let v = a.ndFilter      { m.ndFilter = v }
        if let v = a.shutterAngle  { m.shutterAngle = v.replacingOccurrences(of: "°", with: "") }
        if let v = a.start         { m.tcStart = v }
        if let v = a.end           { m.tcEnd = v }
        if let v = a.lut           { m.lutNodes = v }
        if let v = a.codec         { m.codec = v }
        if let r = a.resolution    { m.resolution = r }
        else if let w = a.width, let h = a.height { m.resolution = "\(w)x\(h)" }
        if m.durationSeconds == nil, let d = a.duration,
           let base = (a.sensorFPS.flatMap(Double.init) ?? a.fps).map(Timecode.roundedBase),
           let frames = Timecode.frames(from: d, base: base), base > 0 {
            m.durationSeconds = Double(frames) / Double(base)
        }
    }
}
