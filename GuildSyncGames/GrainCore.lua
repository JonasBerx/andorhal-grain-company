-- GuildSyncGames GrainCore.lua (Task 2): the pure grain core, ns.GrainCore (upgrades, growth, the hourly kodo race,
-- odds, the race clock, lane positions, the board body). Loads after Core.lua.
-- Pure: string, table and math only, no globals, no date or time (the hour comes in as server seconds).
-- Every division is by a constant. Draws go through Core.Order only: no copy of its step, no edit to Core.lua.

local _, ns = ...

local Core = ns.Core
local GC = {}
ns.GrainCore = GC

local SEED_MOD = 2147483646 -- seeds land in 1..2147483646, valid for Park-Miller
local RESIDUE = 8388608     -- 2^23: (r * 8 + 4)^2 stays below 2^53, exact in doubles
local MAX_BOARD = 80        -- a real board body is at most 49 bytes (five 9-digit fields and 4 carets)
local MAX_DIGITS = 9
local BASE_RATE = 2
local BASE_CAP = 120
local HOUR = 3600

GC.LAUNCH = 1793750400 -- 2026-11-04 00:00 UTC, the same instant as Core.lua's LAUNCH_UTC (Core.Puzzle gives n = 1)
GC.HOUR = HOUR
GC.FLOOR = 50  -- a tick grows only this long after the last growth (Grain.lua reads it; Limits.lua L7)
GC.RUN = 45    -- a race runs the first 45 s of its hour
GC.OPEN = 300  -- results show until 300 s; then betting opens for the next hour's race
GC.START_PURSE = 50
GC.BET_MIN = 5
GC.BET_MAX = 200

-- ---------- the field ----------

GC.UPGRADES = {
  { id = "farmhand", name = "Ghoul farmhand", icon = 136187, rate = 1, cap = 0, prices = { 100, 250, 500 } },
  { id = "scythes", name = "Sharper scythes", icon = 1060569, rate = 2, cap = 0, prices = { 300, 750, 1500 } },
  { id = "granary", name = "Plague-proof granary", icon = 132762, rate = 0, cap = 240, prices = { 200, 500, 1000 } },
}

local function upgrade(id)
  for _, u in ipairs(GC.UPGRADES) do
    if u.id == id then return u end
  end
  return nil
end

local function rank(ranks, id) return (type(ranks) == "table" and tonumber(ranks[id])) or 0 end

-- Grain a minute: 2, plus each rank's rate.
function GC.Rate(ranks)
  local n = BASE_RATE
  for _, u in ipairs(GC.UPGRADES) do n = n + u.rate * rank(ranks, u.id) end
  return n
end

-- Grain the field holds: 120, plus each rank's cap.
function GC.Cap(ranks)
  local n = BASE_CAP
  for _, u in ipairs(GC.UPGRADES) do n = n + u.cap * rank(ranks, u.id) end
  return n
end

-- One minute's growth, never past the cap (and never less than what stands).
function GC.Grow(standing, ranks)
  local cap = GC.Cap(ranks)
  if standing >= cap then return standing end
  return math.min(cap, standing + GC.Rate(ranks))
end

-- The next rank's price, nil at the top rank or for an unknown id.
function GC.NextPrice(ranks, id)
  local u = upgrade(id)
  if not u then return nil end
  return u.prices[rank(ranks, id) + 1]
end

-- ---------- the kodos ----------

-- Twelve kodos over the six kodo icons, two names to an icon.
GC.ROSTER = {
  { name = "Thunderhoof", icon = 132243 },
  { name = "Old Greyhide", icon = 132244 },
  { name = "Mudwallow", icon = 132245 },
  { name = "Barrens Express", icon = 7936025 },
  { name = "Dustplod", icon = 329848 },
  { name = "Snoozehide", icon = 1120007 },
  { name = "Ironhorn", icon = 132243 },
  { name = "Wanderhoof", icon = 132244 },
  { name = "Rumblebelly", icon = 132245 },
  { name = "Mulgore Mist", icon = 7936025 },
  { name = "Bramblesnout", icon = 329848 },
  { name = "Gristlehorn", icon = 1120007 },
}

-- WEIGHTS[i] is the chance weight of the lane that pays PAYS[i]. Roughly 1/pays, so one grain on a lane picked at
-- random returns about 70% (sum of WEIGHTS[i] * PAYS[i] / sum WEIGHTS / 6 = 1255 / 299 / 6 = 0.700, o1604).
GC.PAYS = { 2, 3, 4, 6, 9, 15 }
GC.WEIGHTS = { 105, 70, 52, 35, 23, 14 }

-- Seconds after the start at which each finisher reaches the line, first to sixth; all are in by GC.RUN.
local ARRIVE = { 39, 40, 41, 42, 43, 44 }
local SPEED = { 1 / 39, 1 / 40, 1 / 41, 1 / 42, 1 / 43, 1 / 44 }
-- A sway per finisher, under 1/pi so a runner never steps back: the winner comes late, others lead early.
local SWAY = { -0.06, 0.05, -0.03, 0.06, -0.04, 0.02 }

-- ---------- the draw ----------

-- Hour h's k-th seed (k = 1..4). Quadratic in a 23-bit residue of h, so no two (h, k) share a seed and the hours do
-- not walk a straight line (f7161, f7171).
function GC.Seed(h, k)
  local r = Core.Mod(h, RESIDUE)
  return Core.Mod((r * 8 + k) ^ 2, SEED_MOD) + 1
end

local function total(list)
  local n = 0
  for _, v in ipairs(list) do n = n + v end
  return n
end

-- The pays index the weighted draw u (1..sum WEIGHTS) lands on.
local function weighted(u)
  local acc = 0
  for i, w in ipairs(GC.WEIGHTS) do
    acc = acc + w
    if u <= acc then return i end
  end
  return #GC.WEIGHTS
end

-- Hour h's race: { hour, field = { { name, icon, pays } x6 }, order = { lane x6 }, winner }. The same for everyone.
function GC.Race(h)
  local kodos = Core.Order(#GC.ROSTER, GC.Seed(h, 1))
  local paysAt = Core.Order(#GC.PAYS, GC.Seed(h, 2))
  local field = {}
  for lane = 1, 6 do
    local k = GC.ROSTER[kodos[lane]]
    field[lane] = { name = k.name, icon = k.icon, pays = GC.PAYS[paysAt[lane]] }
  end
  local wi = weighted(Core.Order(total(GC.WEIGHTS), GC.Seed(h, 3))[1])
  local winner, rest = nil, {}
  for lane = 1, 6 do
    if paysAt[lane] == wi then winner = lane else rest[#rest + 1] = lane end
  end
  local order = { winner }
  for _, i in ipairs(Core.Order(5, GC.Seed(h, 4))) do order[#order + 1] = rest[i] end
  return { hour = h, field = field, order = order, winner = winner }
end

-- ---------- the clock ----------

-- The race hour of server time t, and the seconds into it.
function GC.RaceAt(t)
  local h = math.floor(t / HOUR)
  return h, t - h * HOUR
end

-- "running" (h) for the first 45 s, "finished" (h) to 300 s, then "betting" for the next race (h + 1).
function GC.Phase(t)
  local h, s = GC.RaceAt(t)
  if s < GC.RUN then return "running", h end
  if s < GC.OPEN then return "finished", h end
  return "betting", h + 1
end

function GC.Payout(stake, pays, won)
  if not won then return 0 end
  return stake * pays
end

-- How far lane has run at secs into the race, 0..1 (drawing only; the only float math in this file).
function GC.Pos(race, lane, secs)
  local place = 6
  for i, l in ipairs(race.order) do
    if l == lane then place = i end
  end
  if secs <= 0 then return 0 end
  if secs >= ARRIVE[place] then return 1 end
  local x = secs * SPEED[place]
  return math.max(0, math.min(1, x + SWAY[place] * math.sin(math.pi * x)))
end

-- ---------- the board body ----------

-- b = { harvested, won, big, hour, pay } -> "5860^1240^160^492707^160".
function GC.PackBoard(b)
  return b.harvested .. "^" .. b.won .. "^" .. b.big .. "^" .. b.hour .. "^" .. b.pay
end

-- Strict: five digit fields of at most 9 digits; big <= won, pay <= big; hour <= hourNow + 1 (hour 0 with pay 0 is
-- a board harvested but never bet).
function GC.ParseBoard(body, hourNow)
  if type(body) ~= "string" or type(hourNow) ~= "number" or #body > MAX_BOARD then return nil, "not a body" end
  local f = { body:match("^(%d+)%^(%d+)%^(%d+)%^(%d+)%^(%d+)$") }
  if #f ~= 5 then return nil, "not a body" end
  for i = 1, 5 do
    if #f[i] > MAX_DIGITS then return nil, "not a body" end
    f[i] = tonumber(f[i])
  end
  local b = { harvested = f[1], won = f[2], big = f[3], hour = f[4], pay = f[5] }
  if b.big > b.won then return nil, "big" end
  if b.pay > b.big then return nil, "pay" end
  if b.hour > hourNow + 1 then return nil, "hour" end
  return b
end
