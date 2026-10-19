-- GuildSyncBank ranks: who is a bank character (brief B4, B5; J22's "waiting for rank names").
-- A bank character is a roster member whose rank name is BANKER (any case) and who counts as officer under the hub's
-- rule (GuildSync.Comm.IsOfficer). Rank names come from C_Club on the hub's rosterRead, every field through
-- GuildSync.Compat.Plain; this character's own rank from GetMemberInfoForSelf at login and on rosterRead. Never read
-- on message arrival. A read in chat lockdown (secret fields) or a partial roster keeps the last map and the saved
-- set, never an empty set.
-- Saved: GuildSyncBankDB.ranks = { map = { [rankIndex] = name }, bank = { [key] = true } }.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local BANKER = "banker"
local Ranks = {}
ns.Ranks = Ranks
Ranks.BANKER = BANKER -- the Banker rank name, lower case; Health.lua compares against it

local myRank      -- this character's rank name, this session
local changed = {} -- OnChange listeners, in registration order

local function plain(v) return GuildSync.Compat.Plain(v) end
local function saved() return ns.DB().ranks end

local function clubId() return plain(M.Compat.call("C_Club.GetGuildClubId")) end

-- rankIndex -> name for every index in need, or nil when any one could not be read.
local function readMap(need)
  local map, missing = {}, 0
  for _ in pairs(need) do missing = missing + 1 end
  local club = clubId()
  local ids = club and plain(M.Compat.call("C_Club.GetClubMembers", club))
  if type(ids) == "table" then
    for _, id in ipairs(ids) do
      if missing == 0 then break end
      id = plain(id)
      local info = id and plain(M.Compat.call("C_Club.GetMemberInfo", club, id))
      if type(info) == "table" then
        local name, order = plain(info.guildRank), plain(info.guildRankOrder)
        if type(name) == "string" and type(order) == "number" and need[order - 1] and not map[order - 1] then
          map[order - 1] = name
          missing = missing - 1
        end
      end
    end
  end
  if missing > 0 and GuildSync.Compat.Has("GuildControlGetRankName") then
    for ri in pairs(need) do
      if not map[ri] then
        local name = plain(M.Compat.call("GuildControlGetRankName", ri + 1))
        if type(name) == "string" and name ~= "" then
          map[ri] = name
          missing = missing - 1
        end
      end
    end
  end
  if missing > 0 then return nil end
  return map
end

local function onRosterRead(partial)
  Ranks.ReadSelf()
  if not partial then
    local rows = GuildSync.Comm.Roster()
    local need = {}
    for _, row in pairs(rows) do
      if type(row.rankIndex) == "number" then need[row.rankIndex] = true end
    end
    local db = saved()
    local map = readMap(need)
    if map then db.map = map end
    if type(db.map) == "table" and next(db.map) ~= nil then
      local bank = {}
      for key, row in pairs(rows) do
        local name = db.map[row.rankIndex]
        if type(name) == "string" and name:lower() == BANKER and GuildSync.Comm.IsOfficer(key) then bank[key] = true end
      end
      db.bank = bank
    end
  end
  for i = 1, #changed do M.Safe(changed[i]) end
end

-- "noroster": the roster is read and holds nobody; "waiting": no roster yet, or no rank names ever read; "ready".
function Ranks.State()
  local rows, _, _, known = GuildSync.Comm.Roster()
  if not known then return "waiting" end
  if next(rows) == nil then return "noroster" end
  local map = saved().map
  if type(map) == "table" and next(map) ~= nil then return "ready" end
  return "waiting"
end

function Ranks.IsBankChar(key)
  local bank = saved().bank
  return type(bank) == "table" and key ~= nil and bank[key] == true
end

function Ranks.Mine()
  return myRank, GuildSync.Comm.IsOfficer(GuildSync.Comm.MyKey() or "")
end

function Ranks.ReadSelf()
  local club = clubId()
  local info = club and plain(M.Compat.call("C_Club.GetMemberInfoForSelf", club))
  if type(info) ~= "table" then return end
  local name = plain(info.guildRank)
  if type(name) == "string" then myRank = name end
end

function Ranks.Who(key)
  return { key = key, bank = Ranks.IsBankChar(key), officer = GuildSync.Comm.IsOfficer(key) }
end

function Ranks.Ctx(now)
  return {
    now = now,
    me = GuildSync.Comm.MyKey(),
    roster = (GuildSync.Comm.Roster()),
    isBankChar = Ranks.IsBankChar,
    isOfficer = function(key) return GuildSync.Comm.IsOfficer(key) end,
    keyOf = GuildSync.Comm.Key,
    limits = ns.LIMITS,
  }
end

function Ranks.RanksLine()
  if Ranks.State() ~= "ready" then return "waiting for rank names" end
  return nil
end

function Ranks.OnChange(fn)
  if type(fn) ~= "function" then error("ns.Ranks.OnChange: the listener is not a function", 2) end
  changed[#changed + 1] = fn
end

M.On("rosterRead", onRosterRead)
ns.Listen("login", function() Ranks.ReadSelf() end)
