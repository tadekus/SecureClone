//
//  ContentView.swift
//  SecureClone
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: CloneViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: DriveMonitor

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding([.horizontal, .top])
                Picker("", selection: $vm.mode) {
                    ForEach(CloneViewModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal).padding(.top, 10)
                .disabled(vm.isRunning)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if vm.mode == .offload { offloadPane } else { verifyPane }
                    }
                    .padding()
                }

                Divider()
                VStack(spacing: 8) {
                    if !vm.queue.isEmpty { QueueView() }
                    actionButtons
                }
                .padding()
            }
            .frame(minWidth: 400, idealWidth: 440)

            JobProgressView()
                .frame(minWidth: 500)
        }
        .sheet(isPresented: $vm.showSummary) {
            if let job = vm.job { SummarySheet(job: job) { vm.showSummary = false } }
        }
        .alert("Resume previous session?", isPresented: $vm.showResumePrompt) {
            Button("Resume") { vm.resumePrevious() }
            Button("Start over", role: .destructive) { vm.startOver() }
            Button("Cancel", role: .cancel) { vm.cancelPending() }
        } message: {
            if let s = vm.pendingResume {
                Text("A stopped job \"\(s.jobName)\" for this card was found: \(s.completed.count) of \(s.totalFiles) files "
                     + "(\(VolumeInfo.format(s.completedBytes)) of \(VolumeInfo.format(s.totalBytes))) already copied. "
                     + "Resume skips those and re-verifies everything.")
            }
        }
        .alert("This card was already offloaded", isPresented: $vm.showDuplicatePrompt) {
            Button("Copy again anyway") { vm.duplicateContinue() }
            Button("Skip this card", role: .cancel) { vm.duplicateCancel() }
        } message: {
            if let d = vm.duplicateOf {
                Text("Reel \(d.reel) (\(d.fileCount) files, \(VolumeInfo.format(d.totalBytes))) was verified "
                     + "\(DateFormatter.localizedString(from: d.date, dateStyle: .medium, timeStyle: .short)) "
                     + "to \(d.destinations.joined(separator: ", ")).")
            }
        }
        .alert("SecureClone", isPresented: $vm.showError) {
            Button("OK", role: .cancel) { }
        } message: { Text(vm.errorMessage ?? "") }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.checkmark").font(.title).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("SecureClone").font(.title2).bold()
                    Text("v\(AppInfo.versionString)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                Text("Verified media offload").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh drives")
        }
    }

    // MARK: - Offload

    private var offloadPane: some View {
        Group {
            SourcePickerView(volumes: monitor.volumes)
            DestinationPickerView(volumes: monitor.volumes)
            namingSection
            optionsSection
        }
    }

    private var namingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Naming", systemImage: "folder.badge.gearshape").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Project").foregroundStyle(.secondary)
                    TextField("e.g. MYFILM", text: $settings.project).textFieldStyle(.roundedBorder)
                    Text("Day").foregroundStyle(.secondary)
                    TextField("DAY_03", text: $settings.day).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                GridRow {
                    Text("Camera").foregroundStyle(.secondary)
                    TextField("A", text: $vm.camera).textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("Reel").foregroundStyle(.secondary)
                    TextField("A_0071", text: $vm.reel).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Job name").foregroundStyle(.secondary)
                    TextField("Offload", text: $vm.jobName)
                        .textFieldStyle(.roundedBorder)
                        .gridCellColumns(3)
                }
                GridRow {
                    Text("Template").foregroundStyle(.secondary)
                    TextField("{project}/{day}/{camera}/{reel}", text: $settings.template)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        .gridCellColumns(3)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Text(vm.namingPreview).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            Text("Tokens: " + NamingFields.tokens.joined(separator: " "))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Options", systemImage: "slider.horizontal.3").font(.headline)
            HStack {
                Text("Checksum").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                Picker("", selection: $settings.algorithm) {
                    ForEach(HashAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Toggle("Auto-start when a card is inserted (uses the selected destinations)", isOn: $settings.autoStart)
            Toggle("Eject the card after it's verified", isOn: $settings.autoEject)
            Toggle("Skip files that already exist with identical verified hashes", isOn: $settings.skipIdentical)
            Toggle("Also save report + CSV to the source card", isOn: $settings.saveReportToSource)
            Toggle("Prevent sleep while a job runs", isOn: $settings.preventSleep)
            Toggle("Show in menu bar (keeps running when the window is closed)", isOn: $settings.showInMenuBar)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    // MARK: - Verify

    private var verifyPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Re-hash every file listed in an MHL manifest and compare — for checking a shuttle drive after transport or an archive drive later.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Drive to verify", systemImage: "externaldrive").font(.headline)
                    if vm.scanningMHLs { ProgressView().controlSize(.mini) }
                }
                ForEach(monitor.volumes) { vol in
                    verifyRow(vol)
                }
            }

            if vm.verifyVolume != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Manifest (\(vm.availableMHLs.count) found)", systemImage: "doc.text.magnifyingglass").font(.headline)
                        Spacer()
                        Button("Choose file…") { vm.chooseMHLFile() }.controlSize(.small)
                    }
                    if vm.availableMHLs.isEmpty && !vm.scanningMHLs {
                        Text("No .mhl files found on this drive. Use “Choose file…” to pick one manually.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(vm.availableMHLs, id: \.self) { u in
                        MHLRow(url: u, selected: vm.selectedMHL == u) { vm.selectedMHL = u }
                    }
                }
            }
        }
    }

    private func verifyRow(_ vol: VolumeInfo) -> DriveRow {
        let isSel = vm.verifyVolume == vol
        var ejectAction: (() -> Void)? = nil
        if vol.isRemovable { ejectAction = { vm.eject(vol) } }
        return DriveRow(volume: vol, isSelected: isSel, accent: .blue,
                        onSelect: { vm.selectVerifyVolume(isSel ? nil : vol) },
                        onEject: ejectAction)
    }

    // MARK: - Buttons

    @ViewBuilder private var actionButtons: some View {
        if vm.isRunning {
            HStack(spacing: 8) {
                Button { if vm.isPaused { vm.resume() } else { vm.pause() } } label: {
                    Label(vm.isPaused ? "Resume" : "Pause", systemImage: vm.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.bordered)
                .disabled(vm.job?.state == .scanning)

                Button(role: .destructive) { vm.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.bordered).tint(.red)

                if vm.mode == .offload {
                    Button { vm.start() } label: { Label("Queue", systemImage: "text.badge.plus") }
                        .controlSize(.large).buttonStyle(.bordered)
                        .disabled(!vm.canStart)
                        .help("Add the selected card to the queue; it starts when the current job finishes")
                }
            }
        } else {
            HStack(spacing: 8) {
                Button { vm.start() } label: {
                    HStack {
                        Image(systemName: vm.mode == .verify ? "checkmark.shield" : "play.fill")
                        Text(vm.mode == .verify ? "Start Verify"
                             : (vm.job?.state == .stopped ? "Resume / Start Clone" : "Start Clone"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(!vm.canStart)

                if let j = vm.job, !j.state.isActive {
                    Button { vm.clearFinished() } label: { Label("Clear", systemImage: "xmark") }
                        .controlSize(.large).buttonStyle(.bordered)
                }
            }
        }
    }
}

struct MHLRow: View {
    let url: URL
    let selected: Bool
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: "/Volumes/", with: ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

/// Pending jobs, with a remove button each.
struct QueueView: View {
    @EnvironmentObject var vm: CloneViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Queue (\(vm.queue.count))").font(.caption).bold().foregroundStyle(.secondary)
            ForEach(vm.queue) { spec in
                HStack {
                    Image(systemName: spec.autoAdded ? "bolt.fill" : "clock").foregroundStyle(.secondary)
                    Text(spec.jobName).bold()
                    Text("\(spec.source.name) → \(spec.destinations.map { $0.name }.joined(separator: ", "))")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { vm.removeFromQueue(spec) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06)))
            }
        }
    }
}
