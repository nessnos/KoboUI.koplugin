-- kui_status_sort.lua — KoboUI
-- "Status" sort method for My Books: Reading, then Unread, then Finished.
--
-- Inside each group the most recently opened book comes first (KoboUI's
-- "last opened" time, from KOReader's reading history), then by title —
-- so the book you're reading right now is at the very top, and unread
-- books you've never opened are in title order.
--
-- Status is KoboUI's (kbo_library_header.classify), the same as the
-- Filter's: Reading = started or On hold, Unread = never started,
-- Finished = marked Finished.
--
-- Folders (e.g. series groups) aren't mixed in: they stay together, by name.

local _ = require("infra/sui_i18n").translate

local M = {}

M.ID = "koboui_status"

local RANK = { reading = 1, unread = 2, finished = 3 }

local installed = false
function M.install()
    if installed then return end
    local ok, BookList = pcall(require, "ui/widget/booklist")
    if not (ok and BookList and BookList.collates) then return end
    installed = true
    local ffiUtil = require("ffi/util")
    BookList.collates[M.ID] = {
        text = _("status"),
        menu_order = 75, -- after KOReader's percent sorts
        can_collate_mixed = false,
        item_func = function(item)
            local fp = item.path or item.file
            local state = "unread"
            pcall(function()
                state = require("features/library/kbo_library_header").classify(fp)
            end)
            item.kbo_status = state
            item.kbo_rank = RANK[state] or 2
            local t = 0
            pcall(function() t = require("features/library/kui_last_opened").time(fp) end)
            item.kbo_opened = t or 0
        end,
        init_sort_func = function()
            return function(a, b)
                local ra, rb = a.kbo_rank or 9, b.kbo_rank or 9
                if ra ~= rb then return ra < rb end
                local x, y = a.kbo_opened or 0, b.kbo_opened or 0
                if x ~= y then return x > y end
                return ffiUtil.strcoll(a.text or "", b.text or "")
            end
        end,
        mandatory_func = function(item)
            local s = item.kbo_status
            if s == "reading" then return _("Reading")
            elseif s == "finished" then return _("Finished") end
            return _("Unread")
        end,
    }
end

return M
