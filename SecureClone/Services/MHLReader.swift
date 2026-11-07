//
//  MHLReader.swift
//  SecureClone
//
//  Reads MHL v1.x manifests (ours and other tools') back in, for
//  verify-only mode and for "skip files already verified here".
//

import Foundation

struct MHLEntry {
    let file: String            // relative path as written in the MHL
    let size: Int64?
    let hashes: [String: String]   // "xxhash64" -> hex, "md5" -> hex, …

    func hash(for algorithm: HashAlgorithm) -> String? {
        hashes[algorithm.mhlElement]
    }
}

struct MHLDocument {
    let url: URL
    let entries: [MHLEntry]
    let tool: String?
    let finishDate: String?
    /// Folder the file paths are relative to (the MHL's parent, or its
    /// parent's parent when the MHL sits in a SecureClone_Logs folder).
    var baseFolder: URL {
        let parent = url.deletingLastPathComponent()
        return parent.lastPathComponent == SessionStore.folderName
            ? parent.deletingLastPathComponent() : parent
    }
    var totalBytes: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }
}

enum MHLReader {

    static func read(_ url: URL) -> MHLDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let p = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        guard xml.parse() || !p.entries.isEmpty else { return nil }
        return MHLDocument(url: url, entries: p.entries, tool: p.tool, finishDate: p.finishDate)
    }

    /// Every .mhl found under `root` (SecureClone_Logs folders and loose files),
    /// newest first. Depth-limited so a 4 TB drive scan stays quick.
    static func findMHLs(under root: URL, maxDepth: Int = 5) -> [URL] {
        var found: [(URL, Date)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        for case let u as URL in en {
            let depth = u.standardizedFileURL.pathComponents.count - rootDepth
            if depth > maxDepth { en.skipDescendants(); continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                let n = u.lastPathComponent
                if n == ".Spotlight-V100" || n == ".fseventsd" || n == ".Trashes" { en.skipDescendants() }
                continue
            }
            if u.pathExtension.lowercased() == "mhl" {
                found.append((u, v?.contentModificationDate ?? .distantPast))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Index of hashes for files under `folder`, from any MHLs found there:
    /// relativePath -> (size, hash) for the given algorithm.
    static func knownHashes(in folder: URL, algorithm: HashAlgorithm) -> [String: (Int64?, String)] {
        var out: [String: (Int64?, String)] = [:]
        let logs = folder.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mhl" }
        for u in candidates {
            guard let doc = read(u) else { continue }
            for e in doc.entries {
                if let h = e.hash(for: algorithm) { out[e.file] = (e.size, h) }
            }
        }
        return out
    }

    // MARK: - XML parsing

    private final class Parser: NSObject, XMLParserDelegate {
        var entries: [MHLEntry] = []
        var tool: String?
        var finishDate: String?

        private var path: [String] = []
        private var text = ""
        private var cur: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name.lowercased())
            text = ""
            if name.lowercased() == "hash" { cur = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let n = name.lowercased()
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.count >= 2, path[path.count - 2] == "hash" {
                cur[n] = t
            } else if path.count >= 2, path[path.count - 2] == "creatorinfo" {
                if n == "tool" { tool = t }
                if n == "finishdate" { finishDate = t }
            }
            if n == "hash" {
                var hashes: [String: String] = [:]
                for k in ["xxhash64", "xxhash64be", "md5", "sha1", "sha256", "xxhash3", "xxhash128", "c4"] {
                    if let v = cur[k], !v.isEmpty { hashes[k == "xxhash64be" ? "xxhash64" : k] = v.lowercased() }
                }
                if let f = cur["file"], !f.isEmpty {
                    entries.append(MHLEntry(file: f, size: cur["size"].flatMap { Int64($0) }, hashes: hashes))
                }
            }
            path.removeLast()
            text = ""
        }
    }
}
