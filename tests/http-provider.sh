#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
server_pid=""
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT
python3 tests/fake-http-provider.py "$TEST_DIR/port" &
server_pid=$!
for i in {1..100}; do [[ -s "$TEST_DIR/port" ]] && break; sleep .05; done
swiftc -parse-as-library Sources/Clinqy/Providers.swift Sources/Clinqy/AgentPrompt.swift Sources/Clinqy/HTTPRequestBudget.swift Sources/Clinqy/ModelRoute.swift Sources/Clinqy/ModelStream.swift Sources/Clinqy/CodexAppServer.swift Sources/Clinqy/ProcessRunner.swift tests/HTTPProviderTestSupport.swift tests/HTTPProviderTests.swift -o "$TEST_DIR/http-tests"
"$TEST_DIR/http-tests" "http://127.0.0.1:$(cat "$TEST_DIR/port")"
