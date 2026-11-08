//
//  JobProgressView.swift
//  SecureClone
//
//  Right-hand pane: current job header (copy + verify progress, speed, ETA),
//  per-destination rows, then a Log / Clips / Jobs switcher.
//

import SwiftUI
import AppKit

struct JobProgressView: View {
    @EnvironmentObject var vm: CloneViewModel
    @EnvironmentObject var logStore: LogStore
    @State private var pane: Pane = .log

    enum Pane: String, CaseIterable { case log = "Log", clips = "Clips", jobs = "Jobs" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let job = vm.job {
                JobHeader(job: job)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(job.destinationProgress) { dp in
                            DestinationProgressRow(progress: dp, totalBytes: job.totalBytes)
                        }
                    }
                }
                .frame(maxHeight: 180)
                Divider()
            } else {
                HStack {
                    Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
                    Text("No active job — select a source and destinations, then press Start.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Divider()
            }

            Picker("", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            .onChange(of: vm.job?.clips.count ?? 0) { _, n in if n > 0 { pane = .clips } }

            switch pane {
            case .log:   LogView()
            case .clips: if let job = vm.job { ClipGridView(job: job) } else { Text("No job.").foregroundStyle(.secondary) }
            case .jobs:  JobsListView()
            }
        }
        .padding()
    }
}

// MARK: - Header

struct JobHeader: View {
    @ObservedObject var job: CloneJob

    private var isVerifyPhase: Bool { job.state == .verifying || job.kind == .verifyOnly }
    private var showStats: Bool {
        switch job.state {
        case .copying, .paused, .verifying, .completed, .stopped: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).font(.headline)
                    Text(job.state.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if showStats {
                    Text(isVerifyPhase ? job.verifyPercentText : job.percentText)
                        .font(.system(.title3, design: .rounded).monospacedDigit()).bold()
                }
                statusBadge
            }

            if job.kind == .offload {
                HStack {
                    Text("Copy").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    ProgressView(value: job.overallProgress)
                    Text(job.percentText).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            if isVerifyPhase || job.state == .completed || job.verifyBytesDone > 0 {
                HStack {
                    Text("Verify").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    ProgressView(value: job.verifyProgress).tint(.green)
                    Text(job.verifyPercentText).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }

            if showStats {
                let v = isVerifyPhase
                HStack(spacing: 18) {
                    stat("Speed", v ? job.verifySpeedText : job.speedText, icon: "speedometer")
                    stat("ETA", etaText(verify: v), icon: "clock")
                    stat("Elapsed", v ? job.verifyElapsedText : job.elapsedText, icon: "stopwatch")
                    stat(v ? "Verified" : "Copied",
                         v ? "\(VolumeInfo.format(job.verifyBytesDone)) / \(VolumeInfo.format(job.verifyTotalBytes))"
                           : "\(VolumeInfo.format(job.bytesProcessed)) / \(VolumeInfo.format(job.totalBytes))",
                         icon: "doc.on.doc")
                    if !v && job.verifyBytesDone > 0 {
                        stat("Verify", job.verifySpeedText + " · " + job.verifyPercentText, icon: "checkmark.shield")
                    }
                    if job.skippedFileCount > 0 {
                        stat("Skipped", "\(job.skippedFileCount)", icon: "equal.circle")
                    }
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if job.resumedFileCount > 0 {
                Label("\(job.resumedFileCount) files restored from the previous session (re-verified)",
                      systemImage: "arrow.counterclockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !job.currentFile.isEmpty && job.state.isActive {
                Text(job.currentFile)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
        }
    }

    private func etaText(verify: Bool) -> String {
        switch job.state {
        case .completed: return "done"
        case .paused:    return "paused"
        case .stopped:   return "—"
        default:         return verify ? job.verifyEtaText : job.etaText
        }
    }

    private func stat(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label + ":")
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch job.state {
        case .completed: Label("Verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:    Label("Failed", systemImage: "xmark.seal.fill").foregroundStyle(.red)
        case .paused:    Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
        case .stopped:   Label("Stopped", systemImage: "stop.circle.fill").foregroundStyle(.orange)
        default:         EmptyView()
        }
    }
}

// MARK: - Per-destination row

struct DestinationProgressRow: View {
    @ObservedObject var progress: DestinationProgress
    let totalBytes: Int64

    private var fraction: Double {
        totalBytes > 0 ? min(1, Double(progress.bytesCompleted) / Double(totalBytes)) : 0
    }
    private var verifyFraction: Double {
        totalBytes > 0 ? min(1, Double(progress.verifiedBytes) / Double(totalBytes)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "externaldrive.fill").foregroundStyle(progress.failed ? .red : .green)
                Text(progress.volume.name).bold()
                Spacer()
                if progress.verifiedCount > 0 || progress.failed {
                    Text("\(progress.verifiedCount)/\(progress.filesCompleted) verified")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(progress.filesCompleted) files written").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: fraction).tint(progress.failed ? .red : .blue)
            if progress.verifiedBytes > 0 {
                ProgressView(value: verifyFraction).tint(progress.failed ? .red : .green).controlSize(.small)
            }
            HStack {
                Text("written " + VolumeInfo.format(progress.bytesCompleted)).font(.caption2).foregroundStyle(.secondary)
                if progress.verifiedBytes > 0 {
                    Text("· verified " + VolumeInfo.format(progress.verifiedBytes)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}

// MARK: - Log (searchable, exportable, persisted)

struct LogView: View {
    @EnvironmentObject var logStore: LogStore
    @State private var query = ""
    @State private var autoScroll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search log…", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Follow", isOn: $autoScroll).toggleStyle(.checkbox).font(.caption)
                Button { copyLog() } label: { Image(systemName: "doc.on.clipboard") }.help("Copy log")
                Button { exportLog() } label: { Image(systemName: "square.and.arrow.up") }.help("Export log…")
                Button { NSWorkspace.shared.activateFileViewerSelecting([LogStore.directory]) } label: {
                    Image(systemName: "folder")
                }.help("Show log files in Finder")
            }
            .controlSize(.small)

            let lines = logStore.filtered(query)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.timeString).foregroundStyle(.tertiary)
                                Text(line.text).foregroundStyle(color(line.level))
                                    .textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: logStore.lines.count) { _, _ in
                    if autoScroll, query.isEmpty, let last = logStore.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Text("\(lines.count) lines" + (query.isEmpty ? "" : " matching “\(query)”"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func color(_ l: LogLine.Level) -> Color {
        switch l {
        case .info: return .primary
        case .ok:   return .green
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logStore.export(filter: query), forType: .string)
    }

    private func exportLog() {
        let p = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmm"
        p.nameFieldStringValue = "SecureClone_log_\(df.string(from: Date())).txt"
        if p.runModal() == .OK, let u = p.url {
            try? logStore.export(filter: query).data(using: .utf8)?.write(to: u)
        }
    }
}

// MARK: - Finished jobs

struct JobsListView: View {
    @EnvironmentObject var vm: CloneViewModel

    var body: some View {
        if vm.finishedJobs.isEmpty {
            Text("No finished jobs yet this session.").foregroundStyle(.secondary).font(.caption)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.finishedJobs) { job in
                        JobRow(job: job) {
                            vm.job = job
                            vm.showSummary = true
                        }
                    }
                }
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: CloneJob
    let onOpen: () -> Void
    var body: some View {
        HStack {
            Image(systemName: job.state == .completed ? "checkmark.seal.fill"
                  : job.state == .stopped ? "stop.circle.fill" : "xmark.seal.fill")
                .foregroundStyle(job.state == .completed ? .green : job.state == .stopped ? .orange : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).bold()
                Text("\(job.kind == .verifyOnly ? "Verify" : "Offload") · \(job.fileResults.count) files · \(VolumeInfo.format(job.totalBytes)) · \(job.state.label)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Report") { onOpen() }.controlSize(.small).disabled(job.finalReport == nil)
        }
        .font(.caption)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}
