#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/luying-build.XXXXXX")
APP="$BUILD_TEMP/录映.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/*.swift -o "$APP/Contents/MacOS/OpenScreenStudio"
cp LuYing.icns "$APP/Contents/Resources/"
cp exporter.py "$APP/Contents/Resources/"
if [ -f subtitles.swift ]; then cp subtitles.swift "$APP/Contents/Resources/"; fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>录映</string>
<key>CFBundleDisplayName</key><string>录映</string>
<key>CFBundleIconFile</key><string>LuYing.icns</string>
<key>CFBundleIdentifier</key><string>local.openscreenstudio.app</string>
<key>CFBundleExecutable</key><string>OpenScreenStudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSpeechRecognitionUsageDescription</key><string>在本机识别录制音频并生成字幕，不上传音频。</string>
<key>NSCameraUsageDescription</key><string>录制摄像头视频并叠加到你的录屏作品。</string>
<key>NSMicrophoneUsageDescription</key><string>录制你选择的麦克风声音。</string>
</dict></plist>
PLIST
xattr -cr "$APP"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --deep --sign - --requirements '=designated => identifier "local.openscreenstudio.app"' "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$PWD/LuYing.zip"
echo "Built archive: $PWD/LuYing.zip"
echo "Signed staging: $APP"
