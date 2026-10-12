#!/bin/bash
# Build 指语.app (ad-hoc signed, stable bundle id so TCC grants persist across rebuilds)
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Zhiyu.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp art/AppIcon.icns art/menubar@2x.png "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 Sources/*.swift -o "$APP/Contents/MacOS/Zhiyu"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.zhiyu</string>
<key>CFBundleName</key><string>Zhiyu</string>
<key>CFBundleDisplayName</key><string>指语</string>
<key>CFBundleExecutable</key><string>Zhiyu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>指语需要麦克风把你的语音转成文字。</string>
</dict></plist>
PL
# stable self-signed identity => same designated requirement every build, so TCC grants survive rebuilds
ID=$(security find-identity -p codesigning | awk '/Zhiyu Local Signing/{print $2; exit}')
codesign --force --sign "${ID:--}" --identifier local.zhiyu "$APP"
# install: stable path so permissions stick and Launchpad/Spotlight find it
DEST="/Applications/指语.app"
pkill -x Zhiyu 2>/dev/null || true
rm -rf "$DEST" && cp -R "$APP" "$DEST"
echo "built + installed $DEST"
