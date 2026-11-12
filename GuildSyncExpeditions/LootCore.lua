-- GuildSyncExpeditions LootCore.lua: ns.LootCore, the pure loot rules of slice D (0.19 plan, Seams 7, 8).
-- Pure: string, table and math only, no globals, no game calls, no random. LootData.lua loads after this file, so
-- ns.LootData is read at call time. A stream is RiskCore's: a function answering [0, 1).
--   LC.Rate(reward, danger, capstone, traitPct, hours) -> per mille; 0 for an unknown reward, danger or length
--   LC.Drops(p, stream) -> n                           LC.PickSlot(keys, held, stream) -> key
--   LC.IsSetBlue(stream) -> bool                       LC.PctFor(reward, traits) -> 100 | 125 | 150
--   LC.Tier(level) -> 1 | 2                            LC.XP(hours, danger, band, level, rowLevel) -> n
--   LC.Grain(hours, danger, greedy) -> n               LC.Salvage(hours, band) -> n
--   LC.PickSupply(danger, stream) -> id                LC.RecruitSpec(stream, rowLevel) -> spec

local _, ns = ...
if not ns.M then return end

local LC = {}
ns.LootCore = LC

local floor = math.floor

local CAPSTONE_COLUMN = 5
local T1_TOP_LEVEL = 5
local SET_BLUE_PCT = 40
local GREEDY_PCT = 125
local WEIGHT_EMPTY, WEIGHT_HELD = 3, 2
local OVER_LEVEL = 3 -- more levels than this above the row halves the XP
local TRAIT_PCT = { blue = { lucky = 125 }, relic = { keen = 150 } }
local WIN = { succ = true, succw = true }
local FAIL = { fail = true, failw = true }

-- A whole table entry, by the danger factor over 4; 0 for an unknown row.
local function byRow(column, hours, danger)
  local base, factor = column[hours], ns.LootData.FACTOR[danger]
  if not base or not factor then return 0 end
  return floor(base * factor / 4)
end

-- A win keeps it all, a failure half, anything else nothing.
local function share(full, band)
  if WIN[band] then return full end
  if FAIL[band] then return floor(full / 2) end
  return 0
end

local function pick(list, stream)
  return list[floor(stream() * #list) + 1]
end

-- One draw over the list; a weight of 0 is never picked.
local function weighted(list, weightOf, stream)
  local total = 0
  for _, v in ipairs(list) do total = total + weightOf(v) end
  local d, sum = floor(stream() * total), 0
  for _, v in ipairs(list) do
    sum = sum + weightOf(v)
    if d < sum then return v end
  end
end

function LC.Rate(reward, danger, capstone, traitPct, hours)
  local LD = ns.LootData
  local row, length = LD.REWARDS[reward], LD.LENGTH[hours]
  if not row or not length or not LD.FACTOR[danger] then return 0 end
  local base = row[capstone and CAPSTONE_COLUMN or danger]
  return floor(floor(base * traitPct / 100) * length / 100)
end

function LC.Drops(p, stream)
  local extra = stream() * 1000 < p % 1000 and 1 or 0
  return floor(p / 1000) + extra
end

function LC.PickSlot(keys, held, stream)
  return weighted(keys, function(key) return held[key] and WEIGHT_HELD or WEIGHT_EMPTY end, stream)
end

function LC.IsSetBlue(stream)
  return stream() * 100 < SET_BLUE_PCT
end

function LC.PctFor(reward, traits)
  local pcts = TRAIT_PCT[reward]
  if pcts then
    for _, id in ipairs(traits or {}) do
      if pcts[id] then return pcts[id] end
    end
  end
  return 100
end

function LC.Tier(level)
  return level <= T1_TOP_LEVEL and 1 or 2
end

function LC.XP(hours, danger, band, level, rowLevel)
  local xp = share(byRow(ns.LootData.XP, hours, danger), band)
  if level > rowLevel + OVER_LEVEL then return floor(xp / 2) end
  return xp
end

-- The success grain; the win check is the caller's.
function LC.Grain(hours, danger, greedy)
  local grain = byRow(ns.LootData.GRAIN, hours, danger)
  if greedy then return floor(grain * GREEDY_PCT / 100) end
  return grain
end

function LC.Salvage(hours, band)
  return share(ns.LootData.SALVAGE[hours] or 0, band)
end

function LC.PickSupply(danger, stream)
  local function weightOf(row) return danger >= row.from and row.weight or 0 end
  return weighted(ns.LootData.SUPPLIES, weightOf, stream).id
end

-- Five draws, in this order: race, class, sex, name, trait.
function LC.RecruitSpec(stream, rowLevel)
  local LD, D = ns.LootData, ns.FollowerData
  local race = pick(LD.RECRUIT_RACES, stream)
  local class = pick(D.RACES[race], stream)
  local sex = pick(LD.RECRUIT_SEXES, stream)
  local name = pick(LD.NAMES[race], stream)
  local trait = pick(LD.RECRUIT_TRAITS, stream)
  return {
    name = name, race = race, class = class, sex = sex,
    level = math.max(1, math.min(D.MAX_LEVEL, rowLevel - 2)),
    traits = { trait }, origin = "recruit",
  }
end
