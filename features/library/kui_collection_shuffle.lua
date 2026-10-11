--[[
kui_collection_shuffle.lua — KoboUI

Adds "Shuffle" to a collection's sort dialog (open a collection → menu
icon → Sort by / Arrange). A shuffled collection gets a new random book
order:
  * every time the Home screen (or a Custom Screen) opens, so Featured
    Collection and other collection modules show different covers;
  * every time the collection is opened, in KOReader's collection screen
    or in the Library's Collections view;
  * when "Shuffle" is tapped again in the sort dialog.

A shuffled collection is stored as a normal manual collection
(collate = nil) with `shuffle = true` in its settings, and its books'
in-memory `order` is rewritten. Picking any other sort method (or Manual
sorting) turns Shuffle off.

Based on Lina's 2-collection-shuffle.lua patch, which this replaces.
]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

local SHUFFLE_ID = "__shuffle__"

local function RC()
    local ok, ReadCollection = pcall(require, "readcollection")
    return ok and ReadCollection or nil
end

function M.isShuffled(coll_name)
    local ReadCollection = RC()
    local cs = ReadCollection and ReadCollection.coll_settings and ReadCollection.coll_settings[coll_name]
    return cs and cs.shuffle and not cs.collate or false
end

function M.shuffle(coll_name)
    local ReadCollection = RC()
    local coll = ReadCollection and ReadCollection.coll and ReadCollection.coll[coll_name]
    if not coll then return end
    local items = {}
    for _i, item in pairs(coll) do items[#items + 1] = item end
    for i = #items, 2, -1 do -- Fisher–Yates
        local j = math.random(i)
        items[i], items[j] = items[j], items[i]
    end
    for i, item in ipairs(items) do item.order = i end
end

function M.shuffleAllFlagged()
    local ReadCollection = RC()
    if not (ReadCollection and ReadCollection.coll and ReadCollection.coll_settings) then return end
    for coll_name in pairs(ReadCollection.coll) do
        if M.isShuffled(coll_name) then M.shuffle(coll_name) end
    end
end

local installed = false
function M.install()
    if installed then return end
    installed = true
    pcall(require, "random") -- seeds math.random with the current time

    local ok_fmc, FileManagerCollection = pcall(require, "apps/filemanager/filemanagercollection")
    local ReadCollection = RC()
    if ok_fmc and FileManagerCollection and ReadCollection then
        local ButtonDialog = require("ui/widget/buttondialog")
        local UIManager = require("ui/uimanager")

        -- 1. setCollate: our pseudo-collate, and a new order when a
        --    collection is opened.
        local orig_setCollate = FileManagerCollection.setCollate
        FileManagerCollection.setCollate = function(self, collate_id, collate_reverse)
            local coll_name = self.booklist_menu and self.booklist_menu.path
            local cs = coll_name and ReadCollection.coll_settings[coll_name]
            if cs then
                if collate_id == SHUFFLE_ID then
                    cs.shuffle = true
                    collate_id, collate_reverse = false, false -- stored as manual
                    M.shuffle(coll_name)
                elseif collate_id ~= nil then
                    cs.shuffle = nil -- another sort method: Shuffle off
                elseif M.isShuffled(coll_name) then
                    M.shuffle(coll_name) -- collection being opened
                end
            end
            return orig_setCollate(self, collate_id, collate_reverse)
        end

        -- 2. Sort dialog: a "Shuffle" button.
        local orig_showArrange = FileManagerCollection.showArrangeBooksDialog
        FileManagerCollection.showArrangeBooksDialog = function(self, ...)
            local fmc = self
            local coll_name = self.booklist_menu and self.booklist_menu.path
            local shuffled = coll_name and M.isShuffled(coll_name)
            local had_own_new = rawget(ButtonDialog, "new")
            local orig_new = ButtonDialog.new
            local dialog
            ButtonDialog.new = function(cls, o)
                local ok, err = pcall(function()
                    local buttons = o and o.buttons
                    if type(buttons) ~= "table" or not coll_name then return end
                    -- With Shuffle on, KOReader sees a manual collection:
                    -- move the checkmark from "Manual sorting" to "Shuffle".
                    if shuffled then
                        local manual = _("Manual sorting")
                        for _i, row in ipairs(buttons) do
                            for _j, btn in ipairs(row) do
                                if type(btn.text) == "string" and btn.text:find(manual, 1, true) == 1 then
                                    btn.text = manual
                                end
                            end
                        end
                    end
                    local shuffle_row = {{
                        text = _("Shuffle") .. (shuffled and "  ✓" or ""),
                        callback = function()
                            if dialog then UIManager:close(dialog) end
                            fmc.updated_collections[coll_name] = true
                            fmc:setCollate(SHUFFLE_ID)
                            fmc:updateItemTable()
                            pcall(ReadCollection.write, ReadCollection, { [coll_name] = true })
                        end,
                    }}
                    -- Right before the separator ({}) above "Manual sorting".
                    local pos = #buttons + 1
                    for i, row in ipairs(buttons) do
                        if type(row) == "table" and #row == 0 then pos = i break end
                    end
                    table.insert(buttons, pos, shuffle_row)
                end)
                if not ok then logger.warn("kindleui: collection shuffle: could not add button:", err) end
                dialog = orig_new(cls, o)
                return dialog
            end
            local ok, res = pcall(orig_showArrange, self, ...)
            if had_own_new then ButtonDialog.new = had_own_new else ButtonDialog.new = nil end
            if not ok then error(res, 0) end
            return res
        end
    end

    -- 3. Home screen / Custom Screens: reshuffle on every opening.
    local ok_se, ScreenEngine = pcall(require, "engines/sui_screen_engine")
    if ok_se and ScreenEngine and type(ScreenEngine._open) == "function" then
        local orig_open = ScreenEngine._open
        ScreenEngine._open = function(...)
            local ok, err = pcall(M.shuffleAllFlagged)
            if not ok then logger.warn("kindleui: collection shuffle failed:", err) end
            return orig_open(...)
        end
    end
end

return M
