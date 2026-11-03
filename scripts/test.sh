#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
test_dir="$(mktemp -d "$PWD/.build/test.XXXXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Sources/PaperCore/*.swift Tests/PaperCoreTests/*.swift -o "$test_dir/smoke-tests"
"$test_dir/smoke-tests"
