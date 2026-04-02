#!/bin/zsh
set -euo pipefail

ROOT="/Users/ishaan/Documents/code/copy-paste"
SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk"
MODULE_CACHE="$ROOT/.build/ModuleCache"
SCRATCH_PATH="$ROOT/.build-scratch"

mkdir -p "$MODULE_CACHE" "$SCRATCH_PATH"

env \
  SDKROOT="$SDKROOT" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift build --scratch-path "$SCRATCH_PATH"

exec "$SCRATCH_PATH/debug/MultiPaste"
