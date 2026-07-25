#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_x86_scratch="$root_directory/.build/native-x86"
wasm_scratch="$root_directory/.build/wasm"
embedded_scratch="$root_directory/.build/wasm-embedded"

source "$root_directory/Scripts/swift-toolchain.sh"

cd "$root_directory"
verify_swift64_environment

swift64_timed build \
  -c release \
  --triple x86_64-apple-macosx26.0 \
  --scratch-path "$native_x86_scratch" \
  --target GigaTokenCore
echo "native-x86: Foundation-free core built"

swift64_timed build \
  --swift-sdk "$SWIFT_WASM_SDK" \
  -c release \
  --scratch-path "$wasm_scratch" \
  --product GigaTokenSmoke
wasm_bin_path="$(
  swift64 build \
    --swift-sdk "$SWIFT_WASM_SDK" \
    -c release \
    --scratch-path "$wasm_scratch" \
    --show-bin-path
)"
wasm_output="$(node --no-warnings "$root_directory/Scripts/run-wasi.mjs" \
  "$wasm_bin_path/GigaTokenSmoke.wasm"
)"
echo "$wasm_output"
grep -Fq "execution-mode: standard-wasm" <<< "$wasm_output"
grep -Fq "gigatoken-smoke: passed" <<< "$wasm_output"
if grep -Fq "data race detected" <<< "$wasm_output"; then
  echo "standard-wasm: dynamic isolation check reported a data race" >&2
  exit 1
fi

swift64_timed build \
  --swift-sdk "$SWIFT_EMBEDDED_WASM_SDK" \
  -c release \
  --scratch-path "$embedded_scratch" \
  --product GigaTokenSmoke
embedded_bin_path="$(
  swift64 build \
    --swift-sdk "$SWIFT_EMBEDDED_WASM_SDK" \
    -c release \
    --scratch-path "$embedded_scratch" \
    --show-bin-path
)"
embedded_output="$(node --no-warnings "$root_directory/Scripts/run-wasi.mjs" \
  "$embedded_bin_path/GigaTokenSmoke.wasm"
)"
echo "$embedded_output"
grep -Fq "execution-mode: embedded-wasm" <<< "$embedded_output"
grep -Fq "gigatoken-smoke: passed" <<< "$embedded_output"
if grep -Fq "data race detected" <<< "$embedded_output"; then
  echo "wasm-embedded: dynamic isolation check reported a data race" >&2
  exit 1
fi
