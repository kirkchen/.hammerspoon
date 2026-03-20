# Claude Code Menu Bar Status Indicator

## Overview

A Hammerspoon Spoon (`ClaudeCodeStatus.spoon`) that displays Claude Code session status in the macOS menu bar. Shows an emoji icon indicating whether sessions are idle or busy, and provides a dropdown menu to view all sessions and switch to them in iTerm2/tmux.

## Architecture

### Component: ClaudeCodeStatus.spoon

A self-contained Hammerspoon Spoon following the existing project conventions (Caffeine, WeekNumber, etc.). Loaded via `SpoonInstall:andUse()` from `init.lua`.

### Menu Bar Icon States

| State | Display | Meaning |
|---|---|---|
| No Claude sessions | Hidden (menubar hidden via `:removeFromMenuBar()`) | Nothing running |
| Some sessions idle | 💤 (static) | At least one session waiting for user input |
| All sessions busy | 🤔💡 alternating animation | All sessions actively executing |

Animation cycles between 🤔 and 💡 at ~1 second intervals.

### Menubar Lifecycle

The `hs.menubar` item is created once on `:start()` and persists for the lifetime of the Spoon. Visibility is toggled via `:removeFromMenuBar()` / `:returnToMenuBar()` to avoid flicker from repeated create/destroy cycles.

### Animation Timer Lifecycle

A secondary `hs.timer` (1-second interval) drives the emoji animation. It is only started when the state transitions to "all busy" and stopped when transitioning to "some idle" or "no sessions". The poll timer (10-second) manages these transitions.

### Session Detection (every 10 seconds)

Lightweight polling using process inspection. All shell commands use `hs.execute()` (synchronous) — the commands are fast (< 100ms total) and 10-second intervals make blocking acceptable.

1. **Find Claude processes**: `pgrep -af claude` to get PIDs (using `-af` instead of `-x` to handle symlinked/versioned binary names)
2. **Build process tree**: Single `ps -eo pid,ppid` call to build a full PID→PPID map, then walk upward for each Claude PID
3. **Map to tmux sessions**: Compare ancestors against tmux pane PIDs from `tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}'`
4. **Determine busy/idle**: Check if the Claude process has child processes (`pgrep -P <pid>`). Children present = busy (executing tools). No children = idle (waiting for input).
5. **Derive project name**: Use `lsof -a -d cwd -p <pid> -Fn` to reliably extract the CWD, then use the last path component as the display label.

### Dropdown Menu (built on click)

When the user clicks the menu bar icon, the menu is constructed showing:

```
Claude Code Sessions (4)
──────────────────────────────────
◉ ai-tools                ai-tools:1
◉ beat                       beat:1
◯ devbox                   devbox:1
◯ hammerspoon              devbox:2
──────────────────────────────────
↻ Refresh
```

- `◉` = busy (has child processes)
- `◯` = idle (waiting for input)
- Right side shows the tmux session:window location
- Clicking a row switches to that session in iTerm2

### Session Switching

When the user clicks a session row:

1. Execute tmux commands directly via `hs.execute()` (these are tmux server-side commands, no terminal needed):
   - `tmux list-clients -F '#{client_name}'` to find the active client
   - `tmux switch-client -c <client> -t <session_name>:<window_index>` to switch the client to the target session and window
2. Activate iTerm2 via `hs.application.launchOrFocus("iTerm2")` to bring it to the foreground

### File Structure

```
Spoons/ClaudeCodeStatus.spoon/
  init.lua          -- All Spoon logic
```

### init.lua Integration

```lua
Install:andUse("ClaudeCodeStatus", { start = true })
```

### Configuration (with defaults)

| Parameter | Default | Description |
|---|---|---|
| `pollInterval` | 10 | Seconds between process checks |
| `animationInterval` | 1 | Seconds between animation frame switches |
| `idleEmoji` | 💤 | Icon when some sessions are idle |
| `busyEmojis` | {🤔, 💡} | Animation frames when all busy |

## Error Handling

- If `tmux` is not running: hide menubar icon
- If `pgrep`/`lsof` fails: skip that process, continue with others
- If iTerm2 is not running when switching: launch it first
- If no tmux clients found: skip `switch-client`, just launch iTerm2

## Testing

- Manual: Start/stop Claude Code sessions and verify icon state changes
- Manual: Click dropdown items and verify correct tmux session switch
- Edge cases: no sessions, one session, many sessions, tmux not running
