-- module_two_col.lua — KoboUI
-- Module: Two Columns (dynamic instances).
--
-- Puts two existing modules side by side: one on the left, one on the right.
-- Each side is picked in the module's settings, from the modules you already
-- have (Quote, Currently Reading, Reading Stats, a Kobo shelf, …) or as a new
-- shelf / collection / quick-actions row made just for that column.
--
-- The chosen modules are built at the width of their column; their own
-- settings are reachable from this module's settings ("Left module
-- settings", "Right module settings").
--
-- Children are stored in global keys  kindleui_twocol_<inst>_left / _right
-- (instance ids are unique), so the module registry and the layout saver can
-- see them without knowing which screen the module is on:
--   * moduleregistry keeps child instances that live only inside a column;
--   * LayoutService keeps child modules enabled while the column is placed.

local Blitbuffer      = require("ffi/blitbuffer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen
local logger          = require("logger")

local _           = require("infra/sui_i18n").translate
local Config      = require("infra/sui_config")
local SUISettings = require("infra/sui_store")
local SUIStyle    = require("features/sui_style")
local UI          = require("infra/sui_core")

local BASE_ID = "two_col_row"

-- Modules that can't live inside a column: the clock redraws itself in
-- place every minute from the page's own slot, and a column inside a column
-- makes no sense.
local EXCLUDED = { clock = true }

-- Instanciable modules that can be created directly inside a column.
local NEW_BASES = { "coll_row", "meta_row", "quick_actions_row" }

local M = {}

local function key(inst_id, side) return "kindleui_twocol_" .. inst_id .. "_" .. side end

function M.getChild(inst_id, side)
    local v = SUISettings:readSetting(key(inst_id, side))
    return type(v) == "string" and v ~= "" and v or nil
end

local function setChild(inst_id, side, id) SUISettings:saveSetting(key(inst_id, side), id) end

function M.isTwoCol(id) return type(id) == "string" and id:match("^" .. BASE_ID .. "_") ~= nil end

--- Adds the children of every two-column module in `set` to `set`.
function M.expandPlaced(set)
    local extra = {}
    for id in pairs(set) do
        if M.isTwoCol(id) then
            for _i, side in ipairs({ "left", "right" }) do
                local c = M.getChild(id, side)
                if c then extra[c] = true end
            end
        end
    end
    for id in pairs(extra) do set[id] = true end
    return set
end

local function splitPct(pfx, inst_id)
    local n = tonumber(SUISettings:readSetting(pfx .. inst_id .. "_twocol_split"))
    if n and n >= 25 and n <= 75 then return math.floor(n) end
    return 50
end

local function showLabels(pfx, inst_id)
    return SUISettings:readSetting(pfx .. inst_id .. "_twocol_nolabels") ~= true
end

local function registry() return require("modules/moduleregistry") end

local function childMod(inst_id, side)
    local id = M.getChild(inst_id, side)
    if not id or M.isTwoCol(id) or EXCLUDED[id] then return nil end
    return registry().get(id)
end

local function enableChild(mod, pfx)
    if not mod then return end
    if type(mod.setEnabled) == "function" then
        pcall(mod.setEnabled, pfx, true)
    elseif mod.enabled_key then
        SUISettings:saveSetting(pfx .. mod.enabled_key, true)
    end
end

-- A section label like the page's own ones (bold title, and an optional
-- smaller regular line under it, e.g. "12 books"). It starts at the column's
-- left edge, so it lines up with the first cover below it.
-- `nav` (optional): { page, npages, turn = fn(delta), has_wallpaper } — the
-- "1/2" and ‹ › page arrows of a paged cover row, on the title's line, like
-- the page's own section labels.
local function labelWidget(text, sub, w, lf, nav)
    local scale = Config.getLabelScale() * (lf or 1)
    local fs = math.max(8, math.floor(SUIStyle.FS_BODY * scale))
    local right
    if nav and nav.npages and nav.npages > 1 then
        local gap = Screen:scaleBySize(8)
        local ind = TextWidget:new{
            text = string.format("%d/%d", nav.page, nav.npages),
            face = Font:getFace(SUIStyle.FACE_REGULAR, math.max(7, math.floor(SUIStyle.FS_DETAIL * scale))),
            fgcolor = SUIStyle.COLOR and SUIStyle.COLOR.text_primary or Blitbuffer.COLOR_BLACK,
        }
        local probe = TextWidget:new{ text = "Ag", face = Font:getFace(SUIStyle.FACE_REGULAR, fs), bold = true }
        local row_h = probe:getSize().h
        probe:free()
        local ok_gr, GridRenderer = pcall(require, "engines/sui_book_grid")
        local prev_b, next_b
        if ok_gr and GridRenderer then
            prev_b, next_b = GridRenderer.buildPageNavButtons(nav.page, nav.npages, row_h, nav.turn, nav.has_wallpaper)
        end
        right = HorizontalGroup:new{ align = "center" }
        if prev_b then right[#right + 1] = prev_b; right[#right + 1] = HorizontalSpan:new{ width = gap } end
        right[#right + 1] = ind
        if next_b then right[#right + 1] = HorizontalSpan:new{ width = gap }; right[#right + 1] = next_b end
    end
    local right_w = right and (right:getSize().w + Screen:scaleBySize(8)) or 0
    local title = TextWidget:new{
        text = text,
        face = Font:getFace(SUIStyle.FACE_REGULAR, fs),
        bold = true,
        fgcolor = SUIStyle.COLOR and SUIStyle.COLOR.text_primary or Blitbuffer.COLOR_BLACK,
        max_width = math.max(1, w - right_w),
        truncate_with_ellipsis = true,
    }
    local first_line = title
    if right then
        local lh = math.max(title:getSize().h, right:getSize().h)
        first_line = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = w - right:getSize().w, h = lh }, title },
            right,
        }
    end
    local vg = VerticalGroup:new{
        align = "left",
        first_line,
    }
    if sub and sub ~= "" then
        vg[#vg + 1] = TextWidget:new{
            text = sub,
            face = Font:getFace(SUIStyle.FACE_REGULAR, math.max(7, math.floor(SUIStyle.FS_DETAIL * scale))),
            fgcolor = SUIStyle.COLOR and SUIStyle.COLOR.text_secondary or Blitbuffer.COLOR_DARK_GRAY,
            max_width = math.max(1, w),
            truncate_with_ellipsis = true,
        }
    end
    return vg, vg:getSize().h
end

local LABEL_GAP = Screen:scaleBySize(8)

local function labelTextFor(mod, ctx)
    if not mod.label then return nil end
    local t = (type(mod.label_func) == "function" and mod.label_func(ctx)) or mod.label
    return type(t) == "string" and t ~= "" and t or nil
end

local function widths(w, pfx, inst_id)
    -- a clear gap, so two rows of covers read as two separate modules
    local gap = Screen:scaleBySize(40)
    local lw = math.floor((w - gap) * splitPct(pfx, inst_id) / 100)
    return lw, w - gap - lw, gap
end

local function makeInstance(inst_id)
    local S = {
        id          = inst_id,
        name        = _("Two Columns"),
        label       = nil,
        default_on  = true,
        has_covers  = true,
    }

    -- Builds one side. Returns widget, content(for covers), child.
    local function buildSide(side, side_w, ctx)
        local mod = childMod(inst_id, side)
        if not mod or type(mod.build) ~= "function" then return nil end
        local saved_col_w = ctx and ctx.col_w
        local saved_tc = ctx and ctx._kui_two_col
        if ctx then ctx.col_w = side_w; ctx._kui_two_col = true end
        local ok, content = pcall(mod.build, side_w, ctx)
        if ctx then ctx.col_w = saved_col_w; ctx._kui_two_col = saved_tc end
        if not ok then
            logger.warn("kindleui: two columns: " .. tostring(mod.id) .. " failed: " .. tostring(content))
            return nil
        end
        if not content then return nil end
        local vg = VerticalGroup:new{ align = "left" }
        local text = showLabels(ctx and ctx.pfx or "simpleui_hs_", inst_id) and labelTextFor(mod, ctx)
        if text then
            local sub = type(mod.label_sub_func) == "function" and ctx and mod.label_sub_func(ctx) or nil
            -- page arrows for paged cover rows (Featured / Author-Series Collection…)
            local nav
            local npages = ctx and ctx["_row_npages_" .. mod.id]
            if npages and npages > 1 then
                local mid = mod.id
                nav = {
                    page = ctx["_row_page_" .. mid] or 1,
                    npages = npages,
                    has_wallpaper = ctx.has_wallpaper,
                    turn = function(delta)
                        local screen = ctx._screen_widget
                        if screen and screen._turnBookModPage then screen:_turnBookModPage(mid, delta) end
                    end,
                }
            end
            local lw = labelWidget(text, sub, side_w, ctx and ctx.landscape_factor, nav)
            vg[#vg + 1] = lw
            vg[#vg + 1] = VerticalSpan:new{ width = LABEL_GAP }
        end
        vg[#vg + 1] = content
        return vg, content, mod
    end

    function S.build(w, ctx)
        local pfx = ctx and ctx.pfx or "simpleui_hs_"
        local lw, rw, gap = widths(w, pfx, inst_id)
        local left, lcontent, lmod = buildSide("left", lw, ctx)
        local right, rcontent, rmod = buildSide("right", rw, ctx)
        if not left and not right then
            local Tiles = require("engines/kui_kobo_tiles")
            local hold_on = SUISettings:nilOrTrue("simpleui_hs_settings_on_hold")
            local msg = _("No modules chosen")
            return Tiles.placeholder(w, hold_on and (msg .. "  —  " .. _("long press to configure")) or msg)
        end
        local h = math.max(left and left:getSize().h or 0, right and right:getSize().h or 0)
        local row = HorizontalGroup:new{
            align = "top",
            LeftContainer:new{ dimen = Geom:new{ w = lw, h = h }, left or VerticalSpan:new{ width = h } },
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{ dimen = Geom:new{ w = rw, h = h }, right or VerticalSpan:new{ width = h } },
        }
        local frame = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0,
            dimen = Geom:new{ w = w, h = h },
            row,
        }
        frame._twocol_children = {}
        for _i, pair in ipairs({ { lmod, lcontent }, { rmod, rcontent } }) do
            local mod, content = pair[1], pair[2]
            if mod and content and mod.has_covers and type(mod.updateCovers) == "function" then
                frame._twocol_children[#frame._twocol_children + 1] = { mod = mod, widget = content }
            end
        end
        return frame
    end

    function S.getHeight(ctx)
        local pfx = ctx and ctx.pfx or "simpleui_hs_"
        local w = (ctx and ctx.col_w) or Screen:getWidth()
        local lw, rw = widths(w, pfx, inst_id)
        local h = 0
        for _i, pair in ipairs({ { "left", lw }, { "right", rw } }) do
            local mod = childMod(inst_id, pair[1])
            if mod and type(mod.getHeight) == "function" then
                local saved = ctx and ctx.col_w
                local saved_tc = ctx and ctx._kui_two_col
                if ctx then ctx.col_w = pair[2]; ctx._kui_two_col = true end
                local ok, ch = pcall(mod.getHeight, ctx)
                if ctx then ctx.col_w = saved; ctx._kui_two_col = saved_tc end
                ch = ok and tonumber(ch) or 0
                local text = showLabels(pfx, inst_id) and labelTextFor(mod, ctx)
                if text then
                    local sub = type(mod.label_sub_func) == "function" and ctx and mod.label_sub_func(ctx) or nil
                    local _lw, lh = labelWidget(text, sub, pair[2], ctx and ctx.landscape_factor)
                    ch = ch + lh + LABEL_GAP
                end
                h = math.max(h, ch)
            end
        end
        return h > 0 and h or Screen:scaleBySize(60)
    end

    function S.updateCovers(widget, ctx)
        if not widget or not widget._twocol_children then return true end
        local all_done = true
        for _i, c in ipairs(widget._twocol_children) do
            local ok, done = pcall(c.mod.updateCovers, c.widget, ctx)
            if ok and not done then all_done = false end
        end
        return all_done
    end

    function S.getMenuItems(ctx_menu)
        local pfx = ctx_menu.pfx
        local _lc = ctx_menu._ or _
        local refresh = ctx_menu.refresh
        local Reg = registry()

        local function nameOf(id)
            local m = id and Reg.get(id)
            if not m then return _lc("None") end
            local n = m.name or id
            -- Kobo shelves and featured collections: add what they show.
            if id:match("^coll_row_") then
                local c = SUISettings:readSetting(pfx .. id .. "_coll_name")
                if c and c ~= "" then n = n .. " — " .. c end
            end
            return n
        end

        local function pickItems(side)
            local other = M.getChild(inst_id, side == "left" and "right" or "left")
            local sub = {}
            sub[#sub + 1] = {
                text = _lc("None"), radio = true, keep_menu_open = true,
                checked_func = function() return M.getChild(inst_id, side) == nil end,
                callback = function() setChild(inst_id, side, nil); refresh() end,
            }
            for _i, m in ipairs(Reg.list()) do
                local id = m.id
                if not EXCLUDED[id] and not M.isTwoCol(id) and not id:match("^spacer_row_")
                        and id ~= other and type(m.build) == "function" then
                    sub[#sub + 1] = {
                        text_func = function() return nameOf(id) end,
                        radio = true, keep_menu_open = true,
                        checked_func = function() return M.getChild(inst_id, side) == id end,
                        callback = function()
                            setChild(inst_id, side, id)
                            enableChild(m, pfx)
                            refresh()
                        end,
                    }
                end
            end
            sub[#sub].separator = true
            for _i, base_id in ipairs(NEW_BASES) do
                if Reg.isInstanciable(base_id) then
                    local base = Reg.getBase(base_id)
                    sub[#sub + 1] = {
                        text = string.format(_lc("New %s"), (base and base.name) or base_id),
                        keep_menu_open = true,
                        callback = function()
                            local new_id = Reg.createInstance(base_id)
                            if new_id then
                                setChild(inst_id, side, new_id)
                                enableChild(Reg.get(new_id), pfx)
                                UI.Notify.toast(_lc("Added. Open its settings below to set it up."), 2)
                            end
                            refresh()
                        end,
                    }
                end
            end
            return sub
        end

        local function childSettings(side)
            local m = childMod(inst_id, side)
            if not m or type(m.getMenuItems) ~= "function" then
                return { { text = _lc("This module has no settings."), enabled = false } }
            end
            -- the child's own settings, told it lives in a column
            local cm = setmetatable({ _kui_in_two_col = true }, { __index = ctx_menu })
            local ok, items = pcall(m.getMenuItems, cm)
            if ok and type(items) == "table" and #items > 0 then return items end
            return { { text = _lc("This module has no settings."), enabled = false } }
        end

        local items = {}
        for _i, side in ipairs({ "left", "right" }) do
            local _side = side
            items[#items + 1] = {
                text = _side == "left" and _lc("Left side") or _lc("Right side"),
                value_func = function() return nameOf(M.getChild(inst_id, _side)) end,
                sub_item_table_func = function() return pickItems(_side) end,
            }
        end
        for _i, side in ipairs({ "left", "right" }) do
            local _side = side
            items[#items + 1] = {
                text = _side == "left" and _lc("Left module settings") or _lc("Right module settings"),
                enabled_func = function() return childMod(inst_id, _side) ~= nil end,
                separator = _side == "right",
                sub_item_table_func = function() return childSettings(_side) end,
            }
        end
        items[#items + 1] = {
            text = _lc("Left column width"),
            value_func = function() return splitPct(pfx, inst_id) .. "%" end,
            sub_item_table_func = function()
                local sub = {}
                for _i, p in ipairs({ 30, 40, 50, 60, 70 }) do
                    local _p = p
                    sub[#sub + 1] = {
                        text = _p .. "%", radio = true, keep_menu_open = true,
                        checked_func = function() return splitPct(pfx, inst_id) == _p end,
                        callback = function()
                            SUISettings:saveSetting(pfx .. inst_id .. "_twocol_split", _p)
                            refresh()
                        end,
                    }
                end
                return sub
            end,
        }
        items[#items + 1] = {
            text = _lc("Show the modules' titles"),
            checked_func = function() return showLabels(pfx, inst_id) end,
            keep_menu_open = true,
            callback = function()
                SUISettings:saveSetting(pfx .. inst_id .. "_twocol_nolabels", showLabels(pfx, inst_id))
                refresh()
            end,
        }
        return items
    end

    return S
end

M.id            = BASE_ID
M.name          = _("Two Columns")
M.instanciable  = true
M.instances_key = "kindleui_two_col_row_instances"
M.makeInstance  = makeInstance

--- Removes the global child keys of an instance (called on delete).
function M.purge(inst_id)
    setChild(inst_id, "left", nil)
    setChild(inst_id, "right", nil)
end

return M
