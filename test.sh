#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -O2 -Wall -Wextra -mmacosx-version-min=13.0 -c Sources/USBBridge.c -o build/TestUSBBridge.o
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/connect6-link-swift-cache" \
    -import-objc-header Sources/USBBridge.h Sources/LinkEngine.swift Sources/Device.swift Tests/main.swift \
    build/TestUSBBridge.o -framework IOKit -framework CoreFoundation -o build/link-tests
build/link-tests
xcrun clang -Wall -Wextra Tests/USBBridgeTests.c -framework IOKit -framework CoreFoundation -o build/bridge-tests
build/bridge-tests
