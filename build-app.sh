#!/bin/bash
#
# build-app.sh — builds SecureClone.app from the Swift package.
#
# Requirements: macOS 14+ with either Xcode or just the Command Line Tools
# (`xcode-select --install`). No Xcode project file needed.
#
# Usage:  ./build-app.sh            → build/SecureClone.app  (+ zip)
#         ./build-app.sh --universal → Intel + Apple Silicon binary
#

set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=""
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

echo "▶ Building SecureClone (release)…"
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS

BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/SecureClone"
APP="build/SecureClone.app"

# Version: marketing version from the VERSION file; build number from the
# CI run number (auto-increments on GitHub) or 0 for a local build.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${GITHUB_RUN_NUMBER:-0}"
echo "▶ Version $VERSION (build $BUILD)"

echo "▶ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SecureClone"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "▶ Signing with Developer ID: $SIGN_IDENTITY"
    cat > build/entitlements.plist <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><false/>
</dict></plist>
EOP
    codesign --force --deep --options runtime --timestamp --entitlements build/entitlements.plist \
             --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "▶ Ad-hoc signing…"
    codesign --force --deep --sign - "$APP"
fi

echo "▶ Zipping…"
ZIP="build/SecureClone-$VERSION-build$BUILD.zip"
rm -f build/SecureClone*.zip
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "✅ Done:  $APP"
echo "         $ZIP"
echo
echo "First launch: right-click SecureClone.app → Open (ad-hoc signed, not notarized)."
