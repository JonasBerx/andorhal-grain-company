-- GuildSyncExpeditions RiskCore.lua: ns.RiskCore, the pure risk rules (0.19 plan, Seams 4).
-- Pure: string, table and math only, no globals, no game calls, no random.
--   RC.Need(level, danger) -> n
--   RC.Chances(power, need, danger, modsList) -> { success, wound, death, perma, broken, lost, bands } | nil
--     mods, in order race, trait, supply, set: { success, deathPct, woundPct, gearPct, broken, noPerma, rest }
--   RC.Seed(key, start, salt) -> 1..2147483646         RC.Stream(seed) -> a function answering [0, 1) | nil
--   RC.Roll(chances, seed, wornSlots) -> { band, gear = "broken" | "lost" | nil, slot = key | nil }

local _, ns = ...
if not ns.M then return end

local RC = {}
ns.RiskCore = RC

local floor = math.floor

local PM = 2147483647 -- Park-Miller modulus
local INV_M = 1 / PM
local MULT = 16807

-- By danger 1..4 (economy.md section 3).
local S0 = { 85, 70, 55, 40 }
local K = { 0, 10, 25, 40 }
local W = { 5, 10, 15, 20 }
local L = { 0, 1, 3, 6 }
local B = { 3, 6, 10, 15 }

local BANDS = { "perma", "dead", "failw", "fail", "succw", "succ" } -- the order the roll walks

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- A pct field, floored and clamped after each multiply.
local function scaled(pct, by)
  if type(by) ~= "number" then return pct end
  return clamp(floor(pct * by / 100), 0, 100)
end

local function added(sum, by)
  if type(by) ~= "number" then return sum end
  return sum + by
end

function RC.Need(level, danger)
  return 7 * level + 4 * (danger - 1) + 3
end

function RC.Chances(power, need, danger, modsList)
  if not S0[danger] then return nil end
  local plus, brokenBy, noPerma = 0, 0, false
  local deathPct, woundPct, gearPct = 100, 100, 100
  for _, mod in ipairs(modsList or {}) do
    if type(mod) == "table" then
      plus = added(plus, mod.success)
      brokenBy = added(brokenBy, mod.broken)
      deathPct = scaled(deathPct, mod.deathPct)
      woundPct = scaled(woundPct, mod.woundPct)
      gearPct = scaled(gearPct, mod.gearPct)
      if mod.noPerma == true then noPerma = true end
    end
  end

  local s = clamp(S0[danger] + power - need + plus, 5, 95)
  local f = 100 - s
  local dth = floor(f * floor(K[danger] * deathPct / 100) / 100)
  local perma = (danger == 4 and not noPerma) and floor(dth * 50 / 100) or 0
  local failw = floor((f - dth) * 60 * woundPct / 10000)
  local succw = floor(s * W[danger] * woundPct / 10000)
  return {
    success = s,
    wound = failw + succw,
    death = dth,
    perma = perma,
    broken = math.max(0, floor(B[danger] * gearPct / 100) - brokenBy),
    lost = floor(L[danger] * gearPct / 100),
    bands = { perma = perma, dead = dth - perma, failw = failw, fail = f - dth - failw, succw = succw, succ = s - succw },
  }
end

-- A byte hash of the key, then the two numbers. Every product stays under 2^53. The last two rounds are not linear:
-- without them the seeds of consecutive days are a fixed step apart, and so are their first draws.
function RC.Seed(key, start, salt)
  local h = 1
  for i = 1, #key do
    h = (h * MULT + string.byte(key, i)) % PM
  end
  h = (h * MULT + start % PM) % PM
  h = (h * MULT + salt % PM) % PM
  for _ = 1, 2 do
    h = h * (h % 46341 + 1) % PM
  end
  return h == 0 and 1 or h
end

-- Park-Miller; a seed outside [1, PM - 1] is refused (0 sticks at 0).
function RC.Stream(seed)
  if type(seed) ~= "number" or seed ~= floor(seed) or seed < 1 or seed > PM - 1 then return nil end
  local x = seed
  return function()
    x = MULT * x % PM
    return x * INV_M
  end
end

local function draw(stream, n)
  return floor(stream() * n) + 1
end

function RC.Roll(chances, seed, wornSlots)
  local stream = RC.Stream(seed)
  local d, sum, out = draw(stream, 100), 0, {}
  for _, name in ipairs(BANDS) do
    sum = sum + chances.bands[name]
    if d <= sum then
      out.band = name
      break
    end
  end
  if out.band ~= "perma" and #wornSlots > 0 then
    local g = draw(stream, 100)
    if g <= chances.lost then
      out.gear = "lost"
    elseif g <= chances.lost + chances.broken then
      out.gear = "broken"
    end
    if out.gear then out.slot = wornSlots[draw(stream, #wornSlots)] end
  end
  return out
end
