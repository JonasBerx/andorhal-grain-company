-- GuildKOS RulesDemo: the made-up Kill on Sight data behind /gsync demo (R6 Task I1; spec AC37, o857). Pure: Build reads
-- only the guild copy and the `now` it is handed, never the client, the clock or saved data, so the same input gives
-- equal output, and the guild copy is not changed. The answer is store-shaped (RulesRecords' fields), held by the hub
-- for the session; never saved, never sent.
--   state = { kos = { [TargetKey(guid)] = t }, kos_h = { [HunterKey(memberKey)] = h }, kos_m = { [memberKey] = m },
--     me = the demo viewer's memberKey, names = { [memberKey] = name } } (me and names only when the state is not empty)
-- The enemies are 0.3's two-part Alliance names (the demo guild is Horde): five open targets and two waiting marks.
-- Markers, claimers, witnesses and spotters are members below the top three ranks (rankIndex >= 3, o857); confirming
-- officers are the top three (rankIndex <= 2). Both are read from guild.members in sorted key order, never by name.
-- Build(guild, now, kills): the kos_h board, the target kills, the claims and the witness only when kills is true
-- (d1822, o2310; the hub passes ns.Probe.kills). Otherwise only the open targets, the waiting marks and the sightings.
local _, ns = ...
local Demo = {}
ns.RulesDemo = Demo

local DAY, WEEK = 86400, 604800
local WEEK0 = 345600 -- Monday 1970-01-05 00:00 UTC, week 0 (RulesBoard)

-- name, race, class (0.3's Alliance demo set; Snibble dropped, d336/d790)
local ENEMIES = {
  { "Aldric Vane", "Human", "Rogue" },
  { "Brenna Stoutforge", "Dwarf", "Hunter" },
  { "Elowen Duskbrook", "Night Elf", "Druid" },
  { "Fizzik Gearwhistle", "Gnome", "Mage" },
  { "Garrick Holt", "Human", "Warrior" },
  { "Thalia Moonveil", "Night Elf", "Priest" },   -- waiting mark
  { "Durgan Ironbeard", "Dwarf", "Paladin" },     -- waiting mark
}
local OPEN = 5

local WHY = { "Camps the Tarren Mill flight master", "Ganks lowbies at the crossroads", "Kills the quest giver at Hammerfall",
  "Ambushed our herbalists", "Corpse-camped a raid on the way in", "Ganked me twice at the Sepulcher",
  "Picks off our gatherers in Arathi" }
local ZONES = { "Hillsbrad Foothills", "Arathi Highlands", "Silverpine Forest", "Alterac Mountains", "The Barrens",
  "Arathi Highlands", "Hillsbrad Foothills" }

local function guid(i) return "Player-4613-" .. string.format("%08X", 4096 + i) end

-- GuildSync's Wire.Key rule: the name without a realm, spaces squeezed and trimmed, lower-cased.
local function memberKey(name)
  if type(name) ~= "string" then return nil end
  local k = (name:match("^([^-]*)") or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

-- -> members (rankIndex >= 3) and officers (rankIndex <= 2), { id, key } each, in sorted id order.
local function people(guild)
  local ids = {}
  for id, m in pairs(type(guild) == "table" and type(guild.members) == "table" and guild.members or {}) do
    if type(id) == "string" and type(m) == "table" and type(m.rankIndex) == "number" and memberKey(m.name) then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local low, top = {}, {}
  for _, id in ipairs(ids) do
    local m = guild.members[id]
    local p = { id = id, key = memberKey(m.name), name = m.name }
    if m.rankIndex >= 3 then low[#low + 1] = p else top[#top + 1] = p end
  end
  return low, top
end

-- Demo.Build(guild, now, kills) -> state. With fewer than four members below the officers, or no officer, the state is
-- empty.
function Demo.Build(guild, now, kills)
  local state = { kos = {}, kos_h = {}, kos_m = {} }
  now = math.floor(tonumber(now) or 0)
  local low, top = people(guild)
  if #low < 4 or #top < 1 or now < 30 * DAY then return state end
  local officer = top[#top].key
  -- beside the store's three: the demo viewer's key (Mine draws its marks) and each demo member's name by key, so the
  -- page shows demo members by name (f5432)
  state.me = low[1].key
  state.names = {}
  for _, list in ipairs({ low, top }) do
    for _, p in ipairs(list) do state.names[p.key] = p.name end
  end

  local function target(i) return state.kos["t" .. guid(i)] end
  local function holder(p)
    local m = state.kos_m[p.key]
    if not m then
      m = { guid = p.id, marks = {}, claims = {}, witness = {}, sightings = {} }
      state.kos_m[p.key] = m
    end
    return m
  end

  -- five open targets, decided by an officer weeks ago
  for i = 1, OPEN do
    local e = ENEMIES[i]
    local at = now - (20 + 2 * i) * DAY
    state.kos["t" .. guid(i)] = { status = "open", name = e[1], race = e[2], class = e[3], level = 60, zone = ZONES[i],
      why = WHY[i], markedBy = officer, markedAt = at, decidedBy = officer, decidedAt = at, kills = {}, rejected = {} }
  end

  -- the board: confirmed kills, written to the hunter's kos_h record and the target's kills alike. The first hunter
  -- has kills in last week and this week (a streak of two).
  local function hunter(p, kills)
    local rec = { total = #kills, best = 1, since = math.floor((kills[1].time - WEEK0) / 604800), kills = {} }
    for _, k in ipairs(kills) do
      rec.kills[#rec.kills + 1] = { time = k.time, victim = guid(k.victim), officer = officer }
      local t = target(k.victim).kills
      t[#t + 1] = { hunter = p.key, time = k.time }
    end
    state.kos_h["h" .. p.key] = rec
    return rec
  end
  if kills == true then
    local streak = low[#low]
    hunter(streak, { { victim = 1, time = now - WEEK - 3600 }, { victim = 2, time = now - 5400 } }).best = 2
    if #low >= 6 then hunter(low[#low - 1], { { victim = 3, time = now - 2 * DAY } }) end
  end

  -- two waiting marks (no kos record for their GUIDs)
  for j = 1, 2 do
    local i = OPEN + j
    local e = ENEMIES[i]
    local m = holder(low[j])
    m.marks[#m.marks + 1] = { guid = guid(i), name = e[1], race = e[2], class = e[3], level = 60, zone = ZONES[i],
      subzone = "", why = WHY[i], time = now - j * 3600 }
  end

  -- three waiting claims; the third is witnessed by another member's PARTY_KILL line
  local w = holder(low[4])
  if kills == true then
    local claims = { { low[1], 4, 9000 }, { low[2], 5, 9600 }, { low[3], 4, 7200 } }
    for _, c in ipairs(claims) do
      local m = holder(c[1])
      m.claims[#m.claims + 1] = { time = now - c[3], victim = guid(c[2]), zone = ZONES[c[2]] }
    end
    w.witness[#w.witness + 1] = { killer = low[3].id, victim = guid(4), time = now - 7200 + 2 }
  end

  -- sightings, some with a shard
  w.sightings[#w.sightings + 1] = { target = guid(1), time = now - 120, zone = "Hillsbrad Foothills",
    subzone = "Tarren Mill", shard = "12" }
  local s = holder(low[1])
  s.sightings[#s.sightings + 1] = { target = guid(3), time = now - 2400, zone = "Arathi Highlands", subzone = "" }
  return state
end

return Demo
