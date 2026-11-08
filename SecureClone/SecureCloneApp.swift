//
//  SecureCloneApp.swift
//  SecureClone
//
//  Secure media offload tool for the film industry.
//  Read source once → fan out to multiple drives → verify → MHL / CSV / logs.
//

import SwiftUI
import AppKit

@main
struct SecureCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var log: LogStore
    @StateObject private var vm: CloneViewModel
    @StateObject private var speed: SpeedTestViewModel
    @StateObject private var monitor = DriveMonitor()

    init() {
        let settings = AppSettings()
        let log = LogStore()
        _settings = StateObject(wrappedValue: settings)
        _log = StateObject(wrappedValue: log)
        _vm = StateObject(wrappedValue: CloneViewModel(settings: settings, log: log))
        _speed = StateObject(wrappedValue: SpeedTestViewModel(log: log))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(vm)
                .environmentObject(speed)
                .environmentObject(monitor)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    AppDelegate.isBusy = { [weak vm, weak speed] in (vm?.isRunning ?? false) || (speed?.isRunning ?? false) }
                    AppDelegate.keepRunning = { [weak settings] in settings?.showInMenuBar ?? true }
                    // Start monitoring after the first layout pass, never from
                    // inside a view update (publishing there can thrash SwiftUI).
                    DispatchQueue.main.async {
                        monitor.start()
                        vm.attach(monitor: monitor)
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuBarMenu()
                .environmentObject(vm)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environmentObject(vm)
        }
    }
}

/// Keeps the app alive in the menu bar when the window closes, and
/// confirms before quitting during a job.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isBusy: @MainActor () -> Bool = { false }
    static var keepRunning: @MainActor () -> Bool = { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.keepRunning()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.isBusy() else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A job is still running"
        a.informativeText = "Quitting now will stop the copy. Progress is saved and can be resumed, but no report will be written for this card."
        a.addButton(withTitle: "Keep Running")
        a.addButton(withTitle: "Quit Anyway")
        a.alertStyle = .warning
        return a.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    @EnvironmentObject var vm: CloneViewModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            if let j = vm.job, vm.isRunning, j.state != .scanning {
                Text(j.percentText).monospacedDigit()
            } else if !vm.queue.isEmpty {
                Text("\(vm.queue.count)")
            }
        }
    }
    private var icon: String {
        guard let j = vm.job else { return "externaldrive.badge.checkmark" }
        switch j.state {
        case .copying, .scanning: return "arrow.down.circle"
        case .verifying:          return "checkmark.circle"
        case .paused:             return "pause.circle"
        case .completed:          return "checkmark.seal.fill"
        case .failed:             return "xmark.seal.fill"
        default:                  return "externaldrive.badge.checkmark"
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var vm: CloneViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let j = vm.job {
            Text("\(j.title): \(j.state.label)")
            if vm.isRunning {
                Text("\(j.percentText) · \(j.speedText) · ETA \(j.etaText)")
            }
            Divider()
            if vm.isRunning {
                Button(vm.isPaused ? "Resume" : "Pause") { if vm.isPaused { vm.resume() } else { vm.pause() } }
                Button("Stop") { vm.stop() }
            }
        } else {
            Text("Idle")
        }
        if !vm.queue.isEmpty {
            Divider()
            Text("Queued: \(vm.queue.map { $0.jobName }.joined(separator: ", "))")
        }
        Divider()
        Toggle("Auto-start on card insert", isOn: $settings.autoStart)
        Toggle("Eject card when verified", isOn: $settings.autoEject)
        Divider()
        Button("Open SecureClone") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
