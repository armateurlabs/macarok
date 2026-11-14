#!/bin/bash
set -euo pipefail

# Optional upstream Chromaprint helper. Never installs anything outside .build.
# Official release asset digest: acoustid/chromaprint, tag v1.6.2.
# The upstream helper includes FFmpeg 8.0, built with networking disabled.
# Sources: https://github.com/acoustid/chromaprint/tree/v1.6.2
# FFmpeg build: https://github.com/acoustid/ffmpeg-build/tree/v8.0-1
# FFmpeg source: https://ffmpeg.org/releases/ffmpeg-8.0.tar.gz
project_root="$(cd "$(dirname "$0")/.." && pwd)"
tool_directory="$project_root/.build/tools/chromaprint"
archive="$tool_directory/chromaprint-fpcalc-1.6.2-macos-universal.tar.gz"
archive_url="https://github.com/acoustid/chromaprint/releases/download/v1.6.2/chromaprint-fpcalc-1.6.2-macos-universal.tar.gz"
checksum="53d9368f96017fb288d74f6ed4d928f7bbbfb2ff81e69b4ef67b6ceeb217d9b2"
mkdir -p "$tool_directory"

if [[ ! -f "$archive" ]]; then
    download="$archive.download"
    trap 'rm -f "$download"' EXIT
    curl --fail --location --silent --show-error --retry 2 "$archive_url" --output "$download"
    mv "$download" "$archive"
fi
actual_checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_checksum" != "$checksum" ]]; then
    echo "Chromaprint helper checksum did not match the pinned official release." >&2
    exit 1
fi
extraction_directory="$(mktemp -d "$tool_directory/extract.XXXXXXXX")"
trap 'rm -rf "$extraction_directory"' EXIT
tar -xzf "$archive" -C "$extraction_directory" --strip-components=1
test -f "$extraction_directory/fpcalc"
cp "$extraction_directory/fpcalc" "$tool_directory/fpcalc"
chmod 755 "$tool_directory/fpcalc"
echo "$tool_directory/fpcalc"
