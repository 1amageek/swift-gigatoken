#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 MODEL_PATH INPUT_PATH" >&2
    exit 64
fi

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
model_path=$1
input_path=$2
results_dir="$package_root/benchmark-results"

source "$package_root/Scripts/swift-toolchain.sh"
verify_swift64_environment

swift_samples="$(mktemp)"
rust_samples="$(mktemp)"
trap 'rm -f "$swift_samples" "$rust_samples"' EXIT

mkdir -p "$results_dir"

swift64_timed build \
    --package-path "$package_root" \
    -c release \
    --product gigatoken-benchmark
swift_bin_path=$(swift64 build \
    --package-path "$package_root" \
    -c release \
    --show-bin-path)
CARGO_TARGET_DIR="$package_root/.build/rust-reference" \
    RUSTFLAGS="-C target-cpu=native" \
    cargo +nightly-2026-07-21 -Z profile-rustflags build \
      --release \
      --manifest-path "$package_root/Benchmarks/RustReference/Cargo.toml"

swift_binary="$swift_bin_path/gigatoken-benchmark"
rust_binary="$package_root/.build/rust-reference/release/gigatoken-rust-reference-benchmark"

record() {
    local implementation=$1
    local binary=$2
    local result_path=$3
    local sample_path=$4
    "$binary" \
      --model "$model_path" \
      --input "$input_path" \
      --iterations 31 \
      > "$result_path"
    sed -n 's/.*"warmMegabytesPerSecond" *: *\([0-9.]*\).*/\1/p' \
      "$result_path" >> "$sample_path"
    local tokens
    local checksum
    tokens=$(sed -n 's/.*"tokens" *: *\([0-9]*\).*/\1/p' "$result_path")
    checksum=$(sed -n 's/.*"tokenChecksum" *: *"\([^"]*\)".*/\1/p' "$result_path")
    if [[ -z "$tokens" || -z "$checksum" ]]; then
      echo "$implementation produced an incomplete result" >&2
      exit 1
    fi
    printf '%s %s\n' "$tokens" "$checksum" > "$results_dir/$implementation.identity"
}

for run in 1 2 3 4 5 6 7; do
  if (( run % 2 == 1 )); then
    record rust "$rust_binary" "$results_dir/rust.json" "$rust_samples"
    record swift "$swift_binary" "$results_dir/swift.json" "$swift_samples"
  else
    record swift "$swift_binary" "$results_dir/swift.json" "$swift_samples"
    record rust "$rust_binary" "$results_dir/rust.json" "$rust_samples"
  fi
  if ! cmp -s "$results_dir/swift.identity" "$results_dir/rust.identity"; then
    echo "Token identity mismatch" >&2
    exit 1
  fi
done

swift_median=$(sort -n "$swift_samples" | awk 'NR == 4')
rust_median=$(sort -n "$rust_samples" | awk 'NR == 4')
ratio=$(awk -v swift="$swift_median" -v rust="$rust_median" 'BEGIN { print swift / rust }')
identity=$(cat "$results_dir/swift.identity")

printf 'Swift median: %.3f MB/s\n' "$swift_median"
printf 'Rust median: %.3f MB/s\n' "$rust_median"
printf 'Swift/Rust: %.4fx\n' "$ratio"
printf 'Token identity: %s\n' "$identity"
echo "Results written to $results_dir"

if ! awk -v ratio="$ratio" 'BEGIN { exit !(ratio >= 1.0) }'; then
  echo "Performance gate failed: Swift must match or exceed Rust" >&2
  exit 1
fi
