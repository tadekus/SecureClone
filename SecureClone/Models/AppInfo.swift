//
//  AppInfo.swift
//  SecureClone
//
//  Reads the version stamped into Info.plist by build-app.sh.
//

import Foundation

enum AppInfo {
    static let name = "SecureClone"

    /// Marketing version, e.g. "1.1" (from the VERSION file).
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// Build number, e.g. "17" (GitHub run number; "0" for a local build).
    static let build: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    /// "1.1 (17)"
    static var versionString: String { "\(version) (\(build))" }

    /// "SecureClone 1.1 (17)" — for logs and MHL creatorinfo.
    static var fullName: String { "\(name) \(versionString)" }
}
