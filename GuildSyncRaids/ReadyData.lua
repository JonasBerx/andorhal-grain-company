local _, ns = ...
if not ns.M then return end

-- The consumable buffs the ready check looks for (S9 L2, Raids 0.5 Ready): aura spell id -> name, category, source.
-- Data only; ReadyRules.Classify reads it. Categories: flask, elixir, food, world. Forever's client data has no
-- battle or guardian elixir split (SpellCategory 2593 "Item - Elixir / Flask" is shared with flasks), so elixirs are
-- one category (d1241).
-- Source: wago.tools DB2, build 1.60.1.70374 (SpellName, SpellEffect, ItemEffect, ItemXItemEffect, ItemSparse;
-- https://wago.tools/db2/SpellName?build=1.60.1.70374), plus the Wowhead Classic spell pages
-- (https://www.wowhead.com/classic/spell=<id>) where a row cites one.
-- Method: item -> ItemXItemEffect -> ItemEffect (the use spell) -> SpellEffect Apply Aura (food: the eating aura's
-- trigger, the Well Fed aura). Every same-name variant id is listed, vanilla and Midnight-era, because DB2 cannot say
-- which one the client applies (d1242). Create Item rows (the ones named after the potion) and the eating auras are
-- never listed. A row the research could not tie to an item carries unverified = true until probe Q13 confirms it in
-- the beta.

ns.ReadyData = {
  -- flasks
  [17626] = { name = "Flask of the Titans", cat = "flask", src = "wago 1.60.1.70374 item 13510" },
  [17627] = { name = "Distilled Wisdom", cat = "flask", src = "wago 1.60.1.70374; wowhead spell=17627" },
  [17628] = { name = "Supreme Power", cat = "flask", src = "wago 1.60.1.70374 item 13512" },
  [17629] = { name = "Chromatic Resistance", cat = "flask", src = "wago 1.60.1.70374 item 13513" },
  [17624] = { name = "Petrification", cat = "flask", src = "wago 1.60.1.70374 item 13506" },

  -- elixirs (one category, d1241)
  [17538] = { name = "Elixir of the Mongoose", cat = "elixir", src = "wago 1.60.1.70374; wowhead spell=17538" },
  [16883] = { name = "Elixir of the Giants", cat = "elixir", src = "wago 1.60.1.70374 (no item join)", unverified = true },
  [17539] = { name = "Greater Arcane Elixir", cat = "elixir", src = "wago 1.60.1.70374; wowhead spell=17539" },
  [16889] = { name = "Greater Arcane Elixir", cat = "elixir", src = "wago 1.60.1.70374 (variant of 17539)" },
  [11474] = { name = "Shadow Power", cat = "elixir", src = "wago 1.60.1.70374 item 9264" },
  [5896] = { name = "Shadow Power", cat = "elixir", src = "wago 1.60.1.70374 (variant of 11474)" },
  [21920] = { name = "Frost Power", cat = "elixir", src = "wago 1.60.1.70374 (no item join)", unverified = true },
  [5866] = { name = "Frost Power", cat = "elixir", src = "wago 1.60.1.70374 (no item join)", unverified = true },
  [1310077] = { name = "Greater Firepower", cat = "elixir", src = "wago 1.60.1.70374 item 21546", unverified = true },
  [26276] = { name = "Greater Firepower", cat = "elixir", src = "wago 1.60.1.70374 (variant of 1310077)", unverified = true },
  [7844] = { name = "Fire Power", cat = "elixir", src = "wago 1.60.1.70374 item 6373" },
  [5835] = { name = "Fire Power", cat = "elixir", src = "wago 1.60.1.70374 (variant of 7844)" },
  [11348] = { name = "Greater Armor", cat = "elixir", src = "wago 1.60.1.70374 item 13445" },
  [11334] = { name = "Greater Agility", cat = "elixir", src = "wago 1.60.1.70374 item 9187" },
  [11333] = { name = "Greater Agility", cat = "elixir", src = "wago 1.60.1.70374 (variant of 11334)" },
  [11396] = { name = "Greater Intellect", cat = "elixir", src = "wago 1.60.1.70374; wowhead spell=11396" },
  [11394] = { name = "Greater Intellect", cat = "elixir", src = "wago 1.60.1.70374 (variant of 11396)" },
  [11405] = { name = "Greater Strength", cat = "elixir", src = "wago 1.60.1.70374 item 9206" },
  [17537] = { name = "Elixir of Brute Force", cat = "elixir", src = "wago 1.60.1.70374 item 13453" },
  [17535] = { name = "Elixir of the Sages", cat = "elixir", src = "wago 1.60.1.70374 item 13447" },
  [24361] = { name = "Major Troll's Blood Elixir", cat = "elixir", src = "wago 1.60.1.70374 item 20004" },
  [3223] = { name = "Troll's Blood Elixir", cat = "elixir", src = "wago 1.60.1.70374 item 3826" },
  [24363] = { name = "Mana Regeneration", cat = "elixir", src = "wago 1.60.1.70374 SpellName; guess: Mageblood", unverified = true },
  [3593] = { name = "Health II", cat = "elixir", src = "wago 1.60.1.70374 SpellName; guess: Fortitude", unverified = true },
  [16323] = { name = "Juju Power", cat = "elixir", src = "wago 1.60.1.70374 item 12451" },
  [16329] = { name = "Juju Might", cat = "elixir", src = "wago 1.60.1.70374 item 12460" },
  [16326] = { name = "Juju Ember", cat = "elixir", src = "wago 1.60.1.70374 item 12455" },
  [16325] = { name = "Juju Chill", cat = "elixir", src = "wago 1.60.1.70374 item 12457" },
  [16321] = { name = "Juju Escape", cat = "elixir", src = "wago 1.60.1.70374 item 12459" },
  [16322] = { name = "Juju Flurry", cat = "elixir", src = "wago 1.60.1.70374 item 12450" },
  [17038] = { name = "Winterfall Firewater", cat = "elixir", src = "wago 1.60.1.70374 item 12820" },
  [17205] = { name = "Winterfall Firewater", cat = "elixir", src = "wago 1.60.1.70374 (variant of 17038)" },

  -- food: the Well Fed auras (Forever's eating aura "Nutritious Food" triggers them) and Dirge's chops
  [1248422] = { name = "Well Fed (Smoked Desert Dumplings)", cat = "food", src = "wago 1.60.1.70374 item 20452 -> 1248401" },
  [1249523] = { name = "Well Fed (Grilled Squid)", cat = "food", src = "wago 1.60.1.70374 item 13928 -> 1249522" },
  [1249520] = { name = "Well Fed (Nightfin Soup)", cat = "food", src = "wago 1.60.1.70374 item 13931 -> 1249513" },
  [1248421] = { name = "Well Fed (Runn Tum Tuber Surprise)", cat = "food", src = "wago 1.60.1.70374 item 18254 -> 1248396" },
  [1248406] = { name = "Well Fed (Herb Baked Egg)", cat = "food", src = "wago 1.60.1.70374 item 6888 -> 1248377" },
  [25661] = { name = "Increased Stamina (Dirge's Kickin' Chimaerok Chops)", cat = "food", src = "wago 1.60.1.70374 item 21023 -> 25660" },
  [24870] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374; wowhead spell=24870" },
  [19705] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [19706] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [19708] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [19709] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [19710] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [19711] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [24799] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [25694] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [25941] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1225778] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1225779] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1225780] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1225782] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1248420] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1248688] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1249519] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1249521] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1249907] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1249926] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1249927] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1283082] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1294007] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1302064] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },
  [1319310] = { name = "Well Fed", cat = "food", src = "wago 1.60.1.70374 SpellName" },

  -- world buffs
  [22888] = { name = "Rallying Cry of the Dragonslayer", cat = "world", src = "wago 1.60.1.70374; wowhead spell=22888" },
  [355363] = { name = "Rallying Cry of the Dragonslayer", cat = "world", src = "wago 1.60.1.70374 (variant of 22888)" },
  [1304452] = { name = "Rallying Cry of the Dragonslayer", cat = "world", src = "wago 1.60.1.70374 (variant of 22888)" },
  [24425] = { name = "Spirit of Zandalar", cat = "world", src = "wago 1.60.1.70374; wowhead spell=24425" },
  [15366] = { name = "Songflower Serenade", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [1304690] = { name = "Songflower Serenade", cat = "world", src = "wago 1.60.1.70374 (variant of 15366)" },
  [473477] = { name = "Songflower Serenade", cat = "world", src = "wago 1.60.1.70374 (variant of 15366)" },
  [16609] = { name = "Warchief's Blessing", cat = "world", src = "wago 1.60.1.70374; wowhead spell=16609" },
  [355366] = { name = "Warchief's Blessing", cat = "world", src = "wago 1.60.1.70374 (variant of 16609)" },
  [1304594] = { name = "Warchief's Blessing", cat = "world", src = "wago 1.60.1.70374 (variant of 16609)" },
  [22817] = { name = "Fengus' Ferocity", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [1304759] = { name = "Fengus' Ferocity", cat = "world", src = "wago 1.60.1.70374 (variant of 22817)" },
  [22818] = { name = "Mol'dar's Moxie", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [1304753] = { name = "Mol'dar's Moxie", cat = "world", src = "wago 1.60.1.70374 (variant of 22818)" },
  [22820] = { name = "Slip'kik's Savvy", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [1304751] = { name = "Slip'kik's Savvy", cat = "world", src = "wago 1.60.1.70374 (variant of 22820)" },
  [23735] = { name = "Sayge's Dark Fortune of Strength", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23736] = { name = "Sayge's Dark Fortune of Agility", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23737] = { name = "Sayge's Dark Fortune of Stamina", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23738] = { name = "Sayge's Dark Fortune of Spirit", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23766] = { name = "Sayge's Dark Fortune of Intelligence", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23767] = { name = "Sayge's Dark Fortune of Armor", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23768] = { name = "Sayge's Dark Fortune of Damage", cat = "world", src = "wago 1.60.1.70374 SpellName" },
  [23769] = { name = "Sayge's Dark Fortune of Resistance", cat = "world", src = "wago 1.60.1.70374 SpellName" },
}
