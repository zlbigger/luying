#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/luying-timing.XXXXXX")
trap 'rm -rf "$TASK_TEMP"' EXIT
cp Sources/CaptureEngine.swift "$TASK_TEMP/CaptureEngine.swift"
sed 's/private final class CameraSink/final class CameraSink/' Sources/WebcamRecorder.swift > "$TASK_TEMP/WebcamRecorder.swift"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 "$TASK_TEMP/CaptureEngine.swift" "$TASK_TEMP/WebcamRecorder.swift" Tests/CaptureTiming.swift -o "$TASK_TEMP/test"
"$TASK_TEMP/test" "$TASK_TEMP/camera.mov"
