//
//  JobProgressView.swift
//  SecureClone
//

import SwiftUI

struct JobProgressView: View {
    @ObservedObject var vm: CloneViewModel

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
                .frame(maxHeight: 220)

                Divider()
                logView
            } else {
                ContentUnavailableView(
                    "No active job",
                    systemImage: "play.circle",
                    description: Text("Select a source card and one or more destination drives, then press Start Clone.")
                )
            }
        }
        .padding()
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logTail.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: vm.logTail.count) { _, _ in
                    if let last = vm.logTail.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

struct JobHeader: View {
    @ObservedObject var job: CloneJob

    private var showStats: Bool {
        switch job.state {
        case .copying, .paused, .verifying, .completed, .stopped: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.state.label).font(.headline)
                Spacer()
                if showStats {
                    Text(job.percentText)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .bold()
                }
                statusBadge
            }

            ProgressView(value: job.overallProgress)

            if job.state == .verifying || job.state == .completed {
                HStack {
                    Text("Verification").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", job.verifyProgress * 100))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: job.verifyProgress).tint(.green)
            }

            if showStats {
                HStack(spacing: 18) {
                    stat("Speed",   job.speedText,  icon: "speedometer")
                    stat("ETA",     job.state == .completed ? "done"
                                  : job.state == .paused ? "paused"
                                  : job.state == .stopped ? "—" : job.etaText,
                         icon: "clock")
                    stat("Elapsed", job.elapsedText, icon: "stopwatch")
                    stat("Copied",
                         "\(VolumeInfo.format(job.bytesProcessed)) / \(VolumeInfo.format(job.totalBytes))",
                         icon: "doc.on.doc")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if job.resumedFileCount > 0 {
                Label("\(job.resumedFileCount) files restored from the previous session (re-verified)",
                      systemImage: "arrow.counterclockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !job.currentFile.isEmpty && (job.state == .copying || job.state == .paused) {
                Text(job.currentFile)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
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
        case .completed:
            Label("Verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.seal.fill").foregroundStyle(.red)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
        case .stopped:
            Label("Stopped", systemImage: "stop.circle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

struct DestinationProgressRow: View {
    @ObservedObject var progress: DestinationProgress
    let totalBytes: Int64

    private var fraction: Double {
        totalBytes > 0 ? Double(progress.bytesCompleted) / Double(totalBytes) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(progress.failed ? .red : .green)
                Text(progress.volume.name).bold()
                Spacer()
                if progress.verifiedCount > 0 || progress.failed {
                    Text("\(progress.verifiedCount)/\(progress.filesCompleted) verified")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(progress.filesCompleted) files written")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: fraction)
                .tint(progress.failed ? .red : .green)
            Text(VolumeInfo.format(progress.bytesCompleted))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}
