#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$root_directory"

perl -e 'alarm shift; exec @ARGV' 120 \
  xcodebuild test \
    -scheme GigaToken-Package \
    -destination 'platform=macOS' \
    -maximum-test-execution-time-allowance 60

swiftly run swift +6.3.1 ++ run -c release gigatoken-smoke
"$root_directory/Scripts/verify-codegen.sh"
"$root_directory/Scripts/verify-portability.sh"

if [[ $# -eq 2 ]]; then
  "$root_directory/Benchmarks/run-comparison.sh" "$1" "$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [MODEL_PATH INPUT_PATH]" >&2
  exit 64
fi
