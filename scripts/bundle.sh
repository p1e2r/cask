#!/bin/bash
# Builds Cask.app (universal), plus Cask.dmg and Cask.zip, into dist/. Run on macOS with Xcode 16+.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || VERSION="0.1.0"
BUILD="${GITHUB_RUN_NUMBER:-1}"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product CaskApp
swift build -c release "${ARCHS[@]}" --product cask-cli
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="dist/Cask.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/CaskApp" "$APP/Contents/MacOS/Cask"
cp "$BIN/cask-cli" "$APP/Contents/Helpers/cask"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"

# Ad-hoc signature (no paid Apple Developer account needed). Helper first, then the app.
codesign --force --sign - "$APP/Contents/Helpers/cask"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

"$APP/Contents/Helpers/cask" --version

# DMG with an Applications shortcut, and a zip.
STAGE="dist/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cask" -srcfolder "$STAGE" -ov -format UDZO dist/Cask.dmg
rm -rf "$STAGE"
(cd dist && ditto -c -k --keepParent Cask.app Cask.zip)
echo "Built dist/Cask.app $VERSION ($BUILD)"
