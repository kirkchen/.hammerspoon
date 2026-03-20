# Dynamic Island for Claude Code Sessions

## Overview

A floating, animated status indicator on screen — inspired by iPhone's Dynamic Island. Shows Claude Code session activity as a pill-shaped overlay that automatically expands when sessions become busy. Coexists with the existing menubar icon.

## Architecture

New Spoon: `ClaudeCodeIsland.spoon`

- Reads session data from `ClaudeCodeStatus.spoon` via a callback (`onRefresh`)
- Owns its own `hs.canvas`, animation timers, and drag state
- No independent polling — driven entirely by ClaudeCodeStatus refresh callback

### Data Flow

```
ClaudeCodeStatus.spoon (scanSessions every 10s)
        │
        ├── updateIcon() (menubar)
        └── onRefresh(sessions) callback
                │
                ▼
ClaudeCodeIsland.spoon:update(sessions)
        │
        ├── 0 sessions → hide canvas
        ├── all idle → render collapsed pill
        └── any busy → render expanded with busy sessions
```

ClaudeCodeStatus gains one field:

```lua
obj.onRefresh = nil  -- callback, called with (sessions) after each scan
```

Called at end of `refresh()`. ClaudeCodeIsland subscribes via:

```lua
spoon.ClaudeCodeStatus.onRefresh = function(sessions)
  spoon.ClaudeCodeIsland:update(sessions)
end
```

## States

| Condition | Display | Visual |
|---|---|---|
| 0 sessions | Hidden | Canvas removed |
| ≥1 session, all idle | Collapsed Pill | Gray dot + session count |
| ≥1 session busy | Expanded | List of busy sessions only |
| Busy count changes | Stay Expanded | Height animates to fit |
| All return to idle | Collapse | Animate back to pill (2s debounce) |

### Collapse Debounce

When all sessions return to idle, wait 2 seconds before collapsing. This prevents flicker caused by the 30-second transcript mtime heuristic in ClaudeCodeStatus, which can cause sessions to briefly toggle between busy/idle.

## Visual Design

### Collapsed Pill
- Dark background (rgba 0.1, 0.1, 0.1, 0.95), pill-shaped rounded corners
- Gray dot (●) + session count in monospace font
- Size: ~60×30 px

### Expanded
- Same dark background, rounded corners (radius 22)
- Each busy session row: colored dot + project name + status text
- Dot colors:
  - Yellow (pulsing): Thinking / API call
  - Green: Running tool (bash, git, etc.)
- Width: ~260 px
- Height: `paddingTop(12) + busyCount × rowHeight(28) + paddingBottom(12)`
- Each row clickable → switches to tmux session
- Max practical limit: ~5-6 concurrent busy sessions (no scroll needed)

### Animation
- Expand/collapse: ease-out cubic, 250ms (15 steps at 60fps)
- Height adjustment on busy count change: same easing
- Animate width, height, and position (keep centered on current x)
- Cancel any in-progress animation before starting a new one
- Dot pulse: separate timer, opacity 1.0 ↔ 0.4, 2s period, independent of frame animation

### Canvas Level

```lua
canvas:level(hs.canvas.windowLevels.overlay)
canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces + hs.canvas.windowBehaviors.stationary)
```

Always visible, even over fullscreen apps. Visible on all spaces.

## Canvas Structure

Single `hs.canvas` object with dynamically managed elements:

1. **Background**: rounded rectangle fill
2. **Collapsed**: dot circle element + count text element
3. **Expanded**: per-row hit-target rect (invisible, carries `id` for click detection) + dot circle + name text + status text

On state change, elements are cleared via `canvas:replaceElements()` and rebuilt, then frame is animated to new size.

## Positioning & Drag

- Default position: top-center of main screen, 8px from top edge
- Draggable via `mouseDown`/`mouseDragged`/`mouseUp` on canvas
- **Click vs. drag**: if total movement < 3px between mouseDown and mouseUp, treat as click; otherwise treat as drag
- Position persisted across reloads via `hs.settings.set("ClaudeCodeIsland.position", pos)` / `hs.settings.get()`
- Reset: `obj:resetPosition()` clears saved position, returns to top-center
- Screen change: `hs.screen.watcher` clamps saved position to ensure island stays within visible screen bounds (entire island must be on-screen)

## Interaction

- **Click on session row** (expanded): switch to that tmux session (reuses `ClaudeCodeStatus:switchToSession()`)
- **Drag** (any state): move island position
- **No hover behavior**: expand/collapse is automatic only

### Click Detection

Each session row has an invisible hit-target rect element with `id = "row-N"`. In `mouseCallback`, on click (movement < 3px), check `id` to find which row, then call `switchToSession` with the corresponding session data.

## Implementation Details

### Utilities

```lua
local function lerp(a, b, t) return a + (b - a) * t end
```

### Animation

```lua
-- Cancel previous animation before starting new one
if obj.animTimer then obj.animTimer:stop() end

local function animateTo(targetFrame, callback)
  local startFrame = canvas:frame()
  local steps = 15
  local step = 0
  obj.animTimer = hs.timer.doEvery(1/60, function(t)
    step = step + 1
    local p = 1 - (1 - step/steps)^3
    canvas:frame({
      x = lerp(startFrame.x, targetFrame.x, p),
      y = lerp(startFrame.y, targetFrame.y, p),
      w = lerp(startFrame.w, targetFrame.w, p),
      h = lerp(startFrame.h, targetFrame.h, p),
    })
    if step >= steps then
      t:stop()
      obj.animTimer = nil
      if callback then callback() end
    end
  end)
end
```

### Drag with Click Threshold

```lua
obj.dragging = false
obj.dragStart = { x = 0, y = 0 }
obj.dragOffset = { x = 0, y = 0 }
local DRAG_THRESHOLD = 3

canvas:canvasMouseEvents(true, true, false, true)
canvas:mouseCallback(function(c, msg, id, x, y)
  if msg == "mouseDown" then
    obj.dragStart = { x = x, y = y }
    obj.dragOffset = { x = x, y = y }
    obj.dragging = false
  elseif msg == "mouseDragged" then
    local dx = math.abs(x - obj.dragStart.x)
    local dy = math.abs(y - obj.dragStart.y)
    if dx > DRAG_THRESHOLD or dy > DRAG_THRESHOLD then
      obj.dragging = true
    end
    if obj.dragging then
      local f = c:frame()
      c:frame({
        x = f.x + x - obj.dragOffset.x,
        y = f.y + y - obj.dragOffset.y,
        w = f.w, h = f.h
      })
    end
  elseif msg == "mouseUp" then
    if obj.dragging then
      -- Save position
      local f = c:frame()
      obj.position = { x = f.x, y = f.y }
      hs.settings.set("ClaudeCodeIsland.position", obj.position)
    else
      -- Click — find session by element id
      if id and id:match("^row%-") then
        local idx = tonumber(id:match("row%-(%d+)"))
        if idx and obj.busySessions[idx] then
          spoon.ClaudeCodeStatus:switchToSession(obj.busySessions[idx])
        end
      end
    end
    obj.dragging = false
  end
end)
```

## Loading

```lua
-- init.lua
hs.loadSpoon("ClaudeCodeStatus")
hs.loadSpoon("ClaudeCodeIsland")

spoon.ClaudeCodeStatus.onRefresh = function(sessions)
  spoon.ClaudeCodeIsland:update(sessions)
end

spoon.ClaudeCodeStatus:start()
spoon.ClaudeCodeIsland:start()
```

## Configuration

```lua
obj.animationDuration = 0.25   -- 250ms
obj.animationFPS = 60
obj.margin = 8                 -- px from screen edge
obj.collapsedWidth = 60
obj.collapsedHeight = 30
obj.expandedWidth = 260
obj.rowHeight = 28
obj.paddingY = 12
obj.cornerRadius = 18
obj.bgColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.95 }
obj.collapseDelay = 2          -- seconds before collapsing when all idle
```

## Out of Scope

- Toast notifications
- Hover-to-expand
- Showing idle sessions in expanded view
- Native Swift helper app (future consideration if canvas performance is insufficient)
