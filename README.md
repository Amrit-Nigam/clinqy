# Clinqy

**Your cursor's clingy partner.** Your Mac, on autopilot — and you can watch it work.

Clinqy is a macOS menu-bar assistant that uses your Mac the way you would. Press **⌃⌥**, type or say what you want, and a small glowing companion cursor goes and does it on screen. It clicks the Dock, types into the address bar, ticks the checkboxes and fills the form. It asks you before anything consequential, remembers useful things about you, and can learn a task by watching you do it once.

```
"book me a flight to Mumbai"         "where's the brightness setting?"
"tick Keynote and Design panel"      "what's the phone number on my resume?"
"message mom I'll be late"           "in the background, add a reminder to call Raj"
```

## Setup guide

The quickest way to set up Clinqy is to let your AI coding agent do it (Claude Code, Cursor, Codex, Antigravity CLI / agy, Windsurf…).

**1. Fill in the two lines at the top of the prompt**, in plain words:

| If you want to use… | Write after `Model:` |
|---|---|
| Claude Code (your Claude login, the default) | `claude cli` |
| Antigravity CLI / agy (your Google login) | `agy cli` |
| Codex CLI (your ChatGPT login) | `codex cli` |
| An Anthropic / OpenAI / Gemini / OpenRouter key | `anthropic api key`, `openai api key`, `gemini api key` or `openrouter api key` |
| A local model with Ollama | `ollama qwen3-vl` (any vision model) |
| Groq, LM Studio, Together… | `openai-compatible https://api.groq.com/openai/v1 <model>` |
| Not sure | leave it blank, and the agent shows you what's installed and asks |

`Connect to:` lists the coding agents that should be able to use Clinqy: `claude code`, `cursor`, `codex`, `agy cli`, or `none`.

**2. Paste the prompt into your agent:**

````text
Model: claude cli
Connect to: claude code, cursor

Set up Clinqy (https://github.com/Amrit-Nigam/clinqy) on this Mac for me, using the two lines above. Run the
commands yourself. Only stop when you need my answer or a click that only I can do.

1. Check that this Mac has macOS 14+ on Apple silicon and Swift 5.9+. If Swift is missing, run
   `xcode-select --install` and wait for me.
2. If this folder isn't the Clinqy repo, clone it to ~/clinqy and work there.
3. Set up the model from my "Model:" line:
   - Make my settings file from the repo's template:
     `mkdir -p ~/.config/clinqy && cp -n env.example ~/.config/clinqy/env && chmod 600 ~/.config/clinqy/env`
     (if the file already exists, edit it, don't replace it).
   - In it, uncomment the block for my choice in section 1 of env.example. Every option there is listed with
     its KEY=value lines. Leave the rest commented. For a model name, also set CLAUDE_MODEL / AGY_MODEL (or LOCAL_MODEL for
     ollama / openai-compatible).
   - claude/codex/agy cli: check the CLI is installed and logged in. If not, install it with the command in
     env.example and have me log in.
   - API key: don't ask me to paste the key into this chat. Open ~/.config/clinqy/env for me
     (`open -e ~/.config/clinqy/env`), tell me which line to paste the key into, and wait until I've saved it.
     Then check the line has a value, without printing the key.
   - Ollama: run `ollama pull <model>` if needed.
4. Run `./build.sh run`. It builds and installs /Applications/Clinqy.app, adds the `clinqy` command to
   ~/.local/bin and launches the app. Add ~/.local/bin to my PATH if it isn't there.
5. Tell me to open the Clinqy menu-bar icon → Check Permissions… and turn on Accessibility, Screen Recording,
   Microphone and Speech Recognition. Wait for me. If I just turned on Screen Recording, restart Clinqy. The
   "Model:" line in that window should match my choice.
6. Help me load the browser extension: in Chrome, Arc, Brave or Edge, open the extensions page, turn on Developer
   mode, click Load unpacked and choose the repo's `extension/` folder. Give me that folder's full path.
7. Add Clinqy as an MCP server (command `/Applications/Clinqy.app/Contents/MacOS/Clinqy`, argument `mcp`) to
   each agent on my "Connect to:" line. Keep their other servers:
   - claude code: `claude mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp`
   - agy cli: `agy mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp`
   - cursor: ~/.cursor/mcp.json → "mcpServers": {"clinqy": {"command": "/Applications/Clinqy.app/Contents/MacOS/Clinqy", "args": ["mcp"]}}
   - codex: ~/.codex/config.toml → [mcp_servers.clinqy] command = "/Applications/Clinqy.app/Contents/MacOS/Clinqy", args = ["mcp"]
8. Test it: run `clinqy run --dry "open example.com"` and show me the planned steps. Then have me press ⌃⌥
   (Control + Option) and ask "where's the brightness setting?". If something fails, read
   ~/Library/Logs/Clinqy/agent.log and fix it. End with a short summary of what's set up.
````

**Examples of the two lines:**

```text
Model: codex cli
Connect to: cursor, codex
```
```text
Model: openai api key
Connect to: claude code
```
```text
Model: agy cli
Connect to: agy cli, cursor
```
```text
Model: ollama qwen3-vl
Connect to: cursor
```

**Doing it by hand instead?** Copy [`env.example`](env.example) to `~/.config/clinqy/env`, uncomment your model option, then follow [Build & run](#build--run). All the settings are explained in [Choosing the model](#choosing-the-model) and [Configuration](#configuration).

---

## Features

- **One agent loop.** A long-lived Claude session (or Antigravity session with `--agy`) reads the screen, picks actions, acts, checks the result and repeats until the task is done. Each step takes about 1–2 s.
- **Works like a person.** It opens apps from the Dock (or Spotlight), opens websites by typing into the address bar, types at a human rhythm with real key codes, and clicks for real. Your pointer is put back where it was.
- **Clicks that check themselves.**
  - **Checks every click.** After each click it looks for an effect. If nothing changed, it tries the next way: a real mouse click, then a click through the page, then focus plus a key (for checkboxes, tabs and options). It remembers which way works on each site.
  - **Aims carefully.** It waits until the target stops moving, and clicks a spot that isn't covered (a badge over a button's middle).
  - **Re-finds elements.** If the page re-rendered the element, it re-reads the page and finds the same element again, even when a count in its name changed.
  - **Dropdowns.** It searches the list the dropdown opened and scrolls lists that load as you go. Matching is loose ("USA" = "United States", "Sr." = "Senior", "Bangalore" = "Bengaluru"). If the list can't be clicked, it uses the arrow keys.
  - **Uploads.** A file goes into the page's upload field directly, through the site's own upload button (even one that makes its field on the spot), or through the Mac file picker as a last resort.
  - **Apps with few listed elements.** In WhatsApp and other apps that expose little to Accessibility, it clicks text it finds on screen with text recognition.
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
- A model to drive it, one of:
  - [Claude Code](https://claude.com/claude-code), [Codex CLI](https://github.com/openai/codex) or [Antigravity CLI (`agy`)](https://antigravity.google/docs/cli/overview), installed and logged in (your existing login is used), or
  - an API key for Anthropic, OpenAI, Gemini or OpenRouter, or
  - a local model through Ollama or any OpenAI-compatible server.

  See [Choosing the model](#choosing-the-model).
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

`./build.sh` installs `clinqy` to `~/.local/bin`. Any terminal or coding agent (Antigravity CLI, Claude Code, Codex, Cursor…) can call it. It hands the job to the running app, which has the permissions, the browser extension and the cursor.

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

**How runs are going.** `Clinqy stats [days]` gives the success rate (overall and per app), the slowest runs, a per-turn breakdown of model time vs action time (from `agent.log`), and the most common failure reasons and failed steps. `Clinqy stats --last` shows the latest run turn by turn. A **Clicks** section shows how often the first click worked, which fallbacks rescued the rest, and the sites and apps where clicks struggle most. What it learns about each site is kept in `~/Library/Application Support/Clinqy/click-hints.json`.

## MCP server (Claude Code, Antigravity CLI, Codex, Cursor…)

`Clinqy mcp` runs Clinqy as a stdio [MCP](https://modelcontextprotocol.io) server with no extra dependencies. Register it in Claude Code with:

```bash
claude mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp
```

Or in Antigravity CLI (`agy`) with:

```bash
agy mcp add clinqy -- /Applications/Clinqy.app/Contents/MacOS/Clinqy mcp
```

| Tool | Read-only | What it does |
|---|---|---|
| `clinqy_run` | no | Carries out a plain-English task (`task`, optional `dry`, `timeout` in s, default 300) and returns the steps and the final answer. It isn't saved to History or memory. |
| `clinqy_look` | yes | What's in front: the browser tab through the extension (`mode`: `page`, `read` or `url`), or the app's window and controls through Accessibility |
| `clinqy_stats` | yes | The `stats` report (`days`, `last`) |

The server hands tasks to the running app with `clinqy://` links, the same way the `clinqy` command does, and starts the app if it isn't running. It handles one task at a time. If the client cancels a call, the task is stopped in the app.

## Choosing the model

By default Clinqy runs on the Claude Code CLI with your Claude login. To switch to Antigravity CLI (`agy`) with your Google login, pass `--agy` on the command line or set `PROVIDER=agy-cli` (or `USE_AGY=1`) in `~/.config/clinqy/env`. [`env.example`](env.example) has every option ready to uncomment:

| Option | Lines in `~/.config/clinqy/env` |
|---|---|
| Claude Code CLI (default) | nothing, or `PROVIDER=claude-cli` |
| Antigravity CLI (`agy`) | `PROVIDER=agy-cli` or `USE_AGY=1` (or `--agy` flag) |
| Codex CLI | `PROVIDER=codex-cli` |
| Anthropic API | `PROVIDER=anthropic` and `ANTHROPIC_API_KEY=sk-ant-…` |
| OpenAI API | `PROVIDER=openai` and `OPENAI_API_KEY=sk-…` |
| Gemini API | `PROVIDER=gemini` and `GEMINI_API_KEY=…` |
| OpenRouter | `PROVIDER=openrouter` and `OPENROUTER_API_KEY=sk-or-…` |
| Ollama | `PROVIDER=ollama` and `LOCAL_MODEL=qwen3-vl` |
| Any OpenAI-compatible server | `PROVIDER=openai-compatible`, `OPENAI_BASE_URL=…`, `OPENAI_COMPATIBLE_API_KEY=…` and `LOCAL_MODEL=…` |

For example, Antigravity CLI:

```bash
PROVIDER=agy-cli
```

Put each `KEY=value` on its own line, with no comment after the value. `chmod 600 ~/.config/clinqy/env` keeps your keys private.

If `PROVIDER` isn't set, Clinqy uses the `claude` CLI when it's installed (or `agy` when `--agy` or `USE_AGY=1` is set). Without it, Clinqy uses the first API key it finds, then `agy` or Codex CLI.

`CLAUDE_MODEL` / `AGY_MODEL` (the agent) and `FAST_MODEL` (the helper for routine steps) work with every provider. Leave them as `sonnet` / `haiku` / `opus` to get each provider's matching tier, or set any model id the provider accepts:

| Provider | `haiku` (fast) | `sonnet` (agent, default) | `opus` |
|---|---|---|---|
| agy-cli | gemini-3.8-flash (low effort) | gemini-3.8-flash | gemini-3.1-pro |
| anthropic | claude-haiku-4-5 | claude-sonnet-5-5 | claude-opus-5-5 |
| openai | gpt-5.6-luna | gpt-5.6-terra | gpt-5.6-sol |
| gemini | gemini-3.5-flash-lite | gemini-3.6-flash | gemini-3.6-flash |
| openrouter | anthropic/claude-haiku-4.5 | anthropic/claude-sonnet-5.5 | anthropic/claude-opus-5.5 |
| codex-cli | the CLI's default | the CLI's default | the CLI's default |
| ollama, openai-compatible | `LOCAL_MODEL` | `LOCAL_MODEL` | `LOCAL_MODEL` |

Notes:
- **Use a vision model.** Clinqy sometimes sends a screenshot.
- **Speed.** The Claude CLI, the Antigravity CLI (`agy`) and the HTTP APIs keep one conversation per task, so each turn costs only model time. Anthropic replies are prompt-cached, and only the newest screenshot is sent again. Codex CLI has no long-lived chat mode, so it starts once per turn and is noticeably slower.
- **Effort.** `CLAUDE_EFFORT` and `AGY_EFFORT` also set the reasoning effort for models.
- **Rate limits.** The system prompt is about 10k tokens. A free-tier OpenAI account (10k tokens/min) can't fit it on the larger models.
- **Which one is in use.** Menu bar → **Check Permissions…** shows the current provider.

## Configuration

Optional `KEY=value` lines in `~/.config/clinqy/env` (start from [`env.example`](env.example)):

| Key | Default | |
|---|---|---|
| `PROVIDER` | `claude-cli` | Which model service to use (use `agy-cli` or `--agy` / `USE_AGY=1` for Antigravity, see [Choosing the model](#choosing-the-model)) |
| `ANTHROPIC_API_KEY` · `OPENAI_API_KEY` · `GEMINI_API_KEY` · `OPENROUTER_API_KEY` · `OPENAI_COMPATIBLE_API_KEY` | | API keys for the HTTP providers |
| `OPENAI_BASE_URL` | per provider | Endpoint for `openai`, `ollama` or `openai-compatible` |
| `LOCAL_MODEL` | `qwen3-vl` | Model for `ollama` / `openai-compatible` |
| `CLAUDE_PATH` · `AGY_PATH` · `CODEX_PATH` | auto-detected | Path to each CLI |
| `CLAUDE_MODEL` / `AGY_MODEL` | `sonnet` | Model for the agent (any provider) |
| `CLAUDE_EFFORT` / `AGY_EFFORT` | `low` | `low` is noticeably faster per step |
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
- clicks that need more than a centre click (`clicks.html`): a dropdown that loads its options as it scrolls, an upload button that makes its file field on the spot, a button half-covered by a badge, and a button the page keeps re-rendering

Test runs aren't saved to History or memory.

Other debug commands: `--run <bundle-id|-> "<task>"` (run from the terminal with a timed log), `--transcribe <audio>`, `--snapshots`, `--reload-extension`, `--click-label/--type/--key` (act like the user).

## How it's built

```
Sources/Clinqy/
  Agent.swift        the loop: observe → LLM → act → report; actions, asking, history, memory
  AgentPrompt.swift  the system prompt (action vocabulary and rules)
  Brain.swift        persistent `claude` (or `agy` with `--agy`) stream-json session, pre-warmed
  Providers.swift    other model services: Anthropic/OpenAI/Gemini/OpenRouter/Ollama APIs, Claude, Codex & Antigravity (agy) CLI
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
  Stats.swift        `Clinqy stats`: runs.jsonl + per-turn timings and click outcomes from agent.log
  Clicks.swift       click log lines and per-site memory of which way of clicking works
  Replay.swift       offline replay of recorded page snapshots + replies (tests/replay)
bin/clinqy        the command-line entry point (qa · run · workflow · workflows)
tests/qa/            example plain-English QA tests (compiled scripts in tests/qa/.clinqy/)
```

## Privacy

Everything except the model calls stays on your Mac. That covers screen reading, voice (Whisper runs locally), memory, history, skills and logs. Requests and screen summaries go only to the model provider you chose: your Claude, Antigravity (`agy`), or Codex CLI login, the API you gave a key for, or a local model, in which case nothing leaves your Mac.
