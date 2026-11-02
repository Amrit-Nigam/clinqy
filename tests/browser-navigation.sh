#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/BrowserNavigation.swift tests/BrowserNavigationTests.swift -o "$TEST_DIR/navigation-tests"
"$TEST_DIR/navigation-tests"
