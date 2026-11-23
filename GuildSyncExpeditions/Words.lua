-- GuildSyncExpeditions Words.lua (0.19 plan, Seams 18): the wording table, ns.W.
-- What the screens show in place of internal names, and the text of the expedition rows.
-- API: W.Name[internal] -> shown name, W.Time(seconds) -> string, W.Requires(level, met) -> one string,
--   W.Taken.pin / .tip / .out / .done -> words for a row sent today, home or out,
--   W.Quality(q) -> name or nil, W.Pool[region] -> entries, W.PackRefused[why] -> the line for a refused ns.PackSupply,
--   W.RowText(row) -> title, text, place; an id ending -6 or -7 picks among the extra entries, every other id among the rest.
--   W.Talent (the talent window's texts), W.TalentFx[talent id] -> format string for the effect at a rank (one %d: the
--   talent's amount per rank times the rank; a text with no %d is the same at every rank), W.TalentsToSpend(n) -> line.
-- Pure: string and math only, no client calls, no random, no clock. Sets no ns.M, so it loads on its own.
-- B1 files read ns.W at call time, never at file scope: this file loads after them.

local _, ns = ...

local W = {}
ns.W = W

W.Name = {
  ["kit score"] = "Gear Score",
  ["piece value"] = "Item Level",
  Raid = "Assault",
  Scout = "Scouting",
  Rite = "Ritual",
  raid = "Assault",
  scout = "Scouting",
  rite = "Ritual",
  capstone = "Dungeon",
  ["Iron salvage"] = "Iron Scrap",
  ["Rusted salvage"] = "Rusted Scrap",
  idle = "Ready",
  out = "Away",
  resting = "Resting",
  rest = "Resting",
  ["in reserve"] = "Reserve",
  ["Company bag"] = "Storage",
  shop = "Quartermaster",
  T1 = "Level 1-5",
  T2 = "Level 6-10",
  ["death share"] = "Death chance",
}

-- Why ns.PackSupply refused; the Barracks and a quest page say the same.
W.PackRefused = {
  two = "That follower already carries two supplies.",
  same = "That follower already carries one of those.",
  none = "You have none of those.",
}

-- A row sent today whose run came home (pin, tip); why its page is off: the run is still out, or it came home.
W.Taken = {
  pin = "Done",
  tip = "Done today",
  out = "This expedition is under way.",
  done = "Done for today. New expeditions come with the daily reset.",
}

-- The talent window (TalentWindow.lua) and the Followers tab's Talents button, card tip and header line.
local DOT = " \194\183 " -- a middle dot between spaces, as a byte escape: this file stays ASCII
W.Talent = {
  button = "Talents",
  points = "Talent points: %d" .. DOT .. "%d in %s",
  who = "%s" .. DOT .. "Level %d %s",
  rank = "Rank %d/%d",
  nextRank = "Next rank:",
  tier = "Requires %d points in %s talents",
  needs = "Requires %d points in %s",
  needsOne = "Requires %d point in %s",
  learn = "Learn",
  reset = "Reset",
  resetPrice = "Reset" .. DOT .. "%d grain",
  cancel = "Cancel",
  ask = "Reset %s's talents for %d grain?",
  hint = "Left-click adds a rank, right-click takes one back.",
  -- What a refused Learn, Reset or take-back says in the window. A grain refusal reads ns.GrainLine instead.
  refuse = {
    busy = "This follower is out on an expedition. Learn and Reset wait until they are home.",
    learnNone = "Nothing new to learn: spend a point first.",
    resetNone = "No talents are learned, so there is nothing to reset.",
    demo = "Talents are not kept in the demo.",
    learned = "A learned rank only comes back through a reset.",
    other = "That cannot be done now.",
  },
}

W.TalentFx = {
  -- Vanguard
  thickHide = "-%d%% wound chance",
  drilled = "+%d Power on Assaults",
  mailCare = "-%d%% gear break chance",
  holdTheLine = "-%d%% death chance",
  brawler = "+%d Power on Scouting and Rituals",
  battleTested = "+%d%% XP",
  fieldDressing = "Wounds rest %d h less",
  pressTheAttack = "+%d Power on Dangerous and Deadly Assaults",
  plunder = "+%d%% grain from wins",
  bulwark = "-%d%% death chance on Deadly runs",
  bannerBearer = "+%d Power on Assaults",
  spoilsOfWar = "Finds green gear %d%% more often",
  unbreakable = "-%d%% chance gear breaks or is lost",
  commandingPresence = "+%d Power on every expedition",
  warbringer = "+%d Power on Assaults",
  -- Pathfinder
  lightFeet = "Wounds rest %d h less",
  trailwise = "+%d Power on Scouting",
  keenEye = "Finds relics %d%% more often",
  duckAndWeave = "-%d%% wound chance",
  hitAndRun = "+%d Power on runs of 4 hours or less",
  scavenger = "+%d%% salvage",
  carefulHands = "-%d%% chance gear breaks or is lost",
  ambusher = "+%d Power on Scouting",
  lightFingers = "Finds supplies %d%% more often",
  slipAway = "-%d%% death chance",
  wanderer = "+%d Power on Assaults and Rituals",
  talentSpotter = "Finds recruits %d%% more often",
  shadowed = "-%d%% death chance on Deadly runs",
  masterScout = "+%d Power on Scouting",
  quickStudy = "+%d%% XP",
  pathbreaker = "+%d Power on Scouting and on runs of 4 hours or less",
  -- Arcanum
  ward = "-%d%% death chance",
  riteLearned = "+%d Power on Rituals",
  studious = "+%d%% XP",
  mending = "-%d%% wound chance",
  longVigil = "+%d Power on runs of 8 hours or more",
  scribe = "Finds maps and writs %d%% more often",
  wardedKit = "-%d%% gear break chance",
  insight = "+%d Power on Rituals",
  darkBargain = "+3 Power on every expedition; wounds rest 2 h longer",
  spiritTether = "Raising costs %d%% less grain",
  calmMind = "Wounds rest %d h less",
  lastRites = "-%d%% death chance on Deadly runs",
  highRitualist = "+%d Power on Rituals",
  soulAnchor = "A death on a Deadly run is never permanent",
}

function W.TalentsToSpend(n)
  if n == 1 then return "1 talent point to spend" end
  return n .. " talent points to spend"
end

local QUALITY = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare" }

-- Floored to whole minutes; nil or negative reads as under a minute. Minutes are dropped once there is a day.
function W.Time(seconds)
  local total = math.floor((seconds or 0) / 60)
  if total < 1 then return "< 1 min" end
  local days = math.floor(total / 1440)
  local hours = math.floor(total / 60) % 24
  local mins = total % 60
  if days > 0 then
    local line = days .. (days == 1 and " day" or " days")
    if hours > 0 then line = line .. " " .. hours .. " hr" end
    return line
  end
  if hours == 0 then return mins .. " min" end
  if mins == 0 then return hours .. " hr" end
  return hours .. " hr " .. mins .. " min"
end

-- One value, so it can go straight into SetText or AddLine.
function W.Requires(level, met)
  local line = "Requires Level " .. level
  if met then return line end
  return "|cffff2020" .. line .. "|r"
end

function W.Quality(q)
  return QUALITY[q]
end

W.Pool = {
  tirisfal = {
    { kind = "Raid", title = "Scarlet Stragglers", place = "Solliden Farmstead",
      text = "Scarlet converts are camped in the Solliden fields, praying over burnt pumpkins. Run them off before they march on Brill." },
    { kind = "Raid", title = "Burn the Watch Post", place = "Scarlet Watch Post",
      text = "The Crusade has put up a new tower over the east road. Burn it before they finish the roof." },
    { kind = "Raid", title = "Bones at Agamand Mills", place = "Agamand Mills",
      text = "Rattlecage skeletons are up and walking at the Mills, and they don't answer to anyone. Break them down and bring back the skulls." },
    { kind = "Raid", title = "Clearing Stillwater", place = "Stillwater Pond",
      text = "Vile Fin murlocs are fouling the pond the apothecaries draw from. Clear the banks and leave the bodies where the rest can see them." },
    { kind = "Raid", title = "The Bulwark Holds", place = "The Bulwark",
      text = "Scourge patrols keep slipping past the Bulwark at night. Hold the road until the Deathguard change shifts." },
    { kind = "Scout", title = "Lights at Garren's Haunt", place = "Garren's Haunt",
      text = "The farmers swear they've seen lanterns moving in the old Garren house at night. Find out who's carrying them. Don't stay for supper." },
    { kind = "Scout", title = "Smoke at Cold Hearth", place = "Cold Hearth Manor",
      text = "Someone has been lighting fires at Cold Hearth Manor. It's been empty since the plague. Go and see who they are, and count them." },
    { kind = "Scout", title = "Tracks at Brightwater", place = "Brightwater Lake",
      text = "A Deathguard patrol found boot prints on the north shore. Scarlet, most likely. Follow them and see where they go." },
    { kind = "Scout", title = "Count the Wagons", place = "Scarlet Watch Post",
      text = "Wagons keep going up the road to the Monastery. Count them, find out what they're carrying, and don't get seen." },
    { kind = "Rite", title = "Rest for Deathknell", place = "Deathknell",
      text = "Not everyone we dig up in Deathknell wants to join us. Say the rites over the ones that keep clawing back out." },
    { kind = "Rite", title = "Blood for the Apothecarium", place = "Crusader Outpost",
      text = "The Royal Apothecary Society wants Scarlet blood, and it has to be fresh. The Crusader Outpost has plenty of it walking around." },
    { kind = "Rite", title = "Salt for Balnir", place = "Balnir Farmstead",
      text = "The dead at Balnir won't lie down and they won't get up. Salt the rows and say the words. Bring your own salt." },
    { kind = "Rite", title = "Ashes for Brill", place = "Deathknell",
      text = "The undertakers in Brill want ashes from the Deathknell chapel for their rites. The chapel is still standing. Mostly." },
    { kind = "Rite", title = "Names in Nightmare Vale", place = "Nightmare Vale",
      text = "Nightmare Vale is full of our own who never woke right. Put them down and say their names, if you can find out what they were." },
    -- Easy rows -6 and -7 only (W.RowText).
    { extra = true, kind = "Raid", title = "Duskbats at Solliden", place = "Solliden Farmstead",
      text = "Duskbats roost in the Solliden barn and go for anyone crossing the fields at dusk. Clear the rafters and bring the wings to the apothecaries." },
    { extra = true, kind = "Raid", title = "Wolves on the Brill Road", place = "Cold Hearth Manor",
      text = "Young wolves hunt the road below Cold Hearth Manor, and they've grown bold. Thin the pack so the carts get through." },
    { extra = true, kind = "Scout", title = "The Gravedigger's Walk", place = "Stillwater Pond",
      text = "A gravedigger from Brill walked out to Stillwater Pond two days ago and hasn't come back. Find him. If he's lying down, check twice." },
    { extra = true, kind = "Scout", title = "Fresh Horses", place = "Crusader Outpost",
      text = "The Crusader Outpost has twice the horses it had last week. Find out who rode in, and which way they mean to ride next." },
    { extra = true, kind = "Rite", title = "The Agamand Crypt", place = "Agamand Mills",
      text = "The Agamands won't stay in the family crypt north of the Mills. Seal the doors again and say the rites over each of them by name." },
    { extra = true, kind = "Rite", title = "Water from Brightwater", place = "Brightwater Lake",
      text = "The apothecaries want water from the middle of Brightwater Lake, where the plague never reached. Fill the casks and say the words over each one." },
    { capstone = true, title = "Ruins of Lordaeron", place = "Tirisfal Glades",
      text = "Something still walks the throne room above the Undercity. The Dark Lady wants it gone before it finds the way down." },
  },
  silverpine = {
    { kind = "Raid", title = "Trouble at Fenris Keep", place = "Fenris Isle",
      text = "Rot Hide gnolls have dug in at Fenris Keep, and they've started digging up our dead. Cross to the isle and put a stop to it." },
    { kind = "Raid", title = "Moonrage at Olsen's Farthing", place = "Olsen's Farthing",
      text = "A Moonrage pack has moved into the Farthing and the Deathstalkers have lost two scouts to it. Go in and thin them out." },
    { kind = "Raid", title = "Carts on the Dead Field", place = "The Dead Field",
      text = "The Rot Hide have a camp on the Dead Field and they've got hold of our supply carts. Get the carts back and burn the camp." },
    { kind = "Raid", title = "The Coast Road", place = "South Tide's Run",
      text = "Murlocs keep coming up from South Tide's Run and cutting the coast road. Drive them back into the water." },
    { kind = "Raid", title = "Nests in Deep Elem", place = "Deep Elem Mine",
      text = "Moss Stalkers have nested in Deep Elem Mine, and the Sepulcher needs the ore. Burn the nests and mark the shaft." },
    { kind = "Scout", title = "What Pyrewood Guards", place = "Pyrewood Village",
      text = "Pyrewood's folk turn wolf at night, and they've got a watch on the town by day. Find out what they're guarding." },
    { kind = "Scout", title = "A Look Over the Wall", place = "The Greymane Wall",
      text = "Gilneas has kept its gate shut for years. Someone says it opened last week. Climb up and look." },
    { kind = "Scout", title = "One Courier Short", place = "The Skittering Dark",
      text = "Two couriers went into the Skittering Dark and one came out talking nonsense. Find the other one, or what's left." },
    { kind = "Scout", title = "Sails off the Strand", place = "The Shining Strand",
      text = "A ship has been anchored off the Strand for three nights. Find out whose it is and what it's waiting for." },
    { kind = "Scout", title = "Silence at the Orchard", place = "Malden's Orchard",
      text = "The Deathguard at Malden's Orchard have stopped sending reports. Go and see why, and stay off the road." },
    { kind = "Rite", title = "Unpicking the Wards", place = "Ambermill",
      text = "Dalaran's mages have warded the road east of Ambermill. Take the wards apart before anyone in the town notices." },
    { kind = "Rite", title = "Last Crossing", place = "The Decrepit Ferry",
      text = "The old ferry crew still work their route, and nobody has told them they're dead. Say the rites and cut the rope." },
    { kind = "Rite", title = "Wards of Our Own", place = "Beren's Peril",
      text = "Dalaran isn't the only one who can draw a circle. Set our wards along the road and stay until they hold." },
    { kind = "Rite", title = "Room at the Sepulcher", place = "The Sepulcher",
      text = "The Sepulcher is full, and the new dead won't stay in the old ground. Mark out the east field and say the words so it holds them." },
    { kind = "Rite", title = "Washed Ashore", place = "North Tide's Hollow",
      text = "Something keeps washing up at North Tide's Hollow and walking inland. Find where it comes ashore and close the grave." },
    -- Easy rows -6 and -7 only (W.RowText).
    { extra = true, kind = "Raid", title = "Fence at the Orchard", place = "Malden's Orchard",
      text = "Rot Hide scouts keep testing the fence at Malden's Orchard. Break up their camp in the trees before the rest of the pack follows." },
    { extra = true, kind = "Raid", title = "Huts on the Strand", place = "The Shining Strand",
      text = "Murlocs have put up new huts along the Shining Strand, right across the runners' path. Knock them down and drive the builders back into the sea." },
    { extra = true, kind = "Scout", title = "The Ambermill Carts", place = "Ambermill",
      text = "The mages at Ambermill buy only from their own carts now. Find out what those carts bring in, and from where." },
    { extra = true, kind = "Scout", title = "Boats off Fenris", place = "Fenris Isle",
      text = "Someone has been rowing out to Fenris Isle after dark. Watch the shore for a night and come back with a count and a direction." },
    { extra = true, kind = "Rite", title = "The Farthing Graves", place = "Olsen's Farthing",
      text = "The graves behind the Farthing were dug in a hurry during the plague. Walk the rows and say the words over each one, so nothing digs itself back up." },
    { extra = true, kind = "Rite", title = "Ash on the Dead Field", place = "The Dead Field",
      text = "The Dead Field earned its name. Burn the bones the gnolls have dug up and say the rites over the ash." },
    { capstone = true, title = "Shadowfang Keep", place = "Silverpine Forest",
      text = "Arugal's worgen hold the keep above Pyrewood. Go in, take what you can carry, and walk back out." },
  },
  hillsbrad = {
    { kind = "Raid", title = "Fields of Hillsbrad", place = "Hillsbrad Fields",
      text = "Hillsbrad's farmers still grow for Southshore's tables. Burn the barns and send the farmhands running." },
    { kind = "Raid", title = "The Azurelode Dig", place = "Azurelode Mine",
      text = "Southshore's miners have reopened Azurelode. Drive them out, and the ore is ours to weigh." },
    { kind = "Raid", title = "Naga on the Strand", place = "Eastern Strand",
      text = "Daggerspine naga have come out of the water on the Eastern Strand. Push them back before they reach the road." },
    { kind = "Raid", title = "Torches at Nethander Stead", place = "Nethander Stead",
      text = "The Syndicate hide what they take from our carts at Nethander Stead. Go in after dark and take it back." },
    { kind = "Raid", title = "The Southshore Road", place = "Southshore",
      text = "Southshore's militia patrol the road to the Mill. Break the patrol and let the wagons through." },
    { kind = "Scout", title = "Count the Walls", place = "Durnholde Keep",
      text = "The Syndicate hold Durnholde now. Count their guards and their gates, and don't be seen doing it." },
    { kind = "Scout", title = "Lights on Purgation Isle", place = "Purgation Isle",
      text = "Fires burn on Purgation Isle every night. Find out who keeps them lit." },
    { kind = "Scout", title = "The Dun Garok Garrison", place = "Dun Garok",
      text = "Ironforge has doubled the garrison at Dun Garok. Find out why, and how many." },
    { kind = "Scout", title = "Two Roads at Southpoint", place = "Southpoint Tower",
      text = "Southpoint Tower looks down both roads into Silverpine. Climb up and see who uses them." },
    { kind = "Scout", title = "Darrow Hill at Dusk", place = "Darrow Hill",
      text = "Someone has been watching Tarren Mill from Darrow Hill. Find their camp before they find ours." },
    { kind = "Rite", title = "The Tarren Mill Graves", place = "Tarren Mill",
      text = "The Mill's old graves were never blessed for the dead who rise. Walk the rows and say the words." },
    { kind = "Rite", title = "Salt on the Strand", place = "Western Strand",
      text = "The sea keeps giving back the drowned on the Western Strand. Lay them out and send them on." },
    { kind = "Rite", title = "Jars for the Apothecaries", place = "Hillsbrad Fields",
      text = "The Royal Apothecaries want soil from Hillsbrad's fields. Fill the jars and keep them sealed." },
    { kind = "Rite", title = "Ashes at Azurelode", place = "Azurelode Mine",
      text = "Miners died in Azurelode when the plague came. Burn what is left of them before it walks." },
    { kind = "Rite", title = "A Circle at Dun Garok", place = "Dun Garok",
      text = "The old dead under Dun Garok are restless. Mark a circle at the gate and hold it until dawn." },
    -- Easy rows -6 and -7 only (W.RowText).
    { extra = true, kind = "Raid", title = "Wolves at the Mill Gate", place = "Tarren Mill",
      text = "Grey wolves have started taking the Mill's mules. Clear the hills above the gate." },
    { extra = true, kind = "Raid", title = "Murlocs in the Shallows", place = "Western Strand",
      text = "Torn Fin murlocs nest in the shallows by the Western Strand. Break the nests." },
    { extra = true, kind = "Scout", title = "Boats at Southshore", place = "Southshore",
      text = "Count the boats in Southshore's harbour and note which ones are new." },
    { extra = true, kind = "Scout", title = "Cart Tracks to Durnholde", place = "Durnholde Keep",
      text = "Follow the cart tracks from the road to Durnholde and see where they turn in." },
    { extra = true, kind = "Rite", title = "Candles in the Fields", place = "Hillsbrad Fields",
      text = "Light candles at the burned farms in the Fields and say the names we know." },
    { extra = true, kind = "Rite", title = "The Drowned Farmhand", place = "Eastern Strand",
      text = "A farmhand washed up on the Eastern Strand and will not stay down. Give him the rites." },
    { capstone = true, title = "Durnholde Keep", place = "Hillsbrad Foothills",
      text = "The Syndicate lords sit behind Durnholde's walls with our stolen grain in the cellars. Break in, empty the cellars, and walk out." },
  },
}

-- row.story rows draw ns.StoryStep() and never come here. The same id always gets the same entry.
-- An easy row (-6, -7) picks among the extra entries: of its kind, else all of them, else as any other row.
function W.RowText(row)
  local entries = W.Pool[row.region]
  if not entries then return "Expedition", "", "" end
  local id = tostring(row.id)
  local slot = id:match("^%a+%-%d+%-(%d+)$")
  local easy = slot == "6" or slot == "7"
  local all, matched, extraAll, extraMatched = {}, {}, {}, {}
  local kind = type(row.kind) == "string" and row.kind:lower() or nil
  for _, entry in ipairs(entries) do
    if row.capstone and entry.capstone then return entry.title, entry.text, entry.place end
    if not entry.capstone then
      local a, m = all, matched
      if entry.extra == true then a, m = extraAll, extraMatched end
      a[#a + 1] = entry
      if entry.kind:lower() == kind then m[#m + 1] = entry end
    end
  end
  local list = #matched > 0 and matched or all
  if easy and #extraAll > 0 then list = #extraMatched > 0 and extraMatched or extraAll end
  if #list == 0 then return "Expedition", "", "" end
  local sum = 0
  for i = 1, #id do sum = sum + string.byte(id, i) end
  local picked = list[sum % #list + 1]
  return picked.title, picked.text, picked.place
end
