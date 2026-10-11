-- module_kobo_meta.lua — KoboUI
-- Module: Kobo-style author / series shelf (dynamic instances).
--
-- Same tiles as module_kobo_coll.lua, but each tile is an author or a
-- series: the covers of its books (unread ones first), the name, and
-- "N UNREAD BOOKS" — like Kobo's "Sarah J. Maas — 13 UNREAD BOOKS".
-- The authors and series shown are shuffled automatically from your
-- library. Tapping a tile opens that author's / series' books.
--
-- Authors and series come from KoboUI's library metadata (the same data
-- as Library → Browse by Author / Series), i.e. books the library has
-- already indexed.

local _           = require("infra/sui_i18n").translate
local SUISettings = require("infra/sui_store")
local Tiles       = require("engines/kui_kobo_tiles")

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

    local function pool(pfx)
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
        -- Too few with enough books: fill up with the others.
        if #out == 0 then return fallback end
        return out
    end

    local function poolSig(pfx)
        return (useAuthors(pfx) and "a" or "") .. (useSeries(pfx) and "s" or "") .. minBooks(pfx)
    end

    local function menuBefore(ctx_menu)
        local pfx = ctx_menu.pfx
        local _lc = ctx_menu._ or _
        local refresh = ctx_menu.refresh
        return {
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
                    return string.format(ctx_menu.N_ and ctx_menu.N_("%d book", "%d books", n) or "%d", n)
                end,
                separator = true,
                sub_item_table_func = function()
                    local sub = {}
                    for n = 1, 5 do
                        local _n = n
                        sub[#sub + 1] = {
                            text = tostring(_n), radio = true, keep_menu_open = true,
                            checked_func = function() return minBooks(pfx) == _n end,
                            callback = function()
                                SUISettings:saveSetting(pfx .. inst_id .. "_kobo_min", _n)
                                refresh()
                            end,
                        }
                    end
                    return sub
                end,
            },
        }
    end

    return Tiles.makeModule{
        inst_id       = inst_id,
        name          = _("Kobo Author / Series Shelf"),
        count_default = "unread",
        empty_text    = _("No authors or series found yet — open the library once"),
        pool          = pool,
        pool_sig      = poolSig,
        menu_before   = menuBefore,
    }
end

local M = {}
M.id            = "kobo_meta_row"
M.name          = _("Kobo Author / Series Shelf")
M.instanciable  = true
M.instances_key = "kindleui_kobo_meta_row_instances"
M.makeInstance  = makeInstance

return M
