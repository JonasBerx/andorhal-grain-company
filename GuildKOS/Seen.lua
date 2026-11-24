-- GuildKOS Seen: what this account saw itself of each open target (issue 44, d81/d82): its sex and level, for the
-- List's cards. Kept in GuildKOSDB.guilds[guild].seen = { [target GUID] = { sex, level, levelAt, at } } (account-wide,
-- never synced, never sent). Get's level also reads the members' sightings, which carry a level (d83). Spot.OnUnit and Mark.ReadUnit call Seen.Note(guid, unit); every client read goes through
-- ns.Hub.Call (M.Compat.call, which plains every return). Under /gsync demo nothing is read or written.
-- An officer's client also keeps the target record's level current (d82): a level it sees that differs from the
-- record's is written with Store.WriteTarget, at most once per target per UPDATE_GAP. The record format is unchanged.
local _, ns = ...
local Seen = {}
ns.Seen = Seen

Seen.UPDATE_GAP = 600       -- seconds between two level writes of one target by this client (d82)
local WEEK = 604800
local SEX = { [2] = true, [3] = true } -- UnitSex: 2 male, 3 female; 1 (unknown) is not stored

local updated = {}          -- target GUID -> time of this session's last level write
local prunedFor             -- the guild key this session pruned

local function call(...) if ns.Hub then return ns.Hub.Call(...) end end
local function now() return ns.Core and ns.Core.Now() or 0 end

local function openRec(guid)
  local rec = type(guid) == "string" and ns.Store and ns.Store.Target(guid) or nil
  if type(rec) == "table" and rec.status == "open" then return rec end
  return nil
end

-- Seen.Prune(seen, t): drops every entry that is malformed, of a target not held open, or KEEP_WEEKS weeks old.
function Seen.Prune(seen, t)
  if type(seen) ~= "table" or type(t) ~= "number" then return end
  local oldest = t - ns.RulesKills.KEEP_WEEKS * WEEK
  for guid, e in pairs(seen) do
    if type(e) ~= "table" or type(e.at) ~= "number" or e.at <= oldest or not openRec(guid) then seen[guid] = nil end
  end
end

-- This guild's seen table, pruned on the first use of a session (the saved data has arrived by then); nil while the
-- guild name is unread.
local function book()
  local g = ns.Core and ns.Core.Guild()
  if not g then return nil end
  if type(g.seen) ~= "table" then g.seen = {} end
  local gk, t = ns.Core.GuildKey(), now()
  if gk and prunedFor ~= gk and t > 0 then
    prunedFor = gk
    Seen.Prune(g.seen, t)
  end
  return g.seen
end

-- The newest level any held kos_m record's sighting of guid carries (issue 44 d83), and its time; sightings older
-- than KEEP_WEEKS weeks are not read.
local function sightingLevel(guid, t)
  local best, at
  local oldest = t - ns.RulesKills.KEEP_WEEKS * WEEK
  for _, rec in pairs(ns.Store.Members()) do
    for _, s in ipairs(type(rec.sightings) == "table" and rec.sightings or {}) do
      local when = type(s) == "table" and s.target == guid and tonumber(s.time) or nil
      local level = when and tonumber(s.level)
      if level and level >= 1 and when > oldest and (not at or when > at) then best, at = level, when end
    end
  end
  return best, at
end

-- Seen.Get(guid) -> { sex = 2|3|nil, level = number|nil, at } | nil for an open target: sex as this account saw it;
-- level the newest known, this account's own (levelAt) or any member's sighting with a level (its time), the own one
-- on a tie (d83); at the newer of the two. A new table each call. Never throws.
function Seen.Get(guid)
  if type(guid) ~= "string" then return nil end
  local good, out = pcall(function()
    local seen = book()
    if not openRec(guid) then return nil end
    local e = seen and seen[guid]
    e = type(e) == "table" and e or nil
    local level, when = sightingLevel(guid, now())
    if not e and not level then return nil end
    local r = { sex = e and e.sex, level = e and e.level, at = e and e.at }
    local own = e and (e.levelAt or e.at)
    if level and (not r.level or not own or when > own) then r.level = level end
    if when and (not r.at or when > r.at) then r.at = when end
    return r
  end)
  return good and type(out) == "table" and out or nil
end

-- d82: an officer's client writes a seen level that differs from the open record's, once per target per UPDATE_GAP.
local function update(guid, rec, level, t)
  if ns.RulesMarks.IsNameKey(guid) then return end -- a name entry's level comes with its link (Mark.Link)
  if tonumber(rec.level) == level then return end
  if updated[guid] and t - updated[guid] < Seen.UPDATE_GAP then return end
  if not ns.Store.CanWriteOfficer() then return end
  updated[guid] = t
  local copy = {}
  for k, v in pairs(rec) do copy[k] = v end
  copy.level = level
  ns.Store.WriteTarget(guid, copy, t)
end

local function note(guid, unit)
  if type(guid) ~= "string" or type(unit) ~= "string" then return end
  if not ns.Hub or ns.Hub.InDemo() then return end
  local rec = openRec(guid)
  if not rec then return end
  local sex, level = call("UnitSex", unit), call("UnitLevel", unit)
  sex = SEX[sex] and sex or nil
  level = type(level) == "number" and level >= 1 and math.floor(level) or nil -- -1: far above you, keep the older
  local seen = book()
  if not seen then return end
  local e = seen[guid]
  if not e and not sex and not level then return end
  local t = math.floor(now())
  e = type(e) == "table" and e or {}
  if sex then e.sex = sex end
  if level then e.level, e.levelAt = level, t end
  e.at = t
  seen[guid] = e
  if level then update(guid, rec, level, t) end
end

-- Seen.Note(guid, unit): unit shows the target guid; notes its sex and level when guid is an open target. Never throws.
function Seen.Note(guid, unit)
  pcall(note, guid, unit)
end

return Seen
