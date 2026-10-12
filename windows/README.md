<p align="center"><img src="../assets/AppIcon.png" alt="" width="112" height="112"></p>

# Clinqy for Windows

The same Clinqy as on the Mac: press **Ctrl+Alt**, type or say what you want, and the small glowing companion
cursor goes and does it on screen. It clicks the taskbar, types into the address bar, ticks the checkboxes and fills
the form, asks you before anything consequential, remembers useful things about you, and can learn a task by
watching you do it once.

It's a native Windows app (Rust: UI Automation, SendInput, Windows OCR, WebView2), not a port of the Swift code, but
it shares everything that matters with the Mac app: the browser extension, the settings file, memory, history,
workflows, skills, the prompt, the `clinqy` command and the MCP server. A workflow or QA test recorded on a Mac
replays on Windows.

## Install

**Requirements:** Windows 10 (1903+) or 11, x64. WebView2 (built into Windows 11 and current Windows 10).

**One line** (in PowerShell): `irm https://github.com/Amrit-Nigam/clinqy/releases/latest/download/install.ps1 | iex`
does steps 1–2 for you. Or by hand:

1. Download `Clinqy-windows-x64.zip` from the [latest release](https://github.com/Amrit-Nigam/clinqy/releases/latest)
   and unzip it.
2. Right-click `install.ps1` → **Run with PowerShell**. No admin rights needed. It installs to
   `%LOCALAPPDATA%\Programs\Clinqy`, adds a Start menu shortcut, puts `clinqy` on your PATH, opens Clinqy at login
   and starts it.
3. Pick a model. With nothing set, Clinqy uses **Claude Code** (`winget install Anthropic.ClaudeCode`, then
   `claude` once to log in). For anything else, tray icon → **Settings (model, keys)…** and uncomment one block.
4. Add the browser extension (Chrome, Edge, Brave…): tray icon → **Browser extension…** opens the folder and the
   extensions page. Turn on *Developer mode*, click *Load unpacked* and pick the folder. Without it Clinqy still
   works in the browser, from screenshots, just less precisely.
5. Check everything: tray icon → **Check setup…**, or `clinqy doctor` in a terminal.

To remove it: `uninstall.ps1` in the install folder (add `-Purge` to delete your settings and data too).

## Using it

| | |
|---|---|
| **Tap Ctrl+Alt** | Open the command bar. Type, press Enter. |
| **Hold Ctrl+Alt** | Talk (on-device Whisper, downloaded the first time). Let go to send. |
| **Ctrl+Alt while it works** | Add to the task or change the plan. |
| **Click the tray icon while it works** | Stop. |
| **Esc** | Close the bar. |

The footer of the bar has the same tools as on the Mac: **Dry run** (it points at everything it would click and
type, without doing it), **Circle** (draw a loop around something on screen and ask about "this"), **Watch & learn**
(do a task once while it watches; it learns it as a skill), **Skills** and **History** (continue, run again, save
as a workflow).

Only the left Alt counts, so AltGr typing (Ctrl+Alt on many keyboards) never opens Clinqy. Another chord:
`HOTKEY=ctrl+win` (or `ctrl+shift`, `alt+win`) in the settings file.

## The `clinqy` command and MCP

Same commands as on the Mac, for terminals and coding agents:

```powershell
clinqy run "open my latest invoice in Downloads and email it to Priya"
clinqy run --dry "turn on dark mode"          # show, don't do
clinqy qa tests\qa\checkout.md                # a QA test (Markdown), learned once then replayed
clinqy workflow "weekly report" week=32
clinqy look                                   # what's on screen, as text
clinqy doctor                                 # what's set up
clinqy mcp                                    # stdio MCP server: clinqy_run, clinqy_look, clinqy_stats
```

`clinqy://` links work as on the Mac (registered by the app).

## Where things are

| | |
|---|---|
| Settings | `%USERPROFILE%\.config\clinqy\env` (same file and keys as the Mac; template: `env.example`) |
| History, memory, workflows, skills, profile | `%APPDATA%\Clinqy` |
| Logs | `%LOCALAPPDATA%\Clinqy\Logs\agent.log` and `runs.jsonl` |
| Voice models | `%LOCALAPPDATA%\Clinqy\voice` |

Everything stays on your PC except the model calls, which go only to the provider you chose. Clinqy's own windows
are kept out of screenshots and screen shares, so it never sees (or shows) itself.

## Build from source

Needs Rust (MSVC toolchain, `rustup default stable-x86_64-pc-windows-msvc`) and the Visual Studio C++ build tools.

```powershell
cd windows
cargo build                                    # debug: target\debug\ClinqyApp.exe and clinqy.exe
cargo test
powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1   # dist\Clinqy-windows-x64.zip
```

A debug build finds the browser extension in the repo's `extension\` folder. To take screenshots *of* Clinqy (for
docs), start it with `CLINQY_CAPTURABLE=1`.

## How it's built

```
windows/
  crates/clinqy-core      the agent: models, prompt, the loop, memory, history, workflows, browser bridge.
                          No OS APIs; talks to the OS through the Platform and Buddy traits.
  crates/clinqy-windows   the Windows layer: UI Automation, input, screen capture, OCR, clipboard, hotkey,
                          the companion cursor, the status island, Circle.
  crates/clinqy-app       ClinqyApp.exe (tray, command bar, result card, voice, Watch & learn) and clinqy.exe
                          (CLI, MCP), talking over a per-user named pipe.
  scripts/                build-release, install, uninstall.
```

The command bar and result card are WebView2 pages styled with the Mac app's exact tokens (`ui/web/shared.css`); the
companion cursor, status island and Circle overlay are drawn natively (tiny-skia on layered windows) so they can be
click-through and never take focus.
