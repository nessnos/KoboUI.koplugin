-- kui_series_shelf.lua — KoboUI
-- "Bookshelf" style for the Library's Series view.
--
-- Instead of one folder per series, the series are drawn as books standing
-- on wooden shelves: each book is a spine (title written up the spine,
-- volume number at the bottom), the first book of each series faces out
-- with its cover. Every book of a series has the same size.
-- Books without a series form a last group.
--
--   tap a book    → open it
--   hold a book   → the usual book menu
--   tap the plank under a series → that series' own list
--
-- KoboUI's own code (MIT). The look is inspired by the Bookshelf plugin
-- for KOReader by AndyHazz (AGPL); no code from it is used.
--
-- How it plugs in: sui_library_browse calls M.attach(fc, path) whenever the
-- file chooser lists a path. On the Series list with the style on, the
-- file chooser gets instance-level updateItems/_recalculateDimen that draw
-- shelf pages; any other path restores the normal methods.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local ffiUtil        = require("ffi/util")
local lfs            = require("libs/libkoreader-lfs")
local logger         = require("logger")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")

local M = {}

local STYLE_KEY = "kindleui_series_style"   -- "folders" (default) | "shelf"
local ROWS_KEY  = "kindleui_series_shelf_rows"
local COVER_KEY = "kindleui_series_shelf_covers"

function M.isEnabled() return SUISettings:readSetting(STYLE_KEY) == "shelf" end
function M.setEnabled(on) SUISettings:saveSetting(STYLE_KEY, on and "shelf" or "folders") end
function M.getRows()
    local n = tonumber(SUISettings:readSetting(ROWS_KEY)) or 4
    return math.max(2, math.min(6, math.floor(n)))
end
function M.setRows(n) SUISettings:saveSetting(ROWS_KEY, n) end
function M.showCovers() return SUISettings:readSetting(COVER_KEY) ~= false end
function M.setShowCovers(on) SUISettings:saveSetting(COVER_KEY, on and true or false) end
local NUM_KEY = "kindleui_series_shelf_numbers"
function M.showNumbers() return SUISettings:readSetting(NUM_KEY) ~= false end
function M.setShowNumbers(on) SUISettings:saveSetting(NUM_KEY, on and true or false) end

local function S(n) return Screen:scaleBySize(n) end

-- ---------------------------------------------------------------------------
-- Data: series groups with their books
-- ---------------------------------------------------------------------------

local function hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
    return h
end

-- Cloth tones for books without a cover; on a black-and-white screen they
-- show as distinct greys.
local PALETTE = {
    { 0x2F, 0x5D, 0x62 }, -- teal
    { 0x6B, 0x2E, 0x2E }, -- oxblood
    { 0x3B, 0x4A, 0x6B }, -- navy
    { 0x7A, 0x6A, 0x2F }, -- ochre
    { 0x4F, 0x6B, 0x3A }, -- olive
    { 0x5B, 0x3F, 0x6B }, -- plum
    { 0x8C, 0x4A, 0x2F }, -- rust
    { 0x2E, 0x4F, 0x3E }, -- bottle green
    { 0x6E, 0x6E, 0x6E }, -- slate
    { 0x9A, 0x7B, 0x5A }, -- tan
    { 0x3A, 0x3A, 0x3A }, -- charcoal
    { 0xA6, 0x3D, 0x4A }, -- crimson
    { 0x4A, 0x7A, 0x8C }, -- steel blue
    { 0xB5, 0x9A, 0x6A }, -- sand
}

-- Spine colour of a book, taken from its cover: the most common colour on
-- the cover (coarse buckets, averaged), so a red cover gives a red spine.
-- Books without a cover get a cloth tone from the palette. Cached per file.
local _colour_cache = {}
local function coverColour(bim, fp, attr)
    local key = fp .. "|" .. tostring(attr and attr.modification)
    local hit = _colour_cache[key]
    if hit then return hit end
    local col
    local info = bim and bim:getBookInfo(fp, true)
    local cbb = info and info.has_cover and info.cover_bb
    if cbb then
        pcall(function()
            local cw, ch = cbb:getWidth(), cbb:getHeight()
            local buckets, best = {}, nil
            local N = 16
            for iy = 1, N do
                for ix = 1, N do
                    local px = math.floor((ix - 0.5) * cw / N)
                    local py = math.floor((iy - 0.5) * ch / N)
                    local c = cbb:getPixel(px, py):getColorRGB32()
                    local r, g, b = c.r, c.g, c.b
                    local k = math.floor(r / 48) * 64 + math.floor(g / 48) * 8 + math.floor(b / 48)
                    local bk = buckets[k]
                    if not bk then bk = { 0, 0, 0, 0 }; buckets[k] = bk end
                    bk[1], bk[2], bk[3], bk[4] = bk[1] + r, bk[2] + g, bk[3] + b, bk[4] + 1
                    if not best or bk[4] > best[4] then best = bk end
                end
            end
            if best then
                col = { math.floor(best[1] / best[4]), math.floor(best[2] / best[4]), math.floor(best[3] / best[4]) }
            end
        end)
    end
    if info and info.cover_bb then info.cover_bb:free() end
    col = col or PALETTE[hash(fp) % #PALETTE + 1]
    _colour_cache[key] = col
    return col
end

-- Number of pages: from the book info, then from the book's own settings
-- (once it has been opened), else estimated from the file size.
local function pageCount(bi, fp, attr)
    local p = bi and tonumber(bi.pages)
    if p and p > 0 then return p end
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.hasSidecarFile and DocSettings:hasSidecarFile(fp) then
        local ok2, ds = pcall(DocSettings.open, DocSettings, fp)
        if ok2 and ds then
            p = tonumber(ds:readSetting("doc_pages"))
            if p and p > 0 then return p end
            local stats = ds:readSetting("stats")
            p = stats and tonumber(stats.pages)
            if p and p > 0 then return p end
        end
    end
    local size = attr and attr.size or 0
    local ext = (fp:match("%.([^.]+)$") or ""):lower()
    -- roughly 2 KB of compressed text per page in an EPUB (images aside)
    local per_page = (ext == "epub" or ext == "fb2" or ext == "mobi" or ext == "azw3") and 2000
        or (ext == "txt" and 1800) or 60000
    return math.max(60, math.min(1500, math.floor(size / per_page)))
end

local function buildGroups(fc, path)
    local VP = require("features/library/sui_virtual_path")
    local MS = require("features/library/sui_metadata_source")
    local base_dir, filter_state = VP.parse(path)
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if not (base_dir and ok_bim and bim) then return {} end
    local rows = MS.getMatchingFiles(bim, base_dir, filter_state, { recursive = true })
    local by, order = {}, {}
    for _i, row in ipairs(rows) do
        local fp, fname = row[1], row[2]
        local attr = lfs.attributes(fp)
        if attr and attr.mode == "file" and fc:show_file(fname, fp) then
            local key = (row.series and row.series ~= "") and row.series or false
            local g = by[key]
            if not g then
                g = { name = key, books = {} }
                by[key] = g
                order[#order + 1] = g
            end
            local bi = bim:getBookInfo(fp, false)
            g.books[#g.books + 1] = {
                fp = fp, fname = fname, attr = attr,
                title = (row.title and row.title ~= "") and row.title or (fname:gsub("%.[^.]+$", "")),
                authors = row.authors,
                index = tonumber(row.series_index),
                pages = pageCount(bi, fp, attr),
                color = coverColour(bim, fp, attr),
            }
        end
    end
    table.sort(order, function(a, b)
        if a.name == false then return false end
        if b.name == false then return true end
        return ffiUtil.strcoll(a.name, b.name)
    end)
    for _i, g in ipairs(order) do
        table.sort(g.books, function(a, b)
            local ai, bi_ = a.index or math.huge, b.index or math.huge
            if ai ~= bi_ then return ai < bi_ end
            return ffiUtil.strcoll(a.title, b.title)
        end)
        g.label = g.name or VP.displayValue(false, "series")
        g.vpath = VP.buildLeaf(base_dir, filter_state, "series", g.name)
    end
    return order
end

-- ---------------------------------------------------------------------------
-- Layout: groups → rows → pages
-- ---------------------------------------------------------------------------

-- Spine thickness from the page count: ~100 pages thin, ~350 average,
-- 800+ a doorstop.
local function spineWidth(pages)
    local p = pages or 350
    return math.max(S(18), math.min(S(50), S(14) + math.floor(p / 24)))
end

local function layout(groups, avail_w, row_h, covers)
    -- no labels under the shelves: the books get the height instead
    local label_h = S(4)
    local plank_h = S(12)
    local top_gap = S(6)
    local area_h  = row_h - label_h - plank_h - top_gap
    local cover_h = area_h
    local cover_w = math.floor(cover_h * 2 / 3)
    local group_gap = S(12)
    local ok_bim, bim = pcall(require, "bookinfomanager")

    local rows = {}
    local row = { items = {}, segs = {}, x = 0 }
    rows[1] = row
    local function newRow()
        row = { items = {}, segs = {}, x = 0 }
        rows[#rows + 1] = row
    end
    for _gi, g in ipairs(groups) do
        if row.x > 0 then row.x = row.x + group_gap end
        -- every book of a series has the same height (one per series, from
        -- its name); thickness follows each book's number of pages.
        -- Books without a series keep their own heights.
        local g_h = g.name and math.floor(area_h * (0.86 + (hash(g.name) % 15) / 100))
        local seg = nil
        for bi_i, b in ipairs(g.books) do
            local item = { book = b, group = g }
            -- first book of a series faces out when its cover is ready
            if covers and bi_i == 1 and g.name and ok_bim then
                local info = bim:getBookInfo(b.fp, true)
                if info and info.has_cover and info.cover_fetched and info.cover_bb and not info.ignore_cover then
                    item.cover = info
                    item.w = math.min(cover_w, math.floor(cover_h * info.cover_w / math.max(1, info.cover_h)))
                    item.h = math.floor(item.w * info.cover_h / math.max(1, info.cover_w))
                    if item.h > cover_h then
                        item.h = cover_h
                        item.w = math.floor(cover_h * info.cover_w / math.max(1, info.cover_h))
                    end
                elseif info and info.cover_bb then
                    info.cover_bb:free()
                end
            end
            if not item.cover then
                -- thicker for longer books (unknown length: average)
                item.w = spineWidth(b.pages)
                item.h = g_h or math.floor(area_h * (0.84 + (hash(b.fp) % 17) / 100))
            end
            if row.x > 0 and row.x + item.w > avail_w then
                newRow()
                seg = nil
            end
            if not seg then
                seg = { group = g, x0 = row.x, x1 = row.x }
                row.segs[#row.segs + 1] = seg
            end
            item.x = row.x
            row.items[#row.items + 1] = item
            row.x = row.x + item.w + 1
            seg.x1 = row.x - 1
        end
    end
    if #rows[#rows].items == 0 then table.remove(rows) end
    return rows, { label_h = label_h, plank_h = plank_h, top_gap = top_gap, area_h = area_h }
end

-- ---------------------------------------------------------------------------
-- Spine bitmaps (title written up the spine), cached
-- ---------------------------------------------------------------------------

local _spine_cache, _spine_count = {}, 0

local function lum(c) return math.floor(0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3] + 0.5) end
local function shift(c, d)
    return { math.max(0, math.min(255, c[1] + d)), math.max(0, math.min(255, c[2] + d)), math.max(0, math.min(255, c[3] + d)) }
end

-- Colour value for the spine bitmaps: real colour on colour screens,
-- the matching grey otherwise.
local function colour(c, rgb)
    if rgb then return Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF) end
    return Blitbuffer.Color8(lum(c))
end

-- Title at the largest size (≤ max_fs) that fits `len`, so it's readable
-- in full; truncated only when even the smallest size doesn't fit.
-- Fit a title along the spine: one line, shrinking the font; then two
-- lines (split at the space nearest the middle) if the spine is thick
-- enough; only then truncate. Returns a list of TextWidgets.
local function splitTwo(text)
    local best, mid = nil, #text / 2
    for i in text:gmatch("() ") do
        if not best or math.abs(i - mid) < math.abs(best - mid) then best = i end
    end
    if not best then return nil end
    return text:sub(1, best - 1), text:sub(best + 1)
end

local function fittedTitle(text, len, thick, max_fs, fg)
    local min_fs = 6
    for fs = max_fs, min_fs, -1 do
        local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", fs), fgcolor = fg }
        local sz = tw:getSize()
        if sz.w <= len and sz.h <= thick then return { tw } end
        tw:free()
    end
    local a, b = splitTwo(text)
    if a then
        for fs = math.min(max_fs, 10), min_fs, -1 do
            local face = Font:getFace("cfont", fs)
            local lh, bl = math.ceil(face.size * 1.12), math.ceil(face.size * 0.88)
            local t1 = TextWidget:new{ text = a, face = face, fgcolor = fg, forced_height = lh, forced_baseline = bl }
            local t2 = TextWidget:new{ text = b, face = face, fgcolor = fg, forced_height = lh, forced_baseline = bl }
            local s1, s2 = t1:getSize(), t2:getSize()
            if s1.h + s2.h <= thick + 2 then
                if s1.w <= len and s2.w <= len then return { t1, t2 } end
            end
            t1:free(); t2:free()
        end
        -- two lines at the smallest size, second one truncated
        local face = Font:getFace("cfont", min_fs)
        local lh, bl = math.ceil(face.size * 1.12), math.ceil(face.size * 0.88)
        local t1 = TextWidget:new{ text = a, face = face, fgcolor = fg, max_width = len, truncate_with_ellipsis = true, forced_height = lh, forced_baseline = bl }
        local t2 = TextWidget:new{ text = b, face = face, fgcolor = fg, max_width = len, truncate_with_ellipsis = true, forced_height = lh, forced_baseline = bl }
        if t1:getSize().h + t2:getSize().h <= thick + 2 then return { t1, t2 } end
        t1:free(); t2:free()
    end
    return { TextWidget:new{ text = text, face = Font:getFace("cfont", min_fs), fgcolor = fg,
        max_width = len, truncate_with_ellipsis = true } }
end

-- paintRect that keeps colour on RGB bitmaps (plain paintRect/fill turn
-- colours into grey).
local function rect(bb, rgb, x, y, w, h, c)
    if w <= 0 or h <= 0 then return end
    if rgb then bb:paintRectRGB32(x, y, w, h, c) else bb:paintRect(x, y, w, h, c) end
end

local function spineBB(item, col)
    local b = item.book
    local rgb = Screen:isColorEnabled()
    local key = b.fp .. "|" .. item.w .. "|" .. item.h .. "|" .. col[1] .. col[2] .. col[3] .. "|" .. tostring(rgb) .. tostring(M.showNumbers())
    local hit = _spine_cache[key]
    if hit then return hit end
    if _spine_count > 400 then
        for _k, v in pairs(_spine_cache) do v:free() end
        _spine_cache, _spine_count = {}, 0
    end
    local w, h = item.w, item.h
    local bg = colour(col, rgb)
    local dark = lum(col) < 0x90
    local fg = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bb = Blitbuffer.new(w, h, rgb and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
    rect(bb, rgb, 0, 0, w, h, colour({ 0xFF, 0xFF, 0xFF }, rgb))

    local top = 0 -- no page tops: the spine runs the full height

    -- the spine (cover cloth) below the pages
    rect(bb, rgb, 0, top, w, h - top, bg)
    -- a lighter band near the top and bottom, like a printed spine
    local band = colour(shift(col, dark and 0x26 or -0x26), rgb)
    rect(bb, rgb, 0, top + S(6), w, math.max(1, S(1)), band)

    -- volume number at the bottom: small, so the title gets the room
    local foot = 0
    if b.index and item.group.name and M.showNumbers() then
        local num = b.index == math.floor(b.index) and tostring(math.floor(b.index)) or tostring(b.index)
        local face = Font:getFace("cfont", math.max(6, math.min(8, math.floor(w * 0.22))))
        local tw = TextWidget:new{ text = num, face = face, fgcolor = fg, max_width = w - 2 }
        local sz = tw:getSize()
        foot = sz.h + S(1)
        rect(bb, rgb, 1, h - foot - 1, w - 2, 1, band)
        tw:paintTo(bb, math.floor((w - sz.w) / 2), h - foot)
        tw:free()
    end

    -- title, rendered horizontally then turned to read bottom-to-top
    local len = h - top - S(10) - foot - S(2)
    if len > S(16) then
        local thick = w - S(4)
        local lines = fittedTitle(b.title, len, thick, math.max(7, math.min(15, math.floor(w * 0.48))), fg)
        local total = 0
        for _i, tw in ipairs(lines) do total = total + tw:getSize().h end
        local tb = Blitbuffer.new(len, w - 2, rgb and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8)
        rect(tb, rgb, 0, 0, len, w - 2, bg)
        -- centred along and across the spine
        local y = math.floor((w - 2 - total) / 2)
        for _i, tw in ipairs(lines) do
            local sz = tw:getSize()
            tw:paintTo(tb, math.floor((len - sz.w) / 2), y)
            y = y + sz.h
            tw:free()
        end
        local rot = tb:rotatedCopy(90)
        tb:free()
        bb:blitFrom(rot, 1, top + S(8), 0, 0, rot:getWidth(), rot:getHeight())
        rot:free()
    end
    -- outline of the boards
    local ink = colour({ 0, 0, 0 }, rgb)
    rect(bb, rgb, 0, top, w, 1, ink)
    rect(bb, rgb, 0, h - 1, w, 1, ink)
    rect(bb, rgb, 0, 0, 1, h, ink)
    rect(bb, rgb, w - 1, 0, 1, h, ink)
    _spine_cache[key] = bb
    _spine_count = _spine_count + 1
    return bb
end

-- ---------------------------------------------------------------------------
-- One shelf page widget
-- ---------------------------------------------------------------------------

local ShelfPage = InputContainer:extend{ width = 0, height = 0, rows = nil, geo = nil, fc = nil }

function ShelfPage:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapShelf  = { GestureRange:new{ ges = "tap",  range = function() return self.dimen end } },
        HoldShelf = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
    self.label_face = Font:getFace("cfont", 15)
end

function ShelfPage:getSize() return Geom:new{ w = self.width, h = self.height } end

function ShelfPage:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.hits = {}
    local geo = self.geo
    local row_h = self.row_h
    for ri, row in ipairs(self.rows) do
        local ry = y + (ri - 1) * row_h
        local base_y = ry + geo.top_gap + geo.area_h -- top of the plank
        local ox = x + self.margin
        -- books
        for _i, it in ipairs(row.items) do
            local bx = ox + it.x
            local by = base_y - it.h
            if it.cover then
                local ImageWidget = require("ui/widget/imagewidget")
                local img = ImageWidget:new{ image = it.cover.cover_bb, width = it.w, height = it.h,
                    scale_factor = math.min(it.w / it.cover.cover_w, it.h / it.cover.cover_h),
                    image_disposable = false }
                img:paintTo(bb, bx, by)
                img:free()
                bb:paintBorder(bx, by, it.w, it.h, 1, Blitbuffer.COLOR_BLACK)
            else
                local sb = spineBB(it, it.book.color)
                bb:blitFrom(sb, bx, by, 0, 0, it.w, it.h)
            end
            self.hits[#self.hits + 1] = { x = bx, y = by, w = it.w, h = it.h, book = it.book }
        end
        -- plank
        local pw = self.width - 2 * self.margin + S(8)
        -- wooden plank (wood colour on colour screens)
        local wrgb = bb:getType() == Blitbuffer.TYPE_BBRGB32 and Screen:isColorEnabled()
        local wood, edge = colour({ 0xA0, 0x70, 0x45 }, wrgb), colour({ 0x6B, 0x45, 0x25 }, wrgb)
        rect(bb, wrgb, ox - S(4), base_y, pw, geo.plank_h, wood)
        rect(bb, wrgb, ox - S(4), base_y, pw, math.max(1, S(2)), edge)
        rect(bb, wrgb, ox - S(4), base_y + geo.plank_h - math.max(1, S(2)), pw, math.max(1, S(2)), edge)
        -- tapping the plank under a series opens the series
        for _i, seg in ipairs(row.segs) do
            if seg.group.name then
                self.hits[#self.hits + 1] = { x = ox + seg.x0, y = base_y, w = seg.x1 - seg.x0,
                    h = geo.plank_h, group = seg.group }
            end
        end
    end
end

function ShelfPage:hitAt(pos)
    if not (pos and self.hits) then return nil end
    for _i, h in ipairs(self.hits) do
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y - S(4) and pos.y < h.y + h.h + (h.book and 0 or S(4)) then
            return h
        end
    end
end

local function bookItem(b)
    return { text = b.fname, path = b.fp, is_file = true, attr = b.attr, file = b.fp }
end

function ShelfPage:onTapShelf(_args, ges)
    local hit = self:hitAt(ges and ges.pos)
    if not hit then return true end
    local fc = self.fc
    if hit.book then
        pcall(fc.onMenuSelect, fc, bookItem(hit.book))
    elseif hit.group then
        pcall(function()
            fc:changeToPath(hit.group.vpath)
            if fc.onGotoPage then fc:onGotoPage(1) end
        end)
    end
    return true
end

function ShelfPage:onHoldShelf(_args, ges)
    local hit = self:hitAt(ges and ges.pos)
    if hit and hit.book then
        local fc = self.fc
        local ok = pcall(fc.onMenuHold, fc, bookItem(hit.book))
        if not ok then pcall(fc.showFileDialog, fc, bookItem(hit.book)) end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- File chooser instance methods while on the shelf
-- ---------------------------------------------------------------------------

local function availableArea(fc)
    local w = fc.inner_dimen and fc.inner_dimen.w or Screen:getWidth()
    local h = fc.inner_dimen and fc.inner_dimen.h or Screen:getHeight()
    if fc.title_bar and not fc.no_title then h = h - fc.title_bar:getHeight() end
    if fc.page_info then
        local ok, sz = pcall(function() return fc.page_info:getSize() end)
        if ok and sz then h = h - sz.h end
    end
    -- Unread / Read chips at the top
    local SF = package.loaded["features/library/kui_status_filter"]
    if SF and SF.reservedHeight then h = h - SF.reservedHeight(fc) end
    -- With vertical scrolling on, the shelf is the one view that scrolls
    -- sideways: its scrollbar lies along the bottom, so keep that strip free
    -- (no gutter on the right).
    if fc._kui_hbar then
        local VS = package.loaded["features/kui_vertical_scroll"]
        h = h - ((VS and VS.getReservedHeight and VS.getReservedHeight(fc)) or S(34))
    elseif fc._vlibscroll_bar then
        local VS = package.loaded["features/kui_vertical_scroll"]
        w = w - ((VS and VS.getReservedWidth and VS.getReservedWidth(fc)) or S(28))
    end
    return w, h
end

local function shelfRecalc(fc)
    local w, h = availableArea(fc)
    local nrows = M.getRows()
    local row_h = math.floor(h / nrows)
    local margin = S(14)
    local key = w .. "x" .. h .. "x" .. nrows .. "x" .. tostring(M.showCovers())
    if fc._kui_shelf_key ~= key then
        fc._kui_shelf_rows, fc._kui_shelf_geo = layout(fc._kui_shelf_groups or {}, w - 2 * margin, row_h, M.showCovers())
        fc._kui_shelf_key = key
    end
    fc._kui_shelf_dim = { w = w, h = h, row_h = row_h, nrows = nrows, margin = margin }
    local nr = #(fc._kui_shelf_rows or {})
    fc.page_num = math.max(1, math.ceil(nr / nrows))
    if (fc.page or 1) > fc.page_num then fc.page = fc.page_num end
    if (fc.page or 0) < 1 then fc.page = 1 end
    fc.perpage = math.max(1, #fc.item_table)
end

local function shelfUpdateItems(fc, select_number, no_recalculate_dimen)
    fc.layout = {}
    fc.item_group:clear()
    shelfRecalc(fc)
    if fc.page_info then pcall(function() fc.page_info:resetLayout() end) end
    if fc.return_button then pcall(function() fc.return_button:resetLayout() end) end
    if fc.content_group then pcall(function() fc.content_group:resetLayout() end) end
    fc.items_to_update = {}
    local d = fc._kui_shelf_dim
    local first = ((fc.page or 1) - 1) * d.nrows + 1
    local page_rows = {}
    for i = first, math.min(first + d.nrows - 1, #fc._kui_shelf_rows) do
        page_rows[#page_rows + 1] = fc._kui_shelf_rows[i]
    end
    local page = ShelfPage:new{
        width = d.w, height = d.h, rows = page_rows, geo = fc._kui_shelf_geo,
        row_h = d.row_h, margin = d.margin, fc = fc, show_parent = fc.show_parent,
    }
    fc.item_group[1] = page
    local SF = package.loaded["features/library/kui_status_filter"]
    if SF and SF.decorate then SF.decorate(fc) end
    fc:updatePageInfo(1)
    if fc.show_parent then fc.show_parent.dithered = true end
    UIManager:setDirty(fc.show_parent, function()
        return "ui", fc.dimen, true
    end)
end

local SAVED = { "updateItems", "_recalculateDimen" }

local function detach(fc)
    if not fc._kui_shelf_on then return end
    for _i, k in ipairs(SAVED) do
        fc[k] = fc._kui_shelf_saved[k]
    end
    fc._kui_shelf_on, fc._kui_shelf_saved = nil, nil
    fc._kui_shelf_groups, fc._kui_shelf_rows, fc._kui_shelf_key = nil, nil, nil
end

--- Called for every listed path: switches the shelf on for the Series
--- list (style on), off everywhere else.
function M.attach(fc, path)
    if not fc then return end
    local on = false
    if M.isEnabled() and fc.name == "filemanager" then
        local ok_vp, VP = pcall(require, "features/library/sui_virtual_path")
        if ok_vp and VP.isVirtual(path) then
            local _b, _s, dim, level = VP.parse(path)
            on = (level == "dim_list" and dim == "series")
        end
    end
    if not on then return detach(fc) end
    -- The bookshelf always shows the whole bookcase: the Library's
    -- Unread / Read filter (KOReader's status filter) is left out here.
    local FileChooser = require("ui/widget/filechooser")
    local saved_status = FileChooser.show_filter and FileChooser.show_filter.status
    if saved_status then FileChooser.show_filter.status = nil end
    local KH = package.loaded["features/library/kbo_library_header"]
    if KH then KH._filter_off = KH._filter_off + 1 end -- KoboUI: the bookcase is never filtered
    local ok, groups = pcall(buildGroups, fc, path)
    if KH then KH._filter_off = KH._filter_off - 1 end
    if saved_status then FileChooser.show_filter.status = saved_status end
    if not ok then
        logger.warn("kindleui: series shelf failed:", groups)
        return detach(fc)
    end
    if not fc._kui_shelf_on then
        fc._kui_shelf_saved = {}
        for _i, k in ipairs(SAVED) do fc._kui_shelf_saved[k] = rawget(fc, k) end
        fc._kui_shelf_on = true
        fc.updateItems = shelfUpdateItems
        fc._recalculateDimen = shelfRecalc
    end
    fc._kui_shelf_groups = groups
    fc._kui_shelf_key = nil
end

function M.invalidate()
    for _k, v in pairs(_spine_cache) do v:free() end
    _spine_cache, _spine_count = {}, 0
end

return M
