#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/noctweave-attachment-sanitizer-tests"
mkdir -p "$BUILD_DIR"

xcrun swiftc \
  "$ROOT_DIR/Noctweave Messaging Client/AttachmentSanitizer.swift" \
  "$ROOT_DIR/SanitizerTests/AttachmentSanitizerSmokeTests.swift" \
  -o "$BUILD_DIR/AttachmentSanitizerSmokeTests"

"$BUILD_DIR/AttachmentSanitizerSmokeTests"
