//
//  DaySummaryWriter.swift
//  SecureClone
//
//  One report per shooting day aggregating every card offloaded that day:
//  per-card verdicts, totals, per-camera breakdown. Regenerated after each
//  job and written to every destination's SecureClone_Logs folder.
//

import Foundation

enum DaySummaryWriter {

    static func make(for date: Date, project: String = "") -> (text: String, csv: String)? {
        let entries = HistoryStore.entries(onDayOf: date).sorted { $0.date < $1.date }
        guard !entries.isEmpty else { return nil }

        let day = DateFormatter(); day.dateFormat = "EEEE, d MMMM yyyy"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        let totalBytes = entries.reduce(0) { $0 + $1.totalBytes }
        let totalFiles = entries.reduce(0) { $0 + $1.fileCount }
        let failed = entries.filter { !$0.verified }

        var l: [String] = []
        l.append("SHOOTING DAY SUMMARY — \(day.string(from: date))")
        if !project.isEmpty { l.append("Project:  \(project)") }
        l.append("Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)) by \(AppInfo.fullName)")
        l.append(String(repeating: "=", count: 72))
        l.append("")
        l.append(row("Time", "Reel", "Cam", "Files", "Size", "Destinations", "Result"))
        l.append(String(repeating: "-", count: 72))
        for e in entries {
            l.append(row(time.string(from: e.date), e.reel, e.camera ?? "-", String(e.fileCount),
                         VolumeInfo.format(e.totalBytes),
                         e.destinations.joined(separator: ", "),
                         e.verified ? "VERIFIED" : "FAILED"))
        }
        l.append(String(repeating: "-", count: 72))
        l.append("Cards: \(entries.count)   Files: \(totalFiles)   Total: \(VolumeInfo.format(totalBytes))")
        l.append("")

        // Per camera
        let byCam = Dictionary(grouping: entries) { $0.camera ?? "?" }
        l.append("Per camera:")
        for cam in byCam.keys.sorted() {
            let es = byCam[cam]!
            l.append("  \(cam): \(es.count) card\(es.count == 1 ? "" : "s"), \(es.reduce(0) { $0 + $1.fileCount }) files, \(VolumeInfo.format(es.reduce(0) { $0 + $1.totalBytes }))")
        }
        l.append("")

        // Per destination
        var byDest: [String: (Int, Int64)] = [:]
        for e in entries { for d in e.destinations { byDest[d, default: (0, 0)].0 += 1; byDest[d, default: (0, 0)].1 += e.totalBytes } }
        l.append("Per destination drive:")
        for d in byDest.keys.sorted() { l.append("  \(d): \(byDest[d]!.0) cards, \(VolumeInfo.format(byDest[d]!.1))") }
        l.append("")

        l.append(failed.isEmpty
                 ? "RESULT: ALL \(entries.count) CARDS VERIFIED"
                 : "RESULT: \(failed.count) CARD\(failed.count == 1 ? "" : "S") FAILED VERIFICATION — \(failed.map { $0.reel }.joined(separator: ", "))")

        // CSV
        var c = ["Time;Reel;Camera;System;Source;Files;Bytes;Destinations;Folders;Verified;Duration (s);App"]
        for e in entries {
            c.append([time.string(from: e.date), e.reel, e.camera ?? "", e.system, e.sourceName,
                      String(e.fileCount), String(e.totalBytes), e.destinations.joined(separator: " | "),
                      e.destinationFolders.joined(separator: " | "), e.verified ? "yes" : "no",
                      String(Int(e.durationSeconds)), e.appVersion]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ";"))
        }
        return (l.joined(separator: "\n") + "\n", c.joined(separator: "\n") + "\n")
    }

    private static func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
        if s.count >= w { return s }
        let fill = String(repeating: " ", count: w - s.count)
        return right ? fill + s : s + fill
    }
    private static func row(_ t: String, _ reel: String, _ cam: String, _ files: String,
                            _ size: String, _ dest: String, _ result: String) -> String {
        [pad(t, 6), pad(reel, 14), pad(cam, 5), pad(files, 6, right: true),
         pad(size, 10, right: true), pad(dest, 28), result].joined(separator: " ")
    }

    /// Write DAY_<yyyyMMdd>_SUMMARY.txt/.csv to a drive's SecureClone_Logs.
    @discardableResult
    static func write(for date: Date, to volumeRoot: URL, project: String = "") throws -> URL? {
        guard let made = make(for: date, project: project) else { return nil }
        let (text, csv) = made
        let dir = volumeRoot.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        let base = "DAY_\(df.string(from: date))_SUMMARY"
        let t = dir.appendingPathComponent("\(base).txt")
        try text.data(using: .utf8)!.write(to: t)
        try csv.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(base).csv"))
        return t
    }
}
