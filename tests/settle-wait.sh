#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/SettleWait.swift tests/SettleWaitTests.swift -o "$TEST_DIR/settle-wait"
"$TEST_DIR/settle-wait"
