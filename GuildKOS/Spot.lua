-- GuildKOS Spot: sightings and alerts (R6 Task E; spec AC21-AC23, plan f5217, f5219, f5227, d794, d795).
-- Core's dispatcher calls Spot.OnUnit(event, unit, guid) with the GUID already plain (a secret reaches here as nil)
-- and Spot.OnZone() on ZONE_CHANGED_NEW_AREA. Every client read goes through ns.Hub.Call (the handle's M.Compat.call,
-- d763), which plains every return, so a secret is never compared, joined or used as a table key here.
-- An open target's GUID seen on target, mouseover or a nameplate gives the own alert (banner, sound, one chat line;
-- once per target per 60 s, none while /kos off) and a sighting in the own kos_m record (newest 3 of 10 minutes).
-- Out of combat an enemy player whose full name has an open name entry (added by name) counts as that entry; an
-- officer's sighting then links the entry to the player (ns.Mark.Link).
-- A guildmate's merged kos_m record gives heard lines: open targets only, at most 10 a minute.
local _, ns = ...
local Spot = {}
ns.Spot = Spot

local SOUND = 8959          -- the alert's sound kit
local KEEP = 600            -- seconds a sighting stays in the own record
local SIGHTINGS = 3         -- sightings in the own record (RulesRecords SPEC.m)
local HEARD_AGE = 300       -- a heard sighting older than this prints nothing
local HEARD_CAP = 10        -- heard lines per minute, all spotters together
local SOURCES = { "target", "mouseover", "nameplate" }

local spotSeen = {}         -- GUID -> time of its last own alert (the 60 s throttle)
local heardSeen = {}        -- GUID .. "/" .. spotter key -> sighting time of its last heard line
local heardLines = {}       -- times of the heard lines printed in the last minute
local heardFrom = {}        -- record key -> receive times of its new heard sightings in the last minute (D89)
local ring = {}             -- received sightings, newest last (Rules.RING); never stored
local shard = ""            -- the zone UID of the creatures seen in this zone, "" while unread
local broken = {}           -- source -> true while its last read out of combat came back secret
local combatNameSecret      -- true when the last in-combat name read (combatName on) was secret too
local banner, bannerToken = nil, 0

local function R() return ns.Rules end
local function call(...) if ns.Hub then return ns.Hub.Call(...) end end
local function now() return ns.Core and ns.Core.Now() or 0 end
local function esc(s) return ns.Hub and ns.Hub.Escape(s) or R().Clean(s) end
local function myKey()
  local c = type(GuildSync) == "table" and GuildSync.Comm or nil
  return c and c.MyKey() or nil
end

-- A member key drawn as the roster's name, else the key itself.
local function memberName(key)
  local c = type(GuildSync) == "table" and GuildSync.Comm or nil
  local ok, rows = pcall(c and c.Roster)
  local row = ok and type(rows) == "table" and rows[key] or nil
  local name = type(row) == "table" and type(row.name) == "string" and ns.RulesRecords.Safe(row.name) or ""
  if name ~= "" then return name end -- stripped of bidi and control code points (D92, f8503)
  return key
end

-- Drops every entry of map whose time is window or more before t.
local function prune(map, t, window)
  for k, at in pairs(map) do
    if t - at >= window then map[k] = nil end
  end
end

-- Keeps the times in list that are less than window before t, in order.
local function pruneList(list, t, window)
  local n = 0
  for i = 1, #list do
    if t - list[i] < window then n = n + 1 list[n] = list[i] end
  end
  for i = #list, n + 1, -1 do list[i] = nil end
end

-- A client text read made safe and capped before it is stored or shown; nil when empty.
local function text(s, cap)
  if type(s) ~= "string" then return nil end
  s = ns.RulesRecords.Safe(s, cap)
  return s ~= "" and s or nil
end

local function sourceOf(unit)
  if unit == "target" or unit == "mouseover" then return unit end
  if unit:match("^nameplate%d+$") then return "nameplate" end
  return nil
end

-- ---------- the shard (f5217) ----------

-- The zone UID is the fifth field of a creature's GUID; pets and players carry none worth reading.
local function readShard(guid)
  local uid = guid:match("^Creature%-[^-]*%-[^-]*%-[^-]*%-(%d+)%-")
  if uid then shard = uid end
end

function Spot.OnZone() shard = "" end
function Spot.Shard() return shard end
function Spot.Ring() return ring end
function Spot.Throttles() return spotSeen, heardSeen end

-- ---------- last seen ----------

-- An own one (mine) always writes; a heard one never replaces an own one younger than 60 s of receive time t (D89,
-- f8553) nor a newer one.
local function setLastSeen(name, at, zone, subzone, by, mine, t)
  local g = ns.Core and ns.Core.Guild()
  local k = R().Key(name)
  if not g or not k then return false end
  if type(g.lastSeen) ~= "table" then g.lastSeen = {} end
  local held = g.lastSeen[k]
  if not mine and type(held) == "table" and type(held.at) == "number" and (R().KeepOwn(held, t) or held.at >= at) then
    return false
  end
  g.lastSeen[k] = { at = at, zone = zone, subzone = subzone, by = by, mine = mine or nil }
  return true
end

-- ---------- the own alert ----------

local function showBanner(line)
  if not banner then
    banner = CreateFrame("Frame", nil, UIParent)
    banner:SetFrameStrata("HIGH")
    banner:SetSize(640, 40)
    banner:SetPoint("TOP", UIParent, "TOP", 0, -160)
    banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    banner.text:SetPoint("CENTER")
  end
  banner.text:SetText(line)
  banner:Show()
  bannerToken = bannerToken + 1
  local mine = bannerToken
  if ns.Hub then ns.Hub.After(R().BANNER, function() if bannerToken == mine then banner:Hide() end end) end
end

local function alert(rec, zone, subzone)
  local parts = {}
  if type(rec.race) == "string" and rec.race ~= "" then parts[#parts + 1] = esc(rec.race) end
  if type(rec.class) == "string" and rec.class ~= "" then parts[#parts + 1] = esc(rec.class) end
  local who = esc(rec.name or "?") .. (#parts > 0 and (" (" .. table.concat(parts, " ") .. ")") or "")
  local at = esc(zone or "")
  if subzone and subzone ~= zone then at = esc(subzone) .. ", " .. at end
  local line = "KOS: " .. who .. " at " .. at
  showBanner(line)
  if not call("C_Sound.PlaySound", SOUND) then call("PlaySound", SOUND) end
  print(line)
end

-- ---------- the own sighting (AC22) ----------

local function share(guid, t, zone, subzone)
  local here = shard ~= "" and shard or nil
  ns.Store.WriteOwn(function(r)
    local keep = {}
    for _, s in ipairs(r.sightings or {}) do
      local at = tonumber(s.time)
      if s.target ~= guid and at and t - at < KEEP then keep[#keep + 1] = s end
    end
    keep[#keep + 1] = { target = guid, time = t, zone = zone, subzone = subzone, shard = here }
    table.sort(keep, function(a, b)
      if a.time ~= b.time then return a.time > b.time end
      return tostring(a.target) < tostring(b.target)
    end)
    for i = #keep, SIGHTINGS + 1, -1 do keep[i] = nil end
    r.sightings = keep
  end, t)
end

-- ---------- reads (AC21) ----------

-- The open targets held, as Rules.FindName reads them: "t" .. GUID -> record. Name entries are left out, so the
-- in-combat name match never reaches one (review f8).
local function openTargets()
  local out = {}
  for _, t in ipairs(ns.List and ns.List.Open() or {}) do
    if not ns.RulesMarks.IsNameKey(t.guid) then out["t" .. t.guid] = t.rec end
  end
  return out
end

-- True when some name entry (a record under a Marks.NameKey key) is open; no client call.
local function anyNameEntry()
  local g = ns.Core and ns.Core.Guild()
  for k in pairs(g and type(g.kos) == "table" and g.kos or {}) do
    local guid = type(k) == "string" and k:sub(2) or nil
    local rec = ns.RulesMarks.IsNameKey(guid) and ns.Store.Target(guid)
    if type(rec) == "table" and rec.status == "open" then return true end
  end
  return false
end

-- The full name of unit from UnitNameUnmodified's two plain returns (AC16), or nil.
local function fullName(unit)
  local first, second = call("UnitNameUnmodified", unit)
  local name = ns.RulesMarks.FullName(first, second, call("GetRealmName"), call("GetNormalizedRealmName"))
  if name and name:find(" ", 1, true) then return name end
  return nil
end

-- The key of the open name entry an enemy player unit's full name has, or nil. Out of combat only (the caller); the
-- name is read only while some name entry is open, so ordinary spotting reads nothing more.
local function nameEntryOf(unit)
  if not anyNameEntry() then return nil end
  if call("UnitIsPlayer", unit) ~= true or call("UnitIsEnemy", "player", unit) ~= true then return nil end
  local name = fullName(unit)
  local nk = ns.RulesMarks.NameKey(name)
  local rec = nk and ns.Store.Target(nk)
  -- the entry must hold the unit's own name, not only its key (sec f1/f4)
  if type(rec) ~= "table" or rec.status ~= "open" or not ns.RulesMarks.SameName(rec.name, name) then return nil end
  return nk
end

function Spot.OnUnit(_, unit, guid)
  if type(unit) ~= "string" then return end
  if ns.Hub and ns.Hub.InDemo() then return end -- inert under /gsync demo (AC36): no alert, sighting or lastSeen
  local source = sourceOf(unit)
  local combat = call("InCombatLockdown") == true
  local plain = type(guid) == "string"
  if plain then
    if source and not combat then broken[source] = nil end
    if guid:sub(1, 9) == "Creature-" then readShard(guid) return end
  else
    -- no GUID: no unit, or a secret one
    if call("UnitExists", unit) ~= true then return end
    if source and not combat then broken[source] = true end
    if not (combat and ns.Probe and ns.Probe.combatName) then return end
    local name = fullName(unit)
    combatNameSecret = name == nil
    local key = name and R().FindName(name, openTargets())
    if not key then return end
    guid = key:sub(2)
  end
  local rec = ns.Store.Target(guid)
  local realGuid -- set when the unit matched a name entry by its full name: guid is then the entry's key
  if plain and not combat and (type(rec) ~= "table" or rec.status ~= "open") then
    local nk = nameEntryOf(unit)
    if nk then realGuid, guid, rec = guid, nk, ns.Store.Target(nk) end
  end
  if type(rec) ~= "table" or rec.status ~= "open" then return end
  if call("UnitIsEnemy", "player", unit) == false then return end -- a plain false is a friendly unit (f8581)
  local t = now()
  prune(spotSeen, t, R().WINDOW)
  if not R().Throttle(spotSeen, guid, t, R().WINDOW) then return end
  -- the real GUID too, so the record a link makes of it gives no second alert in the window (review f9)
  if realGuid then spotSeen[realGuid] = t end
  local caps = ns.RulesRecords.CAPS
  local zone, subzone = text(call("GetZoneText"), caps.zone), text(call("GetSubZoneText"), caps.subzone)
  if not ns.Core.DB().muted then alert(rec, zone, subzone) end
  -- before the roster is whole the sighting is neither held nor written (AC7a, f5426); the alert above still shows
  if ns.Store.Ready() then share(guid, t, zone, subzone) end
  if setLastSeen(rec.name, t, zone, subzone, memberName(myKey()), true, t) and ns.Hub then ns.Hub.Refresh() end
  -- an officer's sighting links the entry to the player; "decided" or "full" leaves all as is, with no line (gate A 2)
  if realGuid and ns.Store.CanWriteOfficer() then
    local fields = ns.Mark.ReadUnit(unit)
    if fields and fields.guid == realGuid then
      fields.zone = zone
      ns.Mark.Link(guid, fields, t, true)
    end
  end
end

-- "spotting: <working sources>" and, while in-combat matching cannot work, why (the module's status line).
function Spot.Status()
  local working = {}
  for _, s in ipairs(SOURCES) do if not broken[s] then working[#working + 1] = s end end
  local line = "spotting: " .. (#working > 0 and table.concat(working, ", ") or "none")
  if not (ns.Probe and ns.Probe.combatName) then line = line .. "; in-combat name matching is off"
  elseif combatNameSecret then line = line .. "; in-combat spotting is off" end
  return line
end

-- ---------- heard sightings (AC22, f5219) ----------

local function heard(spotter, s, t)
  local guid, at = s.target, tonumber(s.time)
  if type(guid) ~= "string" or not at or t - at > HEARD_AGE then return false end
  if at > t then at = t end -- a time ahead of now counts as now: last seen, the ring and the throttle (f5440)
  local rec = ns.Store.Target(guid)
  -- a name entry no longer open is heard as the open record it was linked to, if any
  if type(rec) == "table" and rec.status ~= "open" and ns.RulesMarks.IsNameKey(guid) then
    rec = ns.Mark.TargetFor({ guid = guid, name = rec.name })
  end
  if type(rec) ~= "table" or rec.status ~= "open" then return false end
  for _, e in ipairs(ring) do
    if e.target == guid and e.spotter == spotter and e.time >= at then return false end
  end
  -- one record key gets HEARD_PER_SENDER new sightings per 60 s of receive time; a refusal stamps nothing (D89)
  local from = heardFrom[spotter] or {}
  heardFrom[spotter] = from
  pruneList(from, t, R().WINDOW)
  if #from >= R().HEARD_PER_SENDER then return false end
  from[#from + 1] = t
  R().AddSighting(ring, { target = guid, time = at, zone = s.zone, subzone = s.subzone, shard = s.shard,
    spotter = spotter }, R().RING, R().RING_PER_SENDER)
  local by = memberName(spotter)
  local changed = setLastSeen(rec.name, at, s.zone, s.subzone, by, false, t)
  -- once per target and spotter per 60 s of sighting time, then the cap over all spotters
  pruneList(heardLines, t, R().WINDOW)
  if #heardLines >= HEARD_CAP then return changed end
  prune(heardSeen, at, R().WINDOW)
  if not R().Throttle(heardSeen, guid .. "/" .. spotter, at, R().WINDOW) then return changed end
  heardLines[#heardLines + 1] = t
  print(R().HeardShardLine(by, rec.name, s.zone, s.subzone, s.shard, shard, esc))
  return changed
end

ns.Store.OnMemberMerged(function(key, rec)
  if type(key) ~= "string" or key == myKey() or type(rec) ~= "table" or type(rec.sightings) ~= "table" then return end
  local t, changed = now(), false
  local newest = {} -- target -> its newest sighting in this record; only that one is heard (f8584)
  for _, s in ipairs(rec.sightings) do
    local at = type(s) == "table" and tonumber(s.time)
    if at and s.target ~= nil and not (newest[s.target] and tonumber(newest[s.target].time) >= at) then
      newest[s.target] = s
    end
  end
  for _, s in ipairs(rec.sightings) do
    if type(s) == "table" and newest[s.target] == s and heard(key, s, t) then changed = true end
  end
  if changed and ns.Hub then ns.Hub.Refresh() end
end)

return Spot
