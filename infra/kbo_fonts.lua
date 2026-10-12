--[[--
kbo_fonts.lua — KoboUI

Kobo sets its small "data" text in a sans-serif, in capitals: "5 HOURS TO GO",
"12 BOOKS", "PAGE 3 OF 10", the navigation bar and the Library tabs. Every
other text keeps the UI font (KOReader's, or the one chosen under
Settings → Style → UI Font).

Setting koboui_label_font:
  nil / "noto"  — KOReader's own sans-serif UI font, Noto Sans (default);
  <family>      — any installed font family.
--]]--

local Font        = require("ui/font")
local SUISettings = require("infra/sui_store")
local _           = require("infra/sui_i18n").translate

local M = {}
M.KEY = "koboui_label_font"

local NOTO = { regular = "noto/NotoSans-Regular.ttf", bold = "noto/NotoSans-Bold.ttf", name = "Noto Sans" }

local _resolved
function M.invalidate() _resolved = nil end

local function families()
    local ok, SUIStyle = pcall(require, "features/sui_style")
    if ok and SUIStyle and SUIStyle.fontFamilies then return SUIStyle.fontFamilies() end
    return {}, {}
end

local function resolve()
    if _resolved then return _resolved end
    local want = SUISettings:readSetting(M.KEY) or "noto"
    local list, map = families()
    local name
    if want ~= "noto" and want ~= "auto" and map[want] then name = want end
    if name and map[name] then
        _resolved = { regular = map[name].regular, bold = map[name].bold or map[name].regular, name = name }
    else
        _resolved = NOTO
    end
    return _resolved
end

--- Name of the label font in use.
function M.currentName() return resolve().name end

--- A face of the label (sans-serif) font. `bold` uses its bold file if it has one.
function M.face(size, bold)
    local r = resolve()
    local f = bold and r.bold or r.regular
    local ok, face = pcall(Font.getFace, Font, f, size)
    if ok and face then return face end
    return Font:getFace(bold and NOTO.bold or NOTO.regular, size)
end

--- True when the label font has a real bold file (so no synthetic bold needed).
function M.hasBold()
    local r = resolve()
    return r.bold ~= nil and r.bold ~= r.regular
end

--- Capitals, like Kobo (UTF-8 aware where KOReader allows).
function M.caps(s)
    if type(s) ~= "string" or s == "" then return s end
    local ok, U = pcall(require, "ffi/utf8proc")
    if ok and U and U.uppercase_dumb then
        local ok2, r = pcall(U.uppercase_dumb, s)
        if ok2 and r then return r end
    end
    return s:upper()
end

--- Settings menu items (Settings → Style → Label Font).
function M.menuItems(refresh)
    local items = {}
    local function pick(v)
        SUISettings:saveSetting(M.KEY, v)
        M.invalidate()
        local ok, Topbar = pcall(require, "screens/sui_topbar")
        if refresh then pcall(refresh) end
        local UIManager = require("ui/uimanager")
        UIManager:askForRestart(_("Restart to apply the label font everywhere."))
    end
    local function cur()
        local v = SUISettings:readSetting(M.KEY)
        return (v == nil or v == "auto") and "noto" or v
    end
    items[#items + 1] = {
        text = _("Noto Sans (KOReader default)"),
        checked_func = function() return cur() == "noto" end,
        callback = function() pick("noto") end,
        radio = true,
        separator = true,
    }
    local list, map = families()
    for _i, name in ipairs(list) do
        local n = name
        items[#items + 1] = {
            text = n,
            checked_func = function() return cur() == n end,
            callback = function() pick(n) end,
            radio = true,
            font_func = function(size)
                local ok, face = pcall(Font.getFace, Font, map[n].regular, size)
                return ok and face or nil
            end,
        }
    end
    return items
end

return M
