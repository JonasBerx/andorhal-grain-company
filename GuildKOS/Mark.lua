-- GuildKOS Mark: Mark as bounty on the current target, and the officers' approve and reject (R6 Task D; spec
-- AC16-AC20). A member's mark waits in the member's own kos_m record; an officer's mark, and an approved or rejected
-- mark, is a kos record written through ns.Store.WriteTarget. Every client read goes through ns.Hub.Call (the handle's
-- M.Compat.call, d763), which plains every return: a secret comes back nil and is never compared or joined here.
local _, ns = ...
local Mark = {}
ns.Mark = Mark

local function Marks() return ns.RulesMarks end
local function call(...) if ns.Hub then return ns.Hub.Call(...) end end
local function myKey()
  local c = type(GuildSync) == "table" and GuildSync.Comm or nil
  return c and c.MyKey() or nil
end
local function now() return ns.Core and ns.Core.Now() or 0 end

-- One "KOS: ..." line for a refusal; answers nil, reason.
local function refuse(reason, line)
  print("KOS: " .. (line or Marks().Refusal(reason) or ("Not marked (" .. tostring(reason) .. ").")))
  return nil, reason
end

local function inCombat() return call("InCombatLockdown") == true and not ns.Probe.combatMark end

-- Mark.Available() -> true | false, line: the button's state.
function Mark.Available()
  if inCombat() then return false, Marks().Refusal("combat") end
  return true
end

-- The marks in a member record that still wait, by Marks.State against the held target.
local function waitingOf(rec)
  local out = {}
  for _, m in ipairs(type(rec) == "table" and type(rec.marks) == "table" and rec.marks or {}) do
    if type(m) == "table" and Marks().State(m, ns.Store.Target(m.guid)) == "waiting" then out[#out + 1] = m end
  end
  return out
end

-- The current target read through the hub: mark fields, or nil, reason.
local function readTarget()
  if call("UnitExists", "target") ~= true then return nil, "target" end
  if call("UnitIsPlayer", "target") ~= true then return nil, "player" end
  if call("UnitIsEnemy", "player", "target") ~= true then return nil, "enemy" end
  if call("C_Secrets.ShouldUnitIdentityBeSecret", "target") == true then return nil, "secret" end
  local guid = call("UnitGUID", "target")
  if type(guid) ~= "string" or guid == "" then return nil, "secret" end
  local _, bad = ns.RulesRecords.TargetKey(guid)
  if bad then return nil, "long" end
  local first, second = call("UnitNameUnmodified", "target")
  if type(first) ~= "string" or first == "" then return nil, "secret" end
  local name = Marks().FullName(first, second, call("GetRealmName"), call("GetNormalizedRealmName"))
  if not name or not name:find(" ", 1, true) then return nil, "name" end
  local R = ns.RulesRecords
  local race, class, level = call("UnitRace", "target"), call("UnitClass", "target"), call("UnitLevel", "target")
  return {
    guid = guid,
    name = R.Safe(name),
    race = type(race) == "string" and R.Safe(race, R.CAPS.race) or nil,
    class = type(class) == "string" and R.Safe(class, R.CAPS.class) or nil,
    level = type(level) == "number" and level >= 1 and math.floor(level) or nil,
  }
end

local function text(s, cap)
  if type(s) ~= "string" then return nil end
  s = ns.RulesRecords.Safe(s, cap)
  return s ~= "" and s or nil
end

-- Mark.FromTarget(why) -> true | nil, reason. The button and /kos mark [why] call it; a refusal prints one line and
-- writes nothing.
function Mark.FromTarget(why)
  if ns.Hub and ns.Hub.InDemo() then return refuse("demo", ns.List.RefusalLine("demo")) end
  if inCombat() then return refuse("combat") end
  -- before the roster is whole nothing is held or written, an officer's mark and a member's alike (AC7a, f5425)
  local ready, notReady = ns.Store.Ready()
  if not ready then return refuse(notReady, ns.List.RefusalLine(notReady)) end
  local mark, reason = readTarget()
  if not mark then return refuse(reason) end
  local held = ns.Store.Target(mark.guid)
  if type(held) == "table" and held.status == "open" then return refuse("open") end
  local caps = ns.RulesRecords.CAPS
  local t = now()
  mark.why = text(why, caps.why)
  mark.zone = text(call("GetZoneText"), caps.zone)
  mark.subzone = text(call("GetSubZoneText"), caps.subzone)
  mark.time = t

  -- an officer's mark is open at once
  if ns.Store.CanWriteOfficer() then
    local rec = { status = "open", name = mark.name, race = mark.race, class = mark.class, level = mark.level,
      zone = mark.zone, why = mark.why, markedBy = myKey(), markedAt = t,
      kills = type(held) == "table" and held.kills or {}, rejected = type(held) == "table" and held.rejected or {} }
    local done, bad = ns.Store.WriteTarget(mark.guid, rec, t)
    if not done then return refuse(bad == "open" and "full" or bad, ns.List.RefusalLine(bad)) end
    print("KOS: " .. ns.Hub.Escape(mark.name) .. " is on the list.")
    if ns.Hub then ns.Hub.Refresh() end
    return true
  end

  -- a member's mark waits in the own kos_m record; the cap refuses before any write (d796)
  local waiting = waitingOf(ns.Store.Member(myKey()))
  for _, m in ipairs(waiting) do
    if m.guid == mark.guid then return refuse("waiting") end
  end
  if #waiting >= Marks().MAX_WAITING then return refuse("cap") end
  local done, bad = ns.Store.WriteOwn(function(r)
    local keep = {}
    for _, m in ipairs(r.marks) do
      if m.guid ~= mark.guid and Marks().State(m, ns.Store.Target(m.guid)) == "waiting" then keep[#keep + 1] = m end
    end
    keep[#keep + 1] = mark
    r.marks = keep
  end, t)
  if not done then return refuse(bad, ns.List.RefusalLine(bad)) end
  print("KOS: " .. ns.Hub.Escape(mark.name) .. " waits for an officer.")
  if ns.Hub then ns.Hub.Refresh() end
  return true
end

-- The held mark from markerKey on guid, when it still waits.
local function waitingMark(markerKey, guid)
  for _, m in ipairs(waitingOf(ns.Store.Member(markerKey))) do
    if m.guid == guid then return m end
  end
  return nil
end

local function decide(status, markerKey, guid, t)
  local can, why = ns.List.CanWrite()
  if not can then return nil, why end
  if type(t) ~= "number" or type(markerKey) ~= "string" or type(guid) ~= "string" then return nil, "args" end
  local m = waitingMark(markerKey, guid)
  if not m then return nil, "mark" end
  local held = ns.Store.Target(guid)
  local rec = { status = status, name = m.name, race = m.race, class = m.class, level = m.level, zone = m.zone,
    why = m.why, markedBy = markerKey, markedAt = m.time, decidedBy = myKey(), decidedAt = math.floor(t),
    kills = type(held) == "table" and held.kills or {}, rejected = type(held) == "table" and held.rejected or {} }
  local done, bad = ns.Store.WriteTarget(guid, rec, math.floor(t))
  if not done then return nil, bad end
  if ns.Hub then ns.Hub.Refresh() end
  return true
end

-- Mark.Approve(markerKey, guid, now) / Mark.Reject(markerKey, guid, now) -> true | nil, why. Officers only; a mark
-- that no longer waits (AC19a) answers nil, "mark".
function Mark.Approve(markerKey, guid, t) return decide("open", markerKey, guid, t) end
function Mark.Reject(markerKey, guid, t) return decide("rejected", markerKey, guid, t) end

-- Mark.Withdraw(guid, now) -> true | nil, why: drops my own mark on guid.
function Mark.Withdraw(guid, t)
  if type(guid) ~= "string" or type(t) ~= "number" then return nil, "args" end
  if not waitingMark(myKey(), guid) then return nil, "mark" end
  local done, bad = ns.Store.WriteOwn(function(r)
    local keep = {}
    for _, m in ipairs(r.marks) do if m.guid ~= guid then keep[#keep + 1] = m end end
    r.marks = keep
  end, math.floor(t))
  if not done then return nil, bad end
  if ns.Hub then ns.Hub.Refresh() end
  return true
end

-- Mark.Waiting() -> { { key = markerKey, mark = mark }, ... }: the waiting marks this client may see (AC20): an
-- officer all held from members on the roster (AC7b: a leaver's marks are not shown), a member only its own. Sorted by
-- mark time, then key and guid.
function Mark.Waiting()
  local out, me = {}, myKey()
  local c = type(GuildSync) == "table" and GuildSync.Comm or nil
  local officer = me ~= nil and c ~= nil and c.IsOfficer(me) == true
  local g = ns.Core and ns.Core.Guild()
  local keys = {}
  if officer then
    local roster = c.Roster()
    if type(roster) ~= "table" then roster = {} end
    for k in pairs(g and type(g.kos_m) == "table" and g.kos_m or {}) do
      if roster[k] ~= nil then keys[#keys + 1] = k end
    end
  elseif me then
    keys[1] = me
  end
  for _, k in ipairs(keys) do
    for _, m in ipairs(waitingOf(ns.Store.Member(k))) do out[#out + 1] = { key = k, mark = m } end
  end
  table.sort(out, function(a, b)
    local ta, tb = tonumber(a.mark.time) or 0, tonumber(b.mark.time) or 0
    if ta ~= tb then return ta < tb end
    if a.key ~= b.key then return a.key < b.key end
    return a.mark.guid < b.mark.guid
  end)
  return out
end

-- The marker's cleanup: once a held target record decides one of my marks, the mark leaves my kos_m record (AC19).
-- Runs after every merged kos record, so also after logging in when the decision came while offline.
local function cleanup()
  local me = myKey()
  local rec = me and ns.Store.Member(me)
  if type(rec) ~= "table" or type(rec.marks) ~= "table" then return end
  if #waitingOf(rec) == #rec.marks then return end
  ns.Store.WriteOwn(function(r)
    local keep = {}
    for _, m in ipairs(r.marks) do
      if Marks().State(m, ns.Store.Target(m.guid)) == "waiting" then keep[#keep + 1] = m end
    end
    r.marks = keep
  end, now())
end
Mark.Cleanup = cleanup

ns.Store.OnTargetMerged(function() cleanup() end)

return Mark
