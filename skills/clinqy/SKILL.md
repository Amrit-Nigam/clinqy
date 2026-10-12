---
name: clinqy
description: |
  Use the user's own browser and Mac through Clinqy (their macOS agent app + browser extension) from any project.
  Read what's on their current browser tab (including pages behind their logins, and forms embedded in other
  sites), check how a local dev page actually renders, run UI tests of a web app in the real browser, or have
  Clinqy carry out an on-screen task (fill a form, click through a flow, open an app). Triggers on: "check my
  browser", "what's on my screen/tab", "look at the page I have open", "test this in the browser", "try it in
  Chrome/Arc", "does the page show…", "fill this form", "click through…", "UI test", "clinqy".
---

# Clinqy: the user's real browser and Mac, from the terminal

Clinqy is the user's own agent app (menu-bar app + a browser extension in their Chrome/Arc/Brave). The `clinqy`
command (on PATH at `~/.local/bin/clinqy`) talks to it. It works on the user's **real** browser session: their
tabs, their logins, their screen.

## Read-only (safe any time)

```bash
clinqy page          # the focused tab: title, URL, every visible element as w<N> role: label [value, checked, required,
                     # "in “question”", "inside <site>" for embedded forms], messages (errors), visible text,
                     # and how many fields are above/below the visible part
clinqy page read     # the whole page's text (main content), including embedded forms
clinqy page url      # just the title and URL
clinqy stats [days]  # Clinqy's own success rate / speed (for work on Clinqy itself)
```

Use `clinqy page` instead of guessing when you need to know what the user sees: an error on their dev server
page, what a logged-in dashboard shows, whether a deploy is live, the exact labels of a form. It reads only the
visible part: ask the user to scroll (or use `page read` for text). If it prints `ERROR:` the browser isn't open
or the extension isn't connected. Say so and move on.

## Doing things on screen (ask first)

```bash
clinqy run "<task in plain words>"   # Clinqy does it on the user's screen, like a person (moves the mouse, types)
```

- This takes over the user's mouse and keyboard while it runs. **Tell the user before running it**, and
  don't run it while they're typing elsewhere.
- Never use it to submit, send, pay, post, delete or change settings unless the user explicitly asked for exactly
  that. Clinqy also asks the user on screen before consequential clicks; don't try to work around that.
- Output: the steps it took and ✓/✗ with its final answer; exit code 0 = succeeded. A long task carries on by
  itself when it runs out of steps, and the command waits through that to the real end.
- `clinqy run --test "<task>"` for a throwaway run (checking a page, trying a flow): not saved to Clinqy's history
  and it doesn't carry on by itself.
- Good uses: "open http://localhost:3000/signup and fill it with test data, then show me the errors",
  "in the open tab, click through the checkout to the payment page and stop there".

## UI tests in the real browser (for web projects)

```bash
clinqy qa tests/ui/login.md        # a test file: optional "# Title", then one step per line;
clinqy qa "open localhost:3000 · log in as test@x.com / pw · Expect the dashboard shows Welcome"
clinqy qa tests/ui/ --json         # a whole folder, machine-readable report
```

Lines starting with Expect/Check/Verify are assertions. The first run uses the model and saves a deterministic
script in `.clinqy/` next to the test; later runs replay it without the model and only re-learn broken steps
(`--relearn` forces it). Exit code 0 = all passed. Good for checking a UI change end to end after editing code;
commit the `.md` tests, and the `.clinqy/` scripts if the user wants fast replays in CI-like runs.

## Troubleshooting

- `No answer from Clinqy` / `isn't connected`: open the browser; the extension is loaded unpacked from the
  Clinqy repo's `extension/` folder. `clinqy extension reload` reloads it from disk.
- Clinqy not running: `clinqy` starts it (`open -b com.amritnigam.clinqy`).
- `clinqy://` links need the token in `~/.config/clinqy/cli-token` (owner-only). The `clinqy` command adds it.
  Never print or share that token.
