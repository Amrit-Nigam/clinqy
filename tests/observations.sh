#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/ObservationGeometry.swift tests/ObservationGeometryTests.swift -o "$TEST_DIR/observation-tests"
"$TEST_DIR/observation-tests"
