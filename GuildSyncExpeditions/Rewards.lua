-- GuildSyncExpeditions Rewards.lua: what a settled run pays out (0.19 plan, Seams 7, 8).
--   ns.ApplyRewards(fid, run, outcome) -> blue   whether a Rare landed (story gear never counts); nil in demo; band perma never reaches it
--   ns.Finds() -> { { row, fid, day, region }, ... }   the newest 5 blue finds, newest first, copies; a read never writes
-- ns.LootCore, GearData, GearCore, AddGear, AddStack, Gear, Bag, TraitEvents and the later slices' GrantSupply, GrantMap,
-- GrantRelic, GrantSetPiece, GrantQuest, OfferRecruit, PendingRecruit and StoryRun are read at call time; the hooks are
-- skipped while they are missing.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local FC = ns.FollowerCore
local RC = ns.RiskCore

local SEED_RANGE = 2147483646
local FINDS_KEPT = 5
local WRIT_MIN_HOURS = 4
local WHITE, GREEN, BLUE = 1, 2, 3
local BLUE_TIER = 2
local WIN = { succ = true, succw = true }
local SALVAGE_NAME = { [1] = "Rusted salvage", [2] = "Iron salvage" }

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function fresh() return { next = 1, rows = {} } end

local function knownRegion(id)
  for _, info in ipairs(ns.Regions.LIST) do
    if info.id == id then return true end
  end
  return false
end

-- A new table of the known fields only, as FC.SoundRow.
local function soundFind(id, r)
  if not whole(id, 1, FC.ID_MAX) or not ns.GearData.WellFormed(r.row) then return nil end
  if not whole(r.fid, 1, FC.ID_MAX) or not whole(r.day, 0, FC.TIME_MAX) then return nil end
  if not knownRegion(r.region) then return nil end
  return { id = id, row = r.row, fid = r.fid, day = r.day, region = r.region }
end

-- At use, never at file load: saved variables are not ready then.
local function finds() return ns.Part("finds", fresh, soundFind) end

local function newestIds(rows)
  local ids = {}
  for id in pairs(rows) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return a > b end)
  return ids
end

local function addFind(code, fid, region)
  local p = finds()
  local id = FC.NextId(p)
  if not id then return end
  local day = ns.BoardCore.Day(ns.Now(), M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset")) or 0
  p.rows[id] = { id = id, row = code, fid = fid, day = day, region = region }
  p.next = id + 1
  local ids = newestIds(p.rows)
  for i = FINDS_KEPT + 1, #ids do p.rows[ids[i]] = nil end
end

function ns.Finds()
  local rows = finds().rows
  local out = {}
  for i, id in ipairs(newestIds(rows)) do
    if i > FINDS_KEPT then break end
    local r = rows[id]
    out[i] = { row = r.row, fid = r.fid, day = r.day, region = r.region }
  end
  return out
end

-- M.Safe keeps only the first answer, so both are stored inside. A missing hook or a throw answers nil and no reason.
local function safely(fn, ...)
  if not fn then return nil end
  local a, b
  M.Safe(function(...) a, b = fn(...) end, ...)
  return a, b
end

local function lost(name)
  ns.Say(ns.W.Name["Company bag"] .. " is full: " .. name .. " is lost.")
end

local function addSalvage(tier, n, name)
  local added, why = ns.AddStack("salvage", tier, n)
  if not added and why == "full" then lost(name) end
end

-- Every copy of a piece of this quality and tier, by its slot; called per drop, so a landed drop counts for the next.
local function heldPieces(q, tier)
  local GD = ns.GearData
  local held = {}
  local function mark(code)
    local row = GD.Row(code)
    if row and row.q == q and row.tier == tier then held[row.slot] = true end
  end
  for _, piece in pairs(ns.Bag()) do mark(piece.row) end
  for _, f in ipairs(ns.Followers()) do
    for _, id in pairs(f.gear) do
      local piece = ns.Gear(id)
      if piece then mark(piece.row) end
    end
  end
  return held
end

-- Answers the row's code when the piece landed.
local function dropPlain(q, tier, stream)
  local GD = ns.GearData
  local keys = {}
  for i, s in ipairs(GD.SLOTS) do keys[i] = s.key end
  local row = GD.Find(ns.LootCore.PickSlot(keys, heldPieces(q, tier), stream), tier, q)
  if not row then return nil end
  local id, why = ns.AddGear({ row = row.code })
  if id then return row.code end
  if why == "full" then addSalvage(row.tier, ns.GearCore.SalvageOf(row.q), row.name) end
  return nil
end

local function hookSeed(stream) return 1 + math.floor(stream() * SEED_RANGE) end

-- The set piece's seed is drawn whether or not the hook exists, so a missing hook moves no later drop.
local function dropSetPiece(region, stream)
  local id, why = safely(ns.GrantSetPiece, region, hookSeed(stream))
  local piece = type(id) == "number" and ns.Gear(id)
  if piece then return piece.row end
  if why == "full" then addSalvage(BLUE_TIER, ns.GearCore.SalvageOf(BLUE), "a set piece") end
  return nil
end

-- Calls each(stream) once per drop of this reward, on the reward's own stream.
local function eachDrop(reward, run, traits, each)
  local LC = ns.LootCore
  local stream = RC.Stream(RC.Seed(reward, run.start, run.seed))
  local n = LC.Drops(LC.Rate(reward, run.danger, run.capstone, LC.PctFor(reward, traits), run.hours), stream)
  for _ = 1, n do each(stream) end
end

-- ns.TraitEvents runs after all of this, so every rate reads the traits held at the start. Answers whether a blue landed.
local function payDrops(fid, run, traits)
  local LC = ns.LootCore
  local tier = LC.Tier(run.level)
  local blue = false
  eachDrop("white", run, traits, function(stream) dropPlain(WHITE, tier, stream) end)
  eachDrop("green", run, traits, function(stream) dropPlain(GREEN, tier, stream) end)
  eachDrop("blue", run, traits, function(stream)
    local code
    if LC.IsSetBlue(stream) then
      code = dropSetPiece(run.region, stream)
    else
      code = dropPlain(BLUE, BLUE_TIER, stream)
    end
    if code then
      addFind(code, fid, run.region)
      blue = true
      -- d2139: the find in words, for a player who cannot hear its sound
      local f, row = ns.Follower(fid), ns.GearData.Row(code)
      if f and row then ns.Say(ns.Escape(f.name) .. " found " .. row.name .. ".") end
    end
  end)
  eachDrop("recruit", run, traits, function(stream)
    local spec = LC.RecruitSpec(stream, run.level)
    if not safely(ns.PendingRecruit) then safely(ns.OfferRecruit, spec) end
  end)
  eachDrop("supply", run, traits, function(stream)
    local _, why = safely(ns.GrantSupply, LC.PickSupply(run.danger, stream), 1)
    if why == "full" then lost("a supply") end
  end)
  if ns.Regions.IsOpen(run.region) then
    eachDrop("map", run, traits, function() safely(ns.GrantMap, run.region, LC.Tier(run.level)) end)
  end
  eachDrop("relic", run, traits, function(stream) safely(ns.GrantRelic, run.region, hookSeed(stream)) end)
  if run.hours >= WRIT_MIN_HOURS then
    eachDrop("writ", run, traits, function(stream) safely(ns.GrantQuest, hookSeed(stream)) end)
  end
  return blue
end

local function holds(traits, id)
  for _, v in ipairs(traits) do
    if v == id then return true end
  end
  return false
end

-- LC.XP and LC.Salvage answer 0 for a death, so band dead reaches only ns.TraitEvents.
function ns.ApplyRewards(fid, run, outcome)
  if M.Demo() then return end
  local f = ns.Follower(fid)
  if not f then return end
  local LC = ns.LootCore
  local band = outcome.band
  local paid = { credited = false, blue = false }

  local xp = LC.XP(run.hours, run.danger, band, f.level, run.level)
  if xp > 0 then f.level, f.xp = FC.GainXP(f.level, f.xp, xp) end
  local salvage = LC.Salvage(run.hours, band)
  if salvage > 0 then
    local tier = LC.Tier(run.level)
    addSalvage(tier, salvage, ns.W.Name[SALVAGE_NAME[tier]])
  end

  if WIN[band] then
    paid.blue = payDrops(fid, run, f.traits)
    local grain = LC.Grain(run.hours, run.danger, holds(f.traits, "greedy"))
    if grain > 0 then paid.credited = ns.Grain("credit", grain) == true end
    if run.story or run.capstone then safely(ns.StoryRun, fid, run, outcome) end
  end
  ns.TraitEvents(fid, run, outcome, paid)
  return paid.blue
end
