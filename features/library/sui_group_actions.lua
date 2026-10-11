-- sui_group_actions.lua — KoboUI
-- Shared "cover picker" and "create collection" dialogs for anything that
-- is conceptually a group of books the user can enter: a plain folder, an
-- in-folder series group, or a virtual author/series/tag leaf.
--
-- Previously each of those three had its own near-identical copy of this
-- UI (sui_foldercovers._openFolderCoverPicker / _openSeriesGroupCoverPicker,
-- sui_browsemeta._openVirtualCoverPicker, etc). Callers now just supply the
-- list of books and an override key; the dialog logic lives here once.
--
-- Public API
-- ----------
--   GroupActions.openCoverPicker(args)
--     args.title          -- dialog title, defaults to "Folder cover"
--     args.override_key   -- string key used with sui_cover_overrides
--     args.items          -- { {path=fullpath, title=display_title}, ... }
--     args.menu           -- the FileChooser/menu widget to invalidate after a change
--     args.empty_message  -- shown instead of the picker when items is empty
--
--   GroupActions.createCollection(args)
--     args.suggested_name       -- pre-filled name (may be "")
--     args.paths                -- { fullpath, ... } snapshot books (optional if connect_folder)
--     args.empty_message        -- shown when neither paths nor connect_folder yield work
--     args.connect_folder       -- filesystem path to link (KOReader connected-folder model)
--     args.connect_subfolders   -- scan subfolders when connecting
--     args.connect_scan_on_show -- rescan when opening the collection (default true)

local _ = require("infra/sui_i18n").translate
local UI = require("infra/sui_core")
local CoverOverrides = require("features/library/sui_cover_overrides")

local GroupActions = {}

function GroupActions.openCoverPicker(args)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
        local items = args.items or {}
    if #items == 0 then
        UI.Notify.toast(args.empty_message or _("No books found."), 2)
        return
    end

    local override_key = args.override_key
    local menu          = args.menu
    local cur_override  = CoverOverrides.get(override_key)

    local picker
    local buttons = {}

    buttons[#buttons + 1] = {{
        text = (not cur_override and "\u{2713} " or "  ") .. _("Auto (first book)"),
        callback = function()
            UIManager:close(picker)
            CoverOverrides.clear(override_key)
            CoverOverrides.invalidateGridItem(menu, override_key)
        end,
    }}

    for _, item in ipairs(items) do
        local fp    = item.path
        local title = (item.title and item.title ~= "") and item.title
            or (fp:match("([^/]+)%.[^%.]+$") or fp)
        buttons[#buttons + 1] = {{
            text = ((cur_override == fp) and "\u{2713} " or "  ") .. title,
            callback = function()
                UIManager:close(picker)
                CoverOverrides.set(override_key, fp)
                CoverOverrides.invalidateGridItem(menu, override_key)
            end,
        }}
    end

    buttons[#buttons + 1] = {{
        text = _("Cancel"),
        callback = function() UIManager:close(picker) end,
    }}

    picker = ButtonDialog:new{
        title = args.title or _("Folder cover"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(picker)
end

function GroupActions.createCollection(args)
    local UIManager   = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local T           = require("ffi/util").template

    local paths = args.paths or {}
    local connect_folder = args.connect_folder
    -- Snapshot collections need at least one book; connected folders may start empty
    -- and pick up files on later scans.
    if #paths == 0 and not connect_folder then
        UI.Notify.toast(args.empty_message or _("No books found."), 2)
        return
    end

    local RC = require("readcollection")
    local input_dialog
    input_dialog = InputDialog:new{
        title   = _("New collection name"),
        input   = args.suggested_name or "",
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function() UIManager:close(input_dialog) end,
            },
            {
                text = _("Create"),
                callback = function()
                    local name = input_dialog:getInputText()
                    if name == "" then return end
                    UIManager:close(input_dialog)

                    if RC.coll[name] then
                        UI.Notify.toast(T(_("Collection already exists: %1"), name))
                        return
                    end

                    RC:addCollection(name)
                    local count = 0

                    if connect_folder then
                        -- Live link: same model as KOReader "Connect folders".
                        local settings = RC.coll_settings[name]
                        settings.folders = settings.folders or {}
                        settings.folders[connect_folder] = {
                            subfolders    = args.connect_subfolders and true or false,
                            scan_on_show  = args.connect_scan_on_show ~= false,
                        }
                        local n = RC:updateCollectionFromFolder(name)
                        if type(n) == "number" then count = n end
                    else
                        for _, fp in ipairs(paths) do
                            if not RC.coll[name][fp] then
                                RC:addItem(fp, name)
                                count = count + 1
                            end
                        end
                    end
                    RC:write({ [name] = true })

                    UI.Notify.toast(T(_("Collection \"%1\" created with %2 books."), name, count))
                end,
            },
        }},
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return GroupActions
