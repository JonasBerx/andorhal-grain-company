-- GuildSyncExpeditions GearData.lua: the item catalogue, ns.GearData (SLOTS, ROWS, Row, WellFormed, Find).
-- Source: DB2 CSVs from wago.tools, product wow_classic_beta, build 1.60.1.70532:
--   https://wago.tools/db2/ItemSparse/csv?build=1.60.1.70532
--   https://wago.tools/db2/Item/csv?build=1.60.1.70532
-- item = ItemSparse ID, icon = Item.IconFileDataID, lvl = ItemSparse.RequiredLevel of an in-band item.
-- Filter: ExpansionID 0, id below 25000, SellPrice >= 1, Item.IconFileDataID > 0, ClassID 2 Weapon or 4 Armor,
-- OverallQualityID 0-3, one item per name (the lowest id), no name holding (case-insensitive substring) QA, Test, [PH],
-- NYI, Debug, Template, Unused, Monster, Deprecated, Dummy, DNT, Trigger, Hidden, placeholder, Gamemaster, Durability,
-- Alliance or Festival, or the word OLD, no name starting with OLD, starting with a number and a space, or ending in a
-- space and a number. Two-handers are excluded: off hand takes a shield, held item or ranged weapon; main hand takes
-- one-hand and main-hand weapons.
-- The rule: the real item lends the icon and the item id only. name is the module's own, in the game's style (Militia
-- gear at the Quartermaster, zone names on drops, the two set names, the two named main hands); quality, tier and value
-- are the module's own too. Each row takes a real item of its slot in its tier's required-level band (1-5 for T1, 6-10
-- for T2), one per icon first, most often matching quality; a main-hand or off-hand row takes the weapon or shield kind
-- its name says.
-- Where the band has too few real items, the shortfall borrows a real item of that slot from outside it. Picks went
-- rarer pieces first, so a row's item is not always the lowest-level one of its slot and quality; only the icon and the
-- id come from the item. A borrowed row's lvl is its tier's first level (1 or 6), so it never asks more than its tier's
-- wear level, and its name is never that item's own name.
-- Codes: two characters. First the slot's position in SLOTS as a..p, then the variant digit: 0 T1 grey, 1 T1 white,
-- 2 T1 green, 3 T2 grey, 4 T2 white, 5 T2 green, 6 T2 blue plain, 7 a Deathguard's Watch piece or the tirisfal main hand,
-- 8 an Ambermill Warding piece or the silverpine main hand. Codes are append-only: a code is a saved record's key.
-- SLOTS order is frozen because a code's first letter is the slot's position; a 17th slot is appended as q, never
-- inserted.
local _, ns = ...
if not ns.M then return end

local SLOTS = {
  { key = "head", weight = 20 },
  { key = "neck", weight = 14 },
  { key = "shoulder", weight = 18 },
  { key = "back", weight = 12 },
  { key = "chest", weight = 24 },
  { key = "wrist", weight = 12 },
  { key = "hands", weight = 16 },
  { key = "waist", weight = 14 },
  { key = "legs", weight = 24 },
  { key = "feet", weight = 16 },
  { key = "finger1", weight = 12 },
  { key = "finger2", weight = 12 },
  { key = "trinket1", weight = 18 },
  { key = "trinket2", weight = 18 },
  { key = "mainhand", weight = 45 },
  { key = "offhand", weight = 25 },
}

local ROWS = {
  { code = "a0", item = 8748, slot = "head", tier = 1, q = 0, name = "Ragged Cap", icon = 133141, lvl = 1 },
  { code = "a1", item = 3536, slot = "head", tier = 1, q = 1, name = "Recruit's Cap", icon = 133072, lvl = 1 },
  { code = "a2", item = 3529, slot = "head", tier = 1, q = 2, name = "Deathknell Coif", icon = 133072, lvl = 1 },
  { code = "a3", item = 3556, slot = "head", tier = 2, q = 0, name = "Dented Helm", icon = 133116, lvl = 6 },
  { code = "a4", item = 3732, slot = "head", tier = 2, q = 1, name = "Militia Cap", icon = 133136, lvl = 6 },
  { code = "a5", item = 7048, slot = "head", tier = 2, q = 2, name = "Scarlet-Forged Helm", icon = 133131, lvl = 6 },
  { code = "a6", item = 7996, slot = "head", tier = 2, q = 3, name = "Throne Room Circlet", icon = 133133, lvl = 6 },
  { code = "a7", item = 7997, slot = "head", tier = 2, q = 3, set = "Deathguard's Watch", name = "Deathguard Watch Helm", icon = 133694, lvl = 6 },
  { code = "a8", item = 4368, slot = "head", tier = 2, q = 3, set = "Ambermill Warding", name = "Ambermill Warded Cowl", icon = 133149, lvl = 6 },
  { code = "b0", item = 4112, slot = "neck", tier = 1, q = 0, name = "Frayed Cord", icon = 133291, lvl = 1 },
  { code = "b1", item = 18442, slot = "neck", tier = 1, q = 1, name = "Knotted Charm", icon = 134311, lvl = 1 },
  { code = "b2", item = 7427, slot = "neck", tier = 1, q = 2, name = "Balnir Choker", icon = 133290, lvl = 1 },
  { code = "b3", item = 7548, slot = "neck", tier = 2, q = 0, name = "Tarnished Chain", icon = 133293, lvl = 6 },
  { code = "b4", item = 15690, slot = "neck", tier = 2, q = 1, name = "Bone Pendant", icon = 133296, lvl = 6 },
  { code = "b5", item = 15200, slot = "neck", tier = 2, q = 2, name = "Gravedigger's Pendant", icon = 134317, lvl = 6 },
  { code = "b6", item = 9333, slot = "neck", tier = 2, q = 3, name = "Medallion of Lordaeron", icon = 132507, lvl = 6 },
  { code = "c0", item = 14170, slot = "shoulder", tier = 1, q = 0, name = "Ragged Shoulderpads", icon = 135044, lvl = 1 },
  { code = "c1", item = 4694, slot = "shoulder", tier = 1, q = 1, name = "Recruit's Mantle", icon = 135059, lvl = 1 },
  { code = "c2", item = 4700, slot = "shoulder", tier = 1, q = 2, name = "Solliden Spaulders", icon = 135039, lvl = 1 },
  { code = "c3", item = 3480, slot = "shoulder", tier = 2, q = 0, name = "Dented Spaulders", icon = 135036, lvl = 6 },
  { code = "c4", item = 10405, slot = "shoulder", tier = 2, q = 1, name = "Militia Mantle", icon = 135058, lvl = 6 },
  { code = "c5", item = 10407, slot = "shoulder", tier = 2, q = 2, name = "Pyrewood Shoulderpads", icon = 135054, lvl = 6 },
  { code = "c6", item = 1793, slot = "shoulder", tier = 2, q = 3, name = "Throne Room Pauldrons", icon = 135037, lvl = 6 },
  { code = "c7", item = 5319, slot = "shoulder", tier = 2, q = 3, set = "Deathguard's Watch", name = "Deathguard Watch Pauldrons", icon = 135038, lvl = 6 },
  { code = "c8", item = 1769, slot = "shoulder", tier = 2, q = 3, set = "Ambermill Warding", name = "Ambermill Warded Mantle", icon = 135040, lvl = 6 },
  { code = "d0", item = 1372, slot = "back", tier = 1, q = 0, name = "Moth-Eaten Cape", icon = 133762, lvl = 1 },
  { code = "d1", item = 2570, slot = "back", tier = 1, q = 1, name = "Coarse Linen Cloak", icon = 133766, lvl = 1 },
  { code = "d2", item = 3322, slot = "back", tier = 1, q = 2, name = "Nightmare Vale Shroud", icon = 133763, lvl = 5 },
  { code = "d3", item = 1505, slot = "back", tier = 2, q = 0, name = "Tattered Cloak", icon = 133760, lvl = 7 },
  { code = "d4", item = 9745, slot = "back", tier = 2, q = 1, name = "Heavy Linen Cloak", icon = 133774, lvl = 6 },
  { code = "d5", item = 2580, slot = "back", tier = 2, q = 2, name = "Moonrage Hide Cloak", icon = 133759, lvl = 7 },
  { code = "d6", item = 3008, slot = "back", tier = 2, q = 3, name = "Cloak of the Fallen Court", icon = 133756, lvl = 6 },
  { code = "e0", item = 56, slot = "chest", tier = 1, q = 0, name = "Patched Tunic", icon = 132664, lvl = 1 },
  { code = "e1", item = 85, slot = "chest", tier = 1, q = 1, name = "Recruit's Tunic", icon = 135011, lvl = 1 },
  { code = "e2", item = 22742, slot = "chest", tier = 1, q = 2, name = "Agamand Hauberk", icon = 135012, lvl = 1 },
  { code = "e3", item = 1509, slot = "chest", tier = 2, q = 0, name = "Stained Jerkin", icon = 135009, lvl = 6 },
  { code = "e4", item = 2613, slot = "chest", tier = 2, q = 1, name = "Militia Tunic", icon = 132665, lvl = 8 },
  { code = "e5", item = 2311, slot = "chest", tier = 2, q = 2, name = "Scarlet Chain Vest", icon = 132760, lvl = 8 },
  { code = "e6", item = 6240, slot = "chest", tier = 2, q = 3, name = "Royal Guard Breastplate", icon = 132678, lvl = 7 },
  { code = "e7", item = 2300, slot = "chest", tier = 2, q = 3, set = "Deathguard's Watch", name = "Deathguard Watch Hauberk", icon = 132724, lvl = 7 },
  { code = "e8", item = 6239, slot = "chest", tier = 2, q = 3, set = "Ambermill Warding", name = "Ambermill Warded Vest", icon = 132681, lvl = 7 },
  { code = "f0", item = 1370, slot = "wrist", tier = 1, q = 0, name = "Frayed Wraps", icon = 132609, lvl = 1 },
  { code = "f1", item = 1836, slot = "wrist", tier = 1, q = 1, name = "Recruit's Bindings", icon = 132603, lvl = 1 },
  { code = "f2", item = 3323, slot = "wrist", tier = 1, q = 2, name = "Deathknell Bindings", icon = 132606, lvl = 5 },
  { code = "f3", item = 3375, slot = "wrist", tier = 2, q = 0, name = "Cracked Cuffs", icon = 132612, lvl = 7 },
  { code = "f4", item = 15297, slot = "wrist", tier = 2, q = 1, name = "Militia Bracers", icon = 132601, lvl = 6 },
  { code = "f5", item = 4308, slot = "wrist", tier = 2, q = 2, name = "Bonelink Bracers", icon = 132611, lvl = 7 },
  { code = "f6", item = 763, slot = "wrist", tier = 2, q = 3, name = "Throne Room Bracers", icon = 132607, lvl = 7 },
  { code = "g0", item = 2968, slot = "hands", tier = 1, q = 0, name = "Torn Mitts", icon = 132962, lvl = 4 },
  { code = "g1", item = 714, slot = "hands", tier = 1, q = 1, name = "Recruit's Gloves", icon = 132952, lvl = 1 },
  { code = "g2", item = 711, slot = "hands", tier = 1, q = 2, name = "Garren's Handwraps", icon = 132961, lvl = 1 },
  { code = "g3", item = 3286, slot = "hands", tier = 2, q = 0, name = "Cracked Gloves", icon = 132953, lvl = 7 },
  { code = "g4", item = 6515, slot = "hands", tier = 2, q = 1, name = "Militia Gloves", icon = 132955, lvl = 6 },
  { code = "g5", item = 6510, slot = "hands", tier = 2, q = 2, name = "Rot Hide Gloves", icon = 132945, lvl = 6 },
  { code = "g6", item = 3281, slot = "hands", tier = 2, q = 3, name = "Worgen Hide Gauntlets", icon = 132963, lvl = 6 },
  { code = "g7", item = 3472, slot = "hands", tier = 2, q = 3, set = "Deathguard's Watch", name = "Deathguard Watch Gauntlets", icon = 132938, lvl = 7 },
  { code = "g8", item = 4239, slot = "hands", tier = 2, q = 3, set = "Ambermill Warding", name = "Ambermill Warded Gloves", icon = 132939, lvl = 8 },
  { code = "h0", item = 1369, slot = "waist", tier = 1, q = 0, name = "Frayed Rope Belt", icon = 132513, lvl = 1 },
  { code = "h1", item = 1835, slot = "waist", tier = 1, q = 1, name = "Recruit's Belt", icon = 132493, lvl = 1 },
  { code = "h2", item = 22743, slot = "waist", tier = 1, q = 2, name = "Solliden Sash", icon = 133694, lvl = 1 },
  { code = "h3", item = 1730, slot = "waist", tier = 2, q = 0, name = "Cracked Belt", icon = 132495, lvl = 7 },
  { code = "h4", item = 9750, slot = "waist", tier = 2, q = 1, name = "Militia Belt", icon = 132514, lvl = 7 },
  { code = "h5", item = 2546, slot = "waist", tier = 2, q = 2, name = "Deathguard Girdle", icon = 132498, lvl = 8 },
  { code = "h6", item = 2851, slot = "waist", tier = 2, q = 3, name = "Girdle of the Wolf Lord", icon = 132491, lvl = 6 },
  { code = "i0", item = 1366, slot = "legs", tier = 1, q = 0, name = "Patched Trousers", icon = 134586, lvl = 1 },
  { code = "i1", item = 194, slot = "legs", tier = 1, q = 1, name = "Recruit's Trousers", icon = 134592, lvl = 1 },
  { code = "i2", item = 22745, slot = "legs", tier = 1, q = 2, name = "Cold Hearth Breeches", icon = 134596, lvl = 1 },
  { code = "i3", item = 1499, slot = "legs", tier = 2, q = 0, name = "Stained Leggings", icon = 134591, lvl = 6 },
  { code = "i4", item = 1507, slot = "legs", tier = 2, q = 1, name = "Militia Leggings", icon = 134588, lvl = 9 },
  { code = "i5", item = 10047, slot = "legs", tier = 2, q = 2, name = "Ambermill Breeches", icon = 134591, lvl = 10 },
  { code = "i6", item = 4309, slot = "legs", tier = 2, q = 3, name = "Courtier's Legguards", icon = 134587, lvl = 9 },
  { code = "i7", item = 7280, slot = "legs", tier = 2, q = 3, set = "Deathguard's Watch", name = "Deathguard Watch Legplates", icon = 134582, lvl = 6 },
  { code = "i8", item = 3473, slot = "legs", tier = 2, q = 3, set = "Ambermill Warding", name = "Ambermill Warded Leggings", icon = 134583, lvl = 8 },
  { code = "j0", item = 2302, slot = "feet", tier = 1, q = 0, name = "Holed Shoes", icon = 132538, lvl = 3 },
  { code = "j1", item = 2383, slot = "feet", tier = 1, q = 1, name = "Recruit's Boots", icon = 132535, lvl = 1 },
  { code = "j2", item = 210, slot = "feet", tier = 1, q = 2, name = "Tirisfal Trail Boots", icon = 132540, lvl = 1 },
  { code = "j3", item = 15481, slot = "feet", tier = 2, q = 0, name = "Cracked Boots", icon = 132536, lvl = 8 },
  { code = "j4", item = 9751, slot = "feet", tier = 2, q = 1, name = "Militia Boots", icon = 132579, lvl = 7 },
  { code = "j5", item = 6518, slot = "feet", tier = 2, q = 2, name = "Brightwater Boots", icon = 132542, lvl = 6 },
  { code = "j6", item = 6506, slot = "feet", tier = 2, q = 3, name = "Treads of the Silent Court", icon = 132582, lvl = 6 },
  { code = "j7", item = 6201, slot = "feet", tier = 2, q = 3, set = "Deathguard's Watch", name = "Deathguard Watch Greaves", icon = 132539, lvl = 7 },
  { code = "j8", item = 2569, slot = "feet", tier = 2, q = 3, set = "Ambermill Warding", name = "Ambermill Warded Boots", icon = 132543, lvl = 8 },
  { code = "k0", item = 5313, slot = "finger1", tier = 1, q = 0, name = "Bent Tin Ring", icon = 134413, lvl = 1 },
  { code = "k1", item = 17692, slot = "finger1", tier = 1, q = 1, name = "Plain Tin Band", icon = 133344, lvl = 1 },
  { code = "k2", item = 3235, slot = "finger1", tier = 1, q = 2, name = "Agamand Ring", icon = 133357, lvl = 1 },
  { code = "k3", item = 1077, slot = "finger1", tier = 2, q = 0, name = "Scratched Band", icon = 133356, lvl = 6 },
  { code = "k4", item = 1449, slot = "finger1", tier = 2, q = 1, name = "Copper Band", icon = 133355, lvl = 6 },
  { code = "k5", item = 5351, slot = "finger1", tier = 2, q = 2, name = "Agamand Signet", icon = 133343, lvl = 6 },
  { code = "k6", item = 7338, slot = "finger1", tier = 2, q = 3, name = "Signet of the Fallen King", icon = 133354, lvl = 6 },
  { code = "l0", item = 5000, slot = "finger2", tier = 1, q = 0, name = "Rusted Loop", icon = 133349, lvl = 1 },
  { code = "l1", item = 1319, slot = "finger2", tier = 1, q = 1, name = "Twisted Wire Ring", icon = 132520, lvl = 1 },
  { code = "l2", item = 7341, slot = "finger2", tier = 1, q = 2, name = "Balnir Band", icon = 133347, lvl = 1 },
  { code = "l3", item = 6678, slot = "finger2", tier = 2, q = 0, name = "Tarnished Ring", icon = 132521, lvl = 6 },
  { code = "l4", item = 3739, slot = "finger2", tier = 2, q = 1, name = "Silvered Band", icon = 132501, lvl = 6 },
  { code = "l5", item = 5622, slot = "finger2", tier = 2, q = 2, name = "Olsen's Ring", icon = 132522, lvl = 6 },
  { code = "l6", item = 1189, slot = "finger2", tier = 2, q = 3, name = "Fenris Keep Seal", icon = 133345, lvl = 6 },
  { code = "m0", item = 4381, slot = "trinket1", tier = 1, q = 0, name = "Chipped Tooth", icon = 133001, lvl = 1 },
  { code = "m1", item = 3005, slot = "trinket1", tier = 1, q = 1, name = "Rabbit's Foot", icon = 133435, lvl = 1 },
  { code = "m2", item = 2920, slot = "trinket1", tier = 1, q = 2, name = "Brill Town Token", icon = 133750, lvl = 5 },
  { code = "m3", item = 2919, slot = "trinket1", tier = 2, q = 0, name = "Worn Knucklebone", icon = 133438, lvl = 6 },
  { code = "m4", item = 2923, slot = "trinket1", tier = 2, q = 1, name = "Lucky Bone", icon = 133434, lvl = 6 },
  { code = "m5", item = 18834, slot = "trinket1", tier = 2, q = 2, name = "Ticking Pocket Watch", icon = 133453, lvl = 6 },
  { code = "m6", item = 2921, slot = "trinket1", tier = 2, q = 3, name = "Heart of the Old Capital", icon = 134414, lvl = 10 },
  { code = "n0", item = 3002, slot = "trinket2", tier = 1, q = 0, name = "Cracked Button", icon = 134229, lvl = 1 },
  { code = "n1", item = 3006, slot = "trinket2", tier = 1, q = 1, name = "Rusty Whistle", icon = 134095, lvl = 1 },
  { code = "n2", item = 3003, slot = "trinket2", tier = 1, q = 2, name = "Deathguard Tally Stone", icon = 133884, lvl = 5 },
  { code = "n3", item = 7148, slot = "trinket2", tier = 2, q = 0, name = "Dull Bone Die", icon = 133868, lvl = 6 },
  { code = "n4", item = 7506, slot = "trinket2", tier = 2, q = 1, name = "Runed Stone", icon = 134376, lvl = 6 },
  { code = "n5", item = 2922, slot = "trinket2", tier = 2, q = 2, name = "Greymane Wall Stone", icon = 134333, lvl = 6 },
  { code = "n6", item = 3004, slot = "trinket2", tier = 2, q = 3, name = "Arugal's Focus", icon = 134514, lvl = 10 },
  { code = "o0", item = 2065, slot = "mainhand", tier = 1, q = 0, name = "Notched Shortsword", icon = 135357, lvl = 4 },
  { code = "o1", item = 36, slot = "mainhand", tier = 1, q = 1, name = "Recruit's Cudgel", icon = 133478, lvl = 1 },
  { code = "o2", item = 2847, slot = "mainhand", tier = 1, q = 2, name = "Scarlet Cutlass", icon = 135327, lvl = 4 },
  { code = "o3", item = 1516, slot = "mainhand", tier = 2, q = 0, name = "Pitted Hatchet", icon = 135419, lvl = 9 },
  { code = "o4", item = 1511, slot = "mainhand", tier = 2, q = 1, name = "Militia Sword", icon = 135274, lvl = 8 },
  { code = "o5", item = 851, slot = "mainhand", tier = 2, q = 2, name = "Sepulcher Blade", icon = 135346, lvl = 10 },
  { code = "o6", item = 4765, slot = "mainhand", tier = 2, q = 3, name = "Lordaeron Guard Blade", icon = 135321, lvl = 9 },
  { code = "o7", item = 4766, slot = "mainhand", tier = 2, q = 3, named = "tirisfal", name = "Agamand Heirloom Blade", icon = 135325, lvl = 8 },
  { code = "o8", item = 3225, slot = "mainhand", tier = 2, q = 3, named = "silverpine", name = "Fang of the Worgen Master", icon = 135637, lvl = 6 },
  { code = "p0", item = 1438, slot = "offhand", tier = 1, q = 0, name = "Split Buckler", icon = 134949, lvl = 4 },
  { code = "p1", item = 876, slot = "offhand", tier = 1, q = 1, name = "Recruit's Buckler", icon = 134955, lvl = 1 },
  { code = "p2", item = 4763, slot = "offhand", tier = 1, q = 2, name = "Agamand Hunting Bow", icon = 135500, lvl = 4 },
  { code = "p3", item = 2215, slot = "offhand", tier = 2, q = 0, name = "Scarred Shield", icon = 134955, lvl = 6 },
  { code = "p4", item = 3649, slot = "offhand", tier = 2, q = 1, name = "Militia Buckler", icon = 134955, lvl = 6 },
  { code = "p5", item = 2777, slot = "offhand", tier = 2, q = 2, name = "Dead Field Shortbow", icon = 135493, lvl = 8 },
  { code = "p6", item = 15944, slot = "offhand", tier = 2, q = 3, name = "Orb of Lordaeron", icon = 134335, lvl = 7 },
}

local function plainKey(slot, tier, q)
  return tostring(slot) .. ":" .. tostring(tier) .. ":" .. tostring(q)
end

local byCode, plain = {}, {}
for _, r in ipairs(ROWS) do
  byCode[r.code] = r
  if r.set == nil and r.named == nil then plain[plainKey(r.slot, r.tier, r.q)] = r end
end

local GearData = { SLOTS = SLOTS, ROWS = ROWS }

-- The live row, or nil for an unknown code or anything not a string. Callers treat it as read-only.
function GearData.Row(code)
  return byCode[code]
end

function GearData.WellFormed(code)
  return type(code) == "string" and string.find(code, "^[0-9A-Za-z][0-9A-Za-z]$") ~= nil
end

-- The one plain row (no set, no named) of a slot, tier and quality, or nil.
function GearData.Find(slot, tier, q)
  return plain[plainKey(slot, tier, q)]
end

ns.GearData = GearData
