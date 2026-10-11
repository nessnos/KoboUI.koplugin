--[[--
kui_vertical_scroll.lua — KoboUI

"Vertical scrolling library" mode for KOReader's file browser (ported from
the standalone vertical_library_scroll.koplugin):

  * Swipe UP  -> next page, swipe DOWN -> previous page (instead of left/right)
  * A thin scrollbar with up/down arrows floats on the right edge; tap or
    drag it to jump to a page.
  * The item grid/list is narrowed so the scrollbar never covers a cover.

Off by default. Toggle it in KoboUI settings → Library → Vertical scrolling,
or in KOReader's File browser → Settings. The setting key is the same as the
standalone plugin's ("vertical_library_scroll"), so an existing choice is kept.

M.install() must run at plugin load time (before the first FileChooser is
built), which is what main.lua does.
--]]--

local _ = require("infra/sui_i18n").translate

local M = {}

--- Empties a Menu's "Page x of y" footer text (it is a text Button, which
--- Button:hide() doesn't hide).
function M.blankPageText(menu)
    local t = menu and menu.page_info_text
    if t and t.setText and t.text ~= "" then
        pcall(t.setText, t, "", t.width)
    end
end

M.SETTING_KEY = "vertical_library_scroll"
local SETTING_KEY = M.SETTING_KEY

-- KoboUI: on by default (the Kobo library scrolls up and down).
local function isEnabled()
    return G_reader_settings:nilOrTrue(SETTING_KEY)
end
M.isEnabled = isEnabled

-- Height of the area at the top of the screen that opens the menu
-- (KoboUI's top bar when it is on, otherwise KOReader's menu zone).
local function topZoneHeight()
    local Screen = require("device").screen
    local ok, h = pcall(function()
        local SUISettings = require("infra/sui_store")
        if SUISettings:nilOrTrue("simpleui_topbar_enabled") then
            return require("screens/sui_topbar").TOTAL_TOP_H()
        end
    end)
    if ok and h then return h end
    local zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    return math.floor(Screen:getHeight() * ((zone and zone.h) or 0.1))
end

-- ---------------------------------------------------------------------------
-- KindleOS-style scrollbar parts: a small solid triangle at each end (grey
-- when you can't go further that way), a thin grey track and a thick black
-- thumb, no frames.
-- ---------------------------------------------------------------------------

local function kindleScrollWidgets()
    local Blitbuffer     = require("ffi/blitbuffer")
    local Device         = require("device")
    local Geom           = require("ui/geometry")
    local GestureRange   = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Screen         = Device.screen

    -- dir: "up" / "down" (vertical bar) or "left" / "right" (horizontal
    -- bar, Series bookshelf). `up` is kept for the vertical ones.
    local Triangle = InputContainer:extend{
        up = true, dir = nil, tri_w = 0, tri_h = 0, pad = 0,
        enabled = true, callback = nil, hidden = false,
    }
    function Triangle:init()
        self.dimen = Geom:new{ w = self.tri_w + 2 * self.pad, h = self.tri_h + 2 * self.pad }
        self.ges_events = {
            TapKindleArrow = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        }
    end
    function Triangle:getSize() return Geom:new{ w = self.tri_w + 2 * self.pad, h = self.tri_h + 2 * self.pad } end
    -- KoboUI: a thin open chevron (^ v ‹ ›) like Kobo's library, grey
    -- when you can't go further that way.
    function Triangle:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = self.tri_w + 2 * self.pad, h = self.tri_h + 2 * self.pad }
        local color = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
        if self.hidden then return end
        local x0, y0, w, h = x + self.pad, y + self.pad, self.tri_w, self.tri_h
        local t = math.max(2, math.floor(math.min(w, h) * 0.16 + 0.5))
        if self.dir == "left" or self.dir == "right" then
            -- column-wise: two strokes meeting at the tip (h is the long side)
            local half = math.floor(h / 2)
            for j = 0, h - 1 do
                local d = math.abs(j - half) / math.max(1, half)       -- 0 at the tip row
                local cx = math.floor(d * (w - t) + 0.5)
                local rx = self.dir == "left" and (x0 + cx) or (x0 + w - t - cx)
                bb:paintRect(rx, y0 + j, t, 1, color)
            end
            return
        end
        local half = math.floor(w / 2)
        for i = 0, w - 1 do
            local d = math.abs(i - half) / math.max(1, half)           -- 0 at the tip column
            local cy = math.floor(d * (h - t) + 0.5)
            local ry = self.up and (y0 + cy) or (y0 + h - t - cy)
            bb:paintRect(x0 + i, ry, 1, t, color)
        end
    end
    function Triangle:enableDisable(on) self.enabled = on and true or false end
    function Triangle:onTapKindleArrow()
        if self.hidden then return false end
        if self.enabled and self.callback then self.callback() end
        return true
    end

    local ScrollBar = InputContainer:extend{
        enable = true, low = 0, high = 1,
        width = 0, height = 0,
        track_w = 2, thumb_w = 6, min_thumb = 12,
        scroll_callback = nil,
        horizontal = false, hidden = false,
    }
    function ScrollBar:init()
        if Device:isTouchDevice() then
            local range = function() return self.touch_dimen end
            local pan_rate = Screen.low_pan_rate and 2.0 or 5.0
            self.ges_events = {
                TapScroll         = { GestureRange:new{ ges = "tap", range = range } },
                HoldScroll        = { GestureRange:new{ ges = "hold", range = range } },
                HoldPanScroll     = { GestureRange:new{ ges = "hold_pan", rate = pan_rate, range = range } },
                HoldReleaseScroll = { GestureRange:new{ ges = "hold_release", range = range } },
                PanScroll         = { GestureRange:new{ ges = "pan", rate = pan_rate, range = range } },
                PanScrollRelease  = { GestureRange:new{ ges = "pan_release", range = range } },
            }
        end
    end
    function ScrollBar:onTapScroll(_arg, ges)
        if self.hidden then return false end
        if self.enable and self.scroll_callback and self.touch_dimen then
            if self.horizontal then
                self.scroll_callback((ges.pos.x - self.touch_dimen.x) / self.width)
            else
                self.scroll_callback((ges.pos.y - self.touch_dimen.y) / self.height)
            end
            return true
        end
    end
    ScrollBar.onHoldScroll        = ScrollBar.onTapScroll
    ScrollBar.onHoldPanScroll     = ScrollBar.onTapScroll
    ScrollBar.onHoldReleaseScroll = ScrollBar.onTapScroll
    ScrollBar.onPanScroll         = ScrollBar.onTapScroll
    ScrollBar.onPanScrollRelease  = ScrollBar.onTapScroll
    function ScrollBar:getSize() return Geom:new{ w = self.width, h = self.height } end
    function ScrollBar:set(low, high)
        self.low = low > 0 and low or 0
        self.high = high < 1 and high or 1
    end
    -- KoboUI: Kobo's scrollbar — a thin black line with a hollow,
    -- rounded thumb (white inside, black outline) for the part you see.
    function ScrollBar:paintTo(bb, x, y)
        if self.hidden or not self.enable then return end
        local b = math.max(2, Screen:scaleBySize(1.2))
        if self.horizontal then
            self.touch_dimen = Geom:new{ x = x, y = y - self.height, w = self.width, h = self.height * 3 }
            local cy = y + math.floor(self.height / 2)
            bb:paintRect(x, cy - math.floor(self.track_w / 2), self.width, self.track_w, Blitbuffer.COLOR_BLACK)
            local tw = math.max(self.min_thumb, math.floor(self.width * (self.high - self.low) + 0.5))
            local tx = x + math.floor(self.low * self.width + 0.5)
            if tx + tw > x + self.width then tx = x + self.width - tw end
            local th = self.thumb_w
            local r = math.floor(th / 2)
            bb:paintRoundedRect(tx, cy - r, tw, th, Blitbuffer.COLOR_BLACK, r)
            bb:paintRoundedRect(tx + b, cy - r + b, tw - 2 * b, th - 2 * b, Blitbuffer.COLOR_WHITE, math.max(0, r - b))
            return
        end
        self.touch_dimen = Geom:new{ x = x - self.width, y = y, w = self.width * 3, h = self.height }
        local cx = x + math.floor(self.width / 2)
        bb:paintRect(cx - math.floor(self.track_w / 2), y, self.track_w, self.height, Blitbuffer.COLOR_BLACK)
        local th = math.max(self.min_thumb, math.floor(self.height * (self.high - self.low) + 0.5))
        local ty = y + math.floor(self.low * self.height + 0.5)
        if ty + th > y + self.height then ty = y + self.height - th end
        local tw = self.thumb_w
        local r = math.floor(tw / 2)
        bb:paintRoundedRect(cx - r, ty, tw, th, Blitbuffer.COLOR_BLACK, r)
        bb:paintRoundedRect(cx - r + b, ty + b, tw - 2 * b, th - 2 * b, Blitbuffer.COLOR_WHITE, math.max(0, r - b))
    end

    return Triangle, ScrollBar
end

function M.install()
local ok_guard, FileChooser = pcall(require, "ui/widget/filechooser")

if ok_guard and FileChooser and not FileChooser._vlibscroll_patch_installed then
    FileChooser._vlibscroll_patch_installed = true

    local BD = require("ui/bidi")
    local Button = require("ui/widget/button")
    local Device = require("device")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Menu = require("ui/widget/menu")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalScrollBar = require("ui/widget/verticalscrollbar")
    local VerticalSpan = require("ui/widget/verticalspan")
    local logger = require("logger")
    local Screen = Device.screen

    -----------------------------------------------------------------------
    -- 1. The floating overlay widget: up-arrow / scrollbar / down-arrow,
    --    anchored to the right edge (left edge in mirrored/RTL layouts)
    --    of the file browser, spanning the item list's vertical extent.
    --
    --    buildArrowButtons()/assembleOverlayFrame() are split out of what
    --    used to be a single buildOverlay() function so that the WIDTH
    --    the overlay needs can be measured once (getReservedWidth(),
    --    below) using a disposable throwaway frame, cheaply, without
    --    needing fc to be init()'d yet -- the frame's width only depends
    --    on fixed, screen-scale-based constants (button/scrollbar sizes),
    --    never on fc.inner_dimen or the real track height. That measured
    --    width is what the _recalculateDimen wrap (section 2) subtracts
    --    from the item grid's available width, so covers/rows are laid
    --    out narrower and leave a real gutter -- rather than the overlay
    --    just floating on top of them with no space reserved.
    -----------------------------------------------------------------------

    local KTriangle, KScrollBar = kindleScrollWidgets()

    local function buildArrowButtons(fc)
        local margin = Screen:scaleBySize(6)
        -- width of the scrollbar's column (the triangles are this wide)
        local bar_w = Screen:scaleBySize(16)
        local span_h = Screen:scaleBySize(6)

        local function arrow(up, callback)
            return KTriangle:new{
                up = up,
                tri_w = bar_w,
                tri_h = math.floor(bar_w * 0.5 + 0.5),
                pad = Screen:scaleBySize(6),
                callback = callback,
            }
        end

        local up_btn = arrow(true, function() fc:onPrevPage() end)
        local down_btn = arrow(false, function() fc:onNextPage() end)

        return up_btn, down_btn, margin, bar_w, span_h
    end

    local function assembleOverlayFrame(fc, up_btn, down_btn, track_h, bar_w, margin, span_h)
        local scrollbar = KScrollBar:new{
            width = bar_w,
            height = track_h,
            track_w = math.max(1, Screen:scaleBySize(0.8)),
            thumb_w = math.max(8, Screen:scaleBySize(7)),
            min_thumb = Screen:scaleBySize(24),
            scroll_callback = function(ratio)
                local page_num = fc.page_num or 1
                if page_num <= 1 then return end
                local target = math.floor(ratio * page_num) + 1
                if target < 1 then target = 1 end
                if target > page_num then target = page_num end
                fc:onGotoPage(target)
            end,
        }

        local inner = VerticalGroup:new{
            align = "center",
            up_btn,
            VerticalSpan:new{ width = span_h },
            scrollbar,
            VerticalSpan:new{ width = span_h },
            down_btn,
        }

        -- No border/background: the triangles and the bar float over the
        -- book grid, like on a Kindle.
        local frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            inner,
        }

        return frame, scrollbar
    end

    -- Cached after the first successful measurement: the reserved width
    -- only depends on Screen:scaleBySize()/Size.border.thin, which don't
    -- change over a running session (rotation swaps w/h, not DPI scale).
    local cached_reserved_w = nil
    local function getReservedWidth(fc)
        if cached_reserved_w then return cached_reserved_w end
        local ok, w = pcall(function()
            local up_btn, down_btn, margin, bar_w, span_h = buildArrowButtons(fc)
            -- Placeholder track height: doesn't affect the frame's WIDTH,
            -- only its height, and we only read :getSize().w below.
            local frame = assembleOverlayFrame(fc, up_btn, down_btn, Screen:scaleBySize(60), bar_w, margin, span_h)
            return frame:getSize().w + margin
        end)
        if ok and w and w > 0 then
            cached_reserved_w = w
            return w
        end
        return 0
    end

    -- KoboUI: the Series bookshelf scrolls sideways, like walking along
    -- a bookcase — the same bar lies along the bottom, with ‹ › arrows.
    local function isHorizontal(fc)
        return fc and fc._kui_shelf_on and true or false
    end
    M.isHorizontal = isHorizontal

    local function hideWidget(w, hidden)
        if not w then return end
        w.hidden = hidden
        if w._kui_frame then w._kui_frame._kui_hidden = hidden end
    end

    -- How far the navigation bar's Current Book cover rises into the list
    -- area (the horizontal bar sits above it).
    local function coverRise()
        local ok, r = pcall(function()
            local BB = require("screens/sui_bottombar")
            local Config = require("infra/sui_config")
            local tabs = Config.loadTabConfig()
            local has = false
            for _i, t in ipairs(tabs or {}) do if t == "current_book" then has = true end end
            if not has then return 0 end
            local _cw, _ch, _bp, protrude = BB.currentBookCoverGeometry()
            return protrude or 0
        end)
        return ok and r or 0
    end

    -- Height kept free at the bottom for the horizontal bar.
    local function getReservedHeight(fc)
        local _u, _d, margin, bar_w = buildArrowButtons(fc)
        return bar_w + 2 * Screen:scaleBySize(6) + margin + coverRise()
    end
    M.getReservedHeight = getReservedHeight

    -- Applies the current page/page_num state of `menu_self` (a
    -- FileChooser instance we've decorated) to our overlay widgets, and
    -- forces the stock horizontal pager (chevrons + "Page X of Y") to
    -- stay hidden & inert. Safe to call repeatedly; safe to call even if
    -- some stock widgets were nil'd out by another plugin (e.g.
    -- SimpleUI's navbar feature).
    local function syncOverlayState(menu_self)
        if not menu_self._vlibscroll_bar then return end
        local ok, err = pcall(function()
            local page = menu_self.page or 1
            local page_num = menu_self.page_num or 1

            -- vertical bar on the right, or (Series bookshelf) the
            -- horizontal one along the bottom
            local horiz = isHorizontal(menu_self) and menu_self._kui_hbar ~= nil
            local bar   = horiz and menu_self._kui_hbar   or menu_self._vlibscroll_bar
            local prev  = horiz and menu_self._kui_hleft  or menu_self._vlibscroll_up
            local nextb = horiz and menu_self._kui_hright or menu_self._vlibscroll_down
            if menu_self._vlibscroll_frame then menu_self._vlibscroll_frame._kui_hidden = horiz end
            hideWidget(menu_self._vlibscroll_bar, horiz)
            hideWidget(menu_self._vlibscroll_up, horiz)
            hideWidget(menu_self._vlibscroll_down, horiz)
            if menu_self._kui_hframe then menu_self._kui_hframe._kui_hidden = not horiz end
            hideWidget(menu_self._kui_hbar, not horiz)
            hideWidget(menu_self._kui_hleft, not horiz)
            hideWidget(menu_self._kui_hright, not horiz)

            if page_num > 1 then
                bar.enable = true
                bar:set((page - 1) / page_num, page / page_num)
                prev:enableDisable(page > 1)
                nextb:enableDisable(page < page_num)
            else
                bar.enable = false
                prev:enableDisable(false)
                nextb:enableDisable(false)
            end

            for _i, w in ipairs{
                menu_self.page_info_left_chev,
                menu_self.page_info_right_chev,
                menu_self.page_info_first_chev,
                menu_self.page_info_last_chev,
                menu_self.page_info_text,
            } do
                if w then
                    -- A Button rebuilt with init() (KoboUI resizes the
                    -- pagination icons that way) is visible again but
                    -- still flagged hidden, so hide() would do nothing.
                    if w.hidden and w.label_widget and not w.label_widget.hide then
                        w.hidden = false
                    end
                    if w.hide then w:hide() end
                    if w.disable then w:disable() end
                end
            end
            -- Button:hide() only hides icon buttons, so the "Page x of y"
            -- text button is blanked instead.
            M.blankPageText(menu_self)
        end)
        if not ok then
            logger.warn("kindleui/vscroll: syncOverlayState failed:", err)
        end
    end

    -- Re-applies the hidden pager after something rebuilt its buttons.
    M.sync = syncOverlayState
    -- Width kept free on the right for the scrollbar (used by the Series
    -- bookshelf, which lays out its own pages).
    M.getReservedWidth = getReservedWidth

    -- Builds the [up-arrow / scrollbar / down-arrow] overlay and appends
    -- it to `fc`'s own widget tree (fc[1][1] is the OverlapGroup
    -- Menu:init() builds to stack the item list, the "go up" return
    -- arrow and the footer pager on top of each other -- appending here
    -- makes our overlay paint on top of all of those, i.e. floating
    -- above the book grid/list).
    local function buildOverlay(fc)
        local top_height = (fc.title_bar and not fc.no_title) and fc.title_bar:getHeight() or 0
        local avail_h = fc.available_height or (fc.inner_dimen.h - top_height)
        if avail_h <= 0 then return end

        local up_btn, down_btn, margin, bar_w, span_h = buildArrowButtons(fc)

        local reserved = up_btn:getSize().h + down_btn:getSize().h + 2 * span_h + 2 * margin
        local track_h = avail_h - reserved
        local min_track_h = Screen:scaleBySize(60)
        if track_h < min_track_h then
            track_h = math.min(min_track_h, avail_h > 0 and avail_h or min_track_h)
        end

        local frame, scrollbar = assembleOverlayFrame(fc, up_btn, down_btn, track_h, bar_w, margin, span_h)

        local size = frame:getSize()
        local x
        if BD.mirroredUILayout() then
            x = margin
        else
            x = fc.inner_dimen.w - size.w - margin
        end
        local y = top_height + math.max(margin, math.floor((avail_h - size.h) / 2))
        frame.overlap_offset = { x, y }

        fc._vlibscroll_frame = frame
        fc._vlibscroll_bar = scrollbar
        fc._vlibscroll_up = up_btn
        fc._vlibscroll_down = down_btn

        local function hideable(f)
            local orig_paint = f.paintTo
            f.paintTo = function(self, ...)
                if self._kui_hidden then return end
                return orig_paint(self, ...)
            end
        end
        hideable(frame)
        table.insert(fc[1][1], frame)

        -- The horizontal version, for the Series bookshelf (file browser
        -- only): ‹ bar › along the bottom of the list area.
        if fc.name == "filemanager" then
            local pad = Screen:scaleBySize(6)
            local function harrow(dir, cb)
                return KTriangle:new{
                    dir = dir, up = false,
                    tri_w = math.floor(bar_w * 0.5 + 0.5), tri_h = bar_w,
                    pad = pad, callback = cb,
                }
            end
            local left_btn  = harrow("left",  function() fc:onPrevPage() end)
            local right_btn = harrow("right", function() fc:onNextPage() end)
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan  = require("ui/widget/horizontalspan")
            local full_w = fc.inner_dimen.w
            local track_w = full_w - 2 * margin - left_btn:getSize().w - right_btn:getSize().w - 2 * span_h
            local hbar = KScrollBar:new{
                horizontal = true,
                width = math.max(Screen:scaleBySize(60), track_w),
                height = bar_w,
                track_w = math.max(1, Screen:scaleBySize(0.8)),
                thumb_w = math.max(8, Screen:scaleBySize(7)),
                min_thumb = Screen:scaleBySize(16),
                scroll_callback = scrollbar.scroll_callback,
            }
            local hframe = FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0,
                HorizontalGroup:new{
                    align = "center",
                    left_btn, HorizontalSpan:new{ width = span_h },
                    hbar, HorizontalSpan:new{ width = span_h },
                    right_btn,
                },
            }
            local hs = hframe:getSize()
            hframe.overlap_offset = { math.floor((full_w - hs.w) / 2),
                top_height + avail_h - hs.h - math.floor(margin / 2) - coverRise() }
            hideable(hframe)
            hframe._kui_hidden = true
            fc._kui_hframe, fc._kui_hbar = hframe, hbar
            fc._kui_hleft, fc._kui_hright = left_btn, right_btn
            hideWidget(hbar, true); hideWidget(left_btn, true); hideWidget(right_btn, true)
            table.insert(fc[1][1], hframe)
        end

        syncOverlayState(fc)
    end

    -----------------------------------------------------------------------
    -- 2. Hook FileChooser:init() -- two things happen here, in order:
    --
    --    a) BEFORE calling through to the stock (possibly
    --       already-patched-by-someone-else) init, install an
    --       instance-level override of self:_recalculateDimen() that
    --       temporarily shrinks self.inner_dimen.w by the overlay's
    --       measured width for the duration of that one call, then
    --       restores it. _recalculateDimen is what Mosaic/List/classic
    --       mode all use to compute item/row width from inner_dimen.w
    --       (self:_recalculateDimen() is always called via ":", i.e.
    --       dynamic method dispatch -- so an instance-level override
    --       here really does take priority over whatever class-level
    --       implementation CoverBrowser has installed for the current
    --       display mode, without us having to know or care which mode
    --       that is). The net effect: covers/rows are laid out narrower
    --       from the start, leaving a real gutter on the right for the
    --       overlay -- instead of the overlay floating on top of them.
    --
    --       This has to happen *before* orig_fc_init runs, since that's
    --       what triggers the first _recalculateDimen() call.
    --
    --    b) AFTER orig_fc_init has finished setting up the title bar /
    --       footer / item list, build and position the actual overlay,
    --       same as before -- and only for the real file-manager/library
    --       screen (self.name == "filemanager"), not other FileChooser
    --       popups.
    -----------------------------------------------------------------------

    local orig_fc_init = FileChooser.init
    FileChooser.init = function(self, ...)
        if self.name == "filemanager" and isEnabled() then
            local reserved = getReservedWidth(self)
            if reserved > 0 and not self._vlibscroll_recalc_installed then
                self._vlibscroll_recalc_installed = true
                local orig_recalc = self._recalculateDimen
                self._recalculateDimen = function(inst, ...)
                    local dimen = inst.inner_dimen
                    local true_w = dimen and dimen.w
                    if dimen and true_w and isEnabled() then
                        dimen.w = true_w - reserved
                    end
                    local ok, err = pcall(orig_recalc, inst, ...)
                    if dimen and true_w then
                        dimen.w = true_w
                    end
                    if not ok then
                        logger.warn("kindleui/vscroll: _recalculateDimen failed:", err)
                    end
                end
            end
        end

        orig_fc_init(self, ...)

        if self.name == "filemanager" and isEnabled() then
            local ok, err = pcall(buildOverlay, self)
            if not ok then
                logger.warn("kindleui/vscroll: buildOverlay failed:", err)
            end
        end
    end

    -----------------------------------------------------------------------
    -- 2b. KoboUI: KOReader's own collection screens (the collections
    --     list and a collection's book list) are plain Menus, not the
    --     FileChooser. Give them the same scrollbar, reserved gutter and
    --     up/down swipes, so they don't show the stock arrows.
    -----------------------------------------------------------------------

    local function isCollectionsMenu(menu)
        if menu.name == "filemanager" then return false end
        if menu.name == "collections" then return true end
        local mgr = menu._manager
        return type(mgr) == "table" and mgr.default_collection_title ~= nil
    end

    local orig_menu_init = Menu.init
    Menu.init = function(self, ...)
        local wanted = isEnabled() and isCollectionsMenu(self) and not self._vlibscroll_recalc_installed
        if wanted then
            local reserved = getReservedWidth(self)
            if reserved > 0 then
                self._vlibscroll_recalc_installed = true
                local orig_recalc = self._recalculateDimen
                self._recalculateDimen = function(inst, ...)
                    local dimen = inst.inner_dimen
                    local true_w = dimen and dimen.w
                    if dimen and true_w and isEnabled() then dimen.w = true_w - reserved end
                    local ok, err = pcall(orig_recalc, inst, ...)
                    if dimen and true_w then dimen.w = true_w end
                    if not ok then logger.warn("kindleui/vscroll: _recalculateDimen failed:", err) end
                end
            end
        end
        orig_menu_init(self, ...)
        if wanted and not self._vlibscroll_bar then
            local ok, err = pcall(buildOverlay, self)
            if not ok then logger.warn("kindleui/vscroll: collections overlay failed:", err) end
            -- Swipe up/down turns pages; left/right no longer does.
            self.onSwipe = function(menu, arg, ges_ev)
                if not (menu._vlibscroll_bar and isEnabled()) then
                    return Menu.onSwipe(menu, arg, ges_ev)
                end
                local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
                if direction == "north" then
                    menu:onNextPage()
                elseif direction == "south" then
                    if ges_ev.pos and ges_ev.pos.y < topZoneHeight() then
                        return Menu.onSwipe(menu, arg, ges_ev)
                    end
                    menu:onPrevPage()
                elseif direction ~= "west" and direction ~= "east" then
                    return Menu.onSwipe(menu, arg, ges_ev)
                end
                return true
            end
        end
    end

    -----------------------------------------------------------------------
    -- 3. Hook Menu:updatePageInfo() -- called every time the
    --    page/selection changes (page turn, refresh, etc). Piggyback on
    --    it to keep the scrollbar thumb and arrow enabled/disabled state
    --    in sync, and to keep re-hiding the stock footer pager (it
    --    re-shows itself here on every call, so ours must run after,
    --    every time too).
    -----------------------------------------------------------------------

    local orig_updatePageInfo = Menu.updatePageInfo
    Menu.updatePageInfo = function(self, select_number)
        orig_updatePageInfo(self, select_number)
        if self._vlibscroll_bar then
            syncOverlayState(self)
        elseif type(self.path) == "string" and self.path:find("/.simpleui-browse/", 1, true) then
            -- Author / series views: the "Page x of y" line sits behind the
            -- navigation bar's Current Book cover; the title bar already
            -- says where you are, so it is left out.
            M.blankPageText(self)
        end
    end

    -----------------------------------------------------------------------
    -- 4. Make swipes actually turn pages.
    --
    --    4a) Wrap FileManager:onSwipeFM() -- this is where stock KOReader
    --        decides what a swipe does in the file manager (Menu:onSwipe()
    --        is *not* used for the top-level file manager -- it delegates
    --        to GestureManager/touch zones instead, see menu.lua). Kept
    --        as a belt-and-braces remap of swipe-up/down to next/prev
    --        page (and swallowing swipe-left/right) for anything that
    --        calls onSwipeFM directly.
    --
    --    4b) THE ACTUAL FIX for "no gesture works": register our own
    --        touch zone that runs *before* "filemanager_swipe".
    --
    --        Why 4a alone is not enough: stock KOReader registers a
    --        full-screen "filemanager_swipe" touch zone (in
    --        FileManager:initGesListener()) whose handler calls
    --        self:onSwipeFM(ges) for every swipe direction -- so 4a on
    --        its own is enough with plain stock KOReader. But SimpleUI
    --        (infra/sui_patches.lua, patchFileManagerClass) *replaces*
    --        that same zone id with its own handler, which explicitly
    --        does NOT call onSwipeFM for north/south (vertical) swipes:
    --        it returns false for those on purpose, so the swipe falls
    --        through to FileManagerMenu's top-of-screen zones and opens
    --        SimpleUI's menu instead. That's a deliberate SimpleUI
    --        design choice for its own navigation, but it means our 4a
    --        wrap is simply never reached for vertical swipes once
    --        SimpleUI is installed -- no matter what it does internally.
    --
    --        The fix is to register a zone of our own, under a
    --        different id, that `overrides` (i.e. is checked before)
    --        "filemanager_swipe" -- whichever version of it currently
    --        exists, stock's or SimpleUI's. KOReader's touch-zone
    --        override graph (DepGraph, in registerTouchZones) resolves
    --        purely by id and tolerates forward references, so this
    --        works regardless of plugin load order. When our mode is
    --        off, or the swipe isn't north/south, our handler returns
    --        false and dispatch falls through to "filemanager_swipe"
    --        exactly as if we weren't here -- so this can't break
    --        horizontal paging, menu-opening swipes, or anything else
    --        when vertical mode is disabled.
    -----------------------------------------------------------------------

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager then
        -- 4a.
        local orig_onSwipeFM = FileManager.onSwipeFM
        FileManager.onSwipeFM = function(self, ges)
            local fc = self.file_chooser
            if fc and fc._vlibscroll_bar and isEnabled() then
                local ok, handled = pcall(function()
                    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
                    if isHorizontal(fc) then
                        -- Series bookshelf: sideways, like a bookcase
                        if direction == "west" then fc:onNextPage() return true end
                        if direction == "east" then fc:onPrevPage() return true end
                        return direction == "north" or direction == "south"
                    end
                    if direction == "north" then
                        fc:onNextPage()
                        return true
                    elseif direction == "south" then
                        fc:onPrevPage()
                        return true
                    elseif direction == "west" or direction == "east" then
                        -- Vertical mode replaces horizontal paging: swallow it.
                        return true
                    end
                    return false
                end)
                if ok and handled then
                    return true
                end
            end
            return orig_onSwipeFM(self, ges)
        end

        -- 4b.
        local orig_initGesListener = FileManager.initGesListener
        FileManager.initGesListener = function(self, ...)
            orig_initGesListener(self, ...)
            local ok, err = pcall(function()
                self:registerTouchZones({
                    {
                        id = "vertical_library_scroll_swipe",
                        ges = "swipe",
                        screen_zone = {
                            ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
                        },
                        overrides = { "filemanager_swipe" },
                        handler = function(ges)
                            local fc = self.file_chooser
                            if not (fc and fc._vlibscroll_bar and isEnabled()) then
                                return false
                            end
                            local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
                            -- KoboUI: a swipe down that starts in the top bar
                            -- still pulls down the quick-settings menu.
                            if direction == "south" and ges.pos and ges.pos.y < topZoneHeight() then
                                return false
                            end
                            if isHorizontal(fc) then
                                -- Series bookshelf: swipe left/right walks
                                -- along the shelves; up/down does nothing.
                                if direction == "west" then fc:onNextPage() return true end
                                if direction == "east" then fc:onPrevPage() return true end
                                return direction == "north" or direction == "south"
                            end
                            if direction == "north" then
                                fc:onNextPage()
                                return true
                            elseif direction == "south" then
                                fc:onPrevPage()
                                return true
                            elseif direction == "west" or direction == "east" then
                                -- Vertical mode replaces horizontal paging: swallow it.
                                return true
                            end
                            return false
                        end,
                    },
                })
            end)
            if not ok then
                logger.warn("kindleui/vscroll: registering swipe zone failed:", err)
            end
        end
    end

    logger.info("kindleui: vertical library scroll hooks installed")
end
end -- M.install


--- Turns the mode on/off and rebuilds the library screen if it's open.
function M.setEnabled(on)
    G_reader_settings:saveSetting(SETTING_KEY, on and true or false)
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        UIManager:nextTick(function()
            if FileManager.instance then
                FileManager.instance:reinit()
            end
        end)
    end
end

--- A KOReader menu item (used in File browser → Settings and in KoboUI's
--- own settings).
function M.menuItem()
    return {
        text = _("Vertical scrolling library"),
        help_text = _("Browse the library as vertically scrolling pages instead of horizontal swipe/arrows: swipe up/down to turn pages, or use the scrollbar and arrows on the right edge of the screen."),
        checked_func = function() return isEnabled() end,
        callback = function() M.setEnabled(not isEnabled()) end,
    }
end

--- Adds the toggle to KOReader's File browser → Settings submenu.
function M.addToMainMenu(menu_items)
    local item = M.menuItem()
    local fbs = menu_items.filebrowser_settings
    if fbs and fbs.sub_item_table then
        item.separator = true
        table.insert(fbs.sub_item_table, item)
    else
        menu_items.kindleui_vertical_library_scroll = item
    end
end

return M
