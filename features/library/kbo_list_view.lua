--[[--
kbo_list_view.lua — KoboUI

The Library's list view drawn like Kobo's "My Books" list:

  Books (one row each)
    [cover]  Title (serif)                         Unread / 19% Read
             521 pages                              6 HOURS TO GO
             SERIES NAME · 2                        EPUB · 2.1 MB
             Author                                 …   ← tap: book menu

  Authors, Series, Collections, Tags, folders
    Name (serif italic)                             3 books

It replaces the content CoverBrowser's ListMenuItem builds, only in the
file manager. The number of rows per page follows Kobo: books rows are
tall enough for a cover (koboui_list_rows_books, default 5), name rows are
short (koboui_list_rows_names, default 10).

Setting: koboui_list_style (default on).
--]]--

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Font        = require("ui/font")
local Geom        = require("ui/geometry")
local Widget      = require("ui/widget/widget")
local TextWidget  = require("ui/widget/textwidget")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local Screen      = Device.screen
local _           = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")

local M = {}

function M.isEnabled() return SUISettings:nilOrTrue("koboui_list_style") end
function M.rowsBooks() return tonumber(SUISettings:readSetting("koboui_list_rows_books")) or 5 end
function M.rowsNames() return tonumber(SUISettings:readSetting("koboui_list_rows_names")) or 10 end

local function S(n) return Screen:scaleBySize(n) end
local BLACK = Blitbuffer.COLOR_BLACK
local GREY  = Blitbuffer.COLOR_GRAY_7 or Blitbuffer.COLOR_DARK_GRAY

local function face(name, size) return Font:getFace(name, size) end

local function header() return package.loaded["features/library/kbo_library_header"]
    or require("features/library/kbo_library_header") end

--- Draws text at (x, y) (top), returns its height. right = align right edge at x.
local function txt(bb, text, f, x, y, color, max_w, right)
    if not text or text == "" then return 0 end
    local t = TextWidget:new{ text = text, face = f, fgcolor = color or BLACK, padding = 0,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil }
    local sz = t:getSize()
    t:paintTo(bb, right and (x - sz.w) or x, y)
    t:free()
    return sz.h
end

local function fmtSize(n)
    if not n then return nil end
    if n >= 1024 * 1024 then return string.format("%.1f MB", n / 1024 / 1024) end
    return string.format("%d KB", math.max(1, math.floor(n / 1024 + 0.5)))
end

local function fmtLeft(secs)
    if not secs or secs <= 0 then return nil end
    local h = math.floor(secs / 3600 + 0.5)
    if h >= 1 then
        return h == 1 and _("1 HOUR TO GO") or string.format(_("%d HOURS TO GO"), h)
    end
    local m = math.max(1, math.floor(secs / 60 + 0.5))
    return string.format(_("%d MINS TO GO"), m)
end

-- ---------------------------------------------------------------------------
-- Row widgets
-- ---------------------------------------------------------------------------
local BookRow = Widget:extend{ width = 0, height = 0, fp = nil, item = nil }

function BookRow:getSize() return Geom:new{ w = self.width, h = self.height } end

function BookRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local fp = self.fp
    local pad = S(14)
    local h = self.height
    -- cover
    local cover_h = math.floor(h * 0.84)
    local cover_w = math.floor(cover_h * 2 / 3)
    local cx, cy = x + pad, y + math.floor((h - cover_h) / 2)
    local drew = false
    pcall(function()
        local bim = require("bookinfomanager")
        local bi = bim:getBookInfo(fp, true)
        if bi and bi.cover_bb and bi.has_cover then
            local ImageWidget = require("ui/widget/imagewidget")
            local bw, bh = bi.cover_bb:getWidth(), bi.cover_bb:getHeight()
            local sc = math.min(cover_w / bw, cover_h / bh)
            local iw = ImageWidget:new{ image = bi.cover_bb, image_disposable = false, scale_factor = sc }
            local isz = iw:getSize()
            iw:paintTo(bb, cx + math.floor((cover_w - isz.w) / 2), cy + math.floor((cover_h - isz.h) / 2))
            iw:free()
            drew = true
        end
    end)
    if not drew then
        bb:paintBorder(cx, cy, cover_w, cover_h, math.max(1, S(1)), GREY)
    end

    -- data
    local SH = require("modules/module_books_shared")
    local ok, d = pcall(SH.getBookData, fp)
    d = ok and d or {}
    local series
    pcall(function() series = SH.getBookSeries(fp) end)
    local state = header().classify(fp)
    local attr = lfs.attributes(fp) or {}

    -- right column
    local rx = x + self.width - pad
    local right_w = math.floor(self.width * 0.30)
    local ry = y + math.floor(h * 0.10)
    local small = face("cfont", 13)
    local tiny = face("cfont", 12)
    local status_text
    if state == "finished" then status_text = _("Finished")
    elseif state == "reading" then
        local pct = math.floor((tonumber(d.percent) or 0) * 100 + 0.5)
        status_text = string.format(_("%d%% Read"), pct)
    else status_text = _("Unread") end
    ry = ry + txt(bb, status_text, face("cfont", 15), rx, ry, BLACK, right_w, true) + S(4)
    if state == "reading" and d.avg_time and d.pages then
        local left = d.avg_time * d.pages * (1 - (tonumber(d.percent) or 0))
        local t = fmtLeft(left)
        if t then ry = ry + txt(bb, t, tiny, rx, ry, BLACK, right_w, true) + S(4) end
    end
    local ext = (fp:match("%.([^%.]+)$") or ""):upper()
    local info = ext
    local sz = fmtSize(attr.size)
    if sz then info = info .. " \u{00B7} " .. sz end
    ry = ry + txt(bb, info, tiny, rx, ry, BLACK, right_w, true) + S(6)
    -- "…" (book menu)
    local dots_y = y + h - S(16)
    local r = math.max(2, S(1.4))
    local D = require("screens/kbo_dropdown")
    for k = 0, 2 do D.disc(bb, rx - S(4) - k * (r * 2 + S(4)), dots_y, r, BLACK) end
    self.dots = { x = rx - S(40), y = dots_y - S(22), w = S(48), h = S(44) }

    -- left text column
    local tx = cx + cover_w + S(20)
    local tw = math.max(S(60), rx - right_w - S(16) - tx)
    local ty = y + math.floor(h * 0.10)
    ty = ty + txt(bb, d.title, face("NotoSerif-Regular.ttf", 18), tx, ty, BLACK, tw) + S(4)
    if d.pages then
        ty = ty + txt(bb, string.format(_("%d pages"), d.pages), small, tx, ty, BLACK, tw) + S(4)
    end
    if series and series.series then
        local s = series.series:upper()
        if series.series_index then s = s .. " \u{00B7} " .. tostring(series.series_index):gsub("%.0$", "") end
        ty = ty + txt(bb, s, face("cfont", 13), tx, ty, BLACK, tw) + S(4)
    end
    local authors = d.authors and d.authors:gsub("\n.*", "") or ""
    if authors ~= "" then
        local ok_an, AN = pcall(require, "features/library/kui_author_names")
        if ok_an and AN and AN.displayName then authors = AN.displayName(authors) end
        txt(bb, authors, small, tx, ty, BLACK, tw)
    end
end

local NameRow = Widget:extend{ width = 0, height = 0, name = "", count = nil }

function NameRow:getSize() return Geom:new{ w = self.width, h = self.height } end

function NameRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local pad = S(22)
    local f = face("NotoSerif-Italic.ttf", 20)
    local cf = face("NotoSerif-Regular.ttf", 16)
    local cw = 0
    if self.count then
        local t = TextWidget:new{ text = self.count, face = cf, padding = 0 }
        local sz = t:getSize()
        cw = sz.w
        t:paintTo(bb, x + self.width - pad - sz.w, y + math.floor((self.height - sz.h) / 2))
        t:free()
    end
    local t = TextWidget:new{ text = self.name, face = f, padding = 0,
        max_width = self.width - 2 * pad - cw - S(20), truncate_with_ellipsis = true }
    local sz = t:getSize()
    t:paintTo(bb, x + pad, y + math.floor((self.height - sz.h) / 2))
    t:free()
end

local function countText(entry)
    local n = entry.virtual_leaf_count or entry.nb_sub_files
    if not n and entry.mandatory then n = tonumber(tostring(entry.mandatory):match("^(%d+)")) end
    if not n then return nil end
    return n == 1 and _("1 book") or string.format(_("%d books"), n)
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
local function wanted(item)
    return M.isEnabled() and item.menu and item.menu.name == "filemanager"
end

local _installed = false
function M.install()
    if _installed then return end
    local ok_lm, ListMenu = pcall(require, "listmenu")
    local ok_up, userpatch = pcall(require, "userpatch")
    if not (ok_lm and ok_up) then return end
    local ListMenuItem = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
    if not ListMenuItem then return end
    _installed = true

    local orig_update = ListMenuItem.update
    ListMenuItem.update = function(self, ...)
        local r = orig_update(self, ...)
        if not wanted(self) then return r end
        local ok, err = pcall(function()
            local e = self.entry or {}
            local w, h = self.width, self.height - 2 * (self.underline_h or 1)
            local row
            if e.is_file or e.file then
                row = BookRow:new{ width = w, height = h, fp = self.filepath, item = self }
            else
                local VerticalSpan = require("ui/widget/verticalspan")
                local name = (self.text or e.text or ""):gsub("/$", "")
                row = NameRow:new{ width = w, height = h, name = name, count = countText(e) }
            end
            local VerticalGroup = require("ui/widget/verticalgroup")
            local VerticalSpan = require("ui/widget/verticalspan")
            local prev = self._underline_container[1]
            self._underline_container[1] = VerticalGroup:new{
                VerticalSpan:new{ width = self.underline_h or 1 },
                row,
            }
            if prev and prev.free then prev:free() end
            self._kbo_row = row
            -- no dog-ear / description marks over our own layout
            self.do_hint_opened = false
            self.has_description = false
        end)
        if not ok then logger.warn("koboui: list row failed:", err) end
        return r
    end

    local orig_tap = ListMenuItem.onTapSelect
    ListMenuItem.onTapSelect = function(self, arg, ges)
        local row = self._kbo_row
        local d = row and row.dots
        if d and ges and ges.pos and ges.pos.x >= d.x and ges.pos.x < d.x + d.w
                and ges.pos.y >= d.y and ges.pos.y < d.y + d.h then
            self.menu:onMenuHold(self.entry)
            return true
        end
        return orig_tap(self, arg, ges)
    end

    -- Rows per page: tall book rows, short name rows (like Kobo).
    local orig_recalc = ListMenu._recalculateDimen
    ListMenu._recalculateDimen = function(self, ...)
        if M.isEnabled() and self.name == "filemanager" then
            local kind = "books"
            pcall(function() kind = header().viewKind(self) end)
            self.files_per_page = (kind == "books") and M.rowsBooks() or M.rowsNames()
        end
        return orig_recalc(self, ...)
    end
    -- CoverBrowser copies the function into FileChooser when list mode is set up
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._recalculateDimen == orig_recalc then
        FileChooser._recalculateDimen = ListMenu._recalculateDimen
    end
end

return M
