#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="$CLIENT_ROOT/../NoctweaveCore"
BUILD_ROOT="$CLIENT_ROOT/../.build/client-attachment-storage-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

xcrun swift build --package-path "$CORE_ROOT" --target NoctweaveCore
CORE_BIN="$(xcrun swift build --package-path "$CORE_ROOT" --show-bin-path)"
CORE_OBJECTS=("$CORE_BIN"/NoctweaveCore.build/*.o)
ARCH="$(uname -m)"
OQS_ROOT="$CORE_ROOT/Vendor/liboqs.xcframework/macos-$ARCH"
xcrun swiftc -parse-as-library \
  -I "$CORE_BIN/Modules" -I "$OQS_ROOT/Headers" \
  "$CLIENT_ROOT/Noctweave Messaging Client/SecureRegularFileIO.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientAttachmentStore.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientAttachmentStorageTests.swift" \
  "${CORE_OBJECTS[@]}" "$OQS_ROOT/liboqs.a" \
  -o "$BUILD_ROOT/ClientAttachmentStorageTests"
"$BUILD_ROOT/ClientAttachmentStorageTests"

# Test the app's complete durable replacement coordinator against isolated real
# Keychain scopes, including an interrupted run resumed with fresh store objects.
xcrun swiftc -D DEBUG -parse-as-library \
  -I "$CORE_BIN/Modules" -I "$OQS_ROOT/Headers" \
  "$CLIENT_ROOT/Noctweave Messaging Client/SecureRegularFileIO.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientAttachmentStore.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientDuressTransition.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/NoctweaveUITestRuntime.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/OpaqueRoutePrefetchBridge.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientDuressTransitionTests.swift" \
  "${CORE_OBJECTS[@]}" "$OQS_ROOT/liboqs.a" \
  -o "$BUILD_ROOT/ClientDuressTransitionTests"
"$BUILD_ROOT/ClientDuressTransitionTests"
