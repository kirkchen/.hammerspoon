# Dynamic Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a floating Dynamic Island overlay that shows busy Claude Code sessions, driven by ClaudeCodeStatus data.

**Architecture:** New `ClaudeCodeIsland.spoon` reads session data via `onRefresh` callback from `ClaudeCodeStatus.spoon`. Single `hs.canvas` with frame animation for expand/collapse. Drag support with click detection via movement threshold.

**Tech Stack:** Hammerspoon Lua, `hs.canvas`, `hs.timer`, `hs.settings`, `hs.screen.watcher`

**Spec:** `docs/superpowers/specs/2026-03-20-dynamic-island-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `Spoons/ClaudeCodeIsland.spoon/init.lua` | Create: Island spoon — canvas, animation, drag, click, state management |
| `Spoons/ClaudeCodeStatus.spoon/init.lua` | Modify: Add `onRefresh` callback to `refresh()` |
| `init.lua` | Modify: Load Island spoon, wire callback |

---

### Task 1: Add `onRefresh` callback to ClaudeCodeStatus

**Files:**
- Modify: `Spoons/ClaudeCodeStatus.spoon/init.lua:77,263-266`

- [ ] **Step 1: Add `onRefresh` field**

In `Spoons/ClaudeCodeStatus.spoon/init.lua`, add after line 77 (`obj.anyBusy = false`):

```lua
obj.onRefresh = nil  -- callback function(sessions), called after each scan
```

- [ ] **Step 2: Call `onRefresh` in `refresh()`**

Change `refresh()` (lines 263-266) from:

```lua
function obj:refresh()
  self.sessions = scanSessions()
  self:updateIcon()
end
```

To:

```lua
function obj:refresh()
  self.sessions = scanSessions()
  self:updateIcon()
  if self.onRefresh then self.onRefresh(self.sessions) end
end
```

- [ ] **Step 3: Verify Hammerspoon reloads without error**

Run: Reload Hammerspoon config (or `hs.reload()` in console)
Expected: No errors in console, menubar icon still works normally

- [ ] **Step 4: Commit**

```bash
git add Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: add onRefresh callback to ClaudeCodeStatus"
```

---

### Task 2: Create Island spoon scaffold with collapsed pill

**Files:**
- Create: `Spoons/ClaudeCodeIsland.spoon/init.lua`

- [ ] **Step 1: Create spoon with metadata, config, and init**

Create `Spoons/ClaudeCodeIsland.spoon/init.lua`:

```lua
local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ClaudeCodeIsland"
obj.version = "1.0"
obj.author = "Kirk Chen"
obj.license = "MIT"

-- Configuration
obj.margin = 8
obj.collapsedWidth = 60
obj.collapsedHeight = 30
obj.expandedWidth = 260
obj.rowHeight = 28
obj.paddingY = 12
obj.cornerRadius = 18
obj.bgColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.95 }
obj.collapseDelay = 2

-- Internal state
obj.canvas = nil
obj.position = nil       -- { x, y } or nil for default
obj.state = "hidden"     -- "hidden", "collapsed", "expanded"
obj.busySessions = {}    -- current busy sessions for click handling
obj.lastSessions = {}    -- all sessions from last update
obj.animTimer = nil      -- frame animation timer
obj.pulseTimer = nil     -- dot pulse timer
obj.pulseAlpha = 1.0     -- current pulse opacity
obj.collapseTimer = nil  -- debounce timer for collapse
obj.screenWatcher = nil
obj.dragging = false
obj.dragStart = { x = 0, y = 0 }
obj.dragOffset = { x = 0, y = 0 }

local DRAG_THRESHOLD = 3

local function lerp(a, b, t) return a + (b - a) * t end

return obj
```

- [ ] **Step 2: Add `getDefaultPosition()` and `getPosition()`**

Append before `return obj`:

```lua
function obj:getDefaultPosition()
  local screen = hs.screen.mainScreen():frame()
  return {
    x = screen.x + (screen.w - self.collapsedWidth) / 2,
    y = screen.y + self.margin
  }
end

function obj:getPosition(width)
  local pos = self.position or self:getDefaultPosition()
  -- When width changes, keep centered on same x-center
  if width then
    local currentWidth = self.canvas and self.canvas:frame().w or self.collapsedWidth
    pos = { x = pos.x - (width - currentWidth) / 2, y = pos.y }
  end
  return pos
end
```

- [ ] **Step 3: Add `init()` and collapsed pill rendering**

Append before `return obj`:

```lua
function obj:init()
  self.position = hs.settings.get("ClaudeCodeIsland.position")
  self.canvas = hs.canvas.new({ x = 0, y = 0, w = self.collapsedWidth, h = self.collapsedHeight })
  self.canvas:level(hs.canvas.windowLevels.overlay)
  self.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
    + hs.canvas.windowBehaviors.stationary)
end

function obj:renderCollapsed(sessionCount)
  local w = self.collapsedWidth
  local h = self.collapsedHeight
  local elements = {
    {  -- Background
      type = "rectangle",
      frame = { x = 0, y = 0, w = w, h = h },
      roundedRectRadii = { xRadius = h / 2, yRadius = h / 2 },
      fillColor = self.bgColor,
      action = "fill",
    },
    {  -- Gray dot
      type = "circle",
      center = { x = 20, y = h / 2 },
      radius = 3.5,
      fillColor = { red = 0.33, green = 0.33, blue = 0.33, alpha = 1 },
      action = "fill",
    },
    {  -- Session count
      type = "text",
      frame = { x = 28, y = 0, w = w - 32, h = h },
      text = hs.styledtext.new(tostring(sessionCount), {
        font = { name = "Menlo", size = 12 },
        color = { red = 0.53, green = 0.53, blue = 0.53, alpha = 1 },
        paragraphStyle = { alignment = "left", lineBreak = "clip",
          minimumLineHeight = h, maximumLineHeight = h },
      }),
    },
  }
  self.canvas:replaceElements(elements)
  return w, h
end
```

- [ ] **Step 4: Add `update()` method with collapsed state only**

Append before `return obj`:

```lua
function obj:update(sessions)
  self.lastSessions = sessions

  if #sessions == 0 then
    self.state = "hidden"
    self.canvas:hide()
    self:stopPulse()
    return
  end

  -- Filter busy sessions
  local busy = {}
  for _, s in ipairs(sessions) do
    if s.busy then table.insert(busy, s) end
  end
  self.busySessions = busy

  if #busy == 0 then
    self:showCollapsed(#sessions)
  else
    -- TODO: expanded state (Task 3)
    self:showCollapsed(#sessions)
  end
end

function obj:showCollapsed(sessionCount)
  if self.collapseTimer then
    self.collapseTimer:stop()
    self.collapseTimer = nil
  end
  self:stopPulse()

  local w, h = self:renderCollapsed(sessionCount)
  local pos = self:getPosition(w)
  self.canvas:frame({ x = pos.x, y = pos.y, w = w, h = h })
  self.canvas:show()
  self.state = "collapsed"
end

function obj:stopPulse()
  if self.pulseTimer then
    self.pulseTimer:stop()
    self.pulseTimer = nil
  end
end
```

- [ ] **Step 5: Add `start()`, `stop()`, and `resetPosition()`**

Append before `return obj`:

```lua
function obj:start()
  self.screenWatcher = hs.screen.watcher.new(function()
    self:clampPosition()
  end)
  self.screenWatcher:start()
  return self
end

function obj:stop()
  if self.animTimer then self.animTimer:stop(); self.animTimer = nil end
  if self.pulseTimer then self.pulseTimer:stop(); self.pulseTimer = nil end
  if self.collapseTimer then self.collapseTimer:stop(); self.collapseTimer = nil end
  if self.screenWatcher then self.screenWatcher:stop(); self.screenWatcher = nil end
  if self.canvas then self.canvas:hide() end
  self.state = "hidden"
  return self
end

function obj:resetPosition()
  self.position = nil
  hs.settings.set("ClaudeCodeIsland.position", nil)
  if self.state ~= "hidden" then
    local w = self.canvas:frame().w
    local pos = self:getDefaultPosition()
    pos.x = pos.x - (w - self.collapsedWidth) / 2
    self.canvas:frame({ x = pos.x, y = pos.y, w = self.canvas:frame().w, h = self.canvas:frame().h })
  end
end

function obj:clampPosition()
  if not self.position then return end
  local screen = hs.screen.mainScreen():frame()
  local f = self.canvas:frame()
  self.position.x = math.max(screen.x, math.min(self.position.x, screen.x + screen.w - f.w))
  self.position.y = math.max(screen.y, math.min(self.position.y, screen.y + screen.h - f.h))
  self.canvas:frame({ x = self.position.x, y = self.position.y, w = f.w, h = f.h })
  hs.settings.set("ClaudeCodeIsland.position", self.position)
end
```

- [ ] **Step 6: Wire up in init.lua and test collapsed pill**

Change `init.lua` lines 19-20 from:

```lua
hs.loadSpoon("ClaudeCodeStatus")
spoon.ClaudeCodeStatus:start()
```

To:

```lua
hs.loadSpoon("ClaudeCodeStatus")
hs.loadSpoon("ClaudeCodeIsland")

spoon.ClaudeCodeStatus.onRefresh = function(sessions)
  spoon.ClaudeCodeIsland:update(sessions)
end

spoon.ClaudeCodeStatus:start()
spoon.ClaudeCodeIsland:start()
```

Run: Reload Hammerspoon
Expected: Dark pill with gray dot + session count appears at top-center of screen

- [ ] **Step 7: Commit**

```bash
git add Spoons/ClaudeCodeIsland.spoon/init.lua init.lua
git commit -m "feat: add ClaudeCodeIsland spoon with collapsed pill"
```

---

### Task 3: Add expanded state rendering

**Files:**
- Modify: `Spoons/ClaudeCodeIsland.spoon/init.lua`

- [ ] **Step 1: Add `renderExpanded()` method**

Add before `return obj`:

```lua
function obj:renderExpanded(busySessions)
  local w = self.expandedWidth
  local h = self.paddingY + #busySessions * self.rowHeight + self.paddingY
  local elements = {
    {  -- Background
      type = "rectangle",
      frame = { x = 0, y = 0, w = w, h = h },
      roundedRectRadii = { xRadius = self.cornerRadius, yRadius = self.cornerRadius },
      fillColor = self.bgColor,
      action = "fill",
    },
  }

  for i, s in ipairs(busySessions) do
    local y = self.paddingY + (i - 1) * self.rowHeight

    -- Hit-target rect (invisible, for click detection)
    table.insert(elements, {
      type = "rectangle",
      id = "row-" .. i,
      frame = { x = 0, y = y, w = w, h = self.rowHeight },
      fillColor = { alpha = 0 },
      action = "fill",
    })

    -- Status dot
    local dotColor
    if s.status == "Thinking..." then
      dotColor = { red = 0.98, green = 0.8, blue = 0.08, alpha = self.pulseAlpha }
    else
      dotColor = { red = 0.29, green = 0.87, blue = 0.5, alpha = 1 }
    end
    table.insert(elements, {
      type = "circle",
      center = { x = 18, y = y + self.rowHeight / 2 },
      radius = 3.5,
      fillColor = dotColor,
      action = "fill",
    })

    -- Project name
    table.insert(elements, {
      type = "text",
      frame = { x = 28, y = y, w = 120, h = self.rowHeight },
      text = hs.styledtext.new(s.project, {
        font = { name = "Menlo", size = 12 },
        color = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
        paragraphStyle = { alignment = "left", lineBreak = "clip",
          minimumLineHeight = self.rowHeight, maximumLineHeight = self.rowHeight },
      }),
    })

    -- Status text
    table.insert(elements, {
      type = "text",
      frame = { x = 148, y = y, w = w - 162, h = self.rowHeight },
      text = hs.styledtext.new(s.status, {
        font = { name = "Menlo", size = 11 },
        color = { red = 0.6, green = 0.6, blue = 0.6, alpha = 1 },
        paragraphStyle = { alignment = "right", lineBreak = "clip",
          minimumLineHeight = self.rowHeight, maximumLineHeight = self.rowHeight },
      }),
    })
  end

  self.canvas:replaceElements(elements)
  return w, h
end
```

- [ ] **Step 2: Add `showExpanded()` and update `update()` to use it**

Add before `return obj`:

```lua
function obj:showExpanded(busySessions)
  -- Cancel pending collapse
  if self.collapseTimer then
    self.collapseTimer:stop()
    self.collapseTimer = nil
  end

  local w, h = self:renderExpanded(busySessions)
  local pos = self:getPosition(w)
  self.canvas:frame({ x = pos.x, y = pos.y, w = w, h = h })
  self.canvas:show()
  self.state = "expanded"

  self:startPulse()
end
```

Then update the `update()` method — replace the `-- TODO: expanded state (Task 3)` block:

Change:
```lua
    -- TODO: expanded state (Task 3)
    self:showCollapsed(#sessions)
```

To:
```lua
    self:showExpanded(busy)
```

- [ ] **Step 3: Add pulse timer**

Add before `return obj`:

```lua
function obj:startPulse()
  if self.pulseTimer then return end  -- already running
  self.pulseTimer = hs.timer.doEvery(0.05, function()
    -- Sine wave: period 2s, range 0.4 to 1.0
    self.pulseAlpha = 0.7 + 0.3 * math.cos(hs.timer.secondsSinceEpoch() * math.pi)
    -- Re-render to update dot alpha (only if expanded)
    if self.state == "expanded" and #self.busySessions > 0 then
      self:renderExpanded(self.busySessions)
    end
  end)
end
```

- [ ] **Step 4: Reload and test expanded state**

Run: Reload Hammerspoon. Have at least one busy Claude session.
Expected: Island expands to show busy sessions with project name and status. Yellow dots pulse for "Thinking..." sessions.

- [ ] **Step 5: Commit**

```bash
git add Spoons/ClaudeCodeIsland.spoon/init.lua
git commit -m "feat: add expanded state with busy session list and pulse"
```

---

### Task 4: Add frame animation

**Files:**
- Modify: `Spoons/ClaudeCodeIsland.spoon/init.lua`

- [ ] **Step 1: Add `animateTo()` method**

Add before `return obj`:

```lua
function obj:animateTo(targetFrame, callback)
  -- Cancel any in-progress animation
  if self.animTimer then self.animTimer:stop(); self.animTimer = nil end

  local startFrame = self.canvas:frame()
  local steps = 15  -- 250ms at 60fps
  local step = 0
  self.animTimer = hs.timer.doEvery(1/60, function(t)
    step = step + 1
    local p = 1 - (1 - step / steps) ^ 3  -- ease-out cubic
    self.canvas:frame({
      x = lerp(startFrame.x, targetFrame.x, p),
      y = lerp(startFrame.y, targetFrame.y, p),
      w = lerp(startFrame.w, targetFrame.w, p),
      h = lerp(startFrame.h, targetFrame.h, p),
    })
    if step >= steps then
      t:stop()
      self.animTimer = nil
      if callback then callback() end
    end
  end)
end
```

- [ ] **Step 2: Update `showCollapsed()` to animate**

Replace `showCollapsed()`:

```lua
function obj:showCollapsed(sessionCount)
  if self.collapseTimer then
    self.collapseTimer:stop()
    self.collapseTimer = nil
  end
  self:stopPulse()

  local w, h = self:renderCollapsed(sessionCount)
  local pos = self:getPosition(w)
  local targetFrame = { x = pos.x, y = pos.y, w = w, h = h }

  if self.state == "hidden" then
    -- No animation on first show
    self.canvas:frame(targetFrame)
    self.canvas:show()
  else
    self:animateTo(targetFrame)
  end
  self.state = "collapsed"
end
```

- [ ] **Step 3: Update `showExpanded()` to animate**

Replace `showExpanded()`:

```lua
function obj:showExpanded(busySessions)
  if self.collapseTimer then
    self.collapseTimer:stop()
    self.collapseTimer = nil
  end

  local w, h = self:renderExpanded(busySessions)
  local pos = self:getPosition(w)
  local targetFrame = { x = pos.x, y = pos.y, w = w, h = h }

  if self.state == "hidden" then
    self.canvas:frame(targetFrame)
    self.canvas:show()
  else
    self:animateTo(targetFrame)
  end
  self.state = "expanded"

  self:startPulse()
end
```

- [ ] **Step 4: Add collapse debounce to `update()`**

In the `update()` method, replace the `#busy == 0` branch:

Change:
```lua
  if #busy == 0 then
    self:showCollapsed(#sessions)
```

To:
```lua
  if #busy == 0 then
    -- Debounce collapse to prevent flicker
    if self.state == "expanded" and not self.collapseTimer then
      self.collapseTimer = hs.timer.doAfter(self.collapseDelay, function()
        self.collapseTimer = nil
        -- Re-check: still no busy sessions?
        local stillBusy = false
        for _, s in ipairs(self.lastSessions) do
          if s.busy then stillBusy = true; break end
        end
        if not stillBusy then
          self:showCollapsed(#self.lastSessions)
        end
      end)
    elseif self.state ~= "expanded" then
      self:showCollapsed(#sessions)
    end
```

- [ ] **Step 5: Reload and test animation**

Run: Reload Hammerspoon. Trigger a Claude session to become busy, then idle.
Expected: Smooth expand/collapse animation with ease-out easing. 2-second delay before collapsing.

- [ ] **Step 6: Commit**

```bash
git add Spoons/ClaudeCodeIsland.spoon/init.lua
git commit -m "feat: add frame animation and collapse debounce"
```

---

### Task 5: Add drag and click interaction

**Files:**
- Modify: `Spoons/ClaudeCodeIsland.spoon/init.lua`

- [ ] **Step 1: Add mouse event handling in `init()`**

At the end of `init()`, after the canvas is created, add:

```lua
  self.canvas:canvasMouseEvents(true, true, false, true)
  self.canvas:mouseCallback(function(c, msg, id, x, y)
    if msg == "mouseDown" then
      self.dragStart = { x = x, y = y }
      self.dragOffset = { x = x, y = y }
      self.dragging = false
    elseif msg == "mouseDragged" then
      local dx = math.abs(x - self.dragStart.x)
      local dy = math.abs(y - self.dragStart.y)
      if dx > DRAG_THRESHOLD or dy > DRAG_THRESHOLD then
        self.dragging = true
      end
      if self.dragging then
        local f = c:frame()
        c:frame({
          x = f.x + x - self.dragOffset.x,
          y = f.y + y - self.dragOffset.y,
          w = f.w, h = f.h
        })
      end
    elseif msg == "mouseUp" then
      if self.dragging then
        local f = c:frame()
        self.position = { x = f.x, y = f.y }
        hs.settings.set("ClaudeCodeIsland.position", self.position)
      elseif id and type(id) == "string" and id:match("^row%-") then
        local idx = tonumber(id:match("row%-(%d+)"))
        if idx and self.busySessions[idx] then
          spoon.ClaudeCodeStatus:switchToSession(self.busySessions[idx])
        end
      end
      self.dragging = false
    end
  end)
```

- [ ] **Step 2: Reload and test drag**

Run: Reload Hammerspoon
Test: Drag the island pill to a different position. Reload Hammerspoon again.
Expected: Island appears at the saved position after reload.

- [ ] **Step 3: Test click on expanded session**

Test: Wait for a busy session. Click on its row in the expanded island.
Expected: iTerm2 comes to foreground, tmux switches to that session.

- [ ] **Step 4: Test resetPosition**

Run in Hammerspoon console: `spoon.ClaudeCodeIsland:resetPosition()`
Expected: Island jumps back to top-center.

- [ ] **Step 5: Commit**

```bash
git add Spoons/ClaudeCodeIsland.spoon/init.lua
git commit -m "feat: add drag, click, and position persistence"
```

---

### Task 6: Final polish and manual testing

**Files:**
- Modify: `Spoons/ClaudeCodeIsland.spoon/init.lua` (if fixes needed)

- [ ] **Step 1: Full manual test**

Test all states:
1. Kill all Claude sessions → island should hide
2. Start one Claude session (idle) → collapsed pill with "1"
3. Make session busy (run a tool) → expand with session row
4. Make session idle → 2s delay then collapse
5. Drag island → position saved
6. Reload Hammerspoon → position preserved
7. `spoon.ClaudeCodeIsland:resetPosition()` → returns to center
8. Multiple busy sessions → expanded with multiple rows
9. Click a row → switches to tmux session

- [ ] **Step 2: Fix any issues found**

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: polish Dynamic Island after manual testing"
```
