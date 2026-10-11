--[[--
kui_navbar_dropdown.lua — KoboUI

The menu a navigation-bar GROUP opens. It is the same KindleOS-style dropdown
as the ⋮ menu of the Kindle-style toolbar (kindletoolbar.koplugin): a plain
white box with a thin dark border and square corners, no shadow, left-aligned
regular-weight items in roomy rows. Tapping a row briefly inverts it, like
on a Kindle.

    ┌──────────────┐
    │ Library      │
    │ Authors      │
    │ Series       │
    │ Collections  │
    └──────────────┘
       Library ^            ← the group's tab

Here it opens upwards, sitting just above the group's tab. Tapping a name
runs that action exactly as if it were its own tab (so the group's tab lights
up while you're in one of its places). Tapping anywhere else, a swipe, or
Back closes it.
--]]--

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")

local _ = require("infra/sui_i18n").translate

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local GRAY  = Blitbuffer.COLOR_DARK_GRAY

local function S(v) return Screen:scaleBySize(v) end

-- ---------------------------------------------------------------------------
-- One row
-- ---------------------------------------------------------------------------

local DropdownItem = InputContainer:extend{
    text = nil,
    width = nil,
    height = nil,
    enabled = true,
    callback = nil,
    face = nil,
    pad_left = nil,
    show_parent = nil,
}

function DropdownItem:init()
    self.label = TextWidget:new{
        text = self.text,
        face = self.face,
        fgcolor = self.enabled and BLACK or GRAY,
        max_width = self.width - 2 * self.pad_left,
    }
    self[1] = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding = 0, padding_left = self.pad_left,
        background = WHITE,
        LeftContainer:new{
            dimen = Geom:new{ w = self.width - self.pad_left, h = self.height },
            self.label,
        },
    }
    self.ges_events = {
        TapItem = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function DropdownItem:onTapItem()
    if not self.enabled or not self.callback then return true end
    if G_reader_settings:nilOrTrue("flash_ui") and self.dimen then
        -- Kindle-like press feedback: invert the row briefly
        self[1].invert = true
        UIManager:widgetInvert(self[1], self.dimen.x, self.dimen.y)
        UIManager:setDirty(nil, "fast", self.dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()
    end
    self.callback()
    return true
end

-- ---------------------------------------------------------------------------
-- The dropdown
-- ---------------------------------------------------------------------------

local KindleDropdown = InputContainer:extend{
    name   = "kindleui_navbar_group_menu",
    items  = nil,   -- { { text=, callback=, enabled= }, ... }
    anchor = nil,   -- Geom of the group's tab; the box sits just above it
    covers_fullscreen = false,
}

function KindleDropdown:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local face = Font:getFace("cfont", 21)
    local pad_left = S(28)
    local row_h = S(54)
    local border = math.max(2, Size.border.window)

    -- width: widest label + padding, within sensible bounds
    local widest = 0
    for _i, it in ipairs(self.items) do
        local tw = TextWidget:new{ text = it.text, face = face }
        widest = math.max(widest, tw:getSize().w)
        tw:free()
    end
    local width = math.max(math.floor(sw * 0.42), widest + 2 * pad_left + S(24))
    width = math.min(width, sw - 2 * S(10))

    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, VerticalSpan:new{ width = S(10) })
    for _i, it in ipairs(self.items) do
        table.insert(vg, DropdownItem:new{
            text = it.text, width = width - 2 * border, height = row_h,
            enabled = it.enabled ~= false, face = face, pad_left = pad_left,
            show_parent = self,
            callback = it.callback,
        })
    end
    table.insert(vg, VerticalSpan:new{ width = S(10) })

    self.box = FrameContainer:new{
        bordersize = border, margin = 0, padding = 0, radius = 0,
        color = BLACK, background = WHITE,
        vg,
    }
    local size = self.box:getSize()
    local a = self.anchor or Geom:new{ x = sw - S(10), y = sh - S(100), w = 0, h = S(100) }
    -- Right-aligned with the tab (like the ⋮ menu hangs from its button),
    -- or left-aligned when that would run off the left edge.
    local x = a.x + a.w - size.w
    if x < S(10) then x = a.x end
    x = math.max(S(10), math.min(sw - S(10) - size.w, x))
    -- Just above the bar.
    local y = math.max(0, a.y - S(4) - size.h)
    self.box_dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self.box.overlap_offset = { x, y }
    self[1] = OverlapGroup:new{
        dimen = Geom:new{ w = sw, h = sh },
        allow_mirroring = false,
        self.box,
    }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        AnyGesture = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

function KindleDropdown:refreshRegion()
    local d = self.box_dimen
    return Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
end

function KindleDropdown:onShow()
    UIManager:setDirty(self, function() return "ui", self:refreshRegion() end)
    return true
end

function KindleDropdown:onCloseWidget()
    local r = self:refreshRegion()
    UIManager:setDirty(nil, function() return "ui", r end)
end

function KindleDropdown:onTapOutside(_arg, ges)
    if not ges.pos:intersectWith(self.box_dimen) then
        UIManager:close(self)
    end
    return true
end

function KindleDropdown:onAnyGesture()
    UIManager:close(self)
    return true
end

function KindleDropdown:onClose()
    UIManager:close(self)
    return true
end

-- ---------------------------------------------------------------------------

local M = {}

--- Opens the menu of group `group_id` above its navigation-bar tab.
function M.show(plugin, group_id, fm_self)
    local QA = require("features/sui_quickactions")
    local Bottombar = require("screens/sui_bottombar")
    local dropdown
    local items = {}
    for _i, id in ipairs(QA.filterValidIds(QA.getQAFolderItems(group_id))) do
        local entry = QA.getEntry(id)
        local mid = id
        items[#items + 1] = {
            text = entry and entry.label or id,
            callback = function()
                UIManager:close(dropdown)
                UIManager:nextTick(function()
                    local ok, err = pcall(function()
                        -- Exactly as if the action were its own tab.
                        Bottombar.onTabTap(plugin, mid, fm_self)
                    end)
                    if not ok then logger.warn("kindleui: group action failed:", tostring(err)) end
                end)
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = _("This group is empty."), enabled = false }
    end
    dropdown = KindleDropdown:new{ items = items, anchor = Bottombar.tabRect(group_id) }
    UIManager:show(dropdown)
    return dropdown
end

return M
