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

-- Internal state
obj.canvas = nil
obj.position = nil       -- { x, y } or nil for default
obj.state = "hidden"     -- "hidden", "collapsed", "expanded"
obj.busySessions = {}    -- current busy sessions for click handling
obj.lastSessions = {}    -- all sessions from last update
obj.animTimer = nil      -- frame animation timer
obj.pulseTimer = nil     -- dot pulse timer
obj.pulseAlpha = 1.0     -- current pulse opacity
obj.screenWatcher = nil
obj.dragging = false
obj.dragStart = { x = 0, y = 0 }
obj.dragOffset = { x = 0, y = 0 }

local DRAG_THRESHOLD = 3

local function lerp(a, b, t) return a + (b - a) * t end

-- Position stores center-x (cx) and y, so expand/collapse stays centered
function obj:getPosition(targetWidth)
  if self.position then
    return { x = self.position.cx - targetWidth / 2, y = self.position.y }
  end
  local screen = hs.screen.mainScreen():frame()
  return {
    x = screen.x + (screen.w - targetWidth) / 2,
    y = screen.y + self.margin
  }
end

function obj:init()
  self.position = hs.settings.get("ClaudeCodeIsland.position")
  self.canvas = hs.canvas.new({ x = 0, y = 0, w = self.collapsedWidth, h = self.collapsedHeight })
  self.canvas:level(hs.canvas.windowLevels.overlay)
  self.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
    + hs.canvas.windowBehaviors.stationary)

  self.canvas:canvasMouseEvents(true, true, true, true)
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
        self.position = { cx = f.x + f.w / 2, y = f.y }
        hs.settings.set("ClaudeCodeIsland.position", self.position)
      elseif id and type(id) == "string" and id:match("^row%-") then
        local idx = tonumber(id:match("row%-(%d+)"))
        if idx and self.busySessions[idx] then
          spoon.ClaudeCodeStatus:switchToSession(self.busySessions[idx])
        end
      end
      self.dragging = false
    elseif msg == "mouseEnter" then
      if #self.busySessions > 0 and self.state == "collapsed" then
        self:snapExpanded(self.busySessions)
      end
    elseif msg == "mouseExit" then
      -- Verify mouse is actually outside (replaceElements triggers spurious exits)
      local mouse = hs.mouse.absolutePosition()
      local f = c:frame()
      local inside = mouse.x >= f.x and mouse.x <= f.x + f.w
                 and mouse.y >= f.y and mouse.y <= f.y + f.h
      if not inside and self.state == "expanded" and not self.dragging then
        self:snapCollapsed(#self.lastSessions, #self.busySessions)
      end
    end
  end)
end

function obj:renderCollapsed(sessionCount, busyCount)
  local h = self.collapsedHeight
  local dotColor
  local label
  if busyCount > 0 then
    dotColor = { red = 0.98, green = 0.8, blue = 0.08, alpha = 1 }
    label = busyCount .. " / " .. sessionCount
  else
    dotColor = { red = 0.33, green = 0.33, blue = 0.33, alpha = 1 }
    label = tostring(sessionCount)
  end
  -- Dynamic width based on label length
  local w = math.max(self.collapsedWidth, 26 + #label * 7 + 12)
  local elements = {
    {  -- Background (trackMouseEnterExit for hover detection)
      type = "rectangle",
      id = "bg",
      frame = { x = 0, y = 0, w = w, h = h },
      roundedRectRadii = { xRadius = h / 2, yRadius = h / 2 },
      fillColor = self.bgColor,
      action = "fill",
      trackMouseEnterExit = true,
    },
    {  -- Status dot
      type = "circle",
      center = { x = 18, y = h / 2 + 2 },
      radius = 3.5,
      fillColor = dotColor,
      action = "fill",
    },
    {  -- Session count
      type = "text",
      frame = { x = 26, y = (h - 14) / 2 + 2, w = w - 26, h = 14 },
      text = hs.styledtext.new(label, {
        font = { name = "Menlo", size = 11 },
        color = { red = 0.53, green = 0.53, blue = 0.53, alpha = 1 },
        paragraphStyle = { alignment = "left", lineBreak = "clip" },
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

  -- Always show collapsed pill; hover expands
  if self.state ~= "expanded" then
    self:showCollapsed(#sessions, #busy)
  else
    -- If hovering and expanded, update content in place
    if #busy > 0 then
      self:renderExpanded(busy)
    else
      self:showCollapsed(#sessions, 0)
    end
  end
end

function obj:animateTo(targetFrame, callback)
  -- Cancel any in-progress animation
  if self.animTimer then self.animTimer:stop(); self.animTimer = nil end

  local startFrame = self.canvas:frame()
  local steps = 15  -- 250ms at 60fps
  local step = 0
  self.animTimer = hs.timer.doEvery(1/60, function()
    step = step + 1
    local p = 1 - (1 - step / steps) ^ 3  -- ease-out cubic
    self.canvas:frame({
      x = lerp(startFrame.x, targetFrame.x, p),
      y = lerp(startFrame.y, targetFrame.y, p),
      w = lerp(startFrame.w, targetFrame.w, p),
      h = lerp(startFrame.h, targetFrame.h, p),
    })
    if step >= steps then
      self.animTimer:stop()
      self.animTimer = nil
      if callback then callback() end
    end
  end)
end

function obj:showCollapsed(sessionCount, busyCount)
  self:stopPulse()

  local w, h = self:renderCollapsed(sessionCount, busyCount)
  local pos = self:getPosition(w)
  local targetFrame = { x = pos.x, y = pos.y, w = w, h = h }

  if self.state == "hidden" then
    self.canvas:frame(targetFrame)
    self.canvas:show()
  else
    self:animateTo(targetFrame)
  end
  self.state = "collapsed"
end

function obj:snapExpanded(busySessions)
  if self.animTimer then self.animTimer:stop(); self.animTimer = nil end
  local w, h = self:renderExpanded(busySessions)
  local pos = self:getPosition(w)
  self.canvas:frame({ x = pos.x, y = pos.y, w = w, h = h })
  self.canvas:show()
  self.state = "expanded"
  self:startPulse()
end

function obj:snapCollapsed(sessionCount, busyCount)
  if self.animTimer then self.animTimer:stop(); self.animTimer = nil end
  self:stopPulse()
  local w, h = self:renderCollapsed(sessionCount, busyCount)
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

function obj:renderExpanded(busySessions)
  local w = self.expandedWidth
  local h = self.paddingY + #busySessions * self.rowHeight + self.paddingY
  local elements = {
    {  -- Background
      type = "rectangle",
      id = "bg",
      frame = { x = 0, y = 0, w = w, h = h },
      roundedRectRadii = { xRadius = self.cornerRadius, yRadius = self.cornerRadius },
      fillColor = self.bgColor,
      action = "fill",
      trackMouseEnterExit = true,
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
    local textY = y + (self.rowHeight - 15) / 2 + 2
    table.insert(elements, {
      type = "circle",
      center = { x = 18, y = y + self.rowHeight / 2 + 2 },
      radius = 3.5,
      fillColor = dotColor,
      action = "fill",
    })

    -- Project name
    table.insert(elements, {
      type = "text",
      frame = { x = 28, y = textY, w = 120, h = 15 },
      text = hs.styledtext.new(s.project, {
        font = { name = "Menlo", size = 12 },
        color = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
        paragraphStyle = { alignment = "left", lineBreak = "clip" },
      }),
    })

    -- Status text
    table.insert(elements, {
      type = "text",
      frame = { x = 148, y = textY, w = w - 162, h = 15 },
      text = hs.styledtext.new(s.status, {
        font = { name = "Menlo", size = 11 },
        color = { red = 0.6, green = 0.6, blue = 0.6, alpha = 1 },
        paragraphStyle = { alignment = "right", lineBreak = "clip" },
      }),
    })
  end

  self.canvas:replaceElements(elements)
  return w, h
end

function obj:showExpanded(busySessions)
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
  if self.screenWatcher then self.screenWatcher:stop(); self.screenWatcher = nil end
  if self.canvas then self.canvas:hide() end
  self.state = "hidden"
  return self
end

function obj:resetPosition()
  self.position = nil
  hs.settings.set("ClaudeCodeIsland.position", nil)
  if self.state ~= "hidden" then
    local f = self.canvas:frame()
    local pos = self:getPosition(f.w)
    self.canvas:frame({ x = pos.x, y = pos.y, w = f.w, h = f.h })
  end
end

function obj:clampPosition()
  if not self.position then return end
  local screen = hs.screen.mainScreen():frame()
  local f = self.canvas:frame()
  local maxCx = screen.x + screen.w - f.w / 2
  local minCx = screen.x + f.w / 2
  self.position.cx = math.max(minCx, math.min(self.position.cx, maxCx))
  self.position.y = math.max(screen.y, math.min(self.position.y, screen.y + screen.h - f.h))
  local pos = self:getPosition(f.w)
  self.canvas:frame({ x = pos.x, y = self.position.y, w = f.w, h = f.h })
  hs.settings.set("ClaudeCodeIsland.position", self.position)
end

return obj
