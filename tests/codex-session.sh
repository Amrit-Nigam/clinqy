#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/CodexAppServer.swift tests/CodexAppServerTests.swift -o "$TEST_DIR/codex-tests"
"$TEST_DIR/codex-tests"
swiftc -parse-as-library Sources/Clinqy/ModelRoute.swift tests/ModelRouteTests.swift -o "$TEST_DIR/route-tests"
"$TEST_DIR/route-tests"
swiftc -parse-as-library Sources/Clinqy/ScreenshotAcknowledgement.swift tests/ScreenshotAcknowledgementTests.swift -o "$TEST_DIR/screenshot-tests"
"$TEST_DIR/screenshot-tests"
swiftc -parse-as-library Sources/Clinqy/Brain.swift Sources/Clinqy/ScreenshotAcknowledgement.swift tests/BrainTestSupport.swift tests/BrainSessionTests.swift -o "$TEST_DIR/brain-tests"
"$TEST_DIR/brain-tests"
