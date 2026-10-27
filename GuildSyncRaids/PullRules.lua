local _, ns = ...
if not ns.M then return end

-- Pure pull rules (S9 L1, Raids 0.5 Pulls): the group snapshot, a pull's start and end, the caps and the login prune,
-- which raid owns a pull (d1231), the four attendance lists and the /gsraids pulls lines. No client calls; only
-- string, table, math. The saved shape is frozen in PULLS-FORMAT.md (d1109).
-- pull = { at, encounterID, name, difficultyID, groupSize, success, duration, snapAge, people = { { guid, name } } };
-- no snapAge = no snapshot, names unknown.

local PullRules = { CAP = 300, KEEP = 35 * 86400, WINDOW = 7200, ENDWITHIN = 3600, NAMECAP = 60, BOSSCAP = 80 }
ns.PullRules = PullRules

local function filled(v) return type(v) == "string" and v ~= "" end

-- At most cap bytes, never half a UTF-8 character.
local function cap(s, n)
  if #s <= n then return s end
  local cut = string.sub(s, 1, n)
  local nextByte = string.byte(s, n + 1)
  if nextByte >= 128 and nextByte < 192 then cut = string.gsub(cut, "[\192-\255][\128-\191]*$", "") end
  return cut
end

-- An event arg through plain, kept only when it is the wanted type (a secret plains to nil and is never compared).
local function arg(plain, v, want)
  v = plain(v)
  if type(v) == want then return v end
  return nil
end

-- reads = { { exists, guid, first, second } } already plained. exists == false: skipped; exists == true: needs a
-- non-empty guid and both name parts (d1233); anything else, or any missing part, drops the whole snapshot (nil).
function PullRules.Snapshot(reads)
  local people = {}
  for _, r in ipairs(reads or {}) do
    if r.exists == true then
      if not (filled(r.guid) and filled(r.first) and filled(r.second)) then return nil end
      people[#people + 1] = { guid = r.guid, name = r.first .. " " .. r.second }
    elseif r.exists ~= false then
      return nil
    end
  end
  return people
end

-- ENCOUNTER_START: appends one pull (people copied from the snapshot, names and boss capped), drops the oldest past
-- CAP. args = { encounterID, name, difficultyID, groupSize } as received; snap nil = names unknown (no snapAge).
function PullRules.Start(list, snap, snapAt, args, now, plain)
  args = args or {}
  local boss = arg(plain, args[2], "string")
  local p = { at = now, encounterID = arg(plain, args[1], "number"), name = boss and cap(boss, PullRules.BOSSCAP),
    difficultyID = arg(plain, args[3], "number"), groupSize = arg(plain, args[4], "number"), people = {} }
  if snap and type(snapAt) == "number" then
    p.snapAge = now - snapAt
    for i, person in ipairs(snap) do p.people[i] = { guid = person.guid, name = cap(person.name, PullRules.NAMECAP) } end
  end
  list[#list + 1] = p
  while #list > PullRules.CAP do table.remove(list, 1) end
  return p
end

-- ENCOUNTER_END: closes the newest pull only, when it is open, has the same encounterID and began at most ENDWITHIN
-- ago. args = { encounterID, name, difficultyID, groupSize, success } as received. Answers the pull, or nil.
function PullRules.End(list, args, now, plain)
  local p = list[#list]
  args = args or {}
  local id = arg(plain, args[1], "number")
  local result = plain(args[5])
  if type(p) ~= "table" or p.success ~= nil or id == nil or p.encounterID ~= id then return nil end
  if type(p.at) ~= "number" or now - p.at > PullRules.ENDWITHIN then return nil end
  if result ~= 1 and result ~= 0 and type(result) ~= "boolean" then return nil end
  p.success = (result == 1 or result == true)
  p.duration = now - p.at
  return p
end

-- The PULLS-FORMAT.md field list: each field and its Lua type. Prune keeps these and nothing else.
local FIELDS = { encounterID = "number", name = "string", difficultyID = "number", groupSize = "number",
  success = "boolean", duration = "number", snapAge = "number" }

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- Login (S-f1): a new list rebuilt from FIELDS, without broken pulls, pulls whose at is not finite or older than KEEP,
-- and only the newest CAP. A field of the wrong type is dropped; boss and person names are capped; people keep only a
-- string guid and name, and a pull whose people is not a table gets {} and loses its snapAge (names unknown).
function PullRules.Prune(list, now)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, p in ipairs(list) do
    if type(p) == "table" and finite(p.at) and now - p.at <= PullRules.KEEP then
      local q = { at = p.at, people = {} }
      for k, t in pairs(FIELDS) do
        if type(p[k]) == t then q[k] = p[k] end
      end
      if q.name then q.name = cap(q.name, PullRules.BOSSCAP) end
      if type(p.people) == "table" then
        for _, person in ipairs(p.people) do
          if type(person) == "table" and type(person.guid) == "string" and type(person.name) == "string" then
            q.people[#q.people + 1] = { guid = person.guid, name = cap(person.name, PullRules.NAMECAP) }
          end
        end
      else
        q.snapAge = nil
      end
      out[#out + 1] = q
    end
  end
  if #out <= PullRules.CAP then return out end
  local newest = {}
  for i = #out - PullRules.CAP + 1, #out do newest[#newest + 1] = out[i] end
  return newest
end

-- A pull the rules can read (S-f2, S-f3: Prune may not have run): a table with a number at, a table people and a boss
-- name that is a string or absent.
local function readable(p)
  return type(p) == "table" and type(p.at) == "number" and type(p.people) == "table"
    and (p.name == nil or type(p.name) == "string")
end

-- A person the rules can read: a table with a string name.
local function named(v) return type(v) == "table" and type(v.name) == "string" end

-- d1231: a pull belongs to one raid: of the raids whose [start - WINDOW, (finish or start) + WINDOW] holds it, the
-- nearest start before the pull, else the nearest start.
local function owner(at, events)
  local before, after
  for _, e in ipairs(events) do
    local s = e.start
    if type(s) == "number" and at >= s - PullRules.WINDOW and at <= (e.finish or s) + PullRules.WINDOW then
      if s <= at then
        if not before or s > before.start then before = e end
      elseif not after or s < after.start then
        after = e
      end
    end
  end
  return before or after
end

-- The pulls ev owns among events (all raids; { ev } when nil), in at order. A pull whose plain groupSize is 5 or less
-- is a party's (a dungeon), never a raid's; no groupSize still counts (R-f1). Known limit: two teams in different
-- instances at the same hour are not separated.
function PullRules.ForRaid(list, ev, events)
  local out = {}
  if type(list) ~= "table" or type(ev) ~= "table" then return out end
  events = events or { ev }
  for _, p in ipairs(list) do
    if readable(p) and not (type(p.groupSize) == "number" and p.groupSize <= 5) then
      local o = owner(p.at, events)
      if o and (o == ev or (o.key ~= nil and o.key == ev.key)) then out[#out + 1] = p end
    end
  end
  table.sort(out, function(a, b) return a.at < b.at end)
  return out
end

local function byKey(list, key)
  table.sort(list, function(a, b) return key(a.name) < key(b.name) end)
end

-- The four lists over a raid's pulls (d1235: a partition of the people present; d1236: no-shows only over pulls with
-- names). Pulls with no snapAge are hidden and left out of m. Names are compared by key(name); each list is sorted by
-- key. A sign-up with no character name is in no list. An unreadable pull or person is skipped. personOf (optional,
-- Comm.Person) joins a person's characters under their main's key (23.other-char): one count a pull, the name shown is
-- the first present character's; nil, or a name it does not know or with no main, keeps key(name).
function PullRules.Lists(pulls, signups, key, personOf)
  local r = { every = {}, some = {}, noShow = {}, unsigned = {}, m = 0, hidden = 0, kills = 0 }
  local canonOf = {}
  local function canon(name)
    local k = key(name)
    if not k or not personOf then return k end
    if canonOf[k] == nil then
      local p = personOf(name)
      canonOf[k] = (type(p) == "table" and type(p.main) == "string" and p.main ~= "") and p.main or k
    end
    return canonOf[k]
  end
  local seen, order = {}, {}
  for _, p in ipairs(pulls or {}) do
    if readable(p) then
      if p.success == true then r.kills = r.kills + 1 end
      if p.snapAge == nil then
        r.hidden = r.hidden + 1
      else
        r.m = r.m + 1
        local here = {}
        for _, person in ipairs(p.people) do
          local k = named(person) and canon(person.name)
          if k and not here[k] then
            here[k] = true
            local s = seen[k]
            if not s then
              s = { name = person.name, k = 0, first = p.name }
              seen[k] = s
              order[#order + 1] = k
            end
            s.k = s.k + 1
          end
        end
      end
    end
  end
  local signed = {}
  for _, s in ipairs(signups or {}) do
    local k = canon(s.character)
    if k and not signed[k] then signed[k] = s end
  end
  for _, k in ipairs(order) do
    local s = seen[k]
    if not signed[k] then
      r.unsigned[#r.unsigned + 1] = { name = s.name }
    elseif s.k == r.m then
      r.every[#r.every + 1] = { name = s.name }
    else
      r.some[#r.some + 1] = { name = s.name, k = s.k, m = r.m, first = s.first }
    end
  end
  if r.m > 0 then
    for k, s in pairs(signed) do
      if not seen[k] and (s.kind == "primary" or s.kind == "late") then
        r.noShow[#r.noShow + 1] = { name = s.character, kind = s.kind }
      end
    end
  end
  byKey(r.every, key); byKey(r.some, key); byKey(r.noShow, key); byKey(r.unsigned, key)
  return r
end

-- /gsraids pulls: the last n pulls, newest first, "<boss>, <date time>, kill|wipe|no end, <k> people" ("1 person";
-- "names unknown" with no snapAge); an unreadable pull gets no line; with none, one line saying so. when = ns.When in
-- the game.
function PullRules.ChatLines(list, n, when)
  local lines = {}
  list = type(list) == "table" and list or {}
  for i = #list, 1, -1 do
    if #lines >= n then break end
    local p = list[i]
    if readable(p) then
      local result = (p.success == true and "kill") or (p.success == false and "wipe") or "no end"
      local who = (p.snapAge == nil and "names unknown") or (#p.people == 1 and "1 person") or (#p.people .. " people")
      lines[#lines + 1] = (p.name or "Unknown boss") .. ", " .. when("%a %d %b %H:%M", p.at) .. ", " .. result .. ", " .. who
    end
  end
  if #lines == 0 then lines[1] = "No pulls recorded on this character yet." end
  return lines
end
