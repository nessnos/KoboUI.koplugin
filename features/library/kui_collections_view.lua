-- kui_collections_view.lua — KoboUI
-- Collections as a Library browse view, drawn like Series / Authors.
--
-- The Library's virtual browse tree (sui_library_browse) gets a
-- "collections" dimension:
--   <base>/.simpleui-browse/collections          → one folder per collection
--   <base>/.simpleui-browse/collections/=<name>  → that collection's books
-- So collections get the same folder covers (single or 2×2), badges, labels
-- and list / mosaic display mode as the series view, with no extra code for
-- the look. Books inside a collection follow the collection's own sort
-- order (manual, title, …), like KOReader's own collection screen.
--
-- Replaces the 2-collections-mosaic.lua user patch.

local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local _ = require("infra/sui_i18n").translate

local M = {}

M.DIMENSION = "collections"

local function RC()
    local ok, ReadCollection = pcall(require, "readcollection")
    return ok and ReadCollection or nil
end

function M.displayName(name)
    local ReadCollection = RC()
    if ReadCollection and name == ReadCollection.default_collection_name then
        return _("Favorites")
    end
    return name
end

-- Collection names in KOReader's own collections-list order.
function M.names()
    local ReadCollection = RC()
    if not ReadCollection or not ReadCollection.coll then return {} end
    local settings = ReadCollection.coll_settings or {}
    local names = {}
    for name in pairs(ReadCollection.coll) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        local oa = settings[a] and settings[a].order
        local ob = settings[b] and settings[b].order
        if oa and ob and oa ~= ob then return oa < ob end
        if oa and not ob then return true end
        if ob and not oa then return false end
        return ffiUtil.strcoll(a, b)
    end)
    return names
end

-- The collection's existing books, in the collection's own sort order.
function M.files(name, ui)
    local ReadCollection = RC()
    local coll = ReadCollection and ReadCollection.coll and ReadCollection.coll[name]
    if not coll then return {} end
    local items = {}
    for _i, item in pairs(coll) do
        if item.file and lfs.attributes(item.file, "mode") == "file" then
            items[#items + 1] = {
                file  = item.file,
                text  = item.text,
                order = item.order or 0,
                attr  = item.attr or lfs.attributes(item.file) or {},
            }
        end
    end
    if #items > 1 then
        local by_order = function(a, b) return a.order < b.order end
        local sorting = by_order
        local cs = (ReadCollection.coll_settings or {})[name] or {}
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        local collate = ok_bl and BookList and BookList.collates and cs.collate and BookList.collates[cs.collate]
        if collate then
            local ok = pcall(function()
                if collate.item_func then
                    for _i, it in ipairs(items) do collate.item_func(it, ui) end
                end
                local f = collate.init_sort_func()
                if cs.collate_reverse then
                    sorting = function(a, b) return f(b, a) end
                else
                    sorting = f
                end
            end)
            if not ok then sorting = by_order end
        end
        if not pcall(table.sort, items, sorting) then table.sort(items, by_order) end
    end
    local out = {}
    for i, it in ipairs(items) do out[i] = it.file end
    return out
end

-- dim_list level: one virtual folder per collection.
function M.buildDirs(fc, base_dir, collate, VirtualPath, fakeAttr, overrides)
    if collate then M._last_leaf = nil end
    local dirs = {}
    for i, name in ipairs(M.names()) do
        if collate then
            local files = M.files(name, fc and fc.ui)
            local vpath = VirtualPath.buildLeaf(base_dir, nil, M.DIMENSION, name)
            local item = fc:getListItem(nil, M.displayName(name), vpath, fakeAttr(i), collate)
            item.nb_sub_files = #files
            item.mandatory    = tostring(#files) .. " \u{F016}"
            item.is_virtual_meta_leaf = true
            item.virtual_leaf_count   = #files
            item.kui_collection = name
            local override_fp = overrides and overrides[vpath]
            if override_fp and lfs.attributes(override_fp, "mode") == "file" then
                item.representative_filepath = override_fp
            elseif files[1] then
                item.representative_filepath = files[1]
            end
            dirs[#dirs + 1] = item
        else
            dirs[#dirs + 1] = true
        end
    end
    return dirs
end

-- file_list level: the collection's books.
function M.buildFiles(fc, path, name, collate)
    -- A shuffled collection gets a new order each time it is entered (not
    -- on every refresh while it stays open).
    if collate and M._last_leaf ~= name then
        M._last_leaf = name
        local ok_sh, SH = pcall(require, "features/library/kui_collection_shuffle")
        if ok_sh and SH and SH.isShuffled(name) then SH.shuffle(name) end
    end
    local files = {}
    local ok_bim, bim = pcall(require, "bookinfomanager")
    for _i, fullpath in ipairs(M.files(name, fc and fc.ui)) do
        local fname = fullpath:match("([^/]+)$") or fullpath
        local attr = lfs.attributes(fullpath)
        if attr and attr.mode == "file" and fc:show_file(fname, fullpath) then
            local item = fc:getListItem(path, fname, fullpath, attr, collate)
            if collate and ok_bim and bim then
                local bi = bim:getBookInfo(fullpath, false)
                if bi and bi.authors and bi.authors ~= "" then
                    item.mandatory = bi.authors:gsub("\n.*", " et al.")
                end
            end
            files[#files + 1] = item
        end
    end
    return files
end

-- KOReader's "Collections" list (from menus, gestures, the home screen…)
-- opens this Library view instead, so collections are always a mosaic
-- (in mosaic mode) with vertical scrolling. "Manage collections" and the
-- "add to collection" picker still use KOReader's own list.
M._stock_depth = 0
function M.showStockList(fmc, ...)
    M._stock_depth = M._stock_depth + 1
    local ok, res = pcall(fmc.onShowCollList, fmc, ...)
    M._stock_depth = M._stock_depth - 1
    if not ok then error(res, 0) end
    return res
end

local _hooked = false
function M.installRedirect()
    if _hooked then return end
    local ok, FMColl = pcall(require, "apps/filemanager/filemanagercollection")
    if not ok or not FMColl then return end
    _hooked = true
    local orig = FMColl.onShowCollList
    FMColl.onShowCollList = function(fmc, file_or_selected, ...)
        if file_or_selected == nil and M._stock_depth == 0 and not fmc.coll_list then
            local FM = package.loaded["apps/filemanager/filemanager"]
            local fm = FM and FM.instance
            local in_reader = fmc.ui and fmc.ui.document ~= nil
            local ok_bm, BM = pcall(require, "features/library/sui_library_browse")
            if fm and fm.file_chooser and not in_reader and ok_bm and BM.isEnabled() then
                if fmc.booklist_menu then
                    -- Back from a collection: the collection closes next;
                    -- land on the Library's Collections view, not Home.
                    fmc.booklist_menu._navbar_closing_intentionally = true
                    fm._sui_show_folder_pending = true
                    -- Closing the collection refreshes the title bar with the
                    -- real folder; put "Collections" back under the title.
                    require("ui/uimanager"):scheduleIn(0.1, function()
                        local fc = fm.file_chooser
                        if fc and fc.path then pcall(fm.updateTitleBarPath, fm, fc.path) end
                    end)
                end
                BM.chooseView(fm, "collections")
                return true
            end
        end
        return orig(fmc, file_or_selected, ...)
    end
end

-- Long-press on a collection folder.
function M.showHoldDialog(fc, item, extra_buttons)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local name = item.kui_collection
    local FM = package.loaded["apps/filemanager/filemanager"]
    local fm = FM and FM.instance
    local dialog
    local buttons = {}
    for _i, b in ipairs(extra_buttons or {}) do buttons[#buttons + 1] = b end
    buttons[#buttons + 1] = {{
        text = _("Open collection (sort, filter…)"),
        callback = function()
            UIManager:close(dialog)
            if fm and fm.collections then fm.collections:onShowColl(name) end
        end,
    }}
    buttons[#buttons + 1] = {{
        text = _("Manage collections"),
        callback = function()
            UIManager:close(dialog)
            if fm and fm.collections then M.showStockList(fm.collections) end
        end,
    }}
    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }}
    dialog = ButtonDialog:new{
        title = M.displayName(name),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

return M
