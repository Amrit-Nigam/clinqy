#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/ControlSocket.swift tests/ControlSocketTests.swift -o "$TEST_DIR/control-socket"
"$TEST_DIR/control-socket"
