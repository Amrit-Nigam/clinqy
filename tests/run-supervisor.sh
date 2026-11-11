#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/RunSupervisor.swift tests/RunSupervisorTests.swift -o "$TEST_DIR/run-supervisor-tests"
"$TEST_DIR/run-supervisor-tests"
