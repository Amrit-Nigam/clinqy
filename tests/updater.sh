#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/Updater.swift tests/UpdaterTests.swift -o "$TEST_DIR/update-tests"
"$TEST_DIR/update-tests"
