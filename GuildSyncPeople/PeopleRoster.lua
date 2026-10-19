-- GuildSyncPeople: the C_Club roster read, the guild key and the calendar clock (plan Task 3, base spec items 5 and 9).
-- People reads the roster itself at each hub rosterRead, only outside the chat lockdown: a missing lockdown function
-- or a nil answer reads as in lockdown (gate A f13 ruling), and the previous read stays. Every field of a
-- ClubMemberInfo goes through GuildSync.Compat.Plain and a type check (M.Compat.call plains only the top level).
-- Rank names never go on the wire: each client shows the rank from its own read (d350).

local _, ns = ...
if not ns.M then return end

local read = { byKey = {}, byGuid = {}, count = 0 } -- the last good read
local guildKey                                       -- the plained guild name once known
local clubOf                                         -- the guild club id guildKey was read under
local seen = false                                   -- the hub fired rosterRead for People this session

local PRESENT = { [1] = true, [4] = true, [5] = true } -- Enum.ClubMemberPresence Online, Away, Busy

local function plain(v) return GuildSync.Compat.Plain(v) end
local function str(v)
  v = plain(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end
local function num(v)
  v = plain(v)
  if type(v) == "number" and v == v then return v end
  return nil
end

-- True only when the client says, plainly, that the chat lockdown is off (Hooks.lua reads it too).
function ns.Unlocked()
  local ok, locked = ns.M.Compat.Try("C_ChatInfo.InChatMessagingLockdown")
  return ok and locked == false
end

local function rgbOf(col)
  if type(col) ~= "table" then return nil end
  local r, g, b = num(col.r), num(col.g), num(col.b)
  if r and g and b then return { r = r, g = g, b = b } end
  return nil
end

local function colourOf(token)
  if token then
    local list = RAID_CLASS_COLORS
    return rgbOf(ns.M.Compat.call("C_ClassColor.GetClassColor", token))
      or rgbOf(type(list) == "table" and list[token] or nil) or { r = 1, g = 1, b = 1 }
  end
  return { r = 1, g = 1, b = 1 }
end

local function viewOf(info)
  local name, guid = str(info.name), str(info.guid)
  if not name or not guid then return nil end
  name = name:match("^([^-]+)") or name
  local key = ns.Key(name)
  if not key then return nil end
  local row = ns.Member(name)
  local token = type(row) == "table" and type(row.class) == "string" and row.class or nil
  local className, race
  local classID, raceID = num(info.classID), num(info.race)
  if classID then
    local ci = ns.M.Compat.call("C_CreatureInfo.GetClassInfo", classID)
    if type(ci) == "table" then
      className = str(ci.className)
      token = token or str(ci.classFile)
    end
  end
  if raceID then
    local ri = ns.M.Compat.call("C_CreatureInfo.GetRaceInfo", raceID)
    if type(ri) == "table" then race = str(ri.raceName) end
  end
  local order = num(info.guildRankOrder)
  local rankIndex = order and (order - 1) or (type(row) == "table" and num(row.rankIndex)) or nil
  local presence = num(info.presence)
  local online
  if presence then online = PRESENT[presence] == true else online = type(row) == "table" and row.online == true end
  return {
    key = key, name = name, guid = guid, classToken = token, className = className, race = race,
    level = num(info.level), rank = str(info.guildRank), rankIndex = rankIndex, online = online,
    colour = colourOf(token),
  }
end

-- The guild key: ClubInfo.name, else GetGuildInfo's first return, plained; read outside lockdown only.
local function readGuildKey(clubId)
  if clubId then
    local info = ns.M.Compat.call("C_Club.GetClubInfo", clubId)
    local name = type(info) == "table" and str(info.name) or nil
    if name then return name end
  end
  return str(ns.M.Compat.call("GetGuildInfo", "player"))
end

-- One read; a nil club id, a member list that is not a table or zero members keeps the previous read.
local function readRoster()
  if not ns.Unlocked() then return false end
  local clubId = num(ns.M.Compat.call("C_Club.GetGuildClubId"))
  -- a new club id, or none (not in a guild): the old key no longer holds (S-f3)
  if clubId ~= clubOf then
    guildKey, clubOf = nil, clubId
  end
  local key = readGuildKey(clubId)
  if key then guildKey = key end
  if not clubId then return false end
  local ids = ns.M.Compat.call("C_Club.GetClubMembers", clubId)
  if type(ids) ~= "table" or #ids == 0 then return false end
  local byKey, byGuid, n = {}, {}, 0
  for _, id in ipairs(ids) do
    local info = ns.M.Compat.call("C_Club.GetMemberInfo", clubId, plain(id))
    if type(info) == "table" then
      local v = viewOf(info)
      if v and not byKey[v.key] then
        byKey[v.key], byGuid[v.guid] = v, v.key
        n = n + 1
      end
    end
  end
  if n == 0 then return false end
  read = { byKey = byKey, byGuid = byGuid, count = n }
  return true
end

ns.M.On("rosterRead", function(partial)
  seen = true
  local ok = readRoster()
  if ns.RosterRead then ns.RosterRead(partial, ok) end
end)

-- ---------- reads for the other files ----------

function ns.GuildKey() return guildKey end
function ns.RosterSeen() return seen end
function ns.PeopleCount() return read.count end

-- Real data only (f9a): People's read, else the hub's roster row when a record is held for that key.
function ns.ViewOf(key)
  if type(key) ~= "string" then return nil end
  local v = read.byKey[key]
  local rec = ns.RecOf and ns.RecOf(key) or nil
  if v then
    v.rec = rec
    return v
  end
  if not (ns.HasRecord and ns.HasRecord(key)) then return nil end
  local row = ns.Member(key)
  if type(row) ~= "table" or type(row.name) ~= "string" then return nil end
  local token = type(row.class) == "string" and row.class or nil
  return { key = key, name = row.name, classToken = token, rankIndex = num(row.rankIndex), online = row.online == true,
    colour = colourOf(token), rec = rec }
end

-- The person (the alt links) for a key: the demo state's while demo is on, else GuildSync.Comm.Person's answer.
function ns.PersonOf(key)
  local on, state = ns.M.Demo()
  if on then return type(state) == "table" and type(state.persons) == "table" and state.persons[key] or nil end
  if type(key) ~= "string" then return nil end
  return ns.Person(key)
end

function ns.KeyOfGuid(guid)
  if type(guid) ~= "string" then return nil end
  return read.byGuid[guid]
end

-- The server clock for display: one GetCurrentCalendarTime() call.
function ns.Now()
  local t = ns.M.Compat.call("C_DateAndTime.GetCurrentCalendarTime")
  if type(t) ~= "table" then return { weekday = 1, hour = 0, minute = 0 } end
  return { weekday = num(t.weekday) or 1, hour = num(t.hour) or 0, minute = num(t.minute) or 0 }
end
