--[[--
qp_store.lua — KoboUI quick settings: saved settings.

Everything is stored in settings/kindleui_quicksettings.lua and written as
soon as it changes (there is no save/discard step).

    buttons = {                       -- in display order
        { id = "wifi", enabled = true, label = nil, icon = nil },
        { id = "custom_3", custom = true, enabled = true,
          label = "Stats", icon = "nerd:E7BA", action = { kind = "koreader", id = "stats_calendar_view" } },
        ...
    }
    per_row           = 5
    slider_brightness = true
    slider_warmth     = true
    slider_steps      = true   -- − / + buttons beside the sliders
    dim_behind        = true   -- darken the screen under the panel
    device_name       = "Lina's Kindle"  -- optional; see qp_device.lua
    next_custom       = 4
--]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Actions = require("features/quickpanel/qp_actions")

local Store = {}

local _settings

local function S()
    if not _settings then
        _settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kindleui_quicksettings.lua")
    end
    return _settings
end

local function save()
    S():flush()
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

--- Makes sure the list holds every built-in button exactly once and that the
--- permanent KOReader button is present and enabled.
local function normalize(list)
    local out, seen = {}, {}
    for _i, b in ipairs(list) do
        if type(b) == "table" and type(b.id) == "string" and not seen[b.id] then
            if b.custom or Actions.BUILTIN[b.id] then
                seen[b.id] = true
                out[#out + 1] = b
            end
        end
    end
    for _i, id in ipairs(Actions.BUILTIN_ORDER) do
        if not seen[id] then
            local def = Actions.BUILTIN[id]
            if id == "koreader_menu" then
                table.insert(out, 1, { id = id, enabled = true })
            else
                out[#out + 1] = { id = id, enabled = def.default_on == true }
            end
            seen[id] = true
        end
    end
    for _i, b in ipairs(out) do
        if Actions.BUILTIN[b.id] and Actions.BUILTIN[b.id].locked then b.enabled = true end
    end
    return out
end

function Store.getButtons()
    local list = S():readSetting("buttons")
    if type(list) ~= "table" then list = {} end
    local fixed = normalize(list)
    return fixed
end

function Store.setButtons(list)
    S():saveSetting("buttons", normalize(list))
    save()
end

function Store.getButton(id)
    for _i, b in ipairs(Store.getButtons()) do
        if b.id == id then return b end
    end
end

--- Changes some fields of one button and saves.
function Store.updateButton(id, fields)
    local list = Store.getButtons()
    for _i, b in ipairs(list) do
        if b.id == id then
            for k, v in pairs(fields) do
                if v == Store.NIL then b[k] = nil else b[k] = v end
            end
        end
    end
    Store.setButtons(list)
end

--- Sentinel for updateButton: remove the field.
Store.NIL = {}

function Store.addCustomButton(fields)
    local n = S():readSetting("next_custom") or 1
    S():saveSetting("next_custom", n + 1)
    local b = { id = "custom_" .. n, custom = true, enabled = true }
    for k, v in pairs(fields or {}) do b[k] = v end
    local list = Store.getButtons()
    list[#list + 1] = b
    Store.setButtons(list)
    return b.id
end

function Store.deleteButton(id)
    local list = Store.getButtons()
    for i = #list, 1, -1 do
        if list[i].id == id and list[i].custom then table.remove(list, i) end
    end
    Store.setButtons(list)
end

-- KoboUI 2.0: where a button appears. b.show_in is
--   nil / "all"  → everywhere (the default, so older setups are unchanged)
--   "reader"     → only when quick settings is opened while reading
--   "library"    → only in the Library and on the Home screen
Store.SHOW_IN = { "all", "reader", "library" }

function Store.showIn(b)
    local v = b and b.show_in
    if v == "reader" or v == "library" then return v end
    return "all"
end

--- Where quick settings is being opened: "reader" when a book is open,
--- otherwise "library" (Library, Home screen, other KoboUI screens).
function Store.currentContext()
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance and RUI.instance.document and not RUI.instance.tearing_down then
        return "reader"
    end
    return "library"
end

--- The buttons shown in the panel, in order. `context` ("reader" or
--- "library") defaults to where it's opened now.
function Store.getVisibleButtons(context)
    context = context or Store.currentContext()
    local out = {}
    for _i, b in ipairs(Store.getButtons()) do
        local where = Store.showIn(b)
        if b.enabled and (where == "all" or where == context) then out[#out + 1] = b end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Panel options
-- ---------------------------------------------------------------------------

local DEFAULTS = {
    per_row           = 5,
    slider_brightness = true,
    slider_warmth     = true,
    slider_steps      = true,
    dim_behind        = true,
    device_name       = nil,
}

function Store.get(key)
    local v = S():readSetting(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

function Store.set(key, value)
    S():saveSetting(key, value)
    save()
end

return Store
