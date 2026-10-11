-- module_year_books.lua — KoboUI
-- Home screen module: "Year in Books" — the books finished in each month
-- of the year, as a bar chart of covers.
--
-- One column per month (J F M … D). Each column is a stack of the covers
-- finished that month: the latest one on top, in full, and the others as
-- slices underneath, so a column grows with the number of books. The count
-- sits above each stack; the current month is in bold with a dot under
-- it. Tap a month for the list of books finished then (tap one to open
-- it). ‹ › on the label row go to earlier years.
--
-- Data: books marked Finished in KOReader (sidecar summary.status
-- "complete"), dated by summary.date_finished, or by the date of the
-- status change.

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

M.id          = "year_books"
M.name        = _("Year in Books")
M.label       = _("Year in Books")
M.enabled_key = "year_books_enabled"
M.default_on  = false

local function S(n) return Screen:scaleBySize(n) end

local SETTING_HEIGHT = "year_books_cover_pct"
local HEIGHT_DEF, HEIGHT_MIN, HEIGHT_MAX = 100, 50, 100 -- cover size, % of the column
local SETTING_COVERS = "year_books_covers"

local function getHeightPct(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_HEIGHT))
    if not v then return HEIGHT_DEF end
    return math.max(HEIGHT_MIN, math.min(HEIGHT_MAX, math.floor(v)))
end
local function showCovers(pfx)
    return SUISettings:readSetting(pfx .. SETTING_COVERS) ~= false
end

local LETTERS = { _("J"), _("F"), _("M"), _("A"), _("M"), _("J"), _("J"), _("A"), _("S"), _("O"), _("N"), _("D") }
local MONTHS  = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
                  _("July"), _("August"), _("September"), _("October"), _("November"), _("December") }

-- Year shown, as an offset from this year. Back to this year every time
-- Home opens.
local _offset, _offset_gen = 0, nil
local function currentOffset()
    local ok, SE = pcall(require, "engines/sui_screen_engine")
    local gen = ok and SE and SE.open_generation or 0
    if gen ~= _offset_gen then _offset_gen = gen; _offset = 0 end
    return _offset
end
local function shownYear()
    return tonumber(os.date("%Y")) + currentOffset()
end

-- ---------------------------------------------------------------------------
-- Data: finished books per month. { [month] = { {fp, title, authors, date}, … } }
-- newest first. Cached per year; dropped when a book's status changes.
-- ---------------------------------------------------------------------------
local _cache = {}
function M.invalidateCache() _cache = {} end

local function finishDate(summary)
    if type(summary) ~= "table" then return nil end
    local d = summary.date_finished
    if type(d) ~= "string" and type(summary.modified) == "string" then d = summary.modified end
    if type(d) == "string" and d:match("^%d%d%d%d%-%d%d") then return d end
    return nil
end

local function readSummary(fp)
    local SH = package.loaded["modules/module_books_shared"]
    local cached = SH and SH._cacheGet and SH._cacheGet(fp)
    if cached and cached.summary ~= nil then
        return cached.summary, cached.title, cached.authors
    end
    local ok_DS, DocSettings = pcall(require, "docsettings")
    if not ok_DS or not DocSettings:hasSidecarFile(fp) then return nil end
    local ok, ds = pcall(DocSettings.open, DocSettings, fp)
    if not ok or not ds then return nil end
    -- read only: no ds:close() (it would rewrite the sidecar)
    local props = ds:readSetting("doc_props") or {}
    return ds:readSetting("summary"), props.title, props.authors
end

function M.getYear(year)
    local hist = package.loaded["readhistory"]
    local nhist = hist and hist.hist and #hist.hist or 0
    local key = tostring(year)
    local hit = _cache[key]
    if hit and hit.nhist == nhist and hit.day == os.date("%Y-%m-%d") then return hit end
    local data = { nhist = nhist, day = os.date("%Y-%m-%d"), months = {}, total = 0 }
    for m = 1, 12 do data.months[m] = {} end
    local ystr = tostring(year)
    local seen = {}
    if hist and hist.hist then
        for i = 1, math.min(nhist, 3000) do
            local e = hist.hist[i]
            local fp = e and e.file
            if fp and not seen[fp] and lfs.attributes(fp, "mode") == "file" then
                seen[fp] = true
                local summary, title, authors = readSummary(fp)
                if type(summary) == "table" and summary.status == "complete" and not summary.exclude_from_goals then
                    local d = finishDate(summary)
                    if d and d:sub(1, 4) == ystr then
                        local m = tonumber(d:sub(6, 7))
                        if m and m >= 1 and m <= 12 then
                            if not title then
                                local ok_bim, bim = pcall(require, "bookinfomanager")
                                local bi = ok_bim and bim and bim:getBookInfo(fp, false)
                                title = bi and bi.title
                                authors = authors or (bi and bi.authors)
                            end
                            title = title or (fp:match("([^/]+)%.[^.]+$") or fp)
                            table.insert(data.months[m], { fp = fp, title = title, authors = authors, date = d })
                            data.total = data.total + 1
                        end
                    end
                end
            end
        end
    end
    for m = 1, 12 do
        table.sort(data.months[m], function(a, b) return a.date > b.date end)
    end
    _cache[key] = data
    return data
end

-- ---------------------------------------------------------------------------
-- Label row
-- ---------------------------------------------------------------------------
function M.label_func()
    local y = shownYear()
    if currentOffset() == 0 then return _("Year in Books") end
    return string.format(_("%d in Books"), y)
end

function M.label_sub_func()
    local data = M.getYear(shownYear())
    local y = shownYear()
    local n = data.total
    if n == 1 then return string.format(_("%d · 1 book finished"), y) end
    return string.format(_("%d · %d books finished"), y, n)
end

function M.label_right_func() return "" end

local NAV_SPAN = 10000
function M.label_nav_func(ctx, screen)
    local off = currentOffset()
    return {
        mod_id        = M.id,
        page          = NAV_SPAN + off,
        npages        = NAV_SPAN,
        has_wallpaper = ctx and ctx.has_wallpaper,
        turnPageFn    = function(delta)
            local new = math.min(0, currentOffset() + delta)
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
local function availableHeight(ctx)
    local sw = ctx and ctx._screen_widget
    local content_h = (sw and sw._layout_content_h) or UI.getContentHeight()
    return content_h - S(112)
end

-- Geometry from the content: covers as wide as a month column (2:3),
-- one slice per extra book, plus the counts above and the month letters
-- below. Size setting: the cover size (%).
local function geometry(w, ctx, year)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local data = M.getYear(year)
    local maxn = 1
    for m = 1, 12 do maxn = math.max(maxn, #data.months[m]) end
    local col_w = w / 12
    local cw = math.floor((col_w - S(8)) * getHeightPct(pfx) / 100)
    local ch = math.floor(cw * 1.5)
    local slice = math.max(S(5), math.floor(ch * 0.2))
    local cap = math.floor(availableHeight(ctx) * 0.85)
    local function th(face)
        local tw = TextWidget:new{ text = "0", face = face }
        local hh = tw:getSize().h
        tw:free()
        return hh
    end
    -- same room as the widget: count + gap above, letter + dot + gaps below
    local num_h = th(Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_CAPTION)) + S(6)
    local let_h = th(Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)) + S(4) + S(4) + S(6)
    local stack = ch + (maxn - 1) * slice
    if num_h + stack + let_h > cap then
        -- a very busy month: thinner slices
        slice = math.max(2, math.floor((cap - num_h - let_h - ch) / math.max(1, maxn - 1)))
        stack = math.min(ch + (maxn - 1) * slice, cap - num_h - let_h)
    end
    return { cw = cw, ch = ch, slice = slice, h = num_h + stack + let_h }
end

local function moduleHeight(ctx, w)
    return geometry(w or Screen:getWidth() - S(40), ctx, shownYear()).h
end

-- Covers cropped to the column, kept for the session (a few hundred small
-- buffers at most).
local _covers = {}
local _ncovers = 0
local function coverBB(fp, w, h)
    local key = fp .. "|" .. w .. "x" .. h
    local bb = _covers[key]
    if bb ~= nil then return bb or nil end
    local ok, got = pcall(Config.getCroppedCoverBB, fp, w, h, "center")
    bb = ok and got or nil
    if bb then
        if _ncovers > 300 then _covers, _ncovers = {}, 0 end
        _covers[key] = bb
        _ncovers = _ncovers + 1
    elseif not Config.cover_extraction_pending then
        _covers[key] = false
    end
    return bb
end

local YearWidget = Widget:extend{ width = 0, height = 0 }

function YearWidget:getSize() return Geom:new{ w = self.width, h = self.height } end

function YearWidget:init()
    local w, h = self.width, self.height
    self.year = shownYear()
    self.data = M.getYear(self.year)
    local now = os.date("*t")
    self.cur_month = (self.year == now.year) and now.month or nil

    local let_face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)
    local let_bold  = Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_CAPTION)
    local num_face  = Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_CAPTION)

    self.letters, self.counts = {}, {}
    for m = 1, 12 do
        local future = self.cur_month and m > self.cur_month
        self.letters[m] = TextWidget:new{ text = LETTERS[m], face = m == self.cur_month and let_bold or let_face,
            fgcolor = future and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK }
        local n = #self.data.months[m]
        if n > 0 then
            self.counts[m] = TextWidget:new{ text = tostring(n), face = num_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
    end
    local let_h = self.letters[1]:getSize().h
    local probe = TextWidget:new{ text = "0", face = num_face }
    local num_h = probe:getSize().h
    probe:free()

    self.col_w = w / 12
    self.dot = S(4)
    self.base_y = h - let_h - self.dot - S(4) - S(6) -- the baseline (room below: letter, dot)
    self.let_h = let_h
    local top_room = num_h + S(4)
    local avail = self.base_y - top_room - S(2)
    self.num_h = num_h

    local g = geometry(w, { pfx = self.pfx, _screen_widget = self.screen_widget }, self.year)
    self.cw, self.ch, self.slice = g.cw, g.ch, g.slice
    self.avail = avail
end

function YearWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local col_w, cw, ch = self.col_w, self.cw, self.ch
    local covers = showCovers(self.pfx or "simpleui_hs_")
    local base = y + self.base_y
    -- baseline
    bb:paintRect(x, base, self.width, math.max(1, S(1)), Blitbuffer.COLOR_BLACK)
    self.cols = {}
    for m = 1, 12 do
        local cx = x + math.floor((m - 1) * col_w)
        local list = self.data.months[m]
        local n = #list
        local sx = cx + math.floor((col_w - cw) / 2)
        if n > 0 then
            local stack_h = math.min(self.avail, ch + (n - 1) * self.slice)
            local top = base - S(2) - stack_h
            -- older books first (bottom), as slices; then the latest on top
            for i = n, 1, -1 do
                local book = list[i]
                local by = top + (i == 1 and 0 or ch + (i - 2) * self.slice)
                local bh = i == 1 and ch or self.slice
                if by + bh > base - S(2) then bh = base - S(2) - by end
                if bh > 0 then
                    local cbb = covers and coverBB(book.fp, cw, ch)
                    if cbb then
                        -- a slice shows the middle band of its cover
                        local src_y = i == 1 and 0 or math.max(0, math.floor((ch - bh) / 2))
                        -- night mode inverts the whole screen: pre-invert the
                        -- cover so it shows in its real colours (like
                        -- KOReader's own cover images)
                        if Screen.night_mode then
                            bb:invertblitFrom(cbb, sx, by, 0, src_y, cw, bh)
                        else
                            bb:blitFrom(cbb, sx, by, 0, src_y, cw, bh)
                        end
                    else
                        local shades = { Blitbuffer.COLOR_GRAY_5, Blitbuffer.COLOR_GRAY_9, Blitbuffer.COLOR_GRAY_7 }
                        bb:paintRect(sx, by, cw, bh, shades[(i - 1) % 3 + 1])
                    end
                    if i ~= 1 then
                        bb:paintRect(sx, by, cw, 1, Blitbuffer.COLOR_WHITE)
                    end
                end
            end
            bb:paintBorder(sx, top, cw, stack_h, 1, Blitbuffer.COLOR_BLACK)
            local cnt = self.counts[m]
            local cs = cnt:getSize()
            cnt:paintTo(bb, cx + math.floor((col_w - cs.w) / 2), top - self.num_h - S(2))
            self.cols[m] = { x = cx, w = math.ceil(col_w) }
        end
        local lt = self.letters[m]
        local ls = lt:getSize()
        local ly = base + S(4)
        lt:paintTo(bb, cx + math.floor((col_w - ls.w) / 2), ly)
        if m == self.cur_month then
            local d = self.dot
            bb:paintRoundedRect(cx + math.floor((col_w - d) / 2), ly + self.let_h + S(1), d, d,
                Blitbuffer.COLOR_BLACK, math.floor(d / 2))
        end
    end
end

function YearWidget:monthAt(pos)
    if not (pos and self.dimen and self.cols) then return nil end
    local m = math.floor((pos.x - self.dimen.x) / self.col_w) + 1
    if m >= 1 and m <= 12 and self.cols[m] then return m end
end

function YearWidget:free()
    for _i, tw in ipairs(self.letters or {}) do tw:free() end
    for _m, tw in pairs(self.counts or {}) do tw:free() end
end

-- Changing a book's place in the chart (sidecar summary).
local function writeSummary(fp, fn)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds then return false end
    local ok, ds = pcall(DocSettings.open, DocSettings, fp)
    if not ok or not ds then return false end
    local summary = ds:readSetting("summary") or {}
    fn(summary)
    ds:saveSetting("summary", summary)
    pcall(ds.flush, ds)
    local SH = package.loaded["modules/module_books_shared"]
    if SH and SH.invalidateSidecarCache then pcall(SH.invalidateSidecarCache, fp) end
    local SP = package.loaded["modules/module_stats_provider"]
    if SP and SP.invalidate then pcall(SP.invalidate) end
    M.invalidateCache()
    return true
end

local function refreshHome()
    local HS = package.loaded["screens/sui_homescreen"]
    if HS and HS.refresh then pcall(HS.refresh, false) end
end

local showMonth

-- Options for one book of the list: open it, give it another finish date
-- (e.g. read long ago, marked Finished only now), or take it out of the
-- chart altogether. "Remove" sets KOReader/KoboUI's "Exclude from goals"
-- on the book, so it also stops counting toward the reading goal; it
-- stays marked Finished.
local function bookOptions(menu, year, month, b, open_fn)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function reopen()
        UIManager:close(menu)
        refreshHome()
        if #(M.getYear(year).months[month] or {}) > 0 then showMonth(year, month, open_fn) end
    end
    dialog = ButtonDialog:new{
        title = b.title,
        title_align = "center",
        buttons = {
            {{ text = _("Open book"), callback = function()
                UIManager:close(dialog)
                UIManager:close(menu)
                if open_fn then open_fn(b.fp) end
            end }},
            {{ text = _("Change finish date…"), callback = function()
                UIManager:close(dialog)
                local y, m, d = b.date:match("^(%d+)%-(%d+)%-(%d+)")
                local DateTimeWidget = require("ui/widget/datetimewidget")
                UIManager:show(DateTimeWidget:new{
                    year = tonumber(y) or year, month = tonumber(m) or month, day = tonumber(d) or 1,
                    ok_text = _("Set date"),
                    title_text = _("Finished on"),
                    callback = function(t)
                        local date = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
                        writeSummary(b.fp, function(sm) sm.date_finished = date end)
                        reopen()
                    end,
                })
            end }},
            {{ text = _("Remove from Year in Books"), callback = function()
                UIManager:close(dialog)
                writeSummary(b.fp, function(sm) sm.exclude_from_goals = true end)
                UI.Notify.toast(_("Removed. It stays marked Finished, and no longer counts toward your reading goal."))
                reopen()
            end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

-- List of the books finished in a month. Tap (or hold) one for its
-- options: open it, change its finish date, or remove it from the chart.
showMonth = function(year, month, open_fn)
    local data = M.getYear(year)
    local list = data.months[month] or {}
    if #list == 0 then return end
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    for _i, b in ipairs(list) do
        local day = tonumber(b.date:sub(9, 10))
        items[#items + 1] = {
            text = b.title .. ((b.authors and b.authors ~= "") and ("  —  " .. b.authors:gsub("\n.*", " et al.")) or ""),
            mandatory = day and string.format("%d %s", day, MONTHS[month]:sub(1, 3)) or nil,
            callback = function() bookOptions(menu, year, month, b, open_fn) end,
            book = b,
        }
    end
    menu = Menu:new{
        title = string.format(#list == 1 and _("%s %d · 1 book") or _("%s %d · %d books"), MONTHS[month], year, #list),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuHold = function(self, item)
            if item and item.book then bookOptions(self, year, month, item.book, open_fn) end
            return true
        end,
    }
    UIManager:show(menu)
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Year in Books"))
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local h = moduleHeight(ctx, w)
    local chart = YearWidget:new{ width = w, height = h, pfx = pfx, screen_widget = ctx and ctx._screen_widget }
    local open_fn = ctx and ctx.open_fn
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = chart,
    }
    tappable.ges_events = {
        TapYearBooks = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapYearBooks(_args, ges)
        local m = chart:monthAt(ges and ges.pos)
        if m then showMonth(chart.year, m, open_fn) end
        return true
    end
    return tappable
end

function M.getHeight(ctx)
    return moduleHeight(ctx, ctx and ctx.col_w)
end

function M.getMenuItems(ctx_menu)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._
    return {
        Config.makeStepperItem{
            text_func     = function() return _lc("Cover size") end,
            unit          = "%",
            get           = function() return getHeightPct(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_HEIGHT, v) end,
            title         = _lc("Cover size"),
            info          = _lc("Size of the covers, as a share of the month column. The chart grows with the busiest month."),
            value_min     = HEIGHT_MIN,
            value_max     = HEIGHT_MAX,
            value_step    = 10,
            default_value = HEIGHT_DEF,
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
        Config.makeLabelToggleItem("year_books", _("Year in Books"), ctx_menu.refresh, _lc),
    }
end

return M
