--[[--
qp_icons.lua — KoboUI quick settings: drawing a button icon.

An icon value is either "nerd:HEX" (a symbol from KOReader's icon font) or
the path of an .svg/.png file.
--]]--

local Font       = require("ui/font")
local Geom       = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local lfs        = require("libs/libkoreader-lfs")

local SUIStyle = require("features/sui_style")

local M = {}

function M.glyph(value)
    if type(value) ~= "string" then return nil end
    local hex = value:match("^nerd:(%x+)$")
    if not hex then return nil end
    local cp = tonumber(hex, 16)
    if not cp then return nil end
    return require("util").unicodeCodepointToUtf8(cp)
end

--- Font size (in KOReader's font units) that makes a glyph about `px` tall.
function M.faceFor(px)
    local Screen = require("device").screen
    local size = math.max(6, math.floor(px / math.max(0.01, Screen:scaleBySize(100) / 100) * 0.95))
    return Font:getFace(SUIStyle.FACE_ICONS or "symbols", size)
end

-- A font symbol drawn so its visible shape — not its text box — sits in the
-- middle of a px × px square. (Symbols carry uneven blank space above and
-- below; measuring the drawn pixels once centres them exactly.)
local Blitbuffer = require("ffi/blitbuffer")
local Widget     = require("ui/widget/widget")
local InkGlyph = Widget:extend{ text = "", face = nil, fgcolor = nil, px = 0 }

function InkGlyph:getSize() return Geom:new{ w = self.px, h = self.px } end

function InkGlyph:_measure()
    if self._ink then return end
    local t = TextWidget:new{ text = self.text, face = self.face, fgcolor = Blitbuffer.COLOR_BLACK, padding = 0 }
    local sz = t:getSize()
    local w, h = math.max(1, sz.w), math.max(1, sz.h)
    local tmp = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    tmp:fill(Blitbuffer.COLOR_WHITE)
    t:paintTo(tmp, 0, 0)
    t:free()
    local x0, y0, x1, y1 = w, h, -1, -1
    for yy = 0, h - 1 do
        for xx = 0, w - 1 do
            if tmp:getPixel(xx, yy):getColor8().a < 200 then
                if xx < x0 then x0 = xx end
                if xx > x1 then x1 = xx end
                if yy < y0 then y0 = yy end
                if yy > y1 then y1 = yy end
            end
        end
    end
    tmp:free()
    if x1 < 0 then x0, y0, x1, y1 = 0, 0, w - 1, h - 1 end
    self._ink = { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1, tw = w, th = h }
    -- Some symbols are wider or taller than the square: draw them smaller.
    local big = math.max(self._ink.w, self._ink.h)
    if big > self.px and not self._shrunk and self.face and self.face.orig_size then
        self._shrunk = true
        local size = math.max(6, math.floor(self.face.orig_size * self.px / big))
        self.face = Font:getFace(self.face_name or SUIStyle.FACE_ICONS or "symbols", size)
        self._ink = nil
        return self:_measure()
    end
end

function InkGlyph:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.px, h = self.px }
    self:_measure()
    local ink = self._ink
    local ox = x + math.floor((self.px - ink.w) / 2) - ink.x
    local oy = y + math.floor((self.px - ink.h) / 2) - ink.y
    local t = TextWidget:new{ text = self.text, face = self.face, fgcolor = self.fgcolor, padding = 0 }
    t:paintTo(bb, ox, oy)
    t:free()
end

--- A text character drawn with its ink centred in a px × px square.
function M.textGlyph(text, face_name, font_size, px, fg)
    return InkGlyph:new{ text = text, face = Font:getFace(face_name, font_size), face_name = face_name,
                         fgcolor = fg, px = px }
end

--- A widget about `px` × `px` showing the icon in `fg`.
function M.widget(value, px, fg, fallback_label)
    local g = M.glyph(value)
    local inner
    if g then
        inner = InkGlyph:new{ text = g, face = M.faceFor(px), fgcolor = fg, px = px }
    elseif type(value) == "string" and lfs.attributes(value, "mode") == "file" then
        local ok_r, QAR = pcall(require, "engines/sui_quickactions_render")
        if ok_r and QAR and QAR.buildFramedIcon then
            local ok, w = pcall(QAR.buildFramedIcon, value, px, fg)
            if ok and w then inner = w end
        end
        if not inner then
            inner = ImageWidget:new{ file = value, width = px, height = px, alpha = true, is_icon = true }
        end
    else
        inner = TextWidget:new{
            text = (fallback_label or "?"):sub(1, 1):upper(),
            face = Font:getFace(SUIStyle.FACE_BOLD, math.max(8, math.floor(px / 2))),
            fgcolor = fg,
        }
    end
    return CenterContainer:new{ dimen = Geom:new{ w = px, h = px }, inner }
end

return M
