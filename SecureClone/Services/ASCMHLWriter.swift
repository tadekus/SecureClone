//
//  ASCMHLWriter.swift
//  SecureClone
//
//  ASC MHL (the current ASC Media Hash List standard, successor to the
//  classic MHL 1.x we also write): an `ascmhl/` folder at the root of the
//  copied tree holding one numbered generation file per verified job and an
//  `ascmhl_chain.txt` that hashes the generation files themselves, so later
//  tools can prove the history is unbroken.
//
//  Scope: file hashes with xxh64/md5/sha256, process info, chain. Directory
//  (root) hashes are not emitted.
//

import Foundation

enum ASCMHLWriter {

    static let folderName = "ascmhl"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Write the next generation for `root` (the folder the paths are relative to).
    @discardableResult
    static func write(root: URL, outcomes: [FileCloneOutcome], algorithm: HashAlgorithm,
                      startDate: Date, finishDate: Date, jobName: String) throws -> URL {
        let dir = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Generation number = existing .mhl files + 1.
        let existing = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mhl" }
        let gen = existing.count + 1
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let safeJob = jobName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let fileName = String(format: "%04d", gen) + "_\(safeJob)_\(stamp.string(from: finishDate)).mhl"
        let url = dir.appendingPathComponent(fileName)

        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(iso.string(from: finishDate))</creationdate>
            <hostname>\(esc(Host.current().localizedName ?? "unknown"))</hostname>
            <tool version="\(esc(AppInfo.versionString))">\(esc(AppInfo.name))</tool>
            <author name="\(esc(NSUserName()))" role="DIT"/>
          </creatorinfo>
          <processinfo>
            <process>transfer</process>
            <ignore>
              <pattern>.DS_Store</pattern>
              <pattern>ascmhl</pattern>
              <pattern>\(SessionStore.folderName)</pattern>
              <pattern>.Spotlight-V100</pattern>
              <pattern>.fseventsd</pattern>
            </ignore>
          </processinfo>
          <hashes>

        """
        let hashDate = iso.string(from: finishDate)
        for o in outcomes.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard let h = o.destinationHashes[root], !h.isEmpty else { continue }
            let mod = o.modificationDate.map { iso.string(from: $0) } ?? hashDate
            x += "    <hash>\n"
            x += "      <path size=\"\(o.size)\" lastmodificationdate=\"\(mod)\">\(esc(o.relativePath))</path>\n"
            x += "      <\(algorithm.mhlElement) action=\"original\" hashdate=\"\(hashDate)\">\(h)</\(algorithm.mhlElement)>\n"
            if let m = o.destinationMD5[root], algorithm != .md5 {
                x += "      <md5 action=\"original\" hashdate=\"\(hashDate)\">\(m)</md5>\n"
            }
            x += "    </hash>\n"
        }
        x += "  </hashes>\n</hashlist>\n"
        let data = x.data(using: .utf8)!
        try data.write(to: url, options: .atomic)

        // Chain: hash of the generation file, appended.
        var chainHasher = XXH64()
        chainHasher.update(data)
        let line = "xxh64: \(chainHasher.hexDigest()) \(fileName)\n"
        let chain = dir.appendingPathComponent("ascmhl_chain.txt")
        if let h = try? FileHandle(forWritingTo: chain) {
            try h.seekToEnd(); try h.write(contentsOf: line.data(using: .utf8)!); try h.close()
        } else {
            try line.data(using: .utf8)!.write(to: chain)
        }
        return url
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
