//
//  ReelDetector.swift
//  SecureClone
//
//  Works out the reel / card name and camera letter from what's on the
//  card, so the job name and destination folder can be pre-filled.
//
//  Patterns:
//    ARRI        A_0071C019_261028_233013_h1DPN.mxf   → reel A_0071, camera A
//    RED         A001_C001_0101XX.R3D / A001_0101XX.RDM → reel A001, camera A
//    Blackmagic  A001_11071234_C001.braw               → reel A001, camera A
//    DJI         D001_QFXJ43/D001C0001_261107_…        → reel D001_QFXJ43, camera D
//    Sony XDCAM  XDROOT/Clip/C0001.MP4                 → reel = volume name
//    Canon       CONTENTS/CLIPS001/…                   → reel = volume name
//    fallback    volume name
//

import Foundation

struct ReelInfo: Equatable {
    var reel: String
    var camera: String?        // single letter, if detected
    var system: String         // "ARRI", "RED", "DJI", … for the log
}

enum ReelDetector {

    static func detect(volume: VolumeInfo, files: [ScannedFile]? = nil) -> ReelInfo {
        let list = files ?? (try? SourceScanner.scan(root: volume.url)) ?? []
        let names = list.map { ($0.relativePath as NSString).lastPathComponent }
        let paths = list.map { $0.relativePath }

        // ARRI: A_0071C019_… (camera letter, underscore, 4-digit reel, C, 3-digit clip)
        if let m = firstMatch(#"^([A-Z])_(\d{4})C\d{3}_"#, in: names) {
            return ReelInfo(reel: "\(m[1])_\(m[2])", camera: m[1], system: "ARRI")
        }
        // ARRI ALE / BIN sidecars: A_0071_1DPN_AVID.ale
        if let m = firstMatch(#"^([A-Z])_(\d{4})_[0-9A-Z]{4}_(AVID|BIN)\."#, in: names) {
            return ReelInfo(reel: "\(m[1])_\(m[2])", camera: m[1], system: "ARRI")
        }
        // RED: A001_C001_0101XX.R3D or folder A001_0101XX.RDM
        if let m = firstMatch(#"^([A-Z])(\d{3})_C\d{3}_[0-9A-Z]+\.R3D$"#, in: names, caseInsensitive: true) {
            return ReelInfo(reel: "\(m[1])\(m[2])", camera: m[1], system: "RED")
        }
        if let m = firstMatch(#"(^|/)([A-Z])(\d{3})_[0-9A-Z]+\.RDM(/|$)"#, in: paths, caseInsensitive: true) {
            return ReelInfo(reel: "\(m[2])\(m[3])", camera: m[2], system: "RED")
        }
        // Blackmagic: A001_11071234_C001.braw
        if let m = firstMatch(#"^([A-Z])(\d{3})_\d{8}_C\d{3}\.braw$"#, in: names, caseInsensitive: true) {
            return ReelInfo(reel: "\(m[1])\(m[2])", camera: m[1], system: "Blackmagic")
        }
        // DJI: top-level folder D001_QFXJ43 (letter + 3 digits + _ + 6 alnum)
        if let m = firstMatch(#"^([A-Z])(\d{3})_([0-9A-Z]{6})(/|$)"#, in: paths) {
            return ReelInfo(reel: "\(m[1])\(m[2])_\(m[3])", camera: m[1], system: "DJI")
        }
        // DJI DCIM fallback: DCIM/100MEDIA/DJI_0001.MP4
        if paths.contains(where: { $0.hasPrefix("DCIM/") && $0.contains("DJI_") }) {
            return ReelInfo(reel: sanitize(volume.name), camera: nil, system: "DJI")
        }
        // Sony / Canon structured cards
        if paths.contains(where: { $0.hasPrefix("XDROOT/") || $0.hasPrefix("PRIVATE/M4ROOT/") }) {
            return ReelInfo(reel: sanitize(volume.name), camera: nil, system: "Sony")
        }
        if paths.contains(where: { $0.hasPrefix("CONTENTS/CLIPS") }) {
            return ReelInfo(reel: sanitize(volume.name), camera: nil, system: "Canon")
        }
        return ReelInfo(reel: sanitize(volume.name), camera: nil, system: "Generic")
    }

    // MARK: - Helpers

    private static func firstMatch(_ pattern: String, in strings: [String],
                                   caseInsensitive: Bool = false) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        for s in strings {
            let ns = s as NSString
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                var groups: [String] = []
                for g in 0..<m.numberOfRanges {
                    let r = m.range(at: g)
                    groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
                return groups
            }
        }
        return nil
    }

    /// Volume names like "Untitled" or "NO NAME" aren't useful reel names.
    static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = ["UNTITLED", "NO NAME", "NONAME", "UNNAMED", ""]
        if generic.contains(trimmed.uppercased()) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmm"
            return "CARD_\(f.string(from: Date()))"
        }
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }
}
