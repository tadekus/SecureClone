//
//  ActiveRunStore.swift
//  SecureClone
//
//  Crash evidence. While a job runs, a small JSON in Application Support
//  records exactly where it is: phase, files copied, files verified, the
//  file in flight. It is removed when the job ends normally. If it is still
//  there at the next launch, the previous run died (crash, force-quit,
//  power loss) and the app reports precisely what had been verified.
//

import Foundation

struct ActiveRun: Codable {
    var jobName: String
    var sourceName: String
    var sourceCapacity: Int64
    var destinations: [String]
    var destinationFolders: [String]
    var mode: String
    var startedAt: Date
    var phase: String                 // scanning / copying / verifying / reporting
    var totalFiles: Int
    var copiedFiles: Int
    var verifiedFiles: Int
    var currentFile: String
    var updatedAt: Date
    var appVersion: String
    var pid: Int32
}

enum ActiveRunStore {
    private static var url: URL { HistoryStore.directory.appendingPathComponent("active_run.json") }

    static func write(_ r: ActiveRun) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(r) { try? d.write(to: url, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    /// A run left behind by a previous process, if any.
    static func takeLeftover() -> ActiveRun? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let r = try? dec.decode(ActiveRun.self, from: d) else { clear(); return nil }
        // Still-running process with that pid? Then it's not a leftover.
        if r.pid != ProcessInfo.processInfo.processIdentifier, kill(r.pid, 0) == 0 { return nil }
        clear()
        return r
    }
}
