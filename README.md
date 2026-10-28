# agent-scoreboard

A macOS menu bar scoreboard for Claude Code sessions. Claude Code hooks report
every state transition to a native menu bar app, which shows one row per
session with a colored dot:

- 🟢 running — Claude is working
- ⚪ idle — finished, waiting for you to prompt
- 🟡 waiting — blocked on a question or permission
- 🔴 error — a session errored

Clicking a session row jumps to its terminal tab (Ghostty supported; adapters
make other terminals easy to add).

## Menu bar icon

A stoplight whose lamps light for the states present on the board, plus a
notification bubble on its top-right corner in the highest-priority colour
(red > yellow > green) showing that state's session count — no number when
it's just one. So three sessions waiting behind two running ones reads as a
yellow bubble with a 3.

With every session idle, the icon is a dim outline and the bubble disappears.

The icon keeps its menu bar position across launches and is restored if macOS
reaps it on sleep.

## Settings

**Settings…** in the menu (⌘,) opens a window with:

- **Claude config folders** — the folders whose `settings.json` carries
  Scoreboard's hooks: `~/.claude`, plus one for each `CLAUDE_CONFIG_DIR` you
  run Claude with. **+** adds a folder and registers the hooks in it; **−**
  removes them. Nothing is registered until you add a folder, so the window
  opens by itself while the list is empty.
- **Hide when idle** (off by default) removes the icon once no session is
  running, waiting or in error, after an adjustable delay. `open -a
  Scoreboard` brings it back.
- **Quit when no sessions** (off by default) quits Scoreboard after an
  adjustable delay with an empty board, and the CLI starts it again — in the
  background, without stealing focus — the moment the next session
  registers. It waits on *no sessions*, not *all idle*, so it doesn't churn
  every time Claude finishes a reply, and it never quits while the menu or
  the Settings window is open.
- **Start at login** defaults to on for a fresh install; turn it off and that
  choice sticks.

## Install

```sh
brew tap acheris-labs/tools
brew install --cask acheris-labs/tools/scoreboard
```

One artifact installs everything: the app bundle carries the CLI, which the
cask symlinks onto your PATH, and the cask opens the app. Then open
**Settings…** from the menu and add your Claude config folder(s) — Scoreboard
registers its hooks there, backing up `settings.json` first. Uninstalling
removes the hooks from every folder; the list of folders is kept, so an
upgrade (or a reinstall) puts them back. `brew uninstall --zap` forgets it.

Upgrading needs `brew update` first — on its own, `brew upgrade` checks a
stale copy of the tap and reports the latest version is already installed:

```sh
brew update && brew upgrade --cask scoreboard
```

To build from source instead, use `make install` (app to `~/Applications`,
CLI symlinked into `~/.local/bin`).

## Commands

- `scoreboard init` — register the hooks in `~/.claude` (the same as adding
  it in Settings) and print a per-hook status check. Idempotent: re-running
  against an already-registered `settings.json` writes nothing.
- `scoreboard init --remove` — remove the hooks from every config folder.
  The cask runs this on uninstall.
- `scoreboard init --restore` — re-register every remembered folder. The cask
  runs this on install, which is how `brew upgrade` keeps your folders.

Every change to a `settings.json` is preceded by a timestamped backup (the
newest five are kept).
- `scoreboard state` — print the board
- `scoreboard rename <name> [--session <id-prefix>]` — rename a session's
  menu row; the name is pinned so hook auto-titles never overwrite it.

## Jump-to-tab

Requires Ghostty 1.4 or later. The hook only records which terminal app a
session runs in, read from `TERM_PROGRAM` (`{"kind": "ghostty"}`); nothing is
captured from the screen. When you click a row, the matching adapter
(`app/Sources/Scoreboard/*Adapter.swift`) looks up the session process's tty
and focuses the Ghostty terminal with that tty, so it lands on the right window
and tab no matter what was focused when the session started. It falls back to
a working-directory match (e.g. claude inside tmux), then plain app activation.
First click prompts once for Automation permission (Scoreboard → Ghostty).
Adding another terminal app is one case in
`app/Sources/ScoreboardCore/TerminalCapture.swift` plus one Swift adapter file.

## How it works

```
Claude Code hooks ──stdin JSON──▶ scoreboard hook (Python, always exits 0)
        │ maps hook -> state event, one NDJSON line, 250ms timeout
        ▼
~/.local/state/scoreboard/scoreboard.sock   (unix socket owned by the app)
        ▼
Scoreboard.app ── SessionStore ──▶ menu rows + urgency dot
        │ atomic snapshot on every change
        ▼
~/.local/state/scoreboard/state.json        (read by `scoreboard state`)
```

- One-way protocol: the app never replies. `scoreboard state` reads the
  snapshot file.
- If the app isn't running, hooks drop silently (logged to
  `~/.local/state/scoreboard/hook.log`) and never block Claude.
- Sessions are removed on SessionEnd; a 15s liveness sweep (`kill -0` on the
  hook's parent pid) reaps sessions that died without one. The snapshot lets
  an app restart recover live sessions.

## Layout

One SwiftPM package, three targets:

- `app/Sources/ScoreboardCore/` — shared: hook mapping, settings merge, socket
  client, terminal capture
- `app/Sources/Scoreboard/` — the menu bar app (AppKit): socket listener,
  session store, status icon
- `app/Sources/ScoreboardCLI/` — the `scoreboard` binary, shipped inside the
  app bundle and symlinked onto PATH by the cask

The CLI is compiled rather than scripted because it runs on every Claude hook:
~5ms per invocation against ~150ms for the Python version it replaced (~250ms
when a pyenv shim was resolving `python3`). That headroom is what makes it
affordable to hook every tool call, which is how a session stops showing
yellow the instant you grant a permission.

## Releasing

```sh
git tag v1.2.3 && git push origin v1.2.3
```

That is the whole process. CI signs and notarizes the app, publishes a
stapled zip and DMG to a GitHub release, and pushes the regenerated cask to
[acheris-labs/homebrew-tools](https://github.com/acheris-labs/homebrew-tools)
so `brew upgrade --cask scoreboard` picks it up. Add a `## [1.2.3]` section
to `CHANGELOG.md` to control the release notes; otherwise they are generated.

## Develop

```sh
make test         # swift test
make run          # build + launch the app
make -C app app   # rebuild just the bundle
```
