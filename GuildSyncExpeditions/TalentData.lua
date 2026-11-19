-- GuildSyncExpeditions TalentData.lua: ns.TalentData, the three follower talent trees (issue 13 spec, build step 1).
-- Plain tables only. Talents stay in tree order: a saved build is one rank per talent in this order, so bump V on any
-- change to the order or the ranks (a build saved under another V is refunded whole).
--   TD.V                       the tree version
--   TD.TIERS, TD.COLS          6 tiers of 4 columns
--   TD.ORDER                   { "Might", "Cunning", "Lore" }, the class kinds (FollowerData.KIND) in order
--   TD.TREES[kind]             { kind, name, talents = { talent, ... } }
--     talent = { id, name, tier, col, max, icon, needs = id | nil, capstone = true | nil, fx, when = clauses | nil }
--     fx, per rank: power (Power), wound / death / gear (a cut in percent of that chance), broken (gear break points
--       off), rest (hours), noPerma (true), xp / grain / salvage (percent more), raise (percent off the raise price),
--       find = { [LootData reward] = percent more often }
--     when: a list of clauses, any one matching is enough; a clause matches a board row when each field it names does:
--       kind (a list of row kinds), danger (a list of 1..4), maxHours, minHours. No when: every expedition.
--   TD.BUILDS[kind]            { { name, ranks = { [talent id] = rank } }, ... }, the example builds (18 points each)
local _, ns = ...
if not ns.M then return end

local ASSAULT = { kind = { "Raid" } }
local SCOUT = { kind = { "Scout" } }
local RITUAL = { kind = { "Rite" } }
local DEADLY = { danger = { 4 } }

local VANGUARD = {
  kind = "Might",
  name = "Vanguard",
  talents = {
    { id = "thickHide", name = "Thick Hide", tier = 1, col = 1, max = 5, icon = "Ability_Warrior_DefensiveStance",
      fx = { wound = 3 } },
    { id = "drilled", name = "Drilled", tier = 1, col = 2, max = 5, icon = "Ability_Warrior_BattleShout",
      fx = { power = 1 }, when = { ASSAULT } },
    { id = "mailCare", name = "Mail Care", tier = 1, col = 3, max = 2, icon = "INV_Stone_SharpeningStone_01",
      fx = { broken = 1 } },
    { id = "holdTheLine", name = "Hold the Line", tier = 2, col = 1, max = 3, icon = "Ability_Warrior_ShieldWall",
      fx = { death = 5 } },
    { id = "brawler", name = "Brawler", tier = 2, col = 3, max = 3, icon = "Ability_Warrior_Cleave",
      fx = { power = 1 }, when = { { kind = { "Scout", "Rite" } } } },
    { id = "battleTested", name = "Battle-tested", tier = 2, col = 4, max = 2, icon = "Ability_Warrior_Revenge",
      fx = { xp = 5 } },
    { id = "fieldDressing", name = "Field Dressing", tier = 3, col = 3, max = 2, icon = "INV_Misc_Bandage_12",
      fx = { rest = -1 } },
    { id = "pressTheAttack", name = "Press the Attack", tier = 3, col = 2, max = 3, icon = "Ability_Warrior_Charge",
      needs = "drilled", fx = { power = 1 }, when = { { kind = { "Raid" }, danger = { 3, 4 } } } },
    { id = "plunder", name = "Plunder", tier = 3, col = 4, max = 2, icon = "INV_Misc_Bag_10",
      fx = { grain = 10 } },
    { id = "bulwark", name = "Bulwark", tier = 4, col = 1, max = 1, icon = "INV_Shield_06",
      needs = "holdTheLine", fx = { death = 20 }, when = { DEADLY } },
    { id = "bannerBearer", name = "Banner Bearer", tier = 4, col = 2, max = 2, icon = "INV_BannerPVP_01",
      fx = { power = 1 }, when = { ASSAULT } },
    { id = "spoilsOfWar", name = "Spoils of War", tier = 4, col = 3, max = 2, icon = "INV_Sword_04",
      fx = { find = { green = 15 } } },
    { id = "unbreakable", name = "Unbreakable", tier = 5, col = 1, max = 2, icon = "Spell_Nature_StoneSkinTotem",
      fx = { gear = 10 } },
    { id = "commandingPresence", name = "Commanding Presence", tier = 5, col = 3, max = 2,
      icon = "Ability_Warrior_WarCry", fx = { power = 1 } },
    { id = "warbringer", name = "Warbringer", tier = 6, col = 2, max = 1, icon = "Ability_Warrior_Sunder",
      needs = "bannerBearer", capstone = true, fx = { power = 3 }, when = { ASSAULT } },
  },
}

local PATHFINDER = {
  kind = "Cunning",
  name = "Pathfinder",
  talents = {
    { id = "lightFeet", name = "Light Feet", tier = 1, col = 1, max = 2, icon = "Spell_Nature_Swiftness",
      fx = { rest = -1 } },
    { id = "trailwise", name = "Trailwise", tier = 1, col = 2, max = 5, icon = "Ability_Tracking",
      fx = { power = 1 }, when = { SCOUT } },
    { id = "keenEye", name = "Keen Eye", tier = 1, col = 3, max = 3, icon = "INV_Misc_Spyglass_03",
      fx = { find = { relic = 10 } } },
    { id = "duckAndWeave", name = "Duck and Weave", tier = 2, col = 1, max = 3, icon = "Ability_Rogue_Feint",
      fx = { wound = 5 } },
    { id = "hitAndRun", name = "Hit and Run", tier = 2, col = 3, max = 3, icon = "Ability_Rogue_Sprint",
      fx = { power = 1 }, when = { { maxHours = 4 } } },
    { id = "scavenger", name = "Scavenger", tier = 2, col = 4, max = 2, icon = "INV_Misc_Gear_01",
      fx = { salvage = 25 } },
    { id = "carefulHands", name = "Careful Hands", tier = 3, col = 1, max = 3, icon = "INV_Misc_Bag_11",
      fx = { gear = 10 } },
    { id = "ambusher", name = "Ambusher", tier = 3, col = 2, max = 2, icon = "Ability_Rogue_Ambush",
      needs = "trailwise", fx = { power = 1 }, when = { SCOUT } },
    { id = "lightFingers", name = "Light Fingers", tier = 3, col = 3, max = 3, icon = "INV_Misc_Food_59",
      fx = { find = { supply = 10 } } },
    { id = "slipAway", name = "Slip Away", tier = 4, col = 1, max = 3, icon = "Ability_Vanish",
      fx = { death = 5 } },
    { id = "wanderer", name = "Wanderer", tier = 4, col = 3, max = 3, icon = "INV_Misc_Map_01",
      fx = { power = 1 }, when = { { kind = { "Raid", "Rite" } } } },
    { id = "talentSpotter", name = "Talent Spotter", tier = 4, col = 4, max = 2, icon = "Ability_Hunter_SniperShot",
      fx = { find = { recruit = 25 } } },
    { id = "shadowed", name = "Shadowed", tier = 5, col = 1, max = 1, icon = "Ability_Stealth",
      needs = "slipAway", fx = { death = 25 }, when = { DEADLY } },
    { id = "masterScout", name = "Master Scout", tier = 5, col = 2, max = 2, icon = "Ability_Hunter_EagleEye",
      needs = "ambusher", fx = { power = 1 }, when = { SCOUT } },
    { id = "quickStudy", name = "Quick Study", tier = 5, col = 4, max = 2, icon = "Spell_Holy_DivineSpirit",
      fx = { xp = 5 } },
    -- once, on Scouting or on a short run (the spec's +15 on short Scouting runs counts it once)
    { id = "pathbreaker", name = "Pathbreaker", tier = 6, col = 2, max = 1, icon = "Ability_Hunter_Pathfinding",
      needs = "masterScout", capstone = true, fx = { power = 3 }, when = { SCOUT, { maxHours = 4 } } },
  },
}

local ARCANUM = {
  kind = "Lore",
  name = "Arcanum",
  talents = {
    { id = "ward", name = "Ward", tier = 1, col = 1, max = 5, icon = "Spell_Holy_PowerWordShield",
      fx = { death = 3 } },
    { id = "riteLearned", name = "Rite-learned", tier = 1, col = 2, max = 5, icon = "INV_Misc_Book_09",
      fx = { power = 1 }, when = { RITUAL } },
    { id = "studious", name = "Studious", tier = 1, col = 4, max = 2, icon = "INV_Misc_Book_11",
      fx = { xp = 5 } },
    { id = "mending", name = "Mending", tier = 2, col = 1, max = 3, icon = "Spell_Holy_Renew",
      fx = { wound = 5 } },
    { id = "longVigil", name = "Long Vigil", tier = 2, col = 3, max = 3, icon = "INV_Misc_Candle_01",
      fx = { power = 1 }, when = { { minHours = 8 } } },
    { id = "scribe", name = "Scribe", tier = 2, col = 4, max = 2, icon = "INV_Misc_Note_01",
      fx = { find = { map = 20, writ = 20 } } },
    { id = "wardedKit", name = "Warded Kit", tier = 3, col = 1, max = 2, icon = "Trade_Tailoring",
      fx = { broken = 1 } },
    { id = "insight", name = "Insight", tier = 3, col = 2, max = 3, icon = "Spell_Holy_MindVision",
      needs = "riteLearned", fx = { power = 1 }, when = { RITUAL } },
    { id = "darkBargain", name = "Dark Bargain", tier = 3, col = 3, max = 1, icon = "Spell_Shadow_DeathCoil",
      fx = { power = 3, rest = 2 } },
    { id = "spiritTether", name = "Spirit Tether", tier = 4, col = 1, max = 2, icon = "Spell_Holy_Resurrection",
      fx = { raise = 15 } },
    { id = "calmMind", name = "Calm Mind", tier = 4, col = 4, max = 2, icon = "Spell_Nature_Sleep",
      fx = { rest = -1 } },
    { id = "lastRites", name = "Last Rites", tier = 5, col = 1, max = 3, icon = "INV_Misc_Bone_HumanSkull_01",
      needs = "spiritTether", fx = { death = 10 }, when = { DEADLY } },
    { id = "highRitualist", name = "High Ritualist", tier = 5, col = 2, max = 2, icon = "INV_Misc_StoneTablet_05",
      needs = "insight", fx = { power = 1 }, when = { RITUAL } },
    { id = "soulAnchor", name = "Soul Anchor", tier = 6, col = 1, max = 1, icon = "Spell_Shadow_SoulGem",
      needs = "lastRites", capstone = true, fx = { noPerma = true }, when = { DEADLY } },
  },
}

ns.TalentData = {
  V = 1,
  TIERS = 6,
  COLS = 4,
  ORDER = { "Might", "Cunning", "Lore" },
  TREES = { Might = VANGUARD, Cunning = PATHFINDER, Lore = ARCANUM },
  BUILDS = {
    Might = {
      { name = "Strike", ranks = { thickHide = 2, drilled = 5, brawler = 3, pressTheAttack = 3, bannerBearer = 2,
        commandingPresence = 2, warbringer = 1 } },
      { name = "Guard", ranks = { thickHide = 5, drilled = 1, mailCare = 2, holdTheLine = 3, battleTested = 2,
        fieldDressing = 2, bulwark = 1, unbreakable = 2 } },
      { name = "Spoils", ranks = { thickHide = 1, drilled = 5, brawler = 1, battleTested = 2, pressTheAttack = 3,
        plunder = 2, bannerBearer = 2, spoilsOfWar = 2 } },
    },
    Cunning = {
      { name = "Strike", ranks = { lightFeet = 1, trailwise = 5, duckAndWeave = 2, hitAndRun = 3, ambusher = 2,
        wanderer = 2, masterScout = 2, pathbreaker = 1 } },
      { name = "Guard", ranks = { lightFeet = 2, trailwise = 1, keenEye = 3, duckAndWeave = 3, scavenger = 2,
        carefulHands = 3, slipAway = 3, shadowed = 1 } },
      { name = "Spoils", ranks = { lightFeet = 2, trailwise = 2, keenEye = 3, hitAndRun = 1, scavenger = 2,
        lightFingers = 3, wanderer = 1, talentSpotter = 2, quickStudy = 2 } },
    },
    Lore = {
      { name = "Strike", ranks = { ward = 3, riteLearned = 5, mending = 1, longVigil = 3, insight = 3, darkBargain = 1,
        highRitualist = 2 } },
      { name = "Guard", ranks = { ward = 5, studious = 2, mending = 3, wardedKit = 2, spiritTether = 2, lastRites = 3,
        soulAnchor = 1 } },
      { name = "Spoils", ranks = { ward = 1, riteLearned = 3, studious = 2, mending = 2, longVigil = 3, scribe = 2,
        darkBargain = 1, spiritTether = 2, calmMind = 2 } },
    },
  },
}
