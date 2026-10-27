-- GuildSyncGames Grain.lua (Task 3): the grain state, account-wide in GuildSyncGamesDB.grain = { era, purse, standing,
-- harvested, won, big, ranks = { farmhand, scythes, granary }, bet = { hour, lane, stake } | nil, last = { hour, pay }
-- | nil, hist = { { hour, lane, stake, pay } }, caravan = { start, hours, stake, back, kind } | nil, lastCaravan = (the
-- same) | nil, salt }, and GuildSyncGamesDB.lastGame. Read at call time through grain();
-- nothing here touches GuildSyncGamesDB at file execution (f7157). Every rule reads ns.Now() (f7154); RaceClock is for
-- drawing only. Play grain only: no gold, no items.
-- The field grows on one chained M.After(60) tick while the client runs. Without C_Timer M.After does not run and the
-- field does not grow, by design; settlement still runs on a read and at login. Do not add an OnUpdate (f7164).
-- Demo: player actions say the inert line through ns.Inert(); internal writes (the tick, the settle, the launch reset)
-- wait silently while M.Demo() is on (f7175).
-- Boards.lua hooks (T4), each called only when defined: ns.BoardsDirty() after a settle or a harvest, and
-- ns.BoardsTick(now) on every tick outside demo, so a flag set earlier drains on this one timer (d1547).

local _, ns = ...

if not ns.M then return end
local M, GC, CC = ns.M, ns.GrainCore, ns.CompanyCore

local HOUR = 3600
local FLOOR = GC.FLOOR -- a tick grows only this long after the last growth by server time (f7159)
local HIST = 8     -- races kept in hist
local GAMES = { wowdle = true, harvest = true, races = true, vendor = true }

local function fresh(t)
  return { era = (type(t) == "number" and t >= GC.LAUNCH) and "live" or "preview", purse = GC.START_PURSE, standing = 0,
    harvested = 0, won = 0, big = 0, ranks = { farmhand = 0, scythes = 0, granary = 0 }, hist = {} }
end

local function hook(name)
  if ns[name] then M.Safe(ns[name]) end
end

-- A due bet settles once: the bet is cleared in the same write that pays it (f7169).
local function settle(g, t)
  local b = g.bet
  if not (b and t and t >= b.hour * HOUR + GC.RUN) then return false end
  local r = GC.Race(b.hour)
  local pay = GC.Payout(b.stake, r.field[b.lane].pays, b.lane == r.winner)
  g.bet = nil
  g.purse, g.won = g.purse + pay, g.won + pay
  if pay > g.big then g.big = pay end
  g.last = { hour = b.hour, pay = pay }
  g.hist[#g.hist + 1] = { hour = b.hour, lane = b.lane, stake = b.stake, pay = pay }
  while #g.hist > HIST do table.remove(g.hist, 1) end
  return true
end

local function int(n, lo, hi)
  return type(n) == "number" and n == math.floor(n) and (not lo or n >= lo) and (not hi or n <= hi)
end

-- The saved shape (f7191, f7212, s1): the totals numbers, every rank 0..3, hist a table of rows with number hour, stake
-- and pay and a lane 1..6 (f7204). A table that fails is replaced whole by fresh(t), as at launch (f7180).
local function sound(g)
  for _, k in ipairs({ "purse", "standing", "harvested", "won", "big" }) do
    if type(g[k]) ~= "number" then return false end
  end
  if type(g.ranks) ~= "table" or type(g.hist) ~= "table" then return false end
  for _, u in ipairs(GC.UPGRADES) do
    if not int(g.ranks[u.id], 0, #u.prices) then return false end
  end
  for _, r in ipairs(g.hist) do
    if type(r) ~= "table" or not int(r.lane, 1, 6) then return false end -- the races page indexes field[lane] (f7204)
    for _, k in ipairs({ "hour", "lane", "stake", "pay" }) do
      if type(r[k]) ~= "number" then return false end
    end
  end
  return true
end

-- A bet settle can pay: a number hour, lane 1..6, a stake in BET_MIN..BET_MAX. A bad one is dropped, unpaid.
local function soundBet(b)
  return type(b) == "table" and int(b.hour) and int(b.lane, 1, 6) and int(b.stake, GC.BET_MIN, GC.BET_MAX)
end

local function among(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

-- A caravan can pay: a whole start, a trip in CC.TRIPS, a stake in CC.STAKES, a whole back >= 0. A bad one is dropped
-- as a field, unpaid; sound() never looks at it (d1591).
local function soundCaravan(v)
  return type(v) == "table" and int(v.start) and among(CC.TRIPS, v.hours) and among(CC.STAKES, v.stake)
    and int(v.back, 0)
end

-- A due caravan pays its sealed back once: cleared, purse and lastCaravan in the same write (AC2).
local function settleCaravan(g, t)
  local v = g.caravan
  if not (v and type(t) == "number" and t >= v.start + v.hours * HOUR) then return end
  g.caravan = nil
  g.purse = g.purse + v.back
  g.lastCaravan = { start = v.start, hours = v.hours, stake = v.stake, back = v.back, kind = v.kind }
end

-- The saved grain, made at call time. Outside demo it also does the launch reset (the whole table replaced, q1550,
-- f7174, f7180), replaces a table of the wrong shape, drops a bad bet and settles a due bet. In demo a missing or
-- unsound grain is a fresh unsaved table.
local function grain()
  local t, demo = ns.Now(), M.Demo()
  local d = GuildSyncGamesDB
  local ok = type(d) == "table" and type(d.grain) == "table" and sound(d.grain)
  if demo then return ok and d.grain or fresh(t) end
  if type(d) ~= "table" then
    d = {}
    GuildSyncGamesDB = d
  end
  if not ok then d.grain = fresh(t) end
  if d.grain.bet ~= nil and not soundBet(d.grain.bet) then d.grain.bet = nil end
  if d.grain.caravan ~= nil and not soundCaravan(d.grain.caravan) then d.grain.caravan = nil end
  if type(t) == "number" and t >= GC.LAUNCH and d.grain.era ~= "live" then d.grain = fresh(t) end
  if settle(d.grain, t) then
    hook("BoardsDirty")
    hook("ArmToast")
  end
  settleCaravan(d.grain, t)
  return d.grain
end

-- ---------- the tick ----------

local ticking, grownAt = false, nil -- outside grain: the launch reset compares the whole table

local function work()
  if M.Demo() then return end
  local t = ns.Now()
  local g = grain()
  if type(t) == "number" then
    if grownAt and t - grownAt >= FLOOR then g.standing = GC.Grow(g.standing, g.ranks) end
    if not grownAt or t - grownAt >= FLOOR then grownAt = t end
  end
  if g.bet then hook("ArmToast") end -- a toast missed while demo was on is armed now (f7193); ArmToast is idempotent
  if ns.BoardsTick then M.Safe(ns.BoardsTick, t) end
  if ns.VendorTick then M.Safe(ns.VendorTick, t) end -- VendorSync.lua (S12 T5), read at call time
  if ns.CompanyTick then M.Safe(ns.CompanyTick, t) end -- CompanySync.lua (S13 T4), read at call time
  local shown = ns.ShownGame and ns.ShownGame()
  if (shown == "harvest" or shown == "races" or shown == "company") and M.Compat.call("InCombatLockdown") == false
    and M.RefreshPage then
    M.RefreshPage()
  end
end

-- Re-arms first, so a throw in the work never ends the chain (f7160).
local function tick()
  M.After(60, tick)
  M.Safe(work)
end

local function start()
  if ticking then return end
  ticking = true
  grownAt = ns.Now()
  M.After(60, tick)
end

-- ---------- login ----------

local loggedIn, sessionStart = false, nil

-- Idempotent: records the session start, settles a past bet and caravan (in grain()), arms the toast for a pending bet
-- and starts the tick. Also runs at the first Farm, Purse or MyBet read if that comes before login.
function ns.OnLogin()
  if sessionStart == nil then sessionStart = ns.Now() end -- the first read with a clock when login had none (f5)
  if loggedIn then return end
  loggedIn = true
  if grain().bet then hook("ArmToast") end
  start()
end

local function read()
  ns.OnLogin()
  return grain()
end

-- ns.Now() at the first ns.OnLogin of this load with a clock; nil before (AC8). A reload is a new session.
function ns.SessionStart()
  if loggedIn and sessionStart == nil then sessionStart = ns.Now() end
  return sessionStart
end

-- ---------- the purse and the field ----------

function ns.Purse() return read().purse end

function ns.Spend(n)
  if ns.Inert() then return nil, "demo" end
  local g = grain()
  if type(n) ~= "number" or n < 0 or n ~= math.floor(n) or n > g.purse then return nil, "short" end
  g.purse = g.purse - n
  return true
end

-- Vendor price pays grain into the purse (S12): a whole n >= 1; harvested, won and the board body stay as they are.
function ns.Credit(n)
  if ns.Inert() then return nil, "demo" end
  if type(n) ~= "number" or n < 1 or n ~= math.floor(n) then return nil, "amount" end
  local g = grain()
  g.purse = g.purse + n
  return true
end

function ns.Farm()
  local g = read()
  local r = g.ranks
  return { standing = g.standing, cap = GC.Cap(r), rate = GC.Rate(r), harvested = g.harvested,
    ranks = { farmhand = r.farmhand, scythes = r.scythes, granary = r.granary } }
end

function ns.Harvest()
  if ns.Inert() then return nil, "demo" end
  local g = grain()
  local n = g.standing
  if n > 0 then
    g.standing, g.purse, g.harvested = 0, g.purse + n, g.harvested + n
    hook("BoardsDirty")
  end
  return n
end

function ns.Buy(id)
  if ns.Inert() then return nil, "demo" end
  local g = grain()
  local price = GC.NextPrice(g.ranks, id)
  if not price then return nil, "max" end
  if price > g.purse then return nil, "short" end
  g.purse = g.purse - price
  g.ranks[id] = g.ranks[id] + 1
  return true
end

-- ---------- bets ----------

-- Only the race now open for betting, by the real clock (f7154, f7156).
local function isOpen(hour)
  local t = ns.Now()
  if type(t) ~= "number" then return false end
  local ph, rh = GC.Phase(t)
  return ph == "betting" and hour == rh
end

-- One bet per race: a new bet on the same race replaces the old one and refunds its stake.
function ns.Bet(hour, lane, stake)
  if ns.Inert() then return nil, "demo" end
  if not isOpen(hour) or type(lane) ~= "number" or lane < 1 or lane > 6 or lane ~= math.floor(lane) then
    return nil, "closed"
  end
  if type(stake) ~= "number" or stake ~= math.floor(stake) or stake < GC.BET_MIN or stake > GC.BET_MAX then
    return nil, "stake"
  end
  local g = grain()
  local back = g.bet and g.bet.stake or 0
  if stake > g.purse + back then return nil, "short" end
  g.purse = g.purse + back - stake
  g.bet = { hour = hour, lane = lane, stake = stake }
  hook("ArmToast")
  return true
end

-- Until the race starts the stake comes back.
function ns.CancelBet()
  if ns.Inert() then return nil, "demo" end
  local g = grain()
  if not (g.bet and isOpen(g.bet.hour)) then return nil, "closed" end
  g.purse = g.purse + g.bet.stake
  g.bet = nil
  hook("ArmToast")
  return true
end

function ns.MyBet()
  local b = read().bet
  return b and { hour = b.hour, lane = b.lane, stake = b.stake } or nil
end

function ns.RaceHist()
  local out = {}
  for i, r in ipairs(grain().hist) do out[i] = { hour = r.hour, lane = r.lane, stake = r.stake, pay = r.pay } end
  return out
end

-- ---------- the caravan (S13) ----------

-- One trip at a time: the stake leaves the purse once and the return is sealed at the send from (MyKey, start, salt).
-- The salt is made here, once, the first time it is needed (s12).
function ns.SendCaravan(hours, stake)
  if ns.Inert() then return nil, "demo" end
  if not (among(CC.TRIPS, hours) and among(CC.STAKES, stake)) then return nil, "choice" end
  local t = ns.Now()
  if type(t) ~= "number" then return nil, "clock" end
  local g = grain()
  if g.caravan then return nil, "busy" end
  if stake > g.purse then return nil, "short" end
  if g.salt == nil then g.salt = math.random(2147483646) end
  local back, kind = CC.Outcome(hours, stake, CC.CaravanSeed(ns.MyKey(), t, g.salt))
  if not back then return nil, "choice" end
  g.purse = g.purse - stake
  g.caravan = { start = t, hours = hours, stake = stake, back = back, kind = kind }
  return true
end

-- The trip on the road; back shows only from the return time.
function ns.Caravan()
  local v = read().caravan
  if not v then return nil end
  local t = ns.Now()
  local home = type(t) == "number" and t >= v.start + v.hours * HOUR
  return { start = v.start, hours = v.hours, stake = v.stake, back = home and v.back or nil }
end

function ns.LastCaravan()
  local v = read().lastCaravan
  return v and { start = v.start, hours = v.hours, stake = v.stake, back = v.back, kind = v.kind } or nil
end

-- Drawing only (the Races page, the toast text); Demo.lua wraps it.
function ns.RaceClock() return ns.Now() end

-- "21:00" in realm time from GetGameTime's offset to UTC (rounded to the hour), else "21:00 UTC".
function ns.RaceLabel(h)
  local t = ns.Now()
  local gh, gm = M.Compat.call("GetGameTime")
  if type(t) == "number" and type(gh) == "number" and type(gm) == "number" then
    local utcMin = math.floor(t / 60) % 1440
    local off = math.floor((gh * 60 + gm - utcMin) / 60 + 0.5)
    return string.format("%02d:00", (h + off) % 24)
  end
  return string.format("%02d:00 UTC", h % 24)
end

-- Realm minus UTC in whole hours through CC.Offset, and whether GetGameTime gave it; (0, false) without (AC7).
function ns.RealmOffset()
  local t = ns.Now()
  local gh, gm = M.Compat.call("GetGameTime")
  if type(t) == "number" and type(gh) == "number" and type(gm) == "number" then return CC.Offset(gh, gm, t), true end
  return 0, false
end

-- The own board row (Boards.lua packs it): nil until grain was ever harvested or won. Real grain, even in demo.
function ns.BoardBody()
  local g = grain()
  if g.harvested == 0 and g.won == 0 then return nil end
  local last = g.last or { hour = 0, pay = 0 }
  return { harvested = g.harvested, won = g.won, big = g.big, hour = last.hour, pay = last.pay }
end

-- ---------- the last game chosen (the flight prompt offers it) ----------

-- A known key is saved; anything else, or demo, changes nothing.
function ns.SetLastGame(key)
  if not GAMES[key] or M.Demo() then return end
  GuildSyncGamesDB = type(GuildSyncGamesDB) == "table" and GuildSyncGamesDB or {}
  GuildSyncGamesDB.lastGame = key
end

function ns.LastGame()
  local d = GuildSyncGamesDB
  local key = type(d) == "table" and d.lastGame
  return GAMES[key] and key or "wowdle"
end
