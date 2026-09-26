#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$CLIENT_ROOT/../.build/client-unlock-retry-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

xcrun swiftc -D DEBUG -parse-as-library \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientUnlockRetryLedger.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/SecureRegularFileIO.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientUnlockRetryLedgerTests.swift" \
  -o "$BUILD_ROOT/ClientUnlockRetryLedgerTests"
"$BUILD_ROOT/ClientUnlockRetryLedgerTests"
