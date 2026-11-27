local _, ns = ...
if not ns.M then return end

-- LootPolicy.lua: the pure loot policy classifier (LOOT-POLICY.md): does an item go to the loot council or to a roll,
-- and why. No client calls and no frame; the item facts come in (ns.Items.Info shape).
-- Exports ns.LootPolicy (LP):
--   LP.Kind(info, size, flagged) -> "council" | "roll", reason | nil
--     info { class, subclass, slot, quality, bind, loading }, size 10 | 20 | 40 | "party" | nil (a raid of unknown
--     size counts as 20), flagged true when an officer marked the item for the council.
--   LP.Text(kind, reason) -> "Roll" | "Roll: <reason>" | "Council: <reason>"
--   LP.REASONS    the reason strings (shared by the tests and the window)
-- At load, when ns.Items is a table: ns.Items.CouncilRule(id, size, info) -> council (bool), reason.
-- Order of the checks: size 10 -> roll; size "party" -> roll; any other size that is not a number or nil -> roll;
-- flagged -> council; no item facts yet -> roll "loading"; recipe -> council; BoE -> roll; legendary -> council;
-- ranged weapon -> council; off-hand -> council; weapon -> council; trinket -> council; else a plain roll (relics).

local LP = {}
ns.LootPolicy = LP

local R = {
  weapon = "weapon", offhand = "off-hand", ranged = "ranged weapon", trinket = "trinket",
  legendary = "legendary", recipe = "recipe", flagged = "flagged", boe = "BoE",
  ten = "10-player raid", dungeon = "dungeon", loading = "loading",
}
LP.REASONS = R

local WEAPON = 2
local ARMOR, SHIELD = 4, 6
local RECIPE = 9
local LEGENDARY = 5
local BOE = 2
local RANGED_SUB = { [2] = true, [3] = true, [16] = true, [18] = true, [19] = true }
local RANGED_SLOT = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }
local OFFHAND_SLOT = { INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true }
local WEAPON_SLOT = {
  INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
}

function LP.Kind(info, size, flagged)
  if size == 10 then return "roll", R.ten end
  if size == "party" then return "roll", R.dungeon end
  if size ~= nil and type(size) ~= "number" then return "roll", nil end
  if flagged == true then return "council", R.flagged end
  if type(info) ~= "table" or info.loading then return "roll", R.loading end
  local class, sub = info.class, info.subclass
  local slot = type(info.slot) == "string" and info.slot or nil
  if class == RECIPE then return "council", R.recipe end
  if info.bind == BOE then return "roll", R.boe end
  if info.quality == LEGENDARY then return "council", R.legendary end
  if (slot and RANGED_SLOT[slot]) or (class == WEAPON and RANGED_SUB[sub]) then return "council", R.ranged end
  if (slot and OFFHAND_SLOT[slot]) or (class == ARMOR and sub == SHIELD) then return "council", R.offhand end
  if (slot and WEAPON_SLOT[slot]) or class == WEAPON then return "council", R.weapon end
  if slot == "INVTYPE_TRINKET" then return "council", R.trinket end
  return "roll", nil
end

function LP.Text(kind, reason)
  local word = kind == "council" and "Council" or "Roll"
  if reason == nil then return word end
  return word .. ": " .. tostring(reason)
end

if type(ns.Items) == "table" then
  ns.Items.CouncilRule = function(_, size, info)
    local kind, reason = LP.Kind(info, size, false)
    return kind == "council", reason
  end
end
