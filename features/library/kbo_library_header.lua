--[[--
kbo_library_header.lua — KoboUI

The top of the Library, like Kobo's "My Books":

    Books   Authors   Series   Collections          ← view tabs (in place of
    ───────                                            the title bar)
    Filter: All ˅    Sort: Recent ˅           …     ← controls row

  * The tabs switch views (all books, authors, series, collections; tags too
    if you switch them on). The current one is bold, in the accent colour
    (Kobo red on a colour screen) and underlined.
  * Filter opens a menu: All / Unread / Reading / Finished, with counts. It
    drives KOReader's file-browser status filter, so every view follows it
    (the Series bookshelf always shows everything).
  * Sort opens: Recent, Date added, Title, Author, Series, File size, File
    type (KOReader's sort methods). On Authors: Last name / First name.
  * … opens the view options: Grid / List view, Group series, Reverse
    order, Bookshelf / Folders for Series, Manage collections.

Only at the top of a view: inside an author, a series, a collection or a
folder, the normal title bar (with its back button) comes back.

How it is put in place:
  * TitleBar (class) — getHeight / getSize / paintTo / handleEvent are
    wrapped: when the title bar is the file manager's and the Library is at
    the top of a view, it is the tab row instead.
  * The controls row goes at the top of the file chooser's item group (the
    hooks in kui_status_filter.lua reserve its height and insert it).

Setting: koboui_library_header (default on).
--]]--

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")
local Accent      = require("infra/kbo_accent")

local M = {}

local KEY = "koboui_library_header"
function M.isEnabled() return SUISettings:nilOrTrue(KEY) end
function M.setEnabled(on) SUISettings:saveSetting(KEY, on and true or false) end
function M.showTags() return SUISettings:isTrue("koboui_tab_tags") end

local function S(n) return Screen:scaleBySize(n) end
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE

local function D() return require("screens/kbo_dropdown") end
local function BM()
    local ok, m = pcall(require, "features/library/sui_library_browse")
    return ok and m or nil
end
local function VP() return require("features/library/sui_virtual_path") end

local function fmInstance()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

function M.tabs()
    local t = {
        { id = "normal",      label = _("Books") },
        { id = "author",      label = _("Authors") },
        { id = "series",      label = _("Series") },
        { id = "collections", label = _("Collections") },
    }
    if M.showTags() then table.insert(t, { id = "tags", label = _("Tags") }) end
    return t
end

-- ---------------------------------------------------------------------------
-- Where are we?
-- ---------------------------------------------------------------------------
local function normPath(p)
    if not p then return nil end
    local ffiUtil = require("ffi/util")
    local ok, r = pcall(ffiUtil.realpath, p)
    return ((ok and r) or p):gsub("/$", "")
end

--- The view whose top level the file chooser shows ("normal", "author",
--- "series", "collections", "tags"), or nil (inside something).
function M.rootView(fc)
    if not (fc and fc.path) or not M.isEnabled() then return nil end
    local bm = BM()
    if not (bm and bm.isEnabled()) then return nil end
    if fc.item_table and (fc.item_table._sg_is_series_view or fc.item_table._sg_parent_path) then return nil end
    local vp = VP()
    if vp.isVirtual(fc.path) then
        local _b, fs, dim, level = vp.parse(fc.path)
        local trail = fs and fs.trail or {}
        if level == "dim_list" and dim and #trail == 0 then return dim end
        return nil
    end
    local home = G_reader_settings:readSetting("home_dir")
    if home and normPath(fc.path) == normPath(home) then return "normal" end
    return nil
end

local function fmRootView(tb)
    local fm = fmInstance()
    if not (fm and fm.title_bar == tb and fm.file_chooser) then return nil end
    return M.rootView(fm.file_chooser), fm
end

-- ---------------------------------------------------------------------------
-- The tab row
-- ---------------------------------------------------------------------------
function M.tabsHeight() return S(54) end

local function tabFace(bold)
    local Font = require("ui/font")
    return Font:getFace(bold and "smallinfofontbold" or "smallinfofont", 18)
end

local function paintTabs(bb, x, y, w, h, current)
    bb:paintRect(x, y, w, h, WHITE)
    local Font = require("ui/font")
    local face = Font:getFace("cfont", 18)
    local pad = require("infra/sui_core").SIDE_M and require("infra/sui_core").SIDE_M() or S(16)
    local gap = S(30)
    local cx = x + pad
    local rects = {}
    local accent = Accent.color()
    for _i, t in ipairs(M.tabs()) do
        local on = t.id == current
        local tw = Accent.text{ text = t.label, face = face, bold = on, fgcolor = on and accent or BLACK, padding = 0 }
        local sz = tw:getSize()
        local ty = y + math.floor((h - sz.h) / 2) - S(2)
        tw:paintTo(bb, cx, ty)
        if tw.free then tw:free() end
        if on then
            Accent.rect(bb, cx - S(6), y + h - math.max(3, S(2.5)), sz.w + S(12), math.max(3, S(2.5)), accent)
        end
        rects[#rects + 1] = { id = t.id, x = cx - gap / 2, w = sz.w + gap }
        cx = cx + sz.w + gap
    end
    bb:paintRect(x, y + h - math.max(1, S(0.7)), w, math.max(1, S(0.7)), Blitbuffer.COLOR_LIGHT_GRAY)
    return rects
end

function M.chooseView(view)
    local fm = fmInstance()
    local bm = BM()
    if not (fm and bm) then return end
    if view == "normal" then
        bm.setLibraryView("normal")
        local fc = fm.file_chooser
        if VP().isVirtual(fc.path) then
            bm.navigateTo(fm, "normal")
        end
        return
    end
    bm.chooseView(fm, view)
end

local function tabTap(tb, ges)
    local r = tb._kbo_tab_rects
    if not (r and ges.pos) then return false end
    local d = tb._kbo_tab_dimen
    if not (d and ges.pos.y >= d.y and ges.pos.y < d.y + d.h) then return false end
    for _i, t in ipairs(r) do
        if ges.pos.x >= t.x and ges.pos.x < t.x + t.w then
            local view = t.id
            UIManager:nextTick(function()
                local ok, err = pcall(M.chooseView, view)
                if not ok then logger.warn("koboui: library tab failed:", err) end
            end)
            return true
        end
    end
    return true
end

local _tb_installed = false
function M.installTitleBar()
    if _tb_installed then return end
    _tb_installed = true
    local TitleBar = require("ui/widget/titlebar")
    local orig_getHeight = TitleBar.getHeight
    local orig_getSize   = TitleBar.getSize
    local orig_paintTo   = TitleBar.paintTo
    local orig_handle    = TitleBar.handleEvent

    TitleBar.getHeight = function(self, ...)
        if fmRootView(self) then return M.tabsHeight() end
        return orig_getHeight(self, ...)
    end
    TitleBar.getSize = function(self, ...)
        if fmRootView(self) then
            return Geom:new{ w = self.width or Screen:getWidth(), h = M.tabsHeight() }
        end
        return orig_getSize(self, ...)
    end
    TitleBar.paintTo = function(self, bb, x, y)
        local view = fmRootView(self)
        if view then
            local w = self.width or Screen:getWidth()
            local h = M.tabsHeight()
            self._kbo_tab_dimen = Geom:new{ x = x, y = y, w = w, h = h }
            self._kbo_tab_rects = paintTabs(bb, x, y, w, h, view)
            return
        end
        self._kbo_tab_rects = nil
        return orig_paintTo(self, bb, x, y)
    end
    TitleBar.handleEvent = function(self, event, ...)
        if event and event.handler == "onGesture" and fmRootView(self) then
            local ges = event.args and event.args[1]
            if ges and ges.ges == "tap" then return tabTap(self, ges) end
            if ges and ges.pos and self._kbo_tab_dimen and self._kbo_tab_dimen:contains(ges.pos) then
                return ges.ges == "hold" or ges.ges == "hold_release"
            end
            return false
        end
        return orig_handle(self, event, ...)
    end
end

-- ---------------------------------------------------------------------------
-- Filter / Sort / … row
-- ---------------------------------------------------------------------------
local FILTERS = {
    { id = "all",      label = _("All") },
    { id = "unread",   label = _("Unread"),   set = { new = true } },
    { id = "reading",  label = _("Reading"),  set = { reading = true, abandoned = true } },
    { id = "finished", label = _("Finished"), set = { complete = true } },
}

local function FC() return require("ui/widget/filechooser") end

local function sameSet(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

function M.currentFilter()
    local st = FC().show_filter and FC().show_filter.status
    if not st then return "all" end
    for _i, f in ipairs(FILTERS) do
        if f.set and sameSet(f.set, st) then return f.id end
    end
    return "custom"
end

local function refreshLibrary(fc)
    pcall(function() require("features/library/sui_foldercovers").invalidateItemTableCache() end)
    pcall(function() require("features/library/sui_metadata_source").clearCache() end)
    if not fc then return end
    if fc._kui_shelf_on then
        pcall(function() fc:changeToPath(fc.path) end)
    else
        pcall(fc.refreshPath, fc)
    end
end

function M.setFilter(id)
    local FileChooser = FC()
    FileChooser.show_filter = FileChooser.show_filter or {}
    local st
    for _i, f in ipairs(FILTERS) do
        if f.id == id and f.set then
            st = {}
            for k in pairs(f.set) do st[k] = true end
        end
    end
    FileChooser.show_filter.status = st
    G_reader_settings:saveSetting("show_filter", FileChooser.show_filter)
    pcall(function() require("features/library/kui_status_filter").invalidate() end)
    M.invalidateCounts()
    local fm = fmInstance()
    refreshLibrary(fm and fm.file_chooser)
end

local _counts
function M.invalidateCounts() _counts = nil end

local function counts(fc)
    if _counts then return _counts end
    local c = { all = 0, unread = 0, reading = 0, finished = 0 }
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local home = G_reader_settings:readSetting("home_dir")
        local bim = require("bookinfomanager")
        local MS = require("features/library/sui_metadata_source")
        local BookList = require("ui/widget/booklist")
        local FileChooser = FC()
        local saved = FileChooser.show_filter.status
        FileChooser.show_filter.status = nil
        local ok, rows = pcall(function()
            return (home and MS.getMatchingFiles(bim, home, nil, { recursive = true })) or {}
        end)
        for _i, r in ipairs(ok and rows or {}) do
            local fp, fname = r[1], r[2]
            if lfs.attributes(fp, "mode") == "file" and fc:show_file(fname, fp) then
                c.all = c.all + 1
                local st = BookList.getBookStatus(fp)
                if st == "complete" then c.finished = c.finished + 1
                elseif st == "reading" or st == "abandoned" then c.reading = c.reading + 1
                else c.unread = c.unread + 1 end
            end
        end
        FileChooser.show_filter.status = saved
    end)
    _counts = c
    return c
end

-- Sort methods offered (KOReader collate ids), in Kobo's order.
local SORTS = {
    { id = "last_opened", label = _("Recent") },
    { id = "date",        label = _("Date added") },
    { id = "title",       label = _("Title") },
    { id = "authors",     label = _("Author") },
    { id = "series",      label = _("Series") },
    { id = "size",        label = _("File size") },
    { id = "type",        label = _("File type") },
}

local function currentSort()
    local id = G_reader_settings:readSetting("collate", "strcoll")
    for _i, s in ipairs(SORTS) do if s.id == id then return s end end
    local c = FC().collates and FC().collates[id]
    return { id = id, label = c and c.text and (c.text:sub(1, 1):upper() .. c.text:sub(2)) or id }
end

local function setSort(id)
    local fm = fmInstance()
    if fm and fm.onSetSortBy then
        fm:onSetSortBy(id)
    else
        G_reader_settings:saveSetting("collate", id)
    end
    refreshLibrary(fm and fm.file_chooser)
end

-- What the controls row holds for a view.
local function controlsFor(view, fc)
    local ctl = {}
    local shelf = fc and fc._kui_shelf_on
    if not shelf then
        local f = M.currentFilter()
        local flabel = f == "custom" and _("Custom") or nil
        for _i, d in ipairs(FILTERS) do if d.id == f then flabel = d.label end end
        ctl[#ctl + 1] = { id = "filter", text = string.format(_("Filter: %s"), flabel) }
    end
    if view == "normal" then
        ctl[#ctl + 1] = { id = "sort", text = string.format(_("Sort: %s"), currentSort().label) }
    elseif view == "author" then
        local AN = require("features/library/kui_author_names")
        ctl[#ctl + 1] = { id = "sort", text = string.format(_("Sort: %s"), AN.isEnabled() and _("Last name") or _("First name")) }
    end
    return ctl
end

function M.rowHeight() return S(62) end

local function chevronDown(bb, x, cy, w, color)
    local h = math.floor(w / 2)
    local t = math.max(1, S(1))
    for i = 0, w - 1 do
        local d = math.abs(i - math.floor(w / 2))
        local yy = cy - math.floor(h / 2) + (h - math.floor(d * h / math.max(1, w / 2)))
        bb:paintRect(x + i, yy - t, 1, t + 1, color)
    end
end

local ControlsRow = InputContainer:extend{ width = 0, height = 0, fc = nil, view = nil }
M.ControlsRow = ControlsRow

function ControlsRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapKoboCtl = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function ControlsRow:getSize() return Geom:new{ w = self.width, h = self.height } end

--- Paints one control (inverted while its menu is open).
local function paintControl(bb, c, inverted)
    local Dd = D()
    local face = Dd.face("italic")
    local pad_x = S(10)
    if inverted then
        if c.id == "more" then
            -- KoboUI: the … button is highlighted with a black circle
            local cx, cy = c.x + math.floor(c.w / 2), c.y + math.floor(c.h / 2)
            local r = math.floor(math.max(c.w, c.h) / 2)
            Dd.disc(bb, cx, cy, r, BLACK)
        else
            bb:paintRect(c.x - pad_x, c.y, c.w + 2 * pad_x, c.h, BLACK)
        end
    end
    local fg = inverted and WHITE or BLACK
    if c.id == "more" then
        local r = math.max(2, S(1.6))
        local cy = c.y + math.floor(c.h / 2)
        local step = r * 2 + S(5)
        local x0 = c.x + math.floor((c.w - (2 * step + 2 * r)) / 2) + r
        for k = 0, 2 do
            Dd.disc(bb, x0 + k * step, cy, r, fg)
        end
        return
    end
    local tw = Dd.drawText(bb, c.text, face, c.x, c.y, c.h, fg)
    chevronDown(bb, c.x + tw + S(10), c.y + math.floor(c.h / 2) + S(2), S(12), fg)
end

function ControlsRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, WHITE)
    local Dd = D()
    local face = Dd.face("italic")
    local pad = require("infra/sui_core").SIDE_M and require("infra/sui_core").SIDE_M() or S(16)
    local cx = x + pad + S(6)
    local h = S(44)
    local cy = y + math.floor((self.height - h) / 2)
    self.ctls = {}
    for _i, c in ipairs(controlsFor(self.view, self.fc)) do
        local tw = Dd.textWidth(c.text, face)
        c.x, c.y, c.w, c.h = cx, cy, tw + S(26), h
        paintControl(bb, c, false)
        self.ctls[#self.ctls + 1] = c
        cx = cx + c.w + S(44)
    end
    local more_w = S(30)
    local more = { id = "more", x = x + self.width - pad - more_w - S(10), y = cy, w = more_w, h = h }
    paintControl(bb, more, false)
    self.ctls[#self.ctls + 1] = more
end

function ControlsRow:onTapKoboCtl(_args, ges)
    local pos = ges and ges.pos
    if not (pos and self.ctls) then return false end
    for _i, c in ipairs(self.ctls) do
        if pos.x >= c.x - S(12) and pos.x < c.x + c.w + S(12) then
            M.openMenu(c, self)
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The menus
-- ---------------------------------------------------------------------------
local function filterRows(row)
    local Dd = D()
    local c = counts(row.fc)
    local cur = M.currentFilter()
    local rows = {}
    for i, f in ipairs(FILTERS) do
        local id = f.id
        rows[#rows + 1] = Dd.itemRow{
            text = f.label, face = "italic", check = cur == id, right = tostring(c[id] or 0),
            sep = i < #FILTERS, height = S(64),
            tap = function(dd)
                dd:close()
                UIManager:nextTick(function() M.setFilter(id) end)
                return true
            end,
        }
        if i == 1 then rows[#rows].sep = true end
    end
    return rows
end

local function sortRows(row)
    local Dd = D()
    local rows = {}
    if row.view == "author" then
        local AN = require("features/library/kui_author_names")
        for _i, o in ipairs({ { true, _("Last name") }, { false, _("First name") } }) do
            local on = o[1]
            rows[#rows + 1] = Dd.itemRow{ text = o[2], face = "italic", check = AN.isEnabled() == on, height = S(64),
                tap = function(dd)
                    dd:close()
                    UIManager:nextTick(function()
                        AN.setEnabled(on)
                        pcall(function() require("features/library/sui_metadata_source").clearCache() end)
                        local fm = fmInstance()
                        refreshLibrary(fm and fm.file_chooser)
                    end)
                    return true
                end }
        end
        return rows
    end
    local cur = currentSort().id
    for _i, s in ipairs(SORTS) do
        local id = s.id
        if FC().collates == nil or FC().collates[id] then
            rows[#rows + 1] = Dd.itemRow{ text = s.label, face = "italic", check = cur == id, height = S(64),
                tap = function(dd)
                    dd:close()
                    UIManager:nextTick(function() setSort(id) end)
                    return true
                end }
        end
    end
    return rows
end

local function moreRows(row)
    local Dd = D()
    local rows = {}
    local fm = fmInstance()
    local function act(text, fn, opts)
        opts = opts or {}
        rows[#rows + 1] = Dd.itemRow{ text = text, face = "italic", check = opts.check, height = S(64),
            tap = function(dd)
                dd:close()
                UIManager:nextTick(function()
                    local ok, err = pcall(fn)
                    if not ok then logger.warn("koboui: library option failed:", err) end
                end)
                return true
            end }
    end
    local view = row.view
    if view == "series" then
        local Shelf = require("features/library/kui_series_shelf")
        act(Shelf.isEnabled() and _("Folder view") or _("Bookshelf view"), function()
            Shelf.setEnabled(not Shelf.isEnabled())
            refreshLibrary(fm and fm.file_chooser)
            if fm and fm.file_chooser then pcall(function() fm.file_chooser:changeToPath(fm.file_chooser.path) end) end
        end)
    end
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if ok_bim and fm and fm.coverbrowser and not (fm.file_chooser and fm.file_chooser._kui_shelf_on) then
        local mode = bim:getSetting("filemanager_display_mode")
        local grid = mode and mode:find("^mosaic") ~= nil
        act(grid and _("List view") or _("Grid view"), function()
            fm.coverbrowser:setDisplayMode(grid and "list_image_meta" or "mosaic_image")
        end)
    end
    if view == "normal" then
        local FCov = require("features/library/sui_foldercovers")
        act(_("Group series"), function()
            FCov.setSeriesGrouping(not FCov.getSeriesGrouping())
            pcall(FCov.invalidateCache)
            refreshLibrary(fm and fm.file_chooser)
        end, { check = FCov.getSeriesGrouping() })
        act(_("Reverse order"), function()
            G_reader_settings:flipNilOrFalse("reverse_collate")
            if fm and fm.file_chooser then
                pcall(function() fm.file_chooser:clearSortingCache() end)
            end
            refreshLibrary(fm and fm.file_chooser)
        end, { check = G_reader_settings:isTrue("reverse_collate") })
    end
    if view == "collections" and fm and fm.collections then
        act(_("Manage collections"), function()
            require("features/library/kui_collections_view").showStockList(fm.collections)
        end)
    end
    act(M.showTags() and _("Hide Tags tab") or _("Show Tags tab"), function()
        SUISettings:saveSetting("koboui_tab_tags", not M.showTags())
        if fm and fm.file_chooser then refreshLibrary(fm.file_chooser) end
    end)
    for i, r in ipairs(rows) do r.sep = i < #rows end
    return rows
end

function M.openMenu(c, row)
    local Dd = D()
    local build, width
    if c.id == "filter" then build = function() return filterRows(row) end; width = S(300)
    elseif c.id == "sort" then build = function() return sortRows(row) end; width = S(280)
    else build = function() return moreRows(row) end; width = S(300) end
    local anchor = Geom:new{ x = c.x - S(10), y = c.y, w = c.w + S(20), h = c.h }
    if c.id == "more" then
        local r = math.floor(math.max(c.w, c.h) / 2)
        local cx, cy = c.x + math.floor(c.w / 2), c.y + math.floor(c.h / 2)
        anchor = Geom:new{ x = cx - r, y = cy - r, w = r * 2, h = r * 2 }
    end
    local dd = Dd.DropDown:new{
        anchor = anchor, width = width, build = build,
        align = c.id == "more" and "center" or "left",
        paint_anchor = function(bb) paintControl(bb, c, true) end,
    }
    dd:show()
end

-- ---------------------------------------------------------------------------
-- Hooks used by kui_status_filter.lua
-- ---------------------------------------------------------------------------
function M.wanted(fc)
    return fc and fc.name == "filemanager" and M.rootView(fc) ~= nil
end

function M.reservedHeight(fc)
    return M.wanted(fc) and M.rowHeight() or 0
end

function M.decorate(fc)
    if not (M.wanted(fc) and fc.item_group) then return end
    M.invalidateCounts()
    local w = (fc.inner_dimen and fc.inner_dimen.w) or Screen:getWidth()
    local row = ControlsRow:new{ width = w, height = M.rowHeight(), fc = fc, view = M.rootView(fc) }
    table.insert(fc.item_group, 1, row)
    if fc.item_group.resetLayout then fc.item_group:resetLayout() end
end

return M
