-- module_meta_row.lua — KoboUI
-- Module: Author / Series Collection (dynamic instances).
--
-- Looks and works exactly like a Featured Collection (a row — or grid — of
-- covers, the same Size/Appearance/Long-press settings), but instead of one
-- collection you pick, it shows ONE AUTHOR OR SERIES from your library,
-- shuffled: each time you come back to the Home screen it's another one
-- ("Ali Hazelwood" today, "A Court of Thorns and Roses" next time…).
-- The section title is the author's or series' name.
--
-- Authors and series come from KoboUI's library metadata (the same data
-- as Library → Browse by Author / Series). The shuffle itself is shared
-- with the Kobo shelves (engines/kui_kobo_tiles.lua: pickSources).
--
-- Base id ends in "_row" so instances ("meta_row_xxxxxx") are treated like
-- the other dynamic modules (see the note in module_feat_coll.lua).

local _ = require("infra/sui_i18n").translate

local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")

local SUISettings  = require("infra/sui_store")
local SUIStyle     = require("features/sui_style")
local UI           = require("infra/sui_core")
local GridRenderer = require("engines/sui_book_grid")
local Tiles        = require("engines/kui_kobo_tiles")

local MAX_ITEMS = 5

local function makeInstance(inst_id)
    local function flag(pfx, suffix)
        return SUISettings:readSetting(pfx .. inst_id .. suffix) ~= true
    end
    local function useAuthors(pfx) return flag(pfx, "_kobo_noauthors") end
    local function useSeries(pfx)  return flag(pfx, "_kobo_noseries") end
    local function minBooks(pfx)
        local n = tonumber(SUISettings:readSetting(pfx .. inst_id .. "_kobo_min"))
        return (n and n >= 1 and n <= 5) and math.floor(n) or 2
    end

    local pick_spec = {
        count = 1,
        pool = function(pfx)
            local out, fallback = {}, {}
            local min = minBooks(pfx)
            local kinds = {}
            if useAuthors(pfx) then kinds[#kinds + 1] = "author" end
            if useSeries(pfx) then kinds[#kinds + 1] = "series" end
            for _i, kind in ipairs(kinds) do
                for _j, v in ipairs(Tiles.listMetaValues(kind)) do
                    local src = { kind = kind, value = v[1] }
                    if (v[2] or 0) >= min then out[#out + 1] = src
                    elseif (v[2] or 0) >= 1 then fallback[#fallback + 1] = src end
                end
            end
            if #out == 0 then return fallback end
            return out
        end,
        pool_sig = function(pfx)
            return (useAuthors(pfx) and "a" or "") .. (useSeries(pfx) and "s" or "") .. minBooks(pfx)
        end,
    }

    local function current(pfx)
        return Tiles.pickSources(pfx or "simpleui_hs_", inst_id, pick_spec)[1]
    end

    local function displayName(pfx)
        local src = current(pfx)
        if not src then return _("Author / Series Collection") end
        return Tiles.sourceName(src)
    end

    local function getFileList(pfx)
        local src = current(pfx)
        if not src then return {} end
        return Tiles.sourceFiles(src)
    end

    local function extraMenuItemsBefore(ctx_menu)
        local pfx = ctx_menu.pfx
        local _lc = ctx_menu._ or _
        local refresh = ctx_menu.refresh
        local shuffle_labels = {
            open = _lc("Every visit"),
            hour = _lc("Hourly"),
            day  = _lc("Daily"),
        }
        local function radio(values, label_of, get, set)
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
        return {
            {
                text = _lc("Showing now"),
                value_func = function() return displayName(pfx) end,
                dim = true,
                callback = function() end,
            },
            {
                text = _lc("Authors"),
                checked_func = function() return useAuthors(pfx) end,
                keep_menu_open = true,
                callback = function()
                    SUISettings:saveSetting(pfx .. inst_id .. "_kobo_noauthors", useAuthors(pfx))
                    refresh()
                end,
            },
            {
                text = _lc("Series"),
                checked_func = function() return useSeries(pfx) end,
                keep_menu_open = true,
                callback = function()
                    SUISettings:saveSetting(pfx .. inst_id .. "_kobo_noseries", useSeries(pfx))
                    refresh()
                end,
            },
            {
                text = _lc("Only with at least"),
                value_func = function()
                    local n = minBooks(pfx)
                    return (ctx_menu.N_ and string.format(ctx_menu.N_("%d book", "%d books", n), n)) or tostring(n)
                end,
                sub_item_table_func = function()
                    return radio({ 1, 2, 3, 4, 5 }, tostring, function() return minBooks(pfx) end,
                        function(v) SUISettings:saveSetting(pfx .. inst_id .. "_kobo_min", v) end)
                end,
            },
            {
                text = _lc("Shuffle"),
                value_func = function() return shuffle_labels[Tiles.reshuffleMode(pfx, inst_id)] end,
                sub_item_table_func = function()
                    return radio({ "open", "hour", "day" }, function(v) return shuffle_labels[v] end,
                        function() return Tiles.reshuffleMode(pfx, inst_id) end,
                        function(v) SUISettings:saveSetting(pfx .. inst_id .. "_kobo_shuffle", v) end)
                end,
            },
            {
                text = _lc("Shuffle now"),
                keep_menu_open = true,
                separator = true,
                callback = function()
                    Tiles.reshuffle(pfx, inst_id)
                    refresh()
                end,
            },
        }
    end

    local mod = GridRenderer.makeModule{
        id          = inst_id,
        name        = _("Author / Series Collection"),
        default_on  = false,
        is_book_mod = true,
        max_items   = MAX_ITEMS,
        paged       = true,
        label_fn    = displayName,
        getFileList = function(ctx) return getFileList(ctx.pfx) end,
        extra_menu_items_before = extraMenuItemsBefore,
        count_label = true,   -- KoboUI: "N books" under the title
        badges = { pages = "off", series = "off", new = "off" },
        progress_style = { default = "none" },
        grid          = true,
        default_rows  = 1,
        default_cols  = MAX_ITEMS,
    }

    -- Nothing to show yet (no authors/series indexed): say so.
    local orig_build = mod.build
    function mod.build(w, ctx)
        local widget = orig_build(w, ctx)
        if widget then return widget end
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = mod.getHeight(ctx) },
            UI.makeColoredText{
                text  = _("No authors or series found yet — open the library once"),
                face  = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY),
                width = w - UI.PAD * 2,
            },
        }
    end

    return mod
end

local M = {}
M.id            = "meta_row"
M.name          = _("Author / Series Collection")
M.instanciable  = true
M.instances_key = "kindleui_meta_row_instances"
M.makeInstance  = makeInstance

return M
