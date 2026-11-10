#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# Usage value types come from Usage.swift; its file-backed store is replaced by a no-op stub (see the stub's comment).
sed '/^enum UsageStore {/,$d' Sources/Clinqy/Usage.swift > "$TEST_DIR/UsageTypes.swift"
find Sources/Clinqy -name '*.swift' ! -name main.swift ! -name Usage.swift | sort > "$TEST_DIR/sources.txt"
mkdir -p "$TEST_DIR/modules"
printf 'module ObjCCatch {\n  header "%s/Sources/ObjCCatch/include/ObjCCatch.h"\n  export *\n}\n' "$PWD" > "$TEST_DIR/modules/module.modulemap"
clang -c -fobjc-arc Sources/ObjCCatch/ObjCCatch.m -I Sources/ObjCCatch/include -o "$TEST_DIR/ObjCCatch.o"
swiftc -parse-as-library $(cat "$TEST_DIR/sources.txt") "$TEST_DIR/UsageTypes.swift" tests/stubs/UsageStoreStub.swift \
  tests/AppLayerTests.swift "$TEST_DIR/ObjCCatch.o" -I "$TEST_DIR/modules" \
  -framework Carbon -framework ApplicationServices -o "$TEST_DIR/app-layer-tests"
CLINQY_FAKE_ACP="$PWD/tests/fake-acp-server.py" "$TEST_DIR/app-layer-tests"
