-- GuildSyncExpeditions Supplies.lua: what a follower packs for an expedition (0.19 plan, Seams 5, 6, 8, 9).
--   ns.SupplyMods(ids, row) -> mods                    ns.SupplyChoices(fid) -> { { id, n, packed, name }, ... }
--   ns.PackSupply(fid, id), ns.GrantSupply(id, n), ns.BuySupply(id) (third value true when ns.Grain has already said the line)
--   ns.CheckPack(fid) -> { droppedId, ... }            ns.ClearPack(fid)
-- A pack only reserves: several followers may pack the last of a stack, and the send that comes first gets it.
-- Grain moves only through ns.Grain.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local GC, FC = ns.GearCore, ns.FollowerCore

local CELLS = 64
local PACK_MAX = 2

local SUPPLIES = {
  { id = "rations", name = "Field Rations", mods = function() return { success = 5 } end },
  { id = "bandage", name = "Linen Bandage", mods = function() return { woundPct = 50 } end },
  { id = "whetstone", name = "Whetstone Kit", mods = function() return { gearPct = 50 } end },
  { id = "candle", name = "Spirit Candle", mods = function() return { deathPct = 50 } end },
  { id = "scoutchart", name = "Scout's Chart", mods = function(row)
    if row and row.kind == "Scout" then return { success = 10 } end
    return {}
  end },
  { id = "gravemoss", name = "Grave-moss Charm", mods = function() return { noPerma = true } end },
}

local BY_ID = {}
for _, s in ipairs(SUPPLIES) do BY_ID[s.id] = s end

local function holds(list, id)
  for _, v in ipairs(list) do
    if v == id then return true end
  end
  return false
end

-- A new list of the known ids, once each, at most two; nil when the follower is gone or none is left.
local function soundPack(fid, row)
  if type(fid) ~= "number" or fid < 1 or fid > FC.ID_MAX or fid ~= math.floor(fid) then return nil end
  if not ns.Follower(fid) then return nil end
  local out = {}
  for _, id in ipairs(row) do
    if BY_ID[id] and not holds(out, id) and #out < PACK_MAX then out[#out + 1] = id end
  end
  if #out == 0 then return nil end
  return out
end

local function fresh() return { rows = {} } end

-- At use, never at file load: saved variables are not ready then.
local function packed() return ns.Part("packed", fresh, soundPack) end

function ns.SupplyMods(ids, row)
  local out = {}
  if type(ids) ~= "table" then return out end
  for _, id in ipairs(ids) do
    local supply = BY_ID[id]
    if supply then
      for field, value in pairs(supply.mods(row)) do
        out[field] = field == "success" and (out.success or 0) + value or value
      end
    end
  end
  return out
end

function ns.SupplyChoices(fid)
  local pack = packed().rows[fid] or {}
  local out = {}
  for _, s in ipairs(SUPPLIES) do
    local n = ns.StackCount("supply", s.id)
    if n >= 1 then out[#out + 1] = { id = s.id, n = n, packed = holds(pack, s.id), name = s.name } end
  end
  return out
end

function ns.PackSupply(fid, id)
  if ns.Inert() then return nil, "demo" end
  if not ns.Follower(fid) then return nil, "unknown" end
  if not BY_ID[id] or ns.StackCount("supply", id) < 1 then return nil, "none" end
  local rows = packed().rows
  local pack = rows[fid] or {}
  if holds(pack, id) then return nil, "same" end
  if #pack >= PACK_MAX then return nil, "two" end
  pack[#pack + 1] = id
  rows[fid] = pack
  return true
end

-- Runs inside ns.Send with no M.Safe around it, so no fid may make it throw.
function ns.CheckPack(fid)
  if M.Demo() then return {} end
  local rows = packed().rows
  local pack = rows[fid]
  if not pack then return {} end
  local kept, dropped = {}, {}
  for _, id in ipairs(pack) do
    local list = ns.StackCount("supply", id) < 1 and dropped or kept
    list[#list + 1] = id
  end
  if #dropped == 0 then return dropped end
  rows[fid] = #kept > 0 and kept or nil
  for _, id in ipairs(dropped) do
    ns.Say("No " .. BY_ID[id].name .. " left in " .. ns.W.Name["Company bag"] .. ".")
  end
  return dropped
end

function ns.ClearPack(fid)
  if M.Demo() then return end
  local rows = packed().rows
  if rows[fid] then rows[fid] = nil end
end

function ns.GrantSupply(id, n)
  if not BY_ID[id] then return nil, "none" end
  return ns.AddStack("supply", id, n)
end

local function shopRow(id)
  for _, s in ipairs(GC.SHOP_SUPPLIES) do
    if s.id == id then return s end
  end
  return nil
end

-- Room for one more, from the bag as it stands: a stack with space, or a free cell and an id for a new stack.
local function hasRoom(id)
  local bag = ns.Bag()
  for _, r in pairs(bag) do
    if r.kind == "supply" and r.key == id and r.n < GC.STACK_MAX.supply then return true end
  end
  for cell = 1, CELLS do
    if not bag[cell] then return ns.Gear(FC.ID_MAX) == nil end
  end
  return false
end

-- Every check comes before the spend, so grain is never taken for nothing.
function ns.BuySupply(id)
  if ns.Inert() then return nil, "demo" end
  local row = shopRow(id)
  if not row then return nil, "unknown" end
  if not hasRoom(id) then return nil, "full" end
  local have, why = M.Purse()
  if not have then return nil, why end
  if have < row.price then return nil, "short" end
  local paid, refused = ns.Grain("spend", row.price)
  if not paid then return nil, refused, true end
  ns.AddStack("supply", id, 1)
  return true
end
