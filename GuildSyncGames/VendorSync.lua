-- GuildSyncGames VendorSync.lua (S12 Task 5, S14 Task 5): the Vendor price records on the "games_v" record domain on
-- GSync, the guild list (ns.VendorGuild) and the board (ns.VendorBoard). S14: the put rule, as Boards.lua: each
-- player's record under their roster key, sent only by that key's own character, never relayed; 4 new revs of one
-- subject key in 600 s; a body is VendorCore.PackBody's text ("n^score^marks^best^streak", 80 bytes at most,
-- VC.ParseBody against today) and must pass ns.Limits.Vendor (L3-L5, the streak on the row's n) by the receiver's
-- clock, on merge and at the fold. The first full rosterRead with MyKey known wipes every foreign record once per
-- guild (ns.WipeForeignOnce: it wipes data). A hidden key (ns.IsHidden) leaves the list and the board. No item id,
-- name or price is in a body. Records live in ns.VendorRecords()
-- (db.guilds[guildKey].vendor, Store.lua) as { rev, hash, body }.
-- Minted on actions only (f7253, o1658): ns.VendorFinished() mints MyKey at once; ns.VendorBestChanged() sets a session
-- flag that ns.VendorTick(now) (Grain.lua's tick) drains at most once per 300 s, never in demo. A login, a tick without
-- the flag or a stored body that differs from ns.VendorBody() never mints. isOwn is Boards' rule (f7265): MyKey with a
-- VendorBody, so the first mint's content() is the own body and its hash matches. Once ns.Now() >= GC.LAUNCH, records
-- with a rev before it are dropped. Rows fold by GuildSync.Comm.Person(key).main: the result is per account.

local _, ns = ...

if not ns.M then return end
local M, GC, K, VC = ns.M, ns.GrainCore, ns.SyncKit, ns.VendorCore

local DOMAIN = "games_v"
local RUN = 10
local MINT_EVERY = 300     -- an endless best mints the own record at most this often (s)
local LIMIT_REVS = 4       -- new revs of one subject key ...
local LIMIT_WINDOW = 600   -- ... per this many seconds
local LIMIT_SUBJECTS = 2100 -- buckets the limit tracks at most (a memory bound: a full guild and its own buckets)

-- GC.LAUNCH once the real clock is past it; nil before (the beta keeps its records) and without a clock.
local function cutoff()
  local t = ns.Now()
  if type(t) == "number" and t >= GC.LAUNCH then return GC.LAUNCH end
  return nil
end

local function today()
  local n = ns.Day()
  if type(n) ~= "number" then return nil end
  return n
end

-- The records, with the preview-era ones (rev before GC.LAUNCH, after launch) dropped.
local function records()
  local recs, cut = ns.VendorRecords(), cutoff()
  if cut then
    for k, r in pairs(recs) do
      if type(r) == "table" and type(r.rev) == "number" and r.rev < cut then recs[k] = nil end
    end
  end
  return recs
end

-- The own body, read at call time; nil until a run was finished or an endless best set.
local function ownBody()
  local b = ns.VendorBody()
  return b and VC.PackBody(b) or nil
end

local function isOwn(key)
  return key ~= nil and key == ns.MyKey() and ns.VendorBody() ~= nil
end

-- ---------- the store (CommSync.lua's header) ----------

local store = { recordRule = "put", kinds = { round = "H", digest = "D", ask = "R", record = "P" } }

local function keys()
  local list = {}
  for k, r in pairs(records()) do if type(r) == "table" and type(r.rev) == "number" then list[#list + 1] = k end end
  table.sort(list)
  return list
end
store.keys = keys
function store.get(key) return records()[key] end
store.isOwn = isOwn
function store.heardOwn() end
function store.content(key)
  if isOwn(key) then return ownBody() end
  local r = records()[key]
  return r and r.body or nil
end
-- The hub's mint (own key) or a stored rev: the own record keeps the body its hash was made from.
function store.stamp(key, rev, hash)
  local recs = ns.VendorRecords()
  local r = recs[key] or {}
  recs[key] = r
  r.rev, r.hash = rev, hash
  if isOwn(key) then r.body = ownBody() end
end
function store.build(key)
  local r = records()[key]
  if not r or not r.rev or type(r.body) ~= "string" then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, by = key, body = r.body }
end
-- Refused (false, nothing kept): MyKey's row, a hash that is not the body's, no clock, a preview-era rev after
-- launch, a body VC.ParseBody refuses against today, or one over the limit table (ns.Limits.Vendor, L3-L5, by the
-- receiver's clock).
function store.merge(msg)
  if msg.key == ns.MyKey() or type(msg.body) ~= "string" or msg.hash ~= K.adler(msg.body) then return false end
  local n, cut = today(), cutoff()
  if not n or (cut and msg.rev < cut) then return false end
  local b = VC.ParseBody(msg.body, n)
  if not b or not ns.Limits.Vendor(b, ns.Now()) then return false end
  ns.VendorRecords()[msg.key] = { rev = msg.rev, hash = msg.hash, body = msg.body }
  if M.RefreshPage then M.RefreshPage() end
  return true
end
local function setHash()
  local recs, parts = records(), {}
  for _, k in ipairs(keys()) do parts[#parts + 1] = k .. "=" .. recs[k].rev .. "=" .. (recs[k].hash or "") end
  return K.adler(table.concat(parts, "/"))
end
function store.round() return { t = "H", hash = setHash() } end
function store.digest()
  local recs, entries = records(), {}
  for _, k in ipairs(keys()) do entries[#entries + 1] = { key = k, rev = recs[k].rev, hash = recs[k].hash } end
  return { t = "D", entries = entries }
end
-- A preview-era rev in a peer's digest is never asked for.
function store.compare(msg)
  local recs, cut, send, ask, theirs, me = records(), cutoff(), {}, {}, {}, ns.MyKey()
  for _, e in ipairs(msg.entries or {}) do
    theirs[e.key] = e
    local r = recs[e.key]
    local fresh = not cut or (tonumber(e.rev) or 0) >= cut
    if fresh and e.key ~= me and (not r or K.newer(e.rev, e.hash, r.rev, r.hash)) then
      ask[#ask + 1] = { key = e.key, rev = r and r.rev or 0 }
    end
  end
  for _, k in ipairs(keys()) do
    local e, r = theirs[k], recs[k]
    if not e or K.newer(r.rev, r.hash, e.rev, e.hash) then send[#send + 1] = k end
  end
  return send, ask
end
function store.stillWanted(w)
  local r = records()[w.subject]
  if w.t == "P" then return r ~= nil and r.rev == tonumber(w.version) end
  if w.t == "R" then return ((r and r.rev) or 0) == (tonumber(w.version) or 0) end
  return true
end
store.pack = K.pack
function store.parts(msg) return { msg } end
function store.subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end

-- ---------- registration ----------

local limiter = K.Limiter(LIMIT_REVS, LIMIT_WINDOW, LIMIT_SUBJECTS)

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }
local handle = {}
for kind, role in pairs(ROLE) do
  handle[kind] = function(msg, from, t) M.Sync.Handle(DOMAIN, role, msg, from, t) end
end

if M.Comm.Register({
  id = DOMAIN, prefix = "GSync", audience = "guild", owner = "self",
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "put" } },
  unpack = K.unpack, handle = handle, limit = limiter.limit,
}) then
  M.Sync.Attach(DOMAIN, store)
end

-- At each rosterRead: preview-era records go; a full read also drops the records whose key is off the roster.
M.On("rosterRead", function(partial)
  local recs = records()
  local rows, isPartial, _, known = ns.Roster()
  limiter.setKnown(known)
  if partial then return end
  if not known or isPartial or type(rows) ~= "table" then return end
  ns.WipeForeignOnce(DOMAIN, recs)
  for key, r in pairs(recs) do
    if not rows[key] and type(r) == "table" and type(r.rev) == "number" then recs[key] = nil end
  end
end)

-- ---------- minting, on actions only ----------

local bestDirty, mintedAt = false, nil

local function mint(t)
  local key = ns.MyKey()
  if type(t) ~= "number" or not key or M.Demo() or not ownBody() then return end
  bestDirty, mintedAt = false, t
  M.Sync.Changed(DOMAIN, key, t)
end

-- VendorStore.lua calls this when the daily run is finished: mints MyKey at once.
function ns.VendorFinished() mint(ns.Now()) end

-- VendorStore.lua calls this on a new endless best: the next tick past MINT_EVERY mints.
function ns.VendorBestChanged() bestDirty = true end

-- Grain.lua's tick: mints only while the best flag is set, at most once per MINT_EVERY, never in demo.
function ns.VendorTick(t)
  if not bestDirty or type(t) ~= "number" or M.Demo() then return end
  if mintedAt and t - mintedAt < MINT_EVERY then return end
  if not ownBody() then
    bestDirty = false
    return
  end
  mint(t)
end

-- ---------- the guild list and the board ----------

local function byName(a, b) return a.name < b.name end

-- One row per person (Person(key).main), the newest record's, every body re-parsed with today; the own row is
-- ns.VendorBody(). A stored row over the limit table and a hidden key (ns.IsHidden, an officer's hide) are left out.
local function folded()
  local n, me, by, t = today(), ns.MyKey(), {}, ns.Now()
  if not n then return {} end
  local function add(key, rev, hash, b)
    if ns.IsHidden and ns.IsHidden(key) then return end
    local p = type(ns.Person) == "function" and ns.Person(key) or nil
    local main = type(p) == "table" and p.main or key
    local cur = by[main]
    if not cur or K.newer(rev, hash, cur.rev, cur.hash) then by[main] = { key = key, rev = rev, hash = hash, b = b } end
  end
  local recs = records()
  for key, r in pairs(recs) do
    if key ~= me and type(r) == "table" and type(r.rev) == "number" then
      local b = VC.ParseBody(r.body, n)
      if b and ns.Limits.Vendor(b, t) then add(key, r.rev, r.hash, b) end
    end
  end
  local own = me and ownBody()
  local ob = own and VC.ParseBody(own, n)
  if ob then add(me, math.huge, "", ob) end
  local rows = {}
  for _, x in pairs(by) do
    local m = ns.Member(x.key)
    local at = x.rev
    if at == math.huge then at = type(recs[me]) == "table" and recs[me].rev or nil end
    rows[#rows + 1] = { key = x.key, name = m and m.name or x.key, class = m and m.class, b = x.b, rev = x.rev, at = at,
      you = x.key == me }
  end
  return rows, n
end

local function known()
  local _, _, _, k = ns.Roster()
  return k == true
end

-- Today in the guild: { { key, name, class, score, marks, at, you } } for today's finished runs, newest finish (at)
-- first; the own row at its stored record's rev, first while that is not stored yet (f7277).
function ns.VendorGuild()
  if not known() then return nil end
  local rows, n = folded()
  local out = {}
  for _, r in ipairs(rows) do
    if r.b.n == n and #r.b.marks == RUN then
      out[#out + 1] = { key = r.key, name = r.name, class = r.class, score = r.b.score, marks = r.b.marks, at = r.at,
        you = r.you }
    end
  end
  table.sort(out, function(a, b)
    local x, y = a.at or math.huge, b.at or math.huge
    if x ~= y then return x > y end
    return byName(a, b)
  end)
  return out
end

-- The board: { { key, name, class, best, streak, you } }, best endless first; the streak is 0 once the record's n is
-- before yesterday.
function ns.VendorBoard()
  if not known() then return nil end
  local rows, n = folded()
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = { key = r.key, name = r.name, class = r.class, best = r.b.best,
      streak = r.b.n >= n - 1 and r.b.streak or 0, you = r.you }
  end
  table.sort(out, function(a, b)
    if a.best ~= b.best then return a.best > b.best end
    return byName(a, b)
  end)
  return out
end
