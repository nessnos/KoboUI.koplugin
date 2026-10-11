-- kui_last_opened.lua — KoboUI
-- "Last opened" sort method.
--
-- KOReader's own "last read date" sort uses the file's access time, which
-- e-readers often don't update (the file system is mounted without atime),
-- so it rarely reflects when a book was really read. This one uses
-- KOReader's reading history (the time a book was last opened). Books not
-- in the history (never opened, or removed from it) come last, by name.
-- (The settings file's save time isn't used: KOReader also rewrites it
-- without the book being opened.)
--
-- Adds `last_opened` to BookList.collates (so it appears in the file
-- browser's "Sort by" menu) and exposes M.time(path) for the home screen
-- modules (Featured Collection's "Last opened" sort).

local _   = require("infra/sui_i18n").translate

local M = {}

M.ID = "last_opened"

function M.time(path)
    if type(path) ~= "string" then return 0 end
    local ok, t = pcall(function()
        local RH = require("readhistory")
        local idx = RH:getIndexByFile(path)
        local e = idx and RH.hist[idx]
        if e and e.time then return e.time end
    end)
    return (ok and tonumber(t)) or 0
end

-- Sorts a list of file paths, most recently opened first (in place).
function M.sortPaths(paths)
    local t = {}
    for _i, p in ipairs(paths) do t[p] = M.time(p) end
    table.sort(paths, function(a, b)
        if t[a] ~= t[b] then return t[a] > t[b] end
        return a < b
    end)
    return paths
end

local installed = false
function M.install()
    if installed then return end
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not (ok and BookList and BookList.collates) then return end
    installed = true
    local ffiUtil  = require("ffi/util")
    local datetime = require("datetime")
    BookList.collates[M.ID] = {
        text = _("last opened"),
        menu_order = 35, -- right after KOReader's "last read date"
        can_collate_mixed = true,
        item_func = function(item)
            item.last_opened = (item.is_file ~= false and (item.path or item.file)) and M.time(item.path or item.file) or 0
        end,
        init_sort_func = function()
            return function(a, b)
                local x, y = a.last_opened or 0, b.last_opened or 0
                if x ~= y then return x > y end
                return ffiUtil.strcoll(a.text or "", b.text or "")
            end
        end,
        mandatory_func = function(item)
            if item.last_opened and item.last_opened > 0 then
                return datetime.secondsToDateTime(item.last_opened)
            end
            return "–"
        end,
    }
end

return M
