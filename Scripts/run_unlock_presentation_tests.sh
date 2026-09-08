#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="$CLIENT_ROOT/../NoctweaveCore"
BUILD_ROOT="$CLIENT_ROOT/../.build/client-unlock-presentation-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

xcrun swift build --package-path "$CORE_ROOT" --target NoctweaveCore
CORE_BIN="$(xcrun swift build --package-path "$CORE_ROOT" --show-bin-path)"
CORE_OBJECTS=("$CORE_BIN"/NoctweaveCore.build/*.o)
OQS_ROOT="$CORE_ROOT/Vendor/liboqs.xcframework/macos-$(uname -m)"
xcrun swiftc -parse-as-library -I "$CORE_BIN/Modules" -I "$OQS_ROOT/Headers" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientLockPresentation.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientLockPresentationTests.swift" \
  "${CORE_OBJECTS[@]}" "$OQS_ROOT/liboqs.a" -o "$BUILD_ROOT/ClientLockPresentationTests"
"$BUILD_ROOT/ClientLockPresentationTests"
