--[[--
Database layer for the Anki vocabulary cards plugin.

Keeps its own SQLite database (anki_vocab.sqlite3) holding one row per card:
the word, its cached Chinese/dictionary meaning, the sentence context it was
collected in, and Anki-style spaced-repetition state (ease, interval, due...).

Words are imported (non-destructively) from the built-in Vocabulary builder's
database (vocabulary_builder.sqlite3), so the user keeps collecting words the
usual way (dictionary lookup → "Add to vocabulary builder") and reviews them
here. Importing again never clobbers the scheduling of cards already present.
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local db_location = DataStorage:getSettingsDir() .. "/anki_vocab.sqlite3"
local vocab_builder_location = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"

local DB_SCHEMA_VERSION = 20260613
local DB_SCHEMA = [[
    CREATE TABLE IF NOT EXISTS "cards" (
        "word"          TEXT NOT NULL UNIQUE,
        "meaning"       TEXT,
        "prev_context"  TEXT,
        "next_context"  TEXT,
        "highlight"     TEXT,
        "book_title"    TEXT,
        "ease"          REAL NOT NULL DEFAULT 2.5,
        "interval"      INTEGER NOT NULL DEFAULT 0, -- in days
        "reps"          INTEGER NOT NULL DEFAULT 0,
        "lapses"        INTEGER NOT NULL DEFAULT 0,
        "state"         INTEGER NOT NULL DEFAULT 0, -- 0 new, 1 learning, 2 review
        "due"           INTEGER NOT NULL,
        "create_time"   INTEGER NOT NULL,
        PRIMARY KEY("word")
    );
    CREATE INDEX IF NOT EXISTS due_index ON cards(due);
]]

-- Spaced-repetition tuning ---------------------------------------------------
local MIN_EASE = 1.3
local AGAIN_STEP = 10 * 60       -- 10 minutes
local HARD_STEP = 10 * 60        -- 10 minutes (still in learning)
local GRAD_GOOD = 1              -- graduate to 1 day on Good
local GRAD_EASY = 4              -- graduate to 4 days on Easy
local DAY = 24 * 3600

local DB = {
    path = db_location,
}

function DB:open()
    local conn = SQ3.open(db_location)
    if Device:canUseWAL() then
        conn:exec("PRAGMA journal_mode=WAL;")
    else
        conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end
    return conn
end

function DB:init()
    local conn = self:open()
    conn:exec(DB_SCHEMA)
    local db_version = tonumber(conn:rowexec("PRAGMA user_version;"))
    if db_version < DB_SCHEMA_VERSION then
        conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
    end
    conn:close()
end

-- SQL string literal escaping (single quotes doubled)
local function q(s)
    if s == nil then return "NULL" end
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

--- Import words from the built-in Vocabulary builder database.
-- Returns number of newly added cards (existing cards are left untouched).
function DB:importFromVocabBuilder()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(vocab_builder_location, "mode") ~= "file" then
        return 0, "vocabulary_builder.sqlite3 not found"
    end
    local ok, src = pcall(SQ3.open, vocab_builder_location, "ro")
    if not ok or not src then
        return 0, "cannot open vocabulary builder database"
    end
    local results
    ok, results = pcall(function()
        return src:exec([[
            SELECT v.word, v.prev_context, v.next_context, v.highlight, t.name AS book_title
            FROM vocabulary v LEFT JOIN title t ON v.title_id = t.id;
        ]])
    end)
    src:close()
    if not ok or not results then
        return 0
    end

    local conn = self:open()
    local now = os.time()
    local stmt = conn:prepare([[
        INSERT OR IGNORE INTO cards
            (word, prev_context, next_context, highlight, book_title, ease, interval, reps, lapses, state, due, create_time)
        VALUES (?, ?, ?, ?, ?, 2.5, 0, 0, 0, 0, ?, ?);
    ]])
    conn:exec("BEGIN;")
    local added = 0
    for i = 1, #results.word do
        stmt:reset():bind(results.word[i], results.prev_context[i], results.next_context[i],
            results.highlight[i], results.book_title[i], now, now)
        stmt:step()
        added = added + tonumber(conn:rowexec("SELECT changes();"))
    end
    conn:exec("COMMIT;")
    stmt:close()
    conn:close()
    logger.dbg("ankivocab: imported", added, "new cards from vocabulary builder")
    return added
end

local function rowToCard(results, i)
    return {
        word = results.word[i],
        meaning = results.meaning[i],
        prev_context = results.prev_context[i],
        next_context = results.next_context[i],
        highlight = results.highlight[i],
        book_title = results.book_title[i],
        ease = tonumber(results.ease[i]),
        interval = tonumber(results.interval[i]),
        reps = tonumber(results.reps[i]),
        lapses = tonumber(results.lapses[i]),
        state = tonumber(results.state[i]),
        due = tonumber(results.due[i]),
    }
end

--- Return the next card to study (due card with the earliest due time), or nil.
function DB:getNextCard()
    local conn = self:open()
    local now = os.time()
    local results = conn:exec(string.format(
        "SELECT * FROM cards WHERE due <= %d ORDER BY due ASC LIMIT 1;", now))
    conn:close()
    if not results or not results.word or #results.word == 0 then
        return nil
    end
    return rowToCard(results, 1)
end

--- Counts: total cards, cards due now, and brand-new (never reviewed) cards.
function DB:getStats()
    local conn = self:open()
    local now = os.time()
    local total = tonumber(conn:rowexec("SELECT count(0) FROM cards;")) or 0
    local due = tonumber(conn:rowexec(string.format("SELECT count(0) FROM cards WHERE due <= %d;", now))) or 0
    local new = tonumber(conn:rowexec("SELECT count(0) FROM cards WHERE reps = 0;")) or 0
    conn:close()
    return { total = total, due = due, new = new }
end

function DB:setMeaning(word, meaning)
    local conn = self:open()
    conn:exec(string.format("UPDATE cards SET meaning = %s WHERE word = %s;", q(meaning), q(word)))
    conn:close()
end

function DB:removeCard(word)
    local conn = self:open()
    conn:exec(string.format("DELETE FROM cards WHERE word = %s;", q(word)))
    conn:close()
end

--- Compute the scheduling outcome for a rating without persisting it.
-- rating: 1 Again, 2 Hard, 3 Good, 4 Easy.
-- Returns a table { ease, interval, reps, lapses, state, due, interval_sec }.
function DB.schedule(card, rating, now)
    now = now or os.time()
    local ease = card.ease or 2.5
    local interval = card.interval or 0
    local reps = (card.reps or 0)
    local lapses = (card.lapses or 0)
    local state = card.state or 0
    local interval_sec

    if rating == 1 then -- Again
        lapses = lapses + 1
        ease = math.max(MIN_EASE, ease - 0.20)
        interval = 0
        state = 1 -- learning
        interval_sec = AGAIN_STEP
    elseif state == 0 or state == 1 then -- new / learning card graduating
        if rating == 2 then -- Hard: stay in learning
            interval = 0
            state = 1
            interval_sec = HARD_STEP
        elseif rating == 3 then -- Good: graduate
            interval = GRAD_GOOD
            state = 2
            interval_sec = interval * DAY
        else -- Easy: graduate further
            ease = ease + 0.15
            interval = GRAD_EASY
            state = 2
            interval_sec = interval * DAY
        end
    else -- review card
        if rating == 2 then -- Hard
            ease = math.max(MIN_EASE, ease - 0.15)
            interval = math.max(1, math.floor(interval * 1.2 + 0.5))
        elseif rating == 3 then -- Good
            interval = math.max(1, math.floor(interval * ease + 0.5))
        else -- Easy
            ease = ease + 0.15
            interval = math.max(1, math.floor(interval * ease * 1.3 + 0.5))
        end
        state = 2
        interval_sec = interval * DAY
    end

    reps = reps + 1
    return {
        ease = ease,
        interval = interval,
        reps = reps,
        lapses = lapses,
        state = state,
        due = now + interval_sec,
        interval_sec = interval_sec,
    }
end

--- Apply a rating to a card and persist the new schedule. Returns the schedule.
function DB:answerCard(card, rating)
    local s = DB.schedule(card, rating)
    local conn = self:open()
    conn:exec(string.format([[
        UPDATE cards SET ease = %f, interval = %d, reps = %d, lapses = %d, state = %d, due = %d
        WHERE word = %s;]],
        s.ease, s.interval, s.reps, s.lapses, s.state, s.due, q(card.word)))
    conn:close()
    -- keep the in-memory card consistent
    for k, v in pairs(s) do card[k] = v end
    return s
end

--- Human-readable interval string for a button preview, e.g. "10分钟", "1天".
function DB.formatInterval(seconds)
    if seconds < 3600 then
        return string.format("%d分钟", math.max(1, math.floor(seconds / 60 + 0.5)))
    elseif seconds < DAY then
        return string.format("%d小时", math.floor(seconds / 3600 + 0.5))
    elseif seconds < 30 * DAY then
        return string.format("%d天", math.floor(seconds / DAY + 0.5))
    elseif seconds < 365 * DAY then
        return string.format("%.1f个月", seconds / (30 * DAY))
    else
        return string.format("%.1f年", seconds / (365 * DAY))
    end
end

--- Convert a (possibly HTML/xdxf) dictionary definition to readable plain text.
function DB.defToText(s)
    if not s then return "" end
    s = s:gsub("<[bB][rR]%s*/?>", "\n")
    s = s:gsub("</[pPdD][iItv]?[vV]?>", "\n")
    s = s:gsub("<[^>]->", "")
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
        :gsub("&nbsp;", " "):gsub("&#160;", " ")
    s = s:gsub("[ \t]+", " ")
    s = s:gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Preview the four interval strings (again/hard/good/easy) for a card.
function DB.previewIntervals(card)
    local now = 0
    return {
        again = DB.formatInterval(DB.schedule(card, 1, now).due),
        hard  = DB.formatInterval(DB.schedule(card, 2, now).due),
        good  = DB.formatInterval(DB.schedule(card, 3, now).due),
        easy  = DB.formatInterval(DB.schedule(card, 4, now).due),
    }
end

return DB
