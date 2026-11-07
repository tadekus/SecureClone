//
//  MetadataService.swift
//  SecureClone
//
//  Two passes, both run against a VERIFIED destination copy (never the
//  source card, so the copy's read bandwidth is never contested):
//
//   1. metadata(…)   — fast header reads; runs before reports so the CSV
//                      is complete. ALE sidecar > MXF header > AVFoundation.
//   2. thumbnails(…) — one decoded frame per clip; runs in the background
//                      after the summary is shown, then writes a contact sheet.
//

import Foundation
import AppKit

enum MetadataService {

    /// Build ClipMetadata for every file. Limited concurrency keeps the drive
    /// doing mostly sequential reads.
    static func metadata(outcomes: [FileCloneOutcome],
                         root: URL,
                         concurrency: Int = 4) async -> [ClipMetadata] {

        // ALE sidecars first: index by clip name.
        let aleFiles = outcomes.filter { $0.relativePath.lowercased().hasSuffix(".ale") }
                               .map { root.appendingPathComponent($0.relativePath) }
        let ale = ALEParser.index(aleFiles: aleFiles)

        var results = Array<ClipMetadata?>(repeating: nil, count: outcomes.count)

        await withTaskGroup(of: (Int, ClipMetadata).self) { group in
            var next = 0
            let total = outcomes.count
            while next < min(concurrency, total) {
                let i = next; next += 1
                let o = outcomes[i]
                group.addTask { (i, await extract(outcome: o, root: root, ale: ale)) }
            }
            for await (i, m) in group {
                results[i] = m
                if next < total {
                    let j = next; next += 1
                    let o = outcomes[j]
                    group.addTask { (j, await extract(outcome: o, root: root, ale: ale)) }
                }
            }
        }
        return results.compactMap { $0 }
    }

    private static func extract(outcome o: FileCloneOutcome, root: URL, ale: [String: ALEClip]) async -> ClipMetadata {
        let url = root.appendingPathComponent(o.relativePath)
        let kind = MediaKind.of(url)
        let name = kind == .sidecar ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var m = ClipMetadata(relativePath: o.relativePath, name: name, size: o.size,
                             sourceHash: o.sourceHash, isMediaClip: kind != .sidecar)
        let ext = url.pathExtension.lowercased()

        switch kind {
        case .video:
            if ext == "mxf" {
                if let info = MXFParser.parse(fileAt: url) {
                    var tmp = m; MXFParser.apply(info, to: &tmp); m.fillMissing(from: tmp)
                }
                // ProRes-in-MXF may also be readable by AVFoundation.
                if m.codec == nil || m.codec!.hasPrefix("ProRes"), let r = await AVExtractor.metadata(fileAt: url) {
                    m.fillMissing(from: fromAV(r, base: m))
                }
            } else if ext == "braw" || ext == "r3d" || ext == "crm" {
                m.codec = ext == "braw" ? "Blackmagic RAW" : ext == "r3d" ? "REDCODE RAW" : "Cinema RAW"
            } else if let r = await AVExtractor.metadata(fileAt: url) {
                m.fillMissing(from: fromAV(r, base: m))
            }
        case .audio:
            if ext == "wav" || ext == "bwf", let w = WAVReader.read(url) {
                m.durationSeconds = w.durationSeconds
                m.codec = w.formatDescription ?? "Linear PCM"
                if let tc = w.timecode() {
                    m.tcStart = tc.start
                    m.tcEnd = tc.end
                    if let f = w.timecodeFPS { m.fps = Timecode.fpsString(f) }
                }
            }
        case .still:
            let s = StillExtractor.metadata(fileAt: url)
            m.resolution = s.resolution; m.exposureIndex = s.iso; m.shutterAngle = s.exposure; m.codec = s.codec
        case .sidecar:
            break
        }

        // ALE wins on every field it provides.
        if kind == .video, let a = ale[name.uppercased()] {
            ALEParser.apply(a, to: &m)
        }
        return m
    }

    private static func fromAV(_ r: AVExtractor.Result, base: ClipMetadata) -> ClipMetadata {
        var m = base
        m.durationSeconds = r.durationSeconds; m.fps = r.fps; m.resolution = r.resolution
        m.codec = r.codec; m.tcStart = r.tcStart; m.tcEnd = r.tcEnd
        return m
    }

    // MARK: - Thumbnails

    /// Generate thumbnails for video + still clips, calling `onThumb` on the
    /// main actor as each one lands. Returns when all are done.
    static func thumbnails(clips: [ClipMetadata],
                           root: URL,
                           concurrency: Int = 3,
                           onThumb: @escaping @MainActor (String, Data) -> Void) async {
        let targets = clips.enumerated().filter { _, c in
            let k = MediaKind.of(URL(fileURLWithPath: c.relativePath))
            return k == .video || k == .still
        }
        let clipList = targets.map { $0.element }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let total = clipList.count
            func work(_ c: ClipMetadata) async {
                let url = root.appendingPathComponent(c.relativePath)
                let data: Data?
                if MediaKind.of(url) == .still {
                    data = StillExtractor.thumbnail(fileAt: url)
                } else {
                    data = await AVExtractor.thumbnail(fileAt: url)
                }
                if let d = data { await onThumb(c.relativePath, d) }
            }
            while next < min(concurrency, total) {
                let c = clipList[next]; next += 1
                group.addTask { await work(c) }
            }
            for await _ in group {
                guard !Task.isCancelled, next < total else { continue }
                let c = clipList[next]; next += 1
                group.addTask { await work(c) }
            }
        }
    }

    // MARK: - Contact sheet

    /// Grid of thumbnails with clip names, written as JPEG next to the reports.
    @discardableResult
    static func writeContactSheet(clips: [ClipMetadata], to root: URL,
                                  jobName: String, finishDate: Date) throws -> URL? {
        let withThumbs = clips.filter { $0.thumbnailJPEG != nil }
        guard !withThumbs.isEmpty else { return nil }

        let cols = 5, cellW: CGFloat = 320, cellH: CGFloat = 180, labelH: CGFloat = 34, pad: CGFloat = 10
        let rows = Int(ceil(Double(withThumbs.count) / Double(cols)))
        let size = NSSize(width: CGFloat(cols) * (cellW + pad) + pad,
                          height: CGFloat(rows) * (cellH + labelH + pad) + pad + 40)

        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.6, alpha: 1)]

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        ("\(jobName)  ·  \(withThumbs.count) clips  ·  \(df.string(from: finishDate))  ·  \(AppInfo.fullName)" as NSString)
            .draw(at: NSPoint(x: pad, y: size.height - 30), withAttributes: titleAttrs)

        for (i, c) in withThumbs.enumerated() {
            let col = i % cols, row = i / cols
            let x = pad + CGFloat(col) * (cellW + pad)
            let yTop = size.height - 40 - pad - CGFloat(row) * (cellH + labelH + pad)
            let thumbRect = NSRect(x: x, y: yTop - cellH, width: cellW, height: cellH)
            NSColor.black.setFill(); thumbRect.fill()
            if let d = c.thumbnailJPEG, let t = NSImage(data: d) {
                let s = t.size
                let scale = min(cellW / s.width, cellH / s.height)
                let w = s.width * scale, h = s.height * scale
                t.draw(in: NSRect(x: x + (cellW - w) / 2, y: thumbRect.minY + (cellH - h) / 2, width: w, height: h))
            }
            (c.name as NSString).draw(in: NSRect(x: x, y: thumbRect.minY - 16, width: cellW, height: 14), withAttributes: labelAttrs)
            var subParts: [String] = []
            if let r = c.resolution { subParts.append(r) }
            if let f = c.fps { subParts.append("\(f) fps") }
            if let k = c.codec { subParts.append(k) }
            if let t = c.tcStart { subParts.append(t) }
            let sub = subParts.joined(separator: "  ·  ")
            (sub as NSString).draw(in: NSRect(x: x, y: thumbRect.minY - 30, width: cellW, height: 12), withAttributes: subAttrs)
        }
        img.unlockFocus()

        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }

        let dir = root.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ReportNaming.base(jobName: jobName, date: finishDate))_thumbs.jpg")
        try jpg.write(to: url)
        return url
    }
}

