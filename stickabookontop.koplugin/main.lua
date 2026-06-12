--[[--
Stick a book on top: pin books and folders to the top of the file browser.

Long-press a book or a folder in the file browser to pin or unpin it.
Up to 4 books and 2 folders can be pinned. Pinned entries are moved to the
top of their folder listing and marked with a pushpin at their top-left
corner: drawn over the cover in CoverBrowser's mosaic/list display modes,
shown as a glyph before the name in the classic display mode.

In addition, every pinned book that does not already live in the HOME folder
gets a "shortcut" entry at the top of the HOME folder. The shortcut looks
just like the book (same cover, name, status) and opens the real file; the
real file stays where it is and stays pinned in its own folder. Shortcuts are
marked with an "open in new" badge at their top-RIGHT corner (a glyph before
the name in classic mode) to tell them apart from real entries.

Pins are stored in settings/stick_a_book_on_top.lua and are shared by all
FileManager instances; this module therefore patches the FileChooser and
FileManager classes once, at plugin load time, the same way CoverBrowser
does (this also makes it work for the very first folder listing, which is
built before plugin instances get access to the file chooser).
--]]

local DataStorage = require("datastorage")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local ImageWidget = require("ui/widget/imagewidget")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

-- Glyphs from nerdfonts/symbols.ttf, always among the UI font fallbacks
local PIN_GLYPH = "\u{F08D}"      -- thumbtack
local SHORTCUT_GLYPH = "\u{F08E}" -- external-link / open-in-new

local KIND_PROPS = {
    files   = { mode = "file",      max = 4, label = "书籍",   unit = "本" },
    folders = { mode = "directory", max = 2, label = "文件夹", unit = "个" },
}
local CN_ORDINAL = { "一", "二", "三", "四" }

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/") or "."

-- Pinned paths in pin order, shared across FileManager instances
local pins = { files = {}, folders = {} }
local pins_lookup = {} -- path -> true, for quick checks at paint time
local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/stick_a_book_on_top.lua")

local function rebuildLookup()
    pins_lookup = {}
    for _, list in pairs(pins) do
        for __, path in ipairs(list) do
            pins_lookup[path] = true
        end
    end
end

local function loadPins()
    for kind, props in pairs(KIND_PROPS) do
        local list = settings:readSetting(kind, {})
        -- drop pins whose target has been deleted, moved or renamed
        for i = #list, 1, -1 do
            if lfs.attributes(list[i], "mode") ~= props.mode then
                table.remove(list, i)
            end
        end
        pins[kind] = list
    end
    rebuildLookup()
end

local function savePins()
    for kind in pairs(KIND_PROPS) do
        settings:saveSetting(kind, pins[kind])
    end
    settings:flush()
    rebuildLookup()
end

loadPins()

-- Badge icons (pushpin / shortcut), cached per name and size
local badge_icons = {}
local function getBadgeIcon(name, size)
    if size <= 0 then return end
    badge_icons[name] = badge_icons[name] or {}
    local icon = badge_icons[name][size]
    if icon == nil then
        local icon_file = plugin_dir .. "/" .. name .. ".svg"
        if lfs.attributes(icon_file, "mode") == "file" then
            icon = ImageWidget:new{
                file = icon_file,
                width = size,
                height = size,
                alpha = true,
            }
        else
            logger.warn("stickabookontop:", name .. ".svg not found in", plugin_dir)
            icon = false
        end
        badge_icons[name][size] = icon
    end
    return icon or nil
end

-- Resolve the HOME folder across KOReader versions:
-- filemanagerutil.getHomeFolder() only exists in newer versions (> v2026.03).
local function getHomeFolder()
    if filemanagerutil.getHomeFolder then
        return filemanagerutil.getHomeFolder()
    end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home then return home end
    if filemanagerutil.getDefaultDir then
        return filemanagerutil.getDefaultDir()
    end
end

-- Build a synthetic file-browser item for a pinned file that physically lives
-- elsewhere, so it can be shown as a shortcut in the HOME folder. The item
-- points at the real path, so it renders the real cover/name and opens the
-- real file; it is flagged is_shortcut for badge drawing.
local function buildShortcutItem(self, realpath, collate)
    local attributes = lfs.attributes(realpath)
    if not attributes or attributes.mode ~= "file" then return nil end
    local parent, filename = util.splitFilePathName(realpath)
    local item = self:getListItem(parent, filename, realpath, attributes, collate)
    item.is_shortcut = true
    return item
end

-- Move pinned entries to the top of the file browser listing:
-- "../" first, then pinned folders, then pinned books, then HOME shortcuts to
-- pinned books that live elsewhere, then everything else in its usual order.
local function processItemTable(self, path, item_table)
    -- Build HOME shortcuts for pinned books that are not already in HOME
    local shortcuts = {}
    local home = ffiUtil.realpath(getHomeFolder())
    if home and ffiUtil.realpath(path) == home and not FileChooser.show_flat_view then
        local collate = self:getCollate()
        for _, realpath in ipairs(pins.files) do
            local parent = ffiUtil.realpath((util.splitFilePathName(realpath)))
            if parent ~= home then -- already shown as a real entry when in HOME
                local item = buildShortcutItem(self, realpath, collate)
                if item then
                    table.insert(shortcuts, item)
                end
            end
        end
    end

    if #pins.files == 0 and #pins.folders == 0 and #shortcuts == 0 then
        return item_table
    end

    local rank = {}
    for i, p in ipairs(pins.folders) do rank[p] = i end
    for i, p in ipairs(pins.files) do rank[p] = #pins.folders + i end
    local head, pinned, rest = {}, {}, {}
    for _, item in ipairs(item_table) do
        if item.path and rank[item.path] then
            table.insert(pinned, item)
        elseif item.is_go_up or (item.path and item.path:match("/%.$")) then
            table.insert(head, item) -- navigation entries stay above the pins
        else
            table.insert(rest, item)
        end
    end
    if #pinned == 0 and #shortcuts == 0 then
        return item_table
    end
    table.sort(pinned, function(a, b) return rank[a.path] < rank[b.path] end)

    if not self.display_mode_type then
        -- classic display mode: covers are not drawn, so mark entries with a
        -- glyph before the name instead of a corner badge
        for _, item in ipairs(pinned) do
            item.text = PIN_GLYPH .. " " .. item.text
        end
        for _, item in ipairs(shortcuts) do
            item.text = SHORTCUT_GLYPH .. " " .. item.text
        end
    end

    local reordered = {}
    for _, group in ipairs({ head, pinned, shortcuts, rest }) do
        for __, item in ipairs(group) do
            reordered[#reordered + 1] = item
        end
    end
    return reordered
end

-- pcall-protected wrapper: if anything in our processing breaks (e.g. on an
-- untested KOReader version), fall back to the unmodified listing instead of
-- taking the file browser down with us.
local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
FileChooser.genItemTableFromPath = function(self, path)
    local item_table = orig_genItemTableFromPath(self, path)
    if self.name ~= "filemanager" then
        return item_table
    end
    local ok, result = pcall(processItemTable, self, path, item_table)
    if not ok then
        logger.warn("stickabookontop: failed to process item table:", result)
        return item_table
    end
    return result or item_table
end

-- Draw a corner badge on pinned entries (pushpin, top-left) and on HOME
-- shortcuts (open-in-new, top-right) in CoverBrowser's mosaic/list modes.
local function paintBadges(self, bb)
    local mode = self.display_mode_type
    local function paintBadge(w, icon_name, corner)
        -- anchor rectangle: the cover frame in mosaic, the whole row in list
        local ax, ay, aw = w.dimen.x, w.dimen.y, w.dimen.w
        local size
        if mode == "mosaic" then
            size = math.floor(math.min(w.dimen.w, w.dimen.h) / 7)
            local target = w[1] and w[1][1] and w[1][1][1]
            if target and target.dimen and target.dimen.w > 0 then
                ax, ay, aw = target.dimen.x, target.dimen.y, target.dimen.w
            end
        else -- "list": the cover thumbnail sits at the left edge of the row
            size = math.floor(w.dimen.h / 6)
        end
        local badge_x = corner == "right" and (ax + aw - size) or ax
        local icon = getBadgeIcon(icon_name, size)
        if icon then
            icon:paintTo(bb, badge_x, ay)
        end
    end
    local function walk(container)
        for i = 1, #container do
            local w = container[i]
            if w.entry then -- a menu item widget
                if w.dimen and w.dimen.w > 0 and w.entry.path then
                    if w.entry.is_shortcut then
                        paintBadge(w, "shortcut", "right")
                    elseif pins_lookup[w.entry.path] then
                        paintBadge(w, "pushpin", "left")
                    end
                end
            elseif #w > 0 then -- a layout container, e.g. a mosaic row
                walk(w)
            end
        end
    end
    walk(self.item_group)
end

local orig_paintTo = FileChooser.paintTo
FileChooser.paintTo = function(self, bb, x, y)
    orig_paintTo(self, bb, x, y)
    if self.name ~= "filemanager" or not self.display_mode_type then
        return
    end
    local ok, err = pcall(paintBadges, self, bb)
    if not ok then
        logger.warn("stickabookontop: failed to paint badges:", err)
    end
end

local function refreshFileManager()
    local fm = FileManager.instance
    if not fm or not fm.file_chooser then return end
    if fm.file_chooser.file_dialog then
        UIManager:close(fm.file_chooser.file_dialog)
        fm.file_chooser.file_dialog = nil
    end
    fm.file_chooser:refreshPath()
end

-- Build the pin/unpin button rows for the long-press file dialog.
-- Returns up to 3 rows: pinning to a position, moving an already pinned
-- entry, and unpinning are all offered, with at most 2 buttons per row.
local function buildPinRows(file, is_file)
    if not file or file:match("/%.%.?$") then return {} end -- skip "../"
    local kind = is_file and "files" or "folders"
    local props = KIND_PROPS[kind]
    local list = pins[kind]
    local cur_pos
    for i, path in ipairs(list) do
        if path == file then
            cur_pos = i
            break
        end
    end
    local function doPin(target_pos)
        if cur_pos then
            table.remove(list, cur_pos)
        end
        table.insert(list, math.min(target_pos, #list + 1), file)
        savePins()
        refreshFileManager()
    end
    local function genPinButton(target_pos)
        return {
            text = "置顶到第" .. CN_ORDINAL[target_pos] .. props.unit,
            callback = function() doPin(target_pos) end,
        }
    end
    local rows = {}
    local position_buttons = {}
    if cur_pos then
        table.insert(rows, { {
            text = PIN_GLYPH .. " 取消置顶（当前第" .. CN_ORDINAL[cur_pos] .. props.unit .. "）",
            callback = function()
                table.remove(list, cur_pos)
                savePins()
                refreshFileManager()
            end,
        } })
        for i = 1, #list do
            if i ~= cur_pos then
                table.insert(position_buttons, genPinButton(i))
            end
        end
    elseif #list == 0 then
        table.insert(rows, { {
            text = PIN_GLYPH .. " 置顶" .. props.label,
            callback = function() doPin(1) end,
        } })
    elseif #list < props.max then
        for i = 1, #list + 1 do
            table.insert(position_buttons, genPinButton(i))
        end
    else
        table.insert(rows, { {
            text = "置顶已满（最多" .. props.max .. props.unit .. props.label .. "）",
            enabled = false,
            callback = function() end,
        } })
    end
    for i = 1, #position_buttons, 2 do
        table.insert(rows, { position_buttons[i], position_buttons[i + 1] })
    end
    return rows
end

if FileManager.addFileDialogButtons then
    for row = 1, 3 do
        FileManager.addFileDialogButtons(FileManager, "stick_a_book_on_top_" .. row,
            function(file, is_file, book_props) -- luacheck: no unused args
                return buildPinRows(file, is_file)[row]
            end)
    end
else
    logger.warn("stickabookontop: FileManager.addFileDialogButtons not available,",
        "pin/unpin dialog buttons disabled; please update KOReader")
end

local StickABookOnTop = WidgetContainer:extend{
    name = "stickabookontop",
}

function StickABookOnTop:init()
end

return StickABookOnTop
