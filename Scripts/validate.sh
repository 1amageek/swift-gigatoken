#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$root_directory/Scripts/swift-toolchain.sh"

cd "$root_directory"
verify_swift64_environment
"$root_directory/Scripts/generate-r50k-parity.py" --check

xcodebuild64_timed test \
  -scheme swift-gigatoken-Package \
  -destination 'platform=macOS' \
  -maximum-test-execution-time-allowance 60

xcodebuild64_timed test \
  -scheme swift-gigatoken-Package \
  -destination 'platform=macOS' \
  -enableAddressSanitizer YES \
  -only-testing:GigaTokenCoreTests/BPEModelTests \
  -maximum-test-execution-time-allowance 60
xcodebuild64_timed test \
  -scheme swift-gigatoken-Package \
  -destination 'platform=macOS' \
  -enableUndefinedBehaviorSanitizer YES \
  -only-testing:GigaTokenCoreTests/BPEModelTests \
  -maximum-test-execution-time-allowance 60
xcodebuild64_timed test \
  -scheme swift-gigatoken-Package \
  -destination 'platform=macOS' \
  -enableThreadSanitizer YES \
  -only-testing:GigaTokenCoreTests/EncoderOwnershipTests \
  -maximum-test-execution-time-allowance 60
echo "native-sanitizers: Address, Undefined Behavior, and Thread Sanitizer gates passed"

swift64_timed run -c release GigaTokenSmoke
"$root_directory/Scripts/verify-codegen.sh"
"$root_directory/Scripts/verify-portability.sh"

if [[ $# -eq 2 ]]; then
  "$root_directory/Benchmarks/run-comparison.sh" "$1" "$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [MODEL_PATH INPUT_PATH]" >&2
  exit 64
fi
