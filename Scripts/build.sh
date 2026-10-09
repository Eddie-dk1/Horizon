#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache"
swift build --product Horizon -c release --scratch-path build/swift --cache-path build/cache --config-path build/config --security-path build/security --disable-sandbox
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" Scripts/icon.swift Resources/Horizon.iconset
iconutil -c icns Resources/Horizon.iconset -o Resources/Horizon.icns
cp Resources/Horizon.iconset/icon_512x512@2x.png Resources/Horizon-1024.png
mkdir -p build/Horizon.app/Contents/MacOS build/Horizon.app/Contents/Resources
cp build/swift/arm64-apple-macosx/release/Horizon build/Horizon.app/Contents/MacOS/Horizon
cp Resources/Info.plist build/Horizon.app/Contents/Info.plist
cp Resources/Horizon.icns build/Horizon.app/Contents/Resources/Horizon.icns
codesign --force --sign - --options runtime --timestamp=none build/Horizon.app
codesign --verify --strict build/Horizon.app
ditto -c -k --sequesterRsrc --keepParent build/Horizon.app build/Horizon-macOS.zip
echo "Ready: $PWD/build/Horizon.app"
