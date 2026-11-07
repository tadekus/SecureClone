//
//  ContentView.swift
//  SecureClone
//

import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = DriveMonitor()
    @StateObject private var vm = CloneViewModel()

    var body: some View {
        HSplitView {
            // LEFT: selection
            VStack(alignment: .leading, spacing: 16) {
                header

                SourcePickerView(volumes: monitor.removableVolumes.isEmpty
                                 ? monitor.volumes : monitor.volumes,
                                 selection: $vm.selectedSource)

                DestinationPickerView(volumes: monitor.volumes,
                                      source: vm.selectedSource,
                                      selection: $vm.selectedDestinations)

                settingsBar

                Spacer()

                startButton
            }
            .padding()
            .frame(minWidth: 360, idealWidth: 400)

            // RIGHT: progress + log
            JobProgressView(vm: vm)
                .frame(minWidth: 460)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .sheet(isPresented: $vm.showSummary) {
            if let job = vm.job {
                SummarySheet(job: job) { vm.showSummary = false }
            }
        }
        .alert("Resume previous session?", isPresented: $vm.showResumePrompt) {
            Button("Resume") { vm.resumePrevious() }
            Button("Start over", role: .destructive) { vm.startOver() }
            Button("Cancel", role: .cancel) { vm.pendingResume = nil }
        } message: {
            if let s = vm.pendingResume {
                Text("A stopped job \"\(s.jobName)\" for this card was found: "
                     + "\(s.completed.count) of \(s.totalFiles) files "
                     + "(\(VolumeInfo.format(s.completedBytes)) of \(VolumeInfo.format(s.totalBytes))) "
                     + "already copied. Resume will skip those and re-verify everything.")
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("SecureClone").font(.title2).bold()
                    Text("v\(AppInfo.versionString)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text("Verified media offload").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh drives")
        }
    }

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Job name").frame(width: 90, alignment: .leading)
                TextField("Offload", text: $vm.jobName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Checksum").frame(width: 90, alignment: .leading)
                Picker("", selection: $vm.algorithm) {
                    ForEach(HashAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Toggle(isOn: $vm.saveReportToSource) {
                Text("Also save report + CSV to the source card")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Writes only into a SecureClone_Logs folder, after verification. Never touches your media files.")
        }
        .disabled(vm.isRunning)
    }

    @ViewBuilder private var startButton: some View {
        if vm.isRunning {
            HStack(spacing: 8) {
                Button {
                    vm.isPaused ? vm.resume() : vm.pause()
                } label: {
                    Label(vm.isPaused ? "Resume" : "Pause",
                          systemImage: vm.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(vm.job?.state == .scanning)

                Button(role: .destructive) {
                    vm.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)
            }
        } else if let job = vm.job, !job.state.isActive {
            // Finished / stopped / failed: offer to go again or clear.
            HStack(spacing: 8) {
                Button {
                    vm.start()
                } label: {
                    Label(job.state == .stopped ? "Resume / Start Clone" : "Start Clone",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canStart)

                Button {
                    vm.reset()
                } label: {
                    Label("Clear", systemImage: "xmark")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                vm.start()
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Clone")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canStart)
        }
    }
}
