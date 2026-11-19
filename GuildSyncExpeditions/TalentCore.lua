-- GuildSyncExpeditions TalentCore.lua: ns.TalentCore, the pure talent rules (issue 13 spec, build step 1).
-- Pure: string, table and math only, no globals, no game calls. A tree is a TalentData.TREES entry; ranks is a list of
-- whole numbers in its tree order (a missing entry is 0); row is a board row ({ kind, danger, hours, ... }).
--   TC.Points(level) -> n                              2 x (level - 1), 0 for a level that is not a whole number >= 1
--   TC.Spent(tree, ranks) -> n                         the points in the build
--   TC.Problem(tree, ranks, level) -> nil | "rank" | "tier" | "arrow" | "points"
--     checked in that order: each rank whole and within its max; tier t holds points only when the tiers above hold
--     3 x (t - 1); a talent with needs holds points only when that talent is at full rank; the build within
--     TC.Points(level). Level nil skips the points check.
--   TC.CanAdd(tree, ranks, i, level) -> true | nil, why    one more rank on talent i leaves no Problem
--   TC.CanTake(tree, ranks, i) -> true | nil, why          talent i holds a rank and one less leaves no Problem
--   TC.TierNeed(tier) -> n                             the points the tiers above must hold: 3 x (tier - 1)
--   TC.Above(tree, ranks, tier) -> n                   the points the build holds in the tiers above that tier
--   TC.Index(tree, id) -> i | nil                      TC.RanksOf(tree, byId) -> ranks | nil (nil on an unknown id)
--   TC.Power(tree, ranks, row) -> n                    the Power talents that row meets; row nil counts only the
--                                                      talents with no condition
--   TC.Mods(tree, ranks, row) -> { mod, ... }          one RiskCore mod table per talent with an odds or rest effect,
--     in tree order (RiskCore.Chances multiplies the pct fields one after another): woundPct / deathPct / gearPct =
--     100 - per x rank, broken and rest = per x rank, noPerma = true. Row nil: only talents with no condition.
--   TC.Percent(tree, ranks, lever) -> n                lever "xp" | "grain" | "salvage" (percent more) | "raise"
--                                                      (percent off); talents with no condition only; 0 otherwise
--   TC.Find(tree, ranks, reward) -> n                  percent more often for a LootData reward (green, relic, ...)

local _, ns = ...
if not ns.M then return end

local TC = {}
ns.TalentCore = TC

local floor = math.floor

local TIER_STEP = 3 -- points in the tiers above, per tier below the first
local PCT = { wound = "woundPct", death = "deathPct", gear = "gearPct" }
local SUMMED = { "broken", "rest" }
local LEVERS = { xp = true, grain = true, salvage = true, raise = true }

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == floor(v)
end

-- The rank of talent i, or 0 for one that is missing or not a sound rank (the reads never fail on a bad build).
local function rankAt(tree, ranks, i)
  local r = type(ranks) == "table" and ranks[i]
  if whole(r, 0, tree.talents[i].max) then return r end
  return 0
end

local function listHas(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

local function clauseMeets(clause, row)
  if clause.kind and not listHas(clause.kind, row.kind) then return false end
  if clause.danger and not listHas(clause.danger, row.danger) then return false end
  local hours = type(row.hours) == "number" and row.hours
  if clause.maxHours and not (hours and hours <= clause.maxHours) then return false end
  if clause.minHours and not (hours and hours >= clause.minHours) then return false end
  return true
end

-- No condition: always. A condition and no row: never.
local function meets(talent, row)
  if not talent.when then return true end
  if type(row) ~= "table" then return false end
  for _, clause in ipairs(talent.when) do
    if clauseMeets(clause, row) then return true end
  end
  return false
end

function TC.Points(level)
  if not whole(level, 1, math.huge) then return 0 end
  return 2 * (level - 1)
end

function TC.TierNeed(tier)
  return TIER_STEP * (tier - 1)
end

function TC.Above(tree, ranks, tier)
  local n = 0
  for i, t in ipairs(tree.talents) do
    if t.tier < tier then n = n + rankAt(tree, ranks, i) end
  end
  return n
end

function TC.Index(tree, id)
  for i, t in ipairs(tree.talents) do
    if t.id == id then return i end
  end
  return nil
end

function TC.RanksOf(tree, byId)
  local out = {}
  for i = 1, #tree.talents do out[i] = 0 end
  for id, r in pairs(byId or {}) do
    local i = TC.Index(tree, id)
    if not i then return nil end
    out[i] = r
  end
  return out
end

function TC.Spent(tree, ranks)
  local n = 0
  for i = 1, #tree.talents do n = n + rankAt(tree, ranks, i) end
  return n
end

function TC.Problem(tree, ranks, level)
  local talents = tree.talents
  if type(ranks) ~= "table" then return "rank" end
  for k, r in pairs(ranks) do
    if not whole(k, 1, #talents) or not whole(r, 0, talents[k].max) then return "rank" end
  end

  local byTier = {}
  for i, t in ipairs(talents) do byTier[t.tier] = (byTier[t.tier] or 0) + rankAt(tree, ranks, i) end
  for i, t in ipairs(talents) do
    if rankAt(tree, ranks, i) > 0 then
      local above = 0
      for tier = 1, t.tier - 1 do above = above + (byTier[tier] or 0) end
      if above < TC.TierNeed(t.tier) then return "tier" end
    end
  end

  for i, t in ipairs(talents) do
    if t.needs and rankAt(tree, ranks, i) > 0 then
      local j = TC.Index(tree, t.needs)
      if not j or rankAt(tree, ranks, j) < talents[j].max then return "arrow" end
    end
  end

  if level ~= nil and TC.Spent(tree, ranks) > TC.Points(level) then return "points" end
  return nil
end

local function moved(tree, ranks, i, by)
  local out = {}
  for k = 1, #tree.talents do out[k] = rankAt(tree, ranks, k) end
  out[i] = out[i] + by
  return out
end

function TC.CanAdd(tree, ranks, i, level)
  if not whole(i, 1, #tree.talents) then return nil, "rank" end
  local why = TC.Problem(tree, moved(tree, ranks, i, 1), level)
  if why then return nil, why end
  return true
end

function TC.CanTake(tree, ranks, i)
  if not whole(i, 1, #tree.talents) or rankAt(tree, ranks, i) == 0 then return nil, "rank" end
  local why = TC.Problem(tree, moved(tree, ranks, i, -1), nil)
  if why then return nil, why end
  return true
end

function TC.Power(tree, ranks, row)
  local n = 0
  for i, t in ipairs(tree.talents) do
    local r = rankAt(tree, ranks, i)
    if r > 0 and t.fx.power and meets(t, row) then n = n + t.fx.power * r end
  end
  return n
end

function TC.Mods(tree, ranks, row)
  local list = {}
  for i, t in ipairs(tree.talents) do
    local r = rankAt(tree, ranks, i)
    if r > 0 and meets(t, row) then
      local mod, any = {}, false
      for field, out in pairs(PCT) do
        if t.fx[field] then mod[out], any = 100 - t.fx[field] * r, true end
      end
      for _, field in ipairs(SUMMED) do
        if t.fx[field] then mod[field], any = t.fx[field] * r, true end
      end
      if t.fx.noPerma then mod.noPerma, any = true, true end
      if any then list[#list + 1] = mod end
    end
  end
  return list
end

function TC.Percent(tree, ranks, lever)
  if not LEVERS[lever] then return 0 end
  local n = 0
  for i, t in ipairs(tree.talents) do
    local r = rankAt(tree, ranks, i)
    if r > 0 and t.fx[lever] and not t.when then n = n + t.fx[lever] * r end
  end
  return n
end

function TC.Find(tree, ranks, reward)
  local n = 0
  for i, t in ipairs(tree.talents) do
    local r = rankAt(tree, ranks, i)
    local pct = t.fx.find and t.fx.find[reward]
    if r > 0 and pct and meets(t, nil) then n = n + pct * r end
  end
  return n
end
