--[[--
qp_iconpicker.lua — KoboUI: a full-screen grid for choosing an icon.

    ┌──────────────────────────────────────────┐
    │  Choose an icon                        ✕ │
    │  [ Symbols ] [ Images ]   [ Search… ]    │
    │  ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐          │
    │  │☀ │ │⚙ │ │☾ │ │⌂ │ │★ │ │♫ │          │  ← tap one to use it
    │  └──┘ └──┘ └──┘ └──┘ └──┘ └──┘          │
    │  …                                       │
    │  ‹   Page 3 of 58   ›      [ Default ]   │
    └──────────────────────────────────────────┘

Symbols: every symbol in KOReader's icon font (searchable by name).
Images:  KoboUI's icons, your own icons (settings/simpleui/sui_icons) and
         KOReader's built-in icons.

Usage:  IconPicker.show{ current = "nerd:EA34", on_select = function(value) … end }
        value is "nerd:HEX", a file path, or nil for "Default".
--]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local lfs             = require("libs/libkoreader-lfs")
local Screen          = Device.screen
local _               = require("infra/sui_i18n").translate

local SUIStyle = require("features/sui_style")
local Icons    = require("features/quickpanel/qp_icons")

local function S(v) return Screen:scaleBySize(v) end
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

-- ---------------------------------------------------------------------------
-- Icon lists
-- ---------------------------------------------------------------------------

local pluginDir -- defined below

local _symbols
local function symbols()
    if _symbols then return _symbols end
    _symbols = {}
    local ok, data = pcall(require, "features/quickpanel/qp_glyphs")
    if not (ok and type(data) == "string") then return _symbols end
    -- Everyday icons first, then every named symbol, then the unnamed ones.
    local FEATURED = {
        "EA5B", "ECA8", "ECA9", "EA34", "EDE6", "EC93", "EB74", "EBB1", "F05B", "EA48",
        "E9DB", "EA30", "E7B9", "E28A", "E7BF", "EB92", "EB52", "EB24", "E7AE", "E778",
        "EC98", "F031", "ED1C", "ECC9", "E7EC", "E84F", "EBE5", "E861", "EAE9",
        "E907", "E9D0", "E7FF", "EA86",
    }
    local names, order = {}, {}
    for hex, name in data:gmatch("(%x+) ([^\n]*)") do
        hex = hex:upper()
        if not names[hex] then names[hex] = name; order[#order + 1] = hex end
    end
    local seen = {}
    local function add(hex)
        if seen[hex] or not names[hex] then return end
        seen[hex] = true
        _symbols[#_symbols + 1] = { value = "nerd:" .. hex, name = names[hex] }
    end
    -- KindleOS' dark mode icon (a half-filled circle) leads the list.
    local pd = pluginDir()
    if pd and lfs.attributes(pd .. "/icons/dark_mode.svg", "mode") == "file" then
        _symbols[#_symbols + 1] = { value = pd .. "/icons/dark_mode.svg", name = "dark mode half circle" }
    end
    for _i, hex in ipairs(FEATURED) do add(hex) end
    local unnamed = {}
    for _i, hex in ipairs(order) do
        if names[hex]:match("^uni%x+$") then unnamed[#unnamed + 1] = hex else add(hex) end
    end
    for _i, hex in ipairs(unnamed) do add(hex) end
    return _symbols
end

pluginDir = function()
    local src = debug.getinfo(1, "S").source or ""
    local dir = (src:sub(1, 1) == "@") and src:sub(2):match("^(.*)/features/quickpanel/[^/]+$") or nil
    if dir and dir:sub(1, 1) ~= "/" then
        local cwd = lfs.currentdir()
        if cwd then dir = cwd .. "/" .. dir end
    end
    return dir
end

local function scanDir(dir, out, seen)
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return end
    local files = {}
    for f in lfs.dir(dir) do
        if f:match("%.[Ss][Vv][Gg]$") or f:match("%.[Pp][Nn][Gg]$") then files[#files + 1] = f end
    end
    table.sort(files)
    for _i, f in ipairs(files) do
        local name = f:gsub("%.[^%.]+$", ""):gsub("[_%.%-]", " ")
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = { value = dir .. "/" .. f, name = name:lower() }
        end
    end
end

local function images()
    local out, seen = {}, {}
    local pd = pluginDir()
    if pd then scanDir(pd .. "/icons", out, seen) end
    local ok_qa, QA = pcall(require, "features/sui_quickactions")
    if ok_qa and QA and QA.ICONS_DIR then scanDir(QA.ICONS_DIR, out, seen) end
    scanDir(lfs.currentdir() .. "/resources/icons/mdlight", out, seen)
    return out
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------

-- Something tappable that remembers where it was painted.
local Hit = Widget:extend{ w = 0, h = 0, child = nil, on_tap = nil }
function Hit:getSize() return Geom:new{ w = self.w, h = self.h } end
function Hit:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    if self.child then
        local cs = self.child:getSize()
        self.child:paintTo(bb, x + math.floor((self.w - cs.w) / 2), y + math.floor((self.h - cs.h) / 2))
    end
end

local function pillButton(text, w, h, selected)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL)
    return FrameContainer:new{
        bordersize = math.max(1, S(1)), color = BLACK, radius = math.floor(h / 2),
        background = selected and BLACK or WHITE, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2, h = h - 2 },
            TextWidget:new{ text = text, face = face, fgcolor = selected and WHITE or BLACK,
                            max_width = w - S(12), truncate_with_ellipsis = true },
        },
    }
end

local IconPicker = InputContainer:extend{
    name = "kindleui_iconpicker",
    covers_fullscreen = true,
    current = nil,
    on_select = nil,
}

function IconPicker:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.tab = (self.current and not self.current:match("^nerd:")) and "images" or "symbols"
    self.filter = ""
    self.page = 1
    self.ges_events = {
        TapPick   = { GestureRange:new{ ges = "tap",   range = function() return self.dimen end } },
        SwipePick = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    if Device:hasKeys() then self.key_events = { ClosePick = { { "Back" } } } end
    self:_rebuild()
end

function IconPicker:_list()
    local src = self.tab == "images" and images() or symbols()
    if self.filter == "" then return src end
    local out = {}
    local f = self.filter:lower()
    for _i, it in ipairs(src) do
        if it.name:find(f, 1, true) then out[#out + 1] = it end
    end
    return out
end

function IconPicker:_rebuild()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = S(18)
    local inner = sw - pad * 2
    self._hits = {}

    local tb = TitleBar:new{
        width = sw, title = _("Choose an icon"), fullscreen = true,
        with_bottom_line = true, close_callback = function() self:_close() end,
        show_parent = self,
    }
    self._titlebar = tb

    local vg = VerticalGroup:new{ align = "left", tb, VerticalSpan:new{ width = S(12) } }

    -- tabs + search
    local bh = S(44)
    local tab_w = math.floor(inner * 0.24)
    local search_w = inner - tab_w * 2 - S(24)
    local function add(hg, w, widget, fn)
        local h = Hit:new{ w = w, h = bh, child = widget, on_tap = fn }
        self._hits[#self._hits + 1] = h
        hg[#hg + 1] = h
    end
    local top = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    add(top, tab_w, pillButton(_("Symbols"), tab_w, bh, self.tab == "symbols"), function()
        self.tab = "symbols"; self.page = 1; self:_redraw()
    end)
    top[#top + 1] = HorizontalSpan:new{ width = S(12) }
    add(top, tab_w, pillButton(_("Images"), tab_w, bh, self.tab == "images"), function()
        self.tab = "images"; self.page = 1; self:_redraw()
    end)
    top[#top + 1] = HorizontalSpan:new{ width = S(12) }
    local search_label = self.filter ~= "" and ("\u{2315} " .. self.filter) or ("\u{2315} " .. _("Search…"))
    add(top, search_w, pillButton(search_label, search_w, bh, self.filter ~= ""), function() self:_search() end)
    vg[#vg + 1] = top
    vg[#vg + 1] = VerticalSpan:new{ width = S(14) }

    -- grid
    local cols = 6
    local cell_w = math.floor(inner / cols)
    local icon_px = math.floor(cell_w * 0.42)
    local name_face = Font:getFace(SUIStyle.FACE_REGULAR, 9)
    local cell_h = icon_px + S(44)
    local footer_h = S(64)
    local used = tb:getSize().h + S(12) + bh + S(14)
    local rows = math.max(1, math.floor((sh - used - footer_h) / cell_h))
    local per_page = rows * cols
    local list = self:_list()
    self._npages = math.max(1, math.ceil(#list / per_page))
    self.page = math.max(1, math.min(self.page, self._npages))
    local first = (self.page - 1) * per_page
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = pad } }
        for c = 1, cols do
            local it = list[first + (r - 1) * cols + c]
            if it then
                local selected = it.value == self.current
                local icon = Icons.widget(it.value, icon_px, selected and WHITE or BLACK, it.name)
                local box = FrameContainer:new{
                    bordersize = selected and 0 or math.max(1, S(1)),
                    color = Blitbuffer.COLOR_LIGHT_GRAY,
                    background = selected and BLACK or WHITE,
                    radius = S(10), padding = S(8), margin = 0,
                    icon,
                }
                local cell = VerticalGroup:new{
                    align = "center",
                    box,
                    VerticalSpan:new{ width = S(4) },
                    TextWidget:new{ text = it.name, face = name_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                                    max_width = cell_w - S(6), truncate_with_ellipsis = true },
                }
                local value = it.value
                local h = Hit:new{ w = cell_w, h = cell_h, child = cell, on_tap = function() self:_pick(value) end }
                self._hits[#self._hits + 1] = h
                row[#row + 1] = h
            else
                row[#row + 1] = HorizontalSpan:new{ width = cell_w }
            end
        end
        vg[#vg + 1] = row
    end
    if #list == 0 then
        vg[#vg + 1] = CenterContainer:new{
            dimen = Geom:new{ w = sw, h = S(120) },
            TextWidget:new{ text = _("No icons found."), face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY) },
        }
    end

    -- footer: pages + default
    local body_h = vg:getSize().h
    local face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local foot = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    local arrow_w = S(60)
    add(foot, arrow_w, TextWidget:new{ text = "\u{2039}", face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE),
        fgcolor = self.page > 1 and BLACK or Blitbuffer.COLOR_LIGHT_GRAY }, function() self:_turn(-1) end)
    foot[#foot + 1] = CenterContainer:new{
        dimen = Geom:new{ w = S(220), h = bh },
        TextWidget:new{ text = string.format(_("Page %d of %d"), self.page, self._npages), face = face },
    }
    add(foot, arrow_w, TextWidget:new{ text = "\u{203A}", face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_TITLE),
        fgcolor = self.page < self._npages and BLACK or Blitbuffer.COLOR_LIGHT_GRAY }, function() self:_turn(1) end)
    local def_w = inner - arrow_w * 2 - S(220)
    add(foot, def_w, pillButton(_("Default icon"), math.min(def_w, S(200)), bh, self.current == nil),
        function() self:_pick(nil) end)

    self[1] = FrameContainer:new{
        background = WHITE, bordersize = 0, padding = 0, margin = 0,
        dimen = Geom:new{ w = sw, h = sh },
        VerticalGroup:new{
            align = "left",
            vg,
            VerticalSpan:new{ width = math.max(0, sh - body_h - footer_h + math.floor((footer_h - bh) / 2)) },
            foot,
        },
    }
end

function IconPicker:_redraw()
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

function IconPicker:_turn(d)
    local p = self.page + d
    if p < 1 or p > (self._npages or 1) then return end
    self.page = p
    self:_redraw()
end

function IconPicker:_search()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Search icons"),
        input = self.filter,
        input_hint = _("e.g. book, moon, wifi"),
        buttons = {{
            { text = _("Clear"), callback = function()
                UIManager:close(dlg); self.filter = ""; self.page = 1; self:_redraw()
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                self.filter = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dlg); self.page = 1; self:_redraw()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function IconPicker:_pick(value)
    self:_close()
    if self.on_select then self.on_select(value) end
end

function IconPicker:_close()
    UIManager:close(self, "ui")
end

function IconPicker:onClosePick() self:_close(); return true end

function IconPicker:onTapPick(_, ges)
    local tb = self._titlebar
    if tb and tb.dimen and ges.pos:intersectWith(tb.dimen) then
        return false -- let the title bar's close button handle it
    end
    for _i, h in ipairs(self._hits or {}) do
        if h.dimen and ges.pos:intersectWith(h.dimen) then
            if h.on_tap then h.on_tap() end
            return true
        end
    end
    return true
end

function IconPicker:onSwipePick(_, ges)
    local d = ges.direction
    if d == "west" or d == "north" then self:_turn(1)
    elseif d == "east" or d == "south" then self:_turn(-1) end
    return true
end

local M = {}

function M.show(opts)
    local p = IconPicker:new{ current = opts.current, on_select = opts.on_select }
    UIManager:show(p)
    return p
end

return M
