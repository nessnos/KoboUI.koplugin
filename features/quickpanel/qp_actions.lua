--[[--
qp_actions.lua — KoboUI quick settings: what the buttons do.

Two kinds of buttons:
  * built-in buttons (this file's BUILTIN table): fixed action, name and icon
    can be changed; the "KOReader" button can't be switched off either;
  * custom buttons: any KOReader action (the same list as gestures use) or
    any KoboUI quick action, with a name and an icon of your choice.

Icons are either "nerd:HEX" (a symbol from KOReader's icon font) or a path
to an .svg/.png file.
--]]--

local Device    = require("device")
local Event     = require("ui/event")
local UIManager = require("ui/uimanager")
local logger    = require("logger")
local _         = require("infra/sui_i18n").translate

local A = {}

local function broadcast(name, ...)
    UIManager:broadcastEvent(Event:new(name, ...))
end

local function plugin()
    local ok, UI = pcall(require, "infra/sui_core")
    return ok and UI.getLivePlugin and UI.getLivePlugin() or nil
end

local function inReader()
    local RUI = package.loaded["apps/reader/readerui"]
    return RUI and RUI.instance ~= nil
end

local function confirm(text, ok_text, fn)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{ text = text, ok_text = ok_text, ok_callback = fn })
end

-- ---------------------------------------------------------------------------
-- Built-in buttons
--
--   label      default name
--   icon       default icon
--   run(p)     what a tap does; p is the open panel (p:close() closes it)
--   keep_open  true = the panel stays open and is redrawn after the tap
--   active()   true = drawn as "on" (filled)
--   available() false = hidden on this device
--   default_on shown in a fresh setup
--   locked     can't be switched off (the KOReader button)
-- ---------------------------------------------------------------------------

A.BUILTIN = {
    koreader_menu = {
        label = _("KOReader"), icon = "nerd:EA5B", locked = true, default_on = true,
        run = function(p)
            p:close()
            UIManager:nextTick(function()
                require("features/kui_topmenu").openFullMenu()
            end)
        end,
    },
    wifi = {
        label = _("Wi-Fi"), icon = "nerd:ECA8", default_on = true, keep_open = true,
        available = function() return Device:hasWifiToggle() end,
        active = function()
            local ok, NetworkMgr = pcall(require, "ui/network/manager")
            if not ok then return false end
            local ok2, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
            return ok2 and on or false
        end,
        -- The label shows the state, like on a Kindle: the network's name
        -- when connected, "On" when Wi-Fi is on but not connected, "Off".
        dynamic_label = function()
            local ok, NetworkMgr = pcall(require, "ui/network/manager")
            if not ok or not NetworkMgr then return _("Off") end
            local ok_on, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
            if not (ok_on and on) then return _("Off") end
            local ok_c, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
            if ok_c and connected then
                local ok_n, nw = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
                local ssid = ok_n and type(nw) == "table" and (nw.ssid or nw.essid)
                if type(ssid) == "string" and ssid ~= "" then return ssid end
            end
            return _("On")
        end,
        run = function(p)
            broadcast("ToggleWifi")
            -- connecting takes a moment: look again a little later too
            UIManager:scheduleIn(1.5, function() p:refresh() end)
            UIManager:scheduleIn(6, function() p:refresh() end)
        end,
    },
    frontlight = {
        label = _("Light"), icon = "nerd:EA34", default_on = true, keep_open = true,
        available = function() return Device:hasFrontlight() end,
        active = function()
            local powerd = Device:getPowerDevice()
            return powerd and powerd:isFrontlightOn() or false
        end,
        run = function(p)
            local powerd = Device:getPowerDevice()
            if powerd then powerd:toggleFrontlight() end
            UIManager:scheduleIn(0.3, function() p:refresh() end)
        end,
    },
    night = {
        label = _("Dark mode"), icon = "nerd:EC93", default_on = true,
        active = function() return G_reader_settings:isTrue("night_mode") end,
        run = function(p)
            p:close()
            UIManager:nextTick(function() broadcast("ToggleNightMode") end)
        end,
    },
    rotate = {
        label = _("Rotate"), icon = "nerd:EB74", default_on = true,
        run = function(p)
            p:close()
            UIManager:nextTick(function() broadcast("IterateRotation") end)
        end,
    },
    sleep = {
        label = _("Sleep"), icon = "nerd:EBB1", default_on = false,
        available = function() return Device:canSuspend() end,
        run = function(p)
            p:close()
            UIManager:scheduleIn(0.2, function() broadcast("RequestSuspend") end)
        end,
    },
    screenshot = {
        label = _("Screenshot"), icon = "nerd:F05B", default_on = false,
        run = function(p)
            p:close()
            UIManager:scheduleIn(0.5, function() broadcast("Screenshot") end)
        end,
    },
    search = {
        label = _("Search"), icon = "nerd:EA48", default_on = true,
        run = function(p)
            p:close()
            UIManager:nextTick(function()
                if inReader() then
                    broadcast("ShowFulltextSearchInput")
                else
                    broadcast("ShowFileSearch")
                end
            end)
        end,
    },
    home = {
        label = _("Home"), icon = "nerd:E9DB", default_on = false,
        run = function(p)
            p:close()
            UIManager:nextTick(function()
                local pl = plugin()
                if pl and pl.onSimpleUIGoHomescreen then pl:onSimpleUIGoHomescreen() end
            end)
        end,
    },
    library = {
        label = _("Library"), icon = "nerd:EA30", default_on = false,
        run = function(p)
            p:close()
            UIManager:nextTick(function()
                local pl = plugin()
                if pl and pl.onSimpleUIGoLibrary then pl:onSimpleUIGoLibrary() end
            end)
        end,
    },
    kindleui_settings = {
        label = _("Settings"), icon = "nerd:EB92", default_on = true,
        run = function(p)
            p:close()
            UIManager:nextTick(function()
                require("screens/sui_settings_window"):show()
            end)
        end,
    },
    restart = {
        label = _("Restart"), icon = "nerd:EB52", default_on = false,
        run = function(p)
            p:close()
            confirm(_("Restart KOReader?"), _("Restart"), function() broadcast("Restart") end)
        end,
    },
    exit = {
        label = _("Exit"), icon = "nerd:EB24", default_on = false,
        run = function(p)
            p:close()
            confirm(_("Exit KOReader?"), _("Exit"), function() broadcast("Exit") end)
        end,
    },
}

A.BUILTIN_ORDER = {
    "koreader_menu", "wifi", "frontlight", "night", "rotate", "search", "kindleui_settings",
    "sleep", "screenshot", "home", "library", "restart", "exit",
}

-- ---------------------------------------------------------------------------
-- Custom actions
--   { kind = "koreader", id = <Dispatcher action id> }
--   { kind = "kindleui", id = <quick action id> }
-- ---------------------------------------------------------------------------

local _dispatcher_list

--- KOReader actions that need no extra value, grouped like the gesture menu:
--- { { key = "general", title = "General", items = { {id, title}, … } }, … }
function A.koreaderActions()
    if _dispatcher_list then return _dispatcher_list end
    local ok_d, Dispatcher = pcall(require, "dispatcher")
    if not ok_d or not Dispatcher then return {} end
    pcall(function() Dispatcher:init() end)
    local settingsList, order
    for i = 1, 60 do
        local name, val = debug.getupvalue(Dispatcher.registerAction, i)
        if not name then break end
        if name == "settingsList" then settingsList = val end
        if name == "dispatcher_menu_order" then order = val end
    end
    if type(settingsList) ~= "table" then return {} end
    if type(order) ~= "table" then
        order = {}
        for k in pairs(settingsList) do order[#order + 1] = k end
        table.sort(order)
    end
    local sections = {
        { key = "general",     title = _("General") },
        { key = "device",      title = _("Device") },
        { key = "screen",      title = _("Screen and lights") },
        { key = "filemanager", title = _("File browser") },
        { key = "reader",      title = _("Reader") },
        { key = "rolling",     title = _("Reflowable books") },
        { key = "paging",      title = _("Fixed-layout books") },
    }
    local placed = {}
    for _i, sec in ipairs(sections) do
        sec.items = {}
        for _i, id in ipairs(order) do
            local def = settingsList[id]
            if type(def) == "table" and def[sec.key] and not placed[id]
                    and def.category == "none" and def.title
                    and (def.condition == nil or def.condition == true) then
                placed[id] = true
                sec.items[#sec.items + 1] = { id = id, title = tostring(def.title) }
            end
        end
    end
    local out = {}
    for _i, sec in ipairs(sections) do
        if #sec.items > 0 then out[#out + 1] = sec end
    end
    _dispatcher_list = out
    return out
end

function A.koreaderActionTitle(id)
    for _i, sec in ipairs(A.koreaderActions()) do
        for _i, it in ipairs(sec.items) do
            if it.id == id then return it.title end
        end
    end
    return id
end

--- KoboUI quick actions (built-in ones and the user's own).
function A.kindleuiActions()
    local ok, QA = pcall(require, "features/sui_quickactions")
    if not ok or not QA then return {} end
    local out = {}
    local ok_ids, ids = pcall(QA.allIds)
    if ok_ids and type(ids) == "table" then
        for _i, id in ipairs(ids) do
            local e = QA.getEntry(id)
            if e and e.label and id ~= "current_book" then
                out[#out + 1] = { id = id, title = e.label, icon = e.icon }
            end
        end
    end
    table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    return out
end

function A.actionTitle(action)
    if type(action) ~= "table" then return _("None") end
    if action.kind == "koreader" then return A.koreaderActionTitle(action.id) end
    if action.kind == "kindleui" then
        local ok, QA = pcall(require, "features/sui_quickactions")
        local e = ok and QA.getEntry(action.id)
        return e and e.label or action.id
    end
    if action.kind == "menu" and type(action.path) == "table" then
        -- captured from KOReader's menu
        local t = table.concat(action.path, " \u{203A} ")
        if action.open_submenu then t = t .. " " .. _("(opens menu)") end
        return t
    end
    return _("None")
end

local function runCustom(action)
    if type(action) == "table" and action.kind == "menu" then
        return require("features/quickpanel/qp_capture").run(action)
    end
    if type(action) ~= "table" or not action.id then return end
    if action.kind == "koreader" then
        local Dispatcher = require("dispatcher")
        Dispatcher:execute({ [action.id] = true })
    elseif action.kind == "kindleui" then
        local QA = require("features/sui_quickactions")
        local pl = plugin()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        if pl and fm and not inReader() and pl._onTabTap then
            pl:_onTabTap(action.id, fm)
        else
            QA.execute(action.id, { plugin = pl, fm = fm })
        end
    end
end

--- Runs a stored action ({kind="koreader"|"kindleui", id} or a captured menu action).
function A.runAction(action)
    local ok, err = pcall(runCustom, action)
    if not ok then logger.warn("koboui: action failed:", err) end
    return ok
end

-- ---------------------------------------------------------------------------
-- Button helpers
-- ---------------------------------------------------------------------------

function A.isAvailable(b)
    local def = A.BUILTIN[b.id]
    if def and def.available then
        local ok, v = pcall(def.available)
        return ok and v
    end
    return true
end

function A.label(b)
    if b.label and b.label ~= "" then return b.label end
    local def = A.BUILTIN[b.id]
    if def then return def.label end
    if b.action then return A.actionTitle(b.action) end
    return _("Button")
end

--- The text under the button in the panel (Wi-Fi shows its state).
function A.panelLabel(b)
    local def = A.BUILTIN[b.id]
    if def and def.dynamic_label then
        local ok, t = pcall(def.dynamic_label)
        if ok and type(t) == "string" and t ~= "" then return t end
    end
    return A.label(b)
end

function A.defaultIcon(b)
    local def = A.BUILTIN[b.id]
    if def then return def.icon end
    if b.action and b.action.kind == "kindleui" then
        local ok, QA = pcall(require, "features/sui_quickactions")
        local e = ok and QA.getEntry(b.action.id)
        if e and e.icon then return e.icon end
    end
    return "nerd:EBCD" -- star
end

function A.icon(b)
    return (b.icon and b.icon ~= "") and b.icon or A.defaultIcon(b)
end

function A.isActive(b)
    local def = A.BUILTIN[b.id]
    if def and def.active then
        local ok, v = pcall(def.active)
        return ok and v and true or false
    end
    return false
end

--- Runs a button's action. `panel` is the open quick-settings panel.
function A.run(b, panel)
    local def = A.BUILTIN[b.id]
    if def then
        local ok, err = pcall(def.run, panel)
        if not ok then logger.warn("kindleui quick settings: button failed:", b.id, err) end
        return
    end
    panel:close()
    UIManager:nextTick(function()
        local ok, err = pcall(runCustom, b.action)
        if not ok then logger.warn("kindleui quick settings: custom action failed:", err) end
    end)
end

return A
