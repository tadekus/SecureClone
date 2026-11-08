// swift-tools-version:5.9
//
// SecureClone as a Swift Package — builds with `swift build`, no Xcode
// project file needed. The GitHub Actions workflow and build-app.sh wrap
// the resulting binary into a proper SecureClone.app bundle.
//

import PackageDescription

let package = Package(
    name: "SecureClone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SecureClone",
            path: "SecureClone",
            exclude: ["SecureClone.entitlements"]
        )
    ]
)
