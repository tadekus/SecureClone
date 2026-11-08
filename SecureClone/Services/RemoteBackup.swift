//
//  RemoteBackup.swift
//  SecureClone
//
//  Optional off-site copy after a verified offload, using the Mac's own
//  rsync over SSH (key-based, non-interactive). Runs in the background and
//  reports progress lines to the log; it never affects the local verdict.
//
//  Target format:  user@host:/path/on/server    (an rsync destination)
//

import Foundation

struct RemoteBackupResult {
    let ok: Bool
    let seconds: Double
    let lastLine: String
}

enum RemoteBackup {

    /// Non-interactive test that the target accepts our key.
    static func test(target: String, identity: String?) -> (Bool, String) {
        guard let host = target.split(separator: ":").first.map(String.init), !host.isEmpty else { return (false, "Target must look like user@host:/path") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if let id = identity, !id.isEmpty { args += ["-i", (id as NSString).expandingTildeInPath] }
        args += [host, "echo ok"]
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0 && text.hasSuffix("ok"), text.isEmpty ? "exit \(p.terminationStatus)" : text)
    }

    /// Copy `folder` to `<target>/<relative>/` with rsync. `onLine` gets
    /// progress / error lines as they arrive (already on a background thread).
    static func run(folder: URL, relative: String, target: String, identity: String?,
                    bandwidthKBps: Int = 0, control: CloneControl,
                    onLine: @escaping (String) -> Void) -> RemoteBackupResult {
        let start = Date()
        let dest = target.hasSuffix("/") ? target + relative : target + "/" + relative
        var ssh = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        if let id = identity, !id.isEmpty { ssh += " -i \"\((id as NSString).expandingTildeInPath)\"" }
        var args = ["-a", "--partial", "--info=progress2", "--no-inc-recursive", "--exclude", ".sc-partial",
                    "--exclude", ".DS_Store", "-e", ssh]
        if bandwidthKBps > 0 { args += ["--bwlimit=\(bandwidthKBps)"] }
        // Create the remote folder first (rsync alone won't make nested parents).
        let remoteDir = dest.split(separator: ":", maxSplits: 1).map(String.init).last ?? ""
        args += ["--rsync-path", "mkdir -p \"\(remoteDir)\" && rsync"]
        args += [folder.path.hasSuffix("/") ? folder.path : folder.path + "/", dest + "/"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        var last = ""
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for raw in s.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { last = line; onLine(line) }
            }
        }
        do { try p.run() } catch { return RemoteBackupResult(ok: false, seconds: 0, lastLine: error.localizedDescription) }
        while p.isRunning {
            if control.isCancelled { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        p.waitUntilExit()
        reader.readabilityHandler = nil
        return RemoteBackupResult(ok: p.terminationStatus == 0, seconds: Date().timeIntervalSince(start), lastLine: last)
    }
}
