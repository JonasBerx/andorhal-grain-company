-- GuildSyncExpeditions BookData.lua: ns.BookData, the relics and the two region sets (0.19 plan, Seams 8).
-- Relic ids are saved keys: append-only. Each icon is borrowed from the GearData row named beside it.
-- A set's pieces are in the order the slot lean draws over.
local _, ns = ...
if not ns.M then return end

ns.BookData = {
  relics = {
    { id = "t1", name = "Agamand Family Crest", region = "tirisfal", tier = 1, icon = 133343 }, -- k5
    { id = "t2", name = "Brill Town Bell", region = "tirisfal", tier = 1, icon = 133750 }, -- m2
    { id = "t3", name = "Scarlet Signet Ring", region = "tirisfal", tier = 1, icon = 133354 }, -- k6
    { id = "t4", name = "Deathknell Grave Candle", region = "tirisfal", tier = 1, icon = 133868 }, -- n3
    { id = "t5", name = "Plagued Pumpkin Seed", region = "tirisfal", tier = 1, icon = 134229 }, -- n0
    { id = "s1", name = "Pyrewood Door Knocker", region = "silverpine", tier = 2, icon = 134095 }, -- n1
    { id = "s2", name = "Ambermill Arcane Shard", region = "silverpine", tier = 2, icon = 134333 }, -- n5
    { id = "s3", name = "Shadowfang Wolf Collar", region = "silverpine", tier = 2, icon = 133290 }, -- b2
    { id = "s4", name = "Sepulcher Bone Key", region = "silverpine", tier = 2, icon = 133438 }, -- m3
    { id = "s5", name = "Fenris Isle Runestone", region = "silverpine", tier = 2, icon = 134376 }, -- n4
  },
  sets = {
    { region = "tirisfal", name = "Deathguard's Watch", capstone = "tirisfal-capstone",
      pieces = { "a7", "c7", "e7", "g7", "i7", "j7" } },
    { region = "silverpine", name = "Ambermill Warding", capstone = "silverpine-capstone",
      pieces = { "a8", "c8", "e8", "g8", "i8", "j8" } },
  },
}
