#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="$CLIENT_ROOT/../NoctweaveCore"
BUILD_ROOT="$CLIENT_ROOT/../.build/client-unlock-presentation-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

source "$CLIENT_ROOT/Scripts/core-test-artifacts.sh"
xcrun swiftc -parse-as-library -I "$CORE_MODULE_DIR" -I "$OQS_ROOT/Headers" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientLockPresentation.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientLockPresentationTests.swift" \
  "${CORE_LINK_INPUTS[@]}" "$OQS_ROOT/liboqs.a" -o "$BUILD_ROOT/ClientLockPresentationTests"
"$BUILD_ROOT/ClientLockPresentationTests"
