-- GuildSyncExpeditions FollowerCore.lua: ns.FollowerCore, the pure follower rules (0.19 plan, Seams 3).
-- Pure: string, table and math only, no globals, no game calls. Loads after Data.lua.
--   FC.ValidName(name) -> bool                         2-12 ASCII letters, the same on every client
--   FC.CheckSpec(name, race, class, sex) -> true | nil, "name" | "race" | "class" | "pair" | "sex"
--   FC.Price(held) -> n | nil                          FC.Held(rows) -> n, every row counts
--   FC.NextId(part) -> id | nil                        above the highest row id; nil at the ceiling
--   FC.NewRow(id, spec) -> row | nil                   FC.SoundRow(id, row) -> a new checked row | nil
--   FC.ToNext(level) -> n | nil                        FC.GainXP(level, xp, n) -> level, xp
--   FC.Affinity(class, row) -> n                       FC.Power(level, kit, set, trait, affinity) -> n
--   FC.SpecPower(spec, row) -> n                       FC.RaceModsOf(race) -> a fresh table
--   FC.RollHire(stream, names, taken) -> three rows | nil   names is LootData.NAMES, taken a set of lower-cased names
--   FC.HireSound(rows, taken) -> bool

local _, ns = ...
if not ns.M then return end

local D = ns.FollowerData
local FC = {}
ns.FollowerCore = FC

FC.ID_MAX = 1000000
FC.STAT_MAX = 1000000
FC.TIME_MAX = 2147483647
FC.GEAR_MAX = 2147483647
FC.TEXT_MAX = 32

local NAME_MIN, NAME_MAX = 2, 12
local TRAITS_KEPT = 3
local STATES = { idle = true, out = true, rest = true, dead = true }
local ORIGINS = { hire = true, recruit = true }
local STATS = { "runs", "wins", "deadly", "wounds", "raised" }
local HIRE_KINDS = { "Might", "Cunning", "Lore" }

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function text(v)
  return type(v) == "string" and #v >= 1 and #v <= FC.TEXT_MAX
end

local function raceHas(race, class)
  local classes = D.RACES[race]
  if not classes then return false end
  for _, c in ipairs(classes) do
    if c == class then return true end
  end
  return false
end

function FC.ValidName(name)
  return type(name) == "string" and #name >= NAME_MIN and #name <= NAME_MAX and string.match(name, "^[A-Za-z]+$") ~= nil
end

function FC.CheckSpec(name, race, class, sex)
  if not FC.ValidName(name) then return nil, "name" end
  if not D.RACES[race] then return nil, "race" end
  if not D.KIND[class] then return nil, "class" end
  if not raceHas(race, class) then return nil, "pair" end
  if not D.BODIES[sex] then return nil, "sex" end
  return true
end

function FC.Price(held)
  if type(held) ~= "number" then return nil end
  return D.PRICES[held + 1]
end

function FC.Held(rows)
  local n = 0
  for _ in pairs(rows) do n = n + 1 end
  return n
end

function FC.NextId(part)
  local top = 0
  for id in pairs(part.rows) do
    if type(id) == "number" and id > top then top = id end
  end
  if whole(part.next, top + 1, FC.ID_MAX) then return part.next end
  if top >= FC.ID_MAX then return nil end
  return top + 1
end

function FC.ToNext(level)
  if not whole(level, 1, D.MAX_LEVEL - 1) then return nil end
  return D.XP_BASE + D.XP_STEP * level
end

function FC.GainXP(level, xp, n)
  if not finite(n) or n < 0 or n ~= math.floor(n) then return level, xp end
  xp = xp + n
  local need = FC.ToNext(level)
  while need and xp >= need do
    xp = xp - need
    level = level + 1
    need = FC.ToNext(level)
  end
  if not need then xp = 0 end -- the surplus at the top is dropped
  return level, xp
end

function FC.Affinity(class, row)
  local kind = D.KIND[class]
  if kind and type(row) == "table" and D.ROW_KIND[kind] == row.kind then return D.AFFINITY end
  return 0
end

local function part0(v)
  return finite(v) and v or 0
end

function FC.Power(level, kit, set, trait, affinity)
  return D.LEVEL_POWER * part0(level) + part0(kit) + part0(set) + part0(trait) + part0(affinity)
end

function FC.SpecPower(spec, row)
  if type(spec) ~= "table" then return 0 end
  local trait = 0
  if type(spec.traits) == "table" then
    for _, id in ipairs(spec.traits) do
      local t = D.TRAIT_POWER[id]
      if t and (not t.rowKind or (type(row) == "table" and row.kind == t.rowKind)) then trait = trait + t.power end
    end
  end
  return FC.Power(spec.level or 1, 0, 0, trait, FC.Affinity(spec.class, row))
end

function FC.RaceModsOf(race)
  local out = {}
  for k, v in pairs(D.PERKS[race] or {}) do out[k] = v end
  return out
end

local function soundStats(stats)
  local out = {}
  for _, k in ipairs(STATS) do
    local v = type(stats) == "table" and stats[k]
    out[k] = whole(v, 0, FC.STAT_MAX) and v or 0
  end
  return out
end

local function soundTraits(traits)
  local out = {}
  if type(traits) == "table" then
    for _, v in ipairs(traits) do
      if text(v) then out[#out + 1] = v end
      if #out == TRAITS_KEPT then break end
    end
  end
  return out
end

local function soundGear(gear)
  local out = {}
  if type(gear) == "table" then
    for k, v in pairs(gear) do
      if text(k) and whole(v, 1, FC.GEAR_MAX) then out[k] = v end
    end
  end
  return out
end

local function soundLook(v)
  if (type(v) == "string" and #v <= FC.TEXT_MAX) or whole(v, 0, FC.ID_MAX) then return v end
  return nil
end

-- A new table of the known fields only, so no unknown number can escape a ceiling.
function FC.SoundRow(id, row)
  if type(row) ~= "table" or not whole(id, 1, FC.ID_MAX) or not raceHas(row.race, row.class) then return nil end
  local level = whole(row.level, 1, D.MAX_LEVEL) and row.level or 1
  local toNext = FC.ToNext(level)
  return {
    id = id,
    name = FC.ValidName(row.name) and row.name or row.class,
    race = row.race,
    class = row.class,
    sex = D.BODIES[row.sex] and row.sex or "m",
    level = level,
    xp = toNext and whole(row.xp, 0, toNext - 1) and row.xp or 0,
    traits = soundTraits(row.traits),
    look = soundLook(row.look),
    state = STATES[row.state] and row.state or "idle",
    untilT = whole(row.untilT, 0, FC.TIME_MAX) and row.untilT or nil,
    origin = ORIGINS[row.origin] and row.origin or "hire",
    renamed = row.renamed == true,
    reserve = row.reserve == true,
    stats = soundStats(row.stats),
    gear = soundGear(row.gear),
  }
end

-- nil on a bad spec. A spec with no origin is a recruit (Seams spec).
function FC.NewRow(id, spec)
  if type(spec) ~= "table" or not FC.CheckSpec(spec.name, spec.race, spec.class, spec.sex) then return nil end
  return FC.SoundRow(id, {
    name = spec.name, race = spec.race, class = spec.class, sex = spec.sex, level = spec.level, xp = spec.xp,
    traits = spec.traits, look = spec.look, origin = spec.origin or "recruit", reserve = spec.reserve,
  })
end

local function sortedKeys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function draw(list, stream)
  return list[math.floor(stream() * #list) + 1]
end

local function freeNames(list, taken, used)
  local out = {}
  for _, name in ipairs(list) do
    local low = string.lower(name)
    if not taken[low] and not used[low] then out[#out + 1] = name end
  end
  return out
end

-- The races of the class that still have a free name, in sorted order.
local function openRaces(class, races, free)
  local out = {}
  for _, race in ipairs(races) do
    if #free[race] > 0 and raceHas(race, class) then out[#out + 1] = race end
  end
  return out
end

-- Might, Cunning, Lore in that order. Each column draws class, race, sex, name, so a stream gives one answer.
function FC.RollHire(stream, names, taken)
  local races, bodies, classes = sortedKeys(names), sortedKeys(D.BODIES), sortedKeys(D.KIND)
  local used, out = {}, {}
  for i, kind in ipairs(HIRE_KINDS) do
    local free = {}
    for _, race in ipairs(races) do free[race] = freeNames(names[race], taken, used) end
    local open = {}
    for _, class in ipairs(classes) do
      if D.KIND[class] == kind and #openRaces(class, races, free) > 0 then open[#open + 1] = class end
    end
    if #open == 0 then return nil end
    local class = draw(open, stream)
    local race = draw(openRaces(class, races, free), stream)
    local sex = draw(bodies, stream)
    local name = draw(free[race], stream)
    out[i] = { name = name, race = race, class = class, sex = sex }
    used[string.lower(name)] = true
  end
  return out
end

function FC.HireSound(rows, taken)
  if type(rows) ~= "table" then return false end
  local seen = {}
  for i, kind in ipairs(HIRE_KINDS) do
    local r = rows[i]
    if type(r) ~= "table" or not FC.CheckSpec(r.name, r.race, r.class, r.sex) or D.KIND[r.class] ~= kind then return false end
    local low = string.lower(r.name)
    if seen[low] or taken[low] then return false end
    seen[low] = true
  end
  return true
end
