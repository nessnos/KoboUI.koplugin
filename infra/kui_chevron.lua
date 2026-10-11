--[[--
kui_chevron.lua — KoboUI

The wide, shallow "pull down" chevron from the Kindle-style toolbar plugin
(kindletoolbar.koplugin), drawn exactly the same way: a thick "V" with round
caps. KoboUI shows it in the middle of the top bar on the Home screen and
in the Library, in place of SimpleUI's "﹀" glyph.

Default size is the toolbar's: 66 × 10 (scaled), stroke max(3, 4 scaled).
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local Screen     = require("device").screen

local Chevron = Widget:extend{
    width     = nil,
    height    = nil,
    thickness = nil,
    fgcolor   = nil, -- defaults to black
    up        = false, -- true: points up (used to close the quick-settings panel)
}

function Chevron:init()
    self.width     = self.width     or Screen:scaleBySize(66)
    self.height    = self.height    or Screen:scaleBySize(10)
    self.thickness = self.thickness or math.max(3, Screen:scaleBySize(4))
end

function Chevron:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Chevron:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local color = self.fgcolor or Blitbuffer.COLOR_BLACK
    -- A wide, shallow "V" with a thick stroke and rounded ends, like KindleOS'
    local w, t = self.width, self.thickness
    local r = math.floor(t / 2)
    local half = (w - 1) / 2
    local drop = self.height - t -- how far the tip sits below the ends
    for i = r, w - 1 - r do
        local d = half - math.abs(i - half) -- 0 at the ends, half at the tip
        local off = math.floor(drop * (d - r) / (half - r) + 0.5)
        if self.up then off = drop - off end
        bb:paintRect(x + i, y + off, 1, t, color)
    end
    -- round caps
    local cap_y = self.up and (y + drop) or y
    bb:paintRoundedRect(x, cap_y, t, t, color, r)
    bb:paintRoundedRect(x + w - t, cap_y, t, t, color, r)
end

return Chevron
