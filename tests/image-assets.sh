#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/ImageAsset.swift tests/ImageAssetTests.swift -o "$TEST_DIR/image-tests"
"$TEST_DIR/image-tests"
