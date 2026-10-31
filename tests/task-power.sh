#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/TaskPowerAssertions.swift tests/TaskPowerAssertionTests.swift -o "$TEST_DIR/power-tests"
"$TEST_DIR/power-tests"
