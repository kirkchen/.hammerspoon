# Dynamic Island for Claude Code Sessions

## Overview

A floating, animated status indicator on screen — inspired by iPhone's Dynamic Island. Shows Claude Code session activity as a pill-shaped overlay that automatically expands when sessions become busy. Coexists with the existing menubar icon.

## Architecture

New Spoon: `ClaudeCodeIsland.spoon`

- Shares session data from `ClaudeCodeStatus.spoon` (via `spoon.ClaudeCodeStatus.sessions`)
- Owns its own `hs.canvas`, animation timers, and drag state
- Polls session data on the same interval as ClaudeCodeStatus (10s), driven by its own timer or by subscribing to ClaudeCodeStatus refresh

## States

| Condition | Display | Visual |
|---|---|---|
| 0 sessions | Hidden | Canvas removed |
| ≥1 session, all idle | Collapsed Pill | Gray dot + session count |
| ≥1 session busy | Expanded | List of busy sessions with status |
| Busy count changes | Stay Expanded | Height animates to fit |
| All return to idle | Collapse | Animate back to pill |

## Visual Design

### Collapsed Pill
- Dark background (`#1a1a1a`), rounded corners (pill shape)
- Gray dot (●) + session count in monospace font
- Approximate size: ~60×30 px
- Semi-transparent shadow

### Expanded
- Same dark background, larger rounded corners
- Each busy session row: colored dot + project name + status text
- Dot colors:
  - Yellow (#facc15, pulsing): Thinking / API call
  - Green (#4ade80): Running tool (bash, git, etc.)
- Width: ~260 px, height: dynamic based on session count
- Each row is clickable → switches to that tmux session

### Animation
- Expand/collapse: ease-out cubic, 250ms
- Height adjustment (busy count change): same easing
- Animate width, height, and position (keep centered on current x position)
- Dot pulse: opacity 1.0 ↔ 0.4, 2s period

## Positioning & Drag

- Default position: top-center of main screen, 8px from top edge
- Draggable: `mouseDown`/`mouseDragged`/`mouseUp` events on canvas
- Position persisted across refreshes (stored in `obj.position`)
- Reset: method `obj:resetPosition()` to return to default
- On screen change (monitor plug/unplug): clamp to visible screen bounds

## Interaction

- **Click on session row** (expanded): switch to that tmux session (same logic as ClaudeCodeStatus `switchToSession`)
- **Drag** (any state): move island position
- **No hover behavior**: expand/collapse is automatic based on busy state only

## Data Flow

```
ClaudeCodeStatus.spoon (scanSessions every 10s)
        │
        ▼
  spoon.ClaudeCodeStatus.sessions  (shared data)
        │
        ▼
ClaudeCodeIsland.spoon (reads sessions, updates canvas)
        │
        ├── 0 sessions → hide canvas
        ├── all idle → render collapsed pill
        └── any busy → render expanded with busy sessions
```

## Canvas Structure

Single `hs.canvas` object with dynamically managed elements:

1. **Background**: rounded rectangle, fill `#1a1a1a` with shadow
2. **Collapsed content**: dot circle + count text (visible when collapsed)
3. **Expanded content**: N session rows, each with dot + name + status text

On state change, elements are cleared and rebuilt, then frame is animated to new size.

## Implementation Details

### Canvas Element Rebuild
Rather than animating individual elements, rebuild the element list on each state change and animate the canvas frame (position + size) to the target dimensions.

### Animation Loop
```lua
local function animateTo(targetFrame, callback)
  local startFrame = canvas:frame()
  local steps = 15  -- 250ms at 60fps
  local step = 0
  hs.timer.doEvery(1/60, function(t)
    step = step + 1
    local p = 1 - (1 - step/steps)^3  -- ease-out cubic
    canvas:frame({
      x = lerp(startFrame.x, targetFrame.x, p),
      y = lerp(startFrame.y, targetFrame.y, p),
      w = lerp(startFrame.w, targetFrame.w, p),
      h = lerp(startFrame.h, targetFrame.h, p),
    })
    if step >= steps then
      t:stop()
      if callback then callback() end
    end
  end)
end
```

### Drag Implementation
```lua
-- Track drag state
obj.dragging = false
obj.dragOffset = { x = 0, y = 0 }

-- Canvas mouse callbacks
canvas:canvasMouseEvents(true, true, false, true)
canvas:mouseCallback(function(c, msg, id, x, y)
  if msg == "mouseDown" then
    obj.dragging = true
    local f = c:frame()
    obj.dragOffset = { x = x, y = y }
  elseif msg == "mouseDragged" and obj.dragging then
    local f = c:frame()
    c:frame({
      x = f.x + x - obj.dragOffset.x,
      y = f.y + y - obj.dragOffset.y,
      w = f.w, h = f.h
    })
  elseif msg == "mouseUp" then
    if obj.dragging then
      obj.dragging = false
      obj.position = { x = c:frame().x, y = c:frame().y }
    end
  end
end)
```

### Session Row Click
Use `id` parameter in mouseCallback to identify which session row was clicked. Each row element gets an `id` field matching the session index.

## Loading

```lua
-- init.lua
hs.loadSpoon("ClaudeCodeStatus")
spoon.ClaudeCodeStatus:start()

hs.loadSpoon("ClaudeCodeIsland")
spoon.ClaudeCodeIsland:start()
```

## Configuration

```lua
obj.pollInterval = 10          -- sync with ClaudeCodeStatus
obj.animationDuration = 0.25   -- 250ms
obj.animationFPS = 60
obj.defaultPosition = "top-center"
obj.margin = 8                 -- px from screen edge
obj.collapsedWidth = 60
obj.collapsedHeight = 30
obj.expandedWidth = 260
obj.rowHeight = 28
obj.cornerRadius = 18
obj.bgColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.95 }
```

## Out of Scope

- Toast notifications
- Hover-to-expand
- Showing idle sessions in expanded view
- Native Swift helper app (future consideration if canvas performance is insufficient)
