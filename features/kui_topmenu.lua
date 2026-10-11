--[[--
kui_topmenu.lua — KoboUI

Makes KoboUI's quick-settings panel (features/quickpanel/) THE top menu:

  * Tapping or swiping down at the top of the screen — on the Home screen,
    in the Library and while reading — opens only the quick-settings panel.
    In the reader the bottom font/config panel isn't opened either.
  * The panel always has a "KOReader" button, which opens KOReader's normal
    top menu with every tab and every setting.

How it works: FileManagerMenu:onShowMenu and ReaderMenu:onShowMenu are
wrapped. Unless the full menu was asked for (the KOReader button, the
"KoboUI: KOReader menu" gesture, KOReader's menu search), they show the
panel instead.

Setting: G_reader_settings "kindleui_quick_menu_only" (default true). When
it is off, the top of the screen opens KOReader's normal menu again.
--]]--

local UIManager = require("ui/uimanager")
local Event     = require("ui/event")
local logger    = require("logger")
local _         = require("infra/sui_i18n").translate

local M = {}

-- KoboUI: off by default. The top of the Home screen and the Library is the
-- Kobo status bar (tap an icon for its panel); swiping down from the top
-- opens KOReader's own menu, like stock KOReader.
M.SETTING_KEY = "koboui_quick_menu_only"

function M.isQuickMenuOnly()
    return G_reader_settings:isTrue(M.SETTING_KEY)
end

function M.setQuickMenuOnly(on)
    G_reader_settings:saveSetting(M.SETTING_KEY, on and true or false)
end

local _panel -- the open quick-settings panel, if any

--- Returns the KOReader menu module (ReaderMenu or FileManagerMenu) that is
--- currently in charge, and the name of its close method.
local function activeMenu()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.menu then
        return RUI.instance.menu, "onCloseReaderMenu"
    end
    local FM = package.loaded["apps/filemanager/filemanager"]
    if FM and FM.instance and FM.instance.menu then
        return FM.instance.menu, "onCloseFileManagerMenu"
    end
end

function M.isPanelOpen()
    return _panel ~= nil and not _panel._closed
end

function M.closePanel()
    if M.isPanelOpen() then _panel:close() end
    _panel = nil
end

--- Shows the quick-settings panel.
function M.showPanel()
    if M.isPanelOpen() then return end
    local menu, close_name = activeMenu()
    if menu and menu.menu_container and menu[close_name] then
        menu[close_name](menu)
    end
    local ok, err = pcall(function()
        local QuickPanel = require("features/quickpanel/qp_panel")
        _panel = QuickPanel:new{}
        _panel.on_close = function() _panel = nil end
        _panel:show()
    end)
    if not ok then
        logger.err("kindleui: quick settings panel failed:", err)
        _panel = nil
        return false
    end
    return true
end

--- Opens KOReader's full top menu (all tabs), on the tab used last time.
function M.openFullMenu()
    M.closePanel()
    local menu, close_name = activeMenu()
    if not menu then return end
    if menu.menu_container and menu[close_name] then
        menu[close_name](menu)
    end
    menu._kui_full_request = true
    local ok, err = pcall(menu.onShowMenu, menu)
    menu._kui_full_request = nil
    if not ok then logger.err("kindleui: opening KOReader menu failed:", err) end
end

--- Opens the quick-settings panel.
function M.openQuickMenu()
    M.showPanel()
end

-- ---------------------------------------------------------------------------
-- Patches
-- ---------------------------------------------------------------------------

local function wrapShowMenu(MenuClass)
    local orig_show = MenuClass.onShowMenu
    MenuClass._kui_orig_onShowMenu = orig_show
    MenuClass.onShowMenu = function(self, tab_index, do_not_show)
        -- do_not_show is used by KOReader's menu search, which needs the full
        -- menu tree, so it always gets the real one.
        if do_not_show or self._kui_full_request or not M.isQuickMenuOnly() then
            return orig_show(self, tab_index, do_not_show)
        end
        if M.showPanel() then return true end
        return orig_show(self, tab_index, do_not_show)
    end
end

-- In the reader, KOReader also opens the bottom config panel (font, margins…)
-- together with the top menu. With the quick panel, only the panel opens.
local function wrapReaderGestures(RMenu)
    local orig_tap = RMenu.onTapShowMenu
    RMenu.onTapShowMenu = function(self, ges)
        if not M.isQuickMenuOnly() then return orig_tap(self, ges) end
        if self.activation_menu ~= "swipe" then
            self:onShowMenu()
            return true
        end
    end
    local orig_swipe = RMenu.onSwipeShowMenu
    RMenu.onSwipeShowMenu = function(self, ges)
        if not M.isQuickMenuOnly() then return orig_swipe(self, ges) end
        if self.activation_menu ~= "tap" and ges.direction == "south" then
            self:onShowMenu()
            self.ui:handleEvent(Event:new("HandledAsSwipe")) -- cancel any pan scroll made
            return true
        end
    end
end

--- Closes dialogs/windows on top of the current full-screen view (e.g.
--- KoboUI's settings window) so a menu can open in their place.
function M.closeOverlays()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if not w or w.covers_fullscreen or w.name == "ReaderUI" or w.name == "filemanager" then
            break
        end
        UIManager:close(w)
    end
end

-- KoboUI: a tap at the top of the Home screen / Library goes to the Kobo
-- status bar: on an icon it opens that icon's panel; elsewhere in the bar
-- it does nothing (KOReader's menu opens with a swipe down instead).
-- Setting koboui_tap_top_menu (default off) brings back "tap opens menu".
local function wrapFMTap(FMMenu)
    local orig_tap = FMMenu.onTapShowMenu
    FMMenu.onTapShowMenu = function(self, ges)
        local SB = require("screens/kbo_statusbar")
        if SB.isEnabled() and ges and ges.pos then
            local ok_tb, Topbar = pcall(require, "screens/sui_topbar")
            local SUISettings = require("infra/sui_store")
            local top_h = ok_tb and SUISettings:nilOrTrue("simpleui_topbar_enabled") and Topbar.TOTAL_TOP_H() or 0
            if ges.pos.y < top_h then
                if SB.onTap(ges.pos) then return true end
                if not G_reader_settings:isTrue("koboui_tap_top_menu") then return true end
            elseif not G_reader_settings:isTrue("koboui_tap_top_menu") then
                return false
            end
        end
        return orig_tap(self, ges)
    end
end

function M.install()
    if M._installed then return end
    M._installed = true
    local ok_fm, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fm and FMMenu then
        wrapShowMenu(FMMenu)
        wrapFMTap(FMMenu)
    end
    local ok_rm, RMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm and RMenu then
        wrapShowMenu(RMenu)
        wrapReaderGestures(RMenu)
    end
end

return M
