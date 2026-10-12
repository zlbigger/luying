#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RUNTIME="${LUYING_RUNTIME_DIR:-$PWD/.runtime}"
mkdir -p "$RUNTIME"
if [ ! -f "$RUNTIME/ffmpeg-8.0.1.tar.xz" ]; then
  curl -L --fail https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz -o "$RUNTIME/ffmpeg-8.0.1.tar.xz"
fi
EXPECTED=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
ACTUAL=$(shasum -a 256 "$RUNTIME/ffmpeg-8.0.1.tar.xz" | cut -d ' ' -f 1)
[ "$ACTUAL" = "$EXPECTED" ] || { echo 'FFmpeg source checksum mismatch'; exit 1; }
if [ ! -x "$RUNTIME/media/bin/ffmpeg" ]; then
  tar -xf "$RUNTIME/ffmpeg-8.0.1.tar.xz" -C "$RUNTIME"
  (cd "$RUNTIME/ffmpeg-8.0.1"
   ./configure --prefix=/ --cc=clang --arch=arm64 --target-os=darwin --disable-autodetect --disable-network --disable-doc --disable-debug --disable-static --enable-shared --disable-x86asm --enable-videotoolbox --enable-audiotoolbox --enable-zlib --install-name-dir=@rpath --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags='-mmacosx-version-min=14.0 -Wl,-rpath,@executable_path/lib'
   make -j"$(sysctl -n hw.ncpu)"
   make DESTDIR="$RUNTIME/media" install)
fi
if [ ! -x "$RUNTIME/venv/bin/pyinstaller" ]; then
  python3 -m venv "$RUNTIME/venv"
  "$RUNTIME/venv/bin/pip" install pyinstaller==6.22.3
fi
"$RUNTIME/venv/bin/pyinstaller" --noconfirm --clean --onedir --name exporter --target-arch arm64 --distpath "$RUNTIME/dist" --workpath "$RUNTIME/pyinstaller-work" --specpath "$RUNTIME" exporter.py
mkdir -p "$RUNTIME/licenses"
cp "$RUNTIME/ffmpeg-8.0.1/COPYING.LGPLv2.1" "$RUNTIME/licenses/FFmpeg-LGPL-2.1.txt"
"$RUNTIME/venv/bin/python" - "$RUNTIME/licenses" <<'PY'
import sys,pathlib,sysconfig,importlib.metadata
out=pathlib.Path(sys.argv[1])
license=pathlib.Path(sysconfig.get_path('stdlib'))/'LICENSE.txt'
if not license.is_file():raise SystemExit('Python license missing')
(out/'Python-LICENSE.txt').write_bytes(license.read_bytes())
for package in ('pyinstaller','altgraph','macholib'):
 d=importlib.metadata.distribution(package)
 for f in d.files:
  if 'license' in str(f).lower() and str(f).endswith(('.txt','LICENSE')):
   (out/(package+'-'+pathlib.Path(f).name)).write_bytes(d.locate_file(f).read_bytes())
PY
