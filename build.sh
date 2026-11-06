#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
project_root="$PWD"
build_dir="${BUILD_DIR:-$project_root/build}"
dist_dir="${DIST_DIR:-$project_root/dist}"
deployment_target=13.0
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
read -r -a architectures <<< "${ARCHS:-arm64 x86_64}"
if [ "${#architectures[@]}" -eq 0 ]; then
    echo 'ARCHS must contain arm64, x86_64, or both.' >&2
    exit 1
fi
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
done
mkdir -p "$build_dir" "$dist_dir"
build_dir="$(cd "$build_dir" && pwd)"
dist_dir="$(cd "$dist_dir" && pwd)"
app_path="$dist_dir/CONNECT 6 Link.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
app_slices=()
diagnostic_slices=()
for architecture in "${architectures[@]}"; do
    slice_dir="$build_dir/$architecture"
    mkdir -p "$slice_dir/module-cache" "$slice_dir/clang-cache"
    export CLANG_MODULE_CACHE_PATH="$slice_dir/clang-cache"
    target="$architecture-apple-macosx$deployment_target"
    xcrun clang -O2 -Wall -Wextra -target "$target" -isysroot "$sdk_path" \
        -c Sources/USBBridge.c -o "$slice_dir/USBBridge.o"
    swift_options=(-O -swift-version 5 -target "$target" -sdk "$sdk_path"
        -module-cache-path "$slice_dir/module-cache" -import-objc-header Sources/USBBridge.h)
    xcrun swiftc "${swift_options[@]}" Sources/LinkEngine.swift Sources/Device.swift Sources/App.swift \
        "$slice_dir/USBBridge.o" -framework IOKit -framework CoreFoundation \
        -framework SwiftUI -framework AppKit -framework ServiceManagement -o "$slice_dir/CONNECT 6 Link"
    xcrun swiftc "${swift_options[@]}" Sources/LinkEngine.swift Sources/Device.swift Tools/main.swift \
        "$slice_dir/USBBridge.o" -framework IOKit -framework CoreFoundation -o "$slice_dir/connect6-diagnose"
    app_slices+=("$slice_dir/CONNECT 6 Link")
    diagnostic_slices+=("$slice_dir/connect6-diagnose")
done
if [ "${#architectures[@]}" -gt 1 ]; then
    xcrun lipo -create "${app_slices[@]}" -output "$app_path/Contents/MacOS/CONNECT 6 Link"
    xcrun lipo -create "${diagnostic_slices[@]}" -output "$build_dir/connect6-diagnose"
else
    cp "${app_slices[0]}" "$app_path/Contents/MacOS/CONNECT 6 Link"
    cp "${diagnostic_slices[0]}" "$build_dir/connect6-diagnose"
fi
cp Info.plist "$app_path/Contents/Info.plist"
xcrun swift -module-cache-path "$build_dir/icon-module-cache" Tools/generate-icon.swift "$build_dir/AppIcon.iconset"
xcrun iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
identity="${SIGNING_IDENTITY:--}"
if [ "$identity" = '-' ]; then
    codesign --force --sign - --options runtime --timestamp=none "$app_path"
else
    codesign --force --sign "$identity" --options runtime --timestamp "$app_path"
fi
codesign --verify --strict --verbose=2 "$app_path"
xcrun lipo "$app_path/Contents/MacOS/CONNECT 6 Link" -verify_arch "${architectures[@]}"
plutil -lint "$app_path/Contents/Info.plist"
echo "Built: $app_path (${architectures[*]}, macOS $deployment_target+)"
