# Set up Clinqy on Windows, step by step

Download it, paste one prompt into the AI you already use, and you're done. This guide is the same setup written out
in full, with what you should see at each step and what to do if something goes wrong.

**You need:** Windows 10 (1903 or later) or Windows 11 on x64, and Chrome, Edge or Brave. No admin rights.

**Time:** about 5 minutes. A fresh agent took 4 minutes 11 seconds to work through the whole prompt.

## 1. Download and install

1. Open the [latest release](https://github.com/Amrit-Nigam/clinqy/releases/latest) and download
   **`Clinqy-windows-x64.zip`**.
2. Unzip it. Extract it fully rather than opening it inside the zip window.
3. Double-click **`Install Clinqy.bat`**.

If SmartScreen says it protected your PC, click **More info → Run anyway**. Clinqy isn't code-signed yet, so Windows
doesn't recognise the publisher.

**You should see:**

```text
Installing Clinqy
  App: C:\Users\<you>\AppData\Local\Programs\Clinqy
  Start menu: Clinqy
  Command: clinqy (open a new terminal to use it)

Done. Press Ctrl+Alt to open Clinqy, or hold Ctrl+H to talk.
```

Clinqy starts and its command bar opens. It's now in the Start menu, and `clinqy` works in any **new** terminal.
Terminals that were already open don't know about it yet.

## 2. Paste the setup prompt

Copy the prompt from the [main README](../README.md#setup-on-windows) or the [website](https://clinqy.vercel.app/#setup)
into the AI you use: Claude Code, Codex, agy, Cursor, Gemini CLI, Windsurf, or a plain chat. There's nothing to fill in.

The top two lines are the only settings, and the defaults suit most people:

```text
Model: auto
Connect to: all
```

- **Model** is the AI Clinqy thinks with. `auto` picks the first one you have, in this order: Claude Code, Codex, agy,
  Ollama. To choose one, use `claude`, `codex`, `agy`, `ollama`, `anthropic`, `openai`, `gemini` or `openrouter`.
- **Connect to** is which coding agents get Clinqy's tools. Use `all`, `none`, or names with commas.

Your AI then does the following. If it's a chat with no terminal, it gives you one command at a time to paste instead.

| Step | What happens | Do you need to do anything? |
|---|---|---|
| Install | Installs or updates Clinqy. Clinqy restarts. | No |
| Choose the AI | Finds what this PC has and picks by the order above. | Only if nothing is installed or logged in |
| Browser extension | Clinqy adds it to your browser, using your mouse for a moment. | Don't touch the mouse while it does this |
| Connect agents | Adds Clinqy over MCP to the agents you have. | No |
| Check | Runs `clinqy doctor` and a test task in the background. | No |

**Your AI should finish with a summary like this:**

```text
Clinqy is installed and working. `doctor` shows everything ready, and the test task
("open example.com and tell me the page title") returned "Example Domain".
```

**Restart any coding agent you connected**, or it won't see Clinqy's tools.

## 3. Check it yourself

In a new terminal:

```powershell
clinqy doctor
```

**You should see** these lines. The first shows whichever AI you're using.

```text
- Model — Claude Code CLI: ... · model sonnet
- Browser extension — connected — web pages are read and driven exactly (✓ ready)
- Voice (on-device Whisper) — installed (✓ ready)
```

Voice may say `on first use` instead. That's fine: it downloads the first time you hold Ctrl+H.

Then try a background task:

```powershell
clinqy run --background "open example.com and tell me the page title"
```

**You should see:** `The page title is "Example Domain".` Your mouse, keyboard and windows aren't touched.

## 4. Use it

| | |
|---|---|
| **Tap Ctrl+Alt** | Open the command bar, type a request, press Enter. |
| **Hold Ctrl+H** | Talk. It listens only while you hold the keys. |
| **Gear on the bar** | Open the Clinqy window: AI and model, background tasks, tasks, and every keyboard shortcut. |
| **Background switch on the bar** | Run tasks in a hidden browser while you keep working. |

If a background task needs your screen, a card appears at the top right and waits for you. Choose **Run in foreground**,
**Keep in background** or **Stop task**.

**Open at login is off by default.** To have Clinqy start when you sign in, turn it on under **General** in the Clinqy
window.

## If something goes wrong

**Windows Defender quarantined Clinqy.** Open Windows Security → Virus & threat protection → Protection history, open
the Clinqy entry, and choose **Actions → Allow on device**. Then open Clinqy again. Your settings and history are kept.
Please also [open an issue](https://github.com/Amrit-Nigam/clinqy/issues) so we can report the file to Microsoft.

**`clinqy` isn't recognised.** The terminal was open before you installed. Open a new one, or use the full path:

```powershell
& "$env:LOCALAPPDATA\Programs\Clinqy\clinqy.exe" doctor
```

**Browser extension: not connected.** Check Clinqy is running, because the extension has nothing to connect to without
it. Then run `clinqy extension install`. If that doesn't work, open your browser's extensions page, turn on
**Developer mode**, click **Load unpacked** and pick `%LOCALAPPDATA%\Programs\Clinqy\extension`.

**No AI found, or a CLI isn't logged in.** Install Claude Code with `winget install Anthropic.ClaudeCode`, or run
`claude`, `codex login` or `agy` once in a new terminal to log in. Then run `clinqy setup` again.

**An API key.** Run `clinqy settings`, paste the key into the line it belongs on, and save. Don't paste keys into a chat
with an AI.

**agy shows Clinqy as connected, but its tools don't run.** In normal use, agy asks your permission first. With `agy -p`
it can't ask, so it denies the tool and produces no output. To run it that way, add an allow-rule for Clinqy under
`permissions.allow` in agy's `settings.json`.

**A coding agent can't see Clinqy.** Restart it. To check it's connected, use `claude mcp list` or `agy mcp list`.

**Still stuck?** The log is at `%LOCALAPPDATA%\Clinqy\Logs\agent.log`.

## Update or uninstall

**Update:** download the latest zip and double-click `Install Clinqy.bat` again, or paste the setup prompt again. Your
settings, memory and history are kept.

**Uninstall:** double-click `Uninstall Clinqy.bat` in `%LOCALAPPDATA%\Programs\Clinqy`. This removes the app, its Start
menu shortcut, PATH entry, login item and `clinqy://` links, and keeps your settings and data. To delete those too, run
`uninstall.ps1 -Purge` from the same folder.

## How this guide was tested

Run on 31 October 2026 on Windows 11 with Clinqy for Windows 0.3.0.

| Step | Result |
|---|---|
| Uninstall the previous copy | The app, shortcut and folder were removed |
| Download the zip from the latest-release link | SHA-256 matched the release notes |
| Install and launch | Worked, version 0.3.0 |
| Microsoft Defender during install and first launch | No detections, and a scan of the installed files found no threats |
| Unedited prompt in a fresh Claude Code agent | Finished in 4 min 11 s, with nothing needed from the user |
| `clinqy doctor` | Model, extension and voice all ready |
| Test task in the background | Returned "Example Domain" |
| MCP in Claude Code and agy | Both listed as connected |

**Not covered by this run:**

- **A brand-new PC.** This PC already had an AI logged in, the extension in the browser, and voice downloaded, so those
  first-time steps didn't run. The prompt's "Needs you" path wasn't used.
- **SmartScreen.** The zip was downloaded with PowerShell rather than a browser, so SmartScreen had no reason to appear.
- **A plain chat with no terminal.** The prompt covers it, but it wasn't run this time.
- **Running Clinqy's tools from agy without prompting.** See the agy note above.
