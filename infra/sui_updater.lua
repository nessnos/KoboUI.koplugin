-- sui_updater.lua — KoboUI
-- SimpleUI's GitHub self-updater is switched off in KoboUI: it would
-- download SimpleUI over KoboUI. This stub keeps the same API so callers
-- don't need to change. KoboUI is updated by copying a new folder.

local M = {}

function M.hasUpdate() return false end
function M.latestVersion() return nil end
function M.scheduleAutoCheck() end
function M.checkForUpdates()
    local ok, UI = pcall(require, "infra/sui_core")
    local _ = require("infra/sui_i18n").translate
    if ok and UI and UI.Notify and UI.Notify.toast then
        UI.Notify.toast(_("KoboUI is updated by replacing the KoboUI.koplugin folder."), 4)
    end
end
function M._doManualCheck() end
function M.build_update_banner_item() return nil end

return M
