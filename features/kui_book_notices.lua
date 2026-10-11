--[[
kui_book_notices.lua — KoboUI

Hides the "Opening file '…'." popup that KOReader shows while a book loads
(ReaderUI:showReaderCoroutine). The screen just keeps showing what was there
until the book is ready, like KindleOS. The "Closing book…" notice is skipped
in main.lua (onCloseDocument) under the same setting.

Setting: kindleui_hide_book_notices (default on).
How: while showReaderCoroutine runs, InfoMessages with timeout == 0 (the
self-closing loading notice) are shown invisibly, the way KOReader does for
"seamless" opening (skipping them would leave no window open and KOReader
would quit). Error messages have no
timeout, so they still show. Language independent.
]]

local M = {}

local KEY = "kindleui_hide_book_notices"

function M.isEnabled()
    local SUISettings = require("infra/sui_store")
    return SUISettings:nilOrTrue(KEY)
end

function M.setEnabled(on)
    local SUISettings = require("infra/sui_store")
    SUISettings:saveSetting(KEY, on and true or false)
end

local installed = false
function M.install()
    if installed then return end
    installed = true
    local UIManager   = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ReaderUI    = require("apps/reader/readerui")

    local depth = 0
    local orig_show = UIManager.show
    UIManager.show = function(self, widget, ...)
        if depth > 0 and type(widget) == "table" and widget.timeout == 0
                and getmetatable(widget) == InfoMessage then
            -- Shown invisibly rather than skipped: KOReader has just closed
            -- the file browser, and this message is the only window left
            -- until the book opens. With no window at all, KOReader would
            -- think everything is closed and quit.
            widget.invisible = true
        end
        return orig_show(self, widget, ...)
    end

    local orig_src = ReaderUI.showReaderCoroutine
    if type(orig_src) == "function" then
        ReaderUI.showReaderCoroutine = function(...)
            if not M.isEnabled() then return orig_src(...) end
            depth = depth + 1
            local ok, err = pcall(orig_src, ...)
            depth = depth - 1
            if not ok then error(err, 0) end
        end
    end
end

return M
