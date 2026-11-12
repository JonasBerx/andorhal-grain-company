-- GuildSyncExpeditions Book.lua: relics, region sets and held chain pieces (0.19 plan, Seams 8).
--   ns.GrantRelic(region, seed) -> id | id, "full" | nil, why     ns.BreakRelic(id, n) -> true | nil, why
--   ns.GrantSetPiece(region, seed) -> item id | nil, why          ns.GrantChainEpic(region) -> item id | "held" | nil, why
--   ns.HoldNamed(piece) -> true | nil                             ns.TakeHeld() -> count moved
--   ns.SetBonus(fid) -> n     ns.SetMods(fid, row) -> table       ns.SetOwned(region) -> n
--   ns.Collection() -> { relics, sets, chains, badges }           ns.HeldEpics() -> { { row, region, temper }, ... }
-- Other files' ns fields are read at call time. Grain never moves here.

local _, ns = ...
if not ns.M then return end

local FC = ns.FollowerCore

local TEMPER_MAX = 5
local SALVAGE_PER_RELIC = 4
local LEAN_OPEN, LEAN_HELD = 3, 2
local BONUS_HALF, BONUS_FULL = 6, 15
local PIECES_HALF, PIECES_FULL = 3, 6
local FULL_SET_DEATH_PCT = 75

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function fresh() return { rows = {} } end

local function soundRelic(id)
  if type(id) ~= "string" or #id > FC.TEXT_MAX or not string.match(id, "^[%w_]+$") then return nil end
  return { found = true }
end

-- Clamped, not reset as a bag row's is: a piece held for a full bag keeps what it can of its temper.
local function soundTemper(v)
  if type(v) ~= "number" or v ~= math.floor(v) then return 0 end
  return math.max(0, math.min(TEMPER_MAX, v))
end

-- A well-formed unknown code stays: it may be a row a later version knows.
local function soundChain(id, row)
  local GD = ns.GearData
  if not whole(id, 1, FC.ID_MAX) or not GD.WellFormed(row.row) then return nil end
  local known = GD.Row(row.row)
  if known and not known.named then return nil end
  return { row = row.row, temper = soundTemper(row.temper) }
end

local function relics() return ns.Part("relics", fresh, soundRelic) end
local function chains() return ns.Part("chains", fresh, soundChain) end

local function relicsIn(region)
  local out = {}
  for _, r in ipairs(ns.BookData.relics) do
    if r.region == region then out[#out + 1] = r end
  end
  return out
end

local function relicById(id)
  for _, r in ipairs(ns.BookData.relics) do
    if r.id == id then return r end
  end
  return nil
end

local function setOf(region)
  for _, s in ipairs(ns.BookData.sets) do
    if s.region == region then return s end
  end
  return nil
end

local function namedRow(region)
  for _, r in ipairs(ns.GearData.ROWS) do
    if r.named ~= nil and r.named == region then return r end
  end
  return nil
end

-- nil for a bad seed.
local function firstDraw(seed)
  local stream = ns.RiskCore.Stream(seed)
  return stream and stream()
end

local function wornBy(f)
  local out = {}
  for _, s in ipairs(ns.GearData.SLOTS) do
    local piece = f.gear[s.key] and ns.Gear(f.gear[s.key])
    if piece and piece.row and piece.cell == nil then out[#out + 1] = piece end
  end
  return out
end

-- Everything the account owns: the bag's pieces, stacks left out, and what followers wear.
local function ownedPieces()
  local out = {}
  for _, r in pairs(ns.Bag()) do
    if r.row then out[#out + 1] = r end
  end
  for _, f in ipairs(ns.Followers()) do
    for _, piece in ipairs(wornBy(f)) do out[#out + 1] = piece end
  end
  return out
end

local function distinctOf(set, pieces)
  local seen, n = {}, 0
  for _, piece in ipairs(pieces) do
    local row = ns.GearData.Row(piece.row)
    if row and row.set == set.name and not seen[piece.row] then
      seen[piece.row] = true
      n = n + 1
    end
  end
  return n
end

local function wornSetCounts(f)
  local counts = {}
  for _, piece in ipairs(wornBy(f)) do
    local row = ns.GearData.Row(piece.row)
    if row and row.set and not piece.broken then counts[row.set] = (counts[row.set] or 0) + 1 end
  end
  return counts
end

local function sortedIds(rows)
  local ids = {}
  for id in pairs(rows) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

function ns.GrantRelic(region, seed)
  if ns.Inert() then return nil, "demo" end
  local list = relicsIn(region)
  if #list == 0 then return nil, "unknown" end
  local r = firstDraw(seed)
  local relic = list[r and math.floor(r * #list) + 1 or 1]
  relics().rows[relic.id] = { found = true }
  local added, why = ns.AddStack("relic", relic.id, 1)
  if added then return relic.id end
  ns.Say(ns.W.Name["Company bag"] .. " is full: " .. relic.name .. " is lost.")
  return relic.id, why
end

-- Every refusal comes before the salvage add, and the stack goes last so its emptied cell lets a held piece land.
function ns.BreakRelic(id, n)
  if ns.Inert() then return nil, "demo" end
  local relic = relicById(id)
  if not relic then return nil, "unknown" end
  if not whole(n, 1, math.huge) or n == math.huge then return nil, "amount" end
  if ns.StackCount("relic", id) < n then return nil, "short" end
  local added, why = ns.AddStack("salvage", relic.tier, SALVAGE_PER_RELIC * n)
  if not added then return nil, why end
  ns.TakeStack("relic", id, n)
  return true
end

-- One draw over the set's pieces; a slot the account already has a blue T2 piece for weighs less.
local function leanPick(set, r)
  local GD = ns.GearData
  local held = {}
  for _, piece in ipairs(ownedPieces()) do
    local row = GD.Row(piece.row)
    if row and row.tier == 2 and row.q == 3 then held[row.slot] = true end
  end
  local weights, total = {}, 0
  for i, code in ipairs(set.pieces) do
    weights[i] = held[GD.Row(code).slot] and LEAN_HELD or LEAN_OPEN
    total = total + weights[i]
  end
  local d, cum = math.floor(r * total) + 1, 0
  for i, w in ipairs(weights) do
    cum = cum + w
    if d <= cum then return set.pieces[i] end
  end
end

function ns.GrantSetPiece(region, seed)
  if ns.Inert() then return nil, "demo" end
  local set = setOf(region)
  if not set then return nil, "unknown" end
  local r = firstDraw(seed)
  return ns.AddGear({ row = r and leanPick(set, r) or set.pieces[1], temper = 0 })
end

function ns.GrantChainEpic(region)
  if ns.Inert() then return nil, "demo" end
  local row = namedRow(region)
  if not row then return nil, "unknown" end
  local piece = { row = row.code, temper = 0 }
  local id, why = ns.AddGear(piece)
  if id then return id end
  if why == "full" and ns.HoldNamed(piece) then return "held" end
  return nil, why
end

function ns.HoldNamed(piece)
  if type(piece) ~= "table" then return nil end
  local row = ns.GearData.Row(piece.row)
  if not row or not row.named then return nil end
  local rows = chains().rows
  local id = 1
  while rows[id] do id = id + 1 end
  if id > FC.ID_MAX then return nil end
  rows[id] = { row = piece.row, temper = soundTemper(piece.temper) }
  return true
end

-- Quiet: it runs after a sale or a freed stack, which have their own lines. A code this version does not know waits.
function ns.TakeHeld()
  local rows = chains().rows
  local moved = 0
  for _, id in ipairs(sortedIds(rows)) do
    local held = rows[id]
    if ns.GearData.Row(held.row) then
      if not ns.AddGear({ row = held.row, temper = held.temper }) then break end
      rows[id] = nil
      moved = moved + 1
    end
  end
  return moved
end

function ns.SetBonus(fid)
  local f = ns.Follower(fid)
  if not f then return 0 end
  local bonus = 0
  for _, n in pairs(wornSetCounts(f)) do
    if n >= PIECES_FULL then
      bonus = bonus + BONUS_FULL
    elseif n >= PIECES_HALF then
      bonus = bonus + BONUS_HALF
    end
  end
  return bonus
end

function ns.SetMods(fid, row)
  local set = type(row) == "table" and setOf(row.region)
  local f = set and ns.Follower(fid)
  if f and wornSetCounts(f)[set.name] == PIECES_FULL then return { deathPct = FULL_SET_DEATH_PCT } end
  return {}
end

function ns.SetOwned(region)
  local set = setOf(region)
  if not set then return 0 end
  return distinctOf(set, ownedPieces())
end

function ns.Collection()
  local rows = relics().rows
  local found, have, total = {}, {}, {}
  for _, r in ipairs(ns.BookData.relics) do
    total[r.region] = (total[r.region] or 0) + 1
    if rows[r.id] then
      found[#found + 1] = r.id
      have[r.region] = (have[r.region] or 0) + 1
    end
  end
  local pieces = ownedPieces()
  local sets, badges = {}, {}
  for _, set in ipairs(ns.BookData.sets) do
    if distinctOf(set, pieces) == #set.pieces then sets[#sets + 1] = set.region end
  end
  local seen = {}
  for _, r in ipairs(ns.BookData.relics) do
    if not seen[r.region] and have[r.region] == total[r.region] then
      seen[r.region] = true
      badges[#badges + 1] = r.region
    end
  end
  return { relics = found, sets = sets, chains = ns.ChaptersDone and ns.ChaptersDone() or {}, badges = badges }
end

function ns.HeldEpics()
  local rows = chains().rows
  local out = {}
  for _, id in ipairs(sortedIds(rows)) do
    local row = ns.GearData.Row(rows[id].row)
    if row and row.named then
      out[#out + 1] = { row = rows[id].row, region = row.named, temper = rows[id].temper }
    end
  end
  return out
end
