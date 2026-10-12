#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
RUNTIME="${LUYING_RUNTIME_DIR:-$PWD/.runtime}"
export LUYING_RUNTIME_DIR="$RUNTIME"
./scripts/build-runtime.sh
BUILD_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/luying-build.XXXXXX")
APP="$BUILD_TEMP/录映.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/*.swift -o "$APP/Contents/MacOS/OpenScreenStudio"
cp assets/reward-qr.png "$APP/Contents/Resources/"
cp LuYing.icns "$APP/Contents/Resources/"
cp exporter.py "$APP/Contents/Resources/"
TOOLS="$APP/Contents/Resources/Tools"
mkdir -p "$TOOLS/lib" "$APP/Contents/Resources/Licenses"
cp -R "$RUNTIME/dist/exporter" "$TOOLS/"
cp "$RUNTIME/media/bin/ffmpeg" "$RUNTIME/media/bin/ffprobe" "$TOOLS/"
cp -R "$RUNTIME/media/lib/"*.dylib "$TOOLS/lib/"
cp "$RUNTIME/licenses/"* "$APP/Contents/Resources/Licenses/"
cp -R third_party/python-runtime "$APP/Contents/Resources/Licenses/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
xcrun swiftc -O -target arm64-apple-macosx14.0 subtitles.swift -o "$TOOLS/subtitles"
find "$TOOLS" -type f -print0 | while IFS= read -r -d '' tool; do
  if file -b "$tool" | /usr/bin/grep -q 'Mach-O'; then codesign --force --sign - "$tool"; fi
done
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
<key>CFBundleShortVersionString</key><string>0.3.5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSpeechRecognitionUsageDescription</key><string>在本机识别录制音频并生成字幕，不上传音频。</string>
<key>NSCameraUsageDescription</key><string>录制摄像头视频并叠加到你的录屏作品。</string>
<key>NSMicrophoneUsageDescription</key><string>录制你选择的麦克风声音。</string>
</dict></plist>
PLIST
xattr -cr "$APP"
printf '%s\n' "$APP" > "$RUNTIME/last-app-path.txt"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --force --deep --sign - --requirements '=designated => identifier "local.openscreenstudio.app"' "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$PWD/LuYing.zip"
echo "Built archive: $PWD/LuYing.zip"
echo "Signed staging: $APP"
