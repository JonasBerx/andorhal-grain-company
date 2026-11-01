-- GuildSyncGames Store.lua: the saved state, today's game, stats and practice (plan Task 5, Seams).
-- GuildSyncGamesDB is account-wide: { phase, day = { n, rows = { words }, done, won, by, hint }, stats = { era,
-- played, won, cur, best, last, dist = { 6 } }, flight, guilds = { [guildKey] = { records } } }.
-- It is read at call time.
-- The day comes from GetServerTime and the reset phase only (f7068); the phase is the last good one seen, rounded to
-- 60 s, and UTC midnight only when none was ever seen (f7066). N never goes backwards (f7067).

local _, ns = ...

if not ns.M then return end
local M, Core = ns.M, ns.Core

local INERT = "Demo: nothing is done to made-up members." -- the hub's own demo line (GuildSync/Demo.lua:18)
local ROLLED = "A new word is out."
local NO_CLOCK = "The server time is not known yet. Try again in a moment."
local TRIES = 6
local WORDS = type(ns.WORDS) == "table" and ns.WORDS or { answers = "", accepted = {} } -- no Words.lua: no game
ns.ROLLED = ROLLED

local answers = {}
for w in WORDS.answers:gmatch("%S+") do answers[#answers + 1] = w end
local order = Core.Order(#answers, Core.SEED)

-- The accepted set, built at the first guess (f7079).
local accepted
local function acceptedSet()
  if accepted then return accepted end
  accepted = {}
  for _, chunk in ipairs(WORDS.accepted) do
    for w in chunk:gmatch("%S+") do accepted[w] = true end
  end
  for _, w in ipairs(answers) do accepted[w] = true end
  return accepted
end

local function freshStats(era)
  return { era = era, played = 0, won = 0, cur = 0, best = 0, dist = { 0, 0, 0, 0, 0, 0 } }
end

local function db()
  GuildSyncGamesDB = type(GuildSyncGamesDB) == "table" and GuildSyncGamesDB or {}
  local d = GuildSyncGamesDB
  if type(d.stats) ~= "table" then d.stats = freshStats(nil) end
  if type(d.guilds) ~= "table" then d.guilds = {} end
  if d.flight == nil then d.flight = true end
  return d
end

-- The one clock read: server time, nil when it cannot be read.
local function now()
  local t = M.Compat.call("GetServerTime")
  if type(t) ~= "number" then return nil end
  return t
end
ns.Now = now -- Sync.lua reads the same clock

-- In demo: says the hub's demo line and answers true (nothing is done); else false.
function ns.Inert()
  if not M.Demo() then return false end
  GuildSync.Say(INERT)
  return true
end

-- The reset phase: a plain answer in range updates the saved one; otherwise the saved one (nil if never seen).
local function phase(t)
  local d = db()
  local p = Core.Phase(t, M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset"))
  if p then d.phase = p end
  return d.phase
end

-- The current N, its label and the seconds to the next reset; nil without a clock.
local function current()
  local t = now()
  if not t then return nil end
  return Core.Puzzle(t, phase(t))
end
ns.Day = current -- the computed N (not the kept day, f7067), its label and seconds left; VendorStore.lua reads it

local function wordFor(n) return Core.WordFor(n, answers, order) end

-- ---------- the hint (S28b Task 2): ns.CLUES (Clues.lua) runs parallel to the answers, read at call time ----------

ns.HINT_PRICE = 20

-- Usable only with one parsable row per answer; the verdict is kept per table.
local cluesChecked, cluesGood
local function cluesOk()
  local c = ns.CLUES
  if c ~= cluesChecked then
    cluesChecked, cluesGood = c, type(c) == "table" and #c == #answers
    if cluesGood then
      for i = 1, #c do
        if not Core.ParseClue(c[i]) then cluesGood = false break end
      end
    end
  end
  return cluesGood
end

-- Day n's category and clue; nil when the clue rows are not usable.
local function clueFor(n)
  if not cluesOk() then return nil end
  local i = Core.IndexFor(n, order)
  if not i then return nil end
  return Core.ParseClue(ns.CLUES[i])
end

local function newDay(n) return { n = n, rows = {}, done = false, won = false } end

-- Brings db.day up to the current N (an unfinished old day is simply dropped: not played); a lower N keeps db.day.
-- The first live day wipes the preview stats (q1521).
local function sync()
  local n = current()
  if not n then return nil end
  local d = db()
  if type(d.day) ~= "table" or type(d.day.n) ~= "number" or n > d.day.n then d.day = newDay(n) end
  if d.day.n >= 1 and d.stats.era ~= "live" then d.stats = freshStats("live") end
  if d.day.n < 1 and d.stats.era == nil then d.stats.era = "preview" end
  return d
end

-- The roll timer: one per day number, at the next reset + 1 s.
local armedFor
local function arm(n, left)
  if armedFor == n or type(left) ~= "number" then return end
  armedFor = n
  M.After(left + 1, function()
    sync()
    if M.RefreshPage then M.RefreshPage() end
    local n2, _, left2 = current()
    if n2 then arm(n2, left2) end
  end)
end

function ns.Today()
  local d = sync()
  if not d then return nil end
  local day = d.day
  local n, label, left = current()
  arm(n, left)
  if day.n ~= n then label = Core.Label(day.n) end -- a kept day above the computed N (f7067)
  if not label then return nil end -- before the previews: no game
  local word = wordFor(day.n)
  if not word then return nil end -- no word list
  local t = { n = day.n, label = label, word = word, len = #word, rows = Core.Scored(day.rows, word), done = day.done,
    won = day.won, by = day.by, fin = day.fin, secsLeft = left, -- secsLeft stays the computed day's: Sync.lua's cutoff
    nextIn = day.n > n and left + (day.n - n) * 86400 or nil } -- a kept day counts to its own end (f7114)
  if day.hint then t.hint = true; t.category, t.clue = clueFor(day.n) end -- bought: kept after the finish (f16)
  return t
end

function ns.Stats()
  local d = sync()
  local s = db().stats
  local cur = d and Core.Streak(s, d.day.n) or 0
  return { played = s.played, won = s.won, cur = cur, best = s.best, dist = s.dist }
end

-- The real day and stats, even in demo (Demo.lua wraps ns.Today and ns.Stats); Sync.lua's own record reads these.
ns.RealToday, ns.RealStats = ns.Today, ns.Stats

local function refusal(why, len)
  if why == "length" then return "Use a " .. len .. "-letter word." end
  return "That word is not on the WoW word list."
end

function ns.Guess(w)
  if ns.Inert() then return nil, "demo", INERT end
  local d = db()
  local before = type(d.day) == "table" and type(d.day.n) == "number" and d.day.n or nil
  if not sync() then return nil, "clock", NO_CLOCK end
  if before and d.day.n > before then return nil, "rolled", ROLLED end
  local today = ns.Today()
  if not today then return nil, "done" end
  local day = d.day
  if day.done then return nil, "done" end
  local word, why = Core.Valid(w, today.len, acceptedSet())
  if not word then return nil, why, refusal(why, today.len) end
  day.by = day.by or ns.MyKey()
  day.rows[#day.rows + 1] = word
  if word ~= today.word and #day.rows < TRIES then return true end

  day.done, day.won = true, word == today.word
  day.fin = ns.MyKey() -- the finishing character owns the record (an alt may finish what its main started); by stays
  local s = d.stats
  s.played = s.played + 1
  if day.won then
    s.won = s.won + 1
    s.cur = (s.last == day.n - 1) and s.cur + 1 or 1
    if s.cur > s.best then s.best = s.cur end
    s.dist[#day.rows] = (s.dist[#day.rows] or 0) + 1
  else
    s.cur = 0
  end
  s.last = day.n
  if ns.OnFinished then ns.OnFinished(Core.Result(day.n, day.won, Core.Scored(day.rows, today.word), s.cur)) end
  if ns.FactsChanged then ns.FactsChanged() end
  return true
end

-- ---------- practice: in memory only, never saved, counted or published ----------

local P, mode = nil, "daily"
local pClue -- the drawn word's { category, clue }, kept off P until the hint (nil: none)

-- The Practice.lua rows { word, category, clue } (o2520), never an answer (q1532); with none usable, the old pool of
-- accepted words that are not answers, { word } with no clue. Built at the first practice.
local pool
local function practicePool()
  if pool then return pool end
  local isAnswer = {}
  for _, w in ipairs(answers) do isAnswer[w] = true end
  pool = {}
  if type(ns.PRACTICE) == "table" then
    for _, r in ipairs(ns.PRACTICE) do
      local w, cat, clue = Core.ParsePractice(r)
      if w and not isAnswer[w] then pool[#pool + 1] = { w, cat, clue } end
    end
  end
  if #pool > 0 then return pool end
  for _, chunk in ipairs(WORDS.accepted) do
    for w in chunk:gmatch("%S+") do
      if not isAnswer[w] then pool[#pool + 1] = { w } end
    end
  end
  return pool
end

function ns.NewPractice()
  local list = practicePool()
  if #list == 0 then return nil end
  local e = list[math.random(#list)]
  local w = e[1]
  pClue = e[2] and { e[2], e[3] } or nil
  P = { word = w, len = #w, rows = {}, done = false, won = false }
  mode = "practice"
  return P
end

function ns.Practice() return P end

function ns.PracticeGuess(w)
  if not P or P.done then return nil, "done" end
  local word, why = Core.Valid(w, P.len, acceptedSet())
  if not word then return nil, why, refusal(why, P.len) end
  P.rows[#P.rows + 1] = { word = word, codes = Core.Score(word, P.word) }
  if word == P.word or #P.rows >= TRIES then P.done, P.won = true, word == P.word end
  return true
end

function ns.Mode() return mode end

function ns.SetMode(m)
  if m == "daily" or m == "practice" then mode = m end
end

-- ---------- the hint: state (read only) and the buy ----------

-- Can the hint be bought now? true[, n] | nil, why; n is the daily day it checked (practice answers true alone). Read
-- only and silent: no spend, no write to the day (not even the day roll or the record; ns.Purse may make the grain table
-- and start its tick; Demo.lua's ns.Today reads the same way), nothing said. The practice game on show is
-- checked first (WoWdle.lua's game()); the daily guards follow ns.Guess.
function ns.HintState()
  if mode == "practice" and P then
    if P.done then return nil, "done" end
    if P.hint then return nil, "bought" end
    if not pClue then return nil, "noclue" end
    return true
  end
  if M.Demo() then return nil, "demo" end
  local t = now()
  if not t then return nil, "clock" end
  local saved = type(GuildSyncGamesDB) == "table" and GuildSyncGamesDB or {}
  local p = Core.Phase(t, M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset")) or saved.phase
  local n, label = Core.Puzzle(t, p)
  local day = type(saved.day) == "table" and type(saved.day.n) == "number" and saved.day or nil
  if day and n > day.n then return nil, "rolled" end -- the next ns.Today() (or BuyHint) moves it
  if day and day.n > n then n, label = day.n, Core.Label(day.n) end -- a kept day (f7067)
  if not label or not wordFor(n) then return nil, "none" end
  if day and day.done then return nil, "done" end
  if day and day.hint then return nil, "bought" end
  if not clueFor(n) then return nil, "noclue" end
  if ns.Purse() < ns.HINT_PRICE then return nil, "short" end
  return true, n
end

-- Buys the hint: true | true, "bought" | nil, why (HintState's). Daily costs HINT_PRICE grain and is saved on the
-- day; practice is free and in memory only (o2520). Only this says the demo line.
function ns.BuyHint()
  local can, why = ns.HintState() -- why is the day n checked when can is true (daily)
  if why == "bought" then return true, "bought" end
  if why == "demo" then ns.Inert(); return nil, "demo" end
  if why == "rolled" then sync() end -- as ns.Guess: the roll is done and told once
  if not can then return nil, why end
  if mode == "practice" and P then
    P.hint, P.category, P.clue = true, pClue[1], pClue[2]
    return true
  end
  local d = sync() -- the day HintState read (made when none was kept yet)
  if not d then return nil, "clock" end
  if type(why) == "number" and d.day.n ~= why then return nil, "rolled" end -- the reset fell after HintState (sec f1)
  local paid, err = ns.Spend(ns.HINT_PRICE)
  if not paid then return nil, err end
  d.day.hint = true
  return true
end

-- ---------- records per guild (for Sync.lua, T6) ----------

-- The guild by name only (Forever is realmless; NoticeBoard Store.lua:70-75), through M.Compat.call (plain, f7100).
local function guildNow()
  local name = M.Compat.call("GetGuildInfo", "player")
  if type(name) ~= "string" or name == "" then return nil end
  return name
end

local guildKey

-- Guild key's records table, made when missing.
local function guildRecords(d, key)
  if type(d.guilds[key]) ~= "table" then d.guilds[key] = { records = {} } end
  if type(d.guilds[key].records) ~= "table" then d.guilds[key].records = {} end
  return d.guilds[key].records
end

-- Before the first rosterRead the guild is read at call time, so records are kept (wiping other guilds waits for it).
function ns.Records()
  local key = guildKey or guildNow()
  if not key then return {} end
  return guildRecords(db(), key)
end

-- The guild's board records (Boards.lua, S11), db.guilds[guildKey].boards beside records, made when missing; the
-- rosterRead below wipes them with another guild's entry.
function ns.BoardRecords()
  local key = guildKey or guildNow()
  if not key then return {} end
  local d = db()
  guildRecords(d, key)
  local g = d.guilds[key]
  if type(g.boards) ~= "table" then g.boards = {} end
  return g.boards
end

-- The guild's Vendor price records (VendorSync.lua, S12), db.guilds[guildKey].vendor, made when missing; wiped with
-- the guild entry.
function ns.VendorRecords()
  local key = guildKey or guildNow()
  if not key then return {} end
  local d = db()
  guildRecords(d, key)
  local g = d.guilds[key]
  if type(g.vendor) ~= "table" then g.vendor = {} end
  return g.vendor
end

-- The guild's Company rows (CompanySync.lua, S13), db.guilds[guildKey].company, made when missing; wiped with the
-- guild entry.
function ns.CompanyRecords()
  local key = guildKey or guildNow()
  if not key then return {} end
  local d = db()
  guildRecords(d, key)
  local g = d.guilds[key]
  if type(g.company) ~= "table" then g.company = {} end
  return g.company
end

-- S14 (d1607): the saved hidden-alt sets, db.guilds[guildKey].hiddenChars[hiddenKey] = { at, chars = { key, ... } },
-- made when missing; CompanySync.lua grows and deletes them.
function ns.HiddenChars()
  local key = guildKey or guildNow()
  if not key then return {} end
  local d = db()
  guildRecords(d, key)
  local g = d.guilds[key]
  if type(g.hiddenChars) ~= "table" then g.hiddenChars = {} end
  return g.hiddenChars
end

-- S14 (d1605, d1610): once per guild and domain, recs loses every record but MyKey's; the marker is
-- db.guilds[guildKey].putWiped[domain]. Without MyKey nothing is done and no marker is set. It wipes data on purpose.
function ns.WipeForeignOnce(domain, recs)
  local key, me = guildKey or guildNow(), ns.MyKey()
  if not key or not me or type(recs) ~= "table" then return end
  local d = db()
  guildRecords(d, key)
  local g = d.guilds[key]
  if type(g.putWiped) ~= "table" then g.putWiped = {} end
  if g.putWiped[domain] then return end
  for k in pairs(recs) do
    if k ~= me then recs[k] = nil end
  end
  g.putWiped[domain] = true
end

-- At each rosterRead: the guild key; every other guild's records are wiped (LinksStore.lua:291-301).
M.On("rosterRead", function()
  local key = guildNow()
  if not key then return end
  local d = db()
  for k in pairs(d.guilds) do
    if k ~= key then d.guilds[k] = nil end
  end
  guildRecords(d, key)
  guildKey = key
end)
