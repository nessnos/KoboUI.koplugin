--[[--
kui_battery.lua — KoboUI

A horizontal battery like KindleOS draws it: an outlined body with a small
cap on the right, filled in proportion to the charge. While charging, a small
bolt is cut out of the middle.

    KUIBattery:new{ level = 82, charging = false, height = <px>, fgcolor = … }
Width is about 2.1 × height (cap included).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local Screen     = require("device").screen

local Battery = Widget:extend{
    level    = 100,
    charging = false,
    height   = nil,
    fgcolor  = nil,
}

function Battery:init()
    self.height = self.height or Screen:scaleBySize(14)
    self.width  = math.floor(self.height * 2.1)
end

function Battery:getSize() return Geom:new{ w = self.width, h = self.height } end

function Battery:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local fg = self.fgcolor or Blitbuffer.COLOR_BLACK
    local h = self.height
    local b = math.max(1, math.floor(h / 8))           -- outline thickness
    local cap_w = math.max(2, math.floor(h / 6))
    local body_w = self.width - cap_w
    -- KoboUI: nearly square corners, like Kobo's battery
    local r = self.radius or math.max(0, math.floor(h / 14))
    if r > 0 then bb:paintBorder(x, y, body_w, h, b, fg, r) else bb:paintBorder(x, y, body_w, h, b, fg) end
    local cap_h = math.floor(h / 2)
    bb:paintRect(x + body_w, y + math.floor((h - cap_h) / 2), cap_w, cap_h, fg)
    local gap = b + math.max(1, math.floor(h / 10))
    local inner_w = body_w - gap * 2
    local lvl = math.max(0, math.min(100, tonumber(self.level) or 0))
    local fill = math.floor(inner_w * lvl / 100 + 0.5)
    if fill > 0 then
        bb:paintRect(x + gap, y + gap, fill, h - gap * 2, fg)
    end
    if self.charging then
        -- a small bolt in the middle, in the background colour over the fill
        local cx = x + math.floor(body_w / 2)
        local top, bot = y + gap, y + h - gap
        local mid = math.floor((top + bot) / 2)
        local bg = Blitbuffer.COLOR_WHITE
        local col = fill > inner_w / 2 and bg or fg
        for yy = top, bot - 1 do
            local off
            if yy < mid then off = math.floor((mid - yy) / 2) else off = -math.floor((yy - mid) / 2) end
            bb:paintRect(cx + off - 1, yy, math.max(2, math.floor(h / 7)), 1, col)
        end
    end
end

return Battery
