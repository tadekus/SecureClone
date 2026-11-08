//
//  AppSettings.swift
//  SecureClone
//
//  User preferences, persisted in UserDefaults.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var project: String          { didSet { save() } }
    @Published var day: String              { didSet { save() } }
    @Published var template: String         { didSet { save() } }
    @Published var autoStart: Bool          { didSet { save() } }
    @Published var autoEject: Bool          { didSet { save() } }
    @Published var skipIdentical: Bool      { didSet { save() } }
    @Published var saveReportToSource: Bool { didSet { save() } }
    @Published var showInMenuBar: Bool      { didSet { save() } }
    @Published var preventSleep: Bool       { didSet { save() } }
    @Published var algorithm: HashAlgorithm { didSet { save() } }
    @Published var verificationMode: VerificationMode { didSet { save() } }
    @Published var copyAppleDouble: Bool    { didSet { save() } }
    @Published var allowSamePhysicalDisk: Bool { didSet { save() } }
    @Published var writePDF: Bool           { didSet { save() } }
    @Published var writeJSON: Bool          { didSet { save() } }
    @Published var writeASCMHL: Bool        { didSet { save() } }
    @Published var notifications: Bool      { didSet { save() } }
    @Published var checkUpdates: Bool       { didSet { save() } }
    @Published var remoteEnabled: Bool      { didSet { save() } }
    @Published var remoteTarget: String     { didSet { save() } }
    @Published var remoteIdentity: String   { didSet { save() } }
    @Published var remoteBandwidthKBps: Int { didSet { save() } }
    @Published var lastUpdateCheck: Date?   { didSet { save() } }
    /// Last-used destination volume paths, so a new card can auto-start.
    @Published var rememberedDestinations: [String] { didSet { save() } }

    private let d = UserDefaults.standard
    private var loading = true

    init() {
        project = d.string(forKey: "project") ?? ""
        day = d.string(forKey: "day") ?? ""
        template = d.string(forKey: "template") ?? "{project}/{day}/{camera}/{reel}"
        autoStart = d.bool(forKey: "autoStart")
        autoEject = d.bool(forKey: "autoEject")
        skipIdentical = d.object(forKey: "skipIdentical") as? Bool ?? true
        saveReportToSource = d.object(forKey: "saveReportToSource") as? Bool ?? true
        showInMenuBar = d.object(forKey: "showInMenuBar") as? Bool ?? true
        preventSleep = d.object(forKey: "preventSleep") as? Bool ?? true
        algorithm = HashAlgorithm(rawValue: d.string(forKey: "algorithm") ?? "") ?? .xxh64
        verificationMode = VerificationMode(rawValue: d.string(forKey: "verificationMode") ?? "") ?? .standard
        copyAppleDouble = d.bool(forKey: "copyAppleDouble")
        allowSamePhysicalDisk = d.bool(forKey: "allowSamePhysicalDisk")
        writePDF = d.object(forKey: "writePDF") as? Bool ?? true
        writeJSON = d.object(forKey: "writeJSON") as? Bool ?? true
        writeASCMHL = d.object(forKey: "writeASCMHL") as? Bool ?? true
        notifications = d.object(forKey: "notifications") as? Bool ?? true
        checkUpdates = d.object(forKey: "checkUpdates") as? Bool ?? true
        remoteEnabled = d.bool(forKey: "remoteEnabled")
        remoteTarget = d.string(forKey: "remoteTarget") ?? ""
        remoteIdentity = d.string(forKey: "remoteIdentity") ?? ""
        remoteBandwidthKBps = d.integer(forKey: "remoteBandwidthKBps")
        lastUpdateCheck = d.object(forKey: "lastUpdateCheck") as? Date
        rememberedDestinations = d.stringArray(forKey: "rememberedDestinations") ?? []
        loading = false
    }

    private func save() {
        guard !loading else { return }
        // Coalesce: many setters can fire in one runloop turn.
        pendingSave = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingSave else { return }
            self.pendingSave = false
            self.flush()
        }
    }

    private var pendingSave = false

    private func flush() {
        d.set(project, forKey: "project")
        d.set(day, forKey: "day")
        d.set(template, forKey: "template")
        d.set(autoStart, forKey: "autoStart")
        d.set(autoEject, forKey: "autoEject")
        d.set(skipIdentical, forKey: "skipIdentical")
        d.set(saveReportToSource, forKey: "saveReportToSource")
        d.set(showInMenuBar, forKey: "showInMenuBar")
        d.set(preventSleep, forKey: "preventSleep")
        d.set(algorithm.rawValue, forKey: "algorithm")
        d.set(verificationMode.rawValue, forKey: "verificationMode")
        d.set(copyAppleDouble, forKey: "copyAppleDouble")
        d.set(allowSamePhysicalDisk, forKey: "allowSamePhysicalDisk")
        d.set(writePDF, forKey: "writePDF"); d.set(writeJSON, forKey: "writeJSON"); d.set(writeASCMHL, forKey: "writeASCMHL")
        d.set(notifications, forKey: "notifications"); d.set(checkUpdates, forKey: "checkUpdates")
        d.set(remoteEnabled, forKey: "remoteEnabled"); d.set(remoteTarget, forKey: "remoteTarget")
        d.set(remoteIdentity, forKey: "remoteIdentity"); d.set(remoteBandwidthKBps, forKey: "remoteBandwidthKBps")
        d.set(lastUpdateCheck, forKey: "lastUpdateCheck")
        d.set(rememberedDestinations, forKey: "rememberedDestinations")
    }
}
