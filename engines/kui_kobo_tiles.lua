--[[--
kui_kobo_tiles.lua — KoboUI

Kobo-style "shelf" tiles for the home screen, as on Kobo's home page
("My Books — 219 BOOKS", "Sarah J. Maas — 13 UNREAD BOOKS"):

    ┌────────┐┌─────┐┌───┐
    │        ││     ││   │   ← up to three covers, the first one big, the
    │ front  ││ 2nd ││3rd│     next ones a bit smaller and tucked behind it,
    │        ││     ││   │     all standing on the same baseline
    └────────┘└─────┘└───┘
    Sarah J. Maas            ← name (serif, like Kobo)
    13 UNREAD BOOKS          ← count (small caps, grey)

The tiles are picked automatically (see "Automatic choice" below).
A tile stands for a SOURCE — a collection, the whole library, an author or
a series. Tapping it opens that collection / library / author / series.
Used by modules/module_kobo_coll.lua and modules/module_kobo_meta.lua.

A source is a table:
    { kind = "collection" | "library" | "author" | "series", value = string }
and is stored in settings as the string  kind .. "\31" .. value.
--]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")

local _           = require("infra/sui_i18n").translate
local N_          = require("infra/sui_i18n").ngettext
local Config      = require("infra/sui_config")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local UI          = require("infra/sui_core")

local M = {}

M.SEP = "\31"
M.MAX_SOURCES = 6

-- Shape of a tile, in multiples of the front cover's height H.
local FRONT_W  = 2 / 3     -- front cover width
local BACK1_H  = 0.90      -- 2nd cover height
local BACK2_H  = 0.80      -- 3rd cover height
local VIS1     = 0.43      -- visible width of the 2nd cover (rest is behind the front one)
local VIS2     = 0.37      -- visible width of the 3rd cover
local TILE_W   = FRONT_W + VIS1 + VIS2   -- ≈ 1.47 H

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

function M.encode(kind, value) return kind .. M.SEP .. (value or "") end

function M.decode(s)
    if type(s) ~= "string" then return nil end
    local kind, value = s:match("^([^\31]+)\31(.*)$")
    if not kind then return nil end
    return { kind = kind, value = value }
end

local function homeDir()
    local d = G_reader_settings:readSetting("home_dir")
    if not d or d == "" then
        local ok, Device = pcall(require, "device")
        d = ok and Device.home_dir or nil
    end
    if d then d = d:gsub("/+$", "") end
    return d
end
M.homeDir = homeDir

local function fileExists(fp)
    return fp and lfs.attributes(fp, "mode") == "file"
end

local function bookStatus(fp)
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not ok or not BookList or not BookList.getBookStatus then return "new" end
    local ok2, st = pcall(BookList.getBookStatus, fp)
    return ok2 and st or "new"
end

local function isUnread(fp) return bookStatus(fp) ~= "complete" end

-- Rows of the SimpleUI metadata index (author/series browsing) for a filter.
local function metaRows(kind, value)
    local bim = Config.getBookInfoManager()
    local base = homeDir()
    if not bim or not base then return {} end
    local ok_fs, FilterState = pcall(require, "features/library/sui_filter_state")
    local ok_ms, MetadataSource = pcall(require, "features/library/sui_metadata_source")
    if not (ok_fs and ok_ms) then return {} end
    local fs = FilterState.new(base)
    if kind == "author" or kind == "series" then
        FilterState.addFilter(fs, kind, value)
    end
    local ok, rows = pcall(MetadataSource.getMatchingFiles, bim, base, fs, { recursive = true })
    if not ok or type(rows) ~= "table" then return {} end
    if kind == "author" or kind == "series" then
        pcall(MetadataSource.sortFiles, rows, kind)
    end
    return rows
end

--- Books of a source, in display order (existing files only).
function M.sourceFiles(src)
    if not src then return {} end
    if src.kind == "collection" then
        local GridRenderer = require("engines/sui_book_grid")
        return GridRenderer.getCollectionFileList(src.value)
    end
    local files, seen = {}, {}
    if src.kind == "library" then
        -- Recently read books first, like Kobo's "My Books" tile.
        local ok_rh, RH = pcall(require, "readhistory")
        local base = homeDir()
        if ok_rh and RH and RH.hist then
            for _i, e in ipairs(RH.hist) do
                local fp = e.file
                if fp and not seen[fp] and (not base or fp:sub(1, #base) == base) and fileExists(fp) then
                    seen[fp] = true
                    files[#files + 1] = fp
                end
            end
        end
    end
    for _i, row in ipairs(metaRows(src.kind, src.value)) do
        local fp = row[1]
        if fp and not seen[fp] and fileExists(fp) then
            seen[fp] = true
            files[#files + 1] = fp
        end
    end
    return files
end

--- Display name of a source.
function M.sourceName(src)
    if not src then return "?" end
    if src.kind == "library" then return _("My Books") end
    if src.kind == "author" and type(src.value) == "string" then
        local ok_an, AN = pcall(require, "features/library/kui_author_names")
        if ok_an and AN then return AN.displayName(src.value) end
    end
    if src.kind == "collection" then
        local TBR = package.loaded["modules/module_tbr"]
        if TBR and TBR.TBR_COLL_NAME == src.value and TBR.getDisplayName then
            return TBR.getDisplayName()
        end
        local ok_rc, RC = pcall(require, "readcollection")
        if ok_rc and RC and RC.default_collection_name == src.value then
            return _("Favorites")
        end
    end
    return src.value or "?"
end

--- Authors or series known to the metadata index: { {value, count}, ... }.
function M.listMetaValues(kind)
    local bim = Config.getBookInfoManager()
    local base = homeDir()
    if not bim or not base then return {} end
    local ok_fs, FilterState = pcall(require, "features/library/sui_filter_state")
    local ok_ms, MetadataSource = pcall(require, "features/library/sui_metadata_source")
    if not (ok_fs and ok_ms) then return {} end
    local ok, vals = pcall(MetadataSource.getFacetValues, bim, base, kind, FilterState.new(base), { recursive = true })
    if not ok or type(vals) ~= "table" then return {} end
    local out = {}
    for _i, v in ipairs(vals) do
        if type(v[1]) == "string" and v[1] ~= "" then out[#out + 1] = { v[1], v[2] } end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Opening a source
-- ---------------------------------------------------------------------------

local function liveFM()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

local function showBookList(title, files, ctx)
    local Menu = require("ui/widget/menu")
    local GridRenderer = require("engines/sui_book_grid")
    local menu
    local items = {}
    for _i, fp in ipairs(files) do
        local _fp = fp
        items[#items + 1] = {
            text = GridRenderer.getBookTitle(fp),
            callback = function()
                UIManager:close(menu)
                if ctx and ctx.open_fn then ctx.open_fn(_fp)
                else require("apps/reader/readerui"):showReader(_fp) end
            end,
        }
    end
    menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    }
    UIManager:show(menu)
end

-- Closes full-screen views (Collections, History, …) left open between the
-- library and the home screen, so the library is what shows up afterwards.
local function closeViewsAboveLibrary()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w.name ~= "homescreen" and w.name ~= "filemanager"
                and w.covers_fullscreen then
            local FM = package.loaded["apps/filemanager/filemanager"]
            if FM and FM.instance == w then break end
            if type(w.onClose) == "function" then
                pcall(w.onClose, w)
            else
                UIManager:close(w)
            end
        end
    end
end

local function markLibraryTab()
    pcall(function()
        local plugin = UI.getLivePlugin()
        local Bottombar = require("screens/sui_bottombar")
        if plugin and Bottombar.setActiveAndRefreshFM then
            Bottombar.setActiveAndRefreshFM(plugin, "home", Config.loadTabConfig())
        end
    end)
end

--- Opens what a tile stands for.
function M.openSource(src, ctx)
    if not src then return end
    if src.kind == "collection" then
        local ok, Coll = pcall(require, "modules/module_collections")
        if ok and Coll and Coll.openCollection then
            Coll.openCollection(src.value)
        end
        return
    end

    closeViewsAboveLibrary()
    local fm = liveFM()
    local fc = fm and fm.file_chooser
    local base = homeDir()

    if src.kind == "library" then
        if fc and base then
            fm._navbar_suppress_path_change = true
            pcall(function() fc:changeToPath(base) end)
            fm._navbar_suppress_path_change = nil
            pcall(function() fm:updateTitleBarPath(base) end)
        end
        if ctx and ctx.close_fn then ctx.close_fn() end
        markLibraryTab()
        return
    end

    -- Author / series: open SimpleUI's author/series view of the library,
    -- or a plain list of the books when that feature is switched off.
    local ok_bm, BM = pcall(require, "features/library/sui_library_browse")
    if fc and base and ok_bm and BM and BM.isEnabled and BM.isEnabled() then
        local VP = require("features/library/sui_virtual_path")
        local target = VP.buildLeaf(base, nil, src.kind, src.value)
        fc._sui_author_dialog_origin = nil
        fc._browse_by_meta_entry_path = VP.buildDimList(base, nil, src.kind)
        fm._navbar_suppress_path_change = true
        local ok_c, err = pcall(function() fc:changeToPath(target) end)
        fm._navbar_suppress_path_change = nil
        if ok_c then
            pcall(function() fm:updateTitleBarPath(target) end)
            pcall(function() fc:onGotoPage(1) end)
            pcall(BM.setSavedMode, src.kind)
            if ctx and ctx.close_fn then ctx.close_fn() end
            markLibraryTab()
            return
        end
        logger.warn("kindleui: kobo tile: could not open", src.kind, src.value, err)
    end
    showBookList(M.sourceName(src), M.sourceFiles(src), ctx)
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local titleFace -- defined below

local _text_h_cache = {}
local function textHeight(face_fn, fs, key)
    local k = key .. ":" .. fs
    if not _text_h_cache[k] then
        local tw = TextWidget:new{ text = "Ag", face = face_fn(fs) }
        _text_h_cache[k] = tw:getSize().h
        tw:free()
    end
    return _text_h_cache[k]
end

--- Geometry for a module `w` wide showing `per_row` tiles per row.
function M.dims(w, per_row, scale, lf, serif)
    lf = lf or 1
    scale = scale or 1
    local pad    = UI.PAD
    local gap    = Screen:scaleBySize(20)
    local inner  = math.max(1, w - pad * 2)
    local tile_w = math.floor((inner - gap * (per_row - 1)) / per_row)
    local H      = math.floor(tile_w / TILE_W * math.min(1, scale))
    -- Keep very wide single tiles from getting absurdly tall.
    H = math.min(H, math.floor(Screen:getHeight() * 0.32 * lf))
    local title_fs = math.max(10, math.floor(SUIStyle.FS_SUBTITLE * lf * math.max(0.8, math.min(1, scale + 0.1))))
    local sub_fs   = math.max(8,  math.floor(SUIStyle.FS_CAPTION * lf * 1.05))
    local text_gap = Screen:scaleBySize(10)
    local sub_gap  = Screen:scaleBySize(2)
    local title_h = textHeight(function(fs) return titleFace(fs, serif ~= false) end, title_fs,
        serif ~= false and "serif" or "sans")
    local sub_h   = textHeight(function(fs) return Font:getFace(SUIStyle.FACE_REGULAR, fs) end, sub_fs, "sub")
    local tile_h  = H + text_gap + title_h + sub_gap + sub_h
    return {
        pad = pad, gap = gap, row_gap = Screen:scaleBySize(26),
        tile_w = tile_w, H = H, tile_h = tile_h,
        title_fs = title_fs, sub_fs = sub_fs,
        text_gap = text_gap, sub_gap = sub_gap,
        title_h = title_h, sub_h = sub_h,
    }
end

function M.totalHeight(d, n_tiles, per_row)
    if n_tiles <= 0 then return Screen:scaleBySize(60) end
    local rows = math.ceil(n_tiles / per_row)
    return rows * d.tile_h + (rows - 1) * d.row_gap
end

titleFace = function(fs, serif)
    if serif then
        local ok, face = pcall(Font.getFace, Font, "NotoSerif-Regular.ttf", fs)
        if ok and face then return face end
    end
    return Font:getFace(SUIStyle.FACE_REGULAR, fs)
end

-- A bordered cover box. Returns the frame and whether a real image is in it.
local function coverBox(fp, w, h)
    local border = math.max(1, Screen:scaleBySize(1))
    local bb = fp and Config.getStretchedCoverBB(fp, w, h)
    local inner
    if bb then
        local ok, img = pcall(function()
            return ImageWidget:new{
                image = bb, image_disposable = false,
                width = w - border * 2, height = h - border * 2,
            }
        end)
        if ok then inner = img end
    end
    local frame = FrameContainer:new{
        bordersize = border,
        color      = Blitbuffer.COLOR_DARK_GRAY,
        background = inner and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_LIGHT_GRAY,
        padding    = 0, margin = 0,
        dimen      = Geom:new{ w = w, h = h },
        inner or VerticalSpan:new{ width = h - border * 2 },
    }
    frame._kui_border = border
    return frame, inner ~= nil
end

--- Builds the stacked-covers part of a tile. Returns widget, cover_slots.
local function buildStack(files, d)
    local H = d.H
    local specs = {
        { h = H,                          w = math.floor(H * FRONT_W) },
        { h = math.floor(H * BACK1_H),    w = math.floor(H * BACK1_H * FRONT_W) },
        { h = math.floor(H * BACK2_H),    w = math.floor(H * BACK2_H * FRONT_W) },
    }
    local x1 = specs[1].w
    local x2 = x1 + math.floor(H * VIS1)
    local xs = { 0, x1 + math.floor(H * VIS1) - specs[2].w, x2 + math.floor(H * VIS2) - specs[3].w }

    local og = OverlapGroup:new{ dimen = Geom:new{ w = d.tile_w, h = H } }
    local slots = {}
    local n = math.min(3, #files)
    -- Paint back to front: the 3rd cover first, the front cover last.
    for i = n, 1, -1 do
        local s = specs[i]
        local frame, has_img = coverBox(files[i], s.w, s.h)
        frame.overlap_offset = { xs[i], H - s.h }
        og[#og + 1] = frame
        if not has_img and not Config.isCoverMissing(files[i]) then
            slots[#slots + 1] = { frame = frame, fp = files[i], w = s.w, h = s.h }
        end
    end
    if n == 0 then
        local frame = coverBox(nil, specs[1].w, specs[1].h)
        frame.overlap_offset = { 0, 0 }
        og[#og + 1] = frame
    end
    return og, slots
end

--- One tile: stack + name + count, tappable. Returns widget, cover_slots.
function M.buildTile(src, d, ctx, opts)
    opts = opts or {}
    local files = M.sourceFiles(src)
    local shown = files
    local count, unread = #files, nil
    if opts.count_mode == "unread" then
        unread = {}
        for _i, fp in ipairs(files) do
            if isUnread(fp) then unread[#unread + 1] = fp end
        end
        -- Kobo shows the unread books on the tile.
        if #unread > 0 then shown = unread end
    end

    local stack, slots = buildStack(shown, d)

    local sub_text
    if unread and #unread > 0 then
        sub_text = string.format(N_("%d unread book", "%d unread books", #unread), #unread)
    else
        sub_text = string.format(N_("%d book", "%d books", count), count)
    end
    sub_text = sub_text:upper()

    local title_w = TextWidget:new{
        text = M.sourceName(src),
        face = titleFace(d.title_fs, opts.serif ~= false),
        fgcolor = SUIStyle.COLOR.text_primary,
        max_width = d.tile_w,
        truncate_with_ellipsis = true,
    }
    local sub_w = TextWidget:new{
        text = sub_text,
        face = require("infra/kbo_fonts").face(d.sub_fs),  -- KoboUI: sans-serif count
        fgcolor = UI.CLR_TEXT_SUB or Blitbuffer.COLOR_DARK_GRAY,
        max_width = d.tile_w,
        truncate_with_ellipsis = true,
    }

    local vg = VerticalGroup:new{
        align = "left",
        stack,
        VerticalSpan:new{ width = d.text_gap },
        title_w,
        VerticalSpan:new{ width = d.sub_gap },
        sub_w,
    }

    local tile = InputContainer:new{
        dimen = Geom:new{ w = d.tile_w, h = d.tile_h },
        vg,
    }
    tile.ges_events = {
        TapKoboTile = {
            GestureRange:new{ ges = "tap", range = function() return tile.dimen end },
        },
    }
    function tile:onTapKoboTile()
        M.openSource(src, ctx)
        return true
    end
    return tile, slots
end

--- The whole module body: tiles in rows. Returns widget (with ._cover_slots).
function M.build(w, ctx, sources, opts)
    opts = opts or {}
    local per_row = opts.per_row or 2
    local d = M.dims(w, per_row, opts.scale, ctx and ctx.landscape_factor, opts.serif)
    local body = VerticalGroup:new{ align = "left" }
    local all_slots = {}
    local row
    for i, src in ipairs(sources) do
        if (i - 1) % per_row == 0 then
            if row then
                body[#body + 1] = row
                body[#body + 1] = VerticalSpan:new{ width = d.row_gap }
            end
            row = HorizontalGroup:new{ align = "top", HorizontalSpan:new{ width = d.pad } }
        else
            row[#row + 1] = HorizontalSpan:new{ width = d.gap }
        end
        local ok, tile, slots = pcall(M.buildTile, src, d, ctx, opts)
        if ok and tile then
            row[#row + 1] = tile
            for _i, s in ipairs(slots or {}) do all_slots[#all_slots + 1] = s end
        else
            logger.warn("kindleui: kobo tile failed:", tostring(tile))
            row[#row + 1] = HorizontalSpan:new{ width = d.tile_w }
        end
    end
    if row then body[#body + 1] = row end
    local frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        dimen = Geom:new{ w = w, h = M.totalHeight(d, #sources, per_row) },
        body,
    }
    frame._cover_slots = all_slots
    return frame
end

--- Fills in covers that weren't extracted yet. true = nothing left to do.
function M.updateCovers(widget)
    if not widget or not widget._cover_slots then return true end
    local all_done = true
    local left = {}
    for _i, slot in ipairs(widget._cover_slots) do
        local bb = Config.getStretchedCoverBB(slot.fp, slot.w, slot.h)
        if bb then
            local b = slot.frame._kui_border or 1
            local ok, img = pcall(function()
                return ImageWidget:new{
                    image = bb, image_disposable = false,
                    width = slot.w - b * 2, height = slot.h - b * 2,
                }
            end)
            if ok and img then
                slot.frame[1] = img
                slot.frame.background = Blitbuffer.COLOR_WHITE
            end
        elseif not Config.isCoverMissing(slot.fp) then
            all_done = false
            left[#left + 1] = slot
        end
    end
    widget._cover_slots = left
    return all_done
end

--- A centred note used when a module has nothing to show yet.
function M.placeholder(w, text)
    local h = Screen:scaleBySize(60)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        TextWidget:new{
            text = text,
            face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY),
            fgcolor = UI.CLR_TEXT_SUB or Blitbuffer.COLOR_DARK_GRAY,
            max_width = w - UI.PAD * 2,
        },
    }
end


-- ---------------------------------------------------------------------------
-- Automatic choice of the tiles
--
-- Each module shuffles through a POOL of sources (every collection of the
-- library, or every author / series) and shows `count` of them. The pick is
-- saved with a key describing when it was made, so the tiles stay the same
-- until the next reshuffle:
--   "open"  → each time the Home screen (or a custom screen) is opened
--   "hour"  → once an hour
--   "day"   → once a day
-- ---------------------------------------------------------------------------

local _session = tostring(os.time())
local _seeded = false

local function periodKey(mode)
    if mode == "hour" then return os.date("%Y%m%d%H") end
    if mode == "day" then return os.date("%Y%m%d") end
    local SE = package.loaded["engines/sui_screen_engine"]
    return _session .. ":" .. tostring(SE and SE.open_generation or 0)
end

local function setting(pfx, inst_id, suffix)
    return SUISettings:readSetting(pfx .. inst_id .. suffix)
end

local function save(pfx, inst_id, suffix, v)
    SUISettings:saveSetting(pfx .. inst_id .. suffix, v)
end

function M.getTileCount(pfx, inst_id)
    local n = tonumber(setting(pfx, inst_id, "_kobo_n"))
    if n and n >= 1 and n <= M.MAX_SOURCES then return math.floor(n) end
    return M.getPerRow(pfx, inst_id)
end

function M.reshuffleMode(pfx, inst_id)
    local m = setting(pfx, inst_id, "_kobo_shuffle")
    if m == "hour" or m == "day" then return m end
    return "open"
end

--- Picks the sources to show. spec.pool(pfx) → { src, ... };
--- spec.pool_sig(pfx) → string that changes when the pool's options change.
function M.pickSources(pfx, inst_id, spec)
    local mode  = M.reshuffleMode(pfx, inst_id)
    local count = spec.count or M.getTileCount(pfx, inst_id)
    local key   = table.concat({ mode, periodKey(mode), count, spec.pool_sig and spec.pool_sig(pfx) or "" }, "|")
    local saved = setting(pfx, inst_id, "_kobo_pick")
    if type(saved) == "table" and saved.key == key and type(saved.list) == "table" then
        local out = {}
        for _i, s in ipairs(saved.list) do
            local src = M.decode(s)
            if src then out[#out + 1] = src end
        end
        return out
    end
    if not _seeded then
        math.randomseed(os.time() + math.floor((os.clock() * 1000) % 1000))
        _seeded = true
    end
    local ok, pool = pcall(spec.pool, pfx)
    if not ok or type(pool) ~= "table" then
        logger.warn("kindleui: kobo shelf pool failed:", tostring(pool))
        pool = {}
    end
    -- Don't show the same tiles twice in a row when there are others.
    local last = {}
    if type(saved) == "table" and type(saved.list) == "table" and #pool > count then
        for _i, s in ipairs(saved.list) do last[s] = true end
    end
    local fresh, stale = {}, {}
    for _i, src in ipairs(pool) do
        local k = M.encode(src.kind, src.value)
        if last[k] then stale[#stale + 1] = k else fresh[#fresh + 1] = k end
    end
    local function shuffle(t)
        for i = #t, 2, -1 do
            local j = math.random(i)
            t[i], t[j] = t[j], t[i]
        end
    end
    shuffle(fresh); shuffle(stale)
    local list = {}
    for _i, k in ipairs(fresh) do if #list < count then list[#list + 1] = k end end
    for _i, k in ipairs(stale) do if #list < count then list[#list + 1] = k end end
    -- "My Books" always leads when it was picked, like on a Kobo.
    for i, k in ipairs(list) do
        if k == M.encode("library", "") and i > 1 then
            table.remove(list, i); table.insert(list, 1, k); break
        end
    end
    save(pfx, inst_id, "_kobo_pick", { key = key, list = list })
    local out = {}
    for _i, k in ipairs(list) do out[#out + 1] = M.decode(k) end
    return out
end

--- Forces a new pick on the next build.
function M.reshuffle(pfx, inst_id)
    -- Keep the list so the new pick avoids the tiles shown now.
    local saved = setting(pfx, inst_id, "_kobo_pick")
    save(pfx, inst_id, "_kobo_pick", { key = "", list = type(saved) == "table" and saved.list or {} })
end

--- Short description of what a shelf shows right now (settings subtitles).
function M.describe(pfx, inst_id)
    local saved = setting(pfx, inst_id, "_kobo_pick")
    local names = {}
    if type(saved) == "table" and type(saved.list) == "table" then
        for _i, s in ipairs(saved.list) do
            names[#names + 1] = M.sourceName(M.decode(s))
        end
    end
    if #names > 0 then return table.concat(names, "  ·  ") end
    return _("Shuffled automatically")
end

-- ---------------------------------------------------------------------------
-- Settings shared by both modules
-- ---------------------------------------------------------------------------

function M.getPerRow(pfx, inst_id)
    local n = tonumber(setting(pfx, inst_id, "_kobo_per_row"))
    if n and n >= 1 and n <= 3 then return math.floor(n) end
    return 2
end

function M.useSerif(pfx, inst_id)
    return setting(pfx, inst_id, "_kobo_sans") ~= true
end

function M.countMode(pfx, inst_id, default)
    return setting(pfx, inst_id, "_kobo_count") or default
end

local function radioList(values, label_of, get, set, refresh)
    local sub = {}
    for _i, v in ipairs(values) do
        local _v = v
        sub[#sub + 1] = {
            text = label_of(_v), radio = true, keep_menu_open = true,
            checked_func = function() return get() == _v end,
            callback = function() set(_v); refresh() end,
        }
    end
    return sub
end

--- Menu items: tiles, reshuffle, layout, count, fonts, scale.
function M.commonMenuItems(ctx_menu, inst_id, count_default)
    local pfx = ctx_menu.pfx
    local _lc = ctx_menu._ or _
    local refresh = ctx_menu.refresh
    local items = {}

    local shuffle_labels = {
        open = _lc("Every visit"),
        hour = _lc("Hourly"),
        day  = _lc("Daily"),
    }

    items[#items + 1] = {
        text = _lc("Number of tiles"),
        value_func = function() return tostring(M.getTileCount(pfx, inst_id)) end,
        sub_item_table_func = function()
            local vals = {}
            for n = 1, M.MAX_SOURCES do vals[#vals + 1] = n end
            return radioList(vals, tostring,
                function() return M.getTileCount(pfx, inst_id) end,
                function(v) save(pfx, inst_id, "_kobo_n", v) end, refresh)
        end,
    }
    items[#items + 1] = {
        text = _lc("Shuffle"),
        value_func = function() return shuffle_labels[M.reshuffleMode(pfx, inst_id)] end,
        sub_item_table_func = function()
            return radioList({ "open", "hour", "day" }, function(v) return shuffle_labels[v] end,
                function() return M.reshuffleMode(pfx, inst_id) end,
                function(v) save(pfx, inst_id, "_kobo_shuffle", v) end, refresh)
        end,
    }
    items[#items + 1] = {
        text = _lc("Shuffle now"),
        keep_menu_open = true,
        separator = true,
        callback = function()
            M.reshuffle(pfx, inst_id)
            refresh()
            UI.Notify.toast(_lc("New picks will show on the Home screen."), 2)
        end,
    }
    items[#items + 1] = {
        text = _lc("Tiles per row"),
        value_func = function() return tostring(M.getPerRow(pfx, inst_id)) end,
        sub_item_table_func = function()
            return radioList({ 1, 2, 3 }, tostring,
                function() return M.getPerRow(pfx, inst_id) end,
                function(v) save(pfx, inst_id, "_kobo_per_row", v) end, refresh)
        end,
    }
    items[#items + 1] = {
        text = _lc("Count"),
        value_func = function()
            return M.countMode(pfx, inst_id, count_default) == "unread" and _lc("Unread books") or _lc("All books")
        end,
        sub_item_table_func = function()
            return radioList({ "all", "unread" },
                function(v) return v == "unread" and _lc("Unread books") or _lc("All books") end,
                function() return M.countMode(pfx, inst_id, count_default) end,
                function(v) save(pfx, inst_id, "_kobo_count", v) end, refresh)
        end,
    }
    items[#items + 1] = {
        text = _lc("Serif titles (like Kobo)"),
        checked_func = function() return M.useSerif(pfx, inst_id) end,
        keep_menu_open = true,
        callback = function()
            save(pfx, inst_id, "_kobo_sans", M.useSerif(pfx, inst_id))
            refresh()
        end,
    }
    items[#items + 1] = Config.makeScaleItem{
        text_func    = function() return _lc("Scale") end,
        enabled_func = function() return not Config.isScaleLinked() end,
        title        = _lc("Scale"),
        info         = _lc("Size of the covers.\n100% fills the tile's width."),
        get          = function() return Config.getModuleScalePct(inst_id, pfx) end,
        set          = function(v) Config.setModuleScale(v, inst_id, pfx) end,
        value_max    = 100,
        refresh      = refresh,
    }
    return items
end

--- Settings keys an instance owns (removed when the instance is deleted).
M.INSTANCE_SUFFIXES = { "_kobo_per_row", "_kobo_count", "_kobo_sans", "_kobo_n", "_kobo_shuffle",
                        "_kobo_pick", "_kobo_nolib", "_kobo_noauthors", "_kobo_noseries", "_kobo_min" }

--- Builds a module descriptor for one instance.
--- spec: { inst_id, name, count_default, empty_text,
---         pool(pfx), pool_sig(pfx), menu_before(ctx_menu) }
function M.makeModule(spec)
    local inst_id = spec.inst_id
    local mod = {
        id          = inst_id,
        name        = spec.name,
        label       = nil,
        default_on  = true,
        has_covers  = true,
    }

    local function opts(pfx)
        return {
            per_row    = M.getPerRow(pfx, inst_id),
            count_mode = M.countMode(pfx, inst_id, spec.count_default),
            serif      = M.useSerif(pfx, inst_id),
            scale      = Config.getModuleScale(inst_id, pfx),
        }
    end

    function mod.build(w, ctx)
        local sources = M.pickSources(ctx.pfx, inst_id, spec)
        if #sources == 0 then return M.placeholder(w, spec.empty_text) end
        local widget = M.build(w, ctx, sources, opts(ctx.pfx))
        if widget._cover_slots and #widget._cover_slots > 0 then
            pcall(Config.flushCoverQueue)
        end
        return widget
    end

    function mod.getHeight(ctx)
        local pfx = ctx and ctx.pfx or "simpleui_hs_"
        local sources = M.pickSources(pfx, inst_id, spec)
        if #sources == 0 then return Screen:scaleBySize(60) end
        local o = opts(pfx)
        local w = (ctx and ctx.col_w) or Screen:getWidth()
        local d = M.dims(w, o.per_row, o.scale, ctx and ctx.landscape_factor, o.serif)
        return M.totalHeight(d, #sources, o.per_row)
    end

    function mod.updateCovers(widget, _ctx)
        return M.updateCovers(widget)
    end

    function mod.getMenuItems(ctx_menu)
        local items = {}
        for _i, it in ipairs(spec.menu_before(ctx_menu)) do items[#items + 1] = it end
        for _i, it in ipairs(M.commonMenuItems(ctx_menu, inst_id, spec.count_default)) do items[#items + 1] = it end
        return items
    end

    return mod
end

return M
