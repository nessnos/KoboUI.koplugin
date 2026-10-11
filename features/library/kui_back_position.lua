-- kui_back_position.lua — KoboUI
-- Library: going back out of a folder returns to the page you were on, not
-- to the top of the list.
--
-- Works for every kind of folder the Library has: real folders, the
-- Authors / Series / Tags / Collections lists (virtual paths), series
-- stacks in All books ("Group series", which stays on the same path and
-- swaps the list), and the Series bookshelf.
--
-- How: the file browser's navigation entry points (opening an item, going
-- up, changing path) are wrapped on the Library's own FileChooser
-- instance, so they sit outside every other patch (some of which jump to
-- page 1 after a path change). Before a navigation we note the view (path
-- + which list) and page; when it has finished:
--   * a different view → we went into something: remember where we were;
--   * the view we came from (top of the stack) → we went back: return to
--     its page.
-- Restoring happens in the same tick, so the screen only shows the final
-- page (no flash of page 1 on e-ink).

local logger = require("logger")

local M = {}

local MAX_DEPTH = 30

local function viewKey(fc)
    local key = tostring(fc.path)
    local it = fc.item_table
    if it and (it._sg_is_series_view or it._sg_parent_path) then
        -- a series stack opened in All books: same path, another list
        key = key .. "#sg:" .. tostring(it)
    end
    return key
end

local function afterNavigation(fc, from)
    local key = viewKey(fc)
    if key == from.key then return end
    local stack = fc._kui_back_stack
    -- going back (possibly several levels): find the view in the stack
    for i = #stack, 1, -1 do
        if stack[i].key == key then
            local saved = stack[i]
            for j = #stack, i, -1 do stack[j] = nil end
            local page = saved.page or 1
            if page > 1 and page ~= fc.page and page <= (fc.page_num or 1) then
                local ok, err = pcall(fc.onGotoPage, fc, page)
                if not ok then logger.warn("kindleui: back position:", err) end
            end
            return
        end
    end
    -- going in (or sideways): remember where we were
    stack[#stack + 1] = from
    if #stack > MAX_DEPTH then table.remove(stack, 1) end
end

local function wrap(fc, name)
    local FileChooser = require("ui/widget/filechooser")
    fc[name] = function(self, ...)
        local depth = self._kui_back_depth or 0
        local from
        if depth == 0 then from = { key = viewKey(self), page = self.page or 1 } end
        self._kui_back_depth = depth + 1
        -- the class method at call time (other patches may swap it)
        local ok, r1, r2, r3 = pcall(FileChooser[name], self, ...)
        self._kui_back_depth = depth
        if from then pcall(afterNavigation, self, from) end
        if not ok then error(r1, 0) end
        return r1, r2, r3
    end
end

function M.attach(fc)
    if not fc or fc._kui_back_attached then return end
    fc._kui_back_attached = true
    fc._kui_back_stack = {}
    wrap(fc, "onMenuSelect")
    wrap(fc, "onFolderUp")
    wrap(fc, "changeToPath")
end

local _installed = false
function M.install()
    if _installed then return end
    _installed = true
    local FileChooser = require("ui/widget/filechooser")
    local orig_init = FileChooser.init
    FileChooser.init = function(self, ...)
        local r = orig_init(self, ...)
        if self.name == "filemanager" then M.attach(self) end
        return r
    end
end

return M
