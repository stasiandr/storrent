#!/bin/sh
# Builds the engine and the app, and wraps them into build/storrent.app.
set -eu
cd "$(dirname "$0")/.."

scripts/build-engine.sh release
swift build -c release
BIN="$(swift build -c release --show-bin-path)/storrent"

APP=build/storrent.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/storrent"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>storrent</string>
    <key>CFBundleDisplayName</key><string>storrent</string>
    <key>CFBundleIdentifier</key><string>dev.stasiandr.storrent</string>
    <key>CFBundleExecutable</key><string>storrent</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>BitTorrent Magnet Link</string>
            <key>CFBundleURLSchemes</key><array><string>magnet</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>BitTorrent Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>org.bittorrent.torrent</string></array>
            <key>CFBundleTypeExtensions</key><array><string>torrent</string></array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>org.bittorrent.torrent</string>
            <key>UTTypeDescription</key><string>BitTorrent Document</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>torrent</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
