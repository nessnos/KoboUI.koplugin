--[[--
kbo_statusbar.lua — KoboUI

The status bar along the top of the Home screen and the Library, like
Kobo's: the clock on the left, a row of line icons on the right —

    ☼  Wi-Fi  Bluetooth  battery  sync  search

Tapping an icon opens its drop-down panel (screens/kbo_panels.lua) under it,
with the icon shown white on a black circle while the panel is open; search
opens the library search straight away. Swiping down from the top of the
screen still opens KOReader's own menu (features/kui_topmenu.lua).

Everything is customisable (Settings → Status Bar → Kobo Status Bar →
Icons): hide any icon (e.g. Sync), reorder them, give any icon another
picture, add entries to an icon's drop-down, and add your own buttons
(e.g. "Calibre") with a name, an icon, and either one action or a drop-down
list of entries (each with its own action).
Bluetooth is hidden unless the device reports Bluetooth or you gave the icon
an action.

Stored in koboui_sb_items: an ordered list of
  { id = "sync", hidden = true, icon = "nerd:…", entries = { {label, action}… } }
  { id = "c1", custom = true, label = "Calibre", icon = …, mode = "action"|"menu",
    action = {…}, entries = { {label = "…", action = {…}}, … } }

The icon rectangles are recorded when the bar is painted (the bar is always
at the top-left of the screen), so taps can be matched against them.
--]]--

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local UIManager       = require("ui/uimanager")
local Widget          = require("ui/widget/widget")
local logger          = require("logger")
local Screen          = Device.screen
local _               = require("infra/sui_i18n").translate

local SUISettings = require("infra/sui_store")

local M = {}

M.KEY_ON = "koboui_statusbar"
M.ICONS = { "brightness", "wifi", "bluetooth", "battery", "sync", "search" }
M.LABELS = {
    brightness = _("Light"),
    wifi       = _("Wi-Fi"),
    bluetooth  = _("Bluetooth"),
    battery    = _("Battery"),
    sync       = _("Sync"),
    search     = _("Search"),
}

local function S(n) return Screen:scaleBySize(n) end

-- KoboUI: always on (no setting any more).
function M.isEnabled() return true end


function M.btAction() return SUISettings:readSetting("koboui_bt_action") end
function M.syncAction() return SUISettings:readSetting("koboui_sync_action") end

function M.isIconAvailable(key)
    if key == "brightness" then return Device:hasFrontlight() end
    if key == "wifi" then
        local ok, v = pcall(function() return Device:hasWifiToggle() end)
        return ok and v == true
    end
    if key == "battery" then
        local ok, v = pcall(function() return Device:hasBattery() end)
        return ok and v == true
    end
    return true
end

-- ---------------------------------------------------------------------------
-- The item list (order, hidden, custom buttons)
-- ---------------------------------------------------------------------------
local ITEMS_KEY = "koboui_sb_items"

local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = copy(v) end
    return r
end

--- The ordered item list (built-ins first time, new built-ins appended).
function M.getItems()
    local list = copy(SUISettings:readSetting(ITEMS_KEY)) or {}
    local have = {}
    for _i, it in ipairs(list) do have[it.id] = true end
    for _i, key in ipairs(M.ICONS) do
        if not have[key] then
            local it = { id = key }
            -- Bluetooth starts hidden unless the device has it.
            if key == "bluetooth" then
                local ok, Topbar = pcall(require, "screens/sui_topbar")
                local hw = ok and Topbar.isBluetoothAvailable and Topbar.isBluetoothAvailable()
                if not hw then it.hidden = true end
            end
            list[#list + 1] = it
        end
    end
    return list
end

function M.setItems(list) SUISettings:saveSetting(ITEMS_KEY, list) end

function M.getItem(id)
    for _i, it in ipairs(M.getItems()) do if it.id == id then return it end end
end

function M.updateItem(id, fields)
    local list = M.getItems()
    for _i, it in ipairs(list) do
        if it.id == id then
            for k, v in pairs(fields) do
                if v == M.NIL then it[k] = nil else it[k] = v end
            end
        end
    end
    M.setItems(list)
end
M.NIL = {}

function M.addCustom(label)
    local list = M.getItems()
    local n = 1
    local used = {}
    for _i, it in ipairs(list) do used[it.id] = true end
    while used["c" .. n] do n = n + 1 end
    local id = "c" .. n
    list[#list + 1] = { id = id, custom = true, label = label or _("Button"), mode = "action" }
    M.setItems(list)
    return id
end

function M.deleteItem(id)
    local list = M.getItems()
    for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
    M.setItems(list)
end

function M.itemLabel(it)
    if not it then return "?" end
    if it.label and it.label ~= "" then return it.label end
    return M.LABELS[it.id] or it.id
end

function M.isIconShown(key)
    local it = type(key) == "table" and key or M.getItem(key)
    if not it then return false end
    if not it.custom and not M.isIconAvailable(it.id) then return false end
    return not it.hidden
end

--- Show the battery percentage next to the icon (Kobo doesn't).
function M.showBatteryPct() return SUISettings:isTrue("koboui_sb_battery_pct") end

function M.setIconShown(key, on)
    M.updateItem(key, { hidden = (not on) and true or M.NIL })
end

-- ---------------------------------------------------------------------------
-- Geometry & hit testing
-- ---------------------------------------------------------------------------
M._rects = {}      -- key -> Geom (screen coordinates), set while painting
M._open = nil      -- the open drop-down, if any

function M.hit(pos)
    if not pos then return nil end
    for key, r in pairs(M._rects) do
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= 0 and pos.y < r.y + r.h + S(6) then
            return key
        end
    end
end

-- ---------------------------------------------------------------------------
-- The icons
-- ---------------------------------------------------------------------------
local Icon = Widget:extend{
    key  = nil,
    size = 0,     -- icon size
    cell_w = 0,   -- tap cell width
    cell_h = 0,
    info = nil,
}

function Icon:getSize() return Geom:new{ w = self.cell_w, h = self.cell_h } end

--- Paints icon `key` centred in rect `r` (inverted = white on a black disc).
function M.paintIcon(bb, key, r, info, inverted, size)
    local D = require("screens/kbo_dropdown")
    info = info or {}
    size = size or math.floor(r.h * 0.6)
    local cx, cy = r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
    local fg = Blitbuffer.COLOR_BLACK
    if inverted then
        -- the circle must stay inside the bar (never cut off at the top)
        local rad = math.floor(math.min(r.w, r.h - 2 * math.max(2, S(3))) / 2)
        D.disc(bb, cx, cy, rad, Blitbuffer.COLOR_BLACK)
        fg = Blitbuffer.COLOR_WHITE
    end
    local it = M.getItem(key) or { id = key }
    -- your own picture (any icon, built-in or custom button)
    -- KoboUI line icons (icons/line, icons/kobo): drawn exactly like the
    -- built-in ones, same size and line thickness.
    if it.custom and not it.icon then
        -- a new button: a thin star until an icon is chosen
        local star = require("infra/sui_paths").getPluginDir() .. "icons/line/star.svg"
        D.paintIcon(bb, star, cx - math.floor(size / 2), cy - math.floor(size / 2), size, fg)
        return
    end
    if type(it.icon) == "string" and it.icon:match("%.svg$")
            and (it.icon:find("/icons/line/", 1, true) or it.icon:find("/icons/kobo/", 1, true)) then
        D.paintIcon(bb, it.icon, cx - math.floor(size / 2), cy - math.floor(size / 2), size, fg)
        return
    end
    if it.icon or it.custom then
        local QPI = require("features/quickpanel/qp_icons")
        local w = QPI.widget(it.icon or "nerd:EBCD", math.floor(size * 0.9), fg, M.itemLabel(it))
        local ws = w:getSize()
        w:paintTo(bb, cx - math.floor(ws.w / 2), cy - math.floor(ws.h / 2))
        if w.free then w:free() end
        return
    end
    if key == "battery" then
        local KUIBattery = require("infra/kui_battery")
        local bh = math.floor(size * 0.46)
        local b = KUIBattery:new{ level = info.battery or 0, charging = info.charging,
            height = bh, fgcolor = fg,
            -- thin outline, like the line icons next to it
            outline = math.max(1, math.floor(size / 24 + 0.5)) }
        local bs = b:getSize()
        b:paintTo(bb, cx - math.floor(bs.w / 2), cy - math.floor(bs.h / 2))
        return
    end
    local name = ({ brightness = "sun", wifi = "wifi", sync = "sync", search = "search",
                    bluetooth = (info.bluetooth == false and info.has_bluetooth) and "bluetooth_off" or "bluetooth" })[key]
    if not name then return end
    local color = fg
    if key == "wifi" and not inverted and not info.wifi then
        color = Blitbuffer.COLOR_GRAY_9
    end
    D.paintIcon(bb, name, cx - math.floor(size / 2), cy - math.floor(size / 2), size, color)
end

function Icon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.cell_w, h = self.cell_h }
    M._rects[self.key] = self.dimen
    local open = M._open and not M._open._closed and M._open._kbo_key == self.key
    M.paintIcon(bb, self.key, self.dimen, self.info, open, self.size)
end

--- The right-hand group of icons for the status bar.
function M.buildIcons(info, bar_h, fs)
    M._rects = {}
    local size = math.max(S(14), math.floor(bar_h * 0.55))
    local cell_w = size + S(24)
    local g = HorizontalGroup:new{ align = "center" }
    for _i, it in ipairs(M.getItems()) do
        if M.isIconShown(it) then
            if it.id == "battery" and M.showBatteryPct() and info.battery then
                local TextWidget = require("ui/widget/textwidget")
                g[#g + 1] = TextWidget:new{ text = info.battery .. "%", face = fs,
                    fgcolor = Blitbuffer.COLOR_BLACK }
            end
            g[#g + 1] = Icon:new{ key = it.id, size = size, cell_w = cell_w, cell_h = bar_h, info = info }
        end
    end
    -- the last icon's cell already gives a margin at the right
    g[#g + 1] = HorizontalSpan:new{ width = 0 }
    return g
end

-- ---------------------------------------------------------------------------
-- Opening the panels
-- ---------------------------------------------------------------------------
function M.closePanel()
    if M._open and not M._open._closed then M._open:close() end
    M._open = nil
end

function M.isPanelOpen()
    return M._open ~= nil and not M._open._closed
end

local function topbarInfo()
    local ok, Topbar = pcall(require, "screens/sui_topbar")
    if ok then
        local ok2, info = pcall(Topbar.getTopbarInfo)
        if ok2 then return info end
    end
    return {}
end

--- Called with a tap position from the top of the screen. Returns true when
--- it hit an icon (and opened its panel / action).
function M.onTap(pos)
    if not M.isEnabled() then return false end
    local key = M.hit(pos)
    if not key then return false end
    M.open(key)
    return true
end

--- Drop-down rows for a list of { label, action } entries.
function M.entryRows(entries)
    local D = require("screens/kbo_dropdown")
    local Actions = require("features/quickpanel/qp_actions")
    local rows = {}
    for _i, e in ipairs(entries or {}) do
        local action = e.action
        rows[#rows + 1] = D.linkRow(e.label or (action and Actions.actionTitle(action)) or "?", function(dd)
            dd:close()
            UIManager:nextTick(function() if action then Actions.runAction(action) end end)
            return true
        end, { sep = true })
    end
    if #rows > 0 then rows[#rows].sep = false end
    return rows
end

function M.open(key)
    M.closePanel()
    local it = M.getItem(key) or { id = key }
    if it.custom then
        if it.mode ~= "menu" then
            if it.action then
                UIManager:nextTick(function() require("features/quickpanel/qp_actions").runAction(it.action) end)
            else
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = string.format(_("\"%s\" has no action yet. Long-press the status bar to set it up."), M.itemLabel(it)),
                    timeout = 3 })
            end
            return
        end
    end
    if key == "search" and not (it.entries and #it.entries > 0) then
        local QA = require("features/sui_quickactions")
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = FM and FM.instance
        UIManager:nextTick(function()
            QA.execute("search_library", { plugin = fm and fm.simpleui, fm = fm })
        end)
        return
    end
    local Panels = require("screens/kbo_panels")
    local spec
    if it.custom then
        local D = require("screens/kbo_dropdown")
        spec = { width = math.floor(Screen:getWidth() * 0.55), build = function()
            local rows = { D.titleRow(M.itemLabel(it), { sep = true }) }
            local more = M.entryRows(it.entries)
            if #more == 0 then
                more = { D.itemRow{ text = _("No entries yet"), face = "italic", dim = true, sep = false } }
            end
            for _i, r in ipairs(more) do rows[#rows + 1] = r end
            return rows
        end }
    else
        spec = Panels.spec(key)
    end
    if not spec then return end
    -- your own entries at the end of a built-in panel
    if not it.custom and it.entries and #it.entries > 0 then
        local build = spec.build or function() return {} end
        spec = setmetatable({ build = function(dd)
            local rows = build(dd)
            if #rows > 0 then rows[#rows].sep = true end
            for _i, r in ipairs(M.entryRows(it.entries)) do rows[#rows + 1] = r end
            return rows
        end }, { __index = spec })
    end
    local D = require("screens/kbo_dropdown")
    local anchor = M._rects[key]
    local dd = D.DropDown:new{
        anchor = anchor,
        width  = spec.width,
        build  = spec.build,
        paint_anchor = function(bb, r) M.paintIcon(bb, key, r, topbarInfo(), true) end,
        other_anchor = function(pos)
            local other = M.hit(pos)
            if other and other ~= key then
                UIManager:nextTick(function() M.open(other) end)
                return true
            end
        end,
        on_close = function()
            if spec.on_close then pcall(spec.on_close) end
        end,
    }
    dd._kbo_key = key
    M._open = dd
    dd:show()
    if spec.on_open then
        UIManager:nextTick(function() pcall(spec.on_open, dd) end)
    end
end

-- ---------------------------------------------------------------------------
-- Settings (Status Bar settings page)
-- ---------------------------------------------------------------------------
--- Opens the settings page of one button (its name, icon, action…).
function M.openButtonPage(plugin, id)
    local SUIWindow = require("engines/sui_window")
    local function buildRoot(ctx)
        local ctx_menu = SUIWindow.makeCtxMenu(ctx)
        return SUIWindow.MenuTable{
            items          = M.menuItems(plugin, ctx_menu, id),
            inner_w        = ctx.inner_w,
            repaint        = function() ctx.repaint() end,
            lock_overlay   = ctx.lockOverlay,
            unlock_overlay = ctx.unlockOverlay,
            push_stack     = function(sid, params)
                if type(sid) == "string" then ctx.push(sid, params) else ctx.push("nested_menu", params) end
            end,
            on_close       = function() end,
        }
    end
    local win = SUIWindow:new{
        name    = "sui_win_context",
        title   = function(ctx)
            local cur = ctx.current()
            if cur and cur.id == "nested_menu" then return cur.params.title or "" end
            return M.itemLabel(M.getItem(id) or { id = id })
        end,
        screens = SUIWindow.makeSettingsScreens(buildRoot),
        kindle_style = true,
    }
    win:show()
end

function M.menuItems(plugin, ctx_menu, page_id)
    local function rebuild()
        local ok_tb, TB = pcall(require, "screens/sui_topbar")
        if ok_tb and TB.invalidateDimCache then pcall(TB.invalidateDimCache) end
        if plugin and plugin._scheduleRebuild then plugin:_scheduleRebuild() end
    end
    local function refresh() if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end end
    local function actionItem(text, help, key)
        return {
            text = text,
            help_text = help,
            value_func = function()
                local a = SUISettings:readSetting(key)
                return a and require("features/quickpanel/qp_actions").actionTitle(a) or _("None")
            end,
            sub_item_table_func = function()
                local QS = require("features/quickpanel/qp_settings")
                local items = QS.actionPicker(
                    function() return SUISettings:readSetting(key) end,
                    function(a) SUISettings:saveSetting(key, a); rebuild() end,
                    refresh,
                    function() require("screens/sui_topbar").showSettings(plugin) end)
                table.insert(items, 1, {
                    text = _("None"), keep_menu_open = true, separator = true,
                    checked_func = function() return SUISettings:readSetting(key) == nil end,
                    callback = function() SUISettings:delSetting(key); rebuild(); refresh() end,
                })
                return items
            end,
        }
    end
    local QS = require("features/quickpanel/qp_settings")
    local Actions = require("features/quickpanel/qp_actions")
    local reopen = function() require("screens/sui_topbar").showSettings(plugin) end

    -- Editor for a { label, action } list (a custom button's drop-down, or
    -- extra entries at the end of a built-in panel).
    local function entriesItems(id)
        local items = {}
        local it = M.getItem(id) or {}
        local entries = it.entries or {}
        for i, e in ipairs(entries) do
            local idx = i
            items[#items + 1] = {
                text_func = function()
                    local cur = (M.getItem(id).entries or {})[idx] or {}
                    return cur.label or (cur.action and Actions.actionTitle(cur.action)) or _("Entry")
                end,
                sub_item_table_func = function()
                    local function get() return (M.getItem(id).entries or {})[idx] or {} end
                    local function put(fields)
                        local list = M.getItem(id).entries or {}
                        list[idx] = list[idx] or {}
                        for k, v in pairs(fields) do list[idx][k] = v end
                        M.updateItem(id, { entries = list })
                        rebuild(); refresh()
                    end
                    local sub = {
                        { text = _("Name"), keep_menu_open = true,
                          value_func = function() return get().label or _("Default") end,
                          callback = function()
                              QS.askText(_("Entry name"), get().label or "", nil, function(t)
                                  local list = M.getItem(id).entries or {}
                                  if list[idx] then list[idx].label = t end
                                  M.updateItem(id, { entries = list }); rebuild(); refresh()
                              end)
                          end },
                        { text = _("Action"),
                          value_func = function() local a = get().action; return a and Actions.actionTitle(a) or _("None") end,
                          sub_item_table_func = function()
                              return QS.actionPicker(function() return get().action end,
                                  function(a) put({ action = a }) end, refresh, reopen)
                          end },
                        { text = _("Move up"), keep_menu_open = true, enabled_func = function() return idx > 1 end,
                          callback = function()
                              local list = M.getItem(id).entries or {}
                              list[idx], list[idx - 1] = list[idx - 1], list[idx]
                              M.updateItem(id, { entries = list }); rebuild(); refresh()
                          end },
                        { text = _("Delete this entry"), keep_menu_open = true,
                          callback = function()
                              local list = M.getItem(id).entries or {}
                              table.remove(list, idx)
                              M.updateItem(id, { entries = list }); rebuild(); refresh()
                          end },
                    }
                    return sub
                end,
            }
        end
        items[#items + 1] = {
            text = _("Add an entry"), keep_menu_open = true, separator = #entries == 0,
            callback = function()
                local list = M.getItem(id).entries or {}
                list[#list + 1] = { label = _("New entry") }
                M.updateItem(id, { entries = list }); rebuild(); refresh()
            end,
        }
        items[#items + 1] = {
            text = _("Add an entry from KOReader's menu"),
            help_text = _("Capture mode: opens KOReader's menu; long-press any item (a submenu works too) and it becomes an entry with that item's name."),
            callback = function()
                require("features/quickpanel/qp_capture").start(function(action)
                    if action then
                        local list = M.getItem(id).entries or {}
                        list[#list + 1] = { label = action.title, action = action }
                        M.updateItem(id, { entries = list }); rebuild()
                    end
                    reopen()
                end)
            end,
        }
        return items
    end

    local function itemPage(id)
        local it = M.getItem(id) or { id = id }
        local sub = {
            { text = _("Show in the status bar"), keep_menu_open = true,
              enabled_func = function() local i = M.getItem(id); return i and (i.custom or M.isIconAvailable(id)) end,
              checked_func = function() return M.isIconShown(id) end,
              callback = function() M.setIconShown(id, not M.isIconShown(id)); rebuild() end },
            { text = _("Name"), keep_menu_open = true,
              value_func = function() return M.itemLabel(M.getItem(id)) end,
              callback = function()
                  QS.askText(_("Name"), M.itemLabel(M.getItem(id)), nil, function(t)
                      M.updateItem(id, { label = t or M.NIL }); rebuild(); refresh()
                  end)
              end },
            { text = _("Icon"), keep_menu_open = true,
              value_func = function() return M.getItem(id).icon and _("Custom") or _("Default") end,
              callback = function()
                  require("features/quickpanel/qp_iconpicker").show{
                      current = M.getItem(id).icon,
                      on_select = function(value)
                          M.updateItem(id, { icon = value or M.NIL }); rebuild(); refresh()
                      end,
                  }
              end },
        }
        if it.custom then
            sub[#sub + 1] = { text = _("When tapped: run an action"), radio = true, keep_menu_open = true,
                checked_func = function() return M.getItem(id).mode ~= "menu" end,
                callback = function() M.updateItem(id, { mode = "action" }); refresh() end }
            sub[#sub + 1] = { text = _("When tapped: open a drop-down"), radio = true, keep_menu_open = true,
                checked_func = function() return M.getItem(id).mode == "menu" end,
                callback = function() M.updateItem(id, { mode = "menu" }); refresh() end }
            sub[#sub + 1] = { text = _("Action"),
                enabled_func = function() return M.getItem(id).mode ~= "menu" end,
                value_func = function() local a = M.getItem(id).action; return a and Actions.actionTitle(a) or _("None") end,
                sub_item_table_func = function()
                    return QS.actionPicker(function() return M.getItem(id).action end,
                        function(a) M.updateItem(id, { action = a }); rebuild() end, refresh, reopen)
                end }
            sub[#sub + 1] = { text = _("Drop-down entries"),
                enabled_func = function() return M.getItem(id).mode == "menu" end,
                value_func = function() return tostring(#(M.getItem(id).entries or {})) end,
                sub_item_table_func = function() return entriesItems(id) end }
            sub[#sub + 1] = { text = _("Delete this button"), keep_menu_open = true,
                callback = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Delete the button \"%s\"?"), M.itemLabel(M.getItem(id))),
                        ok_text = _("Delete"),
                        ok_callback = function() M.deleteItem(id); rebuild(); refresh() end,
                    })
                end }
        else
            sub[#sub + 1] = { text = _("Extra drop-down entries"),
                help_text = _("Your own entries, added at the end of this icon's drop-down (each with an action)."),
                value_func = function() return tostring(#(M.getItem(id).entries or {})) end,
                sub_item_table_func = function() return entriesItems(id) end }
        end
        return sub
    end

    -- Adding a button, like KindleUI's quick settings: name it (or capture
    -- an item of KOReader's menu), then its page opens to pick the icon and
    -- the action.
    local function addButtonItem()
        return {
            text = _("Add a custom button"),
            help_text = _("A new icon in the status bar (e.g. \"Calibre\"): give it a name, then choose its icon and what a tap does — run an action, or open a drop-down with your own entries."),
            keep_menu_open = true,
            callback = function()
                QS.askText(_("Button name"), "", _("e.g. Calibre"), function(t)
                    local id = M.addCustom(t or _("Button"))
                    rebuild(); refresh()
                    M.openButtonPage(plugin, id)
                end)
            end,
        }
    end
    local function captureButtonItem()
        return {
            text = _("Add a button from KOReader's menu"),
            help_text = _("Capture mode: opens KOReader's menu; long-press any item (a plugin, a setting, a submenu) and it becomes a new status-bar button that opens it."),
            callback = function()
                require("features/quickpanel/qp_capture").start(function(action)
                    if action then
                        local id = M.addCustom(action.title)
                        M.updateItem(id, { action = action, mode = "action" })
                        rebuild()
                        M.openButtonPage(plugin, id)
                    else
                        reopen()
                    end
                end)
            end,
        }
    end

    local function arrangeItem()
        return {
            text = _("Arrange buttons"),
            help_text = _("Change the order of the status bar buttons, e.g. put your own button where Sync was."),
            keep_menu_open = true,
            callback = function()
                local SortWidget = require("ui/widget/sortwidget")
                local list = M.getItems()
                local sort_items = {}
                for _i, x in ipairs(list) do
                    sort_items[#sort_items + 1] = {
                        text = M.itemLabel(x) .. (M.isIconShown(x) and "" or ("  (" .. _("hidden") .. ")")),
                        item = x,
                    }
                end
                UIManager:show(SortWidget:new{
                    title = _("Arrange buttons"),
                    item_table = sort_items,
                    covers_fullscreen = true,
                    callback = function()
                        local new = {}
                        for _i, x in ipairs(sort_items) do new[#new + 1] = x.item end
                        M.setItems(new); rebuild(); refresh()
                    end,
                })
            end,
        }
    end

    local function iconsItems()
        local items = {}
        for _i, it in ipairs(M.getItems()) do
            local id = it.id
            items[#items + 1] = {
                text_func = function()
                    local cur = M.getItem(id)
                    if not cur then return "?" end
                    local t = M.itemLabel(cur)
                    if not M.isIconShown(cur) then t = t .. "  (" .. _("hidden") .. ")" end
                    return t
                end,
                sub_item_table_func = function() return itemPage(id) end,
            }
        end
        items[#items].separator = true
        items[#items + 1] = addButtonItem()
        items[#items + 1] = captureButtonItem()
        items[#items + 1] = arrangeItem()
        return items
    end

    if page_id then return itemPage(page_id) end

    return {
        {
            text = _("Buttons"),
            help_text = _("Show, hide, rename, re-icon and arrange the status-bar buttons, add entries to their drop-downs, or add your own buttons."),
            enabled_func = function() return M.isEnabled() end,
            sub_item_table_func = iconsItems,
        },
        arrangeItem(),
        (function() local it = addButtonItem(); it.enabled_func = function() return M.isEnabled() end; return it end)(),
        (function() local it = captureButtonItem(); it.enabled_func = function() return M.isEnabled() end; it.separator = true; return it end)(),
        {
            text = _("Show Battery Percentage"),
            enabled_func = function() return M.isEnabled() end,
            keep_menu_open = true,
            checked_func = function() return M.showBatteryPct() end,
            callback = function()
                SUISettings:saveSetting("koboui_sb_battery_pct", not M.showBatteryPct())
                rebuild()
            end,
        },
        actionItem(_("Sync Action"),
            _("What \"Sync now\" in the sync panel does. For example capture a sync plugin from KOReader's menu (long-press it), or pick a KOReader action."),
            "koboui_sync_action"),

    }
end

return M
