-- module_month_tbr.lua — KoboUI
-- Home screen module: this month's TBR, as a checklist.
--
-- Each month has its own list of books to read. The module shows the
-- shown month's list with a checkbox per book: a book is ticked on its
-- own once it is marked Finished in KOReader, and books read elsewhere
-- (or not tracked) can be ticked by hand. ‹ › on the label row go to
-- other months, so the next month can be planned ahead.
--
--   tap a checkbox → tick / untick (finished books stay ticked)
--   tap a book     → open it
--   hold a book    → remove it, or move it to next month
--   "Add books"    → pick books from the library (checklist)
--
-- Books can also be added from a book's long-press menu in the Library
-- ("Add to <month> TBR").
--
-- Storage: SUISettings "kindleui_month_tbr" = { ["YYYY-MM"] = { {fp, title,
-- authors, done}, … } }.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Widget         = require("ui/widget/widget")
local lfs            = require("libs/libkoreader-lfs")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")

local M = {}

M.id          = "month_tbr"
M.name        = _("Monthly TBR")
M.label       = _("Monthly TBR")
M.enabled_key = "month_tbr_enabled"
M.default_on  = false

local function S(n) return Screen:scaleBySize(n) end

local STORE_KEY      = "kindleui_month_tbr"
local SETTING_ROWS   = "month_tbr_rows"
local SETTING_COVERS = "month_tbr_covers"
local ROWS_DEF, ROWS_MIN, ROWS_MAX = 5, 2, 15

local function maxRows(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_ROWS)) or ROWS_DEF
    return math.max(ROWS_MIN, math.min(ROWS_MAX, math.floor(v)))
end
local function showCovers(pfx)
    return SUISettings:readSetting(pfx .. SETTING_COVERS) ~= false
end

local MONTHS = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
                 _("July"), _("August"), _("September"), _("October"), _("November"), _("December") }

-- ---------------------------------------------------------------------------
-- Months
-- ---------------------------------------------------------------------------
local function monthKey(year, month)
    local d = os.date("*t", os.time{ year = year, month = month, day = 1, hour = 12 })
    return string.format("%04d-%02d", d.year, d.month), d.year, d.month
end
local function keyOffset(offset)
    local t = os.date("*t")
    return monthKey(t.year, t.month + (offset or 0))
end
function M.currentKey() return (keyOffset(0)) end

function M.monthName(key)
    local y, m = key:match("^(%d+)%-(%d+)$")
    y, m = tonumber(y), tonumber(m)
    if not (y and m) then return key end
    if y == tonumber(os.date("%Y")) then return MONTHS[m] end
    return MONTHS[m] .. " " .. y
end

-- Month shown, as an offset from this month (back to this month every
-- time Home opens). Up to 3 months ahead, for planning.
local AHEAD = 3
local _offset, _offset_gen = 0, nil
local function currentOffset()
    local ok, SE = pcall(require, "engines/sui_screen_engine")
    local gen = ok and SE and SE.open_generation or 0
    if gen ~= _offset_gen then _offset_gen = gen; _offset = 0 end
    return _offset
end
local function shownKey() return (keyOffset(currentOffset())) end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
local function store()
    local s = SUISettings:readSetting(STORE_KEY)
    if type(s) ~= "table" then s = {} end
    return s
end
local function saveStore(s) SUISettings:saveSetting(STORE_KEY, s) end

function M.getList(key)
    local l = store()[key]
    return type(l) == "table" and l or {}
end
local function setList(key, list)
    local s = store()
    if #list == 0 then s[key] = nil else s[key] = list end
    saveStore(s)
end

local function indexOf(list, fp)
    for i, it in ipairs(list) do if it.fp == fp then return i end end
end
function M.contains(key, fp) return indexOf(M.getList(key), fp) ~= nil end

local function bookMeta(fp)
    local title, authors
    local ok_bim, bim = pcall(require, "bookinfomanager")
    local bi = ok_bim and bim and bim:getBookInfo(fp, false)
    if bi then title, authors = bi.title, bi.authors end
    if not title or title == "" then title = fp:match("([^/]+)%.[^.]+$") or fp end
    return title, authors
end

function M.add(key, fp)
    local list = M.getList(key)
    if indexOf(list, fp) then return false end
    local title, authors = bookMeta(fp)
    list[#list + 1] = { fp = fp, title = title, authors = authors }
    setList(key, list)
    return true
end
function M.remove(key, fp)
    local list = M.getList(key)
    local i = indexOf(list, fp)
    if not i then return false end
    table.remove(list, i)
    setList(key, list)
    return true
end
local function setDone(key, fp, done)
    local list = M.getList(key)
    local i = indexOf(list, fp)
    if not i then return end
    list[i].done = done or nil
    setList(key, list)
end

-- Book status from its sidecar: "complete", "reading", … and progress.
local function bookStatus(fp)
    if lfs.attributes(fp, "mode") ~= "file" then return "missing", nil end
    local SH = package.loaded["modules/module_books_shared"]
    local cached = SH and SH._cacheGet and SH._cacheGet(fp)
    local summary, pct
    if cached then summary, pct = cached.summary, cached.percent end
    if summary == nil and pct == nil then
        local ok_DS, DocSettings = pcall(require, "docsettings")
        if ok_DS and DocSettings:hasSidecarFile(fp) then
            local ok, ds = pcall(DocSettings.open, DocSettings, fp)
            if ok and ds then
                summary = ds:readSetting("summary")
                pct = ds:readSetting("percent_finished")
            end
        end
    end
    local status = type(summary) == "table" and summary.status or nil
    if not status and pct and pct > 0 then status = "reading" end
    return status or "new", pct
end

-- ticked = finished in KOReader, or ticked by hand
local function isChecked(item)
    if item.done then return true end
    return (bookStatus(item.fp)) == "complete"
end

function M.counts(key)
    local list = M.getList(key)
    local done = 0
    for _i, it in ipairs(list) do if isChecked(it) then done = done + 1 end end
    return done, #list
end

-- Small covers, kept for the session.
local _covers, _ncovers = {}, 0
local function coverBB(fp, w, h)
    local key = fp .. "|" .. w .. "x" .. h
    local bb = _covers[key]
    if bb ~= nil then return bb or nil end
    local ok, got = pcall(Config.getCroppedCoverBB, fp, w, h, "center")
    bb = ok and got or nil
    if bb then
        if _ncovers > 200 then _covers, _ncovers = {}, 0 end
        _covers[key] = bb
        _ncovers = _ncovers + 1
    elseif not Config.cover_extraction_pending then
        _covers[key] = false
    end
    return bb
end

local function refreshHome()
    local HS = package.loaded["screens/sui_homescreen"]
    if HS and HS.refresh then pcall(HS.refresh, false) end
end

-- ---------------------------------------------------------------------------
-- Book picker: the library as a checklist
-- ---------------------------------------------------------------------------
local BOX_ON, BOX_OFF = "\u{2611}  ", "\u{2610}  "

local function libraryBooks()
    local out, seen = {}, {}
    local function push(fp, title, authors)
        if fp and not seen[fp] and lfs.attributes(fp, "mode") == "file" then
            seen[fp] = true
            if not title or title == "" then title, authors = bookMeta(fp) end
            out[#out + 1] = { fp = fp, title = title, authors = authors }
        end
    end
    local home = G_reader_settings:readSetting("home_dir")
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if home and ok_bim and bim then
        local ok_ms, MS = pcall(require, "features/library/sui_metadata_source")
        if ok_ms and MS then
            local ok, rows = pcall(MS.getMatchingFiles, bim, home, nil, { recursive = true })
            if ok and rows then
                for _i, r in ipairs(rows) do push(r[1], r.title, r.authors) end
            end
        end
    end
    local hist = package.loaded["readhistory"]
    for _i, e in ipairs(hist and hist.hist or {}) do push(e.file) end
    return out
end

function M.showPicker(key)
    local Menu = require("ui/widget/menu")
    local ffiUtil = require("ffi/util")
    local list = M.getList(key)
    local chosen = {}
    for _i, it in ipairs(list) do chosen[it.fp] = true end
    local books = libraryBooks()
    -- unread / in progress first, finished last; then by title
    local fin = {}
    for _i, b in ipairs(books) do fin[b.fp] = (bookStatus(b.fp)) == "complete" end
    table.sort(books, function(a, b)
        if chosen[a.fp] ~= chosen[b.fp] then return chosen[a.fp] == true end
        if fin[a.fp] ~= fin[b.fp] then return not fin[a.fp] end
        return ffiUtil.strcoll(a.title:lower(), b.title:lower())
    end)
    local menu
    local items = {}
    local function label(b)
        local a = b.authors and b.authors ~= "" and ("  —  " .. b.authors:gsub("\n.*", " et al.")) or ""
        return (chosen[b.fp] and BOX_ON or BOX_OFF) .. b.title .. a
    end
    for _i, b in ipairs(books) do
        local item
        item = {
            text = label(b),
            mandatory = fin[b.fp] and _("Finished") or nil,
            dim = nil,
            callback = function()
                chosen[b.fp] = not chosen[b.fp] or nil
                item.text = label(b)
                menu:updateItems(nil, true)
            end,
        }
        items[#items + 1] = item
    end
    local function title()
        local n = 0
        for _fp in pairs(chosen) do n = n + 1 end
        return string.format(_("%s TBR · %d chosen"), M.monthName(key), n)
    end
    menu = Menu:new{
        title = title(),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    -- Save when the picker closes (not close_callback: Menu calls that
    -- after every tap on an item).
    local orig_close = menu.onCloseAllMenus
    menu.onCloseAllMenus = function(self)
        -- keep the existing order (and hand ticks), add new ones at the end
        local new = {}
        for _i, it in ipairs(M.getList(key)) do
            if chosen[it.fp] then new[#new + 1] = it; chosen[it.fp] = "kept" end
        end
        for _i, b in ipairs(books) do
            if chosen[b.fp] == true then
                new[#new + 1] = { fp = b.fp, title = b.title, authors = b.authors }
            end
        end
        setList(key, new)
        local r = orig_close(self)
        refreshHome()
        return r
    end
    -- live count in the title
    local orig_update = menu.updateItems
    menu.updateItems = function(self, ...)
        if self.title_bar and self.title_bar.setTitle then pcall(self.title_bar.setTitle, self.title_bar, title()) end
        return orig_update(self, ...)
    end
    UIManager:show(menu)
end

-- Unticked books of last month → this month.
function M.carryOver(key)
    local y, m = key:match("^(%d+)%-(%d+)$")
    local prev = monthKey(tonumber(y), tonumber(m) - 1)
    local n = 0
    for _i, it in ipairs(M.getList(prev)) do
        if not isChecked(it) and M.add(key, it.fp) then n = n + 1 end
    end
    return n, prev
end

-- ---------------------------------------------------------------------------
-- Long-press menu button (Library): "Add to <month> TBR"
-- ---------------------------------------------------------------------------
function M.genButton(file, close_cb)
    local key = M.currentKey()
    local inside = M.contains(key, file)
    local name = M.monthName(key)
    return {
        text = inside and string.format(_("Remove from %s TBR"), name) or string.format(_("Add to %s TBR"), name),
        callback = function()
            if inside then M.remove(key, file) else M.add(key, file) end
            if close_cb then close_cb() end
            refreshHome()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Label row
-- ---------------------------------------------------------------------------
function M.label_func()
    return string.format(_("%s TBR"), M.monthName(shownKey()))
end

function M.label_sub_func()
    local done, total = M.counts(shownKey())
    if total == 0 then return nil end
    return string.format(_("%d of %d read"), done, total)
end

function M.label_right_func() return "" end

local NAV_SPAN = 10000
function M.label_nav_func(ctx, screen)
    local off = currentOffset()
    return {
        mod_id        = M.id,
        page          = NAV_SPAN - AHEAD + off,
        npages        = NAV_SPAN,
        has_wallpaper = ctx and ctx.has_wallpaper,
        turnPageFn    = function(delta)
            local new = math.min(AHEAD, currentOffset() + delta)
            if new == _offset then return end
            _offset = new
            if screen and screen._refreshImmediate then
                screen:_refreshImmediate(true)
            elseif ctx and ctx.refresh_fn then
                ctx.refresh_fn()
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------
local function rowHeight(pfx)
    return showCovers(pfx) and S(56) or S(40)
end

local function visibleRows(pfx, key)
    return math.min(#M.getList(key), maxRows(pfx))
end

local function moduleHeight(ctx)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local n = visibleRows(pfx, shownKey())
    -- rows + the "Add books" line (and "N more" when cut)
    return n * rowHeight(pfx) + S(40)
end

-- A white check mark drawn on the filled box: a short stroke down, then a
-- long one up to the right. Sharp, not rounded: flat ends and a pointed
-- corner (each stroke runs half a thickness past the joint). Filled
-- pixel by pixel, so the edges stay crisp.
local function inStroke(px, py, x0, y0, x1, y1, t, ext0, ext1)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then return false end
    local ux, uy = dx / len, dy / len
    local rx, ry = px - x0, py - y0
    local along = rx * ux + ry * uy
    local across = math.abs(-rx * uy + ry * ux)
    return across <= t / 2 and along >= -ext0 and along <= len + ext1
end

-- Preferred: the check mark from icons/kui_check.svg, rendered smooth
-- (anti-aliased) at the box size. The pixel version below is the fallback.
local _tick_icons = {}
local function drawTickSVG(bb, bx, by, box)
    local w = _tick_icons[box]
    if w == nil then
        w = false
        pcall(function()
            local path = require("infra/sui_paths").getPluginDir() .. "icons/kui_check.svg"
            if lfs.attributes(path, "mode") ~= "file" then return end
            local ImageWidget = require("ui/widget/imagewidget")
            local img = ImageWidget:new{ file = path, width = box, height = box, alpha = true,
                is_icon = true }
            img:_render()
            w = img
        end)
        _tick_icons[box] = w
    end
    if not w then return false end
    return pcall(w.paintTo, w, bb, bx, by)
end

local function drawTickPixels(bb, bx, by, box)
    local t = math.max(2, box * 0.10)
    local ax, ay = box * 0.29, box * 0.53
    local jx, jy = box * 0.44, box * 0.67
    local cx, cy = box * 0.73, box * 0.35
    local x0, x1 = math.floor(box * 0.20), math.ceil(box * 0.82)
    local y0, y1 = math.floor(box * 0.25), math.ceil(box * 0.80)
    for py = y0, y1 do
        local run_start
        for px = x0, x1 + 1 do
            local cxp, cyp = px + 0.5, py + 0.5
            local on = px <= x1 and (inStroke(cxp, cyp, ax, ay, jx, jy, t, 0, t / 2)
                or inStroke(cxp, cyp, jx, jy, cx, cy, t, t / 2, 0))
            if on and not run_start then
                run_start = px
            elseif not on and run_start then
                bb:paintRect(bx + run_start, by + py, px - run_start, 1, Blitbuffer.COLOR_WHITE)
                run_start = nil
            end
        end
    end
end

local function drawTick(bb, bx, by, box)
    if not drawTickSVG(bb, bx, by, box) then drawTickPixels(bb, bx, by, box) end
end

local ListWidget = Widget:extend{ width = 0, height = 0 }

function ListWidget:getSize() return Geom:new{ w = self.width, h = self.height } end

function ListWidget:init()
    local pfx = self.pfx
    self.key = shownKey()
    local list = M.getList(self.key)
    self.row_h = rowHeight(pfx)
    self.covers = showCovers(pfx)
    local nrows = visibleRows(pfx, self.key)
    self.more = #list - nrows

    local title_face = Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_DETAIL)
    local sub_face   = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)

    self.box = S(24)
    self.thumb_w = self.covers and math.floor((self.row_h - S(10)) / 1.5) or 0
    local text_x = self.box + S(12) + (self.covers and (self.thumb_w + S(10)) or 0)
    self.text_x = text_x
    local text_w = self.width - text_x - S(4)

    self.rows = {}
    for i = 1, nrows do
        local it = list[i]
        local status, pct = bookStatus(it.fp)
        local checked = it.done or status == "complete"
        local right
        if it.done and status ~= "complete" then right = nil
        elseif status == "complete" then right = _("Finished")
        elseif status == "missing" then right = _("Not on device")
        elseif pct and pct > 0 then right = string.format("%d%%", math.floor(pct * 100 + 0.5))
        end
        local right_tw = right and TextWidget:new{ text = right, face = sub_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        local rw = right_tw and (right_tw:getSize().w + S(8)) or 0
        self.rows[i] = {
            item = it,
            checked = checked,
            locked = status == "complete",
            title = TextWidget:new{ text = it.title or "?", face = title_face, max_width = text_w - rw,
                truncate_with_ellipsis = true,
                fgcolor = checked and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK },
            author = it.authors and it.authors ~= "" and TextWidget:new{
                text = it.authors:gsub("\n.*", " et al."), face = sub_face, max_width = text_w - rw,
                truncate_with_ellipsis = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY } or nil,
            right = right_tw,
        }
    end
    local add_text = #list == 0 and string.format(_("+  Plan your %s TBR"), M.monthName(self.key)) or _("+  Add books")
    if self.more > 0 then add_text = string.format(_("%d more  ·  "), self.more) .. add_text end
    self.add = TextWidget:new{ text = add_text, face = sub_face, fgcolor = Blitbuffer.COLOR_BLACK }
end

function ListWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local row_h, box = self.row_h, self.box
    self.hits = {}
    for i, r in ipairs(self.rows) do
        local ry = y + (i - 1) * row_h
        -- checkbox
        local bx, by = x + S(2), ry + math.floor((row_h - box) / 2)
        if r.checked then
            bb:paintRect(bx, by, box, box, Blitbuffer.COLOR_BLACK)
            drawTick(bb, bx, by, box)
        else
            bb:paintBorder(bx, by, box, box, math.max(2, S(2)), Blitbuffer.COLOR_BLACK)
        end
        self.hits[#self.hits + 1] = { x = x, y = ry, w = box + S(12), h = row_h, row = r, kind = "box" }
        -- cover
        local tx = x + self.text_x
        if self.covers then
            local th = row_h - S(10)
            local cx = x + box + S(12)
            local cy = ry + S(5)
            local cbb = coverBB(r.item.fp, self.thumb_w, th)
            if cbb then
                -- night mode: pre-invert so the cover keeps its colours
                if Screen.night_mode then
                    bb:invertblitFrom(cbb, cx, cy, 0, 0, self.thumb_w, th)
                else
                    bb:blitFrom(cbb, cx, cy, 0, 0, self.thumb_w, th)
                end
                if r.checked then bb:lightenRect(cx, cy, self.thumb_w, th, 0.4) end
            else
                bb:paintRect(cx, cy, self.thumb_w, th, Blitbuffer.COLOR_GRAY_E)
            end
            bb:paintBorder(cx, cy, self.thumb_w, th, 1, Blitbuffer.COLOR_BLACK)
        end
        -- text
        local th_ = r.title:getSize().h + (r.author and r.author:getSize().h or 0)
        local ty = ry + math.floor((row_h - th_) / 2)
        r.title:paintTo(bb, tx, ty)
        if r.checked then
            -- crossed out, like a ticked list
            local tw = r.title:getSize()
            bb:paintRect(tx, ty + math.floor(tw.h / 2), tw.w, math.max(1, S(1)), Blitbuffer.COLOR_DARK_GRAY)
        end
        if r.author then r.author:paintTo(bb, tx, ty + r.title:getSize().h) end
        if r.right then
            local rs = r.right:getSize()
            r.right:paintTo(bb, x + self.width - rs.w - S(2), ry + math.floor((row_h - rs.h) / 2))
        end
        self.hits[#self.hits + 1] = { x = x + box + S(12), y = ry, w = self.width - box - S(12), h = row_h, row = r, kind = "book" }
        -- separator
        bb:paintRect(tx, ry + row_h - 1, self.width - (tx - x), 1, Blitbuffer.COLOR_GRAY_D)
    end
    local ay = y + #self.rows * row_h
    local as = self.add:getSize()
    local add_y = ay + math.floor((S(40) - as.h) / 2)
    self.add:paintTo(bb, x + S(2), add_y)
    self.hits[#self.hits + 1] = { x = x, y = ay, w = self.width, h = S(40), kind = "add" }
end

function ListWidget:hitAt(pos)
    if not (pos and self.hits) then return nil end
    for _i, h in ipairs(self.hits) do
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y and pos.y < h.y + h.h then return h end
    end
end

function ListWidget:free()
    for _i, r in ipairs(self.rows or {}) do
        r.title:free()
        if r.author then r.author:free() end
        if r.right then r.right:free() end
    end
    if self.add then self.add:free() end
end

local function showBookDialog(key, item, open_fn)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local y, m = key:match("^(%d+)%-(%d+)$")
    local next_key = monthKey(tonumber(y), tonumber(m) + 1)
    dialog = ButtonDialog:new{
        title = item.title,
        title_align = "center",
        buttons = {
            {{ text = _("Open book"), enabled = lfs.attributes(item.fp, "mode") == "file", callback = function()
                UIManager:close(dialog)
                if open_fn then open_fn(item.fp) end
            end }},
            {{ text = string.format(_("Move to %s TBR"), M.monthName(next_key)), callback = function()
                UIManager:close(dialog)
                M.remove(key, item.fp)
                M.add(next_key, item.fp)
                refreshHome()
            end }},
            {{ text = string.format(_("Remove from %s TBR"), M.monthName(key)), callback = function()
                UIManager:close(dialog)
                M.remove(key, item.fp)
                refreshHome()
            end }},
            {{ text = _("Edit the list…"), callback = function()
                UIManager:close(dialog)
                M.showPicker(key)
            end }},
        },
    }
    UIManager:show(dialog)
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Monthly TBR"))
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local h = moduleHeight(ctx)
    local lw = ListWidget:new{ width = w, height = h, pfx = pfx }
    local open_fn = ctx and ctx.open_fn
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = lw,
    }
    tappable.ges_events = {
        TapMonthTBR  = { GestureRange:new{ ges = "tap",  range = function() return tappable.dimen end } },
        HoldMonthTBR = { GestureRange:new{ ges = "hold", range = function() return tappable.dimen end } },
    }
    function tappable:onTapMonthTBR(_args, ges)
        local hit = lw:hitAt(ges and ges.pos)
        if not hit then return true end
        if hit.kind == "add" then
            M.showPicker(lw.key)
        elseif hit.kind == "box" then
            if hit.row.locked then
                UI.Notify.toast(_("Finished in KOReader — ticked automatically."))
            else
                setDone(lw.key, hit.row.item.fp, not hit.row.checked)
                refreshHome()
            end
        elseif hit.kind == "book" then
            if lfs.attributes(hit.row.item.fp, "mode") == "file" and open_fn then
                open_fn(hit.row.item.fp)
            end
        end
        return true
    end
    function tappable:onHoldMonthTBR(_args, ges)
        local hit = lw:hitAt(ges and ges.pos)
        if hit and hit.row then
            showBookDialog(lw.key, hit.row.item, open_fn)
            return true
        end
        return false
    end
    return tappable
end

function M.getHeight(ctx)
    return moduleHeight(ctx)
end

function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        {
            text_func = function() return string.format(_lc("Edit %s TBR…"), M.monthName(M.currentKey())) end,
            callback = function() M.showPicker(M.currentKey()) end,
        },
        {
            text_func = function() return string.format(_lc("Edit %s TBR…"), M.monthName((keyOffset(1)))) end,
            callback = function() M.showPicker((keyOffset(1))) end,
        },
        {
            text = _lc("Carry over unread books from last month"),
            keep_menu_open = true,
            callback = function()
                local n, prev = M.carryOver(M.currentKey())
                UI.Notify.toast(string.format(_lc("%d book(s) added from %s."), n, M.monthName(prev)))
                ctx_menu.refresh()
            end,
        },
        Config.makeStepperItem{
            text_func     = function() return _lc("Books shown") end,
            get           = function() return maxRows(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_ROWS, v) end,
            title         = _lc("Books shown"),
            info          = _lc("How many books of the list the module shows."),
            value_min     = ROWS_MIN,
            value_max     = ROWS_MAX,
            value_step    = 1,
            default_value = ROWS_DEF,
            refresh       = ctx_menu.refresh,
        },
        {
            text           = _lc("Show covers"),
            checked_func   = function() return showCovers(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_COVERS, not showCovers(pfx))
                ctx_menu.refresh()
            end,
        },
        Config.makeLabelToggleItem("month_tbr", _("Monthly TBR"), ctx_menu.refresh, _lc),
    }
end

return M
