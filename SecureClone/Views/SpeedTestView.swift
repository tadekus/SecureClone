//
//  SpeedTestView.swift
//  SecureClone
//
//  Speed-test mode: pick volumes, run, read the results table and the
//  estimated / measured transfer matrix.
//

import SwiftUI
import AppKit

struct SpeedTestView: View {
    @EnvironmentObject var st: SpeedTestViewModel
    @EnvironmentObject var monitor: DriveMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measures real read and write throughput of each drive (caching disabled), then estimates and optionally measures transfer speed between them. Read-only volumes (locked cards) get a read test on their existing files.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("Volumes to test (\(st.selected.count))", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
                ForEach(monitor.volumes) { vol in
                    row(vol)
                }
            }

            HStack(spacing: 12) {
                Text("Test size").foregroundStyle(.secondary)
                Picker("", selection: $st.size) {
                    ForEach(SpeedTestViewModel.TestSize.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 220)
            }
            .disabled(st.isRunning)

            HStack(spacing: 12) {
                Toggle("Real transfer test from", isOn: $st.realTransfer).toggleStyle(.checkbox)
                Picker("", selection: $st.transferSource) {
                    Text("first removable").tag(VolumeInfo?.none)
                    ForEach(st.selected.sorted { $0.name < $1.name }) { v in
                        Text(v.name).tag(VolumeInfo?.some(v))
                    }
                }
                .labelsHidden().frame(maxWidth: 200)
                .disabled(!st.realTransfer)
            }
            .font(.caption)
            .disabled(st.isRunning)

            if st.isRunning || st.finishedAt != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if st.isRunning { ProgressView().controlSize(.small) }
                        Text(st.currentStep).font(.caption)
                    }
                    ProgressView(value: st.stepProgress)
                }
            }

            if !st.results.isEmpty { resultsTable }
            if st.results.count > 1 && st.results.contains(where: { $0.readMBps != nil }) { matrix }
            if !st.transfers.isEmpty { transfersTable }

            if st.finishedAt != nil {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(st.summaryText(), forType: .string)
                } label: { Label("Copy results", systemImage: "doc.on.clipboard") }
                .controlSize(.small)
            }
        }
    }

    private func row(_ vol: VolumeInfo) -> DriveRow {
        let sel = st.selected.contains(vol)
        let ro = SpeedTestService.isReadOnly(vol)
        return DriveRow(volume: vol, isSelected: sel, accent: .purple, showCheckbox: true,
                        subtitle: ro ? "Read-only · \(vol.totalCapacityFormatted)" : nil,
                        onSelect: { if sel { st.selected.remove(vol) } else { st.selected.insert(vol) } })
    }

    // MARK: - Results

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Results", systemImage: "chart.bar").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Volume").bold(); Text("Read").bold(); Text("Write").bold(); Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(st.results) { r in
                    GridRow {
                        Text(r.volume.name).bold()
                        speedCell(r.readMBps)
                        if r.readOnly { Text("read-only").foregroundStyle(.secondary) } else { speedCell(r.writeMBps) }
                        VStack(alignment: .leading, spacing: 1) {
                            if let n = r.note { Text(n).foregroundStyle(.secondary) }
                            if let e = r.error { Text(e).foregroundStyle(.red) }
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private func speedCell(_ v: Double?) -> some View {
        Text(v.map(SpeedTestViewModel.fmt) ?? "—")
            .monospacedDigit()
            .foregroundStyle(color(v))
    }

    private func color(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        if v >= 400 { return .green }
        if v >= 150 { return .primary }
        return .orange
    }

    private var matrix: some View {
        let vols = st.results.map { $0.volume }
        return VStack(alignment: .leading, spacing: 4) {
            Label("Estimated transfer (row → column) = min(read, write)", systemImage: "arrow.left.arrow.right")
                .font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("from \\ to").foregroundStyle(.secondary)
                    ForEach(vols) { v in Text(v.name).bold().lineLimit(1) }
                }
                .font(.caption)
                ForEach(vols) { a in
                    GridRow {
                        Text(a.name).bold().lineLimit(1)
                        ForEach(vols) { b in
                            if a == b {
                                Text("·").foregroundStyle(.tertiary)
                            } else {
                                speedCell(st.estimate(from: a, to: b))
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private var transfersTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Measured transfers (real files, single stream)", systemImage: "arrow.right.circle").font(.headline)
            ForEach(st.transfers) { t in
                HStack {
                    Text("\(t.from.name) → \(t.to.name)").bold()
                    Spacer()
                    if let e = t.error { Text(e).foregroundStyle(.red) } else { speedCell(t.mbps) }
                }
                .font(.caption)
            }
            Text("Offloading to several drives at once runs these in parallel; the card's read speed is usually the ceiling.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}
