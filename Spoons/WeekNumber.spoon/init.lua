--- === WeekNumber ===
---
--- Menubar display weeknumber
---
--- Download: [https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpeedMenu.spoon.zip](https://github.com/Hammerspoon/Spoons/raw/master/Spoons/SpeedMenu.spoon.zip)

local obj={}
obj.__index = obj

-- Metadata
obj.name = "WeekNumber"
obj.version = "1.0"
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
    local dayOfYearCorrected = dayOfYear + dayAdd
    if(dayOfYearCorrected < 0) then
      -- week of last year - decide if 52 or 53
      local lastYearBegin = os.time{year=os.date("*t",tm).year-1,month=1,day=1}
      local lastYearEnd = os.time{year=os.date("*t",tm).year-1,month=12,day=31}
      local dayAdd = getDayAdd(lastYearBegin)
      local dayOfYear = dayOfYear + os.date("%j",lastYearEnd)
      dayOfYearCorrected = dayOfYear + dayAdd
    end  

    local weekNum = math.floor((dayOfYearCorrected) / 7) + 1
    if( (dayOfYearCorrected > 0) and weekNum == 53) then
      -- check if it is not considered as part of week 1 of next year
      local nextYearBegin = os.time{year=os.date("*t",tm).year+1,month=1,day=1}
      local yearBeginDayOfWeek = getYearBeginDayOfWeek(nextYearBegin)
      if(yearBeginDayOfWeek < 5 ) then
        weekNum = 1
      end  
    end  
    return weekNum
end  

local function reload()
    obj.menubar:setTitle("w"..tostring(getWeekNumberOfYear(os.time())))
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