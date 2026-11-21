-- GuildSyncExpeditions Data.lua: ns.FollowerData, the follower tables (0.19 plan, Seams 3; economy.md section 2).
-- Race keys are economy.md's own; class kinds match row kinds as ROW_KIND says.
local _, ns = ...
if not ns.M then return end

ns.FollowerData = {
  RACES = { -- race -> its classes
    Forsaken = { "Warrior", "Rogue", "Mage", "Priest", "Warlock", "Paladin" },
    Orc = { "Warrior", "Rogue", "Hunter", "Shaman", "Warlock" },
    Tauren = { "Warrior", "Hunter", "Shaman", "Druid" },
    Troll = { "Warrior", "Rogue", "Hunter", "Mage", "Priest", "Shaman" },
  },
  KIND = { -- class -> class kind
    Warrior = "Might", Shaman = "Might", Paladin = "Might",
    Rogue = "Cunning", Hunter = "Cunning", Druid = "Cunning",
    Mage = "Lore", Priest = "Lore", Warlock = "Lore",
  },
  ROW_KIND = { Might = "Raid", Cunning = "Scout", Lore = "Rite" },
  PERKS = { -- broken is subtracted, rest is in hours
    Forsaken = { deathPct = 90 }, Orc = { woundPct = 90 }, Tauren = { broken = 2 }, Troll = { rest = -1 },
  },
  BODIES = { m = true, f = true },
  PRICES = { 100, 1000, 10000 }, -- index = held + 1
  CAP_USE = 3, CAP_RESERVE = 2, CAP_ALL = 5, CAP_BOUGHT = 3,
  MAX_LEVEL = 10, XP_BASE = 100, XP_STEP = 75, LEVEL_POWER = 5, AFFINITY = 8,
  TRAIT_POWER = { veteran = { power = 5 }, quiet = { power = 4, rowKind = "Scout" } },
  -- What a worn gear stat is worth to a class kind, in tenths; a stat a kind does not name counts for nothing.
  -- Stat Power = floor(sum of stat x weight / STAT_DIVISOR), read by ns.GearCore.StatPower (issue 43).
  STAT_WEIGHT = {
    Might = { Strength = 10, Agility = 4, Stamina = 6 },
    Cunning = { Strength = 4, Agility = 10, Stamina = 6 },
    Lore = { Intellect = 10, Stamina = 4, Spirit = 6 },
  },
  STAT_DIVISOR = 40,
}
