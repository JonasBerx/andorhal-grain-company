-- GuildSync CraftStore: the crafter directory rules (key, digest, compare, merge, tombstone, own records,
-- guild-only, prune, the per-domain limit). Pure Lua 5.1, no client calls: state and time are passed in.
-- Messages are decoded tables in CraftWire.Unpack's shape; CraftWire itself is not needed here.
local _, ns = ...
local CraftStore = {}
ns.CraftStore = CraftStore

local DAY = 86400
local FUTURE = 300            -- any time later than now + 300 is refused (R4)
local HASH_DAYS = 14          -- dirHash covers crafters seen within the smallest retention
local DIGEST_WINDOW = 300     -- one round and one digest per sender per 5 min, per domain
local RATE_WINDOW = 60        -- the rates are per sender per minute

-- Adler-32 of the bytes as 8 lowercase hex digits (a local copy of addon/GuildKOS/Codec.lua:11-18).
local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end
CraftStore.Adler32 = adler32

-- Keys -----------------------------------------------------------------------------------------------------------

-- Character name -> key: realm cut at the first "-", lowercased, trimmed, inner whitespace collapsed. nil if empty.
function CraftStore.Key(name)
  if type(name) ~= "string" then return nil end
  local k = (name:match("^([^-]*)") or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

local function isOpenEnd(v) return v == nil or v == "" end

local function inRange(key, from, to)
  return (isOpenEnd(from) or key >= from) and (isOpenEnd(to) or key <= to)
end

local function stale(seen, now, retentionDays)
  return retentionDays and retentionDays > 0 and now - (seen or 0) > retentionDays * DAY
end

-- Digest ---------------------------------------------------------------------------------------------------------

-- Every crafter (own and tombstoned included), sorted by key; dirHash covers key,stamp of those seen within 14 days.
function CraftStore.Digest(crafters, now)
  local keys = {}
  for key in pairs(crafters) do keys[#keys + 1] = key end
  table.sort(keys)
  local entries, parts = {}, {}
  for _, key in ipairs(keys) do
    local r = crafters[key]
    entries[#entries + 1] = { key = key, stamp = r.stamp, seen = r.seen }
    if now - (r.seen or 0) <= HASH_DAYS * DAY then parts[#parts + 1] = key .. "," .. tostring(r.stamp) end
  end
  return entries, adler32(table.concat(parts, ";"))
end

-- Compare --------------------------------------------------------------------------------------------------------

-- A D part: what I may send (mine newer, or theirs missing inside the part's range) and what I may ask
-- (theirs newer, or mine missing; stamp 0 when I lack it). Entries seen before my retention are skipped.
-- An R (kind d): send only keys whose stored stamp is strictly newer than the stamp asked; never ask back.
function CraftStore.Compare(crafters, part, now, retentionDays)
  local send, ask = {}, {}
  if part.t == "R" then
    for _, e in ipairs(part.entries or {}) do
      local mine = crafters[e.key]
      if mine and (mine.stamp or 0) > (tonumber(e.stamp) or 0) then send[#send + 1] = e.key end
    end
    return send, ask
  end
  local listed = {}
  for _, e in ipairs(part.entries or {}) do
    listed[e.key] = true
    if not stale(e.seen, now, retentionDays) then
      local mine = crafters[e.key]
      -- f1023; never past now + FUTURE (f4540)
      if mine and mine.stamp == e.stamp and e.seen > (mine.seen or 0) then mine.seen = math.min(e.seen, now + FUTURE) end
      if not mine then
        ask[#ask + 1] = { key = e.key, stamp = 0 }
      elseif mine.stamp > e.stamp then
        send[#send + 1] = e.key
      elseif mine.stamp < e.stamp then
        ask[#ask + 1] = { key = e.key, stamp = mine.stamp }
      end
    end
  end
  for key, mine in pairs(crafters) do
    if not listed[key] and inRange(key, part.from, part.to) and not stale(mine.seen, now, retentionDays) then
      send[#send + 1] = key
    end
  end
  table.sort(send)
  return send, ask
end

-- Merge ----------------------------------------------------------------------------------------------------------

local function profsMap(list)
  local out = {}
  for _, p in ipairs(list or {}) do out[p.skill] = { rank = p.rank, max = p.max, packed = p.packed } end
  return out
end
CraftStore.ProfsMap = profsMap

-- A P from the wire. Refused: no key, a far-future stamp or seen, a subject off the roster, an own character.
function CraftStore.Merge(crafters, msg, now, rosterKeys, ownKeys)
  local key = CraftStore.Key(msg.name)
  local stamp, seen = tonumber(msg.stamp), tonumber(msg.seen) or 0
  if not key or not stamp then return "refused" end
  if stamp > now + FUTURE or seen > now + FUTURE then return "refused" end
  if not (rosterKeys and rosterKeys[key]) then return "refused" end
  if ownKeys and ownKeys[key] then return "refused" end

  local stored = crafters[key]
  if stored and stamp < stored.stamp then return "older" end
  if stored and stamp == stored.stamp then
    if seen > (stored.seen or 0) then stored.seen = seen end
    return "same"
  end
  local profs = profsMap(msg.profs)
  local gone = next(profs) == nil or nil
  crafters[key] = { name = msg.name, class = msg.class, stamp = stamp,
                    seen = math.max(seen, stored and stored.seen or 0), gone = gone, profs = profs }
  return stored and "newer" or "new"
end

-- Own records ----------------------------------------------------------------------------------------------------

-- Canonical profs field: skill,rank,max,packed per skill line, sorted by skill. The directory domain's
-- content(key) (D13: one hash form, the hub stamps with Wire.Hash of it).
local function profsString(profs)
  local skills = {}
  for skill in pairs(profs or {}) do skills[#skills + 1] = skill end
  table.sort(skills)
  local parts = {}
  for i, skill in ipairs(skills) do
    local p = profs[skill]
    parts[i] = table.concat({ tostring(skill), tostring(p.rank), tostring(p.max), tostring(p.packed) }, ",")
  end
  return table.concat(parts, ";")
end
CraftStore.ProfsString = profsString

local function profsHash(profs) return adler32(profsString(profs)) end
CraftStore.ProfsHash = profsHash

-- Re-stamps when the hash changed (max(now, stamp + 1)) or when a foreign P about this character with a stamp
-- >= mine and another hash was heard (max(now, heard + 1)). Returns stamp, changed.
function CraftStore.OwnRecord(own, key, profs, now, heard)
  local o = own[key]
  if not o then o = {}; own[key] = o end
  local hash = profsHash(profs)
  local old = o.stamp or 0
  local stamp = old
  if o.hash ~= hash then stamp = math.max(now, old + 1) end
  if heard and tonumber(heard.stamp) and tonumber(heard.stamp) >= old and heard.hash ~= hash then
    stamp = math.max(stamp, now, tonumber(heard.stamp) + 1)
  end
  o.hash, o.seen = hash, now
  local changed = stamp ~= old
  o.stamp = stamp
  return stamp, changed
end

-- Sharing off: our tombstone P for one own character, with a new stamp. The caller fills in name and class.
function CraftStore.Tombstone(own, key, now)
  local o = own[key]
  if not o then o = {}; own[key] = o end
  local stamp = math.max(now, (o.stamp or 0) + 1)
  o.stamp, o.hash = stamp, profsHash({})
  return { t = "P", stamp = stamp, seen = o.seen or now, profs = {} }
end

-- Prune ----------------------------------------------------------------------------------------------------------

-- Leavers go (unless the roster is partial); so does anyone not seen within retention (0 = never).
function CraftStore.Prune(crafters, rosterKeys, partial, now, retentionDays)
  local removed = {}
  for key, r in pairs(crafters) do
    if (not partial and not rosterKeys[key]) or stale(r.seen, now, retentionDays) then removed[#removed + 1] = key end
  end
  for _, key in ipairs(removed) do crafters[key] = nil end
  table.sort(removed)
  return removed
end

-- Answer guard (pull model) ----------------------------------------------------------------------------------------

function CraftStore.AnswerDelay(r, peers, isOwner)
  if isOwner then return 0.5 end
  peers = math.min(tonumber(peers) or 0, 60)
  return 2 + r * math.max(4, 2 * peers)
end

-- A want is still worth sending: P = I hold the subject at the wanted stamp; R = my stamp (0 if none) is still the
-- one I asked with; D = always.
function CraftStore.StillWanted(crafters, want, now)
  local mine = crafters[want.subject]
  if want.t == "P" then return mine ~= nil and mine.stamp == tonumber(want.version) end
  if want.t == "R" then return (mine and mine.stamp or 0) == (tonumber(want.version) or 0) end
  if want.t == "D" then return true end
  return false
end

-- Rate limits ----------------------------------------------------------------------------------------------------

-- NewLimit(rates, window) -> limit(from, kind, subject, version, n, t), the hub's limit hook (called once per message
-- at its first chunk), with its own counters (one per domain, D16, f4103, f4113).
-- rates: per-minute cap per kind per sender; a string value names the kind whose counter it shares (X = "C"). F and
-- P at 60 are what one sender's send gate can push (f1060).
-- window = { round = <kind>, digest = <kind>, parts = <bool> }: one round per sender per DIGEST_WINDOW; one digest
-- "-" per sender per DIGEST_WINDOW, or (parts) the parts "p.n" of a single n with no p repeated. A refused message
-- counts nothing.
function CraftStore.NewLimit(rates, window)
  rates, window = rates or {}, window or {}
  local rounds, digests, counts = {}, {}, {}
  return function(from, kind, subject, _, _, t)
    t = tonumber(t) or 0
    if kind == window.round then
      local last = rounds[from]
      if last and t - last < DIGEST_WINDOW then return false end
      rounds[from] = t
      return true
    end
    if kind == window.digest then
      local p, n
      if subject ~= "-" then
        if not window.parts then return false end
        p, n = string.match(tostring(subject), "^(%d+)%.(%d+)$")
        p, n = tonumber(p), tonumber(n)
        if not p or not n or p < 1 or p > n then return false end
      end
      local cur = digests[from]
      if cur and t - cur.at < DIGEST_WINDOW then
        if not n or cur.n ~= n or cur.parts[p] then return false end
        cur.parts[p] = true
        return true
      end
      digests[from] = { at = t, n = n, parts = p and { [p] = true } or {} }
      return true
    end
    local counter = type(rates[kind]) == "string" and rates[kind] or kind
    local cap = tonumber(rates[counter])
    if not cap then return true end
    local bySender = counts[counter]
    if not bySender then bySender = {} counts[counter] = bySender end
    local kept = {}
    for _, at in ipairs(bySender[from] or {}) do if t - at < RATE_WINDOW then kept[#kept + 1] = at end end
    bySender[from] = kept
    if #kept >= cap then return false end
    kept[#kept + 1] = t
    return true
  end
end
