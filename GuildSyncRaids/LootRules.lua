local _, ns = ...
if not ns.M then return end

-- Pure loot rules (ticket 59): make, hang, put, edit, prune and read loot records. No client calls; only string,
-- table, math and ns.PullRules (looked up at call time). The saved shape is frozen in LOOT-FORMAT.md.
-- store = { next, list = { rec } }; the caller passes now, the pull list, the raid flag and the key function.

local R = { CAP = 500, KEEP = 35 * 86400, ENCWINDOW = 7200, TRASHWINDOW = 1800,
  WHOCAP = 60, WHYCAP = 200, OTHERSCAP = 120, REFCAP = 64, BOSSCAP = 80, AHEAD = 300, MAXID = 2 ^ 31 - 1,
  LISTEN = true, SEENWINDOW = 10, RARE = 3 }
ns.LootRules = R

-- Control bytes stripped, then at most n bytes, never half a UTF-8 character; nil for a non-string or "" (after the
-- strip).
function R.Cut(s, n)
  if type(s) ~= "string" then return nil end
  s = string.gsub(s, "[%z\1-\31\127]", "")
  if s == "" then return nil end
  if #s <= n then return s end
  local cut = string.sub(s, 1, n)
  local nextByte = string.byte(s, n + 1)
  if nextByte >= 128 and nextByte < 192 then cut = string.gsub(cut, "[\192-\255][\128-\191]*$", "") end
  if cut == "" then return nil end
  return cut
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function int(v, lo, hi) return finite(v) and math.floor(v) == v and v >= lo and v <= hi end

local function num(v) if finite(v) then return v end end
local function yes(v) if v == true then return v end end
local function intIn(lo, hi) return function(v) if int(v, lo, hi) then return v end end end
local function cutTo(n) return function(v) return R.Cut(v, n) end end
local function oneOf(...)
  local set = {}
  for _, v in ipairs({ ... }) do set[v] = true end
  return function(v) if v ~= nil and set[v] then return v end end
end

local BIG = 2 ^ 53

-- One rule per LOOT-FORMAT.md field: the value as kept, or nil (dropped). Make, Edit and Prune all use it.
local RULES = {
  id = intIn(1, R.MAXID), at = num, item = intIn(1, 2 ^ 31 - 1),
  src = oneOf("award", "told", "hand", "seen"),
  who = cutTo(R.WHOCAP),
  suffix = function(v) if int(v, -BIG, BIG) and v ~= 0 then return v end end,
  count = intIn(2, BIG), q = intIn(0, 7), guid = cutTo(R.WHOCAP), enc = num,
  ref = function(v) if type(v) == "string" and #v >= 1 and #v <= R.REFCAP then return v end end, -- a key: never cut
  boss = cutTo(R.BOSSCAP), pull = num,
  how = oneOf("council", "sr", "ms", "os", "de", "bank", "need", "greed"),
  roll = intIn(1, 100), why = cutTo(R.WHYCAP), others = cutTo(R.OTHERSCAP), gone = yes, by = cutTo(R.WHOCAP),
  party = yes, seen = oneOf("chat", "enc", "hist"), seenAt = num, held = yes, from = cutTo(R.WHOCAP),
}
local function check(field, v) return RULES[field](v) end

-- A winner is needed unless the item was disenchanted or went to the bank.
local function hasWinner(rec) return rec.who ~= nil or rec.how == "de" or rec.how == "bank" end

-- The optional fields a caller may give Make, the fields Edit may change, and the ones Prune keeps past the core.
local MAKE = { "who", "suffix", "how", "roll", "why", "others", "enc", "boss", "count", "q", "guid", "ref", "from" }
local EDIT = { "who", "how", "roll", "why", "others", "enc", "boss", "gone" }
local KEEPS = { "suffix", "count", "q", "guid", "ref", "enc", "boss", "pull", "how", "roll", "why", "others", "gone",
  "by", "party", "seen", "seenAt", "held", "from" }

function R.Make(t, now, pulls, inRaid)
  if type(t) ~= "table" then return nil, "table" end
  local item = check("item", t.item)
  if not item then return nil, "item" end
  local src = "award"
  if t.src ~= nil then
    if t.src ~= "told" then return nil, "src" end
    src = "told"
  end
  local at = num(t.at) or num(now)
  if not at then return nil, "time" end
  if num(now) and (at < now - R.KEEP or at > now + R.AHEAD) then return nil, "time" end
  if t.ref ~= nil and not check("ref", t.ref) then return nil, "ref" end
  local rec = { at = at, item = item, src = src }
  for _, f in ipairs(MAKE) do rec[f] = check(f, t[f]) end
  if not hasWinner(rec) then return nil, "winner" end
  if inRaid == false then rec.party = true end
  return R.Hang(rec, pulls)
end

-- A kill's end (at + duration), or nil for anything but a kill.
local function killEnd(p)
  if type(p) ~= "table" or p.success ~= true or not finite(p.at) then return nil end
  return p.at + (num(p.duration) or 0)
end

-- With enc: the newest kill of that encounter that ended at or before at and at most ENCWINDOW before it. Without:
-- the newest kill that ended at most TRASHWINDOW before at, with no pull after it up to at; else trash.
function R.Hang(rec, pulls)
  local at, found = rec.at, nil
  if type(pulls) == "table" and finite(at) then
    local window = rec.enc ~= nil and R.ENCWINDOW or R.TRASHWINDOW
    for _, p in ipairs(pulls) do
      local e = killEnd(p)
      if e and e <= at and at - e <= window and (rec.enc == nil or p.encounterID == rec.enc)
          and (not found or p.at > found.at) then
        found = p
      end
    end
    if found and rec.enc == nil then
      for _, p in ipairs(pulls) do
        if type(p) == "table" and type(p.at) == "number" and p.at > found.at and p.at <= at then
          found = nil
          break
        end
      end
    end
  end
  if found then
    rec.pull = found.at
    rec.enc = num(found.encounterID) or rec.enc
    rec.boss = R.Cut(found.name, R.BOSSCAP) or rec.boss
    if type(found.groupSize) == "number" and found.groupSize <= 5 then rec.party = true end
  else
    rec.pull = nil
    if rec.enc == nil then rec.boss = nil end
  end
  return rec
end

local RANK = { hand = 3, award = 2, told = 1, seen = 0 }

-- Past CAP, in place and in one pass: the oldest seen-only records go first, then the oldest records.
local function trim(list)
  local n = #list
  local drop = n - R.CAP
  if drop <= 0 then return list end
  local seen = 0
  for i = 1, n do
    if type(list[i]) == "table" and list[i].src == "seen" then seen = seen + 1 end
  end
  local dropSeen = math.min(drop, seen)
  local dropOther, j = drop - dropSeen, 0
  for i = 1, n do
    local r = list[i]
    local isSeen = type(r) == "table" and r.src == "seen"
    if isSeen and dropSeen > 0 then
      dropSeen = dropSeen - 1
    elseif not isSeen and dropOther > 0 then
      dropOther = dropOther - 1
    else
      j = j + 1
      list[j] = r
    end
  end
  for i = j + 1, n do list[i] = nil end
  return list
end

-- Appends rec with the next id (trim past CAP). A held ref answers its id: replaced in place when rec's source ranks
-- at least as high (carrying seen, seenAt and held, filling q, count and guid), else nothing changes and the second
-- answer is "kept".
function R.Put(store, rec)
  local list = store.list
  if rec.ref ~= nil then
    for i, old in ipairs(list) do
      if type(old) == "table" and old.ref == rec.ref then
        if (RANK[rec.src] or 0) < (RANK[old.src] or 0) then return old.id, "kept" end
        rec.id = old.id
        rec.seen, rec.seenAt, rec.held = old.seen, old.seenAt, old.held
        if rec.q == nil then rec.q = old.q end
        if rec.count == nil then rec.count = old.count end
        if rec.guid == nil then rec.guid = old.guid end
        list[i] = rec
        return rec.id
      end
    end
  end
  if not check("id", store.next) then return nil, "full" end
  rec.id = store.next
  store.next = store.next + 1
  list[#list + 1] = rec
  trim(list)
  return rec.id
end

-- Change one record: every given field is checked before any write; false clears a field. pull = a kill's at moves
-- the record onto that kill (pull, enc, boss), pull = false moves it to trash; neither re-hangs.
function R.Edit(rec, t, by, pulls)
  if type(t) ~= "table" then return nil, "table" end
  local new, any = {}, false
  for _, f in ipairs(EDIT) do
    local v = t[f]
    if v ~= nil then
      any = true
      if v == false then
        new[f] = false
      else
        local c = check(f, v)
        if c == nil then return nil, f end
        new[f] = c
      end
    end
  end
  local kill
  if t.pull ~= nil then
    any = true
    if t.pull ~= false then
      for _, p in ipairs(type(pulls) == "table" and pulls or {}) do
        if killEnd(p) and p.at == t.pull then kill = p end
      end
      if not kill then return nil, "pull" end
    end
  end
  if not any then return nil, "nothing" end
  local function after(f)
    if new[f] == nil then return rec[f] end
    return new[f] or nil
  end
  if not hasWinner({ who = after("who"), how = after("how") }) then return nil, "winner" end
  for f, v in pairs(new) do rec[f] = v or nil end
  if new.who ~= nil then rec.guid = nil end -- the guid was the old winner's
  rec.src = "hand"
  rec.by = check("by", by)
  if kill then
    rec.pull, rec.enc, rec.boss = kill.at, num(kill.encounterID), R.Cut(kill.name, R.BOSSCAP)
  elseif t.pull == false then
    rec.pull, rec.enc, rec.boss = nil, nil, nil
  elseif new.enc ~= nil then
    R.Hang(rec, pulls)
    -- a boss given in this Change stays when the re-hang finds no kill
    if new.boss and rec.pull == nil then rec.boss = new.boss end
  end
  return true
end

local function near(a, b, window)
  return finite(a.at) and finite(b.at) and math.abs(a.at - b.at) <= window
end

-- The same drop of the same kill: same item and suffix, and the same pull; or, when either has no pull, the same enc
-- within ENCWINDOW; or both without enc within TRASHWINDOW.
function R.SameKill(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or a.item ~= b.item or a.suffix ~= b.suffix then return false end
  if a.pull ~= nil and b.pull ~= nil then return a.pull == b.pull end
  if a.enc ~= nil or b.enc ~= nil then return a.enc == b.enc and near(a, b, R.ENCWINDOW) end
  return near(a, b, R.TRASHWINDOW)
end

-- held, seen, or "other" with the winner of a disagreeing seen-only record of the same kill (R.SameKill).
function R.State(list, rec, keyFn)
  if type(rec) ~= "table" then return nil end
  if rec.held == true then return "held" end
  if rec.seen ~= nil then return "seen" end
  local mine = keyFn(rec.who)
  for _, r in ipairs(type(list) == "table" and list or {}) do
    if type(r) == "table" and r ~= rec and r.src == "seen" and R.SameKill(r, rec) then
      local theirs = keyFn(r.who)
      if theirs ~= mine then return "other", r.who end
    end
  end
  return nil
end

-- The newest unstruck council record whose keyFn(who) is key.
function R.LastCouncil(list, key, keyFn)
  local best
  for _, r in ipairs(type(list) == "table" and list or {}) do
    if type(r) == "table" and r.how == "council" and r.gone ~= true and type(r.at) == "number"
        and (not best or r.at > best.at) then
      local k = keyFn(r.who)
      if k ~= nil and k == key then best = r end
    end
  end
  if not best then return nil end
  return { item = best.item, suffix = best.suffix, at = best.at }
end

-- A new store: every record rebuilt from the LOOT-FORMAT.md fields and re-checked; broken, duplicate-id and
-- older-than-KEEP records dropped, trimmed past CAP as Put does, next at least the highest id + 1. With quality(item),
-- a seen-only record learns its q, and one below Rare is dropped. listen is kept as true or false.
function R.Prune(store, now, quality)
  local old = type(store) == "table" and store or {}
  local kept, seenId, top = {}, {}, 0
  for _, r in ipairs(type(old.list) == "table" and old.list or {}) do
    if type(r) == "table" then
      local id, at = check("id", r.id), check("at", r.at)
      if id and not seenId[id] and at
          and (type(now) ~= "number" or (now - at <= R.KEEP and at <= now + R.AHEAD)) then
        local rec = { id = id, at = at, item = check("item", r.item), src = check("src", r.src), who = check("who", r.who) }
        for _, f in ipairs(KEEPS) do rec[f] = check(f, r[f]) end
        if rec.item and rec.src and hasWinner(rec) then
          if id > top then top = id end
          if rec.src == "seen" and type(quality) == "function" then
            local q = check("q", quality(rec.item))
            if q then rec.q = q end
          end
          if rec.src ~= "seen" or R.Rare(rec.q) then
            seenId[id] = true
            kept[#kept + 1] = rec
          end
        end
      end
    end
  end
  local nextId = check("id", old.next) or 1
  if nextId <= top then nextId = top + 1 end
  local out = { next = nextId, list = trim(kept) }
  if type(old.listen) == "boolean" then out.listen = old.listen end
  return out
end

-- The records ev owns (PullRules' owner rule over events; party records never), grouped by their pull among the
-- pulls ev owns, in pull order; a record with no owned pull goes under its boss when it has enc, else under trash.
function R.ForRaid(list, ev, events, pulls)
  local out = { trash = { rows = {} } }
  local PR = ns.PullRules
  if type(PR) ~= "table" or type(PR.ForRaid) ~= "function" then return out end
  if type(events) ~= "table" then events = {} end
  local wraps = {}
  for _, r in ipairs(type(list) == "table" and list or {}) do
    if type(r) == "table" and r.party ~= true and type(r.at) == "number" then
      wraps[#wraps + 1] = { at = r.at, people = {}, rec = r }
    end
  end
  local ownedPull = {}
  for _, p in ipairs(PR.ForRaid(type(pulls) == "table" and pulls or {}, ev, events)) do ownedPull[p.at] = p end
  local groups, sortAt = {}, {}
  for _, w in ipairs(PR.ForRaid(wraps, ev, events)) do
    local r = w.rec
    local p = r.pull ~= nil and ownedPull[r.pull] or nil
    local gk = (p and ("pull " .. r.pull)) or (r.enc ~= nil and ("enc " .. r.enc)) or nil
    if gk then
      local g = groups[gk]
      if not g then
        g = { boss = r.boss or (p and p.name), enc = r.enc, pull = p and r.pull or nil, rows = {} }
        groups[gk] = g
        out[#out + 1] = g
        sortAt[g] = p and p.at or r.at
      end
      g.rows[#g.rows + 1] = r
    else
      out.trash.rows[#out.trash.rows + 1] = r
    end
  end
  table.sort(out, function(a, b) return sortAt[a] < sortAt[b] end)
  return out
end

-- The one-word source.
function R.Word(rec)
  if rec.src == "hand" then return "by hand" end
  if rec.src == "seen" then return "seen" end
  if rec.seen ~= nil then return "awarded, seen" end
  return "awarded"
end

-- The winner line, unescaped: "Guild bank", "Disenchanted by Name", a name; " (roll)" after a roll.
function R.Winner(rec)
  if rec.how == "bank" then return "Guild bank" end
  local s = rec.who or "Unknown"
  if rec.how == "de" then s = rec.who and ("Disenchanted by " .. rec.who) or "Disenchanted" end
  if rec.roll ~= nil then s = s .. " (" .. tostring(rec.roll) .. ")" end
  return s
end

-- /gsraids loot: the last n records, newest first, "<name or item #id>: <winner>, <boss or trash>, <time>, <word>";
-- with none, one line saying so. A row's name is the caller's (not a saved field). when = ns.When in the game.
function R.ChatLines(list, n, when)
  local lines = {}
  list = type(list) == "table" and list or {}
  for i = #list, 1, -1 do
    if #lines >= n then break end
    local r = list[i]
    if type(r) == "table" then
      local label = type(r.name) == "string" and r.name ~= "" and r.name or ("item #" .. tostring(r.item))
      lines[#lines + 1] = label .. ": " .. R.Winner(r) .. ", " .. (r.boss or "trash") .. ", "
        .. when("%a %d %b %H:%M", r.at) .. ", " .. R.Word(r)
    end
  end
  if #lines == 0 then lines[1] = "No loot recorded on this character yet." end
  return lines
end

-- One line: the record count, the caps and this session's recorded, kept and refused.
function R.Counters(store, session)
  local list = type(store) == "table" and type(store.list) == "table" and store.list or {}
  session = type(session) == "table" and session or {}
  return string.format("%d loot records (at most %d, %d days); this session: %d recorded, %d kept, %d refused",
    #list, R.CAP, R.KEEP / 86400, session.recorded or 0, session.kept or 0, session.refused or 0)
end

-- The listener's sentence for the counters line.
function R.ListenLine(on, c)
  c = type(c) == "table" and c or {}
  return string.format("listener %s: %d lines seen, %d records made, %d lines hidden, %d lines skipped",
    on and "on" or "off", tonumber(c.seen) or 0, tonumber(c.made) or 0, tonumber(c.hidden) or 0,
    tonumber(c.skipped) or 0)
end

-- ---------- the loot line ----------

local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

-- One client format as an anchored pattern with the capture index of the winner (a name has no colon), the link and
-- the count; nil for an unknown % code, no %s, more than two %s or more than one %d. With two %s the lower argument
-- is the winner.
local function pattern(f)
  local parts, args, i = { "^" }, {}, 1
  while i <= #f do
    local c = string.sub(f, i, i)
    if c == "%" then
      local pos, kind, nxt = string.match(f, "^(%d+)%$([sd])()", i + 1)
      if not pos then kind, nxt = string.match(f, "^([sd])()", i + 1) end
      if string.sub(f, i + 1, i + 1) == "%" then
        parts[#parts + 1] = "%%"
        i = i + 2
      elseif not kind then
        return nil
      else
        parts[#parts + 1] = kind == "s" and "(.+)" or "(%d+)"
        args[#args + 1] = { arg = tonumber(pos) or (#args + 1), kind = kind, part = #parts }
        i = nxt
      end
    else
      parts[#parts + 1] = (string.gsub(c, MAGIC, "%%%0"))
      i = i + 1
    end
  end
  local strs, count = {}, nil
  for n, a in ipairs(args) do
    if a.kind == "s" then
      strs[#strs + 1] = n
    elseif count then
      return nil
    else
      count = n
    end
  end
  if #strs == 0 or #strs > 2 then return nil end
  if #strs == 2 and args[strs[2]].arg < args[strs[1]].arg then strs[1], strs[2] = strs[2], strs[1] end
  local p = { link = strs[#strs], count = count }
  if #strs == 2 then
    p.who = strs[1]
    parts[args[p.who].part] = "([^:]+)"
  end
  p.pat = table.concat(parts) .. "$"
  return p
end

-- The client's loot formats as patterns, each once; the ones with a count first, so a single format never takes a
-- multiple line's "x3".
function R.Patterns(formats)
  local counted, plain, done = {}, {}, {}
  for _, f in ipairs(type(formats) == "table" and formats or {}) do
    if type(f) == "string" and not done[f] then
      done[f] = true
      local p = pattern(f)
      if p and p.count then
        counted[#counted + 1] = p
      elseif p then
        plain[#plain + 1] = p
      end
    end
  end
  for _, p in ipairs(plain) do counted[#counted + 1] = p end
  return counted
end

-- link, who, count of a loot line, or nil; who nil is a "you receive" line. A line with no item link reads no
-- pattern; a line that matches none allocates nothing.
function R.ParseLine(text, pats)
  if type(text) ~= "string" or not string.find(text, "|Hitem:", 1, true) then return nil end
  for i = 1, #pats do
    local p = pats[i]
    local a, b, c = string.match(text, p.pat)
    if a then
      local who = p.who and (select(p.who, a, b, c)) or nil
      local count = p.count and tonumber((select(p.count, a, b, c))) or nil
      return (select(p.link, a, b, c)), who, count
    end
  end
  return nil
end

local QUALITY = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5, e6cc80 = 6,
  ["00ccff"] = 7 }

-- A link's quality from its colour code (|cnIQ<d>: or one of the eight |cff colours), else nil.
function R.LinkQuality(link)
  if type(link) ~= "string" then return nil end
  local d = string.match(link, "^|cnIQ(%d):")
  if d then return check("q", tonumber(d)) end
  local hex = string.match(link, "^|c[fF][fF](%x%x%x%x%x%x)")
  return hex and QUALITY[string.lower(hex)] or nil
end

-- A name without its "-Realm" part.
function R.Bare(name)
  if type(name) ~= "string" then return name end
  return string.match(name, "^([^%-]+)") or name
end

-- The winner of a line: the text's name (me on a "you receive" line). The guid is kept, with the snapshot's spelling,
-- only when the newest pull's people hold it under the same name (realm part ignored). No name: nil.
function R.Receiver(pulls, guid, name, isSelf, me)
  if isSelf then name = me end
  if type(name) ~= "string" or name == "" then return nil end
  local newest
  for _, p in ipairs(type(pulls) == "table" and pulls or {}) do
    if type(p) == "table" and finite(p.at) and (not newest or p.at > newest.at) then newest = p end
  end
  if guid ~= nil and newest and type(newest.people) == "table" then
    local mine = string.lower(R.Bare(name))
    for _, person in ipairs(newest.people) do
      if type(person) == "table" and person.guid == guid and type(person.name) == "string"
          and string.lower(R.Bare(person.name)) == mine then
        return person.name, guid
      end
    end
  end
  return name
end

-- Rare and up, or an unknown quality.
function R.Rare(q) return q == nil or (type(q) == "number" and q >= R.RARE) end

-- Worth keeping: Rare or unknown, or a decision record of that item and suffix within ENCWINDOW. The whole list is
-- scanned: it is not ordered by at (Add appends old drops).
function R.Worth(list, item, suffix, q, at)
  if R.Rare(q) then return true end
  if type(list) ~= "table" or not finite(at) then return false end
  for i = #list, 1, -1 do
    local r = list[i]
    if type(r) == "table" and r.src ~= "seen" and r.item == item and r.suffix == suffix and finite(r.at)
        and math.abs(r.at - at) <= R.ENCWINDOW then
      return true
    end
  end
  return false
end

-- A seen-only record from a sighting s = { item, suffix, count, q, who, guid, at, seen, enc }, made and hung as Make.
function R.Sighting(s, now, pulls, inRaid)
  if type(s) ~= "table" then return nil, "table" end
  local seen = check("seen", s.seen)
  if not seen then return nil, "seen" end
  local rec, why = R.Make({ item = s.item, suffix = s.suffix, count = s.count, q = s.q, who = s.who, guid = s.guid,
    at = s.at, enc = s.enc }, now, pulls, inRaid)
  if not rec then return nil, why end
  rec.src, rec.seen, rec.seenAt = "seen", seen, rec.at
  return rec
end

-- A record added by hand: Make with no src and no from, then src "hand" and by.
function R.Add(t, by, now, pulls)
  if type(t) ~= "table" then return nil, "table" end
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  c.src, c.from = nil, nil
  local rec, why = R.Make(c, now, pulls)
  if not rec then return nil, why end
  rec.src, rec.by = "hand", check("by", by)
  return rec
end

-- ---------- pairing ----------

local function realmOf(name) return type(name) == "string" and string.match(name, "%-(.+)$") or nil end

-- The same name key. Two realm parts must be the same realm; the second answer is true when only one name had a
-- realm part (a match that needed the realm stripped, so no guid is copied on it).
local function keyEq(a, b, keyFn)
  local ra, rb = realmOf(a), realmOf(b)
  if ra and rb and string.lower(ra) ~= string.lower(rb) then return false end
  local k = keyFn(R.Bare(a))
  return k ~= nil and k == keyFn(R.Bare(b)), (ra == nil) ~= (rb == nil)
end

-- The same winner: by guid when both have one, else by name key (keyEq's second answer too).
local function sameWho(a, b, keyFn)
  if a.guid ~= nil and b.guid ~= nil then return a.guid == b.guid, false end
  return keyEq(a.who, b.who, keyFn)
end

-- A decision record dec and a seen-only record s of one drop: "same" winner, "held" (the receiver is dec's from), or
-- nil; an already paired dec never pairs. The second answer: copy no guid.
local function partner(dec, s, keyFn)
  if dec.seen ~= nil or dec.held == true or not R.SameKill(dec, s) then return nil end
  local same, bare = sameWho(dec, s, keyFn)
  if same then return "same", bare end
  if dec.from ~= nil and keyEq(dec.from, s.who, keyFn) then return "held", true end
  return nil
end

local function absorb(dec, s, held, noGuid)
  dec.seen, dec.seenAt = s.seen, s.seenAt
  if dec.q == nil then dec.q = s.q end
  if dec.count == nil then dec.count = s.count end
  if held then dec.held = true end
  if not held and not noGuid and dec.guid == nil then dec.guid = s.guid end
end

-- r, already seen by the other listener within SEENWINDOW: same item and suffix, and the same receiver (r's from
-- when r is held, else r's winner). A saved r with a broken at or seenAt is never a twin.
local function twin(r, s, keyFn)
  if r.seen == nil or r.seen == s.seen or r.item ~= s.item or r.suffix ~= s.suffix
      or not finite(r.at) or not finite(s.at)
      or not finite(r.seenAt) or not finite(s.seenAt) or math.abs(r.seenAt - s.seenAt) > R.SEENWINDOW then
    return false
  end
  if r.held == true then return keyEq(r.from, s.who, keyFn), true end
  return sameWho(r, s, keyFn)
end

local function fold(r, s, noGuid)
  if r.src == "seen" then
    if s.seen == "enc" then r.enc, r.boss, r.pull = s.enc, s.boss, s.pull end
    if s.at < r.at then r.at = s.at end
  end
  r.seen = "enc"
  if s.seenAt < r.seenAt then r.seenAt = s.seenAt end
  if r.q == nil then r.q = s.q end
  if r.count == nil then r.count = s.count end
  if r.held ~= true and not noGuid and r.guid == nil then r.guid = s.guid end
end

-- The one entry for a new record (LOOT-FORMAT.md, the Merge table): a held ref first (Put's rule), then a partner,
-- then a twin, else appended; a sighting below Rare with no partner writes nothing. Answers id, kind.
function R.Merge(store, rec, keyFn)
  local list = store.list
  if rec.src ~= "seen" then
    if rec.ref ~= nil then
      for _, old in ipairs(list) do
        if type(old) == "table" and old.ref == rec.ref then
          local id, kept = R.Put(store, rec)
          return id, kept or "ref"
        end
      end
    end
    for i, r in ipairs(list) do
      if type(r) == "table" and r.src == "seen" then
        local kind, bare = partner(rec, r, keyFn)
        if kind then
          rec.id = r.id
          absorb(rec, r, kind == "held", bare)
          list[i] = rec
          return rec.id, kind
        end
      end
    end
  else
    for _, r in ipairs(list) do
      if type(r) == "table" and r.src ~= "seen" then
        local kind, bare = partner(r, rec, keyFn)
        if kind then
          absorb(r, rec, kind == "held", bare)
          return r.id, kind
        end
      end
    end
    for _, r in ipairs(list) do
      if type(r) == "table" then
        local hit, bare = twin(r, rec, keyFn)
        if hit then
          fold(r, rec, bare)
          return r.id, "twin"
        end
      end
    end
    if not R.Rare(rec.q) then return nil, "quality" end
  end
  local id, why = R.Put(store, rec)
  if not id then return nil, why end
  return id, "new"
end

-- After a Change of who on rec (wasSeen: rec's src before the edit was "seen"): joins rec with its partner by Merge's
-- rule. The decision record keeps its id and position and takes the seen fields (and, when it is the other row, the
-- new who, src "hand" and by); the seen-only row is removed and its id answered.
function R.Rejoin(list, rec, wasSeen, keyFn)
  if type(list) ~= "table" or type(rec) ~= "table" then return nil end
  for _, r in ipairs(list) do
    if type(r) == "table" and r ~= rec then
      local dec, s
      if wasSeen and r.src ~= "seen" then
        dec, s = r, rec
      elseif not wasSeen and r.src == "seen" then
        dec, s = rec, r
      end
      local kind, bare
      if dec then kind, bare = partner(dec, s, keyFn) end
      if kind then
        absorb(dec, s, kind == "held", bare)
        if dec == r then
          if kind == "same" then dec.who = s.who end
          dec.src, dec.by = "hand", s.by
        end
        for j, x in ipairs(list) do
          if x == s then
            table.remove(list, j)
            break
          end
        end
        return s.id
      end
    end
  end
  return nil
end

-- One pass per item id: held, seen, or "other" with the winner of a disagreeing seen-only record of the same kill;
-- a seen-only row also gets the award it disagrees with. keyFn runs once per record at most.
function R.Marks(list, keyFn)
  local out, groups, keys = {}, {}, {}
  local function k(r)
    local v = keys[r]
    if v == nil then
      v = keyFn(r.who) or false
      keys[r] = v
    end
    return v
  end
  for _, r in ipairs(type(list) == "table" and list or {}) do
    if type(r) == "table" and r.id ~= nil and r.item ~= nil then
      local g = groups[r.item]
      if not g then
        g = {}
        groups[r.item] = g
      end
      g[#g + 1] = r
    end
  end
  for _, g in pairs(groups) do
    for _, r in ipairs(g) do
      local m, mine = {}, r.src == "seen"
      if r.held == true then m.state = "held" elseif r.seen ~= nil then m.state = "seen" end
      if mine or m.state == nil then
        for _, o in ipairs(g) do
          if o ~= r and (o.src == "seen") ~= mine and R.SameKill(o, r) and k(o) ~= k(r) then
            if mine then m.award = o else m.state, m.other = "other", o.who end
            break
          end
        end
      end
      out[r.id] = m
    end
  end
  return out
end
