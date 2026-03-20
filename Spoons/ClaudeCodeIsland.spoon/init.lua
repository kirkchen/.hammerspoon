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

return obj
