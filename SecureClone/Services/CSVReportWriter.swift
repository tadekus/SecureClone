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
//  spreadsheets as the other DIT tools' exports. Values come from
//  MetadataService (ALE sidecar > MXF header > AVFoundation / ImageIO).
//

import Foundation

enum CSVReportWriter {

    static let header = [
        "Name", "Duration", "Sensor FPS", "EI/ISO (clip)", "ND Filter",
        "Shutter Angle", "TC Start", "TC End", "LUT Nodes", "Codec",
        "Resolution (original)", "Hash Values"
    ]

    static func make(outcomes: [FileCloneOutcome],
                     metadata: [ClipMetadata],
                     algorithm: HashAlgorithm) -> String {
        var lines: [String] = [header.joined(separator: ";")]
        let byPath = Dictionary(uniqueKeysWithValues: metadata.map { ($0.relativePath, $0) })

        for o in outcomes.sorted(by: { $0.relativePath < $1.relativePath }) {
            let m = byPath[o.relativePath]
            let name: String = m?.name ?? (o.relativePath as NSString).lastPathComponent

            // Built step by step: a single 12-element literal of `??` chains
            // makes the Swift type-checker time out.
            var row: [String] = []
            row.append(name)
            row.append(m?.durationDisplay ?? "")
            row.append(m?.fps ?? "")
            row.append(m?.exposureIndex ?? "")
            row.append(m?.ndFilter ?? "")
            row.append(m?.shutterDisplay ?? "")
            row.append(m?.tcStart ?? "")
            row.append(m?.tcEnd ?? "")
            row.append(m?.lutNodes ?? "")
            row.append(m?.codec ?? "")
            row.append(m?.resolution ?? "")
            row.append(hashField(o.sourceHash, algorithm: algorithm))

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

