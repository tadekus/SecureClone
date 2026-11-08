//
//  PDFReportWriter.swift
//  SecureClone
//
//  A4 PDF reports drawn with Core Graphics + AppKit text: the job report
//  (verdict, destinations, per-file table, thumbnails) and the shooting-day
//  summary. No PDF library needed.
//

import Foundation
import AppKit

enum PDFReportWriter {

    private static let pageW: CGFloat = 595.28, pageH: CGFloat = 841.89   // A4 points
    private static let margin: CGFloat = 40

    /// Minimal page-flow helper: y runs downward; new page when out of room.
    private final class Page {
        let ctx: CGContext
        var y: CGFloat = 0
        var pageNumber = 0
        let footer: String
        init(ctx: CGContext, footer: String) { self.ctx = ctx; self.footer = footer }

        func begin() {
            if pageNumber > 0 { end() }
            pageNumber += 1
            ctx.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            y = pageH - margin
        }
        func end() {
            let f = "\(footer)   ·   page \(pageNumber)"
            (f as NSString).draw(at: NSPoint(x: margin, y: margin - 18), withAttributes: PDFReportWriter.attrs(8, .gray))
            ctx.endPDFPage()
        }
        func ensure(_ h: CGFloat) { if y - h < margin + 10 { begin() } }

        func text(_ s: String, size: CGFloat = 10, bold: Bool = false, mono: Bool = false,
                  color: NSColor = .black, indent: CGFloat = 0, lineHeight: CGFloat? = nil) {
            let a = PDFReportWriter.attrs(size, color, bold: bold, mono: mono)
            let maxW = pageW - 2 * margin - indent
            let r = (s as NSString).boundingRect(with: NSSize(width: maxW, height: 10_000),
                                                 options: [.usesLineFragmentOrigin], attributes: a)
            let h = max(lineHeight ?? 0, ceil(r.height) + 2)
            ensure(h)
            (s as NSString).draw(in: NSRect(x: margin + indent, y: y - h, width: maxW, height: h), withAttributes: a)
            y -= h
        }
        func gap(_ h: CGFloat = 6) { y -= h }
        func rule() { ensure(6); ctx.setStrokeColor(NSColor.lightGray.cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: margin, y: y - 2)); ctx.addLine(to: CGPoint(x: pageW - margin, y: y - 2)); ctx.strokePath(); y -= 6 }
    }

    private static func attrs(_ size: CGFloat, _ color: NSColor, bold: Bool = false, mono: Bool = false) -> [NSAttributedString.Key: Any] {
        let font: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                                : (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
        return [.font: font, .foregroundColor: color]
    }

    private static func open(_ url: URL) -> CGContext? {
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        return CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: AppInfo.fullName] as CFDictionary)
    }

    // MARK: - Job report

    @discardableResult
    static func writeJob(to root: URL, jobName: String, finishDate: Date,
                         source: VolumeInfo, sourceFolder: URL?, destinations: [VolumeInfo], destinationFolders: [URL],
                         outcomes: [FileCloneOutcome], clips: [ClipMetadata],
                         algorithm: HashAlgorithm, mode: VerificationMode, startDate: Date,
                         skipped: Int, verified: Bool) throws -> URL {
        let dir = root.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ReportNaming.base(jobName: jobName, date: finishDate)).pdf")
        guard let ctx = open(url) else { throw NSError(domain: "SecureClone", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create PDF"]) }
        let page = Page(ctx: ctx, footer: "\(AppInfo.fullName) — \(jobName)")
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"

        page.begin()
        page.text("Offload Report", size: 20, bold: true)
        page.text(jobName, size: 14, bold: true, color: .darkGray)
        page.gap(8)

        // Verdict banner.
        let quick = !mode.hashes
        let verdict = quick ? "COPIED — NOT VERIFIED (Quick mode)" : verified ? "ALL DESTINATIONS VERIFIED — SAFE TO WIPE SOURCE" : "VERIFICATION FAILED — DO NOT WIPE SOURCE"
        let color: NSColor = quick ? .systemOrange : verified ? .systemGreen : .systemRed
        page.ensure(34)
        ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: margin, y: page.y - 30, width: pageW - 2 * margin, height: 30))
        (verdict as NSString).draw(in: NSRect(x: margin + 10, y: page.y - 26, width: pageW - 2 * margin - 20, height: 20),
                                   withAttributes: attrs(12, color, bold: true))
        page.y -= 36

        let totalBytes = outcomes.reduce(Int64(0)) { $0 + $1.size }
        let timed = outcomes.filter { $0.copySeconds > 0 }
        let secs = timed.reduce(0.0) { $0 + $1.copySeconds }
        let avg = secs > 0 ? Double(timed.reduce(Int64(0)) { $0 + $1.size }) / secs / 1_000_000 : 0
        let rows: [(String, String)] = [
            ("Source", "\((sourceFolder ?? source.url).path)  (\(source.name), \(source.totalCapacityFormatted)\(source.connection.map { ", \($0.label)" } ?? ""))"),
            ("Mode", "\(mode.rawValue) — \(mode.summary)"),
            ("Checksum", algorithm.rawValue + (mode.secondHash ? " + MD5" : "")),
            ("Started", df.string(from: startDate)),
            ("Finished", df.string(from: finishDate)),
            ("Duration", CloneJob.formatDuration(finishDate.timeIntervalSince(startDate))),
            ("Files", "\(outcomes.count)  ·  \(VolumeInfo.format(totalBytes))" + (skipped > 0 ? "  ·  \(skipped) skipped (identical)" : "")),
            ("Avg speed", avg > 0 ? String(format: "%.0f MB/s", avg) : "—"),
            ("Host", "\(Host.current().localizedName ?? "unknown")  ·  user \(NSUserName())  ·  \(AppInfo.fullName)")
        ]
        for (k, v) in rows {
            page.ensure(14)
            (k as NSString).draw(at: NSPoint(x: margin, y: page.y - 12), withAttributes: attrs(9, .gray))
            ((v) as NSString).draw(in: NSRect(x: margin + 70, y: page.y - 12, width: pageW - 2 * margin - 70, height: 12), withAttributes: attrs(9, .black))
            page.y -= 14
        }
        page.gap(10)

        page.text("Destinations", size: 12, bold: true)
        page.rule()
        for (i, d) in destinations.enumerated() {
            let folder = i < destinationFolders.count ? destinationFolders[i] : d.url
            let vals = outcomes.compactMap { $0.verified[folder] }
            let ok = !vals.isEmpty && vals.allSatisfy { $0 }
            let bytes = outcomes.filter { $0.verified[folder] != nil }.reduce(Int64(0)) { $0 + $1.size }
            page.text("\(quick ? "•" : ok ? "✓" : "✗")  \(d.name)\(d.connection.map { "  (\($0.label))" } ?? "")  —  \(folder.path)", size: 9.5, bold: true,
                      color: quick ? .darkGray : ok ? .systemGreen : .systemRed)
            page.text("\(vals.count) files · \(VolumeInfo.format(bytes)) · " + (quick ? "copied, not verified" : ok ? "verified" : "FAILED (\(vals.filter { $0 }.count)/\(vals.count) ok)"),
                      size: 9, color: .darkGray, indent: 14)
        }
        if mode.rereadsSource {
            let bad = outcomes.filter { $0.sourceRereadOK == false }.count
            page.text("Card re-read: " + (bad == 0 ? "identical on a second pass" : "\(bad) file(s) read differently — unreliable card"), size: 9, color: bad == 0 ? .darkGray : .systemRed, indent: 0)
        }
        if mode.byteCompare {
            let bad = outcomes.filter { $0.byteCompareOK.values.contains(false) }.count
            page.text("Byte compare: " + (bad == 0 ? "every copy byte-identical" : "\(bad) copy/copies differ"), size: 9, color: bad == 0 ? .darkGray : .systemRed)
        }
        page.gap(10)

        // Per-file table.
        page.text("Files", size: 12, bold: true)
        page.rule()
        let colX: [CGFloat] = [0, 14, 62, 122, 176, 232]
        func header() {
            page.ensure(14)
            for (t, x) in zip(["", "Time", "Size", "Duration", "Speed", "File  ·  \(algorithm.rawValue)"], colX) {
                (t as NSString).draw(at: NSPoint(x: margin + x, y: page.y - 10), withAttributes: attrs(7.5, .gray, bold: true))
            }
            page.y -= 13
        }
        header()
        let sorted = outcomes.sorted { ($0.copyStartedAt ?? .distantPast) < ($1.copyStartedAt ?? .distantPast) }
        for o in sorted {
            if page.y - 22 < margin + 10 { page.begin(); header() }
            let mark = quick ? "•" : o.allVerified ? "✓" : "✗"
            let mc: NSColor = quick ? .darkGray : o.allVerified ? .systemGreen : .systemRed
            let cells: [(String, NSColor, Bool)] = [
                (mark, mc, true),
                (o.copyStartedAt.map { tf.string(from: $0) } ?? "—", .black, false),
                (VolumeInfo.format(o.size), .black, false),
                (o.copySeconds > 0 ? CloneJob.formatDuration(o.copySeconds) : "skipped", .black, false),
                (o.copySeconds > 0 ? String(format: "%.0f MB/s", o.copyMBps) : "", .black, false)
            ]
            for ((t, c, b), x) in zip(cells, colX) {
                (t as NSString).draw(at: NSPoint(x: margin + x, y: page.y - 9), withAttributes: attrs(7.5, c, bold: b, mono: true))
            }
            let nameW = pageW - 2 * margin - colX[5]
            (o.relativePath as NSString).draw(in: NSRect(x: margin + colX[5], y: page.y - 9, width: nameW, height: 9),
                                               withAttributes: attrs(7, .black, mono: true))
            page.y -= 10
            if !o.sourceHash.isEmpty {
                (o.sourceHash as NSString).draw(in: NSRect(x: margin + colX[5], y: page.y - 8, width: nameW, height: 8),
                                                 withAttributes: attrs(6.5, .gray, mono: true))
                page.y -= 10
            }
        }

        // Thumbnails.
        let thumbs = clips.filter { $0.thumbnailJPEG != nil }
        if !thumbs.isEmpty {
            page.begin()
            page.text("Clips", size: 12, bold: true)
            page.rule()
            let cols = 4, cellW = (pageW - 2 * margin - 3 * 8) / 4, cellH = cellW * 9 / 16
            var col = 0
            for c in thumbs {
                if col == 0 { page.ensure(cellH + 26) }
                let x = margin + CGFloat(col) * (cellW + 8)
                let rect = NSRect(x: x, y: page.y - cellH, width: cellW, height: cellH)
                if let d = c.thumbnailJPEG, let img = NSImage(data: d) { img.draw(in: rect) }
                (c.name as NSString).draw(in: NSRect(x: x, y: page.y - cellH - 10, width: cellW, height: 9), withAttributes: attrs(6.5, .black, mono: true))
                var sub: [String] = []
                if let r = c.resolution { sub.append(r) }
                if let f = c.fps { sub.append("\(f) fps") }
                if let t = c.tcStart { sub.append(t) }
                (sub.joined(separator: " · ") as NSString).draw(in: NSRect(x: x, y: page.y - cellH - 19, width: cellW, height: 8), withAttributes: attrs(6, .gray))
                col += 1
                if col == cols { col = 0; page.y -= cellH + 26 }
            }
        }
        page.end()
        ctx.closePDF()
        return url
    }

    // MARK: - Day summary

    @discardableResult
    static func writeDay(for date: Date, to volumeRoot: URL, project: String) throws -> URL? {
        let entries = HistoryStore.entries(onDayOf: date).sorted { $0.date < $1.date }
        guard !entries.isEmpty else { return nil }
        let dir = volumeRoot.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        let url = dir.appendingPathComponent("DAY_\(df.string(from: date))_SUMMARY.pdf")
        guard let ctx = open(url) else { return nil }
        let page = Page(ctx: ctx, footer: "\(AppInfo.fullName) — day summary")
        let day = DateFormatter(); day.dateFormat = "EEEE, d MMMM yyyy"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"

        page.begin()
        page.text("Shooting Day Summary", size: 20, bold: true)
        page.text(day.string(from: date) + (project.isEmpty ? "" : "  ·  \(project)"), size: 12, color: .darkGray)
        page.gap(10)
        let failed = entries.filter { !$0.verified }
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.totalBytes }
        let color: NSColor = failed.isEmpty ? .systemGreen : .systemRed
        page.ensure(34)
        ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: margin, y: page.y - 30, width: pageW - 2 * margin, height: 30))
        let v = failed.isEmpty ? "ALL \(entries.count) CARDS VERIFIED  ·  \(VolumeInfo.format(totalBytes))" : "\(failed.count) CARD(S) NOT VERIFIED: \(failed.map { $0.reel }.joined(separator: ", "))"
        (v as NSString).draw(in: NSRect(x: margin + 10, y: page.y - 26, width: pageW - 2 * margin - 20, height: 20), withAttributes: attrs(12, color, bold: true))
        page.y -= 40

        let colX: [CGFloat] = [0, 40, 130, 165, 215, 275, 420]
        func header() {
            page.ensure(14)
            for (t, x) in zip(["Time", "Reel", "Cam", "Files", "Size", "Destinations", "Result"], colX) {
                (t as NSString).draw(at: NSPoint(x: margin + x, y: page.y - 10), withAttributes: attrs(8, .gray, bold: true))
            }
            page.y -= 13
        }
        header()
        for e in entries {
            if page.y - 14 < margin + 10 { page.begin(); header() }
            let cells = [tf.string(from: e.date), e.reel, e.camera ?? "-", String(e.fileCount), VolumeInfo.format(e.totalBytes),
                         e.destinations.joined(separator: ", "), e.verified ? "VERIFIED" : "FAILED"]
            for (i, (t, x)) in zip(cells, colX).enumerated() {
                let c: NSColor = i == 6 ? (e.verified ? .systemGreen : .systemRed) : .black
                (t as NSString).draw(in: NSRect(x: margin + x, y: page.y - 10, width: (i < 6 ? colX[i + 1] - x : 100) - 4, height: 10),
                                     withAttributes: attrs(8, c, bold: i == 6, mono: i != 1 && i != 5))
            }
            page.y -= 12
        }
        page.gap(10)
        let byCam = Dictionary(grouping: entries) { $0.camera ?? "?" }
        page.text("Per camera", size: 11, bold: true)
        for cam in byCam.keys.sorted() {
            let es = byCam[cam]!
            page.text("\(cam): \(es.count) card(s), \(es.reduce(0) { $0 + $1.fileCount }) files, \(VolumeInfo.format(es.reduce(0) { $0 + $1.totalBytes }))", size: 9, indent: 10)
        }
        page.end()
        ctx.closePDF()
        return url
    }
}
