#!/usr/bin/env bash
# Sourced by the standalone native-client regression harnesses.
source "$CORE_ROOT/../scripts/swiftpm-options.sh"
# Build products as well as the module; a target-only build must not leave a
# previously emitted static library available for these regression executables.
xcrun swift build --package-path "$CORE_ROOT" "${NOCTWEAVE_SWIFT_BUILD_FLAGS[@]}"
CORE_BIN="$(xcrun swift build --package-path "$CORE_ROOT" "${NOCTWEAVE_SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"

if [[ -f "$CORE_BIN/libNoctweaveCore.a" && -e "$CORE_BIN/NoctweaveCore.swiftmodule" ]]; then
  CORE_MODULE_DIR="$CORE_BIN"
  CORE_LINK_INPUTS=("$CORE_BIN/libNoctweaveCore.a")
elif [[ -d "$CORE_BIN/Modules" ]]; then
  CORE_MODULE_DIR="$CORE_BIN/Modules"
  shopt -s nullglob
  CORE_LINK_INPUTS=("$CORE_BIN"/NoctweaveCore.build/*.o)
  shopt -u nullglob
  if (( ${#CORE_LINK_INPUTS[@]} == 0 )); then
    echo "No Core link objects found in $CORE_BIN" >&2
    exit 1
  fi
else
  echo "No Core module or library found in $CORE_BIN" >&2
  exit 1
fi
OQS_ROOT="$CORE_ROOT/Vendor/liboqs.xcframework/macos-$(uname -m)"
