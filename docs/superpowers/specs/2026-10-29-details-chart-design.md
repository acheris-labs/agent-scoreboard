# Show Details: time spent per state

## Why

The question this answers: **do my agents spend more time waiting on me, or do
I spend more time waiting on them?** Running time (green) is me waiting on
them; waiting time (amber) is them waiting on me. Errors (red) are worth
seeing too. Alongside that: what share of the day agents are running, how
many are going at once, and when the busy times are.

## Goals

- Record how long each session spends in running, waiting and error.
- A **Show Details** window, opened from the menu, with a chart in the style
  of `../tracker`'s chart window and totals underneath.
- Five ranges: last hour, 12 hours, 24 hours, 7 days, 30 days. The 7
  and 30 day views show day-of-week and time-of-day patterns.

## Non-goals

- Idle (lamp off) time is not drawn as a band. It shows as the gap between
  the coloured bands and the sessions line, and as a footer total. Ended
  time is not tracked.
- Breaking waiting down by project or by reason (permission prompt versus a
  question). Not now.
- A separate hour-of-day profile view ("always busy 2 to 4pm"). The 7 and 30
  day timelines are enough.
- Back-filling history from before this ships. Claude's own logs don't carry
  our lamp states; the chart starts empty.
- Configurable colours, export, hover tooltips.

## Anti-goals

- **Wall-clock counting.** Time is summed across sessions, the way CPU usage
  goes past 100% with several cores. Sessions running 12:00 to 12:10 and
  12:05 to 12:15 are 20 minutes of running, not 15.
- Counting time the app didn't see as if it had seen it (see "Gaps").

## Data

### The log

- File: `~/.local/state/scoreboard/history.ndjson` (add `Paths.history`).
- One JSON line per state change, appended by the **app**, in `SessionStore`,
  at the point a session's state changes. The app is the one place that sees
  every change, including sessions removed by the reaper.
- Line shape: `{"ts":1793286000.5,"session":"<session id>","state":"waiting"}`.
  `ts` is epoch seconds. `state` is one of `running`, `waiting`, `error`,
  `idle`, `ended`.
- Write a line only when the state actually changes. Hooks often repeat the
  current state (e.g. `running` on every tool call), and those repeats are
  not logged.
- Write `ended` when a session ends by hook **and** when the reaper removes
  it.
- `idle` is logged so that it closes the running, waiting or error stretch
  before it. Idle time itself is never counted.

### Gaps (app not running)

The app can be quit, or it can quit itself when the board is empty. Events
that arrive while it is down are lost, so the log must not pretend they
didn't happen:

- On quit (`applicationWillTerminate`), log `ended` for every session still
  on the board.
- On launch, after loading `state.json` and the first reap, log each
  remaining session's current state with the launch time.

The time the app was down is then simply not counted.

**Unclean exits** (my call): a crash, `pkill` (SIGTERM, used by `make run`)
or SIGKILL (`terminateOlderInstances`) skip `applicationWillTerminate`.

- While running, the app touches `~/.local/state/scoreboard/history.alive`
  every 15 seconds, on the existing reap timer.
- At launch, before re-logging current states, any session the log still has
  open gets an `ended` line at that file's modification time.
- At worst this loses up to 15 seconds of the time before the crash. It never
  counts the downtime.

**Sleep is not counted** (decided). A session left waiting overnight must not
add the night to "They waited".

- On `NSWorkspace.willSleepNotification`, log `ended` for every session on
  the board.
- On `didWakeNotification`, after a reap, log each remaining session's
  current state with the wake time.
- This is the same pair of steps used for quit and launch. Share one
  function for each step.

### Pruning

At launch, and then once a day while running, rewrite the file without lines
older than 30 days. Write to a temp file and rename it, like the snapshot
save in `SessionStore`. Size is not a concern: a heavy day is a few thousand
lines, and a month is a few MB.

### Building the chart data

When the window opens, or the range changes, read the log and build the
buckets in memory. No stored rollups.

| Range        | Bucket | Points |
|:-------------|:-------|:-------|
| Last hour    | 1 min  | 60     |
| Last 12 h    | 5 min  | 144    |
| Last 24 h    | 15 min | 96     |
| Last 7 days  | 1 h    | 168    |
| Last 30 days | 6 h    | 120    |

How to bucket:

- Walk each session's lines in time order. Each state holds from its `ts`
  until the session's next line.
- A session whose last line isn't `ended` is still open: its state runs until
  now.
- Clip each stretch to the range, and split it across the buckets it
  overlaps.
- For each bucket, add up the seconds per state across all sessions, then
  divide by the bucket length. The result is "agents' worth" in that state:
  2.5 running means two and a half agents' worth of running over that
  bucket.
- **Session line:** the average number of open (not ended) sessions in the
  bucket, idle ones included, computed the same way.
- Lines that fail to parse are skipped.

## Window

Layout **A, Tracker style** (chosen from mockups):

- **Opening it:** a **Show Details** menu item directly under **Settings…**
  in the status menu.
- **Range picker:** a pop-up menu at the top left that reads as the chart's
  heading ("Last 12 hours"), with ⌘1 to ⌘5 to switch. Five segments were
  too crowded.
- **Chart:**
  - Follows the system light/dark appearance, as Tracker's chart window does
    (my call). Dark mode is the reference look. For light mode, copy
    Tracker's treatment (`legibleOnLight` / `darkened`) for the lamp colours,
    and draw the session line in dark grey instead of white.
  - Three stacked, smoothed areas, bottom to top: running (green), waiting
    (amber), error (red). Use the colours of `StatusLevel` in the app, which
    are also the app icon's lamps.
  - The left axis is agents' worth.
  - The session count is drawn as a white smoothed line, with a legend:
    the gap above the colours is idle sessions.
  - Time labels run along the bottom.
- **Footer panes** (Tracker's `FooterPane` look), with totals for the
  selected range:
  - **Running:** "You waited", total time (e.g. `6h 40m`)
  - **Waiting:** "They waited", total time
  - **Error:** total time
  - **Idle:** "Lamp off", total time open but idle
  - **Peak sessions:** active / open, e.g. `2 / 3`. Active excludes idle
  - **Active** (my call): the share of the range where at least one session
    was running, as a %. This is the "what % of the day are agents running"
    number. It is wall-clock time, unlike everything else here. The
    denominator runs from the later of the range start and the log's first
    line, to now (my call). Three days after shipping, the 30-day view then
    reads as a share of those three days, not of 30.
- **Live updates:** while open, the window redraws when the store changes,
  and once a minute (my call).
- **Closing:** ⌘W closes it. As with Settings, the app doesn't quit
  while the window is visible.

## Constraints

- The project is SwiftPM, AppKit for the menu bar and SwiftUI for Settings,
  with no third-party dependencies. Keep it that way.
- It targets **macOS 13** (`Package.swift`, `LSMinimumSystemVersion`). Use
  only APIs available on 13.
- The bucketing is pure logic with no AppKit, so it can be unit tested with
  XCTest like the rest of `ScoreboardCore`.
- `../tracker` is a separate repo. Copy what helps (its smoothing,
  ribbon-fill and footer pane drawing) and don't share code between the two
  repos.

## Left to the builder

- Whether the chart is AppKit drawing (like Tracker) or SwiftUI Charts. It
  must look like the Tracker chart.
- How the log is read: whole file, or from the end back to the range start.
- The exact axis scale. It could be fixed steps or follow the data.
- File and type names.
