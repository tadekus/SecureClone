//
//  ClipMetadata.swift
//  SecureClone
//
//  Per-clip camera metadata, assembled from whichever sources apply:
//    ALE sidecar (ARRI)  >  MXF header  >  AVFoundation / ImageIO
//  Every field is optional; the CSV writer prints what it has.
//

import Foundation

struct ClipMetadata: Identifiable, Sendable {
    var id: String { relativePath }

    let relativePath: String
    let name: String                    // clip name as the CSV shows it (no extension for clips)
    let size: Int64
    let sourceHash: String

    var durationSeconds: Double? = nil
    var fps: String? = nil              // sensor / recording fps, e.g. "24", "23.976"
    var exposureIndex: String? = nil    // EI / ISO
    var ndFilter: String? = nil
    var shutterAngle: String? = nil     // degrees, or exposure time for stills ("1/200s")
    var tcStart: String? = nil
    var tcEnd: String? = nil
    var lutNodes: String? = nil
    var codec: String? = nil
    var resolution: String? = nil       // "4608x2592"
    var isMediaClip: Bool = false       // video / audio / still (not .bin/.ale sidecars)

    var thumbnailJPEG: Data? = nil

    /// Silverstack-style "172.8° @ 24fps" when both parts exist.
    var shutterDisplay: String {
        guard let s = shutterAngle else { return "" }
        if s.hasSuffix("s") { return s }                 // stills: exposure time
        if let f = fps { return "\(s)° @ \(f)fps" }
        return "\(s)°"
    }

    var durationDisplay: String {
        guard let d = durationSeconds else { return "" }
        return String(Int(d.rounded()))
    }

    /// Fill any nil field of self from `other` (lower-priority source).
    mutating func fillMissing(from other: ClipMetadata) {
        if durationSeconds == nil { durationSeconds = other.durationSeconds }
        if fps == nil           { fps = other.fps }
        if exposureIndex == nil { exposureIndex = other.exposureIndex }
        if ndFilter == nil      { ndFilter = other.ndFilter }
        if shutterAngle == nil  { shutterAngle = other.shutterAngle }
        if tcStart == nil       { tcStart = other.tcStart }
        if tcEnd == nil         { tcEnd = other.tcEnd }
        if lutNodes == nil      { lutNodes = other.lutNodes }
        if codec == nil         { codec = other.codec }
        if resolution == nil    { resolution = other.resolution }
    }
}

enum MediaKind {
    case video, audio, still, sidecar

    static func of(_ url: URL) -> MediaKind {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "braw", "r3d", "crm":
            return .video
        case "wav", "bwf", "aif", "aiff":
            return .audio
        case "dng", "jpg", "jpeg", "heic", "tif", "tiff", "png", "arw", "cr2", "cr3", "nef", "raf":
            return .still
        default:
            return .sidecar
        }
    }
}

/// Shared helpers for timecode arithmetic.
enum Timecode {
    /// Frames → "HH:MM:SS:FF" (";" separator for drop-frame).
    static func string(frames: Int64, base: Int, dropFrame: Bool) -> String {
        guard base > 0 else { return "" }
        var f = max(0, frames)
        if dropFrame {
            let dropped = Int64((Double(base) * 0.066666).rounded())   // 2 @30, 4 @60
            let perMinute = Int64(base) * 60 - dropped
            let perTenMin = perMinute * 10 + dropped
            let d = f / perTenMin
            let m = f % perTenMin
            f += (m > dropped)
                ? dropped * 9 * d + dropped * ((m - dropped) / perMinute)
                : dropped * 9 * d
        }
        let b = Int64(base)
        let ff = Int(f % b)
        let ss = Int((f / b) % 60)
        let mm = Int((f / (b * 60)) % 60)
        let hh = Int((f / (b * 3600)) % 24)
        let sep = dropFrame ? ";" : ":"
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(two(hh)):\(two(mm)):\(two(ss))\(sep)\(two(ff))"
    }

    /// "HH:MM:SS:FF" → frames (ignores drop-frame subtleties; fine for durations).
    static func frames(from tc: String, base: Int) -> Int64? {
        let parts = tc.replacingOccurrences(of: ";", with: ":").split(separator: ":").compactMap { Int64($0) }
        guard parts.count == 4, base > 0 else { return nil }
        return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * Int64(base) + parts[3]
    }

    /// 23.976 → "23.976", 24.0 → "24", 29.97 → "29.97"
    static func fpsString(_ fps: Double) -> String {
        let s = String(format: "%.3f", fps)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    static func roundedBase(_ fps: Double) -> Int { Int(fps.rounded()) }
}
