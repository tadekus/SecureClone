//
//  JSONReportWriter.swift
//  SecureClone
//
//  Machine-readable job report: everything the text report says, plus
//  per-file hashes, verification results and clip metadata, for pipelines
//  that ingest offload evidence automatically.
//

import Foundation

struct JSONReport: Codable {
    struct Destination: Codable {
        let volume: String
        let folder: String
        let files: Int
        let bytes: Int64
        let verified: Bool
    }
    struct File: Codable {
        let path: String
        let size: Int64
        let modified: Date?
        let sourceHash: String
        let sourceHashMD5: String?
        let destinationHashes: [String: String]     // folder -> hash
        let verified: [String: Bool]
        let byteCompare: [String: Bool]?
        let sourceRereadOK: Bool?
        let copyStarted: Date?
        let copySeconds: Double
        let copyMBps: Double
        let skipped: Bool
        let metadata: Clip?
    }
    struct Clip: Codable {
        let name: String
        let durationSeconds: Double?
        let fps: String?
        let exposureIndex: String?
        let ndFilter: String?
        let shutterAngle: String?
        let tcStart: String?
        let tcEnd: String?
        let lut: String?
        let codec: String?
        let resolution: String?
    }

    let schema = "secureclone-report/1"
    let tool: String
    let job: String
    let mode: String
    let algorithm: String
    let started: Date
    let finished: Date
    let host: String
    let user: String
    let source: String
    let sourceVolume: String
    let destinations: [Destination]
    let totalFiles: Int
    let totalBytes: Int64
    let skippedFiles: Int
    let verified: Bool
    let files: [File]
}

enum JSONReportWriter {

    static func make(jobName: String, source: VolumeInfo, sourceFolder: URL?,
                     destinations: [VolumeInfo], destinationFolders: [URL],
                     outcomes: [FileCloneOutcome], metadata: [ClipMetadata],
                     algorithm: HashAlgorithm, mode: VerificationMode,
                     startDate: Date, finishDate: Date, skipped: Int, verified: Bool) -> JSONReport {
        let byPath = Dictionary(uniqueKeysWithValues: metadata.map { ($0.relativePath, $0) })
        var dests: [JSONReport.Destination] = []
        for (i, d) in destinations.enumerated() {
            let folder = i < destinationFolders.count ? destinationFolders[i] : d.url
            let rows = outcomes.compactMap { $0.verified[folder] }
            dests.append(.init(volume: d.name, folder: folder.path, files: rows.count,
                               bytes: outcomes.filter { $0.verified[folder] != nil }.reduce(0) { $0 + $1.size },
                               verified: !rows.isEmpty && rows.allSatisfy { $0 }))
        }
        let files: [JSONReport.File] = outcomes.map { o in
            var dh: [String: String] = [:], vf: [String: Bool] = [:], bc: [String: Bool] = [:]
            for (k, v) in o.destinationHashes { dh[k.path] = v }
            for (k, v) in o.verified { vf[k.path] = v }
            for (k, v) in o.byteCompareOK { bc[k.path] = v }
            let m = byPath[o.relativePath]
            return .init(path: o.relativePath, size: o.size, modified: o.modificationDate,
                         sourceHash: o.sourceHash, sourceHashMD5: o.sourceHashMD5,
                         destinationHashes: dh, verified: vf,
                         byteCompare: o.mode.byteCompare ? bc : nil,
                         sourceRereadOK: o.sourceRereadOK,
                         copyStarted: o.copyStartedAt, copySeconds: o.copySeconds, copyMBps: o.copyMBps,
                         skipped: o.copySeconds == 0,
                         metadata: m.map { .init(name: $0.name, durationSeconds: $0.durationSeconds, fps: $0.fps,
                                                 exposureIndex: $0.exposureIndex, ndFilter: $0.ndFilter,
                                                 shutterAngle: $0.shutterAngle, tcStart: $0.tcStart, tcEnd: $0.tcEnd,
                                                 lut: $0.lutNodes, codec: $0.codec, resolution: $0.resolution) })
        }
        return JSONReport(tool: AppInfo.fullName, job: jobName, mode: mode.rawValue, algorithm: algorithm.rawValue,
                          started: startDate, finished: finishDate,
                          host: Host.current().localizedName ?? "unknown", user: NSUserName(),
                          source: (sourceFolder ?? source.url).path, sourceVolume: source.name,
                          destinations: dests, totalFiles: outcomes.count,
                          totalBytes: outcomes.reduce(0) { $0 + $1.size }, skippedFiles: skipped,
                          verified: verified, files: files)
    }

    @discardableResult
    static func write(_ report: JSONReport, to root: URL, jobName: String, finishDate: Date) throws -> URL {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(report)
        let dir = root.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ReportNaming.base(jobName: jobName, date: finishDate)).json")
        try data.write(to: url)
        return url
    }
}
