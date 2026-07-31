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
run_identifier=$(date -u +%Y%m%dT%H%M%SZ)
run_results_dir="$results_dir/strict-$run_identifier"

source "$package_root/Scripts/swift-toolchain.sh"
verify_swift64_environment

mkdir -p "$run_results_dir"
swift_samples="$run_results_dir/swift.samples"
rust_samples="$run_results_dir/rust.samples"
sample_log="$run_results_dir/samples.tsv"
: > "$swift_samples"
: > "$rust_samples"
printf 'pair\torder\timplementation\tmegabytes_per_second\ttokens\tchecksum\n' > "$sample_log"

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

active_build_processes() {
    ps -Ao pid=,pcpu=,comm= \
      | awk '
          {
            name = $3
            sub(/^.*\//, "", name)
            if ($2 + 0 >= 1.0 && name ~ /^(xcodebuild|SWBBuildService|swift-build|swift-frontend|swift-driver|clang|clang\+\+|rustc|cargo)$/) {
              printf "%s:%s(%.1f%%)\n", name, $1, $2
            }
          }
        '
}

wait_for_quiet_host() {
    local attempt=0
    local quiet_observations=0
    local active_processes
    while (( attempt < 60 )); do
      active_processes=$(active_build_processes)
      if [[ -z "$active_processes" ]]; then
        quiet_observations=$((quiet_observations + 1))
        if (( quiet_observations == 5 )); then
          return
        fi
      else
        quiet_observations=0
      fi
      sleep 1
      attempt=$((attempt + 1))
    done
    echo "Benchmark host remained busy for 60 seconds:" >&2
    echo "$active_processes" >&2
    return 75
}

require_quiet_host() {
    local active_processes
    active_processes=$(active_build_processes)
    if [[ -n "$active_processes" ]]; then
      echo "Benchmark invalidated by concurrent build activity:" >&2
      echo "$active_processes" >&2
      return 75
    fi
}

{
  printf 'run=%s\n' "$run_identifier"
  printf 'swift_binary_sha256=%s\n' "$(shasum -a 256 "$swift_binary" | awk '{print $1}')"
  printf 'rust_binary_sha256=%s\n' "$(shasum -a 256 "$rust_binary" | awk '{print $1}')"
  printf 'model_sha256=%s\n' "$(shasum -a 256 "$model_path" | awk '{print $1}')"
  printf 'input_sha256=%s\n' "$(shasum -a 256 "$input_path" | awk '{print $1}')"
  if command -v pmset >/dev/null 2>&1; then
    printf 'power_source=%s\n' "$(pmset -g batt | sed -n '1p')"
  fi
} > "$run_results_dir/manifest.txt"

wait_for_quiet_host

record() {
    local implementation=$1
    local binary=$2
    local result_path=$3
    local sample_path=$4
    local pair=$5
    local order=$6
    require_quiet_host
    "$binary" \
      --model "$model_path" \
      --input "$input_path" \
      --iterations 31 \
      > "$result_path"
    require_quiet_host
    local throughput
    sed -n 's/.*"warmMegabytesPerSecond" *: *\([0-9.]*\).*/\1/p' \
      "$result_path" >> "$sample_path"
    throughput=$(tail -n 1 "$sample_path")
    local tokens
    local checksum
    tokens=$(sed -n 's/.*"tokens" *: *\([0-9]*\).*/\1/p' "$result_path")
    checksum=$(sed -n 's/.*"tokenChecksum" *: *"\([^"]*\)".*/\1/p' "$result_path")
    if [[ -z "$tokens" || -z "$checksum" ]]; then
      echo "$implementation produced an incomplete result" >&2
      exit 1
    fi
    printf '%s %s\n' "$tokens" "$checksum" > "$run_results_dir/$implementation.identity"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pair" "$order" "$implementation" "$throughput" "$tokens" "$checksum" \
      >> "$sample_log"
}

for run in 1 2 3 4 5 6 7; do
  if (( run % 2 == 1 )); then
    record rust "$rust_binary" "$run_results_dir/pair-$run-rust.json" "$rust_samples" "$run" 1
    record swift "$swift_binary" "$run_results_dir/pair-$run-swift.json" "$swift_samples" "$run" 2
  else
    record swift "$swift_binary" "$run_results_dir/pair-$run-swift.json" "$swift_samples" "$run" 1
    record rust "$rust_binary" "$run_results_dir/pair-$run-rust.json" "$rust_samples" "$run" 2
  fi
  if ! cmp -s "$run_results_dir/swift.identity" "$run_results_dir/rust.identity"; then
    echo "Token identity mismatch" >&2
    exit 1
  fi
done

swift_median=$(sort -n "$swift_samples" | awk 'NR == 4')
rust_median=$(sort -n "$rust_samples" | awk 'NR == 4')
ratio=$(awk -v swift="$swift_median" -v rust="$rust_median" 'BEGIN { print swift / rust }')
common_mode_drift=$(
  paste "$swift_samples" "$rust_samples" \
    | awk '
        NR == 1 { minimum = maximum = sqrt($1 * $2) }
        {
          common = sqrt($1 * $2)
          if (common < minimum) minimum = common
          if (common > maximum) maximum = common
        }
        END { print maximum / minimum - 1 }
      '
)
identity=$(cat "$run_results_dir/swift.identity")

printf 'Swift median: %.3f MB/s\n' "$swift_median"
printf 'Rust median: %.3f MB/s\n' "$rust_median"
printf 'Swift/Rust: %.4fx\n' "$ratio"
printf 'Common-mode drift: %.2f%%\n' "$(awk -v drift="$common_mode_drift" 'BEGIN { print drift * 100 }')"
printf 'Token identity: %s\n' "$identity"
echo "Results written to $run_results_dir"

if ! awk -v drift="$common_mode_drift" 'BEGIN { exit !(drift <= 0.05) }'; then
  echo "Benchmark environment invalid: paired common-mode drift exceeded 5%" >&2
  exit 75
fi

if ! awk -v ratio="$ratio" 'BEGIN { exit !(ratio >= 1.0) }'; then
  echo "Performance gate failed: Swift must match or exceed Rust" >&2
  exit 1
fi
