//
//  SourceScanner.swift
//  SecureClone
//
//  Recursively walks a source volume, collecting real media files and
//  skipping macOS/system cruft that shouldn't be copied or hashed.
//

import Foundation

struct ScannedFile: Sendable {
    let url: URL            // absolute source URL
    let relativePath: String // path relative to source root
    let size: Int64
    let modificationDate: Date?
}

enum SourceScanner {

    /// File / directory names to skip entirely.
    private static let skipNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".DS_Store", ".apdisk",
        SessionStore.folderName          // our own reports, if saved to the source
    ]

    /// Returns all copyable files under `root`, with paths relative to it.
    static func scan(root: URL) throws -> [ScannedFile] {
        var results: [ScannedFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                      .fileSizeKey, .contentModificationDateKey,
                                      .isHiddenKey]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],   // we filter manually so we can prune system dirs
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path

        for case let url as URL in enumerator {
            let name = url.lastPathComponent

            // Skip resource-fork sidecars (._Foo) and known system entries.
            if name.hasPrefix("._") || skipNames.contains(name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let vals = try url.resourceValues(forKeys: Set(keys))
            guard vals.isRegularFile == true else { continue }

            let absPath = url.standardizedFileURL.path
            var rel = absPath
            if absPath.hasPrefix(rootPath) {
                rel = String(absPath.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
            }

            results.append(ScannedFile(
                url: url,
                relativePath: rel,
                size: Int64(vals.fileSize ?? 0),
                modificationDate: vals.contentModificationDate
            ))
        }

        return results.sorted { $0.relativePath < $1.relativePath }
    }

    static func totalBytes(_ files: [ScannedFile]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}
