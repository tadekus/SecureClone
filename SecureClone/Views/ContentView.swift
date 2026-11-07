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
        }
        .disabled(vm.isRunning)
    }

    private var startButton: some View {
        Button {
            vm.start()
        } label: {
            HStack {
                if vm.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…")
                } else {
                    Image(systemName: "play.fill")
                    Text("Start Clone")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!vm.canStart)
    }
}
