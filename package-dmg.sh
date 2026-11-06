#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
dist_dir="${DIST_DIR:-$PWD/dist}"
mkdir -p "$dist_dir"
dist_dir="$(cd "$dist_dir" && pwd)"
app_path="$dist_dir/CONNECT 6 Link.app"
if [ ! -x "$app_path/Contents/MacOS/CONNECT 6 Link" ]; then
    echo 'Build the app first with bash build.sh.' >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Version must be three numeric components.' >&2
    exit 1
fi
xcrun lipo "$app_path/Contents/MacOS/CONNECT 6 Link" -verify_arch arm64 x86_64
codesign --verify --strict "$app_path"
stage="$(mktemp -d "${TMPDIR:-/tmp}/connect6-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app_path" "$stage/CONNECT 6 Link.app"
ln -s /Applications "$stage/Applications"
cp Packaging/Install.txt "$stage/Install.txt"
dmg_path="$dist_dir/CONNECT6Link-$version-universal.dmg"
hdiutil create -volname 'CONNECT 6 Link' -srcfolder "$stage" -ov -format UDZO "$dmg_path"
if [ "${SIGNING_IDENTITY:--}" != '-' ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg_path"
fi
hdiutil verify "$dmg_path"
echo "Packaged: $dmg_path"
