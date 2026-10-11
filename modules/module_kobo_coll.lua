-- module_kobo_coll.lua — KoboUI
-- Module: Kobo-style collection shelf (dynamic instances).
--
-- Shows collections of your library — and, if you like, the whole library
-- ("My Books") — as Kobo home-page tiles: a big front cover with two smaller
-- covers tucked behind it, the collection's name and "N BOOKS" underneath.
-- Which collections are shown is shuffled automatically (each time Home
-- opens, every hour or once a day). Tapping a tile opens the collection.
-- See engines/kui_kobo_tiles.lua.
--
-- Base id ends in "_row" so instances ("kobo_coll_row_xxxxxx") are treated
-- like the other dynamic modules (see the note in module_feat_coll.lua).

local _           = require("infra/sui_i18n").translate
local SUISettings = require("infra/sui_store")
local Tiles       = require("engines/kui_kobo_tiles")

local function makeInstance(inst_id)
    local function includeLibrary(pfx)
        return SUISettings:readSetting(pfx .. inst_id .. "_kobo_nolib") ~= true
    end

    local function pool(pfx)
        local GridRenderer = require("engines/sui_book_grid")
        local out = {}
        if includeLibrary(pfx) then out[#out + 1] = { kind = "library", value = "" } end
        for _i, name in ipairs(GridRenderer.listAllCollectionNames()) do
            local ok, files = pcall(GridRenderer.getCollectionFileList, name)
            if ok and type(files) == "table" and #files > 0 then
                out[#out + 1] = { kind = "collection", value = name }
            end
        end
        return out
    end

    local function poolSig(pfx)
        return includeLibrary(pfx) and "lib" or "nolib"
    end

    local function menuBefore(ctx_menu)
        local pfx = ctx_menu.pfx
        local _lc = ctx_menu._ or _
        local refresh = ctx_menu.refresh
        return {
            {
                text = _lc("Include My Books (whole library)"),
                checked_func = function() return includeLibrary(pfx) end,
                keep_menu_open = true,
                separator = true,
                callback = function()
                    SUISettings:saveSetting(pfx .. inst_id .. "_kobo_nolib", includeLibrary(pfx))
                    refresh()
                end,
            },
        }
    end

    return Tiles.makeModule{
        inst_id       = inst_id,
        name          = _("Kobo Collection Shelf"),
        count_default = "all",
        empty_text    = _("No collections with books yet"),
        pool          = pool,
        pool_sig      = poolSig,
        menu_before   = menuBefore,
    }
end

local M = {}
M.id            = "kobo_coll_row"
M.name          = _("Kobo Collection Shelf")
M.instanciable  = true
M.instances_key = "kindleui_kobo_coll_row_instances"
M.makeInstance  = makeInstance

return M
