-- GuildSyncGames VendorStore.lua (S12 Task 4): the Vendor price state, today's pairs, picks, endless mode and stats.
-- GuildSyncGamesDB.vendor is account-wide, beside db.day: { era, day = { n, picks, paid, bonus, fin, got }, result = { n,
-- picks } | nil, best, cur, last }. picks is a string of "1"/"0" marks; day.fin the finishing key (Store.lua:153);
-- result the last finished run, set at the tenth pick and kept through the day roll. day.got is the grain credited
-- today (f7279). Endless runs live in memory.

local _, ns = ...

if not ns.M then return end
local M, Core, VC, GC = ns.M, ns.Core, ns.VendorCore, ns.GrainCore

local RUN = 10
local NO_CLOCK = "The server time is not known yet. Try again in a moment."
local BEST_MAX = 999 -- the parser's cap on a best (VendorCore.lua:20, f7321)

local function int(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and (not hi or v <= hi)
end

local function marksOk(s, exact)
  return type(s) == "string" and not s:find("[^01]") and (#s == RUN or (not exact and #s < RUN))
end

local rights = VC.Rights

-- The whole table is sound, or it is replaced whole (no field-wise repair).
local function sound(v)
  if type(v) ~= "table" or (v.era ~= "live" and v.era ~= "preview") then return false end
  local d = v.day
  if type(d) ~= "table" or not int(d.n, -1e6) or not marksOk(d.picks) then return false end
  if not int(d.paid, 0, rights(d.picks)) or (d.bonus ~= nil and type(d.bonus) ~= "boolean") then return false end
  if d.fin ~= nil and type(d.fin) ~= "string" then return false end
  if d.got ~= nil and not int(d.got, 0) then return false end
  local r = v.result
  if r ~= nil and (type(r) ~= "table" or not int(r.n, -1e6) or not marksOk(r.picks, true)) then return false end
  if not int(v.best, 0) or not int(v.cur, 0) or (v.last ~= nil and not int(v.last, -1e6)) then return false end
  return true
end

local function newDay(n) return { n = n, picks = "", paid = 0, bonus = false } end

local function fresh(n)
  return { era = n >= 1 and "live" or "preview", day = newDay(n), best = 0, cur = 0 }
end

-- Run first by every reader and action (f7255): the saved table if sound, else fresh; the day roll (an unfinished old
-- day is dropped, Store.lua:88); the first n >= 1 replaces a preview-era table whole (q1570). Outside demo it saves;
-- in demo it answers the table it would save and writes nothing (f7254). nil without a clock.
local function state()
  local n = ns.Day()
  if not n then return nil end
  local db = GuildSyncGamesDB
  local v = type(db) == "table" and db.vendor
  local demo = M.Demo()
  if not sound(v) then v = fresh(n)
  elseif demo then v = { era = v.era, day = v.day, result = v.result, best = v.best, cur = v.cur, last = v.last } end
  if n >= 1 and v.era ~= "live" then v = fresh(n) end
  if n > v.day.n then v.day = newDay(n) end
  if not demo then
    if type(GuildSyncGamesDB) ~= "table" then GuildSyncGamesDB = {} end
    GuildSyncGamesDB.vendor = v
  end
  return v
end

-- The daily streak, 0 once the last finished day is before yesterday.
local function streakOf(v)
  return (v.last and v.last >= v.day.n - 1) and v.cur or 0
end

local function hook(name)
  if ns[name] then M.Safe(ns[name]) end
end

local function pairsOf(n)
  local run = VC.Daily(n)
  if not run then return nil end
  local items, out = VC.Items(), {}
  for k, p in ipairs(run) do out[k] = { a = items[p.a], b = items[p.b] } end
  return out
end

local function rightOf(pair, k)
  return (pair.a.price > pair.b.price) == (k == 1)
end

function ns.VendorToday()
  local v = state()
  if not v then return nil end
  local day = v.day
  local prs = pairsOf(day.n)
  if not prs then return nil end
  local _, _, left = ns.Day()
  return { n = day.n, label = Core.Label(day.n), pairs = prs, picks = day.picks, done = #day.picks >= RUN,
    score = rights(day.picks), earned = day.got or 0, secsLeft = left }
end

function ns.VendorStats()
  local v = state()
  if not v then return { best = 0, cur = 0 } end
  return { best = v.best, cur = streakOf(v) }
end

-- The last finished run (or the endless-only record); never wrapped by the demo.
function ns.VendorBody()
  local v = state()
  if not v or (not v.result and v.best == 0) then return nil end
  local r = v.result
  return { n = r and r.n or v.day.n, marks = r and r.picks or "", best = v.best,
    streak = streakOf(v) }
end

-- ---------- endless: in memory only (as practice, Store.lua:170-207), never pays ----------

local mode, E = "daily", nil

local function drawNext()
  local a, b = VC.Draw(E.next, E.used, E.streak + 1)
  if not a then
    E.pair, E.done = nil, true
    return
  end
  E.used[a], E.used[b] = true, true
  local items = VC.Items()
  E.pair = { a = items[a], b = items[b] }
end

function ns.VendorMode(m)
  if m ~= "daily" and m ~= "endless" then return end
  if m == "endless" and ns.Inert() then return nil, "demo" end -- f7273: demo starts no run (o1654)
  mode = m
  if m == "endless" and (not E or E.done) then
    E = { next = VC.Stream(math.random(1, 2147483646)), used = {}, streak = 0, done = false }
    drawNext()
  end
end

function ns.VendorEndless()
  if mode ~= "endless" or not E then return nil end
  return { pair = E.pair, streak = E.streak, done = E.done }
end

local function endlessPick(k)
  if not E or E.done or not E.pair then return nil, "done" end
  local right = rightOf(E.pair, k)
  if right then
    E.streak = E.streak + 1
    drawNext()
  else
    E.done = true
  end
  if E.done then
    local v = state()
    local best = math.min(E.streak, BEST_MAX)
    if v and best > v.best then
      v.best = best
      hook("VendorBestChanged")
    end
  end
  return true, right
end

-- ---------- the daily pick ----------

-- n, i (the daily tab): the day and the pair the pick was made on; a pick for another day or pair is refused as rolled
-- (f7271), never judged against today's pair.
function ns.VendorPick(k, n, i)
  if ns.Inert() then return nil, "demo" end
  if k ~= 1 and k ~= 2 then return nil, "pick" end
  if mode == "endless" then return endlessPick(k) end
  local db = GuildSyncGamesDB
  local before = type(db) == "table" and type(db.vendor) == "table" and type(db.vendor.day) == "table"
    and db.vendor.day.n or nil
  local v = state()
  if not v then return nil, "clock", NO_CLOCK end
  local day = v.day
  if type(before) == "number" and day.n > before then return nil, "rolled", ns.ROLLED end
  if (n ~= nil and n ~= day.n) or (i ~= nil and i ~= #day.picks + 1) then return nil, "rolled", ns.ROLLED end
  if #day.picks >= RUN then return nil, "done" end
  local prs = pairsOf(day.n)
  if not prs then return nil, "done" end
  local right = rightOf(prs[#day.picks + 1], k)
  day.picks = day.picks .. (right and "1" or "0")

  -- Pay (f7251): paid and bonus written first, then ns.Credit only when owed >= 1 (n3), and only on a live day or a
  -- preview day before GC.LAUNCH (f7256, q1567).
  local c = rights(day.picks)
  local owed = 5 * (c - day.paid) + ((c == RUN and not day.bonus) and 25 or 0)
  day.paid, day.bonus = c, day.bonus or c == RUN
  local t = ns.Now()
  if owed >= 1 and (day.n >= 1 or (type(t) == "number" and t < GC.LAUNCH)) and ns.Credit then
    local ran, credited = M.Safe(ns.Credit, owed)
    if ran and credited == true then day.got = (day.got or 0) + owed end -- f7281: only grain the purse took
  end

  if #day.picks >= RUN then
    v.cur = (v.last == day.n - 1) and v.cur + 1 or 1
    v.last = day.n
    day.fin = ns.MyKey()
    v.result = { n = day.n, picks = day.picks }
    hook("VendorFinished")
    hook("FactsChanged")
  end
  return true, right
end
