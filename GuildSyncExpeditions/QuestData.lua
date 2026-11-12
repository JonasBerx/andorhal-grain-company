-- GuildSyncExpeditions QuestData.lua (slice H plan, Seams 1): the writ table, ns.QuestData.
--   ns.QuestData.WRITS -> ordered rows, ns.QuestData.BY_ID[id] -> row, ns.QuestData.STORY_TITLES -> ordered { id, name }
-- Pure data, no ns.M guard (like Words.lua). A row's look, trophy and its title or badge all equal its id.
-- The texts are what a member reads. A bring writ names the mailbox and never says the goods go anywhere: the player keeps them.

local _, ns = ...

local WRITS = {
  -- go
  { id = "g1", band = 1, kind = "go", name = "Walk the ruins of Andorhal", need = 1,
    text = "The Company takes its name from Andorhal and nobody here has seen it lately. Walk the ruins and tell us what's still standing.",
    title = "g1", flairName = "Andorhal Pilgrim", look = "g1", lookName = "Grain-sack apron", tint = { r = 0.76, g = 0.65, b = 0.42 },
    trophy = "g1", trophyName = "Andorhal milestone", map = 1422, pos = { x = 0.44, y = 0.69 }, radius = 0.05, place = "Andorhal" },
  { id = "g2", band = 1, kind = "go", name = "Visit the Sepulcher", need = 1,
    text = "The Sepulcher is taking in new dead faster than it can bury them. Go and see how bad it has got.",
    badge = "g2", flairName = "Sepulcher key", look = "g2", lookName = "Bone mask", tint = { r = 0.85, g = 0.81, b = 0.68 },
    trophy = "g2", trophyName = "Sepulcher lamp", map = 1421, place = "the Sepulcher" },
  { id = "g3", band = 1, kind = "go", name = "Watch from Thoradin's Wall", need = 1,
    text = "Someone ought to stand on Thoradin's Wall and see who is moving through Arathi. It may as well be you.",
    badge = "g3", flairName = "Wall stone", look = "g3", lookName = "Raven-feather hood", tint = { r = 0.30, g = 0.34, b = 0.48 },
    trophy = "g3", trophyName = "Thoradin's banner", map = 1417, place = "Thoradin's Wall" },
  { id = "g4", band = 1, kind = "go", name = "Light a candle at Darrowshire", need = 1,
    text = "Darrowshire lost everyone it had, and some of them were ours once. Go and light a candle, and don't expect thanks.",
    title = "g4", flairName = "Gravewalker", look = "g4", lookName = "Violet sash", tint = { r = 0.58, g = 0.36, b = 0.80 },
    trophy = "g4", trophyName = "Darrowshire candle", map = 1423, pos = { x = 0.34, y = 0.82 }, radius = 0.05, place = "Darrowshire" },

  -- bring
  { id = "b1", band = 1, kind = "bring", name = "Linen for the Company's bandages", need = 20,
    text = "The Deathguard are holding themselves together with twine again. Carry linen to a mailbox so the clerk can count it.",
    badge = "b1", flairName = "Spindle", look = "b1", lookName = "Linen wraps", tint = { r = 0.82, g = 0.77, b = 0.62 },
    trophy = "b1", trophyName = "Bandage basket", item = 2589, itemName = "Linen Cloth" },
  { id = "b2", band = 1, kind = "bring", name = "Wool for the winter stores", need = 10,
    text = "The silos want lining before the frost gets into the grain. Bring wool to a mailbox and we'll put it on the books.",
    badge = "b2", flairName = "Wool bale", look = "b2", lookName = "Woolen scarf", tint = { r = 0.62, g = 0.55, b = 0.46 },
    trophy = "b2", trophyName = "Wool bale", item = 2592, itemName = "Wool Cloth" },
  { id = "b3", band = 1, kind = "bring", name = "Copper for the mill", need = 20,
    text = "The mill's gears are worn down to nubs and the smith won't touch them without copper. Take the ore to a mailbox to be weighed.",
    badge = "b3", flairName = "Ore cart", look = "b3", lookName = "Copper pauldrons", tint = { r = 0.76, g = 0.46, b = 0.26 },
    trophy = "b3", trophyName = "Copper ingot stack", item = 2770, itemName = "Copper Ore" },
  { id = "b4", band = 1, kind = "bring", name = "Peacebloom for the apothecaries", need = 10,
    text = "The apothecaries ran out of peacebloom and have started asking about the garden. Bring a bundle to a mailbox for the tally.",
    title = "b4", flairName = "Company Herbalist", look = "b4", lookName = "Flower crown", tint = { r = 0.85, g = 0.55, b = 0.66 },
    trophy = "b4", trophyName = "Pressed peacebloom", item = 2447, itemName = "Peacebloom" },

  -- kill
  { id = "k1", band = 1, kind = "kill", name = "Thin the Scarlet ranks", need = 10,
    text = "The Crusade keeps marching fresh recruits into Tirisfal and the Deathguard are tired of it. Thin them out.",
    title = "k1", flairName = "Scarlet Bane", look = "k1", lookName = "Deathguard tabard", tint = { r = 0.46, g = 0.30, b = 0.50 },
    trophy = "k1", trophyName = "Scarlet banner", npcs = { 1506, 1507, 1535, 1536, 1537, 1538, 1539, 1540 } },
  { id = "k2", band = 1, kind = "kill", name = "Rot Hide gnolls", need = 8,
    text = "The Rot Hide keep digging up graves in Silverpine. Put down enough of them that the rest take the hint.",
    badge = "k2", flairName = "Gnoll fang", look = "k2", lookName = "Fur collar", tint = { r = 0.58, g = 0.42, b = 0.28 },
    trophy = "k2", trophyName = "Gnoll skull", npcs = { 1772, 1773, 1939, 1940, 1942, 1943, 1944 } },
  { id = "k3", band = 1, kind = "kill", name = "Syndicate in the hills", need = 10,
    text = "Syndicate cutpurses have moved into the Hillsbrad foothills and our carts keep coming back light. Find them and settle the account.",
    badge = "k3", flairName = "Syndicate mask", look = "k3", lookName = "Black hood", tint = { r = 0.32, g = 0.32, b = 0.36 },
    trophy = "k3", trophyName = "Syndicate dagger", npcs = { 2240, 2241, 2244, 2260, 2261 } },
  { id = "k4", band = 1, kind = "kill", name = "Clear the Andorhal fields", need = 10,
    text = "The Scourge are still walking the fields at Andorhal as if they'd paid for them. Clear them off the land.",
    title = "k4", flairName = "Field Warden", look = "k4", lookName = "Brass pauldrons", tint = { r = 0.78, g = 0.63, b = 0.30 },
    trophy = "k4", trophyName = "Scourge skull", npcs = { 1783, 1784, 1787, 1788, 1789, 1791, 1793, 1794, 1795, 1796 } },

  -- talk: a list, so a vendor found in the beta can be added as data
  { id = "t1", band = 1, kind = "talk", name = "Report to Bethor Iceshard", need = 1,
    text = "Bethor Iceshard wants a report from the Company and doesn't like waiting. Find him in the Undercity and tell him what you've seen.",
    badge = "t1", flairName = "Arcane seal", look = "t1", lookName = "Ember-red scarf", tint = { r = 0.85, g = 0.32, b = 0.18 },
    trophy = "t1", trophyName = "Iceshard's letter", npcs = { 1498 }, who = "Bethor Iceshard" },
  { id = "t2", band = 1, kind = "talk", name = "Samples for Master Apothecary Faranell", need = 1,
    text = "Master Apothecary Faranell has asked about the Company's grain samples twice now. Go down to the Apothecarium before he comes looking.",
    badge = "t2", flairName = "Vial", look = "t2", lookName = "Plague-green cloak", tint = { r = 0.52, g = 0.70, b = 0.26 },
    trophy = "t2", trophyName = "Corked vial", npcs = { 2055 }, who = "Master Apothecary Faranell" },
  { id = "t3", band = 1, kind = "talk", name = "A word with High Executor Darthalia", need = 1,
    text = "High Executor Darthalia wants a word about Company wagons on the Hillsbrad roads. Go to Tarren Mill and keep it civil.",
    title = "t3", flairName = "Company Envoy", look = "t3", lookName = "Deathguard sash", tint = { r = 0.60, g = 0.42, b = 0.58 },
    trophy = "t3", trophyName = "Sealed orders", npcs = { 2215 }, who = "High Executor Darthalia" },
  { id = "t4", band = 1, kind = "talk", name = "Orders from Executor Zygand", need = 1,
    text = "Executor Zygand has orders for the Company and trusts no courier with them. Go to Brill and collect them yourself.",
    badge = "t4", flairName = "Brill seal", look = "t4", lookName = "Bat-leather belt", tint = { r = 0.42, g = 0.30, b = 0.28 },
    trophy = "t4", trophyName = "Zygand's orders", npcs = { 1515 }, who = "Executor Zygand" },
}

local BY_ID = {}
for _, w in ipairs(WRITS) do BY_ID[w.id] = w end

ns.QuestData = {
  WRITS = WRITS,
  BY_ID = BY_ID,
  STORY_TITLES = {
    { id = "company-hand", name = "Company Hand" },
    { id = "road-warden", name = "Road Warden" },
    { id = "charter-bearer", name = "Charter Bearer" },
    { id = "keeper-ledger", name = "Keeper of the Ledger" },
  },
}
