-- GuildSyncGames WhoStore.lua (S22 Task 4): the Who said it state, today's lines, picks, endless mode and stats; the
-- twin of VendorStore.lua. GuildSyncGamesDB.who is account-wide: { era, day = { n, picks, heard, paid, bonus, fin, got },
-- chose }, result = { n, picks } | nil, best, cur, last, ebest, played }. picks is a string of "1"/"0" marks; chose
-- the picked speaker id per daily line (V-f1; 0 for a pick that was not a number), cleared at the day roll; heard the run
-- position (#picks + 1) of the line last played; best the best daily score, ebest the endless best, played the
-- finished days. No kit id, file id or text is saved; chose holds speaker ids (numbers only). Endless runs live in
-- memory.
-- ns.VOICES, ns.WhoCore's fields, ns.WhoSoundOn and ns.Credit are read through the tables at each call (a test stubs
-- them). Refusals answer nil and a code; Who.lua turns codes into sentences.

local _, ns = ...

if not ns.M then return end
local M, Core, GC = ns.M, ns.Core, ns.GrainCore

local RUN = 10
local BEST_MAX = 999 -- the parser's cap on a best (VendorCore.lua, WhoCore.lua)

local function int(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and (not hi or v <= hi)
end

local function marksOk(s, exact)
  return type(s) == "string" and not s:find("[^01]") and (#s == RUN or (not exact and #s < RUN))
end

local function rights(marks)
  local _, c = (marks or ""):gsub("1", "")
  return c
end

-- The whole table is sound, or it is replaced whole (no field-wise repair).
local function sound(v)
  if type(v) ~= "table" or (v.era ~= "live" and v.era ~= "preview") then return false end
  local d = v.day
  if type(d) ~= "table" or not int(d.n, -1e6) or not marksOk(d.picks) then return false end
  if d.heard ~= nil and not int(d.heard, 1, RUN) then return false end
  if d.chose ~= nil then
    if type(d.chose) ~= "table" or #d.chose > #d.picks then return false end
    for _, id in pairs(d.chose) do if not int(id, 0) then return false end end
  end
  if not int(d.paid, 0, rights(d.picks)) or (d.bonus ~= nil and type(d.bonus) ~= "boolean") then return false end
  if d.fin ~= nil and type(d.fin) ~= "string" then return false end
  if d.got ~= nil and not int(d.got, 0) then return false end
  local r = v.result
  if r ~= nil and (type(r) ~= "table" or not int(r.n, -1e6) or not marksOk(r.picks, true)) then return false end
  if not int(v.best, 0, RUN) or not int(v.cur, 0) or (v.last ~= nil and not int(v.last, -1e6)) then return false end
  if not int(v.ebest, 0, BEST_MAX) or not int(v.played, 0) then return false end
  return true
end

local function newDay(n) return { n = n, picks = "", paid = 0, bonus = false } end

local function fresh(n)
  return { era = n >= 1 and "live" or "preview", day = newDay(n), best = 0, cur = 0, ebest = 0, played = 0 }
end

-- Run first by every reader and action except ns.WhoBody: the saved table if sound, else fresh; the day roll drops an
-- unfinished old day; the first n >= 1 replaces a preview-era table whole. Outside demo it saves; in demo it answers
-- the table it would save and writes nothing. nil without a clock.
local function state()
  local n = ns.Day()
  if not n then return nil end
  local db = GuildSyncGamesDB
  local v = type(db) == "table" and db.who
  local demo = M.Demo()
  if not sound(v) then v = fresh(n)
  elseif demo then
    v = { era = v.era, day = v.day, result = v.result, best = v.best, cur = v.cur, last = v.last, ebest = v.ebest,
      played = v.played }
  end
  if n >= 1 and v.era ~= "live" then v = fresh(n) end
  if n > v.day.n then v.day = newDay(n) end
  if not demo then
    if v.day.charm ~= nil and v.day.charm ~= true then v.day.charm = nil end -- dropped alone, never in sound()
    if type(GuildSyncGamesDB) ~= "table" then GuildSyncGamesDB = {} end
    GuildSyncGamesDB.who = v
  end
  return v
end

-- The daily streak, 0 once the last finished day is before yesterday.
local function streakOf(v, n)
  return (v.last and v.last >= n - 1) and v.cur or 0
end

local function hook(name)
  if ns[name] then M.Safe(ns[name]) end
end

local mode, run = "daily", nil -- the endless run, in memory only

function ns.WhoToday()
  local v = state()
  if not v then return nil end
  local day = v.day
  local lines = ns.WhoCore.Daily(day.n)
  if not lines then return nil end
  return { n = day.n, label = Core.Label(day.n), lines = lines, picks = day.picks, chose = day.chose or {}, heard = day.heard,
    done = #day.picks >= RUN, mode = mode, score = rights(day.picks), earned = day.got or 0,
    charm = day.charm == true }
end

-- The Lucky charm, as ns.VendorBuyCharm: before the first pick, one a day, doubles the day's pay.
function ns.WhoBuyCharm()
  if ns.Inert() then return nil, "demo" end
  local v = state()
  if not v then return nil, "clock" end
  local day = v.day
  if day.charm == true then return nil, "owned" end
  if #day.picks >= 1 then return nil, "started" end
  if not ns.Spend(GC.CHARM_PRICE) then return nil, "short" end
  day.charm = true
  return true
end

function ns.WhoStats()
  local v = state()
  if not v then return { played = 0, best = 0, ebest = 0, streak = 0 } end
  return { played = v.played, best = v.best, ebest = v.ebest, streak = streakOf(v, v.day.n) }
end

-- The last finished run (or the endless-only record); nil when there is none. Reads the saved table only, never
-- creates it (VendorSync's ownBody calls it while the game may be hidden).
function ns.WhoBody()
  local db = GuildSyncGamesDB
  local v = type(db) == "table" and db.who
  if not sound(v) then return nil end
  local n = ns.Day()
  if n and n >= 1 and v.era ~= "live" then return nil end
  if not v.result and v.ebest == 0 then return nil end
  local marks = v.result and v.result.picks or ""
  return { n = v.result and v.result.n or v.day.n, score = rights(marks), marks = marks, best = v.ebest,
    streak = streakOf(v, n or v.day.n) }
end

-- ---------- endless: in memory only, never pays ----------

local function drawNext()
  local i, choices = ns.WhoCore.Endless(run.seed, run.used)
  if not i then
    run.done = true
    return
  end
  run.used[i] = true
  run.line, run.choices, run.heard = i, choices, false
end

function ns.WhoMode(m)
  if m ~= "daily" and m ~= "endless" then return nil end
  if m == "endless" and ns.Inert() then return nil, "demo" end
  mode = m
  if m == "endless" and (not run or run.done) then
    run = { seed = math.random(1, 2147483646), used = {}, streak = 0, done = false, heard = false }
    drawNext()
  end
  return true
end

function ns.WhoEndless()
  if mode ~= "endless" or not run then return nil end
  return { line = run.line, choices = run.choices, streak = run.streak, done = run.done,
    run = { streak = run.streak, done = run.done } }
end

local function endlessPick(id)
  if not run or run.done or not run.line then return nil, "done" end
  if not run.heard then return nil, "heard" end
  local right = id == ns.VOICES.lines[run.line][3]
  run.heard = false
  if right then
    run.streak = run.streak + 1
    drawNext()
  else
    run.done = true
  end
  if run.done then
    local v = state()
    local best = math.min(run.streak, BEST_MAX)
    if v and best > v.ebest then
      v.ebest = best
      hook("WhoBestChanged")
    end
  end
  return true, right
end

-- ---------- heard, the daily pick ----------

-- The page calls it after a successful ns.WhoPlay: the current line was heard. Writes nothing in demo.
function ns.WhoHeard()
  if M.Demo() then return end
  if mode == "endless" then
    if run and not run.done and run.line then run.heard = true end
    return
  end
  local v = state()
  if not v or #v.day.picks >= RUN then return end
  v.day.heard = #v.day.picks + 1
end

-- n, i (the daily page): the day and the line the pick was made on; another day or line is refused as rolled (R-f1,
-- as VendorPick). Endless ignores them.
function ns.WhoPick(id, n, i)
  if ns.Inert() then return nil, "demo" end
  if mode == "endless" then return endlessPick(id) end
  local db = GuildSyncGamesDB
  local saved = type(db) == "table" and db.who
  local before = type(saved) == "table" and type(saved.day) == "table" and saved.day.n or nil
  local v = state()
  if not v then return nil, "clock" end
  local day = v.day
  if type(before) == "number" and day.n > before then return nil, "rolled", ns.ROLLED end
  if (n ~= nil and n ~= day.n) or (i ~= nil and i ~= #day.picks + 1) then return nil, "rolled", ns.ROLLED end
  if #day.picks >= RUN then return nil, "done" end
  local lines = ns.WhoCore.Daily(day.n)
  if not lines then return nil, "done" end
  if #day.picks == 0 then
    local on, why = ns.WhoSoundOn()
    if not on and why ~= "in combat" then return nil, why end -- R-f3: a heard line can be named in combat
  end
  if day.heard ~= #day.picks + 1 then return nil, "heard" end
  local right = id == ns.VOICES.lines[lines[#day.picks + 1].line][3]
  day.picks = day.picks .. (right and "1" or "0")
  day.chose = day.chose or {}
  day.chose[#day.chose + 1] = type(id) == "number" and id or 0

  -- Pay as VendorStore: paid and bonus written first, then ns.Credit only when owed >= 1, and only on a live day or a
  -- preview day before GC.LAUNCH.
  local WC = ns.WhoCore
  local c = rights(day.picks)
  local owed = WC.Pay(c) - WC.Pay(day.paid)
  if day.charm == true then owed = owed * GC.CHARM_MULT end -- day.paid stays the undoubled count
  day.paid, day.bonus = c, day.bonus or c == RUN
  local t = ns.Now()
  if owed >= 1 and (day.n >= 1 or (type(t) == "number" and t < GC.LAUNCH)) and ns.Credit then
    local ran, credited = M.Safe(ns.Credit, owed)
    if ran and credited == true then day.got = (day.got or 0) + owed end
  end

  if #day.picks >= RUN then
    v.cur = (v.last == day.n - 1) and v.cur + 1 or 1
    v.last = day.n
    v.played = v.played + 1
    if c > v.best then v.best = c end
    day.fin = ns.MyKey()
    v.result = { n = day.n, picks = day.picks }
    hook("WhoChanged")
  end
  return true, right
end
