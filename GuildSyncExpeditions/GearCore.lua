-- GuildSyncExpeditions GearCore.lua: ns.GearCore, the pure gear numbers (0.19 plan, Seams 9).
-- Pure: string, table and math only, no globals, no game calls. Loads after GearData.lua.
--   GC.Value(piece) -> n                               GC.KitScore({ [slot] = piece }) -> n
--   GC.WearLevel(tier) -> 1 | 6 | nil                  GC.SalvageOf(q) -> 1 | 2 | nil
--   GC.SlotPrice(row) -> n | nil                       GC.TemperCost(weight, step, q) -> n
--   GC.RepairCost(row) -> salvage, grain | nil         GC.Sellable(row) -> n | nil
--   GC.OnSale(row, chaptersDone) -> boolean

local _, ns = ...
if not ns.M then return end

local GD = ns.GearData
local GC = {}
ns.GearCore = GC

GC.QUALITY_BASE = { [0] = 1, [1] = 2, [2] = 4, [3] = 6 }
GC.QUALITY_COLOUR = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd" }
GC.STACK_MAX = { salvage = 99, supply = 20, relic = 20 }
GC.SHOP_SUPPLIES = {
  { id = "rations", name = "Field Rations", price = 15, icon = "Interface\\Icons\\INV_Misc_Food_59", note = "+5% success" },
  { id = "bandage", name = "Linen Bandage", price = 10, icon = "Interface\\Icons\\INV_Misc_Bandage_12", note = "Halves wounds" },
}

local WEAR_LEVEL = { 1, 6 }
local KIT_PRICE = { { [0] = 45, [1] = 120 }, { [0] = 90, [1] = 270 } } -- by tier, then quality
local KIT_WEIGHT = 300
local TEMPER_STEP = { 1, 2, 3, 5, 8 }
local BLUE = 3
local SALVAGE = { [0] = 1, [1] = 1, [2] = 1, [3] = 2 }
local REPAIR_PERCENT = 40
local SELL_DIVISOR = 4
local START_STOCK = { mainhand = true, offhand = true, chest = true, legs = true, feet = true } -- grey, first tier

local WEIGHT = {}
GC.WEIGHT = WEIGHT
GC.KIND = {}
for _, s in ipairs(GD.SLOTS) do
  WEIGHT[s.key] = s.weight
  GC.KIND[s.key] = s.key
end
GC.KIND.finger1, GC.KIND.finger2 = "finger", "finger"
GC.KIND.trinket1, GC.KIND.trinket2 = "trinket", "trinket"

function GC.Value(piece)
  if type(piece) ~= "table" or piece.broken then return 0 end
  local row = GD.Row(piece.row)
  if not row then return 0 end
  return GC.QUALITY_BASE[row.q] + 2 * row.tier + (piece.temper or 0)
end

function GC.KitScore(pieces)
  local sum = 0
  for slot, piece in pairs(pieces) do
    sum = sum + (WEIGHT[slot] or 0) * GC.Value(piece)
  end
  return math.floor(sum / 100)
end

function GC.WearLevel(tier)
  return WEAR_LEVEL[tier]
end

function GC.SalvageOf(q)
  return SALVAGE[q]
end

function GC.SlotPrice(row)
  if type(row) ~= "table" then return nil end
  local kit = KIT_PRICE[row.tier] and KIT_PRICE[row.tier][row.q]
  local weight = WEIGHT[row.slot]
  if not kit or not weight then return nil end
  return math.max(1, math.floor(kit * weight / KIT_WEIGHT))
end

-- The first tier is short until chapter 1 is done. No level here: the level gate is the tier tab's.
function GC.OnSale(row, chaptersDone)
  if not GC.SlotPrice(row) then return false end
  if row.tier ~= 1 or chaptersDone >= 1 then return true end
  return row.q == 0 and START_STOCK[row.slot] == true
end

function GC.TemperCost(weight, step, q)
  local cost = math.ceil(TEMPER_STEP[step] * weight / 100)
  if q == BLUE then return cost * 2 end
  return cost
end

function GC.RepairCost(row)
  if type(row) ~= "table" then return nil end
  local price = GC.SlotPrice(row)
  return SALVAGE[row.q], price and math.floor(price * REPAIR_PERCENT / 100)
end

function GC.Sellable(row)
  local price = GC.SlotPrice(row)
  return price and math.floor(price / SELL_DIVISOR)
end

-- Gear stats, shown only: nothing reads them for odds, Power or prices. From a piece's row and temper, never an item id.
--   GC.STATS                                  the five +stat names, in the order the screens list them
--   GC.PieceStats(piece) -> { armor = n|nil, low = n|nil, high = n|nil, stats = { { name = "Stamina", n = 3 }, ... } }
--                                             a broken piece answers as if intact; an unknown row answers { stats = {} }
--   GC.StatTotals({ [slot] = piece }) -> { armor = n, low = n|nil, high = n|nil, stats = { [name] = n } }
--                                             a broken piece adds nothing; Damage is the main hand's only
GC.STATS = { "Strength", "Agility", "Intellect", "Stamina", "Spirit" }

local ARMOR = { chest = 8, legs = 7, head = 6, shoulder = 5, feet = 5, hands = 4, waist = 3, wrist = 3, back = 2 }
local SHIELD_ARMOR = 10
local OFFHAND = { p0 = "shield", p1 = "shield", p3 = "shield", p4 = "shield", p2 = "damage", p5 = "damage" } -- any other has no base line
local SET_STATS = { ["Deathguard's Watch"] = { "Stamina", "Strength" }, ["Ambermill Warding"] = { "Intellect", "Spirit" } }
local GREEN = 2

local function statNames(row)
  local set = SET_STATS[row.set]
  if set then return set[1], set[2] end
  local a, b = string.byte(row.code, 1, 2)
  local i = (a + b) % #GC.STATS
  return GC.STATS[i + 1], GC.STATS[(i + 1) % #GC.STATS + 1]
end

function GC.PieceStats(piece)
  local row = type(piece) == "table" and GD.Row(piece.row)
  if not row then return { stats = {} } end
  local v = GC.Value({ row = piece.row, temper = piece.temper })
  local out = { stats = {} }
  local off = row.slot == "offhand" and OFFHAND[row.code]
  if ARMOR[row.slot] then
    out.armor = v * ARMOR[row.slot]
  elseif off == "shield" then
    out.armor = v * SHIELD_ARMOR
  elseif row.slot == "mainhand" or off == "damage" then
    out.low, out.high = v, 2 * v
  end
  if row.q >= GREEN then
    local first, second = statNames(row)
    out.stats[1] = { name = first, n = math.max(1, math.floor(v / 3)) }
    if row.q >= BLUE then out.stats[2] = { name = second, n = math.max(1, math.floor(v / 4)) } end
  end
  return out
end

function GC.StatTotals(pieces)
  local out = { armor = 0, stats = {} }
  for _, piece in pairs(pieces) do
    if type(piece) == "table" and not piece.broken then
      local s = GC.PieceStats(piece)
      out.armor = out.armor + (s.armor or 0)
      local row = GD.Row(piece.row)
      if row and row.slot == "mainhand" then out.low, out.high = s.low, s.high end
      for _, stat in ipairs(s.stats) do
        out.stats[stat.name] = (out.stats[stat.name] or 0) + stat.n
      end
    end
  end
  return out
end
