#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="$CLIENT_ROOT/../NoctweaveCore"
BUILD_ROOT="$CLIENT_ROOT/../.build/client-attachment-storage-tests"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

source "$CLIENT_ROOT/Scripts/core-test-artifacts.sh"
xcrun swiftc -parse-as-library \
  -I "$CORE_MODULE_DIR" -I "$OQS_ROOT/Headers" \
  "$CLIENT_ROOT/Noctweave Messaging Client/SecureRegularFileIO.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientAttachmentStore.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientAttachmentStorageTests.swift" \
  "${CORE_LINK_INPUTS[@]}" "$OQS_ROOT/liboqs.a" \
  -o "$BUILD_ROOT/ClientAttachmentStorageTests"
"$BUILD_ROOT/ClientAttachmentStorageTests"

# Test the app's complete durable replacement coordinator against isolated real
# Keychain scopes, including an interrupted run resumed with fresh store objects.
xcrun swiftc -D DEBUG -parse-as-library \
  -I "$CORE_MODULE_DIR" -I "$OQS_ROOT/Headers" \
  "$CLIENT_ROOT/Noctweave Messaging Client/SecureRegularFileIO.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientAttachmentStore.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientGroupNameStore.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/ClientDuressTransition.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/NoctweaveUITestRuntime.swift" \
  "$CLIENT_ROOT/Noctweave Messaging Client/OpaqueRoutePrefetchBridge.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientDuressTransitionTests.swift" \
  "${CORE_LINK_INPUTS[@]}" "$OQS_ROOT/liboqs.a" \
  -o "$BUILD_ROOT/ClientDuressTransitionTests"
"$BUILD_ROOT/ClientDuressTransitionTests"
