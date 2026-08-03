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

A stoplight whose lamps light for the states present on the board. The **Icon**
submenu picks between two modes (remembered across restarts):

| Mode | Icon |
|:-----|:-----|
| **Stoplight** | Three lamps, each lit whenever any session is in that state |
| **Highest Wins** | The same stoplight plus a notification bubble in the highest-priority colour (red > yellow > green) showing that state's session count — no number when it's just one |

With every session idle, both modes show the same dim outline.

The icon keeps its menu bar position across launches and is restored if macOS
reaps it on sleep. Two more menu settings:

- **Quit When No Sessions** (off by default) quits Scoreboard after a minute
  with an empty board, and the CLI starts it again — in the background,
  without stealing focus — the moment the next session registers. It waits on
  *no sessions*, not *all idle*, so it doesn't churn every time Claude
  finishes a reply, and it never quits while the menu is open.
- **Start at Login** defaults to on for a fresh install; turn it off and that
  choice sticks.

## Install

```sh
brew tap acheris-labs/tools
brew install --cask acheris-labs/tools/scoreboard
```

That is the whole setup. One artifact installs everything: the app bundle
carries the CLI, which the cask symlinks onto your PATH, and the cask
registers the Claude Code hooks in `~/.claude/settings.json` (backing it up
first) and opens the app. Uninstalling unregisters them again.

Upgrading needs `brew update` first — on its own, `brew upgrade` checks a
stale copy of the tap and reports the latest version is already installed:

```sh
brew update && brew upgrade --cask scoreboard
```

To build from source instead, use `make install` (app to `~/Applications`,
CLI via `uv tool install --editable`).

`scoreboard init` is idempotent — re-running prints a per-hook status check.
`scoreboard init --remove` reverses exactly what it added (a timestamped
backup of settings.json is written before any change).

## Commands

- `scoreboard init [--remove]` — register/unregister Claude Code hooks. The
  cask runs this for you on install and uninstall, which is safe because it is
  idempotent: re-running against an already-registered `settings.json` writes
  nothing. Every real change is preceded by a timestamped backup (the newest
  five are kept).
- `scoreboard state` — print the board
- `scoreboard refresh` — re-link sessions to terminals. Inside a session
  (`! scoreboard refresh`) it captures the current tab directly; outside, it
  matches origin-less sessions to terminals by unique working directory.
- `scoreboard rename <name> [--session <id-prefix>]` — rename a session's
  menu row; the name is pinned so hook auto-titles never overwrite it.

## Jump-to-tab

The terminal a session lives in is captured once, at `SessionStart`, via the
adapter for the current terminal app (`cli/src/scoreboard/terminals/`). The
event carries an opaque `origin` (`{"kind": "ghostty", "terminal_id": ...}`)
that only the matching Swift adapter (`app/Sources/Scoreboard/*Adapter.swift`)
interprets — clicking a row focuses that exact window + tab, falling back to
working-directory match, then plain app activation. First click prompts once
for Automation permission (Scoreboard → Ghostty). Adding another terminal app
is one Python module + one Swift adapter file.

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
