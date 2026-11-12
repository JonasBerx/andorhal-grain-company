-- GuildSyncExpeditions Demo.lua: what /gsync demo shows.
--   ns.DemoState(guild, now) -> the demo state: one table per part, keyed like GuildSyncExpeditionsDB, plus guildRows
--   ns.DemoGuildRows() -> the demo's guildRows as fresh copies | nil        nil when demo is off or the state has none
-- ns.Part hands out a fresh checked copy of a part on every call. Session only: never saved, never sent. guildRows is not
-- a part: records live raw and ns.GuildRecords is {} in demo, so the Guild page and the camp's count read it from here.

local _, ns = ...

if not ns.M then return end
local M = ns.M

local HOUR = 3600
local OUT_FOR = 8040 -- Grubb is due back in 2 h 14 min
local SET = "Ambermill Warding"
local GUILD_ROWS = 4

local function code(slot, tier, q)
  local GD = ns.GearData
  local row = GD.Find(slot, tier, q) or GD.Find(slot, tier, 2)
  return row and row.code
end

local function follower(id, name, race, class, sex, level, xp, origin, stats)
  return { id = id, name = name, race = race, class = class, sex = sex, level = level, xp = xp, traits = {}, state = "idle",
    origin = origin, renamed = false, reserve = false, gear = {},
    stats = { runs = stats[1], wins = stats[2], deadly = stats[3], wounds = stats[4], raised = stats[5] } }
end

local function demoFollowers(now)
  local rows = {
    follower(1, "Vesper", "Forsaken", "Paladin", "f", 10, 0, "hire", { 46, 39, 3, 6, 0 }),
    follower(2, "Grubb", "Troll", "Priest", "m", 9, 210, "hire", { 31, 24, 1, 5, 1 }),
    follower(3, "Ishka", "Tauren", "Druid", "f", 8, 90, "hire", { 22, 15, 0, 4, 0 }),
    follower(4, "Thrak", "Orc", "Warrior", "m", 6, 40, "recruit", { 12, 8, 0, 2, 0 }),
    follower(5, "Mordessa", "Forsaken", "Rogue", "f", 9, 120, "recruit", { 27, 21, 1, 3, 0 }),
  }
  rows[1].traits, rows[1].look = { "veteran", "deadly", "grave" }, "g1"
  rows[2].state, rows[2].untilT = "out", now + OUT_FOR
  rows[3].state = "dead"
  rows[4].reserve, rows[5].reserve = true, true
  return { next = 6, rows = rows }
end

-- Worn pieces are bag rows with no cell: ids 1..16, one per slot, the first two set pieces in their own slots.
local function demoBag(vesper)
  local GD = ns.GearData
  local rows, set = {}, {}
  for _, r in ipairs(GD.ROWS) do
    if r.set == SET and #set < 2 then
      set[#set + 1] = r
      set[r.slot] = r.code
    end
  end
  for i, slot in ipairs(GD.SLOTS) do
    rows[i] = { id = i, row = set[slot.key] or code(slot.key, 2, i % 3 == 1 and 3 or 2), temper = i % 4 == 0 and 2 or 0 }
    vesper.gear[slot.key] = i
  end
  local id, cell = #rows, 0
  local function put(row)
    id, cell = id + 1, cell + 1
    row.id, row.cell = id, cell
    rows[id] = row
  end
  put({ row = code("feet", 2, 2), broken = true, temper = 0 })
  put({ row = code("hands", 1, 1), temper = 3 })
  put({ row = code("legs", 2, 3), temper = 0 })
  put({ kind = "salvage", key = 1, n = 24 })
  put({ kind = "salvage", key = 2, n = 9 })
  for _, s in ipairs({ { "rations", 6 }, { "bandage", 5 }, { "whetstone", 3 }, { "candle", 2 }, { "scoutchart", 2 }, { "gravemoss", 1 } }) do
    put({ kind = "supply", key = s[1], n = s[2] })
  end
  put({ kind = "relic", key = "t1", n = 2 })
  return { next = id + 1, rows = rows }
end

-- Grubb's run, on the first shared Silverpine row of the demo day.
local function demoRun(day, now)
  local RC, BC = ns.RiskCore, ns.BoardCore
  local row
  for _, r in ipairs(BC.Rows(day, ns.Regions.Open(), { "tirisfal" }, {})) do
    if r.region == "silverpine" and not r.capstone then row = r break end
  end
  local ends = now + OUT_FOR
  return { id = 1, fid = 2, rowId = row.id, region = row.region, kind = row.kind, hours = row.hours, level = row.level,
    danger = row.danger, start = ends - row.hours * HOUR, ends = ends, seed = 1, rest = 4,
    chances = RC.Chances(85, 81, row.danger, { {}, {}, {}, {} }), supplies = {} }
end

-- race, the index of the name in ns.LootData.NAMES, class, sex, level, state, wins, deadly
local CREWS = {
  { { "Forsaken", 4, "Mage", "m", 10, "i", 41, 3 }, { "Orc", 3, "Warrior", "m", 9, "o", 30, 1 }, { "Troll", 2, "Hunter", "m", 7, "b", 14, 0 } },
  { { "Tauren", 1, "Shaman", "f", 9, "r", 33, 2 }, { "Forsaken", 5, "Priest", "f", 8, "i", 21, 0 } },
  { { "Troll", 3, "Rogue", "f", 10, "i", 38, 4 }, { "Orc", 4, "Warlock", "f", 6, "i", 9, 0 }, { "Tauren", 2, "Hunter", "m", 5, "o", 6, 0 } },
  { { "Forsaken", 6, "Warlock", "f", 8, "i", 19, 1 } },
}
local CREW_SLOTS = { "head", "chest", "legs", "mainhand" }

local function crewPieces(level)
  local pieces = {}
  local tier = level >= 6 and 2 or 1
  for _, slot in ipairs(CREW_SLOTS) do pieces[slot] = { row = code(slot, tier, 2), temper = 0, broken = false } end
  return pieces
end

local function crewFollowers(spec)
  local out = {}
  for i, c in ipairs(spec) do
    out[i] = { name = ns.LootData.NAMES[c[1]][c[2]], race = c[1], class = c[3], sex = c[4], level = c[5], state = c[6],
      wins = c[7], deadly = c[8], look = i == 1 and "g2" or nil, traits = {}, pieces = crewPieces(c[5]) }
  end
  return out
end

local function demoGuildRows(guild, now, day)
  local names = {}
  for _, m in pairs(guild.members) do names[#names + 1] = m.name end
  table.sort(names)
  local out = {}
  for n = 1, math.min(GUILD_ROWS, #names) do
    local name, key = names[n], GuildSync.Comm.Key(names[n])
    local crew = crewFollowers(CREWS[n])
    out[n] = { key = key, group = key, rev = now - n * HOUR, hash = "", owner = name, view = {
      followers = crew,
      flair = { title = "g1", badges = { "g2" }, trophies = { "g1", "g2" }, quests = 2 },
      collection = { relics = 7 },
      finds = { { code = code("wrist", 2, 3), who = crew[1].name, day = math.max(0, day - n + 1), region = "silverpine" } },
    } }
  end
  return out
end

function ns.DemoState(guild, now)
  local BC = ns.BoardCore
  local reset = M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset")
  local day = BC.Day(now, reset) or 0
  local followers = demoFollowers(now)
  local run = demoRun(day, now)
  local blue = code("wrist", 2, 3)
  return {
    followers = followers,
    runs = { next = 2, rows = { [1] = run } },
    board = { day = day, rows = { [run.rowId] = { fid = 2 } } },
    bag = demoBag(followers.rows[1]),
    packed = { rows = { [1] = { "rations", "bandage" } } },
    maps = { rows = { tirisfal = {} } },
    relics = { rows = { t1 = {}, t2 = {}, s1 = {} } },
    chains = { rows = { [1] = { row = "o7", temper = 0 } } },
    quests = { rows = { g2 = { id = "g2", progress = 0 }, b1 = { id = "b1", progress = 12 }, k1 = { id = "k1", progress = 6 } } },
    flair = { title = "g1", rows = { g1 = { id = "g1" }, ["company-hand"] = { id = "company-hand" } } },
    finds = { next = 3, rows = {
      [1] = { id = 1, row = blue, fid = 1, day = day, region = "silverpine" },
      [2] = { id = 2, row = blue, fid = 5, day = day, region = "tirisfal" },
    } },
    story = { chapter = 2, step = 2, sentDay = 0 },
    traitc = { rows = { [1] = { grave = 2, shaken = 0, streak = 1 } } },
    history = { next = 5, rows = {
      [1] = { kind = "story", c = 2, s = 1, who = "Vesper", res = "succ", t = now },
      [2] = { kind = "writ", wid = "g1", who = "Vesper", res = "complete", t = now - 86400 },
      [3] = { kind = "expedition", title = "Bones at Agamand Mills", who = "Grubb", res = "failw", t = now - 86400 },
      [4] = { kind = "expedition", title = "Clearing Stillwater", who = "Ishka", res = "dead", t = now - 3 * 86400 },
    } },
    guildRows = demoGuildRows(guild, now, day),
  }
end

local function deepCopy(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then out[k] = deepCopy(v) else out[k] = v end
  end
  return out
end

function ns.DemoGuildRows()
  local on, state = M.Demo()
  if not on or type(state) ~= "table" or type(state.guildRows) ~= "table" then return nil end
  return deepCopy(state.guildRows)
end
