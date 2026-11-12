-- GuildSyncExpeditions Words.lua (0.19 plan, Seams 18): the wording table, ns.W.
-- What the screens show in place of internal names, and the text of the expedition rows.
-- API: W.Name[internal] -> shown name, W.Time(seconds) -> string, W.Requires(level, met) -> one string,
--   W.Taken.pin / .tip / .out / .done -> words for a row sent today, home or out,
--   W.Quality(q) -> name or nil, W.Pool[region] -> entries,
--   W.RowText(row) -> title, text, place; an id ending -6 or -7 picks among the extra entries, every other id among the rest.
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

-- A row sent today whose run came home (pin, tip); why its page is off: the run is still out, or it came home.
W.Taken = {
  pin = "Done",
  tip = "Done today",
  out = "This expedition is under way.",
  done = "Done for today. New expeditions come with the daily reset.",
}

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
