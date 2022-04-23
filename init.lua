-- Spoon Install
hs.loadSpoon("SpoonInstall")

spoon.SpoonInstall.use_syncinstall = true

Install = spoon.SpoonInstall

-- Install Spoons
Install:andUse("ReloadConfiguration", { start = true })
Install:andUse("Caffeine", { start = true })
Install:andUse("WeekNumber", { start = true })
Install:andUse("KSheet",
  {
    hotkeys = {
      toggle = { { "cmd", "alt" }, "/" }
    }
  })

-- HANDLE SCROLLING
local oldmousepos = {}
local scrollmult = -4	-- negative multiplier makes mouse work like traditional scrollwheel
local reverse = true

mousetap = hs.eventtap.new({5}, function(e)
    oldmousepos = hs.mouse.getAbsolutePosition()
    local mods = hs.eventtap.checkKeyboardModifiers()
    if mods['cmd'] then
        local dx = e:getProperty(hs.eventtap.event.properties['mouseEventDeltaX'])
        local dy = e:getProperty(hs.eventtap.event.properties['mouseEventDeltaY'])
        if reverse then
            dx = dx * -1
            dy = dy * -1
        end
        local scroll = hs.eventtap.event.newScrollEvent({dx * scrollmult, dy * scrollmult},{},'pixel')
        scroll:post()

        -- put the mouse back
        hs.mouse.setAbsolutePosition(oldmousepos)

        return false, {}
    else
        return false, {}
    end
end)
mousetap:start()
