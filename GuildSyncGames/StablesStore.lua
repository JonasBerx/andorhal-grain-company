-- GuildSyncGames StablesStore.lua (run r-20261107-games-more-to-buy-with-grain-escort-bone, Task 5): the Kodo stables
-- store. GuildSyncGamesDB.stables = { total, kodo?, shares?, at?, paid? }: total the dividends credited so far; kodo
-- the GC.ROSTER index held (one kodo at a time), shares 1..SC.SHARES_MAX, at the epoch of the last buy or exchange
-- (the lock opens at at + SC.LOCK), paid the last race hour settled. Checked by its own soundStables, never by another
-- table's sound(); in demo nothing is checked, dropped, settled or written. Every taken action and every read first
-- settles the dividends due on the old holding (the last SC.CATCHUP finished races only), then a buy or exchange sets
-- paid = the current race hour, so that hour's race never pays the new holding. A top-up, sale or exchange is refused
-- "running" while a race runs (gate A correction 3); a fresh buy is allowed at any second. A refusal before the trade
-- (other, running, cap, none, same, locked, and an exchange into 0 shares, "short", d2047) settles nothing; a
-- "short" buy has settled first.

local _, ns = ...

if not ns.M then return end
local M, GC, SC = ns.M, ns.GrainCore, ns.StablesCore
local INT_MAX = 2147483647 -- the ceiling of total, at and paid (review s1: math.huge is not a sound value)

local function whole(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

-- A holding is all four fields sound, or none of them there.
local function soundStables(s)
  if s.kodo == nil and s.shares == nil and s.at == nil and s.paid == nil then return true end
  return whole(s.kodo, 1, #GC.ROSTER) and whole(s.shares, 1, SC.SHARES_MAX) and whole(s.at, 0, INT_MAX)
    and whole(s.paid, 0, INT_MAX)
end

local function held(s)
  return s.kodo ~= nil and soundStables(s)
end

local function clear(s) s.kodo, s.shares, s.at, s.paid = nil, nil, nil, nil end

-- The saved stables, made at call time. Outside demo a bad total resets to 0 and a bad holding is dropped alone; in
-- demo a missing table is a fresh unsaved one and a bad one is left as it is.
local function stables()
  local d = GuildSyncGamesDB
  if M.Demo() then
    local s = type(d) == "table" and d.stables or nil
    return type(s) == "table" and s or { total = 0 }
  end
  if type(d) ~= "table" then
    d = {}
    GuildSyncGamesDB = d
  end
  if type(d.stables) ~= "table" then d.stables = { total = 0 } end
  local s = d.stables
  if not whole(s.total, 0, INT_MAX) then s.total = 0 end
  if not soundStables(s) then clear(s) end
  return s
end

-- Pays the wins of the held kodo in (paid, lf], not before lf - SC.CATCHUP + 1; paid written before the credit.
local function settle(s, t)
  if M.Demo() or type(t) ~= "number" or not held(s) then return end
  local lf = (GC.RaceAt(t))
  if GC.Phase(t) == "running" then lf = lf - 1 end
  if lf <= s.paid then return end
  local from = math.max(s.paid + 1, lf - SC.CATCHUP + 1)
  local pay = SC.Dividend(s.kodo, s.shares, from, lf)
  s.paid = lf
  if pay >= 1 and ns.Credit then
    local ran, credited = M.Safe(ns.Credit, pay)
    if ran and credited == true then s.total = s.total + pay end
  end
end

-- Credits n through M.Safe; true when there was nothing to credit or the purse took it (review s2).
local function credit(n)
  if n < 1 then return true end
  local ran, credited = M.Safe(ns.Credit, n)
  return ran and credited == true
end

function ns.Stable()
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  local s = stables()
  settle(s, t)
  local h = (GC.RaceAt(t))
  local prices = SC.Prices(h)
  local holding
  if held(s) then
    local kodo = GC.ROSTER[s.kodo]
    holding = { kodo = s.kodo, name = kodo.name, icon = kodo.icon, shares = s.shares, value = s.shares * prices[s.kodo],
      opensAt = s.at + SC.LOCK, locked = t < s.at + SC.LOCK, total = s.total }
  end
  return { hour = h, prices = prices, holding = holding, total = s.total }
end

function ns.StablesTick(t)
  if M.Demo() then return end
  settle(stables(), type(t) == "number" and t or ns.Now())
end

function ns.StableBuy(k, n)
  if ns.Inert() then return nil, "demo" end
  local t = ns.Now()
  if type(t) ~= "number" then return nil, "clock" end
  if not whole(k, 1, #GC.ROSTER) then return nil, "kodo" end
  if not whole(n, 1, SC.SHARES_MAX) then return nil, "count" end
  local s = stables()
  local have = held(s) and s.shares or 0
  if have > 0 and s.kodo ~= k then return nil, "other" end
  if have > 0 and GC.Phase(t) == "running" then return nil, "running" end
  if have + n > SC.SHARES_MAX then return nil, "cap" end
  settle(s, t)
  local h = (GC.RaceAt(t))
  local cost = SC.BuyCost(n, SC.Prices(h)[k])
  if not ns.Spend(cost) then return nil, "short" end
  s.paid = h
  s.kodo, s.shares, s.at = k, have + n, t
  return true
end

-- The refusals a sale and an exchange share; answers the holding's table or nil, why.
local function open(t)
  local s = stables()
  if not held(s) then return nil, "none" end
  if GC.Phase(t) == "running" then return nil, "running" end
  if t < s.at + SC.LOCK then return nil, "locked" end
  return s
end

function ns.StableSell()
  if ns.Inert() then return nil, "demo" end
  local t = ns.Now()
  if type(t) ~= "number" then return nil, "clock" end
  local s, why = open(t)
  if not s then return nil, why end
  settle(s, t)
  local got = SC.SaleValue(s.shares, SC.Prices((GC.RaceAt(t)))[s.kodo])
  if not credit(got) then return nil end -- the purse did not take it: the shares are kept
  clear(s)
  return true
end

function ns.StableExchange(k)
  if ns.Inert() then return nil, "demo" end
  local t = ns.Now()
  if type(t) ~= "number" then return nil, "clock" end
  if not whole(k, 1, #GC.ROSTER) then return nil, "kodo" end
  local s = stables()
  if held(s) and s.kodo == k then return nil, "same" end
  local why
  s, why = open(t)
  if not s then return nil, why end
  local h = (GC.RaceAt(t))
  local p = SC.Prices(h)
  local shares, rest = SC.Exchange(s.shares, p[s.kodo], p[k])
  if shares < 1 then return nil, "short" end -- d2047: no exchange into 0 shares; nothing settled or changed
  settle(s, t)
  if not credit(rest) then return nil end -- the purse did not take the rest: the holding is kept
  s.paid = h
  s.kodo, s.shares, s.at = k, shares, t
  return true
end
