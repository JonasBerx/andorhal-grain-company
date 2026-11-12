-- GuildSyncExpeditions LootData.lua: ns.LootData, the loot tables of slice D (0.19 plan, Seams 8; economy.md sections 2, 6, 7).
-- Plain tables only. The lists are in fixed order: a stream draws from them, so they are never walked with pairs().
local _, ns = ...
if not ns.M then return end

ns.LootData = {
  REWARDS = { -- per mille, before the length factor: Safe, Risky, Dangerous, Deadly, capstone
    white = { 92, 115, 115, 115, 0 },
    green = { 0, 138, 276, 414, 1150 },
    blue = { 0, 0, 0, 0, 1334 },
    recruit = { 0, 10, 20, 40, 40 },
    supply = { 80, 120, 160, 200, 200 },
    map = { 0, 30, 30, 30, 0 },
    relic = { 10, 20, 30, 50, 50 },
    writ = { 0, 20, 30, 40, 40 },
  },
  LENGTH = { [1] = 50, [2] = 75, [4] = 100, [8] = 150, [24] = 300 }, -- hours -> percent
  FACTOR = { 4, 5, 6, 8 }, -- by danger 1..4, over 4
  XP = { [1] = 20, [2] = 35, [4] = 60, [8] = 100, [24] = 240 },
  GRAIN = { [1] = 6, [2] = 11, [4] = 20, [8] = 35, [24] = 90 },
  SALVAGE = { [1] = 2, [2] = 2, [4] = 4, [8] = 6, [24] = 12 },
  SUPPLIES = { -- from = the lowest danger it drops on
    { id = "rations", weight = 25, from = 1 },
    { id = "bandage", weight = 25, from = 1 },
    { id = "whetstone", weight = 20, from = 1 },
    { id = "candle", weight = 15, from = 1 },
    { id = "scoutchart", weight = 10, from = 1 },
    { id = "gravemoss", weight = 5, from = 3 },
  },
  RECRUIT_RACES = { "Forsaken", "Orc", "Tauren", "Troll" },
  RECRUIT_SEXES = { "m", "f" },
  NAMES = {
    Forsaken = { "Nerys", "Mordessa", "Vesper", "Corvane", "Maudrey", "Tamsin", "Hadrick", "Selwyn" },
    Orc = { "Thrak", "Grubb", "Urzog", "Morgra", "Brakka", "Kagra", "Dursha", "Zugrim" },
    Tauren = { "Tahona", "Hurak", "Mahka", "Sunawa", "Tolan", "Nakoma", "Honaw", "Ayita" },
    Troll = { "Ishka", "Zanjin", "Rakaja", "Vashti", "Tozala", "Jinka", "Kazul", "Zendi" },
  },
  RECRUIT_TRAITS = { "keen", "sturdy", "quiet" },
}
