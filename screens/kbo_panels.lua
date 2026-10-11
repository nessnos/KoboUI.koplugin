--[[--
kbo_panels.lua — KoboUI

What the status-bar drop-downs hold (screens/kbo_statusbar.lua opens them,
screens/kbo_dropdown.lua draws them):

  Light      Brightness slider (value above the knob); Natural light slider
             (sun → moon) with an AUTO switch when KOReader's Auto warmth
             plugin is there; Dark mode switch.
  Wi-Fi      WI-FI: ENABLED switch; the networks around (scanned when the
             panel opens; tap one to connect in KOReader's network list);
             Wi-Fi Settings (KOReader's Network menu).
  Bluetooth  the action you chose for it (KOReader has no Bluetooth on Kobo).
  Battery    "eReader: 33%"; Energy saving settings; Battery statistics.
  Sync       "Sync now" runs the action you chose (e.g. a sync plugin captured
             from KOReader's menu) and remembers when; Check for software
             updates (KOReader's updater).
--]]--

local Device    = require("device")
local Event     = require("ui/event")
local UIManager = require("ui/uimanager")
local logger    = require("logger")
local Screen    = Device.screen
local _         = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")
local D = require("screens/kbo_dropdown")

local M = {}

local function S(n) return Screen:scaleBySize(n) end
local function sw() return Screen:getWidth() end

local function closeThen(dd, fn)
    dd:close()
    UIManager:nextTick(function()
        local ok, err = pcall(fn)
        if not ok then logger.warn("koboui: status bar action failed:", err) end
    end)
    return true
end

--- Opens KOReader's menu at a submenu (by menu id, else by its text).
local function openMenuAt(root_id, path)
    local Capture = require("features/quickpanel/qp_capture")
    Capture.openMenuAt({ kind = "menu", root_id = root_id, path = path, open_submenu = true })
end

local function fmInstance()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

-- ---------------------------------------------------------------------------
-- Light
-- ---------------------------------------------------------------------------
local function autowarmthAvailable()
    local fm = fmInstance()
    return Device:hasNaturalLight() and fm and fm.autowarmth ~= nil
end

local function lightRows(dd)
    local rows = {}
    local powerd = Device:getPowerDevice()
    if Device:hasFrontlight() and powerd then
        rows[#rows + 1] = D.titleRow(_("Brightness"), { height = S(56) })
        rows[#rows + 1] = D.sliderRow{
            min = powerd.fl_min or 0, max = powerd.fl_max or 100, fmt = "%d%%",
            left_icon = "sun", right_icon = "sun", right_big = true, sep = true,
            get = function()
                if not powerd:isFrontlightOn() then return powerd.fl_min or 0 end
                return powerd:frontlightIntensity()
            end,
            set = function(v)
                if v <= (powerd.fl_min or 0) then
                    powerd:setIntensity(powerd.fl_min or 0)
                    powerd:turnOffFrontlight()
                else
                    powerd:setIntensity(v)
                    if not powerd:isFrontlightOn() then powerd:turnOnFrontlight() end
                end
            end,
        }
    end
    if Device:hasNaturalLight() and powerd then
        local native = powerd.toNativeWarmth and powerd.fromNativeWarmth and powerd.fl_warmth_max ~= nil
        local wmin = native and (powerd.fl_warmth_min or 0) or 0
        local wmax = native and powerd.fl_warmth_max or 100
        local auto
        if autowarmthAvailable() then
            auto = {
                label = _("AUTO"),
                get = function() return (G_reader_settings:readSetting("autowarmth_activate") or 0) ~= 0 end,
                set = function(on)
                    if on then
                        local mode = SUISettings:readSetting("koboui_autowarmth_mode") or 1
                        UIManager:broadcastEvent(Event:new("AutoWarmthMode", mode))
                    else
                        local cur = G_reader_settings:readSetting("autowarmth_activate") or 0
                        if cur ~= 0 then SUISettings:saveSetting("koboui_autowarmth_mode", cur) end
                        UIManager:broadcastEvent(Event:new("AutoWarmthOff"))
                    end
                end,
            }
        end
        rows[#rows + 1] = D.titleRow(_("Natural light"), { height = S(60), switch = auto })
        rows[#rows + 1] = D.sliderRow{
            min = wmin, max = wmax, left_icon = "sun", right_icon = "moon", sep = true,
            get = function()
                local w = powerd:frontlightWarmth()
                return native and powerd:toNativeWarmth(w) or w
            end,
            set = function(v)
                v = math.max(wmin, math.min(wmax, math.floor(v + 0.5)))
                powerd:setWarmth(native and powerd:fromNativeWarmth(v) or v)
            end,
        }
    end
    rows[#rows + 1] = D.titleRow(_("Dark mode"), {
        height = S(66),
        switch = {
            get = function() return G_reader_settings:isTrue("night_mode") end,
            set = function()
                UIManager:nextTick(function()
                    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
                end)
            end,
        },
    })
    return rows
end

-- ---------------------------------------------------------------------------
-- Wi-Fi
-- ---------------------------------------------------------------------------
local _nets       -- last scan result
local _scanning = false

local function NM()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr or nil
end

local function wifiOn()
    local nm = NM()
    if not nm then return false end
    local ok, on = pcall(nm.isWifiOn, nm)
    return ok and on or false
end

local function currentSSID()
    local nm = NM()
    if not nm then return nil end
    local ok_c, connected = pcall(nm.isConnected, nm)
    if not (ok_c and connected) then return nil end
    local ok_n, nw = pcall(nm.getCurrentNetwork, nm)
    local ssid = ok_n and type(nw) == "table" and (nw.ssid or nw.essid)
    return type(ssid) == "string" and ssid ~= "" and ssid or nil
end

local function scan(dd)
    if _scanning or not wifiOn() then return end
    _scanning = true
    dd:refresh()
    UIManager:scheduleIn(0.2, function()
        local nm = NM()
        local ok, list = pcall(function() return nm and nm:getNetworkList() end)
        _scanning = false
        if ok and type(list) == "table" then
            table.sort(list, function(a, b) return (a.signal_quality or 0) > (b.signal_quality or 0) end)
            _nets = list
        end
        if not dd._closed then dd:refresh() end
    end)
end

local function wifiRows(dd)
    local rows = {}
    local on = wifiOn()
    rows[#rows + 1] = D.switchHeader{
        label_on = _("WI-FI: ENABLED"), label_off = _("WI-FI: DISABLED"),
        get = wifiOn,
        set = function()
            UIManager:broadcastEvent(Event:new("ToggleWifi"))
            _nets = nil
            UIManager:scheduleIn(1.5, function() if not dd._closed then dd:refresh() end end)
            UIManager:scheduleIn(6, function() if not dd._closed then scan(dd) end end)
        end,
    }
    if on then
        local cur = currentSSID()
        local shown, seen = 0, {}
        local function add(ssid, quality, locked, connected)
            if not ssid or seen[ssid] or shown >= 5 then return end
            seen[ssid] = true
            shown = shown + 1
            rows[#rows + 1] = D.itemRow{
                text = ssid, icon = "wifi", lock = locked, bold = connected,
                icon_color = (quality or 100) >= 40 and require("ffi/blitbuffer").COLOR_BLACK
                    or require("ffi/blitbuffer").COLOR_GRAY_9,
                right = connected and "\u{2713}" or nil,
                tap = function(d)
                    if connected then return true end
                    return closeThen(d, function()
                        local nm = NM()
                        if _nets and #_nets > 0 then
                            UIManager:show(require("ui/widget/networksetting"):new{
                                network_list = _nets,
                                connect_callback = function()
                                    local Topbar = require("screens/sui_topbar")
                                    pcall(Topbar.invalidateDimCache)
                                end,
                            })
                        elseif nm then
                            nm:reconnectOrShowNetworkMenu(nil, true)
                        end
                    end)
                end,
            }
        end
        local function isLocked(n)
            local f = n and n.flags and tostring(n.flags) or ""
            return f:find("WPA") ~= nil or f:find("WEP") ~= nil or f:find("SAE") ~= nil
        end
        if cur then
            local cn
            for _i, n in ipairs(_nets or {}) do if n.ssid == cur then cn = n end end
            add(cur, cn and cn.signal_quality or 100, cn and isLocked(cn) or false, true)
        end
        for _i, n in ipairs(_nets or {}) do
            add(n.ssid, n.signal_quality, isLocked(n), n.connected or n.ssid == cur)
        end
        if _scanning then
            rows[#rows + 1] = D.itemRow{ text = _("Looking for networks…"), face = "italic", dim = true, sep = false }
        elseif shown == 0 then
            rows[#rows + 1] = D.itemRow{ text = _("No networks found"), face = "italic", dim = true, sep = false }
        end
    end
    rows[#rows].sep = true
    rows[#rows + 1] = D.linkRow(_("Wi-Fi Settings"), function(d)
        return closeThen(d, function() openMenuAt("network", { _("Network") }) end)
    end)
    return rows
end

-- ---------------------------------------------------------------------------
-- Bluetooth
-- ---------------------------------------------------------------------------
local function btRows(dd)
    local SB = require("screens/kbo_statusbar")
    local Actions = require("features/quickpanel/qp_actions")
    local rows = {}
    local action = SB.btAction()
    rows[#rows + 1] = D.titleRow(_("Bluetooth"), { sep = true })
    if action then
        rows[#rows + 1] = D.itemRow{ text = Actions.actionTitle(action), sep = true,
            tap = function(d) return closeThen(d, function() Actions.runAction(action) end) end }
    else
        rows[#rows + 1] = D.textRow(_("KOReader doesn't control Bluetooth on this device. You can give this icon an action (for example a Bluetooth plugin's menu)."),
            { face = "small", sep = true })
    end
    rows[#rows + 1] = D.linkRow(_("Bluetooth Settings"), function(d)
        return closeThen(d, function() require("screens/sui_topbar").showSettings() end)
    end)
    return rows
end

-- ---------------------------------------------------------------------------
-- Battery
-- ---------------------------------------------------------------------------
local function batteryRows(dd)
    local rows = {}
    local powerd = Device:getPowerDevice()
    local lvl, charging = "?", false
    pcall(function() lvl = powerd:getCapacity(); charging = powerd:isCharging() end)
    local text = string.format(_("eReader: %s%%"), tostring(lvl))
    if charging then text = text .. "  \u{00B7}  " .. _("Charging") end
    rows[#rows + 1] = D.itemRow{ text = text, face = "body", height = S(70) }
    rows[#rows + 1] = D.linkRow(_("Energy saving settings"), function(d)
        return closeThen(d, function() openMenuAt("device", { _("Device") }) end)
    end, { sep = true })
    local fm = fmInstance()
    if fm and fm.batterystat then
        rows[#rows + 1] = D.linkRow(_("Battery statistics"), function(d)
            return closeThen(d, function() UIManager:broadcastEvent(Event:new("ShowBatteryStatistics")) end)
        end)
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- Sync
-- ---------------------------------------------------------------------------
local function lastSyncText()
    local t = SUISettings:readSetting("koboui_last_sync")
    if not t then return _("LAST SYNC: NEVER") end
    local datetime = require("datetime")
    local hm = datetime.secondsToHour(t, G_reader_settings:isTrue("twelve_hour_clock"))
    if os.date("%Y%m%d", t) ~= os.date("%Y%m%d") then
        hm = os.date("%d/%m ", t) .. hm
    end
    return string.format(_("LAST SYNC: %s"), hm)
end

local function syncRows(dd)
    local SB = require("screens/kbo_statusbar")
    local Actions = require("features/quickpanel/qp_actions")
    local rows = {}
    local action = SB.syncAction()
    rows[#rows + 1] = D.textRow(action
        and string.format(_("Sync runs: %s"), Actions.actionTitle(action))
        or _("Sync to download new items. Choose what Sync does in the status bar settings."),
        { face = "body", pad_bot = S(4) })
    if action then
        rows[#rows + 1] = D.buttonRow(_("Sync now"), function(d)
            return closeThen(d, function()
                SUISettings:saveSetting("koboui_last_sync", os.time())
                Actions.runAction(action)
            end)
        end, lastSyncText())
    else
        rows[#rows + 1] = D.buttonRow(_("Set up Sync"), function(d)
            return closeThen(d, function() require("screens/sui_topbar").showSettings() end)
        end)
    end
    rows[#rows].sep = true
    rows[#rows + 1] = D.linkRow(_("Check for software updates"), function(d)
        return closeThen(d, function()
            local ok, OTA = pcall(require, "ui/otamanager")
            if ok and OTA then OTA:fetchAndProcessUpdate() end
        end)
    end)
    return rows
end

-- ---------------------------------------------------------------------------
function M.spec(key)
    local w = sw()
    if key == "brightness" then
        return { width = math.floor(w * 0.56), build = lightRows,
            on_close = function()
                pcall(function() require("screens/sui_topbar").scheduleRefreshAll() end)
            end }
    elseif key == "wifi" then
        return { width = math.floor(w * 0.62), build = wifiRows,
            on_open = function(dd) if not _nets then scan(dd) end end,
            on_close = function()
                pcall(function() require("screens/sui_topbar").scheduleRefreshAll() end)
            end }
    elseif key == "bluetooth" then
        return { width = math.floor(w * 0.6), build = btRows }
    elseif key == "battery" then
        return { width = math.floor(w * 0.46), build = batteryRows }
    elseif key == "search" then
        return { width = math.floor(w * 0.5), build = function()
            return { D.linkRow(_("Search the library"), function(dd)
                return closeThen(dd, function()
                    local fm = fmInstance()
                    require("features/sui_quickactions").execute("search_library", { plugin = fm and fm.simpleui, fm = fm })
                end)
            end) }
        end }
    elseif key == "sync" then
        return { width = math.floor(w * 0.5), build = syncRows }
    end
end

return M
