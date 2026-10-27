-- GuildSync DemoGuild: the made-up guild behind /gsync demo (t40 R5). Pure: Build(now) reads no roster, no clock and
-- no saved data, only the `now` it is given, so the same `now` gives equal tables. The shapes are the ones Roster.lua
-- writes (GuildSyncDB3.guild and .guildLog), so every page draws it through its normal view code.
-- GUIDs are Demo-NNNN, never the client's Player-... shape, so no demo row can match a real member.
-- Forever raises on division by zero: every divisor below is a constant (the generator modulus, 3600, or the length of
-- a fixed, non-empty list), never a count.
-- Loads in the game (TOC, after Core.lua) and outside it (dofile from the test simulator): ns is set only when given.

local _, ns = ...

local floor = math.floor
local format = string.format
local insert = table.insert
local sort = table.sort

local DemoGuild = {}

local GUILD_NAME = "Andorhal Demo Company"
local RANKS = { "Guild Master", "Overseer", "Officer", "Raider", "Field Hand", "Member", "Trial", "Alt" }

-- 30 first names, one per member, so no two names are equal; surnames come from the generator.
local FIRST = { "Mordra", "Silas", "Veyna", "Garrick", "Ophelia", "Thane", "Lirien", "Cassius", "Morwen", "Edric",
  "Isolde", "Barnaby", "Seraphine", "Doran", "Agnes", "Lucan", "Rowena", "Tobias", "Hilde", "Corvin",
  "Elspeth", "Aldous", "Maren", "Fenwick", "Ysolde", "Gideon", "Brannagh", "Osric", "Wilhelmina", "Jasper" }
local SURNAME = { "Blackmoor", "Ashveil", "Grimsby", "Thornwood", "Hollowell", "Duskmantle", "Ravenhill", "Coldbrook",
  "Marrow", "Fenwright", "Gravesend", "Pellham", "Mistvale", "Harrow", "Wychwood", "Barrowe" }
-- Former members, named only in the log (they quit or were removed).
local FORMER = { "Corwin Ashgrave", "Hesper Vane" }

local CLASSES = { "WARRIOR", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local RACES = { "Forsaken", "Orc", "Tauren", "Troll" }
local NOTE_TAILS = { "raids Tue", "main", "alt", "casual", "PvP", "farmer", "new" }
local LEVELS = { 60, 60, 60, 60, 60, 60, 60, 60, 59, 58, 55, 52, 48, 44, 38, 31, 24, 17 }
local ZONES = { "Undercity", "Orgrimmar", "Tirisfal Glades", "Western Plaguelands", "Silverpine Forest",
  "Thunder Bluff", "The Barrens", "Eastern Plaguelands" }
local PROFS = { { id = 171, name = "Alchemy" }, { id = 164, name = "Blacksmithing" }, { id = 333, name = "Enchanting" },
  { id = 202, name = "Engineering" }, { id = 182, name = "Herbalism" }, { id = 165, name = "Leatherworking" },
  { id = 186, name = "Mining" }, { id = 393, name = "Skinning" }, { id = 197, name = "Tailoring" } }
local OFFICER_NOTES = { "", "", "", "trial week 2", "loot council", "bank alt" }

-- The guild log: type, actor index (nil for join and quit), target (member index or a FORMER name), hours ago.
local LOG = {
  { "join", nil, 30, 3 }, { "invite", 2, 30, 4 }, { "promote", 1, 12, 9 }, { "join", nil, 29, 20 },
  { "invite", 3, 29, 21 }, { "quit", nil, FORMER[1], 30 }, { "demote", 2, 17, 46 }, { "promote", 2, 8, 70 },
  { "remove", 1, FORMER[2], 95 }, { "join", nil, 28, 120 }, { "invite", 2, 28, 121 }, { "promote", 3, 21, 150 },
}

-- Park-Miller: x * 16807 stays below 2^46, exact in doubles. Seeded with a constant: no math.random, no clock.
local function generator()
  local x = 20260407
  return function(n) -- 1..n, n a constant list length
    x = x * 16807 % 2147483647
    return x % n + 1
  end
end

local function pick(nextInt, list) return list[nextInt(#list)] end

-- -> guild, log, in the shapes Roster.lua writes (no `by`, no `partial`). `now` only places the log's times.
function DemoGuild.Build(now)
  local nextInt = generator()
  local members, names = {}, {}
  for i = 1, #FIRST do
    local name = FIRST[i] .. " " .. pick(nextInt, SURNAME)
    names[i] = name
    local rankIndex
    if i == 1 then rankIndex = 0 elseif i <= 3 then rankIndex = 1 else rankIndex = nextInt(6) + 1 end
    local online = i % 4 == 1
    local p1 = nextInt(#PROFS)
    local p2 = nextInt(#PROFS)
    local m = {
      name = name,
      rank = RANKS[rankIndex + 1],
      rankIndex = rankIndex,
      level = pick(nextInt, LEVELS),
      class = pick(nextInt, CLASSES),
      online = online,
      note = pick(nextInt, RACES) .. ", " .. pick(nextInt, NOTE_TAILS),
      officerNote = pick(nextInt, OFFICER_NOTES),
      prof1 = { id = PROFS[p1].id, name = PROFS[p1].name, rank = nextInt(300) },
    }
    if p2 ~= p1 then m.prof2 = { id = PROFS[p2].id, name = PROFS[p2].name, rank = nextInt(300) } end
    if online then m.zone = pick(nextInt, ZONES) else m.lastOnlineDays = nextInt(40) - 1 end
    members[format("Demo-%04d", i)] = m
  end

  local hour = floor(now / 3600 + 0.5) * 3600 -- Roster.lua:97 rounds every log time to the hour
  local entries = {}
  for _, e in ipairs(LOG) do
    local target = e[3]
    if type(target) == "number" then target = names[target] end
    insert(entries, { type = e[1], actor = e[2] and names[e[2]] or nil, target = target,
      rank = (e[1] == "promote" or e[1] == "demote") and members[format("Demo-%04d", e[3])].rank or nil,
      ts = hour - e[4] * 3600 })
  end

  local guild = { name = GUILD_NAME, realm = "Demo", ranks = {}, canSeeOfficerNotes = true, members = members,
    count = #FIRST }
  for i, r in ipairs(RANKS) do guild.ranks[i] = r end
  return guild, { entries = entries }
end

-- The Modules page's Guildmates counts in demo (d408; the approved mock's), each capped at the demo guild's count.
DemoGuild.SUITE_HEARD = { guildsync = 24, people = 12, annals = 15, kos = 9, raids = 5, bank = 3, board = 0, crafting = 7, games = 6 }

-- The Guildmates tab's made-up adverts, keyed by key(name): members in GUID order, the first SUITE_HEARD.guildsync
-- (capped) heard this week, each module on the first SUITE_HEARD[id] of them, so View.SuiteHeard over it gives
-- SUITE_HEARD; of the rest, half heard weeks ago on an older version, half never heard.
function DemoGuild.SuiteVersions(guild, now, key)
  local guids = {}
  for guid in pairs(type(guild) == "table" and type(guild.members) == "table" and guild.members or {}) do
    insert(guids, guid)
  end
  sort(guids)
  local week = math.min(DemoGuild.SUITE_HEARD.guildsync, #guids)
  local out = {}
  for i, guid in ipairs(guids) do
    local m = guild.members[guid]
    local k = key(m.name)
    if k and i <= week then
      local mods = {}
      for id, n in pairs(DemoGuild.SUITE_HEARD) do
        if id ~= "guildsync" and i <= n then mods[id] = "0.13.0" end
      end
      -- online members "now", the rest spread over the last six days
      out[k] = { name = m.name, addon = "0.13.0", seen = m.online and now or now - (i % 6 + 1) * 86400 + i * 600,
        mods = mods }
    elseif k and i <= week + floor((#guids - week) / 2) then
      out[k] = { name = m.name, addon = "0.12.0", seen = now - (10 + i) * 86400 }
    end
  end
  return out
end

-- -> every member name of guild and every name its log can carry (members and FORMER), sorted.
function DemoGuild.Names(guild)
  local list = {}
  if type(guild) == "table" and type(guild.members) == "table" then
    for _, m in pairs(guild.members) do insert(list, tostring(m.name)) end
  end
  for _, name in ipairs(FORMER) do insert(list, name) end
  sort(list)
  return list
end

if ns then ns.DemoGuild = DemoGuild end
return DemoGuild
