local _, ns = ...
if not ns.M then return end

-- The pull recorder (S9 L1, Raids 0.5 Pulls): out of combat in a party or raid instance it keeps the last snapshot of
-- the group (PullRules.Snapshot); ENCOUNTER_START stores one pull in ns.DB().pulls and ENCOUNTER_END closes it
-- (PullRules.Start / End). Also ns.PullList (the pulls the Pulls tab shows, demo or saved), the login prune and
-- /gsraids pulls. Nothing is sent. While /gsync demo is on the recorder records nothing (d1237).

local M = ns.M
local PullRules = ns.PullRules
local Plain = GuildSync.Compat.Plain
local call = M.Compat.call

-- Memory only: the last good snapshot and its time, whether a fight is on (set by ENCOUNTER_START), and whether a
-- pull was stored since the last redraw.
local snap, snapAt, inEncounter, dirty

local function now() return Plain(call("GetServerTime")) end

-- The units a snapshot reads: raid1-40 in a raid, else the player and party1-4.
local RAID, PARTY = {}, { "player", "party1", "party2", "party3", "party4" }
for i = 1, 40 do RAID[i] = "raid" .. i end

local function inGroupInstance()
  local _, kind = call("IsInInstance")
  return kind == "party" or kind == "raid"
end

-- Reads the group only when every answer says it is safe: plain false for combat and encounter (anything else, a
-- secret or a missing function included, counts as in a fight), no START seen without its END, in an instance.
-- A dropped snapshot keeps the last good one and its time.
local function snapshot()
  if inEncounter or not inGroupInstance() then return end
  if call("InCombatLockdown") ~= false then return end
  if call("C_InstanceEncounter.IsEncounterInProgress") ~= false then return end
  local inRaid = call("UnitExists", "raid1")
  local units
  if inRaid == true then units = RAID elseif inRaid == false then units = PARTY else return end
  local reads = {}
  for i, unit in ipairs(units) do
    local exists = call("UnitExists", unit)
    local r = { exists = exists }
    if exists == true then
      r.guid = call("UnitGUID", unit)
      r.first, r.second = call("UnitName", unit)
    end
    reads[i] = r
  end
  local people = PullRules.Snapshot(reads)
  if people then snap, snapAt = people, now() end
end

-- After a stored pull, redraws the Raids page (only when it is the shown page) once out of combat (23.pulls-redraw).
local function redraw()
  if not dirty or call("InCombatLockdown") ~= false then return end
  dirty = nil
  M.RefreshPage()
end

function ns.OnPullEvent(event, ...)
  -- d1237: demo records nothing (no read, no snapshot, no pull); the fight flag still follows START, END and zoning,
  -- so a fight that ends in demo does not block snapshots after demo off.
  local demo = M.Demo()
  if event == "ENCOUNTER_START" then
    inEncounter = true
    if demo then return end
    local t = now()
    if type(t) == "number" then
      PullRules.Start(ns.DB().pulls, snap, snapAt, { ... }, t, Plain)
      dirty = true
    end
  elseif event == "ENCOUNTER_END" then
    inEncounter = nil
    if demo then return end
    local t = now()
    if type(t) == "number" then
      PullRules.End(ns.DB().pulls, { ... }, t, Plain)
      dirty = true
    end
    redraw()
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- R-f4: a new zone drops the held snapshot first, so zoning in demo never carries the old group past demo off
    inEncounter, snap, snapAt = nil, nil, nil
    if demo then return end
    if inGroupInstance() then snapshot() end
  elseif not demo then -- GROUP_ROSTER_UPDATE, PLAYER_REGEN_ENABLED
    snapshot()
    if event == "PLAYER_REGEN_ENABLED" then redraw() end
  end
end

-- The pulls the Pulls tab shows: the demo's made-up ones while demo is on, else the saved list.
function ns.PullList()
  if ns.DemoData then
    local d = ns.DemoData()
    if d then return d.pulls or {} end
  end
  return ns.DB().pulls
end

-- Login: drop pulls older than 35 days and broken entries.
function ns.PullsLogin()
  local t = now()
  if type(t) ~= "number" then return end
  local db = ns.DB()
  db.pulls = PullRules.Prune(db.pulls, t)
end

-- /gsraids pulls: the last 5 saved pulls (never the demo's), boss names escaped.
function ns.PullsChat()
  local list = {}
  for _, p in ipairs(ns.DB().pulls) do
    if type(p) == "table" then
      local q = {}
      for k, v in pairs(p) do q[k] = v end
      if type(q.name) == "string" then q.name = ns.Escape(q.name) end
      list[#list + 1] = q
    end
  end
  for _, line in ipairs(PullRules.ChatLines(list, 5, ns.When)) do ns.Say("Raids: " .. line) end
end
