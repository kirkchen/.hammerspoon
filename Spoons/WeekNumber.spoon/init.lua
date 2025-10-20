--- === WeekNumber ===
---
--- Menubar display weeknumber
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpeedMenu.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpeedMenu.spoon.zip)

local obj={}
obj.__index = obj

-- Metadata
obj.name = "WeekNumber"
obj.version = "1.2"
obj.author = "Kirk Chen <rwk0119@yahoo.com.tw>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

local function getYearBeginDayOfWeek(tm)
    local yearBegin = os.time{year=os.date("*t",tm).year,month=1,day=1}
    local yearBeginDayOfWeek = tonumber(os.date("%w",yearBegin))
    -- sunday correct from 0 -> 7
    if(yearBeginDayOfWeek == 0) then yearBeginDayOfWeek = 7 end
    return yearBeginDayOfWeek
end

local function getDayAdd(tm)
    local yearBeginDayOfWeek = getYearBeginDayOfWeek(tm)
    if(yearBeginDayOfWeek < 5 ) then
      -- first day is week 1
      dayAdd = (yearBeginDayOfWeek - 2)
    else 
      -- first day is week 52 or 53
      dayAdd = (yearBeginDayOfWeek - 9)
    end  

    return dayAdd
end

local function getWeekNumberOfYear(tm)
    local dayOfYear = os.date("%j",tm)
    local dayAdd = getDayAdd(tm)
    local weekNumber = math.floor((dayOfYear + dayAdd) / 7) + 1
    return weekNumber
end

local function getCycleAndWeek(tm)
    local weekNumber = getWeekNumberOfYear(tm)

    -- Each quarter has 13 weeks: 6 (C1) + 6 (C2) + 1 (Wiggle)
    local quarter = math.floor((weekNumber - 1) / 13) + 1
    local weekInQuarter = ((weekNumber - 1) % 13) + 1

    -- Handle week 53 (rare year with 53 weeks)
    if quarter > 4 then
        quarter = 4
        weekInQuarter = 13
    end

    if weekInQuarter <= 6 then
        -- First cycle (C1)
        return string.format("Q%dC1W%d (w%d)", quarter, weekInQuarter, weekNumber)
    elseif weekInQuarter <= 12 then
        -- Second cycle (C2)
        local weekInC2 = weekInQuarter - 6
        return string.format("Q%dC2W%d (w%d)", quarter, weekInC2, weekNumber)
    else
        -- Wiggle week (week 13 of quarter)
        return string.format("Q%dC2WW (w%d)", quarter, weekNumber)
    end
end  

local function reload()
    obj.menubar:setTitle(getCycleAndWeek(os.time()))
end

function obj:init()
    self.menubar = hs.menubar.new()
  end

function obj:start()
    reload()
    obj.timer = hs.timer.doEvery(60 * 60, reload)
end
  
function obj:stop()
    if obj.timer then
        obj.timer.stop()
        obj.timer = nil
    end
end

return obj