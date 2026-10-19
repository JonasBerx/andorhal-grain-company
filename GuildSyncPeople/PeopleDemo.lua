-- GuildSyncPeople: profiles over the hub's made-up guild for /gsync demo (plan Task 7, base spec item 36).
-- Pure: no guard, no client call, no global outside the Annals allow-list (check-rules/GuildSyncPeople.json).
-- Build(guild, now) reads only what it is given (the hub's DemoGuild copy, members keyed Demo-NNNN) and never changes
-- it: the same guild and now give equal tables. Members sorted by guid; member i gets a race from a fixed Horde list
-- and, when i mod 3 ~= 0, a profile (20 of 30) from fixed notes, tag sets and hours, editedAt = now - i hours.
-- "You" is the first member. The state lives in the hub's demo session only: never saved, never sent.
-- persons (the alt links, GuildSync.Comm.Person's shape) are the mock's people found by name (NOTES-o696 "The data");
-- when one name is missing, members 2 to 5 by guid take their places. mine (M.MyCharacters' shape) is fixed.

local _, ns = ...

local Demo = {}
ns.Demo = Demo

local RACES = { "Undead", "Orc", "Tauren", "Troll" }

local CLASS = {
  WARRIOR = { "Warrior", 0.78, 0.61, 0.43 }, HUNTER = { "Hunter", 0.67, 0.83, 0.45 },
  ROGUE = { "Rogue", 1, 0.96, 0.41 }, PRIEST = { "Priest", 1, 1, 1 }, SHAMAN = { "Shaman", 0, 0.44, 0.87 },
  MAGE = { "Mage", 0.25, 0.78, 0.92 }, WARLOCK = { "Warlock", 0.53, 0.53, 0.93 }, DRUID = { "Druid", 1, 0.49, 0.04 },
  PALADIN = { "Paladin", 0.96, 0.55, 0.73 },
}

-- Calendar weekdays (1 = Sunday, as PeopleRules' DAYS).
local MONFRI, SATSUN = { 2, 3, 4, 5, 6 }, { 7, 1 }

-- Fixed profiles (the approved mock's notes first), handed out in turn to the members that carry one.
local PROFILES = {
  { note = "Healer for raids, happy to help with Scholo runs. Ask me about herbs. Usually on after work, weekends all day.",
    tags = { "ra", "du", "pr", "so", "sh" },
    spans = { { MONFRI, 19, 23 }, { SATSUN, 14, 24 } } },
  { note = "Raid leader for Molten Core and Onyxia. Feral or resto, whatever the night needs. Skinning and leather on request.",
    tags = { "ra", "pr", "co", "rp" },
    spans = { { { 2, 4, 6 }, 19, 23 } } },
  { note = "Main tank. Ask before you pull. Dungeon runs any night; I bring flasks on raid nights.",
    tags = { "pe", "ra", "du", "gm" },
    spans = { { { 2, 3, 4, 5 }, 18, 22 }, { { 1 }, 16, 20 } } },
  { note = "New here and still levelling. Free water and food at the bank, just whisper me.",
    tags = { "lv", "pr", "so" },
    spans = { { SATSUN, 10, 18 } } },
  { note = "Lockboxes opened for free at the Undercity bank. Out in Hillsbrad most evenings, always up for a fight.",
    tags = { "pv", "wp", "sh" },
    spans = { { MONFRI, 19, 23 } } },
  { note = "Battlegrounds every weekend. Looking for a premade for Warsong Gulch.",
    tags = { "pv", "so" },
    spans = { { SATSUN, 12, 22 } } },
  { note = "Farming herbs and selling flasks. Whisper me for prices.",
    tags = { "pr", "gm" },
    spans = { { { 3, 5 }, 20, 24 } } },
  { note = "Collecting mounts and rare pets. Always happy to chat in guild.",
    tags = { "co", "rp", "so" },
    spans = { { MONFRI, 17, 20 }, { { 7 }, 9, 13 } } },
}

local function maskOf(spans)
  local mask
  for _, s in ipairs(spans) do
    for _, weekday in ipairs(s[1]) do
      for hour = s[2], s[3] - 1 do mask = ns.Rules.Set(mask, weekday, hour, true) end
    end
  end
  return mask
end

local function copy(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

-- The mock's people: a main, its alts, and a member who claims the main without being listed back.
local MAIN, ALTS, CLAIMS = "Seraphine Ravenhill", { "Wilhelmina Ravenhill", "Corvin Wychwood" }, "Tobias Marrow"

-- "Your characters" (rp-6): name, level, class, hidden, main. The pick stays automatic.
local MINE = { { "Ayanna Dawnguard", 60, "PRIEST", false, true }, { "Mortis Vale", 58, "ROGUE", true, false },
  { "Seska Moonhorn", 33, "SHAMAN", false, false } }

local function charOf(row) return { key = row.key, name = row.name, level = row.level, class = row.class } end

local function charsOf(list)
  local out = {}
  for i, row in ipairs(list) do out[i] = charOf(row) end
  return out
end

-- rows = the members by guid ({ key, name, level, class }) -> { [key] = person }
local function personsOf(rows)
  local byName = {}
  for _, row in ipairs(rows) do byName[row.name] = row end
  local main, alts, claimant = byName[MAIN], {}, byName[CLAIMS]
  for i, n in ipairs(ALTS) do alts[i] = byName[n] end
  if not (main and alts[1] and alts[2] and claimant) then
    main, alts, claimant = rows[2], { rows[3], rows[4] }, rows[5]
  end
  local persons = {}
  if not main then return persons end
  table.sort(alts, function(a, b)
    if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
    return a.key < b.key
  end)
  local group = { main }
  for _, row in ipairs(alts) do group[#group + 1] = row end
  for _, row in ipairs(group) do
    persons[row.key] = { key = row.key, main = main.key, chars = charsOf(group), unconfirmed = {} }
  end
  if claimant then
    persons[claimant.key] = { key = claimant.key, main = claimant.key, chars = { charOf(claimant) },
      unconfirmed = { charOf(main) } }
  end
  return persons
end

local function mineOf()
  local chars = {}
  for i, m in ipairs(MINE) do
    chars[i] = { key = string.lower(m[1]), name = m[1], level = m[2], class = m[3], hidden = m[4], main = m[5] }
  end
  return { chars = chars }
end

-- -> { views = { [key] = view }, me = key, persons = { [key] = person }, mine = { chars, pick } }, or nil when guild
-- holds no members.
function Demo.Build(guild, now)
  if type(guild) ~= "table" or type(guild.members) ~= "table" then return nil end
  now = math.floor(tonumber(now) or 0)
  local guids = {}
  for gid in pairs(guild.members) do
    if type(gid) == "string" then guids[#guids + 1] = gid end
  end
  table.sort(guids)
  local views, me, given, rows = {}, nil, 0, {}
  for i, gid in ipairs(guids) do
    local m = guild.members[gid]
    if type(m) == "table" and type(m.name) == "string" and m.name ~= "" then
      local key = string.lower(m.name)
      local class = CLASS[m.class] or { nil, 1, 1, 1 }
      local view = {
        key = key, name = m.name, classToken = m.class, className = class[1], race = RACES[i % #RACES + 1],
        level = m.level, rank = m.rank, rankIndex = m.rankIndex, online = m.online == true,
        colour = { r = class[2], g = class[3], b = class[4] },
      }
      if i % 3 ~= 0 then
        local p = PROFILES[given % #PROFILES + 1]
        given = given + 1
        view.rec = { version = 1, editedAt = now - i * 3600, mask = maskOf(p.spans), tags = copy(p.tags), note = p.note }
      end
      views[key] = view
      me = me or key
      rows[#rows + 1] = { key = key, name = m.name, level = m.level, class = m.class }
    end
  end
  return { views = views, me = me, persons = personsOf(rows), mine = mineOf() }
end
