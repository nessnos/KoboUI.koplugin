--[[--
kbo_wifi_eap.lua — KoboUI

Wi-Fi networks that ask for a username *and* a password (WPA2/WPA3-Enterprise,
802.1X / EAP: work, school, eduroam…). KOReader itself only knows networks
with a single password (WPA-PSK) or none.

What this adds (Kobo / wpa_supplicant only):
  * M.isEnterprise(n)          — the scan flags say EAP.
  * M.saveLogin(n, user, pw)   — kept in KOReader's network.lua next to the
                                 other saved networks (keys kbo_identity,
                                 kbo_eap_password, kbo_eap).
  * M.install()                — wraps NetworkMgr:getNetworkList() so a saved
                                 enterprise network comes back with its login,
                                 and NetworkMgr:authenticateNetwork() so such a
                                 network is joined with EAP. Because KOReader's
                                 own code goes through these two, its automatic
                                 reconnect (and its network list) works with
                                 these networks too, not only KoboUI's panel.

The EAP method isn't in the scan result, so the common ones are tried in turn
and the one that works is remembered: PEAP/MSCHAPv2, TTLS/MSCHAPv2, TTLS/PAP.
No CA certificate is set (wpa_supplicant then accepts the server's), which is
what most phones do when you just type a username and password.
--]]--

local logger = require("logger")

local M = {}

M.METHODS = {
    { id = "peap",      eap = "PEAP", phase2 = "auth=MSCHAPV2" },
    { id = "ttls_mschap", eap = "TTLS", phase2 = "auth=MSCHAPV2" },
    { id = "ttls_pap",  eap = "TTLS", phase2 = "auth=PAP" },
}

local function NM()
    local ok, nm = pcall(require, "ui/network/manager")
    return ok and nm or nil
end

function M.isEnterprise(n)
    local f = n and n.flags and tostring(n.flags) or ""
    return f:find("EAP") ~= nil
end

local function savedTable()
    local nm = NM()
    local ok, s = pcall(function() return nm:getAllSavedNetworks() end)
    return ok and s or nil
end

--- The saved login for this ssid, or nil.
function M.savedLogin(ssid)
    local s = savedTable()
    local e = s and s:readSetting(ssid)
    if type(e) == "table" and e.kbo_identity then
        return { identity = e.kbo_identity, password = e.kbo_eap_password, method = e.kbo_eap }
    end
end

function M.saveLogin(n, identity, password, method)
    local s = savedTable()
    if not s then return end
    s:saveSetting(n.ssid, {
        ssid = n.ssid,
        flags = n.flags,
        -- KOReader only tries networks that have a password: keep one here
        -- (it is the EAP password; authenticateNetwork below knows what to do).
        password = password,
        kbo_identity = identity,
        kbo_eap_password = password,
        kbo_eap = method,
    })
    s:flush()
    n.password, n.psk = password, nil
    n.kbo_identity, n.kbo_eap_password, n.kbo_eap = identity, password, method
end

local function rememberMethod(ssid, method)
    local s = savedTable()
    local e = s and s:readSetting(ssid)
    if type(e) == "table" and e.kbo_identity and e.kbo_eap ~= method then
        e.kbo_eap = method
        s:saveSetting(ssid, e)
        s:flush()
    end
end

-- wpa_supplicant wants strings either quoted or (for most fields) in hex.
local function quote(s)
    return '"' .. tostring(s or ""):gsub("[\r\n]", "") .. '"'
end

local function decodeSSID(ssid)
    if type(ssid) ~= "string" then return ssid end
    local d = ssid:gsub("%f[\\]\\x(%x%x)", function(b)
        local c = string.char(tonumber(b, 16))
        return c == "\\" and "\\\\" or c
    end)
    return (d:gsub("\\\\", "\\"))
end

--- One try with one EAP method. Returns success, message.
local function tryMethod(nm, network, method)
    local WpaClient = require("lj-wpaclient/wpaclient")
    local bin_to_hex = require("ffi/sha2").bin_to_hex
    local wcli, err = WpaClient.new(nm.wpa_supplicant.ctrl_interface)
    if not wcli then return false, tostring(err) end

    local nw_id
    nw_id, err = wcli:addNetwork()
    if nw_id == nil then wcli:close(); return false, tostring(err) end

    local function set(key, value)
        local reply, e = wcli:setNetwork(nw_id, key, value)
        if reply == nil or reply == "FAIL" then
            error(string.format("wpa_supplicant refused %s (%s)", key, tostring(e or reply)), 0)
        end
    end
    local ok_set, set_err = pcall(function()
        set("ssid", bin_to_hex(network.ssid))
        set("key_mgmt", "WPA-EAP")
        set("eap", method.eap)
        set("identity", bin_to_hex(network.kbo_identity))
        set("password", quote(network.kbo_eap_password))
        set("phase2", quote(method.phase2))
    end)
    if not ok_set then
        wcli:removeNetwork(nw_id)
        wcli:close()
        return false, set_err
    end
    wcli:enableNetworkByID(nw_id)
    wcli:attach()

    local success, msg = false, nil
    local tries, failures = 0, 0
    while tries < 25 do
        local connected = wcli:getConnectedNetwork()
        if connected then
            network.wpa_supplicant_id = connected.id
            network.ssid = decodeSSID(connected.ssid) or network.ssid
            success = true
            break
        end
        local ev = wcli:readEvent()
        if ev ~= nil then
            local m = ev.msg or ""
            if ev:isAuthSuccessful() then
                network.wpa_supplicant_id = nw_id
                success = true
                break
            elseif m:find("^CTRL%-EVENT%-EAP%-FAILURE") then
                msg = "eap-failure"
                break
            elseif ev:isAuthFailed() then
                failures = failures + 1
                if failures > 3 then msg = "failed"; break end
            end
        else
            wcli:waitForEvent(1000)
            tries = tries + 1
        end
    end
    if not success then wcli:removeNetwork(nw_id) end
    wcli:close()
    return success, msg or (success and "ok" or "timeout")
end

--- Joins an enterprise network (network.kbo_identity / kbo_eap_password set).
function M.authenticate(nm, network)
    local order = {}
    for _i, m in ipairs(M.METHODS) do
        if m.id == network.kbo_eap then table.insert(order, 1, m) else order[#order + 1] = m end
    end
    for _i, m in ipairs(order) do
        local ok, res = pcall(tryMethod, nm, network, m)
        if ok and res == true then
            network.kbo_eap = m.id
            rememberMethod(network.ssid, m.id)
            return true, "Authenticated"
        end
        if not ok then logger.warn("koboui: EAP attempt error:", res) end
        logger.dbg("koboui: EAP", m.id, "failed on", network.ssid)
    end
    local _ = require("infra/sui_i18n").translate
    return false, _("Wrong username or password, or this network uses a sign-in KoboUI can't do.")
end

local _installed = false
function M.install()
    if _installed then return end
    local nm = NM()
    if not (nm and nm.wpa_supplicant and nm.getNetworkList and nm.authenticateNetwork) then return end
    _installed = true

    local orig_list = nm.getNetworkList
    nm.getNetworkList = function(self, ...)
        local list, err = orig_list(self, ...)
        if type(list) == "table" then
            for _i, n in ipairs(list) do
                if M.isEnterprise(n) then
                    local login = M.savedLogin(n.ssid)
                    if login then
                        n.kbo_identity, n.kbo_eap_password, n.kbo_eap = login.identity, login.password, login.method
                        n.password, n.psk = login.password, nil
                    end
                end
            end
        end
        return list, err
    end

    local orig_auth = nm.authenticateNetwork
    nm.authenticateNetwork = function(self, network, ...)
        if M.isEnterprise(network) then
            if not network.kbo_identity then
                local login = M.savedLogin(network.ssid)
                if login then
                    network.kbo_identity, network.kbo_eap_password, network.kbo_eap = login.identity, login.password, login.method
                end
            end
            if network.kbo_identity then
                return M.authenticate(self, network)
            end
        end
        return orig_auth(self, network, ...)
    end
end

return M
