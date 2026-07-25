#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$root_directory/Scripts/swift-toolchain.sh"

cd "$root_directory"
verify_swift64_environment

xcodebuild64_timed test \
  -scheme swift-gigatoken-Package \
  -destination 'platform=macOS' \
  -maximum-test-execution-time-allowance 60

swift64_timed run -c release GigaTokenSmoke
"$root_directory/Scripts/verify-codegen.sh"
"$root_directory/Scripts/verify-portability.sh"

if [[ $# -eq 2 ]]; then
  "$root_directory/Benchmarks/run-comparison.sh" "$1" "$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [MODEL_PATH INPUT_PATH]" >&2
  exit 64
fi
