--[[--
kbo_accent.lua — KoboUI

The accent colour Kobo's own interface uses for "where you are": the active
tab in the navigation bar and in the Library, the line under it, and so on.

On a colour screen (Kobo Libra/Clara Colour, colour rendering on) it is
Kobo's dark red; on a black-and-white screen it is plain black, so bold
alone marks the current item there.

Setting: koboui_accent = "kobo" (default) | "black" | "blue" | "green" | "purple"
--]]--

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Screen      = Device.screen
local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate

local M = {}

local ffi = require("ffi")
--- True when `c` is an RGB colour (not a plain grey).
function M.isRGB(c)
    return type(c) == "cdata" and ffi.istype(Blitbuffer.ColorRGB32, c)
end

M.KEY = "koboui_accent"

M.CHOICES = {
    { id = "kobo",   label = _("Kobo red"),   rgb = { 0xA8, 0x3A, 0x2C } },
    { id = "blue",   label = _("Blue"),       rgb = { 0x2F, 0x5D, 0x9A } },
    { id = "green",  label = _("Green"),      rgb = { 0x2E, 0x7D, 0x4F } },
    { id = "purple", label = _("Purple"),     rgb = { 0x6E, 0x3E, 0x96 } },
    { id = "black",  label = _("Black (no colour)") },
}

function M.current()
    return SUISettings:readSetting(M.KEY) or "kobo"
end

function M.set(id)
    SUISettings:saveSetting(M.KEY, id)
end

--- True when the accent is really drawn in colour.
function M.isColour()
    if M.current() == "black" then return false end
    local ok, on = pcall(function() return Screen:isColorEnabled() end)
    return ok and on == true
end

--- True when the screen's pixels are stored blue-green-red (Kobo colour
--- framebuffers at 32bpp). KoboUI writes colours straight into the screen
--- buffer, so red and blue must be swapped there. Checked live.
function M.isBGR()
    local ok, bgr = pcall(function()
        local vi = Screen._vinfo
        if vi and vi.red and (Screen.fb_bpp == 32 or vi.bits_per_pixel == 32) then
            return vi.red.offset ~= 0
        end
        return false
    end)
    return ok and bgr or false
end

--- True in KOReader's night (dark) mode: the whole screen is shown
--- inverted, so a colour has to be painted inverted to come out right
--- (blue would otherwise show as orange-red, Kobo red as cyan).
function M.isNight()
    local ok, on = pcall(function() return Screen.night_mode end)
    return ok and on == true
end

--- The accent colour (a ColorRGB32 on colour screens, black otherwise).
function M.color()
    if not M.isColour() then return Blitbuffer.COLOR_BLACK end
    for _i, c in ipairs(M.CHOICES) do
        if c.id == M.current() and c.rgb then
            local r, g, b = c.rgb[1], c.rgb[2], c.rgb[3]
            if M.isNight() then r, g, b = 255 - r, 255 - g, 255 - b end
            if M.isBGR() then r, b = b, r end
            return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
        end
    end
    return Blitbuffer.COLOR_BLACK
end

--- Paints a filled rectangle in `color`, whether it is a grey or an RGB colour.
function M.rect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    color = color or M.color()
    if M.isRGB(color) and bb.paintRectRGB32 then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        bb:paintRect(x, y, w, h, color)
    end
end

--- A TextWidget drawn in `color` (RGB-safe: goes through the alpha-mask
--- painter when the colour isn't a grey).
function M.text(opts)
    local color = opts.fgcolor or M.color()
    if M.isRGB(color) then
        local UI = require("infra/sui_core")
        local o = {}
        for k, v in pairs(opts) do o[k] = v end
        o.fgcolor = color
        return UI.makeColoredText(o)
    end
    return require("ui/widget/textwidget"):new(opts)
end

return M
