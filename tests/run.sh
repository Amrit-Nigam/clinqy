#!/bin/zsh
# End-to-end tests for Clinqy in Chrome, against local pages only (tests/site).
# Needs: Clinqy.app running (./build.sh run) and the extension installed in the browser under test.
# Usage: tests/run.sh [name-filter]          CLINQY_BROWSER=Arc tests/run.sh  (default: Google Chrome)
set -u
cd "$(dirname "$0")"
LOG=~/Library/Logs/Clinqy/agent.log
BASE=http://127.0.0.1:8765
FILTER=${1:-}
BROWSER=${CLINQY_BROWSER:-Google Chrome}
PASS=0; FAIL=0

pgrep -x Clinqy >/dev/null || { echo "Clinqy isn't running (./build.sh run)"; exit 1; }
python3 -m http.server 8765 --bind 127.0.0.1 --directory site >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; osascript -e "tell application \"$BROWSER\" to close (every window whose URL of active tab starts with \"$BASE\")" >/dev/null 2>&1
      [[ $BROWSER == Arc ]] && osascript -e "tell application \"Arc\" to tell front window to close (every tab whose URL starts with \"$BASE\")" >/dev/null 2>&1' EXIT
chrome() { osascript -e "tell application \"$BROWSER\" to $1" 2>/dev/null; }
frontmost() { osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'; }
# Open a test page. Arc ignores setting a tab's URL by script, so it gets a new tab each time.
goto() {
  if [[ $BROWSER == Arc ]]; then chrome "tell front window to make new tab with properties {URL:\"$1\"}" >/dev/null
  else chrome "set URL of active tab of front window to \"$1\""; fi
}
# Bring the browser forward and wait until it really is (macOS ignores AppleScript "activate" from background scripts).
front_chrome() {
  for i in 1 2 3 4 5 6; do
    open -a "$BROWSER"; sleep 0.5
    [[ $(frontmost) == "$BROWSER" ]] && return 0
  done
  return 1
}
chrome "make new window" >/dev/null
front_chrome || { echo "Couldn't bring $BROWSER to the front"; exit 1; }
sleep 1
touch $LOG


# case <name> <page> <task> <check: title:<text> | answer:<text> | notitle:<text>> [auto-answer]
case_() {
  local name=$1 page=$2 task=$3 check=$4 reply=${5:-}
  [[ -n $FILTER && $name != *$FILTER* ]] && return
  goto "$BASE/$page"
  front_chrome
  sleep 2
  local front=$(frontmost)
  local url=$(chrome "get URL of active tab of front window")
  if [[ $front != "$BROWSER" || $url != $BASE/* ]]; then echo "SKIP  $name (test page not in front: $front $url)"; return; fi
  local start=$(wc -l < $LOG) t0=$(date +%s)
  open -g "clinqy://run?task=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$task")&test=1&token=$(cat ~/.config/clinqy/cli-token)"
  local answered=0
  for i in $(seq 1 90); do
    sleep 1
    local out=$(tail -n +$((start+1)) $LOG)
    if [[ -n $reply && $answered == 0 && $out == *"Ask:"* || -n $reply && $answered == 0 && $out == *"About to click"* ]]; then
      sleep 1; open -g "clinqy://answer?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$reply")&token=$(cat ~/.config/clinqy/cli-token)"; answered=1
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
case_ multiline-chat editor.html "in the Message box, write a 4-stop train schedule, one stop per line, but don't send it" "title:msgMultiline=true|sent=0"
case_ code-editor  monaco.html "replace the code in this editor with a Python solution to Two Sum using a dictionary" "title:indented=true|oneLine=false"

# Watch & learn: act like the user (real input via the debug binary), learn a skill, then run it with new values.
watch_learn() {
  [[ -n $FILTER && watch-learn != *$FILTER* ]] && return
  local B=../.build/debug/Clinqy
  [[ -x $B ]] || { echo "SKIP  watch-learn (swift build first)"; return; }
  local SK=~/Library/Application\ Support/Clinqy/skills.json
  local before=$(python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Clinqy/skills.json');print(len(json.load(open(p))) if os.path.exists(p) else 0)")
  goto "$BASE/form.html"; front_chrome; sleep 2
  # Never type into whatever else is in front (an editor, a terminal).
  [[ $(frontmost) == "$BROWSER" ]] || { echo "SKIP  watch-learn ($BROWSER not in front: $(frontmost))"; return; }
  open -g "clinqy://watch?token=$(cat ~/.config/clinqy/cli-token)"; sleep 1.5
  $B --click-label "Your name" >/dev/null && sleep 0.4 && $B --type "Amrit Nigam"; sleep 0.4
  $B --click-label "Keynote" >/dev/null; sleep 0.4; $B --click-label "Great" >/dev/null; sleep 0.6
  open -g "clinqy://stop-watching?token=$(cat ~/.config/clinqy/cli-token)"
  local name=""
  for i in $(seq 1 30); do sleep 1
    name=$(python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Clinqy/skills.json');d=json.load(open(p)) if os.path.exists(p) else [];print(d[0]['name'] if len(d)>$before else '')")
    [[ -n $name ]] && break
  done
  if [[ -z $name ]]; then FAIL=$((FAIL+1)); echo "FAIL  watch-learn      no skill learned"; return; fi
  case_ skill-run form.html "Use the skill “$name”." "title:name=Priya" "name Priya, session Swift workshop, rating Okay"
  # Leave the user's skills as they were.
  python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Clinqy/skills.json');d=json.load(open(p));json.dump([s for s in d if s['name']!='$name'],open(p,'w'))"
  PASS=$((PASS+1)); echo "PASS  watch-learn      learned “$name”"
}
watch_learn

# The clinqy command: learn a QA test, then it must replay with no model.
qa_cli() {
  [[ -n $FILTER && qa-cli != *$FILTER* ]] && return
  goto "$BASE/form.html"; front_chrome; sleep 2   # a fresh form, not one an earlier case filled
  local out
  out=$(../bin/clinqy qa qa/feedback-form.md --relearn 2>&1 | head -1)
  if [[ $out != PASS* ]]; then FAIL=$((FAIL+1)); echo "FAIL  qa-learn         $out"; return; fi
  PASS=$((PASS+1)); echo "PASS  qa-learn         ${out#PASS  }"
  out=$(../bin/clinqy qa qa/feedback-form.md 2>&1 | head -1)
  if [[ $out == PASS*"(replay"* ]]; then PASS=$((PASS+1)); echo "PASS  qa-replay        ${out#PASS  }"
  else FAIL=$((FAIL+1)); echo "FAIL  qa-replay        $out"; fi
}
qa_cli

echo "\n$PASS passed, $FAIL failed"
(( FAIL == 0 ))
