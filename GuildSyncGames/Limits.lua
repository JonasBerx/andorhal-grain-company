-- GuildSyncGames Limits.lua (S14 Task 1): the pure limit table, ns.Limits (L1-L15: how far a guildmate's row can
-- honestly have got by the receiver's clock). Loads after CompanyCore.lua.
-- Pure: string, table and math only, no globals, no clock: t (the receiver's ns.Now()) comes in, and every check
-- answers false, "clock" without it. Every bound is a formula over the cores' constants, except L.MAX_RATE (frozen).
--
-- API:
--   L.Start(t) -> S (GC.LAUNCH from launch on, PREVIEW_START before it) | nil
--   L.WoWdle(res, t), L.Board(b, t), L.Vendor(b, t) -> true | false, why   (the parsed shapes)
--     L.Vendor also checks the Flights block b.f when present (S21: L.FLIGHTS_BEST_CAP); a bad b.f drops the row.
--   L.Who(b, t) -> true | false, why   (S22: the parsed Who said it block b.w; L.Vendor leaves it out, a bad b.w drops
--     only the Who row)
--   L.Company(b, t, off, members, mode) -> true | false, why
--     off = CC.ParseRow's officer part or nil; members = the largest full-read roster count this session or nil;
--     mode "merge" | "fold". With members nil the lottery term is left out of L11; merge skips L13 and fold refuses
--     any d item ("roster", d1608). L11's inflow pays all three dailies a day (Vendor, Flights, Who said it), doubled
--     by a lucky charm (L.CHARM_MULT), and the Kodo stables at the cap: a dividend a race (L.STABLES_RACE) and the
--     price spread a day (L.STABLES_DAY).
-- Reading: L11's draws counts the drawAt times in (S, t] for the realm offset that gives the most (the signature
-- carries no offset), so the bound is never tighter than the realm's own count.

local _, ns = ...

local Core, GC, CC, WC, SC = ns.Core, ns.GrainCore, ns.CompanyCore, ns.WhoCore, ns.StablesCore
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

-- The 1 h rich road at the top stake; the longer trips return less an hour (700 / 2, 1150 / 4, 1150 / 8 at 500).
local function caravanHour()
  return math.floor(maxOf(CC.STAKES) * CC.RICH_PCT[1] / 100)
end

L.MAX_RATE = 11                           -- frozen, not GC.Rate: players farmed at the old top rate since launch (games_balance_test pins it)
L.BIG = GC.BET_MAX * maxOf(GC.PAYS)       -- 3000, the top bet at the top odds
L.VENDOR_DAY = 75                         -- 5 x 10 + 25, VendorStore.lua's day pay and streak bonus
L.FLIGHTS_DAY = 75                        -- the same for the Flights pool (S21, o2167)
L.CARAVAN_HOUR = caravanHour()            -- 600, the best caravan return an hour
L.WHO_DAY = WC and WC.Pay(10) or 0        -- 75, a full Who said it run (0 without WhoCore.lua)
L.CHARM_MULT = GC.CHARM_MULT              -- 2, a lucky charm doubles a daily's pay
L.STABLES_RACE = SC and SC.SHARES_MAX * SC.DIV or 0 -- 20, a full holding's dividend a race (0 without it)
L.STABLES_DAY = SC and SC.SHARES_MAX * (SC.PRICE_MAX - SC.PRICE_MIN) or 0 -- 4200, bought low, sold high
L.BEST_CAP = math.floor(#ns.ITEMS / 2)    -- two unused items a pair
L.FLIGHTS_BEST_CAP = math.floor(#ns.ROUTES / 2) -- two unused routes a pair
L.WHO_BEST_CAP = ns.VOICES and #ns.VOICES.lines or 0 -- an endless run never repeats a line (0 without Voices.lua)
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
  if res.hint ~= nil and res.hint ~= true then return false, "hint" end
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
local function vendorBlock(b, cap)
  if b.score > 10 or #b.marks > 10 then return false, "score" end
  if b.best > cap then return false, "best" end
  if not streakOk(b.n, b.streak) then return false, "streak" end
  return true
end

function L.Vendor(b, t)
  if type(t) ~= "number" then return false, "clock" end
  local good, why = vendorBlock(b, L.BEST_CAP)
  if good and b.f then good, why = vendorBlock(b.f, L.FLIGHTS_BEST_CAP) end
  return good, why
end

-- L14 (score, marks), L15 (best, streak)
function L.Who(b, t)
  if type(t) ~= "number" then return false, "clock" end
  return vendorBlock(b, L.WHO_BEST_CAP)
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
  local inflow = START_PURSE + L.MAX_RATE * grows + L.BIG * races
    + L.CHARM_MULT * (L.VENDOR_DAY + L.FLIGHTS_DAY + L.WHO_DAY) * days
    + L.CARAVAN_HOUR * races + L.STABLES_RACE * races + L.STABLES_DAY * days
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
