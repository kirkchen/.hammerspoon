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
obj.anyBusy = false

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

  -- Step 1: Find Claude CLI PIDs
  local pgrepOut = hs.execute("pgrep -fl claude 2>/dev/null")
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

    -- Check busy state by looking for tool child processes (not MCP servers)
    local childPids = hs.execute("pgrep -P " .. pid .. " 2>/dev/null")
    local isBusy = false
    local status = "Waiting for input"
    if childPids and childPids ~= "" then
      -- Get commands of all children in one ps call
      local pids = childPids:gsub("\n", ","):gsub(",$", "")
      local childInfo = hs.execute("ps -p " .. pids .. " -o pid=,command= 2>/dev/null")
      if childInfo then
        for line in childInfo:gmatch("[^\n]+") do
          local cmd = line:match("^%s*%d+%s+(.+)")
          if cmd then
            -- Skip MCP servers (long-lived background children)
            local isMcp = cmd:match("mcp%-server") or cmd:match("@modelcontextprotocol")
              or cmd:match("context7") or cmd:match("npx ")
            if not isMcp then
              isBusy = true
              cmd = cmd:gsub("%s+$", "")
              local comm = cmd:match("([^/]+)$") or cmd
              if comm:match("^bash") or comm:match("^zsh") or comm:match("^sh$") or comm:match("^sh ") then
                status = "Running command"
              elseif comm:match("^git") then
                status = "Running git"
              elseif comm:match("^node") then
                status = "Thinking..."
              else
                status = "Working..."
              end
              break
            end
          end
        end
      end
    end

    table.insert(sessions, {
      pid = pid,
      project = projectName,
      busy = isBusy,
      status = status,
      tmux = tmuxInfo
    })
  end

  return sessions
end

function obj:init()
  self.menubar = hs.menubar.new()
  self.menubar:removeFromMenuBar()  -- Start hidden; first refresh() will show if needed
end

function obj:refresh()
  self.sessions = scanSessions()
  self:updateIcon()
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
    self.menubar:setTitle(self.idleEmoji)
  elseif not anyBusy then
    self.menubar:setTitle(self.idleEmoji)
  end
end

function obj:startAnimation()
  self:stopAnimation()
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
