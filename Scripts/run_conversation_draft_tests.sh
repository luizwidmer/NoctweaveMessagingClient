#!/usr/bin/env bash
set -euo pipefail

CLIENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PATH="${1:-$CLIENT_ROOT/Noctweave Messaging Client/ClientViewModel.swift}"
BUILD_ROOT="${NOCTWEAVE_DRAFT_TEST_BUILD_ROOT:-$CLIENT_ROOT/../.build/client-conversation-draft-tests}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
mkdir -p "$BUILD_ROOT"

# Compile the actual model properties and actions, replacing only its transport
# and task runner. This exercises asynchronous draft behavior without launching
# a signed app or using the host's stored conversations and authentication state.
{
  cat <<'SWIFT'
import Combine
import Foundation
@MainActor final class ClientConversationDraftModel {
    let client = DeferredDraftSendClient()
    var operation: Task<Void, Never>?
    var statusMessage = ""
    func runOperation(label: String, _ body: @escaping (DeferredDraftSendClient) async throws -> Void) {
        operation = Task { try! await body(client) }
    }
SWIFT
  awk '
    /@Published var selectedRelationshipID:/ { copying = 1 }
    /@Published private\(set\) var isWorking/ { copying = 0 }
    copying { print }
  ' "$SOURCE_PATH"
  awk '
    /    func sendDraft\(\)/ { copying = 1 }
    /    func createGroup\(/ { copying = 0 }
    copying { print }
  ' "$SOURCE_PATH"
  printf '}\n'
} > "$BUILD_ROOT/ClientConversationDraftModel.swift"

xcrun swiftc -parse-as-library \
  "$BUILD_ROOT/ClientConversationDraftModel.swift" \
  "$CLIENT_ROOT/SanitizerTests/ClientConversationDraftTests.swift" \
  -o "$BUILD_ROOT/ClientConversationDraftTests"
"$BUILD_ROOT/ClientConversationDraftTests"
