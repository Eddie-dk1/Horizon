#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/module-cache"
swift build --target HorizonCore --scratch-path build/swift --cache-path build/cache --config-path build/config --security-path build/security --disable-sandbox
mkdir -p build/interaction-checks
swiftc -parse-as-library -module-cache-path "$PWD/build/module-cache" -I build/swift/arm64-apple-macosx/debug/Modules Sources/HorizonApp/AppModel.swift Tests/HorizonInteractionChecks/Runner.swift build/swift/arm64-apple-macosx/debug/HorizonCore.build/*.o -o build/interaction-checks/check
TASK_ROOT="$(mktemp -d "${TMPDIR:-/tmp/}horizon-interactions.XXXXXX")"
build/interaction-checks/check --vault-root "$TASK_ROOT"
