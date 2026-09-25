# CursorBoy

**Your Mac, on autopilot — and you can watch it work.**

CursorBoy is a macOS menu-bar assistant that uses your Mac the way you would. Press **⌃⌥**, type or say what you want, and a small glowing companion cursor goes and does it on screen. It clicks the Dock, types into the address bar, ticks the checkboxes and fills the form. It asks you before anything consequential, remembers useful things about you, and can learn a task by watching you do it once.

```
"book me a flight to Mumbai"         "where's the brightness setting?"
"tick Keynote and Design panel"      "what's the phone number on my resume?"
"message mom I'll be late"           "in the background, add a reminder to call Raj"
```

---

## Features

- **One agent loop.** A long-lived Claude session reads the screen, picks actions, acts, checks the result and repeats until the task is done. Each step takes about 1–2 s.
- **Works like a person.** It opens apps from the Dock (or Spotlight), opens websites by typing into the address bar, types at a human rhythm with real key codes, and clicks for real. Your pointer is put back where it was.
- **Companion cursor.** A glowing blue arrow rides beside your pointer. It flies in arcs to its targets, frames what it's about to use, ripples on click, and floats away when you're idle. It can **mark** things on screen for you with a hand-drawn circle and arrow ("where is…").
- **Sees the whole Mac.**
  - Native apps through the Accessibility tree (Electron apps too).
  - Web pages through a **browser extension**: exact elements, verified typing that survives autofill, dropdowns, reading.
  - Documents through PDFKit, and scans or images through on-device OCR.
  - Scriptable apps through their **AppleScript dictionaries**, used as a fallback or when you ask for "in the background".
- **Voice.** Hold ⌃⌥ and talk. Apple dictation shows a live preview, and **local Whisper** (large-v3 turbo via WhisperKit) writes the final text on-device.
- **Asks when it needs you.** It asks for details, choices and passwords (hidden input), with quick-choice buttons or a voice answer.
- **Safety enforced in code:**
  - Clicks on Pay, Buy, Book, Send, Submit, Delete and similar need your OK, unless you asked for exactly that.
  - It checks with you before acting while you're on a call.
  - A one-click stop sits in the menu bar.
  - A watchdog stops a run that's stuck for 30 s.
- **Result cards.** Options, prices, plans and summaries appear in a card you can copy from.
- **History.** Every run is saved. You can **Continue** from one or **Run again**.
- **Memory.** After each task it keeps lasting facts about you (people, preferences, usual apps). It never saves passwords, card numbers or OTPs.
- **Watch & learn.** Click *Watch & learn*, do a task yourself, and press ⌃⌥ to stop. It becomes a reusable **skill** with fill-in parameters.
- **Selected text.** Whatever you had highlighted is sent along with your request.
- **Never touches your tabs.** Websites open in new tabs. It only reuses tabs it opened itself.

## Requirements

- macOS 14+ on Apple silicon (tested on an M4)
- Swift 5.9+ (Xcode Command Line Tools are enough)
- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude` on your PATH). CursorBoy uses your Claude login.
- Chrome, Arc, Brave or Edge for the browser extension (optional but recommended)

## Build & run

```bash
./build.sh run        # builds build/CursorBoy.app, signs it, and launches it
```

On first launch, grant the permissions CursorBoy asks for (menu bar icon → **Check Permissions…**):

| Permission | Why |
|---|---|
| Accessibility | Read buttons and fields, click and type |
| Screen Recording | Screenshots and OCR when the Accessibility tree isn't enough |
| Microphone & Speech Recognition | Voice input |
| Automation | AppleScript fallback for scriptable apps |

The first voice use downloads the Whisper model (~630 MB) into `~/Library/Application Support/CursorBoy/models`.

### Browser extension

1. Open `chrome://extensions` (or `arc://extensions`, `brave://extensions`…).
2. Turn on **Developer mode** and click **Load unpacked**.
3. Pick the `extension/` folder in this repo.

It connects to the app on `ws://127.0.0.1:47823`, and only browser-extension origins are accepted. After updating the extension files, run `open "cursorboy://reload-extension"` to reload it in every connected browser.

## Using it

| | |
|---|---|
| **⌃⌥** (tap Control + Option together) | Open the command bar |
| **⌃⌥** (hold) | Talk; release to send |
| **⌃⌥** while working | Tap: add context or change the plan mid-task · hold: say it |
| **⏹** (command bar or menu bar) | Stop the current task |
| **Esc** | Close the command bar |
| **Watch & learn** | Record yourself doing a task; ⌃⌥ or ⏹ to stop and learn it |
| **Skills / History** | Footer tabs in the command bar |

### URL scheme (for scripting)

```
cursorboy://run?task=<text>[&test=1]   run a task in the frontmost app (test=1: not saved to history or memory)
cursorboy://answer?text=<text>         answer the current question
cursorboy://add?text=<text>            add context to the running task
cursorboy://cancel                     stop the current task
cursorboy://watch · cursorboy://stop-watching
cursorboy://reload-extension
```

## Configuration

Optional `KEY=value` lines in `~/.config/cursorboy/env`:

| Key | Default | |
|---|---|---|
| `CLAUDE_PATH` | auto-detected | Path to the `claude` CLI |
| `CLAUDE_MODEL` | `sonnet` | Model for the agent |
| `CLAUDE_EFFORT` | `low` | `low` is noticeably faster per step |
| `WHISPER_MODEL` | `large-v3-v20240930_turbo_632MB` | Any WhisperKit variant |
| `VOICE_ENGINE` | whisper | Set `apple` to use only Apple dictation |

### Your data (all local)

| File | What |
|---|---|
| `~/.config/cursorboy/memory.md` | Facts CursorBoy remembers about you (edit freely, or menu → **Edit Memory…**) |
| `~/Library/Application Support/CursorBoy/history.json` | Run history |
| `~/Library/Application Support/CursorBoy/skills.json` | Learned skills |
| `~/Library/Logs/CursorBoy/agent.log` | Step-by-step log (secrets masked) |

## Tests

```bash
swift build --build-system native
.build/debug/CursorBoy --selftest     # safety rules, reply parsing, scripting dictionaries
tests/run.sh [filter]                 # end-to-end in Chrome against local pages in tests/site
```

`tests/run.sh` needs the app running and the extension in Chrome. It opens its own Chrome window and refuses to act unless its test page is in front. It covers:
- checkboxes that only accept real clicks, radio buttons, text fields and dropdowns
- a Pay button, both declined and confirmed
- reading a PDF
- Watch & learn followed by running the learned skill

Test runs aren't saved to History or memory.

Other debug commands: `--run <bundle-id|-> "<task>"` (run from the terminal with a timed log), `--transcribe <audio>`, `--snapshots`, `--reload-extension`, `--click-label/--type/--key` (act like the user).

## How it's built

```
Sources/CursorBoy/
  Agent.swift        the loop: observe → Claude → act → report; actions, asking, history, memory
  AgentPrompt.swift  the system prompt (action vocabulary and rules)
  Brain.swift        persistent `claude -p` stream-json session, pre-warmed
  AXEngine.swift     Accessibility: element trees, focus, typing, key combos
  Hand.swift         human-paced actions: Dock/Spotlight, address bar, clicks, typing
  Buddy.swift        the companion cursor (CoreAnimation overlay per screen)
  UI.swift           command bar, status island, result card, history, skills
  BrowserBridge.swift + extension/   page context and actions via the browser extension
  Reader.swift       documents (PDFKit/AppKit) and OCR (Vision)
  Scripting.swift    AppleScript dictionaries for scriptable apps
  Safety.swift       risky-click confirmation, call detection
  Voice.swift, Whisper.swift         push-to-talk, on-device Whisper
  Recorder.swift, Skills.swift       watch & learn
  History.swift      run history and result cards
```

## Privacy

Everything except the model calls stays on your Mac. That covers screen reading, voice (Whisper runs locally), memory, history, skills and logs. Requests and screen summaries go to Claude through your own Claude Code login.
