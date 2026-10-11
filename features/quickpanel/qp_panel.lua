--[[--
qp_panel.lua — KoboUI quick settings: the panel that drops down from the
top of the screen, laid out like KindleOS' own quick settings:

    ┌──────────────────────────────────────────────┐
    │ Lina's Kindle                        82% ▮▮▮ │  ← device name, time • date, battery
    │ 10:17 AM • Tue, June 30th                    │
    │   (≡)      (wifi)     (moon)     (⚙)         │  ← round buttons, N per row
    │ KOReader   Wi-Fi    Dark mode  Settings       │
    ├──────────────────────────────────────────────┤
    │ Brightness                               12   │
    │ (−)  ━━━━━━━━━━━━●───────────────────   (+)   │  ← sliders
    │ Warmth                                   10   │
    │ (−)  ━━━━━━━●────────────────────────   (+)   │
    │                    ︿                          │  ← chevron: tap to close
    ┝━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┥
    ░░░░░░░ the screen behind is dimmed ░░░░░░░░░░░░

Tap outside the panel, tap the chevron or swipe up to close it.
Long-press a button to change it (opens its page in KoboUI settings).
Long-press − / + to jump to the minimum / maximum.
--]]--

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local Screen          = Device.screen
local _               = require("infra/sui_i18n").translate

local SUIStyle = require("features/sui_style")
local Store    = require("features/quickpanel/qp_store")
local Actions  = require("features/quickpanel/qp_actions")
local Slider   = require("features/quickpanel/qp_slider")
local Icons    = require("features/quickpanel/qp_icons")
local DeviceName = require("features/quickpanel/qp_device")
local Chevron  = require("infra/kui_chevron")

local function S(v) return Screen:scaleBySize(v) end

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE

-- A plain box with a rounded outline (or a filled one when `filled`).
local Tile = Widget:extend{ size = 0, filled = false, radius = 0, border = 2, content = nil }

function Tile:getSize() return Geom:new{ w = self.size, h = self.size } end

function Tile:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    if self.filled then
        bb:paintRoundedRect(x, y, self.size, self.size, BLACK, self.radius)
    else
        bb:paintRoundedRect(x, y, self.size, self.size, WHITE, self.radius)
        bb:paintBorder(x, y, self.size, self.size, self.border, BLACK, self.radius)
    end
    if self.content then
        local cs = self.content:getSize()
        self.content:paintTo(bb, x + math.floor((self.size - cs.w) / 2), y + math.floor((self.size - cs.h) / 2))
    end
end

-- Wraps a widget and remembers where it was painted (for hit tests).
local Area = Widget:extend{ w = 0, h = 0, child = nil }
function Area:getSize() return Geom:new{ w = self.w, h = self.h } end
function Area:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    if self.child then
        local cs = self.child:getSize()
        self.child:paintTo(bb, x + math.floor((self.w - cs.w) / 2), y + math.floor((self.h - cs.h) / 2))
    end
end

local QuickPanel = InputContainer:extend{
    name = "kindleui_quicksettings",
}

function QuickPanel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local full = function() return self.dimen end
    self.ges_events = {
        TapQP        = { GestureRange:new{ ges = "tap",         range = full } },
        HoldQP       = { GestureRange:new{ ges = "hold",        range = full } },
        HoldRelQP    = { GestureRange:new{ ges = "hold_release", range = full } },
        SwipeQP      = { GestureRange:new{ ges = "swipe",       range = full } },
        PanQP        = { GestureRange:new{ ges = "pan",         range = full } },
        PanRelQP     = { GestureRange:new{ ges = "pan_release", range = full } },
    }
    if Device:hasKeys() then
        self.key_events = { CloseQP = { { "Back" } } }
    end
    self:build()
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function buttonCell(b, cell_w, tile_sz, label_face)
    local active = Actions.isActive(b)
    local fg = active and WHITE or BLACK
    local icon = Icons.widget(Actions.icon(b), math.floor(tile_sz * 0.48), fg, Actions.label(b))
    local tile = Tile:new{
        size = tile_sz, filled = active, radius = math.floor(tile_sz / 2),
        border = math.max(2, S(2)), content = icon,
    }
    local label = TextWidget:new{
        text = Actions.panelLabel(b),
        face = label_face,
        fgcolor = BLACK,
        max_width = cell_w - S(4),
        truncate_with_ellipsis = true,
    }
    local cell = CenterContainer:new{
        dimen = Geom:new{ w = cell_w, h = tile_sz + S(8) + label:getSize().h },
        VerticalGroup:new{
            align = "center",
            tile,
            VerticalSpan:new{ width = S(8) },
            label,
        },
    }
    return cell, tile
end

-- A plain − / + sign (no frame) with a comfortable tap area.
-- − and + drawn like Neo QuickSettings' step buttons: the regular (not bold)
-- UI font at its "small button" size, "−" (U+2212) and fullwidth "＋" (U+FF0B).
local function stepButton(text, size)
    return Area:new{ w = size, h = size,
        child = Icons.textGlyph(text, "cfont", Screen:scaleBySize(14), size, BLACK) }
end

function QuickPanel:_sliderSpecs()
    local specs = {}
    local powerd = Device:getPowerDevice()
    if Store.get("slider_brightness") and Device:hasFrontlight() and powerd then
        specs[#specs + 1] = {
            kind = "brightness", title = _("Brightness"), glyph = "\u{E7DF}",
            min = powerd.fl_min, max = powerd.fl_max, step = 1,
            get = function() return powerd:frontlightIntensity() end,
            set = function(v)
                if v <= powerd.fl_min then
                    powerd:setIntensity(powerd.fl_min)
                    powerd:turnOffFrontlight()
                else
                    powerd:setIntensity(v)
                    if not powerd:isFrontlightOn() then powerd:turnOnFrontlight() end
                end
            end,
        }
    end
    if Store.get("slider_warmth") and Device:hasNaturalLight() and powerd then
        -- Show the device's native warmth scale (0-24 on Kindles, like the
        -- stock KindleOS slider) instead of KOReader's internal 0-100.
        local native = powerd.toNativeWarmth and powerd.fromNativeWarmth
            and powerd.fl_warmth_max ~= nil
        local wmin = native and (powerd.fl_warmth_min or 0) or 0
        local wmax = native and powerd.fl_warmth_max or 100
        specs[#specs + 1] = {
            kind = "warmth", title = _("Warmth"), glyph = "\u{E7E0}",
            min = wmin, max = wmax, step = 1,
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
    return specs
end

-- "18:02 • Sept 30, 2026", like KindleOS' quick settings.
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "June",
                 "July", "Aug", "Sept", "Oct", "Nov", "Dec" }
local function dateLine()
    local datetime = require("datetime")
    local t = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    local d = os.date("*t")
    return string.format("%s \u{2022} %s %d, %d", t, MONTHS[d.month], d.day, d.year)
end

local function batteryWidget(face)
    if not Device:hasBattery() then return nil end
    local powerd = Device:getPowerDevice()
    local ok, lvl = pcall(powerd.getCapacity, powerd)
    if not ok or type(lvl) ~= "number" then return nil end
    local charging = false
    pcall(function() charging = powerd:isCharging() == true end)
    local label = TextWidget:new{ text = lvl .. "%", face = face, fgcolor = BLACK }
    local KUIBattery = require("infra/kui_battery")
    return HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = S(8) },
        KUIBattery:new{ level = lvl, charging = charging, height = math.floor(label:getSize().h * 0.55) },
    }
end

function QuickPanel:build()
    local sw      = Screen:getWidth()
    local pad     = S(26)
    local inner_w = sw - pad * 2
    self._buttons = {}
    self._sliders = {}

    local body = VerticalGroup:new{ align = "left" }
    local function padded(w)
        return HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, w }
    end

    -- Header: device name, time • date, battery ----------------------------
    local name_face = Font:getFace(SUIStyle.FACE_BOLD, SUIStyle.FS_BODY)
    local line_face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    -- The date line is pulled up under the name (text boxes carry extra
    -- line spacing), so the two read as one block like on a Kindle.
    local name_w = TextWidget:new{ text = DeviceName.name(), face = name_face, fgcolor = BLACK,
                                   max_width = math.floor(inner_w * 0.7), truncate_with_ellipsis = true }
    local date_w = TextWidget:new{ text = dateLine(), face = line_face, fgcolor = BLACK,
                                   max_width = math.floor(inner_w * 0.75), truncate_with_ellipsis = true }
    local name_h, date_h = name_w:getSize().h, date_w:getSize().h
    local date_y = name_h - math.floor(date_h * 0.28)
    date_w.overlap_offset = { 0, date_y }
    local left = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{ w = inner_w, h = date_y + date_h },
        name_w,
        date_w,
    }
    local head_dimen = Geom:new{ w = inner_w, h = left:getSize().h }
    local head = OverlapGroup:new{ dimen = head_dimen, LeftContainer:new{ dimen = head_dimen:copy(), left } }
    local batt = batteryWidget(line_face)
    if batt then
        -- battery sits level with the device name, like on a Kindle
        local bd = Geom:new{ w = inner_w, h = left[1]:getSize().h }
        head[#head + 1] = RightContainer:new{ dimen = bd, batt }
    end
    body[#body + 1] = VerticalSpan:new{ width = S(22) }
    body[#body + 1] = padded(head)
    body[#body + 1] = VerticalSpan:new{ width = S(26) }

    -- Buttons ------------------------------------------------------------------
    local visible = {}
    for _i, b in ipairs(Store.getVisibleButtons()) do
        if Actions.isAvailable(b) then visible[#visible + 1] = b end
    end
    local per_row = math.max(3, math.min(8, Store.get("per_row") or 5))
    local tile_sz = math.min(S(64), math.floor(inner_w / per_row) - S(16))
    local label_face = Font:getFace(SUIStyle.FACE_REGULAR, math.max(10, SUIStyle.FS_DETAIL))
    -- Like KindleOS: the width is shared equally between the columns, each
    -- circle and its label centred in its column, and a shorter last row is
    -- centred as a whole (keeping the same spacing).
    local step = inner_w / per_row
    local function centreX(col)          -- col is 0-based
        return pad + math.floor(step / 2 + col * step + 0.5)
    end
    local row, row_x
    for i, b in ipairs(visible) do
        local col = (i - 1) % per_row
        if col == 0 then
            if row then
                body[#body + 1] = row
                body[#body + 1] = VerticalSpan:new{ width = S(16) }
            end
            row = HorizontalGroup:new{ align = "top" }
            row_x = 0
        end
        -- a shorter last row is centred as a whole, like on a Kindle
        local row_start = i - col
        local n_in_row = math.min(per_row, #visible - row_start + 1)
        local cx = centreX(col) + math.floor((per_row - n_in_row) * step / 2 + 0.5)
        -- the label may use the space up to the neighbouring circles
        local cell_w = math.floor(math.min(step, 2 * cx, 2 * (sw - cx)))
        local cell, tile = buttonCell(b, cell_w, tile_sz, label_face)
        local x = cx - math.floor(cell_w / 2)
        if x > row_x then row[#row + 1] = HorizontalSpan:new{ width = x - row_x } end
        row[#row + 1] = cell
        row_x = x + cell_w
        self._buttons[#self._buttons + 1] = { tile = tile, button = b }
    end
    if row then body[#body + 1] = row end

    -- Sliders ------------------------------------------------------------------
    local specs = self:_sliderSpecs()
    body[#body + 1] = VerticalSpan:new{ width = S(22) }
    if #specs > 0 then
        body[#body + 1] = LineWidget:new{
            dimen = Geom:new{ w = sw, h = math.max(1, S(1)) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end
    local title_face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_BODY)
    local steps = Store.get("slider_steps")
    local btn_sz = S(40)
    for _i, spec in ipairs(specs) do
        body[#body + 1] = VerticalSpan:new{ width = S(18) }
        body[#body + 1] = padded(TextWidget:new{ text = spec.title, face = title_face, fgcolor = BLACK })
        body[#body + 1] = VerticalSpan:new{ width = S(18) }

        local gap = S(14)
        local slider_w = steps and (inner_w - (btn_sz + gap) * 2) or inner_w
        local slider = Slider:new{
            width = slider_w, value = spec.get(), value_min = spec.min, value_max = spec.max,
            value_face = Font:getFace(SUIStyle.FACE_REGULAR, SUIStyle.FS_DETAIL),
        }
        local ref = { spec = spec, slider = slider }
        slider.on_change = function(v, _final)
            pcall(spec.set, v)
        end
        if steps then
            ref.minus = stepButton("\u{2212}", btn_sz)
            ref.plus  = stepButton("\u{FF0B}", btn_sz)
            -- − / + line up with the rail, below the value written over the knob
            local rail_h = slider:getSize().h - slider.label_h
            local function side(btn)
                return VerticalGroup:new{
                    VerticalSpan:new{ width = slider.label_h },
                    CenterContainer:new{ dimen = Geom:new{ w = btn_sz, h = math.max(btn_sz, rail_h) }, btn },
                }
            end
            body[#body + 1] = padded(HorizontalGroup:new{
                align = "top",
                side(ref.minus),
                HorizontalSpan:new{ width = gap },
                slider,
                HorizontalSpan:new{ width = gap },
                side(ref.plus),
            })
        else
            body[#body + 1] = padded(slider)
        end
        self._sliders[#self._sliders + 1] = ref
    end

    -- Chevron (close) ------------------------------------------------------------
    body[#body + 1] = VerticalSpan:new{ width = S(14) }
    self._handle = Area:new{ w = sw, h = S(44), child = Chevron:new{ up = true } }
    body[#body + 1] = self._handle
    body[#body + 1] = LineWidget:new{
        dimen = Geom:new{ w = sw, h = math.max(3, S(3)) },
        background = BLACK,
    }

    self._frame = FrameContainer:new{
        background = WHITE, bordersize = 0, padding = 0, margin = 0,
        body,
    }
    self._panel_h = self._frame:getSize().h
end

function QuickPanel:paintTo(bb, x, y)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Dim what's behind the panel, like KindleOS does.
    if Store.get("dim_behind") and self._panel_h < sh then
        bb:darkenRect(0, self._panel_h, sw, sh - self._panel_h, 0.4)
    end
    self._frame:paintTo(bb, x, y)
    self._panel_dimen = Geom:new{ x = 0, y = 0, w = sw, h = self._panel_h }
end

-- ---------------------------------------------------------------------------
-- Showing / closing
-- ---------------------------------------------------------------------------

function QuickPanel:show()
    UIManager:show(self)
    UIManager:setDirty(self, "ui")
end

function QuickPanel:close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self, "ui")
    if self.on_close then pcall(self.on_close) end
end

--- Rebuilds the panel (e.g. after Wi-Fi was toggled).
function QuickPanel:refresh()
    if self._closed then return end
    local old_h = self._panel_h or 0
    self:build()
    if self._panel_h ~= old_h then
        UIManager:setDirty("all", "ui")
    else
        UIManager:setDirty(self, function()
            return "ui", Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = self._panel_h }
        end)
    end
end

function QuickPanel:onCloseQP() self:close(); return true end
function QuickPanel:onCloseWidget() self._closed = true end

-- ---------------------------------------------------------------------------
-- Gestures
-- ---------------------------------------------------------------------------

local function inside(pos, d)
    return d and d.x and pos.x >= d.x and pos.x < d.x + d.w and pos.y >= d.y and pos.y < d.y + d.h
end

function QuickPanel:_repaintSlider(ref)
    local d = ref.slider.dimen
    local region = Geom:new{ x = 0, y = d.y, w = Screen:getWidth(), h = d.h }
    UIManager:setDirty(self, function() return "fast", region end)
end

function QuickPanel:_step(ref, dir, to_end)
    local spec = ref.spec
    local v
    if to_end then
        v = dir < 0 and spec.min or spec.max
    else
        v = ref.slider.value + dir * spec.step
    end
    ref.slider:set(v, true)
    self:_repaintSlider(ref)
end

function QuickPanel:onTapQP(_, ges)
    local pos = ges.pos
    if not inside(pos, self._panel_dimen) then self:close(); return true end
    if inside(pos, self._handle.dimen) then self:close(); return true end
    for _i, ref in ipairs(self._buttons) do
        if inside(pos, ref.tile.dimen) then
            local b = ref.button
            Actions.run(b, self)
            local def = Actions.BUILTIN[b.id]
            if def and def.keep_open then
                UIManager:scheduleIn(0.2, function() self:refresh() end)
            end
            return true
        end
    end
    for _i, ref in ipairs(self._sliders) do
        if ref.minus and inside(pos, ref.minus.dimen) then self:_step(ref, -1); return true end
        if ref.plus and inside(pos, ref.plus.dimen) then self:_step(ref, 1); return true end
        if ref.slider:hit(pos) then
            ref.slider:set(ref.slider:valueAt(pos.x), true)
            self:_repaintSlider(ref)
            return true
        end
    end
    return true
end

function QuickPanel:onHoldQP(_, ges)
    self._hold_pos = ges.pos
    return true
end

function QuickPanel:onHoldRelQP(_, ges)
    local pos = self._hold_pos or ges.pos
    self._hold_pos = nil
    if not inside(pos, self._panel_dimen) then return true end
    for _i, ref in ipairs(self._sliders) do
        if ref.minus and inside(pos, ref.minus.dimen) then self:_step(ref, -1, true); return true end
        if ref.plus and inside(pos, ref.plus.dimen) then self:_step(ref, 1, true); return true end
    end
    for _i, ref in ipairs(self._buttons) do
        if inside(pos, ref.tile.dimen) then
            local id = ref.button.id
            self:close()
            UIManager:nextTick(function()
                require("features/quickpanel/qp_settings").openButtonSettings(id)
            end)
            return true
        end
    end
    return true
end

function QuickPanel:onSwipeQP(_, ges)
    if self._dragging then return true end
    if ges.direction == "north" then self:close() end
    return true
end

function QuickPanel:onPanQP(_, ges)
    local pos = ges.pos
    if self._dragging then
        if self._dragging.slider:set(self._dragging.slider:valueAt(pos.x)) then
            self:_repaintSlider(self._dragging)
        end
        return true
    end
    for _i, ref in ipairs(self._sliders) do
        if ref.slider:knobHit(pos) or ref.slider:hit(pos) then
            self._dragging = ref
            ref.slider:set(ref.slider:valueAt(pos.x))
            self:_repaintSlider(ref)
            return true
        end
    end
    return true
end

function QuickPanel:onPanRelQP(_, ges)
    if self._dragging then
        local ref = self._dragging
        self._dragging = nil
        ref.slider:set(ref.slider:valueAt(ges.pos.x), true)
        self:_repaintSlider(ref)
    end
    return true
end

return QuickPanel
