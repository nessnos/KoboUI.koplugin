--[[--
qp_settings.lua — KoboUI quick settings: its settings pages.

Everything saves as soon as it's changed.

  Quick Settings
    Top menu shows quick settings only   [✓]
    Device name                           Lina's Kindle
    Buttons                             >
        Add a custom button
        Arrange buttons
        Buttons per row                   5
        ── one row per button ──          Shown / Hidden  >
            Show in quick settings        [✓]
            Name                          Wi-Fi
            Icon                          (opens the icon grid)
            Action                        (custom buttons only)  >
            Delete this button            (custom buttons only)
    Slider options                      >
        Brightness slider                 [✓]
        Warmth slider                     [✓]
        − / + buttons                     [✓]
    Dim the screen behind the panel       [✓]
--]]--

local UIManager = require("ui/uimanager")
local _         = require("infra/sui_i18n").translate

local Store   = require("features/quickpanel/qp_store")
local Actions = require("features/quickpanel/qp_actions")

local M = {}

local function toast(msg)
    local ok, UI = pcall(require, "infra/sui_core")
    if ok and UI.Notify and UI.Notify.toast then UI.Notify.toast(msg, 2) end
end

function M.askText(title, current, hint, on_done, reset_text)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = current or "",
        input_hint = hint,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = reset_text or _("Default"), callback = function()
                UIManager:close(dlg); on_done(nil)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local t = dlg:getInputText()
                UIManager:close(dlg)
                if t and t:match("%S") then on_done(t) else on_done(nil) end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Action picker (custom buttons)
-- ---------------------------------------------------------------------------

--- Generic action picker: `get()` returns the current action table (or nil),
--- `set(action)` stores one. `reopen()` is called after a capture, to come
--- back to the page the picker was opened from.
function M.actionPicker(get, set, refresh, reopen)
    local function isCurrent(kind, aid)
        local a = get()
        return a and a.kind == kind and a.id == aid
    end
    local function choose(kind, aid)
        set({ kind = kind, id = aid })
        refresh()
    end
    local items = {}
    -- Capture mode: pick any item straight from KOReader's own menu.
    items[#items + 1] = {
        text = _("Pick from KOReader's menu (capture)"),
        help_text = _("Opens KOReader's menu. Go to the item you want and long-press it (tapping a final item works too): instead of running, it becomes the action. Close the menu to cancel."),
        separator = true,
        callback = function()
            local Capture = require("features/quickpanel/qp_capture")
            Capture.start(function(action)
                if action then set(action) end
                if reopen then reopen() end
            end)
        end,
    }
    items[#items + 1] = {
        text = _("KoboUI"),
        sub_item_table_func = function()
            local sub = {}
            for _i, a in ipairs(Actions.kindleuiActions()) do
                local aid = a.id
                sub[#sub + 1] = {
                    text = a.title, radio = true, keep_menu_open = true,
                    checked_func = function() return isCurrent("kindleui", aid) end,
                    callback = function() choose("kindleui", aid) end,
                }
            end
            return sub
        end,
    }
    for _i, sec in ipairs(Actions.koreaderActions()) do
        local items_of = sec.items
        items[#items + 1] = {
            text = sec.title,
            sub_item_table_func = function()
                local sub = {}
                for _i, a in ipairs(items_of) do
                    local aid = a.id
                    sub[#sub + 1] = {
                        text = a.title, radio = true, keep_menu_open = true,
                        checked_func = function() return isCurrent("koreader", aid) end,
                        callback = function() choose("koreader", aid) end,
                    }
                end
                return sub
            end,
        }
    end
    return items
end

local function actionPickerItems(id, refresh)
    return M.actionPicker(
        function() local b = Store.getButton(id); return b and b.action end,
        function(action) Store.updateButton(id, { action = action }) end,
        refresh,
        function() M.openButtonSettings(id) end)
end

-- ---------------------------------------------------------------------------
-- One button's page
-- ---------------------------------------------------------------------------

function M.buttonItems(id, refresh)
    local b = Store.getButton(id)
    if not b then
        return { { text = _("This button was deleted."), dim = true, callback = function() end } }
    end
    local def = Actions.BUILTIN[id]
    local items = {}

    if def and def.locked then
        items[#items + 1] = {
            text = _("Always shown in quick settings"),
            dim = true, callback = function() end,
        }
    else
        items[#items + 1] = {
            text = _("Show in quick settings"),
            checked_func = function()
                local cur = Store.getButton(id); return cur and cur.enabled
            end,
            keep_menu_open = true,
            callback = function()
                local cur = Store.getButton(id)
                if cur then Store.updateButton(id, { enabled = not cur.enabled }) end
                refresh()
            end,
        }
        -- KoboUI 2.0: where the button appears.
        local SHOW_IN_LABELS = {
            all     = _("Everywhere"),
            reader  = _("Only while reading"),
            library = _("Only in Library & Home"),
        }
        items[#items + 1] = {
            text = _("Show in"),
            help_text = _("Where this button appears: everywhere, only when you open quick settings while reading a book, or only in the Library and on the Home screen."),
            enabled_func = function()
                local cur = Store.getButton(id); return cur and cur.enabled
            end,
            value_func = function()
                return SHOW_IN_LABELS[Store.showIn(Store.getButton(id))]
            end,
            sub_item_table_func = function()
                local sub = {}
                for _i, where in ipairs(Store.SHOW_IN) do
                    local _w = where
                    sub[#sub + 1] = {
                        text = SHOW_IN_LABELS[_w], radio = true, keep_menu_open = true,
                        checked_func = function() return Store.showIn(Store.getButton(id)) == _w end,
                        callback = function()
                            Store.updateButton(id, { show_in = (_w ~= "all") and _w or Store.NIL })
                            refresh()
                        end,
                    }
                end
                return sub
            end,
        }
    end

    if def and def.dynamic_label then
        items[#items + 1] = {
            text = _("Name"),
            value_func = function() return _("Network, On or Off") end,
            help_text = _("Shows the name of the Wi-Fi network you're connected to, \"On\" when Wi-Fi is on but not connected, and \"Off\" when it's off."),
            dim = true,
            callback = function() end,
        }
    else
    items[#items + 1] = {
        text = _("Name"),
        value_func = function()
            local cur = Store.getButton(id); return cur and Actions.label(cur) or ""
        end,
        keep_menu_open = true,
        callback = function()
            local cur = Store.getButton(id)
            M.askText(_("Button name"), cur and cur.label or Actions.label(cur), nil, function(t)
                Store.updateButton(id, { label = t or Store.NIL })
                refresh()
            end)
        end,
    }
    end

    items[#items + 1] = {
        text = _("Icon"),
        value_func = function()
            local cur = Store.getButton(id)
            return (cur and cur.icon) and _("Custom") or _("Default")
        end,
        keep_menu_open = true,
        callback = function()
            local cur = Store.getButton(id)
            require("features/quickpanel/qp_iconpicker").show{
                current = cur and cur.icon or nil,
                on_select = function(value)
                    Store.updateButton(id, { icon = value or Store.NIL })
                    refresh()
                end,
            }
        end,
    }

    if b.custom then
        items[#items + 1] = {
            text = _("Action"),
            value_func = function()
                local cur = Store.getButton(id)
                return cur and cur.action and Actions.actionTitle(cur.action) or _("None")
            end,
            sub_item_table_func = function() return actionPickerItems(id, refresh) end,
        }
        items[#items + 1] = {
            text = _("Delete this button"),
            keep_menu_open = true,
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete the button \"%s\"?"), Actions.label(Store.getButton(id) or b)),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        Store.deleteButton(id)
                        refresh()
                    end,
                })
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- The whole page
-- ---------------------------------------------------------------------------

function M.makeMenuItems(ctx_menu)
    local refresh = (ctx_menu and ctx_menu.refresh) or function() end
    local TM = require("features/kui_topmenu")
    local QPDevice = require("features/quickpanel/qp_device")

    local function buttonsItems()
        local items = {}
        items[#items + 1] = {
            text = _("Add a custom button"),
            keep_menu_open = true,
            callback = function()
                Store.addCustomButton{ label = _("New button") }
                toast(_("Button added at the end of the list. Open it to choose its action."))
                refresh()
            end,
        }
        items[#items + 1] = {
            text = _("Add a button from KOReader's menu"),
            help_text = _("Capture mode: opens KOReader's menu; tap any item and it becomes a new button with that item's name."),
            callback = function()
                require("features/quickpanel/qp_capture").start(function(action)
                    if action then
                        local new_id = Store.addCustomButton{ label = action.title }
                        if new_id then Store.updateButton(new_id, { action = action }) end
                        M.openButtonSettings(new_id)
                    end
                end)
            end,
        }
        items[#items + 1] = {
            text = _("Arrange buttons"),
            keep_menu_open = true,
            callback = function()
                local SortWidget = require("ui/widget/sortwidget")
                local list = Store.getButtons()
                local sort_items = {}
                for _i, bt in ipairs(list) do
                    sort_items[#sort_items + 1] = {
                        text = Actions.label(bt) .. (not bt.enabled and ("  (" .. _("hidden") .. ")")
                            or (Store.showIn(bt) == "reader" and ("  (" .. _("reading") .. ")"))
                            or (Store.showIn(bt) == "library" and ("  (" .. _("Library & Home") .. ")"))
                            or ""),
                        button = bt,
                    }
                end
                UIManager:show(SortWidget:new{
                    title = _("Arrange buttons"),
                    item_table = sort_items,
                    covers_fullscreen = true,
                    callback = function()
                        local new = {}
                        for _i, it in ipairs(sort_items) do new[#new + 1] = it.button end
                        Store.setButtons(new)
                        refresh()
                    end,
                })
            end,
        }
        items[#items + 1] = {
            text = _("Buttons per row"),
            separator = true,
            sub_item_table_func = function()
                local sub = {}
                for n = 3, 8 do
                    local _n = n
                    sub[#sub + 1] = {
                        text = tostring(_n), radio = true, keep_menu_open = true,
                        checked_func = function() return Store.get("per_row") == _n end,
                        callback = function() Store.set("per_row", _n); refresh() end,
                    }
                end
                return sub
            end,
        }
        items[#items + 1] = { text = _("Buttons"), is_title = true }
        for _i, bt in ipairs(Store.getButtons()) do
            if Actions.isAvailable(bt) then
                local bid = bt.id
                items[#items + 1] = {
                    text_func = function()
                        local cur = Store.getButton(bid)
                        return cur and Actions.label(cur) or bid
                    end,
                    value_func = function()
                        local cur = Store.getButton(bid)
                        if not cur then return "" end
                        if Actions.BUILTIN[bid] and Actions.BUILTIN[bid].locked then return _("Always") end
                        if not cur.enabled then return _("Hidden") end
                        local where = Store.showIn(cur)
                        if where == "reader" then return _("Reading") end
                        if where == "library" then return _("Library & Home") end
                        return _("Shown")
                    end,
                    sub_item_table_func = function() return M.buttonItems(bid, refresh) end,
                }
            end
        end
        return items
    end

    return {
        {
            text = _("Top menu shows quick settings only"),
            help_text = _("When on, tapping or swiping down at the top of the screen opens only the quick settings. Its KOReader button opens KOReader's full menu."),
            checked_func = function() return TM.isQuickMenuOnly() end,
            keep_menu_open = true,
            callback = function() TM.setQuickMenuOnly(not TM.isQuickMenuOnly()); refresh() end,
        },
        {
            text = _("Device name"),
            value_func = function() return QPDevice.name() end,
            keep_menu_open = true,
            callback = function()
                M.askText(_("Device name"), Store.get("device_name") or "",
                    QPDevice.defaultName(),
                    function(t) Store.set("device_name", t or false); refresh() end)
            end,
        },
        {
            text = _("Buttons"),
            sub_item_table_func = buttonsItems,
        },
        {
            text = _("Slider options"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Brightness slider"),
                        checked_func = function() return Store.get("slider_brightness") end,
                        keep_menu_open = true,
                        callback = function() Store.set("slider_brightness", not Store.get("slider_brightness")); refresh() end,
                    },
                    {
                        text = _("Warmth slider"),
                        checked_func = function() return Store.get("slider_warmth") end,
                        keep_menu_open = true,
                        callback = function() Store.set("slider_warmth", not Store.get("slider_warmth")); refresh() end,
                    },
                    {
                        text = _("\u{2212} / + buttons beside the sliders"),
                        checked_func = function() return Store.get("slider_steps") end,
                        keep_menu_open = true,
                        callback = function() Store.set("slider_steps", not Store.get("slider_steps")); refresh() end,
                    },
                }
            end,
        },
        {
            text = _("Dim the screen behind the panel"),
            checked_func = function() return Store.get("dim_behind") end,
            keep_menu_open = true,
            callback = function() Store.set("dim_behind", not Store.get("dim_behind")); refresh() end,
        },
        {
            text = _("Open quick settings"),
            callback = function()
                TM.closeOverlays()
                UIManager:nextTick(TM.openQuickMenu)
            end,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Opening one button's page directly (long-press on a button in the panel)
-- ---------------------------------------------------------------------------

function M.openButtonSettings(id)
    local SUIWindow = require("engines/sui_window")
    local b = Store.getButton(id)
    local title = b and Actions.label(b) or _("Button")
    local function buildRoot(ctx)
        local ctx_menu = SUIWindow.makeCtxMenu(ctx)
        return SUIWindow.MenuTable{
            items          = M.buttonItems(id, ctx_menu.refresh),
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
            return title
        end,
        screens = SUIWindow.makeSettingsScreens(buildRoot),
        kindle_style = true,
    }
    win:show()
end

return M
