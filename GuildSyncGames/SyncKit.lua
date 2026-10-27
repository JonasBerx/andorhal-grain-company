-- GuildSyncGames SyncKit.lua (Task 4): the sync helpers Sync.lua ("games") and Boards.lua ("games_g") share, moved out
-- of Sync.lua unchanged: adler (the hash), newer (rev, then hash), the codec (Hello.lua's) and the limit per subject key.
-- ns.SyncKit.Limiter(maxRevs, window, maxSubjects) makes one limit with its own buckets and its own rosterKnown, so each
-- domain counts its own revs; setKnown is for the domain's rosterRead handler.

local _, ns = ...

if not ns.M then return end

local SEP = "~"
local K = {}
ns.SyncKit = K

function K.newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

function K.adler(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

-- ---------- the codec (Hello.lua's) ----------

function K.pack(m)
  if type(m) ~= "table" then return nil end
  if m.t == "P" then
    return table.concat({ "P", m.key, tostring(m.rev), m.hash or "", m.by or "", m.body or "" }, SEP)
  end
  if m.t == "H" then return "H" .. SEP .. (m.hash or "") end
  if m.t == "D" or m.t == "R" then
    local list = {}
    for _, e in ipairs(m.entries or {}) do list[#list + 1] = e.key .. "," .. tostring(e.rev or 0) .. "," .. (e.hash or "") end
    return m.t .. SEP .. table.concat(list, ";")
  end
  return nil
end

function K.unpack(logical)
  if type(logical) ~= "string" then return nil end
  local f = {}
  for x in (logical .. SEP):gmatch("([^~]*)~") do f[#f + 1] = x end
  local t = f[1]
  if t == "P" then
    local rev = tonumber(f[3])
    if not rev or not f[2] or f[2] == "" then return nil end
    return { t = "P", key = f[2], rev = rev, hash = f[4], by = f[5], body = f[6] or "" }
  end
  if t == "H" then return { t = "H", hash = f[2] or "" } end
  if t == "D" or t == "R" then
    local entries = {}
    for e in ((f[2] or "") .. ";"):gmatch("([^;]*);") do
      local k, r, h = e:match("^([^,]*),([^,]*),(.*)$")
      if k then entries[#entries + 1] = { key = k, rev = tonumber(r) or 0, hash = h } end
    end
    return { t = t, entries = entries }
  end
  return nil
end

-- ---------- the limit: per subject key, any sender (f7061) ----------

-- maxRevs new revs of one subject key per window seconds; at most maxSubjects buckets are tracked (a memory bound).
function K.Limiter(maxRevs, window, maxSubjects)
  local seen, seenN = {}, 0 -- subject -> { [version] = first heard at }

  local function expire(s, t)
    local live = 0
    for v, at in pairs(s) do
      if t - at >= window then s[v] = nil else live = live + 1 end
    end
    return live
  end

  -- The bucket for subject and its live count; nil when maxSubjects live buckets are held.
  local function bucket(subject, t)
    local s = seen[subject]
    if s then return s, expire(s, t) end
    if seenN >= maxSubjects then
      for k, x in pairs(seen) do
        if expire(x, t) == 0 then seen[k], seenN = nil, seenN - 1 end
      end
      if seenN >= maxSubjects then return nil end
    end
    s = {}
    seen[subject], seenN = s, seenN + 1
    return s, 0
  end

  -- True when version is already in s, or s has room for it (then it is recorded).
  local function admit(s, live, version, t)
    if not s then return false end
    if s[version] then return true end
    if live >= maxRevs then return false end
    s[version] = t
    return true
  end

  -- Nothing passes before the roster is known. A key off the known roster is not tracked (the hub refuses it as off
  -- the roster), so junk subjects never fill maxSubjects. The owner's own sends are held only by a bucket of her own,
  -- so a relay's junk for her key cannot hold her back; every send still counts in the subject's bucket.
  -- Read once here (the hub keeps the last roster) and at each rosterRead (setKnown), so no P reads the whole roster
  -- (f7130).
  local rosterKnown = select(4, ns.Roster()) and true or false

  local function limit(from, kind, subject, version, _, t)
    if kind ~= "P" then return true end
    if not rosterKnown then -- until a read says known: asked here, then never again per P
      rosterKnown = select(4, ns.Roster()) and true or false
      if not rosterKnown then return false end
    end
    if ns.Member(subject) == nil then return true end
    t, version = tonumber(t) or 0, tostring(version)
    local s, live = bucket(subject, t)
    if from and ns.Key(from) == subject then
      local own, ownLive = bucket(subject .. "\0own", t)
      if not admit(own, ownLive, version, t) then return false end
      if s and not s[version] then s[version] = t end
      return true
    end
    return admit(s, live, version, t)
  end

  return { limit = limit, setKnown = function(known) rosterKnown = known and true or false end }
end
