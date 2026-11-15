#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -ne 2 ]]; then echo "Usage: $0 version build-number" >&2; exit 2; fi
release_version="$1"
build_number="$2"
source "$project_root/scripts/release-version.sh"
validate_release_version "$release_version" "$build_number"
cd "$project_root"

./scripts/build-app.sh release "$release_version" "$build_number"
app_path="$project_root/dist/Macarok.app"
case "$(lipo -archs "$app_path/Contents/MacOS/Macarok")" in
    arm64) architecture="arm64" ;;
    x86_64) architecture="x86_64" ;;
    "arm64 x86_64"|"x86_64 arm64") architecture="universal" ;;
    *) echo "The application has an unsupported architecture." >&2; exit 1 ;;
esac
image_name="Macarok-$release_version-$architecture.dmg"
image_path="$project_root/dist/$image_name"
if [[ -e "$image_path" || -e "$image_path.sha256" ]]; then
    echo "Release files already exist: $image_path. Remove them explicitly before rebuilding." >&2
    exit 1
fi

staging_directory="$(mktemp -d "$project_root/dist/.macarok-dmg.XXXXXXXX")"
mount_directory="$staging_directory/mount"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        if ! hdiutil detach "$mount_directory" >/dev/null 2>&1; then
            echo "Could not detach the verification image; leaving $staging_directory in place." >&2
            return
        fi
    fi
    rm -rf "$staging_directory"
}
trap cleanup EXIT

contents_directory="$staging_directory/contents"
mkdir -p "$contents_directory" "$mount_directory"
ditto "$app_path" "$contents_directory/Macarok.app"
ln -s /Applications "$contents_directory/Applications"
cp LICENSE "$contents_directory/LICENSE.txt"
cp Support/ThirdPartyNotices.md "$contents_directory/ThirdPartyNotices.md"
hdiutil create -volname Macarok -srcfolder "$contents_directory" -fs HFS+ -format UDZO "$staging_directory/$image_name"
hdiutil verify "$staging_directory/$image_name"
mounted=1
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_directory" "$staging_directory/$image_name" > "$staging_directory/attach.log"
mounted_app="$mount_directory/Macarok.app"
codesign --verify --deep --strict "$mounted_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mounted_app/Contents/Info.plist")" == "${release_version%%-*}" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$mounted_app/Contents/Info.plist")" == "$build_number" ]]
[[ "$(readlink "$mount_directory/Applications")" == /Applications ]]
cmp LICENSE "$mounted_app/Contents/Resources/LICENSE.txt"
cmp LICENSE "$mount_directory/LICENSE.txt"
hdiutil detach "$mount_directory"
mounted=0

(
    cd "$staging_directory"
    shasum -a 256 "$image_name" > "$image_name.sha256"
    shasum -a 256 -c "$image_name.sha256"
)
mv "$staging_directory/$image_name" "$image_path"
mv "$staging_directory/$image_name.sha256" "$image_path.sha256"
echo "$image_path"
echo "$image_path.sha256"
