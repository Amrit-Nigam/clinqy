#!/bin/zsh
# Asking policy: risk classification, pre-authorisation, autonomy levels, always-allow storage, block lists, ask batching.
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/AskingPolicy.swift Sources/Clinqy/Safety.swift Sources/Clinqy/Config.swift \
  tests/AskingPolicyTests.swift -o "$TEST_DIR/asking-policy-tests"
"$TEST_DIR/asking-policy-tests"
