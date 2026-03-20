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
  -- self:refresh()  -- Will be enabled in Task 2
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
