//
//  HistoryStore.swift
//  SecureClone
//
//  Local record of every completed job, kept in
//  ~/Library/Application Support/SecureClone/history.json.
//  Powers the duplicate-card guard and the shooting-day summary.
//

import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var jobName: String
    var reel: String
    var camera: String?
    var system: String
    var sourceName: String
    var sourceCapacity: Int64
    var fileCount: Int
    var totalBytes: Int64
    var destinations: [String]          // volume names
    var destinationFolders: [String]    // full paths written to
    var verified: Bool
    var durationSeconds: Double
    var appVersion: String
    /// Cheap card fingerprint for the duplicate guard: newest media mtime.
    var newestFileDate: Date?
}

enum HistoryStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SecureClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var fileURL: URL { directory.appendingPathComponent("history.json") }

    static func load() -> [HistoryEntry] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: d)) ?? []
    }

    static func append(_ e: HistoryEntry) {
        var all = load()
        all.append(e)
        if all.count > 5000 { all.removeFirst(all.count - 5000) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(all) { try? d.write(to: fileURL, options: .atomic) }
    }

    /// Entries from the same calendar day as `date`.
    static func entries(onDayOf date: Date) -> [HistoryEntry] {
        let cal = Calendar.current
        return load().filter { cal.isDate($0.date, inSameDayAs: date) }
    }

    // MARK: - Duplicate-card guard

    /// A previous verified offload that looks like the same card: same reel,
    /// same file count and total size (and same newest file date when known).
    static func findDuplicate(reel: String, fileCount: Int, totalBytes: Int64,
                              newestFileDate: Date?, withinDays: Int = 7) -> HistoryEntry? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -withinDays, to: Date()) ?? .distantPast
        return load().reversed().first { e in
            e.verified && e.date >= cutoff &&
            e.reel.caseInsensitiveCompare(reel) == .orderedSame &&
            e.fileCount == fileCount && e.totalBytes == totalBytes &&
            (newestFileDate == nil || e.newestFileDate == nil ||
             abs(e.newestFileDate!.timeIntervalSince(newestFileDate!)) < 2)
        }
    }
}
