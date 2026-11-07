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
        rememberedDestinations = d.stringArray(forKey: "rememberedDestinations") ?? []
        loading = false
    }

    private func save() {
        guard !loading else { return }
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
        d.set(rememberedDestinations, forKey: "rememberedDestinations")
    }
}
