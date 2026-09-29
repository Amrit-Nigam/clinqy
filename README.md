# Clinqy

**Your cursor's clingy partner.** Your Mac, on autopilot — and you can watch it work.

Clinqy is a macOS menu-bar assistant that uses your Mac the way you would. Press **⌃⌥**, type or say what you want, and a small glowing companion cursor goes and does it on screen. It clicks the Dock, types into the address bar, ticks the checkboxes and fills the form. It asks you before anything consequential, remembers useful things about you, and can learn a task by watching you do it once.

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
- **Selected text and the clipboard.** Whatever you had highlighted is sent along with your request. With nothing highlighted, something you copied in the last 10 minutes counts as "this" ("translate this", "reply to this", "add this to my tracker"). Clipboard text is only sent when the request points at it, and password-manager copies are never kept.
- **Saved workflows first.** If a request matches a saved workflow (same words, only the typed values differ: "message mom I'm stuck in traffic" vs. the saved "message mom I'll be late"), it's replayed with no model. The model only steps in to heal a step whose target is gone. Turn it off with `WORKFLOW_FIRST=off`.
- **Calendar & Reminders.** Events and reminders go straight through EventKit, with no clicking through Calendar. "Schedule a call with Priya Thursday afternoon" checks your free time and books the first slot that fits.
- **Files.** Finds files through Spotlight: name, content, the site a download came from, who sent it ("the PDF I got from HR last week"). It also renames in bulk, moves files and sorts Downloads into subfolders. Every rename or move can be undone. Deleting only moves to the Trash.
- **Moving data between apps.** It pulls tables out of a web page, a PDF or a CSV and writes them into a CSV, a new Numbers or Excel document, the clipboard (paste into any spreadsheet), or a web form.
- **Dry run.** Toggle **Dry run** in the command bar (or start a request with "dry run:") and the companion points at everything it would click and type, without doing it. Opening apps and sites, scrolling and reading still happen so it can plan the whole path.
- **Follow-ups by voice.** After a spoken task finishes, the mic stays open for 5 s: "now email that to Rahul" builds on what just happened. Silence, "no thanks" or "bas" closes it. `FOLLOW_UP=off` turns it off.
- **Hindi and Hinglish.** Menu → **Voice Language**: Auto-detect, English, Hinglish (Hindi-English written in Latin letters, the way people text) or Hindi. Requests in any of these are understood, and replies and messages keep your style.
- **Never touches your tabs.** Websites open in new tabs. It only reuses tabs it opened itself.

## Requirements

- macOS 14+ on Apple silicon (tested on an M4)
- Swift 5.9+ (Xcode Command Line Tools are enough)
- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude` on your PATH). Clinqy uses your Claude login.
- Chrome, Arc, Brave or Edge for the browser extension (optional but recommended)

## Build & run

```bash
./build.sh run        # builds build/Clinqy.app, signs it, and launches it
```

On first launch, grant the permissions Clinqy asks for (menu bar icon → **Check Permissions…**):

| Permission | Why |
|---|---|
| Accessibility | Read buttons and fields, click and type |
| Screen Recording | Screenshots and OCR when the Accessibility tree isn't enough |
| Microphone & Speech Recognition | Voice input |
| Automation | AppleScript fallback for scriptable apps |
| Calendars & Reminders | Adding and finding events and reminders (asked the first time you schedule something) |

The first voice use downloads the Whisper model (~630 MB) into `~/Library/Application Support/Clinqy/models`.

### Browser extension

1. Open `chrome://extensions` (or `arc://extensions`, `brave://extensions`…).
2. Turn on **Developer mode** and click **Load unpacked**.
3. Pick the `extension/` folder in this repo.

It connects to the app on `ws://127.0.0.1:47823`, and only browser-extension origins are accepted. The app reloads the extension by itself when its version (in `manifest.json`) differs from the one the app was built with; `clinqy extension reload` forces it. Elements in embedded frames (e.g. a Greenhouse form inside a careers page) are listed and driven like the rest.

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

Every link must carry `&token=<~/.config/clinqy/cli-token>` (`?token=` when it has no other parameters): web pages can open `clinqy://` links too, and must not be able to start tasks or answer questions. The `clinqy` command adds it for you.

```
clinqy://run?task=<text>[&test=1][&dry=1]   run a task in the frontmost app (test=1: not saved to history or memory; dry=1: dry run)
clinqy://answer?text=<text>         answer the current question
clinqy://add?text=<text>            add context to the running task
clinqy://cancel                     stop the current task
clinqy://qa?path=<file>|text=<test>&out=<report.json>[&relearn=1][&model=…]
clinqy://workflow?name=<name>[&<input>=<value>…]
clinqy://watch · clinqy://stop-watching
clinqy://reload-extension
clinqy://browser?cmd=page|read|url&id=<id>  what's in the focused browser tab → Application Support/Clinqy/cli/<id>.txt
```

## The `clinqy` command: QA and workflows for any coding agent

`./build.sh` installs `clinqy` to `~/.local/bin`. Any terminal or coding agent (Claude Code, Codex, Cursor…) can call it. It hands the job to the running app, which has the permissions, the browser extension and the cursor.

```bash
clinqy qa tests/qa/                      # run every test in a folder
clinqy qa login.md --json                # one test, machine-readable report
clinqy qa "Go to https://example.com
Expect: Example Domain"                     # inline test
clinqy qa login.md --relearn --model opus
clinqy run "open github"                 # a task (not saved to history)
clinqy run --dry "book a cab home"       # show every click and keystroke, do none
clinqy workflow "Fill form" "Your name=Priya"
clinqy workflows
```

**QA tests** are plain English, one step per line, with an optional `# Title`. Lines starting with **Expect / Check / Verify** are assertions:

```markdown
# Feedback form: name and sessions
Go to http://127.0.0.1:8765/form.html
Type Amrit Nigam as the name
Tick Keynote and Design panel
Expect: the page title shows name=Amrit Nigam
```

- **First run (learn):** the model carries out the test and compiles a **deterministic script** (actions, how to find each target, and checks). It's saved in `.clinqy/` next to the test, so you can commit it.
- **Every run after that (replay):** **no model**. Each step is found by role and label, and each check is "this text is on screen". It's fast (about 4 s for the example), free and repeatable.
- **UI changed? (heal):** if a step can't find its target, the model takes over from there only, the test still reports pass or fail, and the compiled script is updated.
- **Result:** `PASS`/`FAIL` with each check and the steps before a failure. Exit code 0 means everything passed. `--json` gives the full report (name, passed, mode `replay`/`learned`/`healed`, durationMs, steps, checks, message).
- Tests run unattended: the agent never asks questions, doesn't touch History or memory, and loads pages fresh.
- **QA cursor:** during tests the companion becomes an **amber targeting reticle with a "QA" tag**. Checks flash ✓ (green pop) or ✕ (red shake).

**Workflows (routines without a model).** Every successful run records exactly what it did. In **History**, hover a run and click **Save workflow**. Typed text becomes named inputs, defaulting to the original values. Saved workflows appear under **Skills → Workflows**:
- **Run:** replays it with no model.
- **Daily…:** schedules it (for example 09:00, once a day).
- **Delete.**

From the terminal: `clinqy workflow <name> "Input=value"`. A step that breaks is healed by the model, and the workflow is saved with the fix.

**How runs are going.** `Clinqy stats [days]` gives the success rate (overall and per app), the slowest runs, a per-turn breakdown of model time vs action time (from `agent.log`), and the most common failure reasons and failed steps. `Clinqy stats --last` shows the latest run turn by turn.

## MCP server (Claude Code, Codex, Cursor…)

`Clinqy mcp` runs Clinqy as a stdio [MCP](https://modelcontextprotocol.io) server with no extra dependencies. Register it in Claude Code with:

```bash
claude mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp
```

| Tool | Read-only | What it does |
|---|---|---|
| `clinqy_run` | no | Carries out a plain-English task (`task`, optional `dry`, `timeout` in s, default 300) and returns the steps and the final answer. It isn't saved to History or memory. |
| `clinqy_look` | yes | What's in front: the browser tab through the extension (`mode`: `page`, `read` or `url`), or the app's window and controls through Accessibility |
| `clinqy_stats` | yes | The `stats` report (`days`, `last`) |

The server hands tasks to the running app with `clinqy://` links, the same way the `clinqy` command does, and starts the app if it isn't running. It handles one task at a time. If the client cancels a call, the task is stopped in the app.

## Configuration

Optional `KEY=value` lines in `~/.config/clinqy/env`:

| Key | Default | |
|---|---|---|
| `CLAUDE_PATH` | auto-detected | Path to the `claude` CLI |
| `CLAUDE_MODEL` | `sonnet` | Model for the agent |
| `CLAUDE_EFFORT` | `low` | `low` is noticeably faster per step |
| `WHISPER_MODEL` | `large-v3-v20240930_turbo_632MB` | Any WhisperKit variant |
| `VOICE_ENGINE` | whisper | Set `apple` to use only Apple dictation |
| `VOICE_LANGUAGE` | `auto` | `auto`, `en`, `hinglish`, `hi`, or any Whisper code (the menu setting wins) |
| `FAST_MODEL` | `haiku` | Faster model for routine steps; `off` to use only the main model |
| `WORKFLOW_FIRST` | on | `off`: always ask the model, even when a saved workflow matches |
| `FOLLOW_UP` | on | `off`: don't keep the mic open after a spoken task |
| `FAST_AUTO` | on | `off`: the fast model only takes over when the main model plans routine steps |
| `REPLAY_RECORD` | off | `on`: record each run as an offline replay fixture |

### Your data (all local)

| File | What |
|---|---|
| `~/.config/clinqy/memory.md` | Facts Clinqy remembers about you (edit freely, or menu → **Edit Memory…**) |
| `~/Library/Application Support/Clinqy/history.json` | Run history |
| `~/Library/Application Support/Clinqy/skills.json` | Learned skills |
| `~/Library/Application Support/Clinqy/workflows.json` | Saved workflows (and schedules) |
| `~/Library/Application Support/Clinqy/applications.json` | Job applications Clinqy filled or sent |
| `~/Library/Application Support/Clinqy/file-moves/` | Renames/moves it made, for `files undo` |
| `~/Library/Logs/Clinqy/agent.log` | Step-by-step log (secrets masked) |

## Tests

```bash
swift build --build-system native
.build/debug/Clinqy --selftest     # safety rules, reply parsing, stats parsing, replay fixtures, scripting dictionaries
.build/debug/Clinqy replay tests/replay   # recorded runs re-checked offline
tests/run.sh [filter]                 # end-to-end in Chrome against local pages in tests/site
```

**Replay fixtures** (`tests/replay/*.json`) are recorded runs: the page snapshots the extension sent, plus the model's reply for each turn. Replaying them needs no browser, model or screen. Each turn is checked against pure code:
- how the reply is parsed into actions
- which clicks need your OK
- which elements kept or changed their w-id since the previous snapshot (drift)
- what was added, removed or changed
- which field has focus

`expect` holds the known-good answers. `Clinqy replay <file> --bless` writes the current answers into it. To record live runs, set `REPLAY_RECORD=on` in `~/.config/clinqy/env`. Fixtures go to `~/Library/Logs/Clinqy/replays/`. They hold whatever the page showed, so strip personal data before committing one.

`Clinqy watch <app> <text> [--gone] [--timeout s]` waits until text appears in an app, or with `--gone` until it disappears. It listens for Accessibility notifications and falls back to polling. It's handy for checking what `Watch.until` sees.

`tests/run.sh` needs the app running and the extension in Chrome. It opens its own Chrome window and refuses to act unless its test page is in front. It covers:
- checkboxes that only accept real clicks, radio buttons, text fields and dropdowns
- a Pay button, both declined and confirmed
- reading a PDF
- Watch & learn followed by running the learned skill

Test runs aren't saved to History or memory.

Other debug commands: `--run <bundle-id|-> "<task>"` (run from the terminal with a timed log), `--transcribe <audio>`, `--snapshots`, `--reload-extension`, `--click-label/--type/--key` (act like the user).

## How it's built

```
Sources/Clinqy/
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
  Workflow.swift     deterministic workflows (steps + targets), store; replay/heal/QA live in Agent.swift
  Router.swift       before the model: saved-workflow matching, follow-up dismissals
  FastLane.swift     routine steps on a faster model, handed back to the main one on anything risky
  Events.swift       calendar events and reminders (EventKit)
  Files.swift        Spotlight file search, rename/move/organize with undo, trash
  Tables.swift       extract tables and write rows (CSV, Numbers/Excel, clipboard)
  Clipboard.swift    what the user copied recently ("this" when nothing is selected)
  Pdf.swift, Media.swift             PDF and video/audio jobs in the background
  NameHints.swift, MemoryTidy.swift  name-aware voice correction; memory clean-up
  Applications.swift                 job-application tracker
  MCPServer.swift    `Clinqy mcp`: stdio MCP server relaying to the running app
  Watch.swift        wait for text to appear/vanish via AXObserver notifications (polling fallback)
  Stats.swift        `Clinqy stats`: runs.jsonl + per-turn timings from agent.log
  Replay.swift       offline replay of recorded page snapshots + replies (tests/replay)
bin/clinqy        the command-line entry point (qa · run · workflow · workflows)
tests/qa/            example plain-English QA tests (compiled scripts in tests/qa/.clinqy/)
```

## Privacy

Everything except the model calls stays on your Mac. That covers screen reading, voice (Whisper runs locally), memory, history, skills and logs. Requests and screen summaries go to Claude through your own Claude Code login.
