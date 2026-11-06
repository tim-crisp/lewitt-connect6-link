#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dist_dir="${DIST_DIR:-$PWD/dist}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
dmg_path="$dist_dir/CONNECT6Link-$version-universal.dmg"
mount_root="$(mktemp -d "${TMPDIR:-/tmp}/connect6-verify.XXXXXX")"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then hdiutil detach "$mount_root/disk" -quiet; fi
    rmdir "$mount_root"
}
trap cleanup EXIT
hdiutil verify "$dmg_path"
hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_root/disk" -quiet
mounted=true
app="$mount_root/disk/CONNECT 6 Link.app"
test -x "$app/Contents/MacOS/CONNECT 6 Link"
test -s "$app/Contents/Resources/AppIcon.icns"
test -s "$mount_root/disk/Install.txt"
test "$(readlink "$mount_root/disk/Applications")" = /Applications
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
xcrun lipo "$app/Contents/MacOS/CONNECT 6 Link" -verify_arch arm64 x86_64
codesign --verify --strict --verbose=2 "$app"
plutil -lint "$app/Contents/Info.plist"
echo 'PASS: DMG mounts, installer layout is complete, and the packaged app is signed and universal.'
