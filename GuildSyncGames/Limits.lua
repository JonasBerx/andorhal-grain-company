-- GuildSyncGames Limits.lua (S14 Task 1): the pure limit table, ns.Limits (L1-L13: how far a guildmate's row can
-- honestly have got by the receiver's clock). Loads after CompanyCore.lua.
-- Pure: string, table and math only, no globals, no clock: t (the receiver's ns.Now()) comes in, and every check
-- answers false, "clock" without it. Every bound is a formula over the cores' constants.
--
-- API:
--   L.Start(t) -> S (GC.LAUNCH from launch on, PREVIEW_START before it) | nil
--   L.WoWdle(res, t), L.Board(b, t), L.Vendor(b, t) -> true | false, why   (the parsed shapes)
--   L.Company(b, t, off, members, mode) -> true | false, why
--     off = CC.ParseRow's officer part or nil; members = the largest full-read roster count this session or nil;
--     mode "merge" | "fold". With members nil the lottery term is left out of L11; merge skips L13 and fold refuses
--     any d item ("roster", d1608).
-- Reading: L11's draws counts the drawAt times in (S, t] for the realm offset that gives the most (the signature
-- carries no offset), so the bound is never tighter than the realm's own count.

local _, ns = ...

local Core, GC, CC = ns.Core, ns.GrainCore, ns.CompanyCore
local L = {}
ns.Limits = L

local HOUR = 3600
local DAY = 86400
local GIFT_STEP = 10
local START_PURSE = GC.START_PURSE
local FLOOR = 50 -- GC.FLOOR, written as a literal for the division rule (games_limits_core_test pins both)

local function maxOf(list)
  local m = 0
  for _, v in ipairs(list) do if v > m then m = v end end
  return m
end

local function topRate()
  local ranks = {}
  for _, u in ipairs(GC.UPGRADES) do ranks[u.id] = #u.prices end
  return GC.Rate(ranks)
end

-- The 1 h rich road at the top stake; the longer trips return less an hour (700 / 2, 1150 / 4, 1150 / 8 at 500).
local function caravanHour()
  return math.floor(maxOf(CC.STAKES) * CC.RICH_PCT[1] / 100)
end

L.MAX_RATE = topRate()                    -- 11 grain a grow at max ranks
L.BIG = GC.BET_MAX * maxOf(GC.PAYS)       -- 3000, the top bet at the top odds
L.VENDOR_DAY = 75                         -- 5 x 10 + 25, VendorStore.lua's day pay and streak bonus
L.CARAVAN_HOUR = caravanHour()            -- 600, the best caravan return an hour
L.BEST_CAP = math.floor(#ns.ITEMS / 2)    -- two unused items a pair
L.SKEW = 300
L.PREVIEW_DAYS = Core.PREVIEW_DAYS
L.PREVIEW_START = GC.LAUNCH - (L.PREVIEW_DAYS + 1) * DAY -- 2026-10-20 00:00 UTC
L.MEMBER_SLACK = 50
L.TOTAL_CAP = CC.TOTAL_CAP                -- TICKETS_MAX x (1000 + MEMBER_SLACK)

function L.Start(t)
  if type(t) ~= "number" then return nil end
  return t >= GC.LAUNCH and GC.LAUNCH or L.PREVIEW_START
end

local function terms(t)
  local S = L.Start(t)
  local e = math.max(0, t - S) + L.SKEW
  return S, math.floor(e / FLOOR), math.floor(e / HOUR) + 1, math.floor(e / DAY) + 2
end

-- The last week whose draw is at or before x.
local function drawn(x, off)
  local w, _, drawAt = CC.Week(x, off)
  return drawAt == x and w or w - 1
end

local function draws(S, t)
  local most = 0
  for off = -12, 11 do
    local n = drawn(t, off) - drawn(S, off)
    if n > most then most = n end
  end
  return most
end

local function streakOk(n, streak)
  return streak <= (n >= 1 and n or n + L.PREVIEW_DAYS)
end

-- L1, L2
function L.WoWdle(res, t)
  if type(t) ~= "number" then return false, "clock" end
  if res.tries < 0 or res.tries > 6 or #res.rows > 6 then return false, "tries" end
  if not streakOk(res.n, res.streak) then return false, "streak" end
  return true
end

-- L7-L10
function L.Board(b, t)
  if type(t) ~= "number" then return false, "clock" end
  local S, grows, races = terms(t)
  if b.harvested > L.MAX_RATE * grows then return false, "harvested" end
  if b.won > L.BIG * races then return false, "won" end
  if b.big > L.BIG or b.pay > L.BIG then return false, "big" end
  if b.hour ~= 0 and b.hour < math.floor(S / HOUR) then return false, "hour" end
  return true
end

-- L3-L5
function L.Vendor(b, t)
  if type(t) ~= "number" then return false, "clock" end
  if b.score > 10 or #b.marks > 10 then return false, "score" end
  if b.best > L.BEST_CAP then return false, "best" end
  if not streakOk(b.n, b.streak) then return false, "streak" end
  return true
end

-- L6, L11-L13
function L.Company(b, t, off, members, mode)
  if type(t) ~= "number" then return false, "clock" end
  if b.count > CC.TICKETS_MAX or b.prevCount > CC.TICKETS_MAX then return false, "tickets" end
  local sum = 0
  for k = 1, 6 do
    local g = b.gifts[k]
    if g < 0 or g % GIFT_STEP ~= 0 then return false, "gift" end
    sum = sum + g
  end
  local S, grows, races, days = terms(t)
  local inflow = START_PURSE + L.MAX_RATE * grows + L.BIG * races + L.VENDOR_DAY * days + L.CARAVAN_HOUR * races
  if members then
    inflow = inflow + draws(S, t) * (members + L.MEMBER_SLACK) * CC.TICKETS_MAX * CC.TICKET_PRICE
  end
  if sum > inflow then return false, "gifts" end
  local d = off and off.draw
  if d then
    if not members then
      if mode == "fold" then return false, "roster" end
    elseif (d.total or 0) > CC.TICKETS_MAX * (members + L.MEMBER_SLACK) then
      return false, "draw"
    end
  end
  return true
end
