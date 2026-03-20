# Claude Code Menu Bar Status Indicator

## Overview

A Hammerspoon Spoon (`ClaudeCodeStatus.spoon`) that displays Claude Code session status in the macOS menu bar. Shows an emoji icon indicating whether sessions are idle or busy, and provides a dropdown menu to view all sessions and switch to them in iTerm2/tmux.

## Architecture

### Component: ClaudeCodeStatus.spoon

A self-contained Hammerspoon Spoon following the existing project conventions (Caffeine, WeekNumber, etc.). Loaded via `SpoonInstall:andUse()` from `init.lua`.

### Menu Bar Icon States

| State | Display | Meaning |
|---|---|---|
| No Claude sessions | Hidden (menubar removed) | Nothing running |
| Some sessions idle | 💤 (static) | At least one session waiting for user input |
| All sessions busy | 🤔💡 alternating animation | All sessions actively executing |

Animation cycles between 🤔 and 💡 at ~1 second intervals.

### Session Detection (every 10 seconds)

Lightweight polling using process inspection:

1. **Find Claude processes**: `pgrep -x claude` to get PIDs
2. **Map to tmux sessions**: For each Claude PID, walk the process tree upward to find the ancestor whose PID matches a tmux pane PID (`tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}'`)
3. **Determine busy/idle**: Check if the Claude process has child processes (`pgrep -P <pid>`). Children present = busy (executing tools). No children = idle (waiting for input).
4. **Derive project name**: Use the Claude process's CWD (via `lsof -p <pid> | grep cwd`) to extract the directory name as the display label.

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

1. Activate iTerm2 via `hs.application.launchOrFocus("iTerm2")`
2. Execute `tmux switch-client -t <session_name>` in iTerm2 via `hs.osascript.applescript` to send the command to iTerm2's current terminal session
3. Then `tmux select-window -t <session_name>:<window_index>` to land on the correct window

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

## Testing

- Manual: Start/stop Claude Code sessions and verify icon state changes
- Manual: Click dropdown items and verify correct tmux session switch
- Edge cases: no sessions, one session, many sessions, tmux not running
