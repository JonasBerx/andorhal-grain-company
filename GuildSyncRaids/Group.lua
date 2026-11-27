local _, ns = ...
if not ns.M then return end
-- Group.lua: F (shared pieces C and D). The group this character is in: its kind (ns.GroupKind), its roster
-- (ns.RaidRoster), who leads it (ns.Leads, ns.MayEdit) and the ready check's sender rule (ns.LeadsMyRaid, moved from
-- Ready.lua's askerLeads). No UI. Every game call goes through M.Compat.call / Try (values already plain); unit
-- reads happen only out of combat, and a secret is never compared or indexed.

local M = ns.M
local Has = GuildSync.Compat.Has
local call, Try = M.Compat.call, M.Compat.Try

local MAXROWS = 40
local RAID = {}
for i = 1, MAXROWS do RAID[i] = "raid" .. i end
local PARTY = { "player", "party1", "party2", "party3", "party4" }

-- The last good roster read (out of combat), or nil. Answered in combat while the group kind is the same.
local last

-- "raid", "party" or nil. Not identity-restricted, so valid in combat.
function ns.GroupKind()
  if Has("IsInRaid") then
    if call("IsInRaid") == true then return "raid" end
  else
    local inRaid = call("UnitInRaid", "player") -- a local: a call that answers nothing would leave type() no argument
    if type(inRaid) == "number" then return "raid" end
  end
  if Has("GetNumGroupMembers") then
    local n = call("GetNumGroupMembers")
    if type(n) == "number" and n > 0 then return "party" end
  elseif call("UnitExists", "party1") == true then
    return "party"
  end
  return nil
end

-- The wire key and name ("First Second") of a unit whose two name parts are plain strings, or nil.
local function unitKey(unit)
  local first, second = call("UnitName", unit)
  if type(first) ~= "string" or type(second) ~= "string" then return nil end
  local name = first .. " " .. second
  return ns.Key(name), name
end

local function newRow(unit, group, online)
  local key, name = unitKey(unit)
  if not key then return nil end
  local guid = call("UnitGUID", unit)
  if type(guid) ~= "string" then guid = nil end
  return { name = name, key = key, unit = unit, guid = guid, group = group, online = online }
end

-- A fresh list of fresh rows, so a caller may sort it or add fields.
local function copyList(src)
  local out = { at = src.at, kind = src.kind }
  for i, r in ipairs(src) do
    out[i] = { name = r.name, key = r.key, unit = r.unit, guid = r.guid, group = r.group, online = r.online }
  end
  return out
end

local function readRaid(list)
  local n = call("GetNumGroupMembers")
  if type(n) ~= "number" or n > MAXROWS then n = MAXROWS end
  for i = 1, n do
    -- ok, name, rank, subgroup (3rd value), level, class, fileName, zone, online (8th value)
    local r = { Try("GetRaidRosterInfo", i) }
    local group = r[4]
    if r[1] and type(group) == "number" and group == math.floor(group) and group >= 1 and group <= 8 then
      local online = r[9] == true or r[9] == 1
      local row = newRow(RAID[i], group, online)
      if row then list[#list + 1] = row end
    end
  end
end

local function readParty(list)
  local hasConn = Has("UnitIsConnected")
  for _, unit in ipairs(PARTY) do
    if unit == "player" or call("UnitExists", unit) == true then
      local online = true
      if hasConn then online = call("UnitIsConnected", unit) == true end
      local row = newRow(unit, 1, online)
      if row then list[#list + 1] = row end
    end
  end
end

-- { { name, key, unit, guid, group, online }, ..., at, kind }, or nil and why ("no group", "combat", "no api").
-- In combat: a copy of the last good read and "combat" when its kind matches. Every answer is a fresh copy.
function ns.RaidRoster()
  local kind = ns.GroupKind()
  if not kind then
    last = nil
    return nil, "no group"
  end
  if call("InCombatLockdown") ~= false then
    if last and last.kind == kind then return copyList(last), "combat" end
    return nil, "combat"
  end
  local list = { kind = kind }
  if kind == "raid" then
    if not Has("GetRaidRosterInfo") then return nil, "no api" end
    readRaid(list)
  else
    readParty(list)
  end
  local at = call("GetServerTime")
  if type(at) == "number" then list.at = at end
  last = list
  return copyList(list)
end

-- In a raid: the leader or an assistant. In a party: the leader only. Solo: false. Plain true only.
function ns.Leads(unit)
  local kind = ns.GroupKind()
  if kind == "raid" then
    return call("UnitIsGroupLeader", unit) == true or call("UnitIsGroupAssistant", unit) == true
  elseif kind == "party" then
    return call("UnitIsGroupLeader", unit) == true
  end
  return false
end

-- An officer, or the player leads the group.
function ns.MayEdit()
  if ns.IsOfficer(ns.MyKey()) then return true end
  return ns.Leads("player")
end

-- The ready check's sender rule (was Ready.lua askerLeads): from is the key of a raid unit that is the leader or an
-- assistant (plain true).
function ns.LeadsMyRaid(from)
  if type(from) ~= "string" then return false end
  for _, unit in ipairs(RAID) do
    if (call("UnitIsGroupLeader", unit) == true or call("UnitIsGroupAssistant", unit) == true)
      and unitKey(unit) == from then
      return true
    end
  end
  return false
end
