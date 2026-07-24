#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 MODEL_PATH INPUT_PATH" >&2
    exit 64
fi

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
model_path=$1
input_path=$2
results_dir="$package_root/benchmark-results/general"
python_environment="$package_root/.build/python-reference"
iterations=7

mkdir -p "$results_dir"

swiftly run swift +6.3.1 ++ build \
    --package-path "$package_root" \
    -c release \
    --product gigatoken-benchmark
swift_bin_path=$(swiftly run swift +6.3.1 ++ build \
    --package-path "$package_root" \
    -c release \
    --show-bin-path)
CARGO_TARGET_DIR="$package_root/.build/rust-reference" \
    RUSTFLAGS="-C target-cpu=native" \
    cargo +nightly-2026-07-21 -Z profile-rustflags build \
      --release \
      --manifest-path "$package_root/Benchmarks/RustReference/Cargo.toml"

if [ ! -x "$python_environment/bin/python" ]; then
    python3 -m venv "$python_environment"
fi
"$python_environment/bin/python" -m pip install \
    --disable-pip-version-check \
    --quiet \
    --requirement "$package_root/Benchmarks/PythonReference/requirements.txt"

"$swift_bin_path/gigatoken-benchmark" \
    --model "$model_path" \
    --input "$input_path" \
    --iterations "$iterations" \
    > "$results_dir/swift.json"
"$package_root/.build/rust-reference/release/gigatoken-rust-reference-benchmark" \
    --model "$model_path" \
    --input "$input_path" \
    --iterations "$iterations" \
    > "$results_dir/rust.json"
RAYON_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false \
    "$python_environment/bin/python" \
    "$package_root/Benchmarks/PythonReference/benchmark.py" \
    --implementation tiktoken \
    --input "$input_path" \
    --iterations "$iterations" \
    > "$results_dir/tiktoken.json"
RAYON_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false \
    "$python_environment/bin/python" \
    "$package_root/Benchmarks/PythonReference/benchmark.py" \
    --implementation huggingface \
    --input "$input_path" \
    --iterations "$iterations" \
    > "$results_dir/huggingface.json"

read_field() {
    local result_path=$1
    local field=$2
    "$python_environment/bin/python" -c \
      'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
      "$result_path" \
      "$field"
}

swift_tokens=$(read_field "$results_dir/swift.json" tokens)
swift_checksum=$(read_field "$results_dir/swift.json" tokenChecksum)
swift_speed=$(read_field "$results_dir/swift.json" warmMegabytesPerSecond)

printf '%-34s %12s %12s\n' "implementation" "MB/s" "vs Swift"
for implementation in swift rust tiktoken huggingface; do
    result_path="$results_dir/$implementation.json"
    tokens=$(read_field "$result_path" tokens)
    checksum=$(read_field "$result_path" tokenChecksum)
    speed=$(read_field "$result_path" warmMegabytesPerSecond)
    if [[ "$tokens" != "$swift_tokens" || "$checksum" != "$swift_checksum" ]]; then
        echo "$implementation token identity differs from swift-gigatoken" >&2
        exit 1
    fi
    relative=$(awk -v swift="$swift_speed" -v other="$speed" 'BEGIN { print swift / other }')
    printf '%-34s %12.3f %11.2fx\n' "$implementation" "$speed" "$relative"
done
printf 'Token identity: %s %s\n' "$swift_tokens" "$swift_checksum"
echo "Results written to $results_dir"
