--[[--
Full-screen Anki-style flashcard review widget.

Front of the card shows the word and the sentence context it was collected in.
Tapping the card (or "显示答案") flips it, revealing the Chinese/dictionary
meaning. Four buttons (重来/困难/良好/简单) rate recall and schedule the next
review, then the next due card is shown. Closing or running out of due cards
ends the session.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local ReviewWidget = InputContainer:extend{
    title = _("Vocabulary review"),
    plugin = nil, -- back-reference for meaning lookup
    db = nil,
    card = nil,
    show_answer = false,
    reviewed = 0,
}

function ReviewWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    -- fresh per-instance tables (do not mutate the shared class defaults)
    self.key_events = {}
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = self.dimen } },
    }
    self:loadNext()
end

-- Load the next due card; if none remain, finish the session.
function ReviewWidget:loadNext()
    self.card = self.db:getNextCard()
    self.show_answer = false
    if not self.card then
        self:onClose()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = self.reviewed > 0
                and string.format(_("今日复习完成，共复习 %d 张卡片。"), self.reviewed)
                or _("没有需要复习的卡片。"),
        })
        return
    end
    self:update()
end

-- Build the "...prev 【word】 next..." context string, or nil if no context.
function ReviewWidget:getContextText()
    local prev = (self.card.prev_context or ""):gsub("\n", " ")
    local next = (self.card.next_context or ""):gsub("\n", " ")
    if prev == "" and next == "" then
        return nil
    end
    local word = self.card.highlight or self.card.word
    return "…" .. prev .. " 【" .. word .. "】 " .. next .. "…"
end

function ReviewWidget:buildButtons()
    local buttons
    if not self.show_answer then
        buttons = { { {
            text = _("显示答案"),
            callback = function() self:flip() end,
        } } }
    else
        local p = self.db.previewIntervals(self.card)
        -- Button labels are single-line (Button renders its label with a
        -- single-line TextWidget), so the interval follows the rating inline.
        buttons = { {
            { text = "重来 " .. p.again, callback = function() self:rate(1) end },
            { text = "困难 " .. p.hard,  callback = function() self:rate(2) end },
            { text = "良好 " .. p.good,  callback = function() self:rate(3) end },
            { text = "简单 " .. p.easy,  callback = function() self:rate(4) end },
        } }
    end
    return ButtonTable:new{
        width = self.dimen.w - 2 * Size.padding.large,
        buttons = buttons,
        zero_sep = true,
        show_parent = self,
    }
end

function ReviewWidget:update()
    local stats = self.db:getStats()
    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        fullscreen = true,
        align = "center",
        title = self.title,
        subtitle = string.format(_("剩余 %d  ·  已复习 %d"), stats.due, self.reviewed),
        subtitle_truncate_left = false,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local button_table = self:buildButtons()
    local content_w = self.dimen.w - 2 * Size.padding.large
    local inner_pad = Size.padding.large

    local content = VerticalGroup:new{ align = "left" }

    if self.card.book_title and self.card.book_title ~= "" then
        table.insert(content, TextBoxWidget:new{
            text = self.card.book_title,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = content_w,
            alignment = "center",
        })
        table.insert(content, VerticalSpan:new{ width = Size.span.vertical_large })
    end

    -- The word itself, large and centered.
    table.insert(content, TextBoxWidget:new{
        text = self.card.word,
        face = Font:getFace("tfont", 32),
        bold = true,
        width = content_w,
        alignment = "center",
    })

    local context = self:getContextText()
    if context then
        table.insert(content, VerticalSpan:new{ width = Size.span.vertical_large })
        table.insert(content, TextBoxWidget:new{
            text = context,
            face = Font:getFace("cfont", 19),
            width = content_w,
            alignment = "center",
        })
    end

    -- Reserve the remaining vertical space for the (scrollable) meaning.
    local used_h = content:getSize().h
    local avail_h = self.dimen.h - self.title_bar:getHeight() - button_table:getSize().h - 2 * inner_pad

    if self.show_answer then
        table.insert(content, VerticalSpan:new{ width = Size.span.vertical_large })
        table.insert(content, LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{ w = content_w, h = Size.line.medium },
        })
        table.insert(content, VerticalSpan:new{ width = Size.span.vertical_large })
        used_h = content:getSize().h
        local meaning_h = math.max(Screen:scaleBySize(80), avail_h - used_h)
        local meaning = (self.card.meaning and self.card.meaning ~= "")
            and self.card.meaning or _("（未找到释义）")
        self.meaning_widget = ScrollTextWidget:new{
            text = meaning,
            face = Font:getFace("cfont", 20),
            width = content_w,
            height = meaning_h,
            dialog = self,
        }
        table.insert(content, self.meaning_widget)
    end

    local content_frame = FrameContainer:new{
        width = self.dimen.w,
        height = avail_h + 2 * inner_pad,
        padding = inner_pad,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = avail_h },
            content,
        },
    }

    self.frame = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            self.title_bar,
            content_frame,
            CenterContainer:new{
                dimen = Geom:new{ w = self.dimen.w, h = button_table:getSize().h },
                button_table,
            },
        },
    }
    self[1] = self.frame
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
end

-- Flip to the answer side, fetching and caching the meaning if needed.
function ReviewWidget:flip()
    if self.show_answer then return end
    if not self.card.meaning or self.card.meaning == "" then
        local meaning = self.plugin:lookupMeaning(self.card.word)
        if meaning and meaning ~= "" then
            self.card.meaning = meaning
            self.db:setMeaning(self.card.word, meaning)
        end
    end
    self.show_answer = true
    self:update()
end

function ReviewWidget:rate(rating)
    self.db:answerCard(self.card, rating)
    self.reviewed = self.reviewed + 1
    self:loadNext()
end

function ReviewWidget:onTap(_arg, ges)
    -- On the front, tapping anywhere flips the card. On the back, let taps
    -- through so the meaning can be scrolled / buttons pressed.
    if not self.show_answer then
        self:flip()
        return true
    end
    return false
end

function ReviewWidget:onSwipe(_arg, ges)
    if ges.direction == "south" then
        self:onClose()
        return true
    end
    return false
end

function ReviewWidget:onMultiSwipe(_arg, _ges)
    self:onClose()
    return true
end

function ReviewWidget:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
    return true
end

function ReviewWidget:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.dimen
    end)
end

function ReviewWidget:onClose()
    UIManager:close(self)
    return true
end

return ReviewWidget
