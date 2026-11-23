-- GuildSyncExpeditions GearCore.lua: ns.GearCore, the pure gear numbers (0.19 plan, Seams 9).
-- Pure: string, table and math only, no globals, no game calls. Loads after GearData.lua.
--   GC.Value(piece) -> n                               GC.KitScore({ [slot] = piece }) -> n
--   GC.WearLevel(tier) -> 1 | 6 | nil                  GC.SalvageOf(q) -> 1 | 2 | nil
--   GC.SlotPrice(row) -> n | nil                       GC.TemperCost(weight, step, q) -> n
--   GC.RepairCost(row) -> salvage, grain | nil         GC.Sellable(row) -> n | nil
--   GC.OnSale(row, chaptersDone, forge) -> boolean     GC.SupplyOnSale(supplyRow, opened) -> boolean
--   GC.ShopPrice(row) -> n | nil                       what the Quartermaster asks: SlotPrice, or the Forge's green price
--   GC.GREEN: the green quality, which the Quartermaster sells only once the Forge is open

local _, ns = ...
if not ns.M then return end

local GD = ns.GearData
local GC = {}
ns.GearCore = GC

GC.QUALITY_BASE = { [0] = 1, [1] = 2, [2] = 4, [3] = 6 }
GC.QUALITY_COLOUR = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd" }
GC.STACK_MAX = { salvage = 99, supply = 20, relic = 20 }
GC.GREEN = 2
-- unlock: the influence step (ns.InfluenceCore) that puts the row on sale; a row with none is always on sale.
GC.SHOP_SUPPLIES = {
  { id = "rations", name = "Field Rations", price = 15, icon = "Interface\\Icons\\INV_Misc_Food_59", note = "+5% success" },
  { id = "warhorn", name = "War Horn", price = 25, icon = "Interface\\Icons\\INV_Misc_Horn_01",
    note = "+10% on Assaults", unlock = "supplies" },
  { id = "chalk", name = "Ritual Chalk", price = 25, icon = "Interface\\Icons\\INV_Misc_Dust_02",
    note = "+10% on Rituals", unlock = "supplies" },
  { id = "scoutchart", name = "Scout's Chart", price = 25, icon = "Interface\\Icons\\INV_Misc_Map_01",
    note = "+10% on Scouting", unlock = "apothecary" },
  { id = "bandage", name = "Linen Bandage", price = 10, icon = "Interface\\Icons\\INV_Misc_Bandage_12", note = "Halves wounds" },
  { id = "whetstone", name = "Whetstone Kit", price = 20, icon = "Interface\\Icons\\INV_Stone_SharpeningStone_01",
    note = "Halves gear wear", unlock = "supplies" },
  { id = "candle", name = "Spirit Candle", price = 40, icon = "Interface\\Icons\\INV_Misc_Candle_01",
    note = "Halves the death chance", unlock = "supplies" },
  { id = "gravemoss", name = "Grave-moss Charm", price = 150, icon = "Interface\\Icons\\INV_Misc_Herb_07",
    note = "No permanent death", unlock = "apothecary" },
  { id = "journal", name = "Field Journal", price = 20, icon = "Interface\\Icons\\INV_Misc_Book_11",
    note = "+25% XP", unlock = "supplies" },
  { id = "sack", name = "Spoils Sack", price = 30, icon = "Interface\\Icons\\INV_Misc_Bag_08",
    note = "+50% gear finds", unlock = "supplies" },
}

local WEAR_LEVEL = { 1, 6 }
local KIT_PRICE = { { [0] = 45, [1] = 120 }, { [0] = 90, [1] = 270 } } -- by tier, then quality
local KIT_WEIGHT = 300
local TEMPER_STEP = { 1, 2, 3, 5, 8 }
local GREEN, BLUE = GC.GREEN, 3
-- The Forge's green kit price by tier, for the shop only: KIT_PRICE has no green, so a dropped green keeps no SlotPrice
-- (Sellable and RepairCost read SlotPrice).
local GREEN_KIT = { 360, 810 }
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

function GC.ShopPrice(row)
  if type(row) ~= "table" then return nil end
  if row.q ~= GREEN then return GC.SlotPrice(row) end
  local kit, weight = GREEN_KIT[row.tier], WEIGHT[row.slot]
  if not kit or not weight then return nil end
  return math.floor(kit * weight / KIT_WEIGHT)
end

-- The first tier is short until chapter 1 is done. No level here: the level gate is the tier tab's.
-- forge: the Forge is open (ns.Opened("forge")); green is on sale only then.
function GC.OnSale(row, chaptersDone, forge)
  if not GC.ShopPrice(row) then return false end
  if row.q == GREEN and forge ~= true then return false end
  if row.tier ~= 1 or chaptersDone >= 1 then return true end
  return row.q == 0 and START_STOCK[row.slot] == true
end

-- A SHOP_SUPPLIES row. opened is ns.Opened, passed in so this file stays pure; nil opens only the rows with no unlock.
function GC.SupplyOnSale(row, opened)
  if type(row) ~= "table" then return false end
  return row.unlock == nil or (opened ~= nil and opened(row.unlock) == true)
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

-- Gear stats. From a piece's row, temper and roll, never an item id. Armor and Damage are shown only. The five +stats give
-- Power through GC.StatPower, by the follower's class kind; prices, repair, temper, sell values and the kit score never read them.
--   GC.STATS                                  the five +stat names, in the order the screens list them
--   GC.PieceStats(piece) -> { armor = n|nil, low = n|nil, high = n|nil, stats = { { name = "Stamina", n = 3 }, ... } }
--                                             a broken piece answers as if intact; an unknown row answers { stats = {} }
--   GC.StatTotals({ [slot] = piece }) -> { armor = n, low = n|nil, high = n|nil, stats = { [name] = n } }
--                                             a broken piece adds nothing; Damage is the main hand's only
--   GC.StatPower({ [slot] = piece }, kind) -> n   the Power the worn +stats give a class kind ("Might", "Cunning", "Lore"):
--                                             floor(sum of stat x FollowerData.STAT_WEIGHT[kind][stat] / STAT_DIVISOR);
--                                             0 for an unknown kind or no table of pieces
GC.STATS = { "Strength", "Agility", "Intellect", "Stamina", "Spirit" }

-- A rolled stat (issue 43, stage 2). A dropped plain green or blue carries piece.roll = 1..#GC.ROLLS: the roll names its
-- +stats in place of the catalogue's, a green the first, a blue both; the amounts stay the rule's. Any other row, and any
-- other value of roll, reads as no roll. The order is the wire's (Record.lua) and a saved piece's: append only, and the
-- gear triple's third character has room for four.
--   GC.ROLLS                                  { { name = "of the Bear", first stat, second stat }, ... }
--   GC.CanRoll(row) -> boolean                a green or blue row with no set and no named
--   GC.PieceName(piece) -> name | nil         the row's name, with the roll's name after it; nil for an unknown row
GC.ROLLS = {
  { name = "of the Bear", "Strength", "Stamina" },
  { name = "of the Monkey", "Agility", "Stamina" },
  { name = "of the Owl", "Intellect", "Spirit" },
  { name = "of the Whale", "Stamina", "Spirit" },
}

local ARMOR = { chest = 8, legs = 7, head = 6, shoulder = 5, feet = 5, hands = 4, waist = 3, wrist = 3, back = 2 }
local SHIELD_ARMOR = 10
local OFFHAND = { p0 = "shield", p1 = "shield", p3 = "shield", p4 = "shield", p2 = "damage", p5 = "damage" } -- any other has no base line
local SET_STATS = { ["Deathguard's Watch"] = { "Stamina", "Strength" }, ["Ambermill Warding"] = { "Intellect", "Spirit" } }

function GC.CanRoll(row)
  return type(row) == "table" and row.q >= GREEN and row.set == nil and row.named == nil
end

-- The roll a piece shows, or nil. A roll that is not a number never reaches the table: NaN is no key to read.
local function rollOf(row, roll)
  if type(roll) ~= "number" or roll ~= roll or not GC.CanRoll(row) then return nil end
  return GC.ROLLS[roll]
end

local function statNames(row, roll)
  local rolled = rollOf(row, roll)
  if rolled then return rolled[1], rolled[2] end
  local set = SET_STATS[row.set]
  if set then return set[1], set[2] end
  local a, b = string.byte(row.code, 1, 2)
  local i = (a + b) % #GC.STATS
  return GC.STATS[i + 1], GC.STATS[(i + 1) % #GC.STATS + 1]
end

function GC.PieceName(piece)
  local row = type(piece) == "table" and GD.Row(piece.row)
  if not row then return nil end
  local rolled = rollOf(row, piece.roll)
  return rolled and (row.name .. " " .. rolled.name) or row.name
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
    local first, second = statNames(row, piece.roll)
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

-- ns.FollowerData is read at call time: this file takes nothing from it at load.
function GC.StatPower(pieces, kind)
  local D = ns.FollowerData
  local weights = D.STAT_WEIGHT[kind]
  if type(pieces) ~= "table" or not weights then return 0 end
  local sum = 0
  for name, n in pairs(GC.StatTotals(pieces).stats) do
    sum = sum + n * (weights[name] or 0)
  end
  return math.floor(sum / D.STAT_DIVISOR)
end
