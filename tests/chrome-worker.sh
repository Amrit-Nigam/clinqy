#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/BackgroundPolicy.swift Sources/Clinqy/ChromeWorker.swift tests/ChromeWorkerTests.swift -o "$TEST_DIR/worker-tests"
"$TEST_DIR/worker-tests"
