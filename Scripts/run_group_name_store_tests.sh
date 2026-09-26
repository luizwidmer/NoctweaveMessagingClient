#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$CLIENT_ROOT/../.build/client-group-name-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

xcrun swiftc -parse-as-library \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientGroupNameStore.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientGroupNameStoreTests.swift" \
  -o "$BUILD_ROOT/ClientGroupNameStoreTests"
"$BUILD_ROOT/ClientGroupNameStoreTests"
