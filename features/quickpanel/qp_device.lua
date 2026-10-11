--[[--
qp_device.lua — KoboUI quick settings: the name shown at the top of the
panel ("Lina's Kindle").

Order:
  1. the name typed in KoboUI settings (Quick Settings → Device name);
  2. on a Kindle, the name it was registered with, if it can be found in
     the Kindle's own registration files (best effort, read once);
  3. "Kindle" on a Kindle, otherwise KOReader's model name.
--]]--

local Device = require("device")
local _      = require("infra/sui_i18n").translate

local M = {}

local _found -- cached result of the Kindle lookup (false = nothing found)

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function lookupKindleName()
    if _found ~= nil then return _found or nil end
    _found = false
    if not (Device.isKindle and Device:isKindle()) then return nil end
    local candidates = {
        "/var/local/java/prefs/reginfo",
        "/var/local/java/prefs/com.amazon.ebook.framework/prefs",
        "/var/local/appreg.db.name",
    }
    for _i, path in ipairs(candidates) do
        local ok, txt = pcall(readFile, path)
        if ok and txt and #txt > 0 then
            local name = txt:match("<user_device_name>%s*(.-)%s*</user_device_name>")
                or txt:match("<device_name>%s*(.-)%s*</device_name>")
                or txt:match("<deviceName>%s*(.-)%s*</deviceName>")
                or txt:match("[Dd]evice[_ ]?[Nn]ame%s*[=:]%s*([^\r\n]+)")
            if name and name ~= "" then
                _found = name
                return name
            end
        end
    end
    return nil
end

function M.defaultName()
    local n = lookupKindleName()
    if n then return n end
    if Device.isKindle and Device:isKindle() then return _("Kindle") end
    return Device.model or "KOReader"
end

function M.name()
    local Store = require("features/quickpanel/qp_store")
    local custom = Store.get("device_name")
    if type(custom) == "string" and custom:match("%S") then return custom end
    return M.defaultName()
end

return M
