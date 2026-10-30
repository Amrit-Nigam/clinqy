#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/CodexAppServer.swift tests/CodexAppServerTests.swift -o "$TEST_DIR/codex-tests"
"$TEST_DIR/codex-tests"
