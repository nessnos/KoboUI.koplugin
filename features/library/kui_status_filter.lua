-- kui_status_filter.lua — KoboUI
-- Library: a row of KindleOS-style filter chips at the top of the list —
-- "Unread (711)" "Read (78)". Tap one to show only those books, tap it
-- again to show everything.
--
--   Unread = not marked Finished (new, reading, on hold)
--   Read   = marked Finished
--
-- It drives KOReader's own file-browser status filter
-- (FileChooser.show_filter.status, also in File browser → Book status), so
-- every Library view follows it: folders, All books, Authors, Series
-- (folders and bookshelf), Collections and Tags, through
-- FileChooser:show_file(). The choice is kept like KOReader's.
--
-- Layout: the chip row is put at the top of the file chooser's item group,
-- and the item area is laid out that much shorter (instance-level wraps
-- of _recalculateDimen and updateItems, like the vertical scrollbar).
-- The Series bookshelf, which lays out its own pages, calls
-- M.reservedHeight / M.decorate itself.
--
-- Setting: kindleui_status_chips (default on).

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local lfs            = require("libs/libkoreader-lfs")
local logger         = require("logger")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")

local M = {}

local KEY = "kindleui_status_chips"
function M.isEnabled() return SUISettings:nilOrTrue(KEY) end

local function S(n) return Screen:scaleBySize(n) end

local UNREAD = { new = true, reading = true, abandoned = true }
local READ   = { complete = true }

local function FC() return require("ui/widget/filechooser") end

-- "unread", "read" or nil (everything, or a mix set in KOReader's menu)
function M.current()
    local st = FC().show_filter and FC().show_filter.status
    if not st then return nil end
    local function same(set)
        for k in pairs(set) do if not st[k] then return false end end
        for k in pairs(st) do if not set[k] then return false end end
        return true
    end
    if same(UNREAD) then return "unread" end
    if same(READ) then return "read" end
    return nil
end

function M.set(which)
    local FileChooser = FC()
    FileChooser.show_filter = FileChooser.show_filter or {}
    if which == "unread" then
        FileChooser.show_filter.status = { new = true, reading = true, abandoned = true }
    elseif which == "read" then
        FileChooser.show_filter.status = { complete = true }
    else
        FileChooser.show_filter.status = nil
    end
end

-- ---------------------------------------------------------------------------
-- Counts over the whole library (home folder), cached until a book's status
-- changes or the library changes.
-- ---------------------------------------------------------------------------
local _counts = nil
function M.invalidate() _counts = nil end

local function counts(fc)
    if _counts then return _counts end
    local unread, read = 0, 0
    local ok = pcall(function()
        local home = G_reader_settings:readSetting("home_dir")
        local bim = require("bookinfomanager")
        local MS = require("features/library/sui_metadata_source")
        local BookList = require("ui/widget/booklist")
        local FileChooser = FC()
        -- count without the status filter itself
        local saved = FileChooser.show_filter.status
        FileChooser.show_filter.status = nil
        local rows = (home and MS.getMatchingFiles(bim, home, nil, { recursive = true })) or {}
        for _i, r in ipairs(rows) do
            local fp, fname = r[1], r[2]
            if lfs.attributes(fp, "mode") == "file" and fc:show_file(fname, fp) then
                if BookList.getBookStatus(fp) == "complete" then read = read + 1 else unread = unread + 1 end
            end
        end
        FileChooser.show_filter.status = saved
    end)
    if not ok then return { unread = 0, read = 0 } end
    _counts = { unread = unread, read = read }
    return _counts
end

-- ---------------------------------------------------------------------------
-- The chip row
-- ---------------------------------------------------------------------------
function M.rowHeight() return S(60) end

local ChipRow = InputContainer:extend{ width = 0, height = 0, fc = nil }

function ChipRow:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapChip = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function ChipRow:getSize() return Geom:new{ w = self.width, h = self.height } end

function ChipRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local c = counts(self.fc)
    local cur = M.current()
    local face = Font:getFace("cfont", 15)
    local chip_h = S(42)
    local pad_x = S(14)
    local gap = S(10)
    local cx = x + S(12)
    local cy = y + math.floor((self.height - chip_h) / 2)
    self.chips = {}
    for _i, def in ipairs({
        { id = "unread", text = string.format(_("Unread (%d)"), c.unread) },
        { id = "read",   text = string.format(_("Read (%d)"), c.read) },
    }) do
        local on = cur == def.id
        local tw = TextWidget:new{ text = def.text, face = face,
            fgcolor = on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK }
        local ts = tw:getSize()
        local w = ts.w + 2 * pad_x
        local r = math.floor(chip_h / 2)
        if on then
            bb:paintRoundedRect(cx, cy, w, chip_h, Blitbuffer.COLOR_BLACK, r)
        else
            bb:paintRoundedRect(cx, cy, w, chip_h, Blitbuffer.COLOR_DARK_GRAY, r)
            local b = math.max(1, S(1))
            bb:paintRoundedRect(cx + b, cy + b, w - 2 * b, chip_h - 2 * b, Blitbuffer.COLOR_WHITE, r - b)
        end
        tw:paintTo(bb, cx + pad_x, cy + math.floor((chip_h - ts.h) / 2))
        tw:free()
        self.chips[#self.chips + 1] = { id = def.id, x = cx, w = w }
        cx = cx + w + gap
    end
end

function ChipRow:onTapChip(_args, ges)
    local pos = ges and ges.pos
    if not (pos and self.chips) then return false end
    for _i, ch in ipairs(self.chips) do
        if pos.x >= ch.x - S(4) and pos.x < ch.x + ch.w + S(4) then
            M.set(M.current() ~= ch.id and ch.id or nil)
            local fc = self.fc
            pcall(function() require("features/library/sui_foldercovers").invalidateItemTableCache() end)
            pcall(function() require("features/library/sui_metadata_source").clearCache() end)
            if fc then
                if fc._kui_shelf_on then
                    -- the bookshelf builds its shelves on path changes
                    pcall(function() fc:changeToPath(fc.path) end)
                else
                    pcall(fc.refreshPath, fc)
                end
            end
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
-- Not on the Series bookshelf: it shows the whole bookcase, unfiltered.
local function wanted(fc)
    return fc and fc.name == "filemanager" and M.isEnabled() and not fc._kui_shelf_on
end

local function KH()
    local ok, H = pcall(require, "features/library/kbo_library_header")
    return ok and H.isEnabled() and H or nil
end

function M.reservedHeight(fc)
    -- KoboUI: the Kobo Filter / Sort row replaces the chips.
    local H = KH()
    if H then return H.reservedHeight(fc) end
    return wanted(fc) and M.rowHeight() or 0
end

-- Puts the chip row on top of fc's item group (after it was filled).
function M.decorate(fc)
    local H = KH()
    if H then return H.decorate(fc) end
    if not wanted(fc) or not fc.item_group then return end
    M.invalidate() -- recount: cheap, and the library may have changed
    local w = (fc.inner_dimen and fc.inner_dimen.w) or Screen:getWidth()
    local row = ChipRow:new{ width = w, height = M.rowHeight(), fc = fc }
    table.insert(fc.item_group, 1, row)
    if fc.item_group.resetLayout then fc.item_group:resetLayout() end
end

local _installed = false
function M.install()
    if _installed then return end
    _installed = true
    local FileChooser = FC()
    local orig_init = FileChooser.init
    FileChooser.init = function(self, ...)
        if self.name == "filemanager" then
            local inst_recalc = rawget(self, "_recalculateDimen")
            self._recalculateDimen = function(inst, ...)
                local dimen = inst.inner_dimen
                local true_h = dimen and dimen.h
                local res = M.reservedHeight(inst)
                if dimen and true_h and res > 0 then dimen.h = true_h - res end
                local f = inst_recalc or FileChooser._recalculateDimen
                local ok, err = pcall(f, inst, ...)
                if dimen and true_h then dimen.h = true_h end
                if not ok then logger.warn("kindleui: status chips recalc:", err) end
            end
            self.updateItems = function(inst, ...)
                local r = FileChooser.updateItems(inst, ...)
                M.decorate(inst)
                return r
            end
        end
        return orig_init(self, ...)
    end
end

return M
