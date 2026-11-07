//
//  SessionStore.swift
//  SecureClone
//
//  Persists job progress so a stopped job can be resumed later. The session
//  file lives in SecureClone_Logs/ on EVERY destination drive (so it
//  survives any single drive being unplugged), and is deleted on success.
//
//  A resume trusts a file only if (a) the session lists it as fully copied
//  with its source hash, and (b) the file still exists on the destination
//  with the right size. Every resumed file is still re-verified from disk
//  in the verify phase — resuming never skips verification.
//

import Foundation

struct SessionRecord: Codable, Sendable {
    let relativePath: String
    let size: Int64
    let modificationDate: Date?
    let sourceHash: String
}

struct CloneSession: Codable, Sendable {
    var jobName: String
    var sourceVolumeName: String
    var sourceTotalCapacity: Int64          // extra identity check for the card
    var destinationPaths: [String]
    var algorithm: String
    var startedAt: Date
    var totalFiles: Int
    var totalBytes: Int64
    var completed: [SessionRecord]
    var updatedAt: Date

    var completedBytes: Int64 { completed.reduce(0) { $0 + $1.size } }
}

enum SessionStore {

    static let folderName = "SecureClone_Logs"

    private static func fileName(jobName: String) -> String {
        let safe = jobName.replacingOccurrences(of: "/", with: "-")
        return ".session_\(safe).json"           // dot-prefixed: hidden in Finder
    }

    static func url(destinationRoot: URL, jobName: String) -> URL {
        destinationRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName(jobName: jobName))
    }

    /// Write the session to every destination.
    static func save(_ session: CloneSession, destinationRoots: [URL]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(session) else { return }
        for root in destinationRoots {
            let u = url(destinationRoot: root, jobName: session.jobName)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: u, options: .atomic)
        }
    }

    /// Look for a resumable session for this exact source + destinations + job.
    /// Returns the most recently updated one found on any destination.
    static func find(jobName: String,
                     source: VolumeInfo,
                     destinationRoots: [URL]) -> CloneSession? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var best: CloneSession? = nil
        for root in destinationRoots {
            let u = url(destinationRoot: root, jobName: jobName)
            guard let data = try? Data(contentsOf: u),
                  let s = try? dec.decode(CloneSession.self, from: data) else { continue }
            guard s.sourceVolumeName == source.name,
                  s.sourceTotalCapacity == source.totalCapacity,
                  Set(s.destinationPaths) == Set(destinationRoots.map { $0.path })
            else { continue }
            if best == nil || s.updatedAt > best!.updatedAt { best = s }
        }
        return best
    }

    static func delete(jobName: String, destinationRoots: [URL]) {
        for root in destinationRoots {
            try? FileManager.default.removeItem(at: url(destinationRoot: root, jobName: jobName))
        }
    }

    /// Which completed records can actually be trusted on disk right now.
    static func validRecords(_ session: CloneSession,
                             destinationRoots: [URL]) -> [SessionRecord] {
        session.completed.filter { rec in
            destinationRoots.allSatisfy { root in
                let f = root.appendingPathComponent(rec.relativePath)
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                return size == rec.size
            }
        }
    }
}
