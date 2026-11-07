//
//  JobSpec.swift
//  SecureClone
//
//  Everything needed to run (or queue) one offload: where from, where to,
//  and how the destination folder is named. The naming template turns
//  `{project}/{day}/{camera}/{reel}` into `MYFILM/DAY_03/A/A_0071`.
//

import Foundation

struct NamingFields: Codable, Equatable {
    var project: String = ""
    var day: String = ""            // "DAY_03"
    var camera: String = ""         // "A"
    var reel: String = ""           // "A_0071"
    var template: String = "{project}/{day}/{camera}/{reel}"

    static let tokens = ["{project}", "{day}", "{camera}", "{reel}", "{date}", "{job}", "{card}"]

    /// Rendered relative path for the destination folder. Empty segments are
    /// dropped so an unset {project} doesn't create an empty folder level.
    func render(jobName: String, cardName: String, date: Date = Date()) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        var s = template
        let map: [String: String] = [
            "{project}": project, "{day}": day, "{camera}": camera, "{reel}": reel,
            "{date}": df.string(from: date), "{job}": jobName, "{card}": cardName
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: Self.clean(v)) }
        return s.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
         .replacingOccurrences(of: "/", with: "-")
         .replacingOccurrences(of: ":", with: "-")
    }
}

/// A job waiting in the queue (or the one running).
struct JobSpec: Identifiable, Equatable {
    let id = UUID()
    var source: VolumeInfo
    var destinations: [VolumeInfo]
    var jobName: String
    var naming: NamingFields
    var algorithm: HashAlgorithm
    var reelInfo: ReelInfo?
    var addedAt = Date()
    var autoAdded = false           // came from auto-start on mount

    /// Copy only this folder of the card (nil = whole card).
    var sourceFolder: URL? = nil
    /// Per-destination base folder chosen by the user (volume URL → folder).
    /// The naming template is appended underneath. nil = drive root.
    var destinationBases: [URL: URL] = [:]

    /// What is actually read: the chosen subfolder or the whole volume.
    var sourceRoot: URL { sourceFolder ?? source.url }

    /// Destination subfolder, e.g. "MYFILM/DAY_03/A/A_0071". May be empty
    /// (template rendered to nothing) → copy to the base folder itself.
    var relativeFolder: String {
        naming.render(jobName: jobName, cardName: source.name)
    }

    func destinationRoot(for volume: VolumeInfo) -> URL {
        let base = destinationBases[volume.url] ?? volume.url
        let rel = relativeFolder
        return rel.isEmpty ? base : base.appendingPathComponent(rel, isDirectory: true)
    }

    static func == (l: JobSpec, r: JobSpec) -> Bool { l.id == r.id }
}
