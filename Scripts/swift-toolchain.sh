#!/usr/bin/env bash

readonly SWIFT_SNAPSHOT="swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a"
readonly SWIFT_TOOLCHAIN_IDENTIFIER="org.swift.64202607171a"
readonly SWIFT_WASM_SDK="${SWIFT_SNAPSHOT}_wasm"
readonly SWIFT_EMBEDDED_WASM_SDK="${SWIFT_SNAPSHOT}_wasm-embedded"
readonly SWIFT_WASM_TARGET_TRIPLE="wasm32-unknown-wasip1"
readonly SWIFT_COMMAND_TIMEOUT_SECONDS=120

SWIFT_EXECUTABLE="$(
  env TOOLCHAINS="$SWIFT_TOOLCHAIN_IDENTIFIER" xcrun --find swift 2>/dev/null || true
)"
readonly SWIFT_EXECUTABLE
SWIFT_TOOLCHAIN_BIN_DIRECTORY="$(dirname "$SWIFT_EXECUTABLE")"
readonly SWIFT_TOOLCHAIN_BIN_DIRECTORY
readonly LLVM_NM="$SWIFT_TOOLCHAIN_BIN_DIRECTORY/llvm-nm"
readonly LLVM_OBJDUMP="$SWIFT_TOOLCHAIN_BIN_DIRECTORY/llvm-objdump"
XCODE_SWIFT_EXECUTABLE="$(
  env -u TOOLCHAINS xcrun --toolchain XcodeDefault --find swift 2>/dev/null || true
)"
readonly XCODE_SWIFT_EXECUTABLE

swift64() {
  "$SWIFT_EXECUTABLE" "$@"
}

swift64_timed() {
  perl -e 'alarm shift; exec @ARGV' \
    "$SWIFT_COMMAND_TIMEOUT_SECONDS" \
    "$SWIFT_EXECUTABLE" \
    "$@"
}

xcodebuild64_timed() {
  perl -e 'alarm shift; exec @ARGV' \
    "$SWIFT_COMMAND_TIMEOUT_SECONDS" \
    env -u TOOLCHAINS \
    xcodebuild \
    "$@"
}

verify_swift64_environment() {
  if [[ -z "$SWIFT_EXECUTABLE" || ! -x "$SWIFT_EXECUTABLE" ]]; then
    echo "Swift toolchain is not installed: $SWIFT_TOOLCHAIN_IDENTIFIER" >&2
    exit 1
  fi
  for llvm_tool in "$LLVM_NM" "$LLVM_OBJDUMP"; do
    if [[ ! -x "$llvm_tool" ]]; then
      echo "Pinned LLVM tool is not installed: $llvm_tool" >&2
      exit 1
    fi
  done
  if [[ -z "$XCODE_SWIFT_EXECUTABLE" || ! -x "$XCODE_SWIFT_EXECUTABLE" ]]; then
    echo "Xcode default Swift toolchain is not installed" >&2
    exit 1
  fi

  if [[ "$SWIFT_EXECUTABLE" != *"/${SWIFT_SNAPSHOT}.xctoolchain/"* ]]; then
    echo "Swift toolchain path does not match the pinned snapshot: $SWIFT_EXECUTABLE" >&2
    exit 1
  fi

  local version
  version="$(swift64 --version)"
  if [[ "$version" != *"Apple Swift version 6.4-dev"* ]]; then
    echo "Pinned toolchain does not report Swift 6.4-dev" >&2
    echo "$version" >&2
    exit 1
  fi

  local installed_sdks
  installed_sdks="$(swift64 sdk list)"
  for required_sdk in "$SWIFT_WASM_SDK" "$SWIFT_EMBEDDED_WASM_SDK"; do
    if ! grep -Fqx "$required_sdk" <<< "$installed_sdks"; then
      echo "Required Swift SDK is not installed: $required_sdk" >&2
      exit 1
    fi
  done

  local xcode_version
  xcode_version="$("$XCODE_SWIFT_EXECUTABLE" --version 2>&1)"
  if [[ "$xcode_version" != *"Apple Swift version 6.4 "* ]]; then
    echo "Xcode default toolchain does not report Swift 6.4" >&2
    echo "$xcode_version" >&2
    exit 1
  fi

  echo "swift-toolchain-id: $SWIFT_TOOLCHAIN_IDENTIFIER"
  echo "swift-toolchain-snapshot: $SWIFT_SNAPSHOT"
  echo "swift-toolchain-path: $SWIFT_EXECUTABLE"
  echo "swift-llvm-tools: $LLVM_NM $LLVM_OBJDUMP"
  echo "$version"
  echo "swift-wasm-sdk: $SWIFT_WASM_SDK"
  echo "swift-embedded-wasm-sdk: $SWIFT_EMBEDDED_WASM_SDK"
  echo "swift-wasm-target: $SWIFT_WASM_TARGET_TRIPLE"
  echo "xcode-swift-path: $XCODE_SWIFT_EXECUTABLE"
  echo "$xcode_version"
}
