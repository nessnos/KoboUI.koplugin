--[[--
kbo_panels.lua — KoboUI

What the status-bar drop-downs hold (screens/kbo_statusbar.lua opens them,
screens/kbo_dropdown.lua draws them):

  Light      Brightness slider (value above the knob); Natural light slider
             (sun → moon) with an AUTO switch when KOReader's Auto warmth
             plugin is there; Dark mode switch.
  Wi-Fi      WI-FI: ENABLED switch; turning it on happens inside the panel
             ("Turning on Wi-Fi…", "Looking for networks…", "Connecting to
             X…") instead of KOReader's pop-ups: a saved network is joined on
             its own, else the networks around are listed — tap one to join
             (a password box opens for a new locked one, a username +
             password box for work/school "Enterprise" networks — see
             infra/kbo_wifi_eap.lua; long-press to type them again). Wi-Fi Settings (KOReader's Network menu).
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
-- What the panel is doing, shown in its rows instead of KOReader's pop-ups:
--   nil | "turning_on" | "scanning" | "connecting" | "failed"
local _wifi = { state = nil, target = nil, msg = nil }
local _failed = {}        -- ssid -> true: the last try failed (tap asks the password again)
local _pending_cb         -- KOReader's "connected" callback, while we wait for the user to pick

local function NM()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        pcall(function() require("infra/kbo_wifi_eap").install() end)
    end
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

local function isLocked(n)
    local f = n and n.flags and tostring(n.flags) or ""
    return f:find("WPA") ~= nil or f:find("WEP") ~= nil or f:find("SAE") ~= nil
end

local function sortNets(list)
    table.sort(list, function(a, b) return (a.signal_quality or 0) > (b.signal_quality or 0) end)
end

--- Runs fn while KOReader's own "Scanning…", "Authenticating…", "Connected"
--- pop-ups are kept off the screen: the drop-down shows those steps instead.
local function quiet(fn, ...)
    local InfoMessage = require("ui/widget/infomessage")
    local function isInfo(w)
        local mt = type(w) == "table" and getmetatable(w)
        local guard = 0
        while mt and guard < 10 do
            if mt == InfoMessage then return true end
            mt = getmetatable(mt)
            guard = guard + 1
        end
        return false
    end
    local hidden = setmetatable({}, { __mode = "k" })
    local orig_show, orig_close = UIManager.show, UIManager.close
    UIManager.show = function(self, w, ...)
        if isInfo(w) then hidden[w] = true; return end
        return orig_show(self, w, ...)
    end
    UIManager.close = function(self, w, ...)
        if hidden[w] then hidden[w] = nil; return end
        return orig_close(self, w, ...)
    end
    local res = { n = 0 }
    local function pack(...) res = { n = select("#", ...), ... } end
    pack(pcall(fn, ...))
    UIManager.show, UIManager.close = orig_show, orig_close
    if not res[1] then
        logger.warn("koboui: Wi-Fi step failed:", res[2])
        return nil, tostring(res[2])
    end
    return (table.unpack or unpack)(res, 2, res.n)
end

--- Rebuilds the panel and paints it now (the next steps block the UI).
local function show(dd, state, target, msg)
    _wifi.state, _wifi.target, _wifi.msg = state, target, msg
    if dd and not dd._closed then
        dd:refresh()
        UIManager:forceRePaint()
    end
end

local function refreshTopbar()
    pcall(function() require("screens/sui_topbar").scheduleRefreshAll() end)
end

local function scan(dd)
    if _scanning or not wifiOn() then return end
    _scanning = true
    dd:refresh()
    UIManager:scheduleIn(0.2, function()
        local nm = NM()
        local list = nm and quiet(nm.getNetworkList, nm)
        _scanning = false
        if type(list) == "table" then
            sortNets(list)
            _nets = list
        end
        if not dd._closed then dd:refresh() end
    end)
end

--- Connected: get an address and let KOReader know (status icon, sync plugins…).
local function finishConnect(dd, ssid, cb)
    local nm = NM()
    show(dd, "connecting", ssid)
    quiet(nm.obtainIP, nm)
    nm.lease_ssid = ssid
    _failed[ssid] = nil
    for _i, n in ipairs(_nets or {}) do n.connected = (n.ssid == ssid) or nil end
    if cb then
        pcall(cb)
    else
        pcall(nm.scheduleConnectivityCheck, nm)
    end
    show(dd, nil)
    refreshTopbar()
end

--- Takes the place of KOReader's reconnectOrShowNetworkMenu while the panel
--- turns Wi-Fi on: scan, join the network wpa_supplicant joined or a saved
--- one, else leave the list in the panel for the user to pick from.
local function panelReconnect(dd, cb)
    local nm = NM()
    show(dd, "scanning")
    local list, err = quiet(nm.getNetworkList, nm)
    if type(list) == "table" and #list == 0 then list, err = quiet(nm.getNetworkList, nm) end
    if type(list) ~= "table" then
        _nets = {}
        _pending_cb = cb
        show(dd, "failed", nil, err or _("Couldn't scan for networks."))
        return nil
    end
    sortNets(list)
    _nets = list
    local ssid
    for _i, n in ipairs(list) do
        if n.connected then ssid = n.ssid; break end
    end
    if not ssid then
        for _i, n in ipairs(list) do
            if n.password then
                show(dd, "connecting", n.ssid)
                local ok = quiet(nm.authenticateNetwork, nm, n)
                if ok then ssid = n.ssid; n.connected = true; break end
            end
        end
    end
    if not ssid and Device:hasWifiManager() then
        -- wpa_supplicant may still join a network it knows on its own (15 s max, like KOReader)
        local conf = quiet(nm.getConfiguredNetworks, nm)
        if type(conf) == "table" and #conf > 0 then
            show(dd, "connecting")
            local ffiutil = require("ffi/util")
            for _i = 1, 60 do
                ffiutil.usleep(250 * 1000)
                local nw = quiet(nm.getCurrentNetwork, nm)
                if type(nw) == "table" and nw.ssid then ssid = nw.ssid; break end
            end
        end
    end
    if ssid then
        finishConnect(dd, ssid, cb)
        return true
    end
    -- Nothing saved around: the networks are listed in the panel.
    _pending_cb = cb
    show(dd, nil)
    return nil
end

local function turnOn(dd)
    local nm = NM()
    if not nm then return end
    _nets = nil
    show(dd, "turning_on")
    UIManager:scheduleIn(0.05, function()
        local orig = rawget(nm, "reconnectOrShowNetworkMenu")
        local hooked = false
        nm.reconnectOrShowNetworkMenu = function(_self, cb)
            hooked = true
            return panelReconnect(dd, cb)
        end
        local status = quiet(nm.enableWifi, nm, nil, false)
        nm.reconnectOrShowNetworkMenu = orig
        if not hooked then
            -- Platforms that don't scan when Wi-Fi turns on (or a connection
            -- attempt still running): look for networks once it's up.
            show(dd, status == nil and "failed" or nil, nil,
                status == nil and _("A previous connection attempt is still running.") or nil)
            UIManager:scheduleIn(2.5, function()
                if not dd._closed then dd:refresh(); scan(dd) end
            end)
        elseif status == false then
            show(dd, "failed", nil, _("Couldn't turn on Wi-Fi."))
        end
        refreshTopbar()
    end)
end

local function turnOff(dd)
    local nm = NM()
    if not nm then return end
    _nets, _pending_cb = nil, nil
    _wifi.state, _wifi.target, _wifi.msg = nil, nil, nil
    quiet(nm.disableWifi, nm, nil, true)
    refreshTopbar()
    UIManager:scheduleIn(1, function() if not dd._closed then dd:refresh() end end)
end

local function doConnect(dd, n)
    local nm = NM()
    show(dd, "connecting", n.ssid)
    UIManager:scheduleIn(0.05, function()
        for _i, c in ipairs(_nets or {}) do
            if c.connected then
                quiet(nm.disconnectNetwork, nm, c)
                quiet(nm.releaseIP, nm)
                c.connected = nil
            end
        end
        local ok, err = quiet(nm.authenticateNetwork, nm, n)
        if ok then
            local cb = _pending_cb
            _pending_cb = nil
            n.connected = true
            finishConnect(dd, n.ssid, cb)
        else
            _failed[n.ssid] = true
            show(dd, "failed", n.ssid, type(err) == "string" and err ~= "" and err or _("Connection failed"))
        end
    end)
end

local function askPassword(dd, n)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = n.ssid,
        input = n.password or "",
        input_hint = _("Password"),
        text_type = "password",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Connect"), is_enter_default = true, callback = function()
                local pw = dlg:getInputText()
                if not pw or pw == "" then return end
                UIManager:close(dlg)
                if pw ~= n.password then
                    n.password, n.psk = pw, nil
                    pcall(function() NM():saveNetwork(n) end)
                end
                doConnect(dd, n)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- Work / school networks: username and password (WPA-Enterprise, EAP).
local function askLogin(dd, n)
    local EAP = require("infra/kbo_wifi_eap")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local login = EAP.savedLogin(n.ssid) or {}
    local dlg
    dlg = MultiInputDialog:new{
        title = n.ssid,
        fields = {
            { text = n.kbo_identity or login.identity or "", hint = _("Username") },
            { text = n.kbo_eap_password or login.password or "", hint = _("Password"), text_type = "password" },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Connect"), is_enter_default = true, callback = function()
                local f = dlg:getFields()
                local user, pw = f[1], f[2]
                if not user or user == "" or not pw or pw == "" then return end
                UIManager:close(dlg)
                EAP.saveLogin(n, user, pw, login.method)
                doConnect(dd, n)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function connectTo(dd, n, ask)
    if (n.connected and not ask) or _wifi.state == "connecting" then return true end
    if tostring(n.flags or ""):find("WEP") then
        show(dd, "failed", n.ssid, _("Networks with WEP encryption are not supported."))
        return true
    end
    local EAP = require("infra/kbo_wifi_eap")
    if EAP.isEnterprise(n) then
        if not ask and not _failed[n.ssid] and (n.kbo_identity or EAP.savedLogin(n.ssid)) then
            doConnect(dd, n)
        else
            askLogin(dd, n)
        end
    elseif not isLocked(n) then
        n.password = n.password or ""
        doConnect(dd, n)
    elseif ask or not n.password or _failed[n.ssid] then
        askPassword(dd, n)
    else
        doConnect(dd, n)
    end
    return true
end

local function wifiRows(dd)
    local rows = {}
    local on = wifiOn()
    local st = _wifi.state
    rows[#rows + 1] = D.switchHeader{
        label_on = _("WI-FI: ENABLED"), label_off = _("WI-FI: DISABLED"),
        get = function() return st == "turning_on" or wifiOn() end,
        set = function(v)
            if _wifi.state == "turning_on" or _wifi.state == "scanning" or _wifi.state == "connecting" then return end
            if v then turnOn(dd) else turnOff(dd) end
        end,
    }
    local function status(text)
        rows[#rows + 1] = D.itemRow{ text = text, face = "italic", dim = true }
    end
    local T = require("ffi/util").template
    if st == "turning_on" then
        status(_("Turning on Wi-Fi…"))
    elseif on then
        if st == "scanning" or _scanning then
            status(_("Looking for networks…"))
        elseif st == "connecting" then
            status(_wifi.target and T(_("Connecting to %1…"), _wifi.target) or _("Connecting…"))
        elseif st == "failed" then
            rows[#rows + 1] = D.textRow(_wifi.target
                and T(_("Couldn't connect to %1. %2"), _wifi.target, _wifi.msg or "")
                or (_wifi.msg or _("Connection failed")),
                { face = "italic", color = require("ffi/blitbuffer").COLOR_GRAY_5, sep = true,
                  pad_top = S(14), pad_bot = S(14) })
        end
        local cur = currentSSID()
        local shown, seen = 0, {}
        local BB = require("ffi/blitbuffer")
        local function add(n, connected)
            local ssid = n.ssid
            if not ssid or ssid == "" or seen[ssid] or shown >= 6 then return end
            seen[ssid] = true
            shown = shown + 1
            rows[#rows + 1] = D.itemRow{
                text = ssid, icon = "wifi", lock = isLocked(n), bold = connected,
                icon_color = (n.signal_quality or 100) >= 40 and BB.COLOR_BLACK or BB.COLOR_GRAY_9,
                right = connected and "\u{2713}" or nil,
                tap = function(d) return connectTo(d, n) end,
                -- long-press: type the password again (e.g. it changed)
                hold = isLocked(n) and function(d) return connectTo(d, n, true) end or nil,
            }
        end
        if cur then
            local cn
            for _i, n in ipairs(_nets or {}) do if n.ssid == cur then cn = n end end
            add(cn or { ssid = cur, signal_quality = 100 }, true)
        end
        for _i, n in ipairs(_nets or {}) do add(n, n.connected or n.ssid == cur) end
        if shown == 0 and not (st == "scanning" or _scanning or st == "connecting") then
            rows[#rows + 1] = D.itemRow{ text = _("No networks found. Tap to look again."),
                face = "italic", tap = function(d) scan(d); return true end }
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
            on_open = function(dd)
                local st = _wifi.state
                if st ~= "turning_on" and st ~= "scanning" and st ~= "connecting" then
                    _wifi.state, _wifi.target, _wifi.msg = nil, nil, nil
                end
                if not _nets then scan(dd) end
            end,
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
