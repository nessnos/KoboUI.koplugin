--[[--
qp_slider.lua — KoboUI quick settings: the light sliders.

A thin rail, a thicker filled bar up to the current value and a round black
knob with a white rim. Tap anywhere on the rail to jump there, or drag the
knob. The widget only draws and maps positions to values; the panel feeds
it the gestures.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local Screen     = require("device").screen

local Slider = Widget:extend{
    width     = 0,
    value     = 0,
    value_min = 0,
    value_max = 100,
    on_change = nil,   -- function(value, is_final)
    value_face = nil,  -- when set, the current value is written above the knob
}

function Slider:init()
    self.r       = self.r or Screen:scaleBySize(15)
    self.rail_h  = math.max(2, Screen:scaleBySize(2))
    self.fill_h  = math.max(4, Screen:scaleBySize(6))
    self.rim     = math.max(2, Screen:scaleBySize(2))
    self.label_h = 0
    if self.value_face then
        local TextWidget = require("ui/widget/textwidget")
        local t = TextWidget:new{ text = "0", face = self.value_face }
        self.label_h = t:getSize().h + Screen:scaleBySize(4)
        t:free()
    end
    self.height  = self.label_h + self.r * 2 + Screen:scaleBySize(8)
    self.dimen   = Geom:new{ w = self.width, h = self.height }
    self.value   = self:clamp(self.value)
end

function Slider:clamp(v)
    v = math.floor((v or 0) + 0.5)
    return math.max(self.value_min, math.min(self.value_max, v))
end

function Slider:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

-- x range the knob centre can travel (local coordinates)
function Slider:_ends()
    return self.r, self.width - self.r
end

function Slider:_xFor(v)
    local a, b = self:_ends()
    local span = self.value_max - self.value_min
    if span <= 0 then return a end
    return math.floor(a + (v - self.value_min) / span * (b - a) + 0.5)
end

function Slider:valueAt(abs_x)
    local a, b = self:_ends()
    local lx = abs_x - (self.dimen.x or 0)
    local f = (lx - a) / math.max(1, b - a)
    f = math.max(0, math.min(1, f))
    return self:clamp(self.value_min + f * (self.value_max - self.value_min))
end

function Slider:knobHit(pos)
    if not self.dimen.x then return false end
    local kx = self.dimen.x + self:_xFor(self.value)
    return math.abs(pos.x - kx) <= self.r * 2
        and pos.y >= self.dimen.y - self.r and pos.y <= self.dimen.y + self.height + self.r
end

function Slider:hit(pos)
    if not self.dimen.x then return false end
    local d = self.dimen
    return pos.x >= d.x and pos.x <= d.x + d.w
        and pos.y >= d.y - self.r and pos.y <= d.y + d.h + self.r
end

--- Moves to `v`; calls on_change when the value changes (or when final).
function Slider:set(v, is_final)
    v = self:clamp(v)
    local changed = v ~= self.value
    self.value = v
    if (changed or is_final) and self.on_change then self.on_change(v, is_final) end
    return changed
end

local function pill(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    bb:paintRoundedRect(x, y, w, h, color, math.floor(h / 2))
end

local function disc(bb, cx, cy, r, color)
    bb:paintRoundedRect(cx - r, cy - r, r * 2, r * 2, color, r)
end

function Slider:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local cy = y + self.label_h + math.floor((self.height - self.label_h) / 2)
    local a, b = self:_ends()
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    -- rail
    pill(bb, x + a - self.rail_h, cy - math.floor(self.rail_h / 2), (b - a) + self.rail_h * 2, self.rail_h,
        Blitbuffer.COLOR_BLACK)
    -- filled part
    local kx = x + self:_xFor(self.value)
    pill(bb, x + a - math.floor(self.fill_h / 2), cy - math.floor(self.fill_h / 2),
        kx - (x + a) + self.fill_h, self.fill_h, Blitbuffer.COLOR_BLACK)
    -- knob: white rim, black centre
    disc(bb, kx, cy, self.r, Blitbuffer.COLOR_WHITE)
    disc(bb, kx, cy, self.r - self.rim, Blitbuffer.COLOR_BLACK)
    -- current value above the knob
    if self.value_face then
        local TextWidget = require("ui/widget/textwidget")
        local t = TextWidget:new{ text = tostring(self.value), face = self.value_face,
                                  fgcolor = Blitbuffer.COLOR_BLACK }
        local tw = t:getSize().w
        local tx = math.max(x, math.min(x + self.width - tw, kx - math.floor(tw / 2)))
        t:paintTo(bb, tx, y)
        t:free()
    end
end

return Slider
