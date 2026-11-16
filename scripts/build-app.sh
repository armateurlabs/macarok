#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
release_version="${2:-}"
build_number="${3:-}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release] [version build-number]" >&2; exit 2 ;; esac
if [[ "$#" -gt 3 ]]; then echo "Usage: $0 [debug|release] [version build-number]" >&2; exit 2; fi
if [[ -n "$release_version" || -n "$build_number" ]]; then
    source "$project_root/scripts/release-version.sh"
    validate_release_version "$release_version" "$build_number"
fi
cd "$project_root"
swift build --configuration "$configuration" --product Macarok
binary_directory="$(swift build --configuration "$configuration" --show-bin-path)"
app_path="$project_root/dist/Macarok.app"
mkdir -p "$project_root/dist"
staging_directory="$(mktemp -d "$project_root/dist/.macarok-build.XXXXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
staged_app="$staging_directory/Macarok.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"
cp "$binary_directory/Macarok" "$staged_app/Contents/MacOS/Macarok"
cp Support/Info.plist "$staged_app/Contents/Info.plist"
if [[ -n "$release_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${release_version%%-*}" "$staged_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$staged_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleGetInfoString string Macarok $release_version" "$staged_app/Contents/Info.plist"
fi
swift scripts/make-icon.swift
cp Support/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
cp LICENSE "$staged_app/Contents/Resources/LICENSE.txt"
cp Support/ThirdPartyNotices.md "$staged_app/Contents/Resources/ThirdPartyNotices.md"
mkdir -p "$staged_app/Contents/Resources/Licenses"
cp .build/checkouts/GRDB.swift/LICENSE "$staged_app/Contents/Resources/Licenses/GRDB-MIT.txt"
cp .build/checkouts/KeyboardShortcuts/license "$staged_app/Contents/Resources/Licenses/KeyboardShortcuts-MIT.txt"
cp .build/checkouts/CXXTagLib/LICENSE.txt "$staged_app/Contents/Resources/Licenses/TagLib-MPL.txt"
cp .build/checkouts/CXXTagLib/Sources/taglib/utfcpp/LICENSE "$staged_app/Contents/Resources/Licenses/utfcpp-Boost.txt"
vlckit_notice="$(find .build/artifacts -type f -path '*/VLCKit/COPYING.txt' -print -quit)"
[[ -n "$vlckit_notice" ]] && cp "$vlckit_notice" "$staged_app/Contents/Resources/Licenses/VLCKit-COPYING.txt"
if [[ "${MACAROK_INCLUDE_FPCALC:-1}" == "1" ]]; then
    helper_path="$(./scripts/fetch-fingerprint-helper.sh)"
    mkdir -p "$staged_app/Contents/SharedSupport/Helpers"
    cp "$helper_path" "$staged_app/Contents/SharedSupport/Helpers/fpcalc"
    cp Support/Chromaprint-LICENSE.md Support/FFmpeg-LGPL-2.1.txt "$staged_app/Contents/Resources/Licenses/"
    codesign --force --sign - "$staged_app/Contents/SharedSupport/Helpers/fpcalc"
fi
framework_path="$(find .build/artifacts -type d -name VLCKit.framework -path '*macos*' -print -quit)"
if [[ -z "$framework_path" ]]; then
    echo "The macOS VLCKit framework is missing from SwiftPM artifacts." >&2
    exit 1
fi
ditto "$framework_path" "$staged_app/Contents/Frameworks/VLCKit.framework"
for resource_bundle in "$binary_directory"/*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    ditto "$resource_bundle" "$staged_app/Contents/Resources/$(basename "$resource_bundle")"
done
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
rm -rf "$app_path"
mv "$staged_app" "$app_path"
echo "$app_path"
