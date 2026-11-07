-- GuildKOS Mark: Mark as bounty on the current target, and the officers' approve and reject (R6 Task D; spec
-- AC16-AC20). A member's mark waits in the member's own kos_m record; an officer's mark, and an approved or rejected
-- mark, is a kos record written through ns.Store.WriteTarget. Mark.FromName marks a typed First Surname under a
-- RulesMarks name key; Mark.Link turns that open name entry into the real player's record (an officer's mark or
-- approval of that name, or Spot's sighting). Every client read goes through ns.Hub.Call (the handle's
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

-- The open targets held, "t" .. guid -> rec (the map Marks.FindLinked and Marks.TargetOf read).
local function openMap()
  local out = {}
  for _, e in ipairs(ns.List.Open()) do out["t" .. e.guid] = e.rec end
  return out
end

-- Mark.TargetFor(mark, open) -> rec | nil: the record a mark is judged against. A real-GUID mark reads its own
-- record; a name-key mark the linked open record of that name, else its own (Marks.TargetOf). open is optional.
function Mark.TargetFor(mark, open)
  if type(mark) ~= "table" then return nil end
  local held = ns.Store.Target(mark.guid)
  if not Marks().IsNameKey(mark.guid) then return held end
  return Marks().TargetOf(mark, held, open or openMap())
end

-- A judge for one pass over many marks: the open map is built once, and only when a name-key mark is met.
local function judge()
  local map
  return function(m)
    if type(m) == "table" and Marks().IsNameKey(m.guid) and not map then map = openMap() end
    return Mark.TargetFor(m, map)
  end
end

-- A name-key mark whose name does not make its key (an edited saved file, sec f1): it never waits, so it is neither
-- shown, decided nor counted, and the next own write drops it.
local function forged(m)
  return type(m) == "table" and Marks().IsNameKey(m.guid) and Marks().NameKey(m.name) ~= m.guid
end

-- Does mark m still wait, by Marks.State against target(m)?
local function waits(m, target)
  return not forged(m) and Marks().State(m, target(m)) == "waiting"
end

-- The marks in a member record that still wait, by Marks.State against Mark.TargetFor.
local function waitingOf(rec, target)
  target = target or judge()
  local out = {}
  for _, m in ipairs(type(rec) == "table" and type(rec.marks) == "table" and rec.marks or {}) do
    if type(m) == "table" and waits(m, target) then out[#out + 1] = m end
  end
  return out
end

-- The stored marks to keep in a WriteOwn edit: those still waiting by Marks.State against target, except a mark
-- whose guid is skip. Unlike waitingOf it keeps a non-table entry (State answers "waiting" for one), as before.
local function stillWaiting(marks, target, skip)
  local keep = {}
  for _, m in ipairs(marks) do
    if (skip == nil or m.guid ~= skip) and waits(m, target) then keep[#keep + 1] = m end
  end
  return keep
end

-- Mark.ReadUnit(unit) -> mark fields { guid, name, race, class, level } | nil, reason, read through the hub.
function Mark.ReadUnit(unit)
  if call("UnitExists", unit) ~= true then return nil, "target" end
  if call("UnitIsPlayer", unit) ~= true then return nil, "player" end
  if call("UnitIsEnemy", "player", unit) ~= true then return nil, "enemy" end
  if call("C_Secrets.ShouldUnitIdentityBeSecret", unit) == true then return nil, "secret" end
  local guid = call("UnitGUID", unit)
  if type(guid) ~= "string" or guid == "" then return nil, "secret" end
  local _, bad = ns.RulesRecords.TargetKey(guid)
  if bad then return nil, "long" end
  local first, second = call("UnitNameUnmodified", unit)
  if type(first) ~= "string" or first == "" then return nil, "secret" end
  local name = Marks().FullName(first, second, call("GetRealmName"), call("GetNormalizedRealmName"))
  if not name or not name:find(" ", 1, true) then return nil, "name" end
  local R = ns.RulesRecords
  local race, class, level = call("UnitRace", unit), call("UnitClass", unit), call("UnitLevel", unit)
  return {
    guid = guid,
    name = R.Safe(name),
    race = type(race) == "string" and R.Safe(race, R.CAPS.race) or nil,
    class = type(class) == "string" and R.Safe(class, R.CAPS.class) or nil,
    level = type(level) == "number" and level >= 1 and math.floor(level) or nil,
  }
end
local function readTarget() return Mark.ReadUnit("target") end

local function text(s, cap)
  if type(s) ~= "string" then return nil end
  s = ns.RulesRecords.Safe(s, cap)
  return s ~= "" and s or nil
end

-- Mark.Link(nameGuid, real, t, auto) -> true | nil, why: the open name entry under nameGuid becomes the real
-- player's record. real: ReadUnit's fields plus optional why, zone, decidedBy, decidedAt. Every check comes before
-- any write; then the entry is removed and the real record written open (the entry written back if that fails).
-- auto (Spot's sighting) never links over a newer rejection or removal. Prints nothing.
function Mark.Link(nameGuid, real, t, auto)
  local can, gate = ns.Store.CanWriteOfficer()
  if not can then return nil, gate end
  if type(real) ~= "table" or type(real.guid) ~= "string" or type(t) ~= "number" then return nil, "args" end
  t = math.floor(t)
  local entry = ns.Store.Target(nameGuid)
  if type(entry) ~= "table" or entry.status ~= "open" then return nil, "target" end
  local held = ns.Store.Target(real.guid)
  if auto and not Marks().MayAutoLink(entry, held) then return nil, "decided" end
  -- the open targets other than the entry: at the cap the real write would be refused, and so would the write-back
  local others = 0
  for _, e in ipairs(ns.List.Open()) do if e.guid ~= nameGuid then others = others + 1 end end
  if others >= ns.Store.OPEN_MAX then return nil, "full" end
  local decided = real.decidedBy ~= nil
  local rec = { status = "open", name = real.name, race = real.race, class = real.class, level = real.level,
    zone = real.zone or text(call("GetZoneText"), ns.RulesRecords.CAPS.zone), why = real.why or entry.why,
    markedBy = entry.markedBy, markedAt = entry.markedAt,
    decidedBy = decided and real.decidedBy or entry.decidedBy, decidedAt = decided and real.decidedAt or entry.decidedAt,
    kills = type(held) == "table" and held.kills or {}, rejected = type(held) == "table" and held.rejected or {} }
  local key, long = ns.RulesRecords.TargetKey(real.guid)
  if not key then return nil, long end
  -- the "open" cap answer is left aside: the entry's slot is freed before the real write
  local parsed, bad = ns.Store.CanWrite("kos", key, rec, t)
  if not parsed and bad ~= "open" then return nil, bad end
  local removed, why = ns.List.Remove(nameGuid, t)
  if not removed then return nil, why end
  local done, refused = ns.Store.WriteTarget(real.guid, rec, t)
  if not done then
    ns.Store.WriteTarget(nameGuid, entry, t)
    return nil, refused
  end
  if ns.Hub then ns.Hub.Refresh() end
  return true
end

-- The key of the open name entry for a full name, or nil. The entry must hold that same name (sec f4).
local function openEntry(name)
  local nk = Marks().NameKey(name)
  local entry = nk and ns.Store.Target(nk)
  if type(entry) == "table" and entry.status == "open" and Marks().SameName(entry.name, name) then return nk end
  return nil
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
    local nk = openEntry(mark.name)
    if nk then
      local done, bad = Mark.Link(nk, mark, t)
      if not done then
        return refuse(bad, ns.List.RefusalLine((bad == "full" or bad == "open") and "open" or bad))
      end
      print("KOS: " .. ns.Hub.Escape(mark.name) .. " is on the list.")
      return true
    end
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
    local keep = stillWaiting(r.marks, judge(), mark.guid)
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
  -- approving a real-GUID mark of a name on the list links the name entry (o2705: decided by me, now)
  local nk = status == "open" and not Marks().IsNameKey(guid) and openEntry(m.name)
  if nk then
    local done, bad = Mark.Link(nk, { guid = guid, name = m.name, race = m.race, class = m.class, level = m.level,
      zone = m.zone, why = m.why, decidedBy = myKey(), decidedAt = math.floor(t) }, math.floor(t))
    if not done then return nil, bad == "full" and "open" or bad end -- the page prints List.RefusalLine (rev f5)
    return true
  end
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

-- Mark.FromName(name, why) -> true | nil, reason: /kos add and the Name box. An officer's name entry is open at once;
-- a member's name mark waits. Typing the targeted enemy's own name marks the target (d2002). A refusal prints one line.
function Mark.FromName(name, why)
  if ns.Hub and ns.Hub.InDemo() then return refuse("demo", ns.List.RefusalLine("demo")) end
  if inCombat() then return refuse("combat") end
  local ready, notReady = ns.Store.Ready()
  if not ready then return refuse(notReady, ns.List.RefusalLine(notReady)) end
  if type(name) ~= "string" or select(2, name:gsub("%S+", "")) ~= 2 then return refuse("fullname") end
  local nk = Marks().NameKey(name)
  if not nk then return refuse("fullname") end
  local unit = readTarget()
  if unit and Marks().SameName(unit.name, name) then return Mark.FromTarget(why) end
  local open = openMap()
  local held = ns.Store.Target(nk)
  if (type(held) == "table" and held.status == "open" and Marks().SameName(held.name, name))
    or Marks().FindLinked(nk, open, name) then return refuse("named") end
  local display = Marks().NameDisplay(name)
  local t = now()
  why = text(why, ns.RulesRecords.CAPS.why)

  if ns.Store.CanWriteOfficer() then
    local rec = { status = "open", name = display, why = why, markedBy = myKey(), markedAt = t,
      kills = type(held) == "table" and held.kills or {}, rejected = type(held) == "table" and held.rejected or {} }
    local done, bad = ns.Store.WriteTarget(nk, rec, t)
    if not done then return refuse(bad == "open" and "full" or bad, ns.List.RefusalLine(bad)) end
    print("KOS: " .. ns.Hub.Escape(display) .. " is on the list.")
    if ns.Hub then ns.Hub.Refresh() end
    return true
  end

  local target = function(m) return Mark.TargetFor(m, open) end
  local waiting = waitingOf(ns.Store.Member(myKey()), target)
  for _, m in ipairs(waiting) do
    if m.guid == nk or Marks().SameName(m.name, name) then return refuse("waiting") end
  end
  if #waiting >= Marks().MAX_WAITING then return refuse("cap") end
  local done, bad = ns.Store.WriteOwn(function(r)
    local keep = stillWaiting(r.marks, target, nk)
    keep[#keep + 1] = { guid = nk, name = display, why = why, time = t }
    r.marks = keep
  end, t)
  if not done then return refuse(bad, ns.List.RefusalLine(bad)) end
  print("KOS: " .. ns.Hub.Escape(display) .. " waits for an officer.")
  if ns.Hub then ns.Hub.Refresh() end
  return true
end

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
  local target = judge()
  for _, k in ipairs(keys) do
    for _, m in ipairs(waitingOf(ns.Store.Member(k), target)) do out[#out + 1] = { key = k, mark = m } end
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
    r.marks = stillWaiting(r.marks, judge())
  end, now())
end
Mark.Cleanup = cleanup

ns.Store.OnTargetMerged(function() cleanup() end)

return Mark
