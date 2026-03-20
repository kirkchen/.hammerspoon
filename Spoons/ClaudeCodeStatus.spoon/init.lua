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

-- Menu bar icons (template images, auto-adapt to light/dark mode)
local function makeIcon(size, drawFn)
  local canvas = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
  drawFn(canvas, size)
  local img = canvas:imageFromCanvas()
  canvas:delete()
  return img:template(true)
end

-- Sparkle/star icon - Claude-inspired
local function drawSparkle(canvas, size)
  -- Four-pointed star
  local cx, cy = size / 2, size / 2
  local outer = size * 0.45
  local inner = size * 0.12
  local points = {}
  for i = 0, 7 do
    local angle = (i * math.pi / 4) - (math.pi / 2)
    local r = (i % 2 == 0) and outer or inner
    table.insert(points, { x = cx + r * math.cos(angle), y = cy + r * math.sin(angle) })
  end
  canvas:appendElements({
    type = "segments",
    coordinates = points,
    closed = true,
    fillColor = { black = 1 },
    action = "fill",
  })
end

-- Smaller sparkle for animation frame 2
local function drawSparkleSmall(canvas, size)
  local cx, cy = size / 2, size / 2
  local outer = size * 0.3
  local inner = size * 0.08
  local points = {}
  for i = 0, 7 do
    local angle = (i * math.pi / 4) - (math.pi / 2)
    local r = (i % 2 == 0) and outer or inner
    table.insert(points, { x = cx + r * math.cos(angle), y = cy + r * math.sin(angle) })
  end
  canvas:appendElements({
    type = "segments",
    coordinates = points,
    closed = true,
    fillColor = { black = 1 },
    action = "fill",
  })
end

local iconSize = 18
local idleIcon = makeIcon(iconSize, drawSparkle)
local busyIcons = {
  makeIcon(iconSize, drawSparkle),
  makeIcon(iconSize, drawSparkleSmall),
}

-- Internal state
obj.menubar = nil
obj.pollTimer = nil
obj.animationTimer = nil
obj.animationFrame = 1
obj.sessions = {}
obj.anyBusy = false
obj.onRefresh = nil  -- callback function(sessions), called after each scan

-- Resolve tmux path (Hammerspoon GUI apps lack /opt/homebrew/bin in PATH)
local tmuxPath
for _, p in ipairs({"/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"}) do
  if hs.fs.attributes(p) then
    tmuxPath = p
    break
  end
end

local function scanSessions()
  local sessions = {}
  local homeDir = os.getenv("HOME")

  -- Step 1: Read session files from ~/.claude/sessions/
  local sessionsDir = homeDir .. "/.claude/sessions"
  local sessionData = {}
  local allPids = {}

  local iter, dirObj = hs.fs.dir(sessionsDir)
  if not iter then return sessions end

  for filename in iter, dirObj do
    local pidStr = filename:match("^(%d+)%.json$")
    if pidStr then
      local pid = tonumber(pidStr)
      local f = io.open(sessionsDir .. "/" .. filename, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(hs.json.decode, content)
        if ok and data then
          table.insert(sessionData, {
            pid = pid,
            cwd = data.cwd or "",
          })
          table.insert(allPids, pid)
        end
      end
    end
  end

  if #sessionData == 0 then return sessions end

  -- Step 2: Single ps call for alive check, process tree, AND child commands
  local psOut = hs.execute("ps -eo pid,ppid,command 2>/dev/null")
  local alivePids = {}
  local parentOf = {}
  local childrenOf = {} -- pid -> list of command strings
  if psOut then
    for line in psOut:gmatch("[^\n]+") do
      local p, pp, cmd = line:match("^%s*(%d+)%s+(%d+)%s+(.+)")
      if p and pp and cmd then
        p = tonumber(p)
        pp = tonumber(pp)
        alivePids[p] = true
        parentOf[p] = pp
        if not childrenOf[pp] then childrenOf[pp] = {} end
        table.insert(childrenOf[pp], cmd)
      end
    end
  end

  -- Step 3: Get tmux pane mapping
  if not tmuxPath then return sessions end
  local tmuxOut = hs.execute(tmuxPath .. " list-panes -a -F '#{pane_pid} #{session_name} #{window_index} #{pane_index}' 2>/dev/null")
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

  -- Step 4: For each alive session, resolve tmux location and busy state
  local now = os.time()
  for _, sd in ipairs(sessionData) do
    if alivePids[sd.pid] then
      local pid = sd.pid
      local projectName = sd.cwd:match("([^/]+)$") or "unknown"

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

      -- Check busy state from pre-built children map
      local isBusy = false
      local status = "Waiting for input"
      local children = childrenOf[pid] or {}
      for _, cmd in ipairs(children) do
        -- Skip long-lived background children (MCP servers, caffeinate, etc.)
        local isBackground = cmd:match("mcp%-server") or cmd:match("@modelcontextprotocol")
          or cmd:match("context7") or cmd:match("npx ") or cmd:match("mcp%-")
          or cmd:match("caffeinate")
        if not isBackground then
          isBusy = true
          cmd = cmd:gsub("%s+$", "")
          local comm = cmd:match("([^/]+)$") or cmd
          if comm:match("^bash") or comm:match("^zsh") or comm:match("^sh$") or comm:match("^sh ") then
            status = "Running command"
          elseif comm:match("^git") then
            status = "Running git"
          elseif comm:match("^node") or comm:match("^claude") then
            status = "Thinking..."
          else
            status = "Working..."
          end
          break
        end
      end

      table.insert(sessions, {
        pid = pid,
        project = projectName,
        busy = isBusy,
        status = status,
        tmux = tmuxInfo,
        cwd = sd.cwd
      })
    end
  end

  -- Step 5: Batch-check transcript mtime for idle sessions to detect "thinking"
  local idleDirs = {}
  local idleSessionsByDir = {}
  for i, s in ipairs(sessions) do
    if not s.busy then
      local encodedCwd = s.cwd:gsub("[/.]", "-")
      local dir = homeDir .. "/.claude/projects/" .. encodedCwd
      if not idleSessionsByDir[dir] then
        idleSessionsByDir[dir] = {}
        table.insert(idleDirs, dir)
      end
      table.insert(idleSessionsByDir[dir], i)
    end
  end

  if #idleDirs > 0 then
    -- Single shell call: for each dir, find newest .jsonl mtime
    local parts = {}
    for _, dir in ipairs(idleDirs) do
      table.insert(parts, "f=$(ls -t '" .. dir .. "/'*.jsonl 2>/dev/null | head -1);"
        .. "[ -n \"$f\" ] && echo '" .. dir .. " '$(stat -f '%m' \"$f\" 2>/dev/null)")
    end
    local batchOut = hs.execute(table.concat(parts, ";") .. " 2>/dev/null")
    if batchOut then
      for dir, mtime in batchOut:gmatch("(%S+)%s+(%d+)") do
        if (now - tonumber(mtime)) < 30 then
          local indices = idleSessionsByDir[dir]
          if indices then
            for _, i in ipairs(indices) do
              sessions[i].busy = true
              sessions[i].status = "Thinking..."
            end
          end
        end
      end
    end
  end

  -- Remove internal cwd field from session data
  for _, s in ipairs(sessions) do s.cwd = nil end

  return sessions
end

function obj:init()
  self.menubar = hs.menubar.new()
  self.menubar:removeFromMenuBar()  -- Start hidden; first refresh() will show if needed
end

function obj:refresh()
  self.sessions = scanSessions()
  self:updateIcon()
  if self.onRefresh then self.onRefresh(self.sessions) end
end

function obj:updateIcon()
  if #self.sessions == 0 then
    self.menubar:removeFromMenuBar()
    self:stopAnimation()
    self.anyBusy = false
    return
  end

  self.menubar:returnToMenuBar()

  local anyBusy = false
  for _, s in ipairs(self.sessions) do
    if s.busy then
      anyBusy = true
      break
    end
  end

  if anyBusy and not self.anyBusy then
    self.anyBusy = true
    self:startAnimation()
  elseif not anyBusy and self.anyBusy then
    self.anyBusy = false
    self:stopAnimation()
    self.menubar:setTitle("")
    self.menubar:setIcon(idleIcon)
  elseif not anyBusy then
    self.menubar:setTitle("")
    self.menubar:setIcon(idleIcon)
  end
end

function obj:startAnimation()
  self:stopAnimation()
  self.animationFrame = 1
  self.menubar:setTitle("")
  self.menubar:setIcon(busyIcons[1])
  self.animationTimer = hs.timer.doEvery(self.animationInterval, function()
    self.animationFrame = (self.animationFrame % #busyIcons) + 1
    self.menubar:setIcon(busyIcons[self.animationFrame])
  end)
end

function obj:stopAnimation()
  if self.animationTimer then
    self.animationTimer:stop()
    self.animationTimer = nil
  end
end

function obj:buildMenu()
  local menuItems = {}

  -- Header
  table.insert(menuItems, {
    title = "Claude Code Sessions (" .. #self.sessions .. ")",
    disabled = true
  })
  table.insert(menuItems, { title = "-" }) -- separator

  -- Session rows
  local monoFont = { name = "Menlo", size = 12 }
  for _, s in ipairs(self.sessions) do
    local icon = s.busy and "◉" or "◯"
    local left = icon .. " " .. s.project
    local padding = string.rep(" ", math.max(2, 24 - #s.project))
    local text = left .. padding .. s.status
    local styledTitle = hs.styledtext.new(text, { font = monoFont })

    table.insert(menuItems, {
      title = styledTitle,
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

function obj:switchToSession(session)
  if not session.tmux then return end

  local target = session.tmux.session .. ":" .. session.tmux.window

  -- Find the tmux client to switch
  local clientOut = hs.execute(tmuxPath .. " list-clients -F '#{client_name}' 2>/dev/null")
  if clientOut then
    local client = clientOut:match("[^\n]+")
    if client then
      local safeClient = client:gsub("'", "'\\''")
      local safeTarget = target:gsub("'", "'\\''")
      hs.execute(tmuxPath .. " switch-client -c '" .. safeClient .. "' -t '" .. safeTarget .. "' 2>/dev/null")
    end
  end

  -- Bring iTerm2 to foreground
  hs.application.launchOrFocus("iTerm2")
end

function obj:start()
  self:refresh()
  self.pollTimer = hs.timer.doEvery(self.pollInterval, function() self:refresh() end)
  self.menubar:setMenu(function() return self:buildMenu() end)
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
