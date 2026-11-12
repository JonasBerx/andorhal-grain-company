-- GuildSyncExpeditions Sync.lua (slice I, plan Task 2): the "expeditions" record domain on GSync, officer hides and the
-- bank recipient.
--   ns.GuildRecord(key) -> view, rev | nil        a stored record, unpacked; nil in demo
--   ns.GuildRecords() -> { { key, group, rev, view, owner, you }, ... }   the fold (Seams), newest rev first; {} in demo
--   ns.GuildCount() -> "12" | nil                 Persons other than your own; nil until the roster is known, and in demo
--   ns.IsFollowerHidden(ownerKey, name) -> bool
--   ns.Hides() -> { { owner, name, ownerName }, ... }   this officer's list, oldest first
--   ns.SetHidden(ownerKey, name, on) -> true | nil, "demo" | "officer" | "unknown" | "name" | "self" | "full"
--   ns.SetBankRecipient(nameOrNil) -> true | nil, "demo" | "officer" | "unknown"
--   ns.OwnOfficer() -> { bank, at, hides = { { owner, name } } } | nil   no officer check: every reader gates at read time
--   ns.BankRecipient() -> roster name | nil
-- One record per player, served only by its key's own client (put rule). Records live raw in
-- GuildSyncExpeditionsDB.records = { [key] = { rev, hash, body } }, never through ns.Part: in demo a Part is a throwaway
-- copy, so merges would be lost and the digest would read empty. Demo gates only the own pack and mint and the page reads.
-- Nothing sends from a timer: the tick compares the packed body's hash and calls M.Sync.Changed, whose queue sends.
-- Every byte from another member is hostile: revs parse digits only (f1191), the hub binds header to payload (f1175), and
-- a digest draws asks only for keys on the known roster (a record store has no wantCap).

local _, ns = ...

if not ns.M then return end
local M, C = ns.M, GuildSync.Comm
local FC = ns.FollowerCore

local DOMAIN = "expeditions"
local SEP = "~"
local PERIOD = 180        -- seconds between own checks, and the least time between two own versions
local KEY_MAX = 50
local MAX_HIDES = 10
local MAX_AT = 9999999999 -- 10 digits, the most Unpack takes
local LIMIT_REVS = 4      -- new revs of one subject key ...
local LIMIT_WINDOW = 600  -- ... per this many seconds
local LIMIT_SUBJECTS = 2100

-- ---------- helpers (Games/SyncKit.lua's: that file is another addon's private ns) ----------

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

local function adler(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

-- Digits only, so "nan", "inf", "1e309", "0x10" and signs never become a number (f1191).
local function digits(s)
  if type(s) ~= "string" or #s > 16 or not s:find("^%d+$") then return nil end
  return tonumber(s)
end

local function pack(m)
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

local function unpackMsg(logical)
  if type(logical) ~= "string" then return nil end
  local f = {}
  for x in (logical .. SEP):gmatch("([^~]*)~") do f[#f + 1] = x end
  local t = f[1]
  if t == "P" then
    local rev = digits(f[3])
    if not rev or not f[2] or f[2] == "" then return nil end
    return { t = "P", key = f[2], rev = rev, hash = f[4], by = f[5], body = f[6] or "" }
  end
  if t == "H" then return { t = "H", hash = f[2] or "" } end
  if t == "D" or t == "R" then
    local entries = {}
    for e in ((f[2] or "") .. ";"):gmatch("([^;]*);") do
      local k, r, h = e:match("^([^,]*),([^,]*),(.*)$")
      if k then entries[#entries + 1] = { key = k, rev = digits(r) or 0, hash = h } end
    end
    return { t = t, entries = entries }
  end
  return nil
end

-- maxRevs new revs of one subject key per window seconds, at most maxSubjects buckets (a memory bound). Nothing passes
-- before the roster is known. A subject that is not a canonical key, or whose sender is not that key, passes here and takes
-- no bucket, and the hub refuses it (the put rule), so spellings of a roster key cannot fill the cap. A key off the known
-- roster is left to the hub as well.
local function Limiter(maxRevs, window, maxSubjects)
  local seen, seenN = {}, 0

  local function expire(s, t)
    local live = 0
    for v, at in pairs(s) do
      if t - at >= window then s[v] = nil else live = live + 1 end
    end
    return live
  end

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

  local function admit(s, live, version, t)
    if not s then return false end
    if s[version] then return true end
    if live >= maxRevs then return false end
    s[version] = t
    return true
  end

  local rosterKnown = select(4, C.Roster()) and true or false

  local function limit(from, kind, subject, version, _, t)
    if kind ~= "P" then return true end
    if not rosterKnown then
      rosterKnown = select(4, C.Roster()) and true or false
      if not rosterKnown then return false end
    end
    if type(subject) ~= "string" or type(from) ~= "string" or C.Key(subject) ~= subject or C.Key(from) ~= subject then
      return true
    end
    if C.Member(subject) == nil then return true end
    t, version = tonumber(t) or 0, tostring(version)
    local s, live = bucket(subject, t)
    if from and C.Key(from) == subject then
      local own, ownLive = bucket(subject .. "\0own", t)
      if not admit(own, ownLive, version, t) then return false end
      if s and not s[version] then s[version] = t end
      return true
    end
    return admit(s, live, version, t)
  end

  return { limit = limit, setKnown = function(known) rosterKnown = known and true or false end }
end

-- ---------- the records ----------

local checked   -- the records table already walked this session
local memo = {} -- key -> { hash, view | false }, one Unpack per stored version
local stash     -- the own body the next mint hashes (the tick sets it just before M.Sync.Changed)

local function soundRecord(key, r)
  return type(key) == "string" and type(r) == "table" and type(r.rev) == "number" and r.rev >= 0 and r.rev < 2 ^ 53
    and type(r.hash) == "string" and type(r.body) == "string" and #r.body <= ns.Rec.MAX_BODY
end

local function records()
  if type(GuildSyncExpeditionsDB) ~= "table" then GuildSyncExpeditionsDB = {} end
  local recs = GuildSyncExpeditionsDB.records
  if type(recs) ~= "table" then
    recs = {}
    GuildSyncExpeditionsDB.records = recs
    checked = recs
  elseif not rawequal(recs, checked) then
    for key, r in pairs(recs) do
      if not soundRecord(key, r) then recs[key] = nil end
    end
    checked = recs
  end
  return recs
end

local function isOwn(key) return key ~= nil and key == C.MyKey() end

-- ---------- one frame's reads ----------

-- Comm.Person rebuilds the guild's tables on every call, so a draw reads each key once and builds the active hides once.
-- Dropped on a merge, on a hide or unhide, on a dropped record, and when the frame has passed.
local pass -- { persons = { [key] = answer | false }, hides = set | nil }

local function thisPass()
  if not pass then
    local p = { persons = {} }
    pass = p
    M.After(0, function()
      if pass == p then pass = nil end
    end)
  end
  return pass
end

local function personOf(key)
  local persons = thisPass().persons
  local p = persons[key]
  if p == nil then
    p = C.Person(key) or false
    persons[key] = p
  end
  return p or nil
end

local redrawArmed

-- One redraw per frame however many records merge in it. M.RefreshPage is read when it fires.
local function redrawSoon()
  if redrawArmed then return end
  redrawArmed = true
  M.After(0, function()
    redrawArmed = false
    M.RefreshPage()
  end)
end

-- ---------- the store (CommSync.lua's header) ----------

local store = { recordRule = "put", kinds = { round = "H", digest = "D", ask = "R", record = "P" } }

local function keys()
  local list = {}
  for k in pairs(records()) do list[#list + 1] = k end
  table.sort(list)
  return list
end
store.keys = keys
function store.get(key) return records()[key] end
store.isOwn = isOwn
function store.heardOwn() end

-- The own record is what the last own check packed, else what is stored (after a reload the stash is empty).
function store.content(key)
  if isOwn(key) and stash then return stash end
  local r = records()[key]
  return r and r.body or nil
end

function store.stamp(key, rev, hash)
  local recs = records()
  local body = store.content(key)
  if type(body) ~= "string" then return end
  recs[key] = { rev = rev, hash = hash, body = body }
  memo[key] = nil
end

function store.build(key)
  local r = records()[key]
  if not r or not r.rev or type(r.body) ~= "string" then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, by = key, body = r.body }
end

function store.merge(msg)
  local body = msg.body
  if msg.key == C.MyKey() or type(body) ~= "string" or type(msg.rev) ~= "number" or #body > ns.Rec.MAX_BODY
    or msg.hash ~= adler(body) or not ns.Rec.Unpack(body) then
    return false
  end
  -- An honest owner mints a new rev for every body, so a second body at a held rev only buys a redraw.
  local held = records()[msg.key]
  if held and held.rev == msg.rev then return false end
  records()[msg.key] = { rev = msg.rev, hash = msg.hash, body = body }
  memo[msg.key] = nil
  pass = nil
  redrawSoon()
  M.FactsChanged()
  return true
end

local function setHash()
  local recs, parts = records(), {}
  for _, k in ipairs(keys()) do parts[#parts + 1] = k .. "=" .. recs[k].rev .. "=" .. recs[k].hash end
  return adler(table.concat(parts, "/"))
end
function store.round() return { t = "H", hash = setHash() } end

function store.digest()
  local recs, entries = records(), {}
  for _, k in ipairs(keys()) do entries[#entries + 1] = { key = k, rev = recs[k].rev, hash = recs[k].hash } end
  return { t = "D", entries = entries }
end

-- Asks only for a key on the known roster, and for nothing while the roster is unknown: this is the bound on wants (f3).
function store.compare(msg)
  local recs, send, ask, theirs, me = records(), {}, {}, {}, C.MyKey()
  local rows, _, _, known = C.Roster()
  for _, e in ipairs(msg.entries or {}) do
    theirs[e.key] = e
    local r = recs[e.key]
    if known and rows[e.key] and e.key ~= me and (not r or newer(e.rev, e.hash, r.rev, r.hash)) then
      ask[#ask + 1] = { key = e.key, rev = r and r.rev or 0 }
    end
  end
  for _, k in ipairs(keys()) do
    local e, r = theirs[k], recs[k]
    if not e or newer(r.rev, r.hash, e.rev, e.hash) then send[#send + 1] = k end
  end
  return send, ask
end

function store.stillWanted(w)
  local r = records()[w.subject]
  if w.t == "P" then return r ~= nil and r.rev == tonumber(w.version) end
  if w.t == "R" then return ((r and r.rev) or 0) == (tonumber(w.version) or 0) end
  return true
end
store.pack = pack
function store.parts(msg) return { msg } end
function store.subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end

-- ---------- the own check ----------

local function ownCheck()
  if M.Demo() then return end
  local t, key = ns.Now(), C.MyKey()
  if not t or not key then return end
  if not select(4, C.Roster()) then return end -- a partial roster passes: readers gate the officer section themselves
  local body = ns.Rec.Pack(ns.OwnView())
  if not body then return end
  local r = records()[key]
  if r then
    if r.hash == adler(body) then return end
    if r.rev <= t and t - r.rev < PERIOD then return end
  end
  stash = body
  M.Sync.Changed(DOMAIN, key, t)
  M.FactsChanged()
end

local function tick()
  M.After(PERIOD, tick) -- first, so a throw below cannot end the timer
  ownCheck()
end

-- ---------- registration ----------

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }

ns.LoginHooks[#ns.LoginHooks + 1] = function()
  local limiter = Limiter(LIMIT_REVS, LIMIT_WINDOW, LIMIT_SUBJECTS)
  local handle = {}
  for kind, role in pairs(ROLE) do
    handle[kind] = function(msg, from, t) M.Sync.Handle(DOMAIN, role, msg, from, t) end
  end
  if M.Comm.Register({
    id = DOMAIN, prefix = "GSync", audience = "guild", owner = "self", maxChunks = 12,
    kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "put" } },
    unpack = unpackMsg, handle = handle, limit = limiter.limit,
  }) then
    records() -- the table and its row check exist from login, so a later read writes nothing
    M.Sync.Attach(DOMAIN, store)
  end
  -- A full known read drops the records whose key left the roster, so a character in another guild re-syncs.
  M.On("rosterRead", function(partial)
    local rows, isPartial, _, known = C.Roster()
    limiter.setKnown(known)
    if partial or isPartial or not known or type(rows) ~= "table" then return end
    local recs, dropped = records(), false
    for key in pairs(recs) do
      if not rows[key] then recs[key], memo[key], dropped = nil, nil, true end
    end
    if dropped then
      pass = nil
      M.FactsChanged()
    end
  end)
  M.After(10, tick)
end

-- ---------- reads ----------

function ns.GuildRecord(key)
  if M.Demo() or type(key) ~= "string" then return nil end
  local r = records()[key]
  if not r then return nil end
  local m = memo[key]
  if not m or m.hash ~= r.hash then
    m = { hash = r.hash, view = ns.Rec.Unpack(r.body) or false }
    memo[key] = m
  end
  if not m.view then return nil end
  return m.view, r.rev
end

-- The group of a key: the Person's main, or the key itself when Comm.Person answers nothing.
local function groupOf(key)
  local p = personOf(key)
  return p and p.main or key, p
end

local function shownName(key, p)
  local first = p and p.chars and p.chars[1]
  if first and first.name then return first.name end
  local row = C.Member(key)
  return row and row.name or key
end

-- Per Person and per acct the newest rev (then hash): a token merges records only inside one Person (C3).
function ns.GuildRecords()
  local list = {}
  if M.Demo() then return list end
  local me, mine = C.MyKey(), nil
  if me then mine = groupOf(me) end
  local kept = {} -- group .. "\0" .. acct -> row
  for key, r in pairs(records()) do
    local view = ns.GuildRecord(key)
    if view then
      local group, p = groupOf(key)
      local at = group .. "\0" .. tostring(view.acct)
      local cur = kept[at]
      if not cur or newer(r.rev, r.hash, cur.rev, cur.hash) then
        kept[at] = { key = key, group = group, rev = r.rev, hash = r.hash, view = view, owner = shownName(key, p),
          you = group == mine }
      end
    end
  end
  for _, row in pairs(kept) do list[#list + 1] = row end
  table.sort(list, function(a, b)
    if a.rev ~= b.rev then return a.rev > b.rev end
    if a.hash ~= b.hash then return a.hash > b.hash end
    return a.key < b.key
  end)
  return list
end

function ns.GuildCount()
  if M.Demo() or not select(4, C.Roster()) then return nil end
  local n, seen = 0, {}
  for _, row in ipairs(ns.GuildRecords()) do
    if not row.you and not seen[row.group] then
      seen[row.group] = true
      n = n + 1
    end
  end
  return tostring(n)
end

-- ---------- officer section ----------

-- The separators ^ ! . cannot sit in a key: Pack's self-check would refuse the whole record (f9).
local function goodKey(k)
  return type(k) == "string" and #k >= 1 and #k <= KEY_MAX and k:find("^[%w %+%-\128-\255]+$") ~= nil
end

local function freshOfficer() return { next = 1, rows = {}, at = 0 } end

local function soundHide(id, row)
  if type(id) ~= "number" or not goodKey(row.owner) or not FC.ValidName(row.name) then return nil end
  return row
end

local function officer()
  local p = ns.Part("officer", freshOfficer, soundHide)
  if type(p.next) ~= "number" then p.next = 1 end
  -- A hand-edited at (-1, 1.5) would make Pack refuse the whole record: repaired to 0 (R-rows).
  local at = p.at
  if type(at) ~= "number" or not (at >= 0 and at <= MAX_AT and at % 1 == 0) then p.at = 0 end
  return p
end

-- The saved hide rows, oldest first.
local function hideRows(p)
  local ids, list = {}, {}
  for id in pairs(p.rows) do ids[#ids + 1] = id end
  table.sort(ids)
  for i, id in ipairs(ids) do list[i] = p.rows[id] end
  return list, ids
end

local function amOfficer()
  local me = C.MyKey()
  return me ~= nil and C.IsOfficer(me) == true
end

function ns.OwnOfficer()
  local p, hides = officer(), {}
  for _, row in ipairs(hideRows(p)) do
    if #hides < MAX_HIDES then hides[#hides + 1] = { owner = row.owner, name = row.name } end
  end
  local bank = goodKey(p.bank) and p.bank or nil
  if not bank and #hides == 0 then return nil end
  return { bank = bank, at = bank and p.at or 0, hides = hides }
end

function ns.Hides()
  local list = {}
  for i, row in ipairs(hideRows(officer())) do
    local m = C.Member(row.owner)
    list[i] = { owner = row.owner, name = row.name, ownerName = m and m.name or row.owner }
  end
  return list
end

-- Every key of owner's Person, owner included.
local function keysOfPerson(owner)
  local set, p = { [owner] = true }, personOf(owner)
  for _, ch in ipairs(p and p.chars or {}) do
    if ch.key then set[ch.key] = true end
  end
  return set
end

-- owner .. "\0" .. name of every hide in force, built once per pass. A section counts only while its key is an officer
-- now, never from the payload. Reads the stored table, past the fold (f5).
local function activeHides()
  local now = thisPass()
  if now.hides then return now.hides end
  local set, me = {}, C.MyKey()
  local function add(hides)
    for _, h in ipairs(hides) do set[h.owner .. "\0" .. h.name] = true end
  end
  if amOfficer() then
    local own = ns.OwnOfficer()
    if own then add(own.hides) end
  end
  for key in pairs(records()) do
    if key ~= me and C.IsOfficer(key) then
      local view = ns.GuildRecord(key)
      if view and view.officer then add(view.officer.hides) end
    end
  end
  now.hides = set
  return set
end

function ns.IsFollowerHidden(ownerKey, name)
  if type(ownerKey) ~= "string" or type(name) ~= "string" then return false end
  local hides = activeHides()
  for key in pairs(keysOfPerson(ownerKey)) do
    if hides[key .. "\0" .. name] then return true end
  end
  return false
end

function ns.SetHidden(owner, name, on)
  if ns.Inert() then return nil, "demo" end
  if not amOfficer() then return nil, "officer" end
  pass = nil
  local p = officer()
  local rows, ids = hideRows(p)
  if not on then
    for i, row in ipairs(rows) do
      if row.owner == owner and row.name == name then
        p.rows[ids[i]] = nil
        M.FactsChanged()
        return true
      end
    end
    return nil, "unknown"
  end
  if not goodKey(owner) or C.Member(owner) == nil then return nil, "unknown" end
  if not FC.ValidName(name) then return nil, "name" end
  if keysOfPerson(C.MyKey())[owner] then return nil, "self" end
  for _, row in ipairs(rows) do
    if row.owner == owner and row.name == name then return true end
  end
  if #rows >= MAX_HIDES then return nil, "full" end
  p.rows[p.next] = { owner = owner, name = name }
  p.next = p.next + 1
  M.FactsChanged()
  return true
end

function ns.SetBankRecipient(name)
  if ns.Inert() then return nil, "demo" end
  if not amOfficer() then return nil, "officer" end
  local p = officer()
  if name == nil then
    p.bank, p.at = nil, 0
    return true
  end
  local key = type(name) == "string" and C.Key(name) or nil
  if not goodKey(key) or C.Member(key) == nil then return nil, "unknown" end
  p.bank, p.at = key, ns.Now() or 0
  return true
end

-- The newest setting among current officers: others scored min(at, rev), so a forward-dated at cannot pin itself, the own
-- setting by its at. Then rev, then hash. A bad bank on the newest setting answers nil: there is no fallback past it.
function ns.BankRecipient()
  if M.Demo() then return nil end
  local me, best = C.MyKey(), nil
  local function consider(score, rev, hash, bank)
    if not best or score > best.score or (score == best.score and newer(rev, hash, best.rev, best.hash)) then
      best = { score = score, rev = rev, hash = hash, bank = bank }
    end
  end
  for key, r in pairs(records()) do
    if key ~= me and C.IsOfficer(key) then
      local view = ns.GuildRecord(key)
      local section = view and view.officer
      if section and section.bank then consider(math.min(section.at, r.rev), r.rev, r.hash, section.bank) end
    end
  end
  if amOfficer() then
    local own = ns.OwnOfficer()
    if own and own.bank then consider(own.at, own.at, "", own.bank) end
  end
  local row = best and C.Member(best.bank)
  return row and row.name or nil
end
