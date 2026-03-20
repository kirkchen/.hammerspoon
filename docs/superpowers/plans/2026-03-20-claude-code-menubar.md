# Claude Code Menu Bar Status Indicator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Hammerspoon Spoon that shows Claude Code session status as an emoji in the macOS menu bar, with a dropdown to switch tmux sessions in iTerm2.

**Architecture:** Single Spoon (`ClaudeCodeStatus.spoon`) following the WeekNumber/Caffeine pattern. A 10-second poll timer detects Claude processes and maps them to tmux sessions via process tree walking. A separate 1-second animation timer drives the busy emoji. Dropdown menu is built on-click with session switching via direct `tmux` and `hs.application` calls.

**Tech Stack:** Lua (Hammerspoon API), shell commands (`pgrep`, `ps`, `lsof`, `tmux`)

**Spec:** `docs/superpowers/specs/2026-03-20-claude-code-menubar-design.md`

---

## File Structure

```
Spoons/ClaudeCodeStatus.spoon/
  init.lua          -- All Spoon logic (~200 lines)
init.lua            -- Modify: add Install:andUse line
```

Single file Spoon. Responsibilities broken into internal functions:
- `scanSessions()` — process detection and tmux mapping
- `updateIcon()` — menubar emoji state management
- `buildMenu()` — dropdown menu construction (called on click)
- `switchToSession(session)` — iTerm2/tmux switching

---

## Task 1: Spoon Skeleton with Static Menubar

**Files:**
- Create: `Spoons/ClaudeCodeStatus.spoon/init.lua`

- [ ] **Step 1: Create Spoon directory**

```bash
mkdir -p Spoons/ClaudeCodeStatus.spoon
```

- [ ] **Step 2: Write Spoon skeleton with hardcoded static emoji**

Create `Spoons/ClaudeCodeStatus.spoon/init.lua` with the full skeleton following the WeekNumber pattern:

```lua
local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ClaudeCodeStatus"
obj.version = "1.0"
obj.author = "Kirk Chen"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Configuration
obj.pollInterval = 10
obj.animationInterval = 1
obj.idleEmoji = "💤"
obj.busyEmojis = {"🤔", "💡"}

-- Internal state
obj.menubar = nil
obj.pollTimer = nil
obj.animationTimer = nil
obj.animationFrame = 1
obj.sessions = {}
obj.allBusy = false

function obj:init()
  self.menubar = hs.menubar.new()
  self.menubar:removeFromMenuBar()  -- Start hidden; first refresh() will show if needed
end

function obj:start()
  self:refresh()
  return self
end

function obj:stop()
  if self.pollTimer then
    self.pollTimer:stop()
    self.pollTimer = nil
  end
  if self.animationTimer then
    self.animationTimer:stop()
    self.animationTimer = nil
  end
  if self.menubar then
    self.menubar:removeFromMenuBar()
  end
  return self
end

return obj
```

- [ ] **Step 3: Verify Spoon loads**

Reload Hammerspoon config. Temporarily add to `init.lua`:
```lua
hs.loadSpoon("ClaudeCodeStatus")
spoon.ClaudeCodeStatus:start()
```
Verify: no errors in Hammerspoon console. Icon stays hidden (no sessions detected yet since `refresh()` is a no-op stub at this point — just verifying clean load).

- [ ] **Step 4: Commit**

```bash
git add Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: add ClaudeCodeStatus Spoon skeleton with static menubar"
```

---

## Task 2: Session Detection (scanSessions)

**Files:**
- Modify: `Spoons/ClaudeCodeStatus.spoon/init.lua`

- [ ] **Step 1: Implement scanSessions function**

Add the `scanSessions` function before `init()`. This function:
1. Runs `pgrep -af claude` to find Claude PIDs (filter to only lines matching the `claude` CLI binary, excluding Claude.app helper processes like `ShipIt`)
2. Runs `ps -eo pid,ppid` once to build the process tree
3. Runs `tmux list-panes -a -F '#{pane_pid} #{session_name} #{window_index} #{pane_index}'` to get pane→session mapping
4. For each Claude PID, walks the tree upward to find a matching tmux pane PID
5. Gets CWD via `lsof -a -d cwd -p <pid> -Fn`
6. Checks child processes via `pgrep -P <pid>` to determine busy/idle

```lua
local function scanSessions()
  local sessions = {}

  -- Step 1: Find Claude CLI PIDs
  local pgrepOut = hs.execute("pgrep -af claude 2>/dev/null")
  if not pgrepOut or pgrepOut == "" then return sessions end

  local claudePids = {}
  for line in pgrepOut:gmatch("[^\n]+") do
    local pid, cmd = line:match("^(%d+)%s+(.+)")
    if pid and cmd and (cmd:match("/claude") or cmd:match("^claude"))
       and not cmd:match("ShipIt") and not cmd:match("Claude%.app")
       and not cmd:match("claude%-desktop") then
      table.insert(claudePids, tonumber(pid))
    end
  end

  if #claudePids == 0 then return sessions end

  -- Step 2: Build process tree (single ps call)
  local psOut = hs.execute("ps -eo pid,ppid 2>/dev/null")
  local parentOf = {}
  if psOut then
    for line in psOut:gmatch("[^\n]+") do
      local p, pp = line:match("(%d+)%s+(%d+)")
      if p and pp then
        parentOf[tonumber(p)] = tonumber(pp)
      end
    end
  end

  -- Step 3: Get tmux pane mapping
  local tmuxOut = hs.execute("tmux list-panes -a -F '#{pane_pid} #{session_name} #{window_index} #{pane_index}' 2>/dev/null")
  local panePids = {}
  if tmuxOut then
    for line in tmuxOut:gmatch("[^\n]+") do
      local panePid, sessName, winIdx, paneIdx = line:match("(%d+)%s+(%S+)%s+(%d+)%s+(%d+)")
      if panePid then
        panePids[tonumber(panePid)] = {
          session = sessName,
          window = tonumber(winIdx),
          pane = tonumber(paneIdx)
        }
      end
    end
  end

  -- Step 4-6: For each Claude PID, resolve tmux location, CWD, and busy state
  for _, pid in ipairs(claudePids) do
    -- Walk process tree to find tmux pane
    local tmuxInfo = nil
    local cur = parentOf[pid]
    for _ = 1, 20 do
      if not cur or cur <= 1 then break end
      if panePids[cur] then
        tmuxInfo = panePids[cur]
        break
      end
      cur = parentOf[cur]
    end

    -- Get CWD
    local projectName = "unknown"
    local lsofOut = hs.execute("lsof -a -d cwd -p " .. pid .. " -Fn 2>/dev/null")
    if lsofOut then
      local cwd = lsofOut:match("\nn(/[^\n]+)")
      if cwd then
        projectName = cwd:match("([^/]+)$") or cwd
      end
    end

    -- Check busy state (has child processes?)
    local childOut = hs.execute("pgrep -P " .. pid .. " 2>/dev/null")
    local isBusy = childOut ~= nil and childOut ~= ""

    table.insert(sessions, {
      pid = pid,
      project = projectName,
      busy = isBusy,
      tmux = tmuxInfo
    })
  end

  return sessions
end
```

- [ ] **Step 2: Wire scanSessions into poll timer**

Replace the entire `start()` function with the following (adds poll timer and menu callback):

```lua
function obj:start()
  self:refresh()
  self.pollTimer = hs.timer.doEvery(self.pollInterval, function() self:refresh() end)
  return self
end

function obj:refresh()
  self.sessions = scanSessions()
  self:updateIcon()
end
```

Add a minimal `updateIcon`:

```lua
function obj:updateIcon()
  if #self.sessions == 0 then
    self.menubar:removeFromMenuBar()
    return
  end
  self.menubar:returnToMenuBar()
  self.menubar:setTitle(self.idleEmoji)
end
```

- [ ] **Step 3: Verify session detection**

Reload Hammerspoon. Open Console (`hs.openConsole()`).
Add a temporary debug line in `refresh()`: `hs.printf("Claude sessions: %d", #self.sessions)`
Verify it detects the correct number of running Claude sessions.

- [ ] **Step 4: Commit**

```bash
git add Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: implement session detection via process tree walking"
```

---

## Task 3: Icon State Management (Animation)

**Files:**
- Modify: `Spoons/ClaudeCodeStatus.spoon/init.lua`

- [ ] **Step 1: Implement full updateIcon with animation logic**

Replace the minimal `updateIcon` with the full version:

```lua
function obj:updateIcon()
  if #self.sessions == 0 then
    self.menubar:removeFromMenuBar()
    self:stopAnimation()
    self.allBusy = false
    return
  end

  self.menubar:returnToMenuBar()

  local allBusy = true
  for _, s in ipairs(self.sessions) do
    if not s.busy then
      allBusy = false
      break
    end
  end

  if allBusy and not self.allBusy then
    -- Transition to all-busy: start animation
    self.allBusy = true
    self:startAnimation()
  elseif not allBusy and self.allBusy then
    -- Transition to some-idle: stop animation
    self.allBusy = false
    self:stopAnimation()
    self.menubar:setTitle(self.idleEmoji)
  elseif not allBusy then
    self.menubar:setTitle(self.idleEmoji)
  end
end

function obj:startAnimation()
  self.animationFrame = 1
  self.menubar:setTitle(self.busyEmojis[1])
  self.animationTimer = hs.timer.doEvery(self.animationInterval, function()
    self.animationFrame = (self.animationFrame % #self.busyEmojis) + 1
    self.menubar:setTitle(self.busyEmojis[self.animationFrame])
  end)
end

function obj:stopAnimation()
  if self.animationTimer then
    self.animationTimer:stop()
    self.animationTimer = nil
  end
end
```

- [ ] **Step 2: Verify icon states**

Reload Hammerspoon.
- With Claude idle in some sessions: should show 💤
- Ask Claude to do something long-running in all sessions: should animate 🤔💡
- Kill all Claude processes: icon should disappear

- [ ] **Step 3: Commit**

```bash
git add Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: add icon animation for busy/idle state transitions"
```

---

## Task 4: Dropdown Menu

**Files:**
- Modify: `Spoons/ClaudeCodeStatus.spoon/init.lua`

- [ ] **Step 1: Implement buildMenu callback**

Add the menu builder and wire it to the menubar in `start()`:

```lua
function obj:buildMenu()
  local menuItems = {}

  -- Header
  table.insert(menuItems, {
    title = "Claude Code Sessions (" .. #self.sessions .. ")",
    disabled = true
  })
  table.insert(menuItems, { title = "-" }) -- separator

  -- Session rows
  for _, s in ipairs(self.sessions) do
    local icon = s.busy and "◉" or "◯"
    local tmuxLabel = ""
    if s.tmux then
      tmuxLabel = s.tmux.session .. ":" .. s.tmux.window
    end

    local title = icon .. "  " .. s.project
    if tmuxLabel ~= "" then
      -- Pad to align right column
      local padding = string.rep(" ", math.max(1, 30 - #s.project))
      title = title .. padding .. tmuxLabel
    end

    table.insert(menuItems, {
      title = title,
      fn = function() obj:switchToSession(s) end,
      disabled = (s.tmux == nil)
    })
  end

  -- Footer
  table.insert(menuItems, { title = "-" })
  table.insert(menuItems, {
    title = "↻ Refresh",
    fn = function() obj:refresh() end
  })

  return menuItems
end
```

Add the `setMenu` line inside the existing `start()` function, after the `self.pollTimer` line:

```lua
-- Add this line inside start(), after the pollTimer line:
self.menubar:setMenu(function() return self:buildMenu() end)
```

- [ ] **Step 2: Verify dropdown**

Reload Hammerspoon. Click the 💤 icon. Verify:
- Header shows session count
- Each session shows ◉/◯ with project name and tmux location
- Refresh button works

- [ ] **Step 3: Commit**

```bash
git add Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: add dropdown menu showing session list"
```

---

## Task 5: Session Switching

**Files:**
- Modify: `Spoons/ClaudeCodeStatus.spoon/init.lua`

- [ ] **Step 1: Implement switchToSession**

```lua
function obj:switchToSession(session)
  if not session.tmux then return end

  local target = session.tmux.session .. ":" .. session.tmux.window

  -- Find the tmux client to switch
  local clientOut = hs.execute("tmux list-clients -F '#{client_name}' 2>/dev/null")
  if clientOut then
    local client = clientOut:match("[^\n]+")
    if client then
      hs.execute("tmux switch-client -c '" .. client .. "' -t '" .. target .. "' 2>/dev/null")
    end
  end

  -- Bring iTerm2 to foreground
  hs.application.launchOrFocus("iTerm2")
end
```

- [ ] **Step 2: Verify switching**

Reload Hammerspoon. Click the menu bar icon, then click on a session that is NOT the currently visible one. Verify:
- iTerm2 comes to foreground
- tmux switches to the correct session and window

- [ ] **Step 3: Commit**

```bash
git add Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: implement session switching via tmux and iTerm2"
```

---

## Task 6: Integration into init.lua

**Files:**
- Modify: `init.lua`

- [ ] **Step 1: Add ClaudeCodeStatus to init.lua**

Since this is a local-only Spoon (not in the official Spoon repo), `SpoonInstall:andUse` with `use_syncinstall = true` will fail. Use direct loading instead.

Add after the existing `Install:andUse` calls:

```lua
hs.loadSpoon("ClaudeCodeStatus")
spoon.ClaudeCodeStatus:start()
```

- [ ] **Step 2: Clean up temporary loading code**

If temporary `hs.loadSpoon` / `spoon.ClaudeCodeStatus:start()` lines were added elsewhere in `init.lua` during Task 1 Step 3, remove them to avoid duplicate loading. Ensure only one copy exists.

- [ ] **Step 3: Full integration test**

Reload Hammerspoon. Verify:
- Icon appears when Claude sessions are running
- Icon hides when no Claude sessions
- Dropdown lists all sessions correctly
- Clicking a session switches iTerm2/tmux
- Animation works when all sessions are busy

- [ ] **Step 4: Commit**

```bash
git add init.lua Spoons/ClaudeCodeStatus.spoon/init.lua
git commit -m "feat: integrate ClaudeCodeStatus Spoon into init.lua"
```
