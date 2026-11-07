//
//  LogWriter.swift
//  SecureClone
//
//  Human-readable job report. The last line is the one the loader hands
//  to the producer: whether it's safe to wipe the source.
//

import Foundation

enum LogWriter {

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func makeReport(
        jobName: String,
        source: VolumeInfo,
        destinations: [VolumeInfo],
        outcomes: [FileCloneOutcome],
        algorithm: HashAlgorithm,
        startDate: Date,
        finishDate: Date
    ) -> String {
        var lines: [String] = []
        lines.append("\(AppInfo.fullName) — Job Report")
        lines.append("======================")
        lines.append("Job:        \(jobName)")
        lines.append("Started:    \(stamp.string(from: startDate))")
        lines.append("Source:     \(source.url.path)  (\(source.name), \(source.totalCapacityFormatted))")
        lines.append("Algorithm:  \(algorithm.rawValue)")
        lines.append("")
        lines.append("Destinations:")

        var allGood = true
        for dest in destinations {
            let forDest = outcomes.compactMap { o -> Bool? in o.verified[dest.url] }
            let files = forDest.count
            let okCount = forDest.filter { $0 }.count
            let bytes = outcomes
                .filter { $0.verified[dest.url] != nil }
                .reduce(Int64(0)) { $0 + $1.size }
            let ok = (okCount == files && files > 0)
            if !ok { allGood = false }
            let mark = ok ? "[✓]" : "[✗]"
            let status = ok ? "VERIFIED" : "FAILED (\(okCount)/\(files) ok)"
            lines.append("  \(mark) \(dest.url.path)   \(files) files   \(VolumeInfo.format(bytes))   \(status)")
        }

        lines.append("")

        // List any failures explicitly.
        let failures = outcomes.filter { !$0.allVerified }
        if !failures.isEmpty {
            lines.append("MISMATCHES / FAILURES:")
            for f in failures {
                for (destURL, ok) in f.verified where !ok {
                    lines.append("  ✗ \(f.relativePath)  →  \(destURL.lastPathComponent)")
                    lines.append("      source: \(f.sourceHash)")
                    lines.append("      dest:   \(f.destinationHashes[destURL] ?? "—")")
                }
            }
            lines.append("")
        }

        lines.append("Total files: \(outcomes.count)")
        lines.append("Total size:  \(VolumeInfo.format(outcomes.reduce(0) { $0 + $1.size }))")
        lines.append("Completed:   \(stamp.string(from: finishDate))")
        lines.append("Duration:    \(formatDuration(finishDate.timeIntervalSince(startDate)))")
        lines.append("")
        lines.append("Result:      " + (allGood
            ? "ALL DESTINATIONS VERIFIED — SAFE TO WIPE SOURCE"
            : "VERIFICATION FAILED — DO NOT WIPE SOURCE"))

        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    static func write(report: String,
                      to destinationRoot: URL,
                      jobName: String,
                      finishDate: Date) throws -> URL {
        let dir = destinationRoot.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ReportNaming.base(jobName: jobName, date: finishDate)).txt")
        try report.data(using: .utf8)!.write(to: url)
        return url
    }

    private static func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
