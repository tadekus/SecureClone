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
        finishDate: Date,
        destinationFolders: [URL] = [],
        skipped: Int = 0,
        sourceFolder: URL? = nil,
        mode: VerificationMode = .standard
    ) -> String {
        var lines: [String] = []
        lines.append("\(AppInfo.fullName) — Job Report")
        lines.append("======================")
        lines.append("Job:        \(jobName)")
        lines.append("Started:    \(stamp.string(from: startDate))")
        lines.append("Source:     \((sourceFolder ?? source.url).path)  (\(source.name), \(source.totalCapacityFormatted))")
        lines.append("Algorithm:  \(algorithm.rawValue)" + (mode.secondHash ? " + MD5" : ""))
        lines.append("Mode:       \(mode.rawValue) — \(mode.summary)")
        lines.append("Host:       \(Host.current().localizedName ?? "unknown")  user \(NSUserName())")
        lines.append("")
        lines.append("Destinations:")

        var allGood = true
        for (i, dest) in destinations.enumerated() {
            let key = i < destinationFolders.count ? destinationFolders[i] : dest.url
            let folder = key.path
            let forDest = outcomes.compactMap { o -> Bool? in o.verified[key] }
            let files = forDest.count
            let okCount = forDest.filter { $0 }.count
            let bytes = outcomes
                .filter { $0.verified[key] != nil }
                .reduce(Int64(0)) { $0 + $1.size }
            let ok = (okCount == files && files > 0)
            if !ok { allGood = false }
            let mark = ok ? "[✓]" : "[✗]"
            let status = ok ? "VERIFIED" : "FAILED (\(okCount)/\(files) ok)"
            lines.append("  \(mark) \(folder)   \(files) files   \(VolumeInfo.format(bytes))   \(status)")
        }
        if skipped > 0 {
            lines.append("")
            lines.append("Skipped:     \(skipped) files already present with identical verified hashes (re-verified)")
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

        // Per-file transfer times and speeds.
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        lines.append("Files (time · size · duration · speed):")
        for o in outcomes.sorted(by: { ($0.copyStartedAt ?? .distantPast) < ($1.copyStartedAt ?? .distantPast) }) {
            let mark = o.allVerified ? "✓" : "✗"
            if let t = o.copyStartedAt, o.copySeconds > 0 {
                lines.append("  \(mark) \(tf.string(from: t))  \(pad(VolumeInfo.format(o.size), 10))  \(pad(formatDuration(o.copySeconds), 8))  \(pad(String(format: "%.0f MB/s", o.copyMBps), 10))  \(o.relativePath)")
            } else {
                lines.append("  \(mark) \(pad("—", 8))  \(pad(VolumeInfo.format(o.size), 10))  \(pad("skipped", 8))  \(pad("", 10))  \(o.relativePath)")
            }
        }
        let timed = outcomes.filter { $0.copySeconds > 0 }
        if !timed.isEmpty {
            let bytes = timed.reduce(Int64(0)) { $0 + $1.size }
            let secs = timed.reduce(0.0) { $0 + $1.copySeconds }
            let avg = secs > 0 ? Double(bytes) / secs / 1_000_000 : 0
            lines.append("  Average copy speed: \(String(format: "%.0f", avg)) MB/s over \(VolumeInfo.format(bytes)) in \(formatDuration(secs))")
        }
        lines.append("")

        lines.append("Total files: \(outcomes.count)")
        lines.append("Total size:  \(VolumeInfo.format(outcomes.reduce(0) { $0 + $1.size }))")
        lines.append("Completed:   \(stamp.string(from: finishDate))")
        lines.append("Duration:    \(formatDuration(finishDate.timeIntervalSince(startDate)))")
        lines.append("")
        if mode.rereadsSource {
            let bad = outcomes.filter { $0.sourceRereadOK == false }.count
            lines.append("Card re-read: " + (bad == 0 ? "every file hashed identically on a second read of the card" : "\(bad) file(s) hashed DIFFERENTLY on re-read — the card read unreliably"))
        }
        if mode.byteCompare {
            let bad = outcomes.filter { $0.byteCompareOK.values.contains(false) }.count
            lines.append("Byte compare: " + (bad == 0 ? "every copy byte-identical to the source" : "\(bad) copy/copies differ byte-for-byte"))
        }
        lines.append("")
        if !mode.hashes {
            lines.append("Result:      COPIED IN QUICK MODE — NOT VERIFIED. DO NOT WIPE THE SOURCE ON THIS REPORT.")
        } else {
            lines.append("Result:      " + (allGood
                ? "ALL DESTINATIONS VERIFIED (\(mode.rawValue.uppercased())) — SAFE TO WIPE SOURCE"
                : "VERIFICATION FAILED — DO NOT WIPE SOURCE"))
        }

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

    private static func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }

    private static func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
