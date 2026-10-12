--[[--
kbo_dropdown.lua — KoboUI

The drop-down panels of the Kobo-style status bar (and the Library's Filter /
Sort / … menus): a white card with a black border and a small caret pointing
at what opened it, holding rows drawn like Kobo's own:

  * titleRow     "Brightness"                      (optional switch on the right)
  * sliderRow    ☼ ───────●───────── ☼              (value above the knob)
  * switchHeader [●  ] WI-FI: ENABLED
  * itemRow      ✓ / icon / 🔒 network name … count
  * linkRow      Wi-Fi Settings                     (serif italic)
  * textRow      eReader: 33%
  * buttonRow    [ Sync now ]  LAST SYNC: 13:57

A row is a plain table: { height, paint(row, bb, x, y, w), tap(row, pos, dd),
pan(row, pos, dd, final), sep = draw a line under it }. The panel's build
function returns the row list; dd:refresh() builds it again (after a toggle).

The panel covers the whole screen for input only: a tap outside the card
closes it (a tap on another status-bar icon opens that one's panel instead),
and it paints only the card and the highlighted anchor.
--]]--

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")
local Screen         = Device.screen

local Accent = require("infra/kbo_accent")

local D = {}

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local DARK  = Blitbuffer.COLOR_DARK_GRAY
local GREY  = Blitbuffer.COLOR_GRAY
local LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

local function S(n) return Screen:scaleBySize(n) end
D.S = S

-- ---------------------------------------------------------------------------
-- Faces
-- ---------------------------------------------------------------------------
local _faces = {}
function D.face(kind)
    if _faces[kind] then return _faces[kind] end
    local f
    if kind == "title" then f = Font:getFace("NotoSerif-Regular.ttf", 21)
    elseif kind == "serif" then f = Font:getFace("NotoSerif-Regular.ttf", 19)
    elseif kind == "italic" then f = Font:getFace("NotoSerif-Italic.ttf", 19)
    elseif kind == "caps" then f = Font:getFace("cfont", 14)
    elseif kind == "small" then f = Font:getFace("cfont", 15)
    elseif kind == "icons" then f = Font:getFace("symbols", 16)
    else f = Font:getFace("cfont", 18) end
    _faces[kind] = f
    return f
end

function D.textWidth(text, face)
    local t = TextWidget:new{ text = text, face = face }
    local w = t:getSize().w
    t:free()
    return w
end

--- Draws `text` with its top-left at (x, y) inside a line box of height `h`
--- (vertically centred). Returns the text width.
function D.drawText(bb, text, face, x, y, h, color, max_w, bold)
    local t = TextWidget:new{ text = text, face = face, fgcolor = color or BLACK,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil, bold = bold }
    local sz = t:getSize()
    t:paintTo(bb, x, y + math.floor((h - sz.h) / 2))
    t:free()
    return sz.w
end

-- ---------------------------------------------------------------------------
-- Icons (SVG files drawn through an alpha mask, so any colour works)
-- ---------------------------------------------------------------------------
local _icons = {}
local _tmp

function D.iconPath(name)
    local dir = require("infra/sui_paths").getPluginDir()
    return dir .. "icons/kobo/" .. name .. ".svg"
end

function D.paintIcon(bb, name, x, y, size, color)
    local key = name .. "@" .. size
    local iw = _icons[key]
    if not iw then
        local ImageWidget = require("ui/widget/imagewidget")
        local file = name:find("/", 1, true) and name or D.iconPath(name)
        iw = ImageWidget:new{ file = file, width = size, height = size, alpha = true, is_icon = true }
        local ok = pcall(function() iw:_render() end)
        if not ok then return end
        _icons[key] = iw
    end
    if not _tmp or _tmp:getWidth() ~= size or _tmp:getHeight() ~= size then
        if _tmp then _tmp:free() end
        _tmp = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    end
    require("infra/sui_core").paintWithAlphaMask(iw, bb, x, y, size, size, color or BLACK, nil, _tmp)
end

function D.disc(bb, cx, cy, r, color)
    bb:paintRoundedRect(cx - r, cy - r, r * 2, r * 2, color, r)
end

-- ---------------------------------------------------------------------------
-- Little widgets drawn inside rows
-- ---------------------------------------------------------------------------

--- Kobo's switch: on = black track, white knob on the right.
function D.switchSize() return S(48), S(26) end
function D.paintSwitch(bb, x, y, on)
    local w, h = D.switchSize()
    local r = math.floor(h / 2)
    local b = math.max(2, S(1.5))
    if on then
        bb:paintRoundedRect(x, y, w, h, BLACK, r)
        local kx = x + w - r
        D.disc(bb, kx, y + r, r - b, WHITE)
        bb:paintBorder(kx - r + b * 2, y + b * 2, (r - b * 2) * 2, (r - b * 2) * 2, math.max(1, S(1)), BLACK, r - b * 2)
    else
        bb:paintRoundedRect(x, y, w, h, DARK, r)
        bb:paintRoundedRect(x + b, y + b, w - 2 * b, h - 2 * b, WHITE, r - b)
        D.disc(bb, x + r, y + r, r - b * 2, DARK)
    end
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------
D.PAD = function() return S(24) end

--- A title, with an optional switch (and caps label) on the right.
function D.titleRow(text, opts)
    opts = opts or {}
    local row = { height = opts.height or S(58), sep = opts.sep }
    function row.paint(r, bb, x, y, w)
        local pad = D.PAD()
        D.drawText(bb, text, D.face(opts.face or "title"), x + pad, y, r.height, opts.color)
        if opts.switch then
            local sw, sh = D.switchSize()
            local sx = x + w - pad - sw
            D.paintSwitch(bb, sx, y + math.floor((r.height - sh) / 2), opts.switch.get())
            if opts.switch.label then
                local lw = D.textWidth(opts.switch.label, D.face("caps"))
                D.drawText(bb, opts.switch.label, D.face("caps"), sx - S(14) - lw, y, r.height, BLACK)
            end
        end
    end
    if opts.switch then
        function row.tap(r, pos, dd)
            if pos.x < r.dimen.x + r.dimen.w / 2 then return true end
            opts.switch.set(not opts.switch.get())
            dd:refresh()
            return true
        end
    elseif opts.tap then
        row.tap = function(r, pos, dd) return opts.tap(dd) end
    end
    return row
end

--- [switch] CAPS LABEL — the whole row toggles.
function D.switchHeader(opts)
    local row = { height = S(70), sep = true }
    function row.paint(r, bb, x, y, w)
        local pad = D.PAD()
        local sw, sh = D.switchSize()
        local on = opts.get()
        D.paintSwitch(bb, x + pad, y + math.floor((r.height - sh) / 2), on)
        D.drawText(bb, on and opts.label_on or opts.label_off, D.face("caps"),
            x + pad + sw + S(14), y, r.height, BLACK)
    end
    function row.tap(r, pos, dd)
        opts.set(not opts.get())
        dd:refresh()
        return true
    end
    return row
end

--- A slider; opts: min, max, get, set(v, final), fmt (value label), left_icon, right_icon.
function D.sliderRow(opts)
    local label_h = opts.fmt and S(30) or 0
    local row = { height = label_h + S(56), sep = opts.sep, is_slider = true }
    local function geom(r)
        local pad = D.PAD()
        local isz = S(18)
        local x0 = r.dimen.x + pad + (opts.left_icon and (isz + S(14)) or 0)
        local x1 = r.dimen.x + r.dimen.w - pad - (opts.right_icon and (isz + S(14)) or 0)
        local kr = S(13)
        return x0 + kr, x1 - kr, kr, isz
    end
    local function valueAt(r, px)
        local a, b = geom(r)
        local f = math.max(0, math.min(1, (px - a) / math.max(1, b - a)))
        return math.floor(opts.min + f * (opts.max - opts.min) + 0.5)
    end
    function row.paint(r, bb, x, y, w)
        local a, b, kr, isz = geom(r)
        local cy = y + label_h + math.floor((r.height - label_h) / 2)
        local v = r._live or opts.get() or opts.min
        local span = math.max(1, opts.max - opts.min)
        local kx = math.floor(a + (v - opts.min) / span * (b - a) + 0.5)
        if opts.left_icon then
            D.paintIcon(bb, opts.left_icon, x + D.PAD(), cy - math.floor(isz / 2), isz, BLACK)
        end
        if opts.right_icon then
            local big = opts.right_big and math.floor(isz * 1.3) or isz
            D.paintIcon(bb, opts.right_icon, x + w - D.PAD() - math.floor((isz + big) / 2), cy - math.floor(big / 2), big, BLACK)
        end
        local thin = math.max(1, S(1))
        local thick = math.max(3, S(3))
        bb:paintRect(a, cy - math.floor(thin / 2), b - a, thin, DARK)
        if kx > a then bb:paintRect(a, cy - math.floor(thick / 2), kx - a, thick, BLACK) end
        -- knob: white disc, black ring, thin inner ring
        D.disc(bb, kx, cy, kr, BLACK)
        D.disc(bb, kx, cy, kr - math.max(2, S(1.5)), WHITE)
        local ir = math.floor(kr * 0.55)
        bb:paintBorder(kx - ir, cy - ir, ir * 2, ir * 2, math.max(1, S(1)), BLACK, ir)
        if opts.fmt then
            local t = string.format(opts.fmt, v)
            local tw = D.textWidth(t, D.face("serif"))
            local tx = math.max(x, math.min(x + w - tw, kx - math.floor(tw / 2)))
            D.drawText(bb, t, D.face("serif"), tx, y, label_h + S(6), BLACK)
        end
    end
    function row.pan(r, pos, dd, final)
        local v = valueAt(r, pos.x)
        if v ~= r._live or final then
            r._live = v
            pcall(opts.set, v, final)
            dd:refreshRow(r, final)
        end
        if final then r._live = nil end
        return true
    end
    function row.tap(r, pos, dd)
        -- KoboUI: a tap on the end icons (☼ / ☾) steps by one instead of
        -- jumping to the end of the rail
        local a, b, kr = geom(r)
        local step
        if pos.x < a - kr then step = -1 elseif pos.x > b + kr then step = 1 end
        if step then
            local cur = tonumber(opts.get()) or opts.min
            local v = math.max(opts.min, math.min(opts.max, math.floor(cur + 0.5) + step))
            if v ~= cur then pcall(opts.set, v, true) end
            dd:refreshRow(r, true)
            return true
        end
        return row.pan(r, pos, dd, true)
    end
    return row
end

--- A list item: optional check mark, icon and lock, text, right text.
function D.itemRow(opts)
    local row = { height = opts.height or S(64), sep = opts.sep ~= false }
    function row.paint(r, bb, x, y, w)
        local pad = D.PAD()
        local cx = x + pad
        local face = D.face(opts.face or "serif")
        if opts.check ~= nil then
            if opts.check then
                D.drawText(bb, "\u{2713}", D.face("serif"), cx, y, r.height, opts.color or BLACK)
            end
            cx = cx + S(34)
        end
        if opts.icon then
            local isz = S(17)
            D.paintIcon(bb, opts.icon, cx, y + math.floor((r.height - isz) / 2), isz, opts.icon_color or BLACK)
            cx = cx + isz + S(20)
        end
        if opts.lock ~= nil then
            if opts.lock then
                D.drawText(bb, "\u{F023}", D.face("icons"), cx, y, r.height, BLACK)
            end
            cx = cx + S(34)
        end
        local rw = 0
        if opts.right then
            rw = D.textWidth(opts.right, face)
            D.drawText(bb, opts.right, face, x + w - pad - rw, y, r.height, opts.right_color or BLACK)
            rw = rw + S(16)
        end
        D.drawText(bb, opts.text, face, cx, y, r.height, opts.color or BLACK,
            math.max(S(40), x + w - pad - rw - cx), opts.bold)
    end
    if opts.tap then row.tap = function(r, pos, dd) return opts.tap(dd) end end
    if opts.dim then
        local inner = row.paint
        row.paint = function(r, bb, x, y, w) opts.color = GREY; return inner(r, bb, x, y, w) end
        row.tap = nil
    end
    return row
end

--- A serif italic link (e.g. "Wi-Fi Settings").
function D.linkRow(text, tap, opts)
    opts = opts or {}
    return D.itemRow{ text = text, face = "italic", tap = tap, height = opts.height or S(66), sep = opts.sep or false }
end

--- Static text (wraps).
function D.textRow(text, opts)
    opts = opts or {}
    local face = D.face(opts.face or "body")
    local row = { sep = opts.sep }
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local function box(w)
        return TextBoxWidget:new{ text = text, face = face, width = w - 2 * D.PAD(), fgcolor = opts.color or BLACK }
    end
    row.measure = function(r, w)
        local b = box(w)
        r.height = b:getSize().h + (opts.pad_top or S(18)) + (opts.pad_bot or S(18))
        b:free()
    end
    function row.paint(r, bb, x, y, w)
        local b = box(w)
        b:paintTo(bb, x + D.PAD(), y + (opts.pad_top or S(18)))
        b:free()
    end
    return row
end

--- A grey button (serif italic) with a caps note under it.
function D.buttonRow(text, tap, note)
    local row = { height = S(note and 116 or 84) }
    function row.paint(r, bb, x, y, w)
        local pad = D.PAD()
        local face = D.face("italic")
        local tw = D.textWidth(text, face)
        local bw, bh = tw + S(40), S(46)
        bb:paintRect(x + pad, y + S(10), bw, bh, LIGHT)
        D.drawText(bb, text, face, x + pad + S(20), y + S(10), bh, BLACK)
        r._btn = { x = x + pad, y = y + S(10), w = bw, h = bh }
        if note then
            D.drawText(bb, note, D.face("caps"), x + pad, y + S(10) + bh + S(10), S(34), BLACK)
        end
    end
    function row.tap(r, pos, dd)
        local b = r._btn
        if b and pos.x >= b.x - S(10) and pos.x <= b.x + b.w + S(10) then return tap(dd) end
        return true
    end
    return row
end

--- Empty space.
function D.spacer(h) return { height = h, paint = function() end } end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------
local DropDown = InputContainer:extend{
    name          = "koboui_dropdown",
    anchor        = nil,   -- Geom of what opened it (screen coordinates)
    width         = nil,
    build         = nil,   -- function(dd) -> rows
    paint_anchor  = nil,   -- function(bb, rect): draws the highlighted anchor
    other_anchor  = nil,   -- function(pos) -> true when the tap was handled (another icon)
    on_close      = nil,
    align         = "center", -- "center" | "left" (card starts at the anchor)
    caret         = true,
}
D.DropDown = DropDown

function DropDown:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local range = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        DDTap        = { GestureRange:new{ ges = "tap", range = range } },
        DDHold       = { GestureRange:new{ ges = "hold", range = range } },
        DDPan        = { GestureRange:new{ ges = "pan", range = range } },
        DDPanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        DDSwipe      = { GestureRange:new{ ges = "swipe", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_layout()
end

function DropDown:_layout()
    local ok, rows = pcall(self.build, self)
    if not ok then
        logger.warn("koboui: drop-down build failed:", rows)
        rows = { D.textRow(tostring(rows)) }
    end
    self.rows = rows
    local sw = Screen:getWidth()
    local w = self.width or math.floor(sw * 0.62)
    w = math.min(w, sw - S(16))
    local pad_v = S(8)
    local h = pad_v * 2
    for _i, r in ipairs(rows) do
        if r.measure then r:measure(w) end
        h = h + (r.height or 0)
    end
    local a = self.anchor or Geom:new{ x = sw - S(40), y = 0, w = S(40), h = S(40) }
    -- KoboUI: "side" — the card beside the anchor (like Kobo's book "…"
    -- menu), its caret on the card's left (or right) edge pointing at it.
    if self.placement == "side" then
        local sh = Screen:getHeight()
        local margin = S(12)
        self.caret_h = self.caret and S(14) or 0
        local acy = a.y + math.floor(a.h / 2)
        local x = a.x + a.w + self.caret_h
        self.caret_side = "left"
        if x + w > sw - margin then
            x = a.x - self.caret_h - w
            self.caret_side = "right"
        end
        x = math.max(margin, math.min(sw - margin - w, x))
        local y = acy - math.floor(h / 2)
        y = math.max(margin, math.min(sh - margin - h, y))
        if h > sh - 2 * margin then h = sh - 2 * margin end
        self.card = Geom:new{ x = x, y = y, w = w, h = h }
        self.pad_v = pad_v
        self.acy = math.max(y + S(24), math.min(y + h - S(24), acy))
        return
    end
    self.caret_side = nil
    local acx = a.x + math.floor(a.w / 2)
    local margin = S(12)
    local x
    if self.align == "left" then
        x = math.max(margin, a.x - S(4))
    else
        x = acx - math.floor(w / 2)
    end
    x = math.max(margin, math.min(sw - margin - w, x))
    self.caret_h = self.caret and S(14) or 0
    local y = a.y + a.h + self.caret_h - math.max(1, S(1))
    local maxh = Screen:getHeight() - y - S(10)
    if h > maxh then h = maxh end
    self.card = Geom:new{ x = x, y = y, w = w, h = h }
    self.pad_v = pad_v
    self.acx = math.max(x + S(24), math.min(x + w - S(24), acx))
end

--- The region this panel paints (card + caret + anchor).
function DropDown:paintRegion()
    local c = self.card
    local r
    if self.caret_side then
        r = Geom:new{ x = c.x - self.caret_h, y = c.y, w = c.w + 2 * self.caret_h, h = c.h }
    else
        r = Geom:new{ x = c.x, y = c.y - self.caret_h, w = c.w, h = c.h + self.caret_h }
    end
    if self.anchor then r = r:combine(self.anchor) end
    return r
end

function DropDown:paintTo(bb, x, y)
    if self.paint_anchor and self.anchor then
        pcall(self.paint_anchor, bb, self.anchor)
    end
    local c = self.card
    local bw = math.max(2, S(1.5))
    bb:paintRect(c.x, c.y, c.w, c.h, WHITE)
    bb:paintBorder(c.x, c.y, c.w, c.h, bw, BLACK)
    -- caret on the left/right border ("side" placement)
    if self.caret and self.caret_side then
        local ch = self.caret_h
        for i = 0, ch do
            local hh = math.floor(ch * i / ch)
            local xx = (self.caret_side == "left") and (c.x - ch + i) or (c.x + c.w - 1 + ch - i)
            bb:paintRect(xx, self.acy - hh, 1, hh * 2 + 1, BLACK)
            if hh - bw > 0 then bb:paintRect(xx, self.acy - hh + bw, 1, (hh - bw) * 2 + 1, WHITE) end
        end
        local ex = (self.caret_side == "left") and c.x or (c.x + c.w - bw)
        bb:paintRect(ex, self.acy - ch + bw, bw, (ch - bw) * 2 + 1, WHITE)
    -- caret: a triangle on the top border, pointing at the anchor
    elseif self.caret then
        local ch = self.caret_h
        local half = ch
        for i = 0, ch do
            local hw = math.floor(half * i / ch)
            local yy = c.y - ch + i
            bb:paintRect(self.acx - hw, yy, hw * 2 + 1, 1, BLACK)
            if hw - bw > 0 then
                bb:paintRect(self.acx - hw + bw, yy, (hw - bw) * 2 + 1, 1, WHITE)
            end
        end
        bb:paintRect(self.acx - half + bw, c.y, (half - bw) * 2 + 1, bw, WHITE)
    end
    -- rows
    local ry = c.y + self.pad_v
    local inner_x, inner_w = c.x + bw, c.w - 2 * bw
    for i, r in ipairs(self.rows) do
        local rh = r.height or 0
        if ry + rh > c.y + c.h then break end
        r.dimen = Geom:new{ x = inner_x, y = ry, w = inner_w, h = rh }
        local ok, err = pcall(r.paint, r, bb, inner_x, ry, inner_w)
        if not ok then logger.warn("koboui: drop-down row paint failed:", err) end
        if r.sep and i < #self.rows then
            bb:paintRect(inner_x, ry + rh - math.max(1, S(1)), inner_w, math.max(1, S(1)), LIGHT)
        end
        ry = ry + rh
    end
end

function DropDown:show()
    UIManager:show(self, "ui", self:paintRegion())
end

function DropDown:close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self, "ui", self:paintRegion())
    if self.on_close then pcall(self.on_close) end
end
DropDown.onClose = DropDown.close

--- Rebuilds the rows (after a change) and repaints.
function DropDown:refresh()
    if self._closed then return end
    local old = self:paintRegion()
    self:_layout()
    local region = old:combine(self:paintRegion())
    UIManager:setDirty("all", function() return "ui", region end)
end

--- Repaints one row only (slider drags).
function DropDown:refreshRow(row, final)
    if self._closed or not row.dimen then return end
    local d = row.dimen
    UIManager:setDirty(self, function() return final and "ui" or "fast", d end)
end

function DropDown:_rowAt(pos)
    for _i, r in ipairs(self.rows or {}) do
        local d = r.dimen
        if d and pos.y >= d.y and pos.y < d.y + d.h and pos.x >= d.x and pos.x < d.x + d.w then
            return r
        end
    end
end

function DropDown:_inCard(pos)
    local c = self.card
    return pos.x >= c.x and pos.x < c.x + c.w and pos.y >= c.y - self.caret_h and pos.y < c.y + c.h
end

function DropDown:onDDTap(_args, ges)
    local pos = ges.pos
    if self:_inCard(pos) then
        local r = self:_rowAt(pos)
        if r and r.tap then
            local ok, err = pcall(r.tap, r, pos, self)
            if not ok then logger.warn("koboui: drop-down tap failed:", err) end
        end
        return true
    end
    if self.anchor and self.anchor:contains(pos) then
        self:close()
        return true
    end
    self:close()
    if self.other_anchor then pcall(self.other_anchor, pos) end
    return true
end

function DropDown:onDDHold(_args, ges)
    return true
end

function DropDown:onDDPan(_args, ges)
    local pos = ges.pos
    local r = self._drag or self:_rowAt(pos)
    if r and r.pan then
        self._drag = r
        r.pan(r, pos, self, false)
    end
    return true
end

function DropDown:onDDPanRelease(_args, ges)
    local r = self._drag
    self._drag = nil
    if r and r.pan then r.pan(r, ges.pos, self, true) end
    return true
end

function DropDown:onDDSwipe(_args, ges)
    local pos = ges.pos
    if self:_inCard(pos) then
        local r = self:_rowAt(pos)
        if r and r.is_slider then return true end
        if ges.direction == "north" then self:close() end
        return true
    end
    self:close()
    return true
end

function D.open(opts)
    local dd = DropDown:new(opts)
    dd:show()
    return dd
end

return D
