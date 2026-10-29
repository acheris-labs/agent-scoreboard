# Changelog

## [3.2.0]

### Added
- **Show Details** (in the menu, under Settings…): a chart of how your agents
  spend their time. Green is running (you waiting on them), amber is waiting
  (them waiting on you), red is error, and a line shows how many sessions
  were open. Time is summed across sessions, like CPU across cores. Pick the
  last hour, 24 hours, 7 days or 30 days; the footer totals each state and
  shows the share of time any agent was running.
- History is recorded from this version on, kept for 30 days, in
  `~/.local/state/scoreboard/history.ndjson`. Time while the Mac sleeps or
  Scoreboard isn't running is not counted.
- A proper app icon: the menu bar stoplight, all three lamps lit. It shows in
  Finder, the About box and the Settings window.

### Changed
- While no config folder is registered, Scoreboard never hides its icon or
  quits, since the icon is the only way back to Settings.

## [3.1.0]

### Added
- A Settings window (**Settings…** in the menu, ⌘,) with the list of Claude
  config folders Scoreboard's hooks are registered in. **+** adds a folder
  (`~/.claude`, or one per `CLAUDE_CONFIG_DIR`); **−** removes the hooks from
  it. It opens by itself while no folder is registered.
- `scoreboard init --restore` re-registers every remembered folder.

### Changed
- Installing no longer registers hooks automatically: add your config folders
  in Settings. Upgrades keep the folders you chose.
- Uninstalling removes the hooks from every registered folder, not just
  `~/.claude`.
- Hide when idle, Quit when no sessions and Start at login moved from the menu
  into the Settings window.

### Upgrading from 3.0
- The 3.0 uninstall step removes the hooks from `~/.claude` during the
  upgrade, and 3.0 kept no list to restore from. Settings opens after the
  upgrade: click **+** and choose `~/.claude` once.

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
