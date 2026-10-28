# Changelog

## [3.0.0]

### Changed
- Clicking a session now finds its Ghostty tab from the session's tty, using
  Ghostty 1.4's new AppleScript `tty` property. It lands on the right tab no
  matter which tab was focused when the session started.
- The hook no longer runs AppleScript at session start, so it is faster and
  never needs Automation permission.

### Breaking
- **Requires Ghostty 1.4 or later** for exact tab jumps. On older versions a
  click falls back to matching the session's working directory.
- `scoreboard refresh` is removed: there is nothing left to re-link.
