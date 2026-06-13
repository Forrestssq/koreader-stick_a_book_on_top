--[[--
Anki vocabulary cards: an Anki-style spaced-repetition review mode for the
words collected by KOReader's built-in Vocabulary builder.

Words (with their sentence context and book title) are imported from
vocabulary_builder.sqlite3; reviewing happens here as flip flashcards that
show the Chinese/dictionary meaning (looked up on demand via the installed
dictionaries and cached) and rate recall with 重来/困难/良好/简单.
--]]

local DB = require("db")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ReviewWidget = require("reviewwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Register our menu entry into the "More tools" group of both the file manager
-- and the reader menus. This is a process-wide singleton, so doing it at module
-- load time adds the entry exactly once.
require("ui/plugin/insert_menu").add("ankivocab")

local AnkiVocab = WidgetContainer:extend{
    name = "ankivocab",
}

function AnkiVocab:init()
    DB:init()
    -- Pull in any newly collected words (best-effort; never fatal).
    pcall(function() DB:importFromVocabBuilder() end)
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function AnkiVocab:onDispatcherRegisterActions()
    Dispatcher:registerAction("ankivocab_review", {
        category = "none",
        event = "StartAnkiReview",
        title = _("Anki 单词复习"),
        general = true,
    })
end

function AnkiVocab:addToMainMenu(menu_items)
    menu_items.ankivocab = {
        text = _("Anki 单词卡片"),
        sub_item_table = {
            {
                text_func = function()
                    local stats = DB:getStats()
                    return T(_("开始复习（%1 张到期）"), stats.due)
                end,
                callback = function()
                    self:startReview()
                end,
                separator = true,
            },
            {
                text = _("从单词本导入新单词"),
                callback = function()
                    local added = select(1, DB:importFromVocabBuilder())
                    UIManager:show(InfoMessage:new{
                        text = T(_("已从单词本导入 %1 个新单词。"), added or 0),
                    })
                end,
            },
            {
                text = _("统计"),
                keep_menu_open = true,
                callback = function()
                    local stats = DB:getStats()
                    UIManager:show(InfoMessage:new{
                        text = T(_("总卡片：%1\n到期待复习：%2\n未学过的新卡片：%3"),
                            stats.total, stats.due, stats.new),
                    })
                end,
            },
        },
    }
end

function AnkiVocab:onStartAnkiReview()
    self:startReview()
    return true
end

function AnkiVocab:startReview()
    pcall(function() DB:importFromVocabBuilder() end)
    local stats = DB:getStats()
    if stats.due == 0 then
        UIManager:show(InfoMessage:new{
            text = stats.total == 0
                and _("单词本为空。请先在阅读时查词并“加入单词本”。")
                or _("暂时没有到期需要复习的卡片，休息一下吧。"),
        })
        return
    end
    UIManager:show(ReviewWidget:new{
        plugin = self,
        db = DB,
        ui = self.ui,
    })
end

--- Look up a word in the installed dictionaries and return a plain-text meaning,
-- or nil if no dictionary module or no result is available.
function AnkiVocab:lookupMeaning(word)
    local dict = self.ui and self.ui.dictionary
    if not dict or not dict.startSdcv then
        return nil
    end
    local ok, results = pcall(function() return dict:startSdcv(word) end)
    if not ok or type(results) ~= "table" then
        logger.dbg("ankivocab: dictionary lookup failed for", word, results)
        return nil
    end
    local parts = {}
    local total_len = 0
    for _, r in ipairs(results) do
        local def = DB.defToText(r.definition)
        if def ~= "" then
            local header = (r.dict and r.dict ~= "") and ("【" .. r.dict .. "】\n") or ""
            local chunk = header .. def
            table.insert(parts, chunk)
            total_len = total_len + #chunk
            -- Cap output: a handful of dictionaries is plenty for a flashcard.
            if #parts >= 5 or total_len > 4000 then
                break
            end
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "\n\n")
end

return AnkiVocab
