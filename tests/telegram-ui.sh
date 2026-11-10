#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -enable-bare-slash-regex Sources/Clinqy/TelegramUI.swift tests/TelegramUITests.swift -o "$TEST_DIR/telegram-ui-tests"
"$TEST_DIR/telegram-ui-tests"
