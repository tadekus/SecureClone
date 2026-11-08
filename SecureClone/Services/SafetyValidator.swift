//
//  SafetyValidator.swift
//  SecureClone
//
//  Pre-flight checks that refuse a job which could never be a real backup:
//    • a destination on the same physical disk as the source
//    • two destinations on the same physical disk ("two backups" that die together)
//    • source nested inside a destination, or a destination inside the source
//    • symlinks anywhere in the source or destination paths
//    • online-only (dataless) files on the source (iCloud, Dropbox, OneDrive)
//  Returns problems as text; the view model shows them and does not start.
//

import Foundation
import Darwin

struct SafetyProblem: Identifiable {
    enum Severity { case refuse, warn }
    let id = UUID()
    let severity: Severity
    let message: String
}

enum SafetyValidator {

    static func check(source: VolumeInfo, sourceFolder: URL?,
                      destinations: [VolumeInfo], destinationFolders: [URL],
                      files: [ScannedFile],
                      allowSamePhysicalDisk: Bool) -> [SafetyProblem] {
        var out: [SafetyProblem] = []
        let src = (sourceFolder ?? source.url).standardizedFileURL

        // Nesting.
        for d in destinationFolders {
            let dst = d.standardizedFileURL
            if isSame(dst, src) || isInside(dst, src) {
                out.append(.init(severity: .refuse, message: "Destination \(short(dst)) is inside the source — that is not a backup."))
            } else if isInside(src, dst) {
                out.append(.init(severity: .refuse, message: "Source \(short(src)) is inside destination \(short(dst))."))
            }
        }

        // Symlinks in paths.
        for u in [src] + destinationFolders.map { $0.standardizedFileURL } {
            if let comp = firstSymlinkComponent(in: u) {
                out.append(.init(severity: .refuse, message: "\(short(u)) goes through a symbolic link (\(comp)); refusing to follow it."))
            }
        }

        // Physical disks.
        let srcDisks = DriveConnectionInfo.physicalDisks(for: source.url)
        var seen: [String: VolumeInfo] = [:]
        for d in destinations {
            let disks = DriveConnectionInfo.physicalDisks(for: d.url)
            if !disks.isEmpty, !srcDisks.isDisjoint(with: disks) {
                out.append(.init(severity: .refuse, message: "\(d.name) is on the same physical disk as the source \(source.name)."))
            }
            for disk in disks {
                if let other = seen[disk], other != d {
                    out.append(.init(severity: allowSamePhysicalDisk ? .warn : .refuse,
                                     message: "\(d.name) and \(other.name) are volumes of the same physical disk (\(disk)) — one failure would take both backups."
                                        + (allowSamePhysicalDisk ? "" : " Enable “Allow backups on the same disk” to override.")))
                } else {
                    seen[disk] = d
                }
            }
        }

        // Online-only files.
        let dataless = files.filter { $0.isDataless }
        if !dataless.isEmpty {
            let total = dataless.reduce(Int64(0)) { $0 + $1.size }
            out.append(.init(severity: .refuse,
                             message: "\(dataless.count) file\(dataless.count == 1 ? " is" : "s are") online-only (iCloud / Dropbox placeholders, \(VolumeInfo.format(total))). Download them first; a placeholder copy is not a backup."))
        }
        return out
    }

    // MARK: - Helpers

    private static func isSame(_ a: URL, _ b: URL) -> Bool { a.path == b.path }
    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let p = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path.hasPrefix(p)
    }
    private static func short(_ u: URL) -> String {
        u.path.replacingOccurrences(of: "/Volumes/", with: "")
    }

    /// Name of the first path component that is a symlink, or nil.
    static func firstSymlinkComponent(in url: URL) -> String? {
        var path = ""
        for comp in url.pathComponents where comp != "/" {
            path += "/" + comp
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                // Mount points themselves ("/Volumes/Name") may be links on some
                // systems; anything deeper that is a link is user-made.
                let parts = path.split(separator: "/")
                if parts.count <= 2 && parts.first == "Volumes" { continue }
                return comp
            }
        }
        return nil
    }
}
