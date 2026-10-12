# Bundled components

LuYing source and original icon: MIT. The prebuilt app includes the following separate components:

- Python 3.11: Python Software Foundation License. Full license is inside `录映.app/Contents/Resources/Licenses/Python-LICENSE.txt`. Python standard-library extension dependencies retain their accompanying notices.
- PyInstaller 6.22.3 bootloader: GPL with the distribution exception permitting bundled programs under their own license; see bundled license. Build helpers altgraph/macholib retain their licenses.
- FFmpeg 8.0.1: **LGPL 2.1 or later**, built without GPL/nonfree/external codec libraries. Shared libraries are under `Contents/Resources/Tools/lib`; FFmpeg CLI dynamically links them. You may replace them with compatible builds and re-sign the app locally. No DRM or restriction on reverse engineering these components is imposed.

The exact unmodified FFmpeg source archive is included with the v0.2.0 GitHub Release as `ffmpeg-8.0.1.tar.xz`; upstream: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz . SHA-256: `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41`.

The complete build flags and process are in `scripts/build-runtime.sh`. H.264 encoding uses macOS VideoToolbox. FFmpeg and Python are separate works and are not relicensed under LuYing's MIT license. App Store/Developer ID notarization is not provided in this release.
