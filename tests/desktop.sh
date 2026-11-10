#!/bin/zsh
# End-to-end tests for Clinqy in a native app (TextEdit): typing, menus by path, window control, waiting.
# Needs: Clinqy.app running. Opens its own TextEdit documents and closes only those documents, without saving.
# Usage: CLINQY_DESKTOP_TESTS=1 tests/desktop.sh [name-filter]
#
# This is a live test. Every task goes to the model Clinqy is configured with, and it types into TextEdit documents.
# It refuses to run unless CLINQY_DESKTOP_TESTS=1 is set, and it is not part of CI.
# Limits: the script's own document operations are targeted by document ID. The AI agent still chooses which document
# and window to act on for each task, so agent actions and window targeting are not fully isolated from other windows.
# The explicit schedule scenario and the close-without-saving scenario were removed. The AI agent's actions during a
# live run are not isolated, so this script cannot rule out effects on the user's data.
set -u
cd "$(dirname "$0")"
if [[ ${CLINQY_DESKTOP_TESTS:-} != 1 ]]; then
  echo "tests/desktop.sh is a live test (real model calls, TextEdit, your Clinqy app). Set CLINQY_DESKTOP_TESTS=1 to run it."
  exit 2
fi
LOG=~/Library/Logs/Clinqy/agent.log
FILTER=${1:-}
PASS=0; FAIL=0
TOKEN=$(cat ~/.config/clinqy/cli-token)
B=/Applications/Clinqy.app/Contents/MacOS/Clinqy

pgrep -x Clinqy >/dev/null || { echo "Clinqy isn't running (./build.sh run)"; exit 1; }
te() { osascript -e "tell application \"TextEdit\" to $1" 2>/dev/null; }
frontmost() { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'; }
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
# Only the TextEdit documents this script created are closed, by id. The user's other documents and TextEdit itself
# are left alone (the script used to close every document and quit TextEdit, discarding unsaved work).
TEST_DOCS=()
cleanup() { for d in $TEST_DOCS; do te "close (first document whose id is $d) saving no" >/dev/null; done; }
trap cleanup EXIT

# Document operations name the test document by id. The id comes from the same AppleScript call that creates the
# document, so it can't be another window's; "front document" is never used, since the user can change focus.
new_doc() { te "id of (make new document)"; }
doc_text() { te "text of (first document whose id is $1)"; }
set_doc_text() { te "set text of (first document whose id is $1) to \"$2\"" >/dev/null; }

# A fresh TextEdit document in front, with optional starting text.
# Every scenario calls this before it sends a task. If the document can't be created, or TextEdit can't be brought to
# the front, the whole run stops here: no task is sent, and the EXIT trap closes any document already created.
fresh_doc() {
  local id; id=$(new_doc)
  if [[ ! $id =~ ^[0-9]+$ ]]; then
    echo "FAIL  could not create a TextEdit document (got '$id'); no task was sent" >&2
    exit 1
  fi
  TEST_DOCS+=($id)
  if [[ -n ${1:-} ]]; then
    set_doc_text $id "$1"
    [[ $(doc_text $id) == "$1" ]] || { echo "FAIL  could not set the test document text; no task was sent" >&2; exit 1; }
  fi
  for i in 1 2 3 4 5 6; do open -a TextEdit; sleep 0.5; [[ $(frontmost) == TextEdit ]] && return 0; done
  echo "FAIL  TextEdit did not come to the front; no task was sent" >&2
  exit 1
}

# run <task> → sets ANSWER (the final ✓/✗ line) and RUN_TURNS; waits up to 120 s.
run() {
  local start=$(wc -l < $LOG)
  open -g "clinqy://run?task=$(enc "$1")&test=1&token=$TOKEN"
  for i in $(seq 1 120); do
    sleep 1
    tail -n +$((start+1)) $LOG | grep -qE "\] (✓|✗)" && break
  done
  sleep 1
  RUN_OUT=$(tail -n +$((start+1)) $LOG)
  RUN_TURNS=$(echo $RUN_OUT | grep -c ' turn ')
  ANSWER=$(echo $RUN_OUT | grep -E "\] (✓|✗)" | tail -1)
}

result() {   # result <name> <ok 0/1> <detail>
  if (( $2 )); then PASS=$((PASS+1)); printf "PASS  %-16s %2s turns\n" $1 ${RUN_TURNS:-0}
  else FAIL=$((FAIL+1)); printf "FAIL  %-16s %2s turns  %s\n" $1 ${RUN_TURNS:-0} "${3:0:200}"; fi
}

want() { [[ -z $FILTER || $1 == *$FILTER* ]]; }

if want type; then
  fresh_doc
  run "type 'Hello from Clinqy — café €5' into this TextEdit document"; answer=$ANSWER
  text=$(doc_text ${TEST_DOCS[-1]})
  [[ $text == *"Hello from Clinqy — café €5"* ]]; result type $(( $? == 0 )) "text=$text · $answer"
fi

if want window; then
  fresh_doc "window test"
  run "resize this TextEdit window to 700 by 450"; answer=$ANSWER
  b=$(te "get bounds of front window")   # left, top, right, bottom
  w=$(echo $b | awk -F', ' '{print $3-$1}'); h=$(echo $b | awk -F', ' '{print $4-$2}')
  (( w >= 690 && w <= 710 && h >= 440 && h <= 460 )); result window $(( $? == 0 )) "size=${w}x${h} · $answer"
fi

if want menu; then
  fresh_doc "menu test"
  run "in TextEdit, open Format > Font > Show Fonts"; answer=$ANSWER
  wins=$(osascript -e 'tell application "System Events" to get name of every window of process "TextEdit"' 2>/dev/null)
  [[ $wins == *Font* ]]; result menu $(( $? == 0 )) "windows=$wins · $answer"
  osascript -e 'tell application "System Events" to tell process "TextEdit" to click (first button of (first window whose name contains "Font") whose subrole is "AXCloseButton")' >/dev/null 2>&1
fi

if want watch-cli; then
  fresh_doc "the build finished"
  RUN_TURNS=0
  $B watch TextEdit "build finished" --timeout 5 >/dev/null 2>&1; found=$?
  $B watch TextEdit "never appears here" --timeout 2 >/dev/null 2>&1; missing=$?
  (( found == 0 && missing != 0 )); result watch-cli $(( $? == 0 )) "found=$found missing=$missing"
fi

if want wait-native; then
  fresh_doc "Status: working"
  # The text changes 6 s after the task starts, so the agent must wait for it rather than read it right away.
  # The edit goes to the document created above, by id, even if focus has moved to another window by then.
  wait_doc=${TEST_DOCS[-1]}
  ( sleep 6; set_doc_text $wait_doc "Status: done, code QX-2081" ) &
  run "wait until this TextEdit document says done, then tell me the code in it"; answer=$ANSWER
  [[ $answer == *QX-2081* ]]; result wait-native $(( $? == 0 )) "$answer"
fi

if want restore-front; then
  fresh_doc
  # Start from another app: when the task is done, that app should be in front again.
  osascript -e 'tell application "Finder" to activate' >/dev/null; sleep 1
  run "type 'restore check' into the open TextEdit document"; answer=$ANSWER
  sleep 1
  text=$(doc_text ${TEST_DOCS[-1]}); front=$(frontmost)
  [[ ${text:l} == *"restore check"* && $front == Finder ]]; result restore-front $(( $? == 0 )) "front=$front text=$text · $answer"
fi

# The schedule scenario ("remind me every weekday…") is intentionally absent: it writes a real entry to the user's
# schedules.json, and this script can't isolate that file yet (the app has no data-directory override).

if want mcp; then
  RUN_TURNS=0
  out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"clinqy_look","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"clinqy_run","arguments":{"task":"what is the name of the frontmost app? just answer"}}}' | $B mcp 2>/dev/null)
  look=$(print -r -- "$out" | python3 -c 'import sys,json
for l in sys.stdin:
    m=json.loads(l)
    if m.get("id")==2: print(m["result"]["content"][0]["text"][:80].replace("\n"," "))')
  ran=$(print -r -- "$out" | python3 -c 'import sys,json
for l in sys.stdin:
    m=json.loads(l)
    if m.get("id")==3: print(("ERR " if m["result"].get("isError") else "")+m["result"]["content"][0]["text"][-120:].replace("\n"," "))')
  [[ -n $look && -n $ran && $ran != ERR* ]]; result mcp $(( $? == 0 )) "look=$look | run=$ran"
fi

echo "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
