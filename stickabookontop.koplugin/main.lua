--[[--
Stick a book on top: pin books and folders to the top of the file browser.

Long-press a book or a folder in the file browser to pin or unpin it.
Up to 4 books and 2 folders can be pinned. Pinned entries are moved to the
top of their folder listing and marked with a pushpin at their top-left
corner: drawn over the cover in CoverBrowser's mosaic/list display modes,
shown as a glyph before the name in the classic display mode.

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
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- Thumbtack glyph from nerdfonts/symbols.ttf, always among the UI font fallbacks
local PIN_GLYPH = "\u{F08D}"

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

-- Pushpin badge, cached per size
local pin_icons = {}
local function getPinIcon(size)
    if size <= 0 then return end
    local icon = pin_icons[size]
    if icon == nil then
        local icon_file = plugin_dir .. "/pushpin.svg"
        if lfs.attributes(icon_file, "mode") == "file" then
            icon = ImageWidget:new{
                file = icon_file,
                width = size,
                height = size,
                alpha = true,
            }
        else
            logger.warn("stickabookontop: pushpin.svg not found in", plugin_dir)
            icon = false
        end
        pin_icons[size] = icon
    end
    return icon or nil
end

-- Move pinned entries to the top of the file browser listing:
-- "../" first, then pinned folders, then pinned books, then everything else
-- in its usual order.
local orig_genItemTableFromPath = FileChooser.genItemTableFromPath
FileChooser.genItemTableFromPath = function(self, path)
    local item_table = orig_genItemTableFromPath(self, path)
    if self.name ~= "filemanager" or (#pins.files == 0 and #pins.folders == 0) then
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
    if #pinned == 0 then
        return item_table
    end
    table.sort(pinned, function(a, b) return rank[a.path] < rank[b.path] end)
    if not self.display_mode_type then
        -- classic display mode: covers are not drawn, so mark pinned entries
        -- with a pushpin glyph before the name instead
        for _, item in ipairs(pinned) do
            item.text = PIN_GLYPH .. " " .. item.text
        end
    end
    local reordered = {}
    for _, group in ipairs({ head, pinned, rest }) do
        for __, item in ipairs(group) do
            reordered[#reordered + 1] = item
        end
    end
    return reordered
end

-- Draw the pushpin badge on the top-left corner of pinned entries in
-- CoverBrowser's mosaic and list display modes.
local orig_paintTo = FileChooser.paintTo
FileChooser.paintTo = function(self, bb, x, y)
    orig_paintTo(self, bb, x, y)
    local mode = self.display_mode_type
    if self.name ~= "filemanager" or not mode or not next(pins_lookup) then
        return
    end
    local function paintBadge(w)
        local badge_x, badge_y = w.dimen.x, w.dimen.y
        local size
        if mode == "mosaic" then
            size = math.floor(math.min(w.dimen.w, w.dimen.h) / 7)
            -- anchor to the cover frame, centered inside the grid cell
            local target = w[1] and w[1][1] and w[1][1][1]
            if target and target.dimen and target.dimen.w > 0 then
                badge_x, badge_y = target.dimen.x, target.dimen.y
            end
        else -- "list": the cover thumbnail sits at the left edge of the row
            size = math.floor(w.dimen.h / 6)
        end
        local icon = getPinIcon(size)
        if icon then
            icon:paintTo(bb, badge_x, badge_y)
        end
    end
    local function walk(container)
        for i = 1, #container do
            local w = container[i]
            if w.entry then -- a menu item widget
                if w.entry.path and pins_lookup[w.entry.path] and w.dimen and w.dimen.w > 0 then
                    paintBadge(w)
                end
            elseif #w > 0 then -- a layout container, e.g. a mosaic row
                walk(w)
            end
        end
    end
    walk(self.item_group)
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
