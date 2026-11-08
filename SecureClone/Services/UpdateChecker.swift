//
//  UpdateChecker.swift
//  SecureClone
//
//  Checks GitHub Releases for a newer version. CI publishes a release for
//  every successful build on main, so "latest" is always the newest build.
//

import Foundation

struct UpdateInfo {
    let version: String      // "2.8"
    let build: String        // "31"
    let url: URL             // release page
    let assetURL: URL?       // the .zip
}

enum UpdateChecker {
    static let repo = "tadekus/SecureClone"

    static func check() async -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init) else { return nil }
        // tag: v2.8-build31
        let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = body.split(separator: "-", maxSplits: 1).map(String.init)
        let version = parts.first ?? body
        let build = parts.count > 1 ? parts[1].replacingOccurrences(of: "build", with: "") : "0"
        var asset: URL? = nil
        if let assets = json["assets"] as? [[String: Any]] {
            asset = assets.compactMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
                          .first { $0.pathExtension == "zip" }
        }
        return UpdateInfo(version: version, build: build, url: page, assetURL: asset)
    }

    /// True when `remote` is newer than the running app (version, then build).
    static func isNewer(_ remote: UpdateInfo) -> Bool {
        let cur = AppInfo.version.split(separator: ".").compactMap { Int($0) }
        let rem = remote.version.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(cur.count, rem.count) {
            let a = i < cur.count ? cur[i] : 0, b = i < rem.count ? rem[i] : 0
            if a != b { return b > a }
        }
        return (Int(remote.build) ?? 0) > (Int(AppInfo.build) ?? 0)
    }
}
