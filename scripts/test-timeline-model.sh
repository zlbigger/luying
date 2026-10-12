#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/luying-model.XXXXXX")
trap 'rm -rf "$TASK_TEMP"' EXIT
"${1:-ffmpeg}" -v error -y -f lavfi -i color=size=320x180:rate=15 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 3 -c:v h264_videotoolbox -allow_sw 1 -c:a aac "$TASK_TEMP/input.mp4"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 Sources/CaptureEngine.swift Sources/Timeline.swift Tests/TimelineModel.swift -o "$TASK_TEMP/test"
"$TASK_TEMP/test" "$TASK_TEMP/input.mp4"
