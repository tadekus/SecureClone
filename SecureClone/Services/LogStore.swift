//
//  LogStore.swift
//  SecureClone
//
//  App-wide log: kept in memory (last 20 000 lines, searchable in the UI)
//  and appended to ~/Library/Application Support/SecureClone/logs/<date>.log
//  so nothing is lost when a job is cleared or the app restarts.
//

import Foundation

struct LogLine: Identifiable {
    let id: Int
    let time: Date
    let level: Level
    let text: String

    enum Level { case info, ok, warn, error }

    var timeString: String { LogFormat.time.string(from: time) }
}

/// Formatters kept outside the MainActor class so LogLine can use them anywhere.
enum LogFormat {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let full: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    static let day: DateFormatter  = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
}

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    private var nextID = 0
    private let maxLines = 20_000
    private var fileHandle: FileHandle?
    private var fileDay: String = ""

    static var directory: URL {
        let d = HistoryStore.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func log(_ text: String, level: LogLine.Level = .info) {
        let line = LogLine(id: nextID, time: Date(), level: level, text: text)
        nextID += 1
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        appendToFile(line)
    }

    func clear() { lines.removeAll() }

    /// Full text for export / clipboard.
    func export(filter: String = "") -> String {
        filtered(filter).map { "\(LogFormat.full.string(from: $0.time))  \($0.text)" }.joined(separator: "\n") + "\n"
    }

    func filtered(_ query: String) -> [LogLine] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - File

    private func appendToFile(_ line: LogLine) {
        let day = LogFormat.day.string(from: line.time)
        if day != fileDay || fileHandle == nil {
            try? fileHandle?.close()
            let url = Self.directory.appendingPathComponent("\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
            fileDay = day
        }
        let s = "\(LogFormat.full.string(from: line.time))  \(line.text)\n"
        if let d = s.data(using: .utf8) { try? fileHandle?.write(contentsOf: d) }
    }
}
