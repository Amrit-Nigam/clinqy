#!/bin/zsh
# Live Phase 0.2/0.3 probe (not CI): a front fixture counts focus intrusion while Clinqy's SkyLight click and
# keyboard session drive TextEdit behind it. Needs Accessibility (and Screen Recording for capture timings).
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/Config.swift Sources/Clinqy/NativeInputTiming.swift Sources/Clinqy/SkyLight.swift Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/TaskContext.swift Sources/Clinqy/ObservationGeometry.swift Sources/Clinqy/NativeWindowObservation.swift Sources/Clinqy/AXEngine.swift Sources/Clinqy/AXTreeBudget.swift Sources/Clinqy/InputPlan.swift Sources/Clinqy/Clipboard.swift tests/FocusIntrusionProbe.swift -o "$TEST_DIR/focus-intrusion-probe"
"$TEST_DIR/focus-intrusion-probe"
