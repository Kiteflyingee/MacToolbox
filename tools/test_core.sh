#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
mkdir -p build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$task_root/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/build/ModuleCache"
exec swift test --disable-xctest --enable-swift-testing \
  --scratch-path build/SwiftPM --cache-path build/PackageCache \
  --config-path build/PackageConfig --security-path build/PackageSecurity \
  --disable-sandbox "$@"
