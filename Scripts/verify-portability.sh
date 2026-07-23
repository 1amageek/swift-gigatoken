#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
native_x86_scratch="$root_directory/.build/native-x86"
wasm_scratch="$root_directory/.build/wasm"
embedded_scratch="$root_directory/.build/wasm-embedded"

cd "$root_directory"

swiftly run swift +6.3.1 ++ build \
  -c release \
  --triple x86_64-apple-macosx26.0 \
  --scratch-path "$native_x86_scratch" \
  --target GigaTokenCore
echo "native-x86: Foundation-free core built"

swiftly run swift +6.3.1 ++ build \
  --swift-sdk swift-6.3.1-RELEASE_wasm \
  -c release \
  --scratch-path "$wasm_scratch" \
  --product gigatoken-smoke
node --no-warnings "$root_directory/Scripts/run-wasi.mjs" \
  "$wasm_scratch/wasm32-unknown-wasip1/release/gigatoken-smoke.wasm"

swiftly run swift +6.3.1 ++ build \
  --swift-sdk swift-6.3.1-RELEASE_wasm-embedded \
  -c release \
  --scratch-path "$embedded_scratch" \
  --product gigatoken-smoke
node --no-warnings "$root_directory/Scripts/run-wasi.mjs" \
  "$embedded_scratch/wasm32-unknown-wasip1/release/gigatoken-smoke.wasm"
