--[[--
qp_capture.lua — KoboUI quick settings: capture mode.

Lets a custom button run ANY item of KOReader's own menu, even ones that
have no gesture/dispatcher action (e.g. a particular font setting, a plugin
entry, "Clear cache", …):

  1. In the button's settings: Action → "Pick from KOReader's menu".
  2. KOReader's full menu opens with a note. Browse to the item as usual
     (open tabs and submenus); tap the item you want.
  3. Instead of running, the item is remembered as the button's action:
     the path of names that leads to it ("Settings › Screen › Rotation").
     Closing the menu without picking anything cancels.

When the button is pressed later, the same path is looked up again in the
menu that's active then (file browser or reader) and the item's action is
run, just as if it had been tapped in the menu.

An action is stored as
    { kind = "menu", path = { "Screen", "Rotation" }, root_id = "screen",
      context = "reader" | "filemanager", title = "Rotation" }
`root_id` is the menu_items key of the first entry when it has one, which
survives a translated or reworded first entry.
--]]--

local UIManager = require("ui/uimanager")
local logger    = require("logger")
local _         = require("infra/sui_i18n").translate

local M = {}

local _state -- { on_done = fn(action), path = {…}, root_id, menu, finished }

local function clean(t)
    if type(t) ~= "string" then return nil end
    -- drop bidi marks and the "▸" KOReader adds after submenu names
    t = t:gsub("\u{2066}", ""):gsub("\u{2067}", ""):gsub("\u{2068}", ""):gsub("\u{2069}", "")
         :gsub("\u{200E}", ""):gsub("\u{200F}", ""):gsub("%s*\u{25B8}%s*$", ""):gsub("%s*\u{25C2}%s*$", "")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function menuText(item)
    if type(item.text_func) == "function" then
        local ok, t = pcall(item.text_func)
        if ok and type(t) == "string" then return clean(t) end
    end
    if type(item.text) == "string" then return clean(item.text) end
    local ok, Menu = pcall(require, "ui/widget/menu")
    if ok and Menu and Menu.getMenuText then
        local ok2, t = pcall(Menu.getMenuText, item)
        if ok2 and type(t) == "string" then return clean(t) end
    end
end

-- Text without a trailing value ("Font size: 22" → "Font size"), used as a
-- second chance when an item's label shows a changing value.
local function stem(t)
    if type(t) ~= "string" then return nil end
    return (t:gsub("%s*[:：]%s*.*$", ""):gsub("%s+$", ""))
end

local function activeMenu()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.menu then return RUI.instance.menu, "reader" end
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.menu then return FM.instance.menu, "filemanager" end
end

local function menuIdOf(menu, item)
    if not (menu and type(menu.menu_items) == "table") then return nil end
    for k, v in pairs(menu.menu_items) do
        if v == item then return k end
    end
end

function M.isActive() return _state ~= nil and not _state.finished end

local function finish(action)
    local st = _state
    _state = nil
    if not st then return end
    st.finished = true
    if action then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = string.format(_("Captured: %s"), table.concat(action.path, " › ")),
            timeout = 2,
        })
    else
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Capture cancelled."), timeout = 2 })
    end
    if st.on_done then
        UIManager:nextTick(function() pcall(st.on_done, action) end)
    end
end

-- ---------------------------------------------------------------------------
-- Hooks into KOReader's TouchMenu (installed once)
-- ---------------------------------------------------------------------------

local function install()
    if M._installed then return end
    local ok, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok or not TouchMenu then return end
    M._installed = true

    local orig_select = TouchMenu.onMenuSelect
    TouchMenu.onMenuSelect = function(self, item, tap_on_checkmark)
        if not M.isActive() then return orig_select(self, item, tap_on_checkmark) end
        local text = menuText(item) or "?"
        local is_sub = item.sub_item_table ~= nil or item.sub_item_table_func ~= nil
        if is_sub then
            -- entering a submenu: remember the step, let the menu open it
            if #_state.path == 0 then _state.root_id = menuIdOf(_state.menu, item) end
            table.insert(_state.path, text)
            return orig_select(self, item, tap_on_checkmark)
        end
        -- a final item: capture it instead of running it
        local path = {}
        for _i, p in ipairs(_state.path) do path[#path + 1] = p end
        path[#path + 1] = text
        local root_id = _state.root_id
        if #_state.path == 0 then root_id = menuIdOf(_state.menu, item) end
        local action = {
            kind = "menu", path = path, root_id = root_id,
            context = _state.context, title = text,
        }
        self:closeMenu()
        finish(action)
        return true
    end

    -- Long-press captures any entry, a submenu included (e.g. a plugin's
    -- entry under More tools): pressing the button later opens KOReader's
    -- menu right at that submenu.
    local orig_hold = TouchMenu.onMenuHold
    TouchMenu.onMenuHold = function(self, item, text_truncated)
        if not M.isActive() then return orig_hold(self, item, text_truncated) end
        local text = menuText(item) or "?"
        local path = {}
        for _i, p in ipairs(_state.path) do path[#path + 1] = p end
        path[#path + 1] = text
        local root_id = _state.root_id
        if #_state.path == 0 then root_id = menuIdOf(_state.menu, item) end
        local is_sub = item.sub_item_table ~= nil or item.sub_item_table_func ~= nil
        local action = {
            kind = "menu", path = path, root_id = root_id,
            context = _state.context, title = text,
            open_submenu = is_sub or nil,
        }
        self:closeMenu()
        finish(action)
        return true
    end

    local orig_back = TouchMenu.backToUpperMenu
    TouchMenu.backToUpperMenu = function(self, no_close)
        if M.isActive() and #self.item_table_stack ~= 0 and #_state.path > 0 then
            table.remove(_state.path)
            if #_state.path == 0 then _state.root_id = nil end
        end
        return orig_back(self, no_close)
    end

    local orig_tab = TouchMenu.switchMenuTab
    TouchMenu.switchMenuTab = function(self, tab_num)
        if M.isActive() then _state.path = {}; _state.root_id = nil end
        return orig_tab(self, tab_num)
    end

    -- The menu closing without a pick cancels the capture.
    local orig_cw = TouchMenu.onCloseWidget
    TouchMenu.onCloseWidget = function(self, ...)
        if M.isActive() then
            UIManager:nextTick(function()
                if M.isActive() then finish(nil) end
            end)
        end
        if orig_cw then return orig_cw(self, ...) end
    end
end

--- Starts capture mode: opens KOReader's full menu; on_done(action or nil).
function M.start(on_done)
    install()
    local TM = require("features/kui_topmenu")
    local menu, context = activeMenu()
    if not menu then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("KOReader's menu isn't available here."), timeout = 2,
        })
        if on_done then on_done(nil) end
        return
    end
    _state = { on_done = on_done, path = {}, menu = menu, context = context }
    TM.closeOverlays()
    UIManager:nextTick(function()
        TM.openFullMenu()
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Capture mode: go to the menu item you want and long-press it (tapping a final item works too).\nIt won't run now, it becomes the button's action. Long-press a submenu (e.g. a plugin under More tools) to have the button open the menu there.\nClose the menu to cancel."),
            timeout = 4,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Running a captured action
-- ---------------------------------------------------------------------------

local function findIn(list, want)
    if type(list) ~= "table" then return nil end
    for _i, it in ipairs(list) do
        if type(it) == "table" and menuText(it) == want then return it end
    end
    local s = stem(want)
    for _i, it in ipairs(list) do
        if type(it) == "table" and stem(menuText(it)) == s then return it end
    end
end

local function subOf(item)
    if item.sub_item_table_func then
        local ok, t = pcall(item.sub_item_table_func)
        if ok then return t end
    end
    return item.sub_item_table
end

-- A stand-in for the TouchMenu that menu callbacks receive: they may call
-- touchmenu_instance:updateItems() / closeMenu(); here there's no menu open.
local FakeTouchMenu = setmetatable({ item_table = {}, item_table_stack = {} }, {
    __index = function() return function() end end,
})

--- Runs a captured menu action. Returns true when it ran.
function M.run(action)
    if type(action) ~= "table" or type(action.path) ~= "table" or #action.path == 0 then return false end
    local menu = activeMenu()
    if not menu then return false end
    if menu.tab_item_table == nil and menu.setUpdateItemTable then
        pcall(menu.setUpdateItemTable, menu)
    end
    local tabs = menu.tab_item_table
    if type(tabs) ~= "table" then return false end

    -- first step: by menu id when known, else by text in every tab
    local item
    if action.root_id and type(menu.menu_items) == "table" then
        item = menu.menu_items[action.root_id]
    end
    if not item then
        for _i, tab in ipairs(tabs) do
            item = findIn(tab, action.path[1])
            if item then break end
        end
    end
    for i = 2, #action.path do
        if not item then break end
        item = findIn(subOf(item), action.path[i])
    end
    if not item then
        local where = action.context == "reader" and _("while reading")
            or action.context == "filemanager" and _("in the library") or nil
        UIManager:show(require("ui/widget/infomessage"):new{
            text = where and string.format(_("\"%s\" isn't in the menu here. It was captured %s."), action.title or "?", where)
                or string.format(_("\"%s\" isn't in the menu here."), action.title or "?"),
            timeout = 3,
        })
        return false
    end

    local is_sub = item.sub_item_table ~= nil or item.sub_item_table_func ~= nil
    if action.open_submenu or (is_sub and not item.callback and not item.callback_func) then
        return M.openMenuAt(action)
    end

    if item.checkmark_callback and not item.callback then
        pcall(item.checkmark_callback)
        return true
    end
    local cb = (item.callback_func and item.callback_func()) or item.callback
    if cb then
        local ok, err = pcall(cb, FakeTouchMenu)
        if not ok then logger.warn("kindleui: captured menu action failed:", err) end
        return ok
    end
    if item.tap_input or item.tap_input_func then
        -- same text-input dialog the menu would show
        local InputContainer = require("ui/widget/container/inputcontainer")
        local host = setmetatable({}, { __index = InputContainer })
        local ok, err = pcall(function()
            host:onInput(item.tap_input or item.tap_input_func())
        end)
        if not ok then logger.warn("kindleui: captured menu input failed:", err) end
        return ok
    end
    return false
end

--- Opens KOReader's full menu and walks it to the captured submenu, as if
--- you had tapped your way there.
function M.openMenuAt(action)
    local menu = activeMenu()
    if not menu then return false end
    local TM = require("features/kui_topmenu")
    TM.closeOverlays()
    UIManager:nextTick(function()
        TM.openFullMenu()
        UIManager:nextTick(function()
            local tm = menu.menu_container and menu.menu_container[1]
            if not (tm and tm.switchMenuTab and type(tm.tab_item_table) == "table") then return end
            -- tab that holds the first step
            local first
            if action.root_id and type(menu.menu_items) == "table" then first = menu.menu_items[action.root_id] end
            local tab_idx
            for i, tab in ipairs(tm.tab_item_table) do
                for _j, it in ipairs(tab) do
                    if (first and it == first) or (not first and type(it) == "table" and menuText(it) == action.path[1]) then
                        tab_idx = i; first = it; break
                    end
                end
                if tab_idx then break end
            end
            if not tab_idx then
                local fi = findIn
                for i, tab in ipairs(tm.tab_item_table) do
                    local it = fi(tab, action.path[1])
                    if it then tab_idx = i; first = it; break end
                end
            end
            if not tab_idx then return end
            pcall(tm.switchMenuTab, tm, tab_idx)
            local item = first
            for i = 1, #action.path do
                if i > 1 then item = findIn(tm.item_table, action.path[i]) end
                if not item then break end
                if item.sub_item_table or item.sub_item_table_func then
                    pcall(tm.onMenuSelect, tm, item)
                else
                    break
                end
            end
        end)
    end)
    return true
end

return M
