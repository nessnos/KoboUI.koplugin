-- module_calendar.lua — KoboUI
-- Home screen module: this month's reading calendar, filling a page.
--
-- A month grid (weeks × 7 days) like KOReader's Reading statistics →
-- Calendar view: each day shows its number, the books read that day as
-- grey bars with their titles (a book read several days in a row is one
-- bar spanning those days) and the time read that day. Today is
-- highlighted. Tap the calendar to open KOReader's full Calendar view.
--
-- Data: page_stat / book from the Reading statistics database.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local Screen         = Device.screen
local _              = require("infra/sui_i18n").translate

local Config      = require("infra/sui_config")
local UI          = require("infra/sui_core")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")

local M = {}

M.id          = "calendar"
M.name        = _("Reading Calendar")
M.label       = _("Reading Calendar")
M.enabled_key = "calendar_enabled"
M.default_on  = false

local SETTING_HEIGHT = "calendar_height_pct"
local HEIGHT_DEF, HEIGHT_MIN, HEIGHT_MAX = 100, 40, 100
local SETTING_TIME   = "calendar_show_time"

local function getHeightPct(pfx)
    local v = tonumber(SUISettings:readSetting(pfx .. SETTING_HEIGHT))
    if not v then return HEIGHT_DEF end
    return math.max(HEIGHT_MIN, math.min(HEIGHT_MAX, math.floor(v)))
end
-- KoboUI: books in colour on a colour screen (setting "Colours", default on)
local SETTING_COLOURS = "calendar_colours"
local function useColours(pfx)
    if SUISettings:readSetting((pfx or "simpleui_hs_") .. SETTING_COLOURS) == false then return false end
    local ok, A = pcall(require, "infra/kbo_accent")
    if not ok then return false end
    local okc, on = pcall(function() return Screen:isColorEnabled() end)
    return okc and on == true
end

local function showTime(pfx)
    return SUISettings:readSetting(pfx .. SETTING_TIME) ~= false
end

local MONTHS = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
                 _("July"), _("August"), _("September"), _("October"), _("November"), _("December") }
local WDAYS  = { _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat") }

-- Month shown, as an offset from the current month (0 = this month,
-- -1 = last month…). Back to the current month every time Home opens.
local _offset, _offset_gen = 0, nil
local function currentOffset()
    local ok, SE = pcall(require, "engines/sui_screen_engine")
    local gen = ok and SE and SE.open_generation or 0
    if gen ~= _offset_gen then _offset_gen = gen; _offset = 0 end
    return _offset
end

local function shownMonth()
    local t = os.date("*t")
    local d = os.date("*t", os.time{ year = t.year, month = t.month + currentOffset(), day = 1, hour = 12 })
    return d.year, d.month, (currentOffset() == 0) and t.day or nil
end

function M.label_func()
    local year, month = shownMonth()
    return MONTHS[month] .. " " .. year
end

-- No page indicator text between the chevrons (an empty string still
-- gives the label row its right-hand slot, where the chevrons go).
function M.label_right_func() return "" end

-- ‹ › on the label row: previous / next month. Next is greyed out on the
-- current month (no statistics for the future).
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

-- First day of the week (1 = Sunday, 2 = Monday). Module setting,
-- default Monday.
local SETTING_WEEKSTART = "calendar_week_start"
local function weekStartSetting(pfx)
    return SUISettings:readSetting((pfx or "simpleui_hs_") .. SETTING_WEEKSTART) == "sunday" and "sunday" or "monday"
end
local function weekStart(pfx)
    return weekStartSetting(pfx) == "sunday" and 1 or 2
end

-- ---------------------------------------------------------------------------
-- Data: { [day] = { total = seconds, books = { [id_book] = seconds } } },
-- titles = { [id_book] = title }. Cached per month, rebuilt once a day.
-- ---------------------------------------------------------------------------
local _cache = {}

function M.invalidateCache() _cache = {} end

local function loadMonth(year, month)
    local today = os.date("%Y-%m-%d")
    local key = string.format("%04d-%02d", year, month)
    local hit = _cache[key]
    if hit and hit.today == today then return hit end
    local data = { key = key, today = today, days = {}, titles = {} }
    local conn = Config.openStatsDB()
    if conn then
        local first = os.time{ year = year, month = month, day = 1, hour = 0 }
        local last  = os.time{ year = year, month = month + 1, day = 1, hour = 0 } - 1
        pcall(function()
            local stmt = conn:prepare(string.format([[
                SELECT CAST(strftime('%%d', start_time, 'unixepoch', 'localtime') AS INTEGER) AS d,
                       id_book, SUM(duration)
                FROM page_stat
                WHERE start_time BETWEEN %d AND %d
                GROUP BY d, id_book
            ]], first, last))
            local ids = {}
            for row in stmt:rows() do
                local d, id, dur = tonumber(row[1]), tonumber(row[2]), tonumber(row[3]) or 0
                if d and id then
                    local day = data.days[d] or { total = 0, books = {} }
                    day.books[id] = (day.books[id] or 0) + dur
                    day.total = day.total + dur
                    data.days[d] = day
                    ids[#ids + 1] = id
                end
            end
            stmt:close()
            if #ids > 0 then
                local st2 = conn:prepare("SELECT id, title FROM book WHERE id IN (" .. table.concat(ids, ",") .. ")")
                for row in st2:rows() do
                    data.titles[tonumber(row[1])] = tostring(row[2] or "")
                end
                st2:close()
            end
        end)
        pcall(conn.close, conn)
    end
    _cache[key] = data
    return data
end

local function fmtTime(sec)
    sec = math.floor(sec or 0)
    if sec < 60 then return nil end
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh%02d", h, m) end
    return string.format("%dm", m)
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
-- Height left for this module on its page: the page height minus room for
-- the section label, gaps and the page dots.
local function availableHeight(ctx)
    local sw = ctx and ctx._screen_widget
    local content_h = (sw and sw._layout_content_h) or UI.getContentHeight()
    return content_h - Screen:scaleBySize(112)
end

local function moduleHeight(ctx)
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    return math.max(Screen:scaleBySize(200), math.floor(availableHeight(ctx) * getHeightPct(pfx) / 100))
end

-- Bar shades per book, cycled (light → dark), with matching text colour.
local SHADES = {
    { bg = Blitbuffer.COLOR_GRAY_E, fg = Blitbuffer.COLOR_BLACK },
    { bg = Blitbuffer.COLOR_GRAY_B, fg = Blitbuffer.COLOR_BLACK },
    { bg = Blitbuffer.COLOR_GRAY_5, fg = Blitbuffer.COLOR_WHITE },
    { bg = Blitbuffer.COLOR_GRAY_9, fg = Blitbuffer.COLOR_BLACK },
}

-- KoboUI: one colour per book on colour screens — strong enough for a
-- Kaleido screen, each with a readable text colour.
local COLOURS = {
    { rgb = { 0xA8, 0x3A, 0x2C }, fg = Blitbuffer.COLOR_WHITE }, -- red
    { rgb = { 0x2F, 0x5D, 0x9A }, fg = Blitbuffer.COLOR_WHITE }, -- blue
    { rgb = { 0xE0, 0xB0, 0x30 }, fg = Blitbuffer.COLOR_BLACK }, -- yellow
    { rgb = { 0x2E, 0x7D, 0x4F }, fg = Blitbuffer.COLOR_WHITE }, -- green
    { rgb = { 0xD9, 0x7A, 0x2B }, fg = Blitbuffer.COLOR_BLACK }, -- orange
    { rgb = { 0x6E, 0x3E, 0x96 }, fg = Blitbuffer.COLOR_WHITE }, -- purple
    { rgb = { 0x2A, 0x8C, 0x8C }, fg = Blitbuffer.COLOR_WHITE }, -- teal
    { rgb = { 0xC2, 0x55, 0x7A }, fg = Blitbuffer.COLOR_WHITE }, -- pink
}
local function colourShades()
    local A = require("infra/kbo_accent")
    local out = {}
    local night = A.isNight and A.isNight()
    for i, c in ipairs(COLOURS) do
        -- the background is painted pre-inverted in dark mode (A.rgb), so
        -- the text is too, to keep its contrast
        local fg = c.fg
        if night then fg = (fg == Blitbuffer.COLOR_WHITE) and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE end
        out[i] = { bg = A.rgb(c.rgb[1], c.rgb[2], c.rgb[3]), fg = fg }
    end
    return out
end

local CalendarWidget = Widget:extend{ width = 0, height = 0 }

function CalendarWidget:getSize() return Geom:new{ w = self.width, h = self.height } end

function CalendarWidget:init()
    local w, h = self.width, self.height
    local year, month, today = shownMonth()
    local data = loadMonth(year, month)
    local ws = weekStart(self.pfx)
    local first_wday = os.date("*t", os.time{ year = year, month = month, day = 1, hour = 12 }).wday
    local ndays = os.date("*t", os.time{ year = year, month = month + 1, day = 0, hour = 12 }).day
    local lead = (first_wday - ws) % 7
    local nweeks = math.ceil((lead + ndays) / 7)

    local head_face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)
    local num_face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)
    local num_bold  = Font:getFace(SUIStyle.FACE_BOLD or SUIStyle.FACE_REGULAR, SUIStyle.FS_CAPTION)
    local bar_face  = Font:getFace(SUIStyle.FACE_REGULAR, math.max(9, SUIStyle.FS_CAPTION - 2))
    local time_face = Font:getFace(SUIStyle.FACE_REGULAR, math.max(8, SUIStyle.FS_CAPTION - 3))

    local head = TextWidget:new{ text = "Wed", face = head_face }
    local head_h = head:getSize().h + Screen:scaleBySize(4)
    head:free()
    self.head_h = head_h
    self.col_w = w / 7
    self.row_h = math.floor((h - head_h) / nweeks)
    self.nweeks, self.lead, self.ndays, self.today = nweeks, lead, ndays, today
    self.ws = ws

    -- Weekday header labels.
    self.heads = {}
    for i = 0, 6 do
        local wd = (ws - 1 + i) % 7 + 1
        self.heads[i + 1] = TextWidget:new{ text = WDAYS[wd], face = head_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = math.floor(self.col_w) - 4 }
    end
    -- Day numbers.
    self.nums = {}
    for d = 1, ndays do
        self.nums[d] = TextWidget:new{ text = tostring(d), face = d == today and num_bold or num_face,
            fgcolor = d == today and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK }
    end
    local num_h = self.nums[1]:getSize().h
    self.num_h = num_h

    -- Day totals.
    self.times = {}
    if showTime(self.pfx) then
        for d = 1, ndays do
            local s = data.days[d] and fmtTime(data.days[d].total)
            if s then
                self.times[d] = TextWidget:new{ text = s, face = time_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
            end
        end
    end

    -- Book bars: per week, consecutive days of one book become one bar;
    -- bars are stacked in lanes under the day number.
    local probe = TextWidget:new{ text = "Xg", face = bar_face }
    local lane_h = probe:getSize().h + Screen:scaleBySize(2)
    probe:free()
    local time_h = 0
    for _d, tw in pairs(self.times) do time_h = tw:getSize().h break end
    local max_lanes = math.max(0, math.floor((self.row_h - num_h - time_h - Screen:scaleBySize(6)) / lane_h))
    self.lane_h, self.max_lanes = lane_h, max_lanes

    local shade_of, next_shade = {}, 1
    local PALETTE = useColours(self.pfx) and colourShades() or SHADES
    self.bars = {}
    for wk = 0, nweeks - 1 do
        local spans = {} -- id -> list of {c0, c1}
        local order = {}
        for col = 0, 6 do
            local d = wk * 7 + col - lead + 1
            local day = d >= 1 and d <= ndays and data.days[d]
            if day then
                for id, _sec in pairs(day.books) do
                    local list = spans[id]
                    if not list then list = {}; spans[id] = list; order[#order + 1] = id end
                    local last = list[#list]
                    if last and last[2] == col - 1 then last[2] = col else list[#list + 1] = { col, col } end
                end
            end
        end
        local items = {}
        for _i, id in ipairs(order) do
            for _j, sp in ipairs(spans[id]) do items[#items + 1] = { id = id, c0 = sp[1], c1 = sp[2] } end
        end
        table.sort(items, function(a, b)
            if a.c0 ~= b.c0 then return a.c0 < b.c0 end
            return (a.c1 - a.c0) > (b.c1 - b.c0)
        end)
        local lanes = {}
        local overflow = {}
        for _i, it in ipairs(items) do
            local placed
            for l = 1, max_lanes do
                local busy = false
                for _k, o in ipairs(lanes[l] or {}) do
                    if not (it.c1 < o.c0 or it.c0 > o.c1) then busy = true break end
                end
                if not busy then
                    lanes[l] = lanes[l] or {}
                    table.insert(lanes[l], it)
                    placed = l
                    break
                end
            end
            if placed then
                if not shade_of[it.id] then
                    shade_of[it.id] = PALETTE[(next_shade - 1) % #PALETTE + 1]
                    next_shade = next_shade + 1
                end
                local shade = shade_of[it.id]
                local bw = math.floor((it.c1 - it.c0 + 1) * self.col_w) - Screen:scaleBySize(4)
                local title = data.titles[it.id] or "?"
                local text = TextWidget:new{ text = title, face = bar_face, fgcolor = shade.fg,
                    max_width = math.max(8, bw - Screen:scaleBySize(4)), truncate_with_ellipsis = true }
                self.bars[#self.bars + 1] = { wk = wk, c0 = it.c0, lane = placed, w = bw,
                    bg = shade.bg, text = text }
            else
                for c = it.c0, it.c1 do overflow[c] = (overflow[c] or 0) + 1 end
            end
        end
        -- "+n" when a day has more books than fit.
        for c, n in pairs(overflow) do
            self.bars[#self.bars + 1] = { wk = wk, c0 = c, more = TextWidget:new{
                text = "+" .. n, face = time_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY } }
        end
    end
end

function CalendarWidget:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local col_w, row_h, head_h = self.col_w, self.row_h, self.head_h
    local pad = Screen:scaleBySize(3)
    local line = math.max(1, Screen:scaleBySize(1))
    -- Weekday header.
    for i = 1, 7 do
        local tw = self.heads[i]
        local sz = tw:getSize()
        tw:paintTo(bb, x + math.floor((i - 1) * col_w + (col_w - sz.w) / 2), y)
    end
    local gy = y + head_h
    -- Grid lines.
    for r = 0, self.nweeks do
        bb:paintRect(x, gy + r * row_h, self.width, line, Blitbuffer.COLOR_GRAY_9)
    end
    for c = 0, 7 do
        local cx = x + math.floor(c * col_w)
        if c == 7 then cx = x + self.width - line end
        bb:paintRect(cx, gy, line, self.nweeks * row_h, Blitbuffer.COLOR_GRAY_9)
    end
    -- Days.
    for wk = 0, self.nweeks - 1 do
        for col = 0, 6 do
            local d = wk * 7 + col - self.lead + 1
            local cx = x + math.floor(col * col_w)
            local cy = gy + wk * row_h
            if d < 1 or d > self.ndays then
                bb:paintRect(cx + line, cy + line, math.floor(col_w) - line, row_h - line, Blitbuffer.COLOR_GRAY_E)
            else
                local tw = self.nums[d]
                local sz = tw:getSize()
                if d == self.today then
                    local r = math.max(sz.w, sz.h) + Screen:scaleBySize(2)
                    bb:paintRoundedRect(cx + pad, cy + pad, r, sz.h, Blitbuffer.COLOR_BLACK, math.floor(sz.h / 2))
                    tw:paintTo(bb, cx + pad + math.floor((r - sz.w) / 2), cy + pad)
                else
                    tw:paintTo(bb, cx + pad, cy + pad)
                end
                local tt = self.times[d]
                if tt then
                    local ts = tt:getSize()
                    tt:paintTo(bb, cx + math.floor(col_w) - ts.w - pad, cy + row_h - ts.h - pad)
                end
            end
        end
    end
    -- Book bars.
    for _i, b in ipairs(self.bars) do
        local cx = x + math.floor(b.c0 * col_w)
        local cy = gy + b.wk * row_h + pad + self.num_h + Screen:scaleBySize(2)
        if b.more then
            local ms = b.more:getSize()
            b.more:paintTo(bb, cx + math.floor(col_w) - ms.w - pad, gy + b.wk * row_h + pad)
        else
            local by = cy + (b.lane - 1) * self.lane_h
            local bh = self.lane_h - Screen:scaleBySize(2)
            require("infra/kbo_accent").rect(bb, cx + Screen:scaleBySize(2), by, b.w, bh, b.bg)
            local ts = b.text:getSize()
            b.text:paintTo(bb, cx + Screen:scaleBySize(4), by + math.floor((bh - ts.h) / 2))
        end
    end
end

function CalendarWidget:free()
    for _i, tw in ipairs(self.heads or {}) do tw:free() end
    for _d, tw in pairs(self.nums or {}) do tw:free() end
    for _d, tw in pairs(self.times or {}) do tw:free() end
    for _i, b in ipairs(self.bars or {}) do
        if b.text then b.text:free() end
        if b.more then b.more:free() end
    end
end

local function openCalendarView()
    local ok, QA = pcall(require, "features/sui_quickactions")
    if ok and QA and QA.execute then
        pcall(QA.execute, "stats_calendar", { plugin = UI.getLivePlugin and UI.getLivePlugin() })
    end
end

function M.build(w, ctx)
    Config.applyLabelToggle(M, _("Reading Calendar"))
    local pfx = (ctx and ctx.pfx) or "simpleui_hs_"
    local h = moduleHeight(ctx)
    local cal = CalendarWidget:new{ width = w, height = h, pfx = pfx }
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
        [1]   = cal,
    }
    tappable.ges_events = {
        TapCalendar = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    function tappable:onTapCalendar()
        openCalendarView()
        return true
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
        Config.makeStepperItem{
            text_func     = function() return _lc("Height") end,
            unit          = "%",
            get           = function() return getHeightPct(pfx) end,
            set           = function(v) SUISettings:saveSetting(pfx .. SETTING_HEIGHT, v) end,
            title         = _lc("Height"),
            info          = _lc("Share of the page the calendar takes. 100% fills the page, so put the calendar on a page of its own."),
            value_min     = HEIGHT_MIN,
            value_max     = HEIGHT_MAX,
            value_step    = 5,
            default_value = HEIGHT_DEF,
            refresh       = ctx_menu.refresh,
        },
        {
            text = _lc("Week starts on"),
            sub_item_table = {
                {
                    text = _lc("Monday"), radio = true, keep_menu_open = true,
                    checked_func = function() return weekStartSetting(pfx) == "monday" end,
                    callback = function() SUISettings:saveSetting(pfx .. SETTING_WEEKSTART, "monday"); ctx_menu.refresh() end,
                },
                {
                    text = _lc("Sunday"), radio = true, keep_menu_open = true,
                    checked_func = function() return weekStartSetting(pfx) == "sunday" end,
                    callback = function() SUISettings:saveSetting(pfx .. SETTING_WEEKSTART, "sunday"); ctx_menu.refresh() end,
                },
            },
        },
        {
            text           = _lc("Colours"),
            help_text      = _lc("On a colour screen, each book gets its own colour instead of a shade of grey."),
            checked_func   = function() return SUISettings:readSetting(pfx .. SETTING_COLOURS) ~= false end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_COLOURS, SUISettings:readSetting(pfx .. SETTING_COLOURS) == false)
                ctx_menu.refresh()
            end,
        },
        {
            text           = _lc("Show reading time per day"),
            checked_func   = function() return showTime(pfx) end,
            keep_menu_open = true,
            callback       = function()
                SUISettings:saveSetting(pfx .. SETTING_TIME, not showTime(pfx))
                ctx_menu.refresh()
            end,
        },
        Config.makeLabelToggleItem("calendar", _("Reading Calendar"), ctx_menu.refresh, _lc),
    }
end

return M
