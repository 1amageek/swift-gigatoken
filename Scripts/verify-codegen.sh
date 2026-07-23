#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "native-codegen: skipped because the host is not ARM64"
  exit 0
fi

cd "$root_directory"
swiftly run swift +6.3.1 ++ build -c release --product swift-gigatoken-benchmark
binary_path=$(swiftly run swift +6.3.1 ++ build -c release --show-bin-path)
binary="$binary_path/swift-gigatoken-benchmark"
fill_symbol=$(
  llvm-nm "$binary" \
    | awk '/R50KPretokenizerV17fillPretokenBatch/ && !found { print $3; found = 1 }'
)
boundary_symbol=$(
  llvm-nm "$binary" \
    | awk '/R50KPretokenizerV12boundaryMask/ && !found { print $3; found = 1 }'
)

if [[ -z "$fill_symbol" || -z "$boundary_symbol" ]]; then
  echo "native-codegen: pretoken batch symbols were not found" >&2
  exit 1
fi

fill_assembly=$(llvm-objdump --disassemble-symbols="$fill_symbol" "$binary")
boundary_assembly=$(llvm-objdump --disassemble-symbols="$boundary_symbol" "$binary")
if grep -q 'SIMD128ByteMaskKernelV6scan64' <<<"$boundary_assembly"; then
  echo "native-codegen: scan64 remained an external hot-loop call" >&2
  exit 1
fi
if ! grep -Eq 'ldp[[:space:]]+q[0-9]+, q[0-9]+,' <<<"$boundary_assembly"; then
  echo "native-codegen: paired NEON input loads were not found" >&2
  exit 1
fi
if ! grep -q 'umaxv.16b' <<<"$boundary_assembly"; then
  echo "native-codegen: NEON ASCII maximum reduction was not found" >&2
  exit 1
fi
if ! grep -q 'addp.16b' <<<"$boundary_assembly"; then
  echo "native-codegen: NEON mask reduction was not found" >&2
  exit 1
fi
if grep -Eq 'stp[[:space:]]+q[0-9]+, q[0-9]+,' <<<"$boundary_assembly"; then
  echo "native-codegen: byte masks were materialized as a vector stack aggregate" >&2
  exit 1
fi
if ! grep -q 'prfm[[:space:]]*pldl2keep' <<<"$fill_assembly"; then
  echo "native-codegen: L2 cache prefetch was not fused into the fill loop" >&2
  exit 1
fi
crc32_count=$(grep -c 'crc32x' <<<"$fill_assembly")
if (( crc32_count < 2 || crc32_count % 2 != 0 )); then
  echo "native-codegen: paired ARM CRC32 hash instructions were not found" >&2
  exit 1
fi
if grep -Eq 'bl[[:space:]].*(ARMCRC32|vector_kernels_crc32)' <<<"$fill_assembly"; then
  echo "native-codegen: ARM CRC32 hash retained a function call" >&2
  exit 1
fi

echo "native-codegen: NEON scan, L2 prefetch, and inlined ARM CRC32 hash verified"
