//
//  ClipGridView.swift
//  SecureClone
//
//  Thumbnail grid of the clips in the current job, with the key metadata
//  under each one. Thumbnails fill in as the background pass produces them.
//

import SwiftUI
import AppKit

struct ClipGridView: View {
    @ObservedObject var job: CloneJob

    private var mediaClips: [ClipMetadata] {
        job.clips.filter { $0.isMediaClip }
    }

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(mediaClips.count) clips").font(.headline)
                Spacer()
                if job.thumbnailsTotal > 0 && job.thumbnailsDone < job.thumbnailsTotal {
                    ProgressView().controlSize(.small)
                    Text("thumbnails \(job.thumbnailsDone)/\(job.thumbnailsTotal)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if mediaClips.isEmpty {
                ContentUnavailableView("No clips yet", systemImage: "film",
                                       description: Text("Clip metadata appears after verification."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(mediaClips) { clip in
                            ClipCell(clip: clip)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct ClipCell: View {
    let clip: ClipMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85))
                if let d = clip.thumbnailJPEG, let img = NSImage(data: d) {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: MediaKind.of(URL(fileURLWithPath: clip.relativePath)) == .audio
                          ? "waveform" : "film")
                        .font(.title).foregroundStyle(.gray)
                }
            }
            .aspectRatio(16/9, contentMode: .fit)

            Text(clip.name)
                .font(.system(.caption, design: .monospaced)).bold()
                .lineLimit(1).truncationMode(.tail)

            Text(line1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(line2).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(tooltip)
    }

    private var line1: String {
        var parts: [String] = []
        if let r = clip.resolution { parts.append(r) }
        if let f = clip.fps { parts.append("\(f) fps") }
        if let k = clip.codec { parts.append(k) }
        return parts.joined(separator: " · ")
    }
    private var line2: String {
        var parts: [String] = []
        if let tc = clip.tcStart { parts.append("TC \(tc)") }
        if let d = clip.durationSeconds { parts.append("\(Int(d.rounded()))s") }
        if let ei = clip.exposureIndex { parts.append("EI \(ei)") }
        if !clip.shutterDisplay.isEmpty { parts.append(clip.shutterDisplay) }
        return parts.joined(separator: " · ")
    }
    private var tooltip: String {
        var t = clip.relativePath
        if let l = clip.lutNodes { t += "\nLUT: \(l)" }
        if let n = clip.ndFilter { t += "\nND: \(n)" }
        t += "\nHash: \(clip.sourceHash)"
        return t
    }
}
