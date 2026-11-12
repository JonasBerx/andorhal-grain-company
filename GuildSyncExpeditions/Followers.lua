-- GuildSyncExpeditions Followers.lua: the saved followers part, hire, add, dismiss and the reads (0.19 plan, Seams 3, 6).
--   ns.Followers() -> list                    copies, ordered by id
--   ns.Follower(fid) -> row | nil             the saved row
--   ns.HirePrice() -> n | nil                 nil at 3 held
--   ns.Hire(name, race, class, sex) -> id | nil, why
--   ns.HireOffer() -> three candidates | {}   copies, Might, Cunning, Lore; {} with no readable day or no free name
--   ns.AddFollower(spec) -> id | nil, why     no grain moves
--   ns.Dismiss(fid) -> true | nil, why
--   ns.RaceMods(fid) -> a fresh table         ns.PowerOf(fid, row) -> n
-- The later slices' ns.UnequipAll, ClearPack, TakeWaitingRecruit, IsReserve, KitScore, SetBonus and TraitBonus are read
-- at call time and skipped while they are missing.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local FC = ns.FollowerCore
local D = ns.FollowerData
local SEED_MAX = 2147483646

local function fresh() return { next = 1, rows = {} } end

-- At use, never at file load: saved variables are not ready then.
local function part() return ns.Part("followers", fresh, FC.SoundRow) end

local function freshOffer() return { day = 0, rows = {} } end

local function soundOfferRow(id, row)
  if (id ~= 1 and id ~= 2 and id ~= 3) or not FC.CheckSpec(row.name, row.race, row.class, row.sex) then return nil end
  return { name = row.name, race = row.race, class = row.class, sex = row.sex }
end

local function offerPart() return ns.Part("hireoffer", freshOffer, soundOfferRow) end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then out[k] = copy(v) else out[k] = v end
  end
  return out
end

function ns.Followers()
  local rows = part().rows
  local ids = {}
  for id in pairs(rows) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = {}
  for i, id in ipairs(ids) do out[i] = copy(rows[id]) end
  return out
end

function ns.Follower(fid)
  return part().rows[fid]
end

function ns.HirePrice()
  return FC.Price(FC.Held(part().rows))
end

function ns.RaceMods(fid)
  local row = part().rows[fid]
  return FC.RaceModsOf(row and row.race)
end

local function ask(name, ...)
  if ns[name] then return ns[name](...) end
  return nil
end

function ns.PowerOf(fid, row)
  local f = part().rows[fid]
  if not f then return 0 end
  return FC.Power(f.level, ask("KitScore", fid), ask("SetBonus", fid), ask("TraitBonus", fid, row), FC.Affinity(f.class, row))
end

-- Every check comes before the spend and only plain assignments after it, so grain is never taken for nothing.
function ns.Hire(name, race, class, sex)
  if ns.Inert() then return nil, "demo" end
  local good, why = FC.CheckSpec(name, race, class, sex)
  if not good then return nil, why end
  local p = part()
  if FC.Held(p.rows) >= D.CAP_BOUGHT then return nil, "full" end
  local price = ns.HirePrice()
  if not price then return nil, "full" end
  local id = FC.NextId(p)
  local row = id and FC.NewRow(id, { name = name, race = race, class = class, sex = sex, origin = "hire" })
  if not row then return nil, "full" end
  local offer = offerPart()
  local paid, refused = ns.Grain("spend", price)
  if not paid then return nil, refused end
  p.rows[id] = row
  p.next = id + 1
  offer.day = 0
  offer.rows = {}
  return id
end

local function heldNames()
  local taken = {}
  for _, row in pairs(part().rows) do taken[string.lower(row.name)] = true end
  return taken
end

local function candidates(rows)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = { name = row.name, race = row.race, class = row.class, sex = row.sex, level = 1, traits = {} }
  end
  return out
end

-- Rolls only on a new day, a bad part, or a saved name that is now held. Called from the open hire panel and its Hire
-- click, never from a fact read. The day comes before the first ns.Part, which stores the part.
function ns.HireOffer()
  local RC = ns.RiskCore
  if M.Demo() then
    return candidates(FC.RollHire(RC.Stream(RC.Seed("hire", 0, 1)), ns.LootData.NAMES, heldNames()) or {})
  end
  local day = ns.BoardCore.Day(ns.Now(), M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset"))
  if not day then return {} end
  local offer = offerPart()
  local taken = heldNames()
  if offer.day == day and FC.HireSound(offer.rows, taken) then return candidates(offer.rows) end
  local rows = FC.RollHire(RC.Stream(RC.Seed("hire", day, math.random(SEED_MAX))), ns.LootData.NAMES, taken)
  if not rows then return {} end
  offer.day = day
  offer.rows = rows
  return candidates(rows)
end

function ns.AddFollower(spec)
  if ns.Inert() then return nil, "demo" end
  if type(spec) ~= "table" then return nil, "spec" end
  local good, why = FC.CheckSpec(spec.name, spec.race, spec.class, spec.sex)
  if not good then return nil, why end
  local p = part()
  if FC.Held(p.rows) >= D.CAP_ALL then return nil, "full" end
  local id = FC.NextId(p)
  local row = id and FC.NewRow(id, spec)
  if not row then return nil, "full" end
  if spec.reserve == nil and row.origin == "recruit" then row.reserve = true end -- a recruit never joins in use by itself
  p.rows[id] = row
  p.next = id + 1
  return id
end

function ns.Dismiss(fid)
  if ns.Inert() then return nil, "demo" end
  local rows = part().rows
  local row = rows[fid]
  if not row then return nil, "unknown" end
  if row.state == "out" then return nil, "busy" end -- a run points at it
  local reserve = row.reserve == true
  if ns.IsReserve then reserve = ns.IsReserve(fid) end
  if ns.UnequipAll then
    local done, why = ns.UnequipAll(fid)
    if not done then return nil, why end
  end
  if ns.ClearPack then ns.ClearPack(fid) end
  rows[fid] = nil
  if reserve and ns.TakeWaitingRecruit then ns.TakeWaitingRecruit() end
  return true
end
