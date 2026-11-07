//
//  CSVReportWriter.swift
//  SecureClone
//
//  Writes a Silverstack-style clip report:
//    - semicolon separated, every value double-quoted, UTF-8, LF line endings
//    - hash column as "XXH64BE:<hex>" (or "MD5:" / "SHA256:")
//    - clip names shown without extension, sidecars with extension
//
//  Columns match the sample from set exactly so it drops into the same
//  spreadsheets as the other DIT tools' exports. Camera-metadata columns
//  (FPS, ISO, TC, LUT, codec, resolution) need per-format header parsing
//  (ARRI MXF, RED R3D, …) and are left empty until that's implemented.
//  Duration is filled for WAV audio (read from the header).
//

import Foundation

enum CSVReportWriter {

    static let header = [
        "Name", "Duration", "Sensor FPS", "EI/ISO (clip)", "ND Filter",
        "Shutter Angle", "TC Start", "TC End", "LUT Nodes", "Codec",
        "Resolution (original)", "Hash Values"
    ]

    /// Extensions treated as "clips": listed by name without extension.
    private static let clipExtensions: Set<String> = [
        "mxf", "mov", "mp4", "mkv", "avi", "braw", "r3d", "ari", "arx",
        "wav", "bwf", "aif", "aiff", "crm", "mts", "m2ts"
    ]

    static func make(outcomes: [FileCloneOutcome],
                     sourceRoot: URL,
                     algorithm: HashAlgorithm) -> String {
        var lines: [String] = [header.joined(separator: ";")]

        for o in outcomes.sorted(by: { $0.relativePath < $1.relativePath }) {
            let url = sourceRoot.appendingPathComponent(o.relativePath)
            let ext = url.pathExtension.lowercased()
            let name = clipExtensions.contains(ext)
                ? url.deletingPathExtension().lastPathComponent
                : url.lastPathComponent

            let duration: String
            if ext == "wav" || ext == "bwf", let secs = WAVInfo.durationSeconds(of: url) {
                duration = String(Int(secs.rounded()))
            } else {
                duration = ""
            }

            let row = [
                name, duration,
                "", "", "", "", "", "", "", "", "",       // camera metadata: TODO
                hashField(o.sourceHash, algorithm: algorithm)
            ]
            lines.append(row.map(quote).joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func hashField(_ hash: String, algorithm: HashAlgorithm) -> String {
        switch algorithm {
        case .xxh64:  return "XXH64BE:\(hash)"
        case .md5:    return "MD5:\(hash)"
        case .sha256: return "SHA256:\(hash)"
        }
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    @discardableResult
    static func write(csv: String, to root: URL, jobName: String, finishDate: Date) throws -> URL {
        let dir = root.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ReportNaming.base(jobName: jobName, date: finishDate)).csv")
        try csv.data(using: .utf8)!.write(to: url)
        return url
    }
}

/// Shared file-name convention for all report types: <JobName>_<yyyyMMdd>_<EEE>
/// (matches the "SD16_20261028_WED" style from set). A time suffix keeps
/// repeated runs on the same day from overwriting each other.
enum ReportNaming {
    static func base(jobName: String, date: Date) -> String {
        let safe = jobName.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: ":", with: "-")
        let day = DateFormatter(); day.dateFormat = "yyyyMMdd"
        let dow = DateFormatter(); dow.locale = Locale(identifier: "en_US_POSIX"); dow.dateFormat = "EEE"
        let time = DateFormatter(); time.dateFormat = "HHmm"
        return "\(safe)_\(day.string(from: date))_\(dow.string(from: date).uppercased())_\(time.string(from: date))"
    }
}

/// Minimal RIFF/WAVE header reader: enough to get duration without
/// touching the audio payload.
enum WAVInfo {
    static func durationSeconds(of url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 64 * 1024), head.count >= 12,
              head[0..<4] == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8)
        else { return nil }

        var byteRate: UInt32 = 0
        var dataSize: UInt32 = 0
        var i = 12
        while i + 8 <= head.count {
            let id = String(decoding: head[i..<i+4], as: UTF8.self)
            let size = head[i+4..<i+8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if id == "fmt ", i + 16 <= head.count {
                byteRate = head[i+16..<i+20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            } else if id == "data" {
                dataSize = size
                break
            }
            i += 8 + Int(size) + (Int(size) & 1)
        }
        guard byteRate > 0, dataSize > 0 else { return nil }
        return Double(dataSize) / Double(byteRate)
    }
}
