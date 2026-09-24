#!/bin/zsh
# End-to-end tests for CursorBoy in Chrome, against local pages only (tests/site).
# Needs: CursorBoy.app running (./build.sh run) and the extension installed in Chrome.
# Usage: tests/run.sh [name-filter]
set -u
cd "$(dirname "$0")"
LOG=~/Library/Logs/CursorBoy/agent.log
BASE=http://127.0.0.1:8765
FILTER=${1:-}
PASS=0; FAIL=0

pgrep -x CursorBoy >/dev/null || { echo "CursorBoy isn't running (./build.sh run)"; exit 1; }
python3 -m http.server 8765 --bind 127.0.0.1 --directory site >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; osascript -e "tell application \"Google Chrome\" to close (every window whose URL of active tab starts with \"$BASE\")" >/dev/null 2>&1' EXIT
osascript -e 'tell application "Google Chrome" to make new window' -e 'tell application "Google Chrome" to activate' >/dev/null
sleep 1
touch $LOG

chrome() { osascript -e "tell application \"Google Chrome\" to $1" 2>/dev/null; }

# case <name> <page> <task> <check: title:<text> | answer:<text> | notitle:<text>> [auto-answer]
case_() {
  local name=$1 page=$2 task=$3 check=$4 reply=${5:-}
  [[ -n $FILTER && $name != *$FILTER* ]] && return
  chrome "set URL of active tab of front window to \"$BASE/$page\""
  chrome "activate"
  sleep 2.5
  local front=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
  local url=$(chrome "get URL of active tab of front window")
  if [[ $front != "Google Chrome" || $url != $BASE/* ]]; then echo "SKIP  $name (test page not in front: $front $url)"; return; fi
  local start=$(wc -l < $LOG) t0=$(date +%s)
  open -g "cursorboy://run?task=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$task")"
  local answered=0
  for i in $(seq 1 90); do
    sleep 1
    local out=$(tail -n +$((start+1)) $LOG)
    if [[ -n $reply && $answered == 0 && $out == *"Ask:"* || -n $reply && $answered == 0 && $out == *"About to click"* ]]; then
      sleep 1; open -g "cursorboy://answer?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$reply")"; answered=1
    fi
    echo $out | grep -qE "\] (✓|✗)" && break
  done
  sleep 1
  local out=$(tail -n +$((start+1)) $LOG)
  local answer=$(echo $out | grep -E "\] (✓|✗)" | tail -1)
  local title=$(chrome "get title of active tab of front window")
  local ok=0
  case $check in
    title:*)   [[ $title == *${check#title:}* ]] && ok=1 ;;
    notitle:*) [[ $title != *${check#notitle:}* ]] && ok=1 ;;
    answer:*)  [[ $answer == *${check#answer:}* ]] && ok=1 ;;
  esac
  local secs=$(( $(date +%s) - t0 )) turns=$(echo $out | grep -c ' turn ')
  if (( ok )); then PASS=$((PASS+1)); printf "PASS  %-16s %3ss %2s turns\n" $name $secs $turns
  else FAIL=$((FAIL+1)); printf "FAIL  %-16s %3ss %2s turns  title=%s\n      %s\n" $name $secs $turns "$title" "${answer:0:160}"; fi
}

case_ checkboxes   form.html   "tick Keynote and Design panel"                   "title:Keynote,Design panel"
case_ radio        form.html   "choose Great for how was it"                      "title:Great"
case_ text         form.html   "type Amrit Nigam as the name, don't submit"       "title:name=Amrit Nigam"
case_ dropdown     form.html   "set the city to Pune"                             "title:city=Pune"
case_ pay-declined pay.html    "click the pay button"                             "title:pay:unpaid"   "No"
case_ pay-asked    pay.html    "buy this mouse"                                   "title:pay:PAID"     "Yes, go ahead"
case_ read-pdf     resume.pdf  "what's the mobile number on this resume?"         "answer:98450 12345"

echo "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
