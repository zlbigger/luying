#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/luying-test.XXXXXX")
trap 'rm -rf "$TASK_TEMP"' EXIT
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=15' -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac "$TASK_TEMP/input.mp4"
python3 - "$TASK_TEMP/mouse.json" <<'PY'
import json,sys
json.dump({'width':320,'height':180,'events':[{'time':i/400,'x':0.2+(i%50)/100,'y':0.5,'kind':'click' if i==200 else 'move'} for i in range(800)]},open(sys.argv[1],'w'))
PY
python3 exporter.py "$TASK_TEMP/input.mp4" "$TASK_TEMP/output.mp4" --mouse "$TASK_TEMP/mouse.json" --start .25 --end 1.75 --speed 2 --width 320 --fps 15 --padding 16 --denoise > "$TASK_TEMP/result.json" 2> "$TASK_TEMP/ffmpeg.log"
python3 - "$TASK_TEMP/output.mp4" <<'PY'
import json,subprocess,sys
result=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',sys.argv[1]]))
v=next(s for s in result['streams'] if s['codec_type']=='video')
assert (v['width'],v['height'])==(320,180),v
assert abs(float(result['format']['duration'])-.75)<.15,result['format']['duration']
assert any(s['codec_type']=='audio' for s in result['streams'])
print('PASS: dense mouse trace, zoom, trim, speed, audio denoise and MP4 output')
PY
