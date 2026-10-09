#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/space-checks build/module-cache
swiftc -module-cache-path "$PWD/build/module-cache" Sources/HorizonApp/SpaceLayout.swift Sources/HorizonApp/SpaceNodeStyle.swift Tests/HorizonSpaceChecks/main.swift -o build/space-checks/check
build/space-checks/check
swiftc -parse-as-library -module-cache-path "$PWD/build/module-cache" Sources/HorizonApp/DropFiles.swift Tests/HorizonSpaceChecks/DropChecks.swift -o build/space-checks/drop-check
build/space-checks/drop-check
