-- GuildSyncGames Sync.lua: the "games" record domain on GSync and ns.GuildToday (plan Task 6; S14 Task 4).
-- One put-rule domain (S14, AC1): each player's result for the day under their roster key, served only by that key's
-- own client: the hub refuses a P whose sender is not its key and answers wants only for the own key, so a late login
-- gets a member's result only while that member is online. A body is Core.PackBody's text (no letter of a word, only
-- the codes). Records live in ns.Records() (db.guilds[guildKey].records, Store.lua) as { rev, hash, body, n }.
-- Own content comes from db.day and stats only, and only MyKey is minted, when db.day.fin is MyKey (f7062): an alt that
-- shares the saved variables never serves or mints records[main]. The first full rosterRead wipes every foreign record
-- once per guild (ns.WipeForeignOnce, d1605: it wipes data). merge and GuildToday keep a result only inside the limits
-- L1 and L2 (ns.Limits.WoWdle), and GuildToday leaves out a player an officer hid (ns.IsHidden). A P is limited per
-- subject key, 4 new revs in 600 s (f7061). Revs from before yesterday's day start are skipped and pruned (f7063).
-- merge takes N in [today-1, today+1] (f7064); GuildToday lists N == today. Demo sends nothing: the hub holds every send.

local _, ns = ...

if not ns.M then return end
local M, Core = ns.M, ns.Core

local DOMAIN = "games"
local DAY = 86400
local LIMIT_REVS = 4       -- new revs of one subject key ...
local LIMIT_WINDOW = 600   -- ... per this many seconds (f7061)
local LIMIT_SUBJECTS = 2100 -- buckets the limit tracks at most (a memory bound: a full guild and its own buckets)

-- The start of yesterday's reset day; nil without a clock or a day.
local function cutoff()
  local d, t = ns.Today(), ns.Now()
  if not d or not t or type(d.secsLeft) ~= "number" then return nil end
  return t + d.secsLeft - 2 * DAY
end

-- The records, with the stale ones (rev before yesterday's day start) dropped.
local function records()
  local recs, cut = ns.Records(), cutoff()
  if cut then
    for k, r in pairs(recs) do
      if type(r) == "table" and type(r.rev) == "number" and r.rev < cut then recs[k] = nil end
    end
  end
  return recs
end

-- The own key: MyKey, and only once the real day (not the demo's) is done and was finished by it (f7062, f7111).
local function isOwn(key)
  if key == nil or key ~= ns.MyKey() then return false end
  local d = ns.RealToday()
  return d ~= nil and d.done == true and d.fin == key
end

-- The own body, from the real db.day and stats only; nil until today's game is done.
local function ownBody()
  local d = ns.RealToday()
  if not d or not d.done then return nil end
  return Core.PackBody(Core.Result(d.n, d.won, d.rows, ns.RealStats().cur)), d.n
end

-- adler, newer, the codec and the limit live in SyncKit.lua (moved from here unchanged, Task 4 of S11).
local K = ns.SyncKit
local newer, adler = K.newer, K.adler

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
  if isOwn(key) then return (ownBody()) end
  local r = records()[key]
  return r and r.body or nil
end
-- The hub's mint (own key) or a stored rev: the own record takes its body from db.day.
function store.stamp(key, rev, hash)
  local recs = ns.Records()
  local r = recs[key] or {}
  recs[key] = r
  r.rev, r.hash = rev, hash
  if isOwn(key) then r.body, r.n = ownBody() end
end
function store.build(key)
  local r = records()[key]
  if not r or not r.rev or type(r.body) ~= "string" then return nil end
  local body = isOwn(key) and ownBody() or r.body
  return { t = "P", key = key, rev = r.rev, hash = r.hash, by = key, body = body }
end
-- Refused (false, nothing kept) for a stale rev or a body Core.ParseBody refuses (N outside [today-1, today+1],
-- more than 6 rows, a row of another length, a code other than g, y or x, tries that do not match) or outside the
-- limits L1 and L2 (ns.Limits.WoWdle). A P for MyKey is never taken (only this client mints it), nor one whose hash
-- is not its body's.
function store.merge(msg)
  if msg.key == ns.MyKey() or type(msg.body) ~= "string" or msg.hash ~= adler(msg.body) then return false end
  local d, cut = ns.Today(), cutoff()
  if not d or (cut and msg.rev < cut) then return false end
  local res = Core.ParseBody(msg.body, d.n)
  if not res or not ns.Limits.WoWdle(res, ns.Now()) then return false end
  ns.Records()[msg.key] = { rev = msg.rev, hash = msg.hash, body = msg.body, n = res.n }
  if M.RefreshPage then M.RefreshPage() end
  if ns.FactsChanged then ns.FactsChanged() end
  return true
end
local function setHash()
  local recs, parts = records(), {}
  for _, k in ipairs(keys()) do parts[#parts + 1] = k .. "=" .. recs[k].rev .. "=" .. (recs[k].hash or "") end
  return adler(table.concat(parts, "/"))
end
function store.round() return { t = "H", hash = setHash() } end
function store.digest()
  local recs, entries = records(), {}
  for _, k in ipairs(keys()) do entries[#entries + 1] = { key = k, rev = recs[k].rev, hash = recs[k].hash } end
  return { t = "D", entries = entries }
end
-- A stale rev in a peer's digest is never asked for (f7063).
function store.compare(msg)
  local recs, cut, send, ask, theirs, me = records(), cutoff(), {}, {}, {}, ns.MyKey()
  for _, e in ipairs(msg.entries or {}) do
    theirs[e.key] = e
    local r = recs[e.key]
    local fresh = not cut or (tonumber(e.rev) or 0) >= cut
    if fresh and e.key ~= me and (not r or newer(e.rev, e.hash, r.rev, r.hash)) then
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
store.pack = K.pack
function store.parts(msg) return { msg } end
function store.subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end

-- ---------- the limit: per subject key, any sender (f7061) ----------

local limiter = K.Limiter(LIMIT_REVS, LIMIT_WINDOW, LIMIT_SUBJECTS)

-- ---------- registration ----------

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

-- On load (the first rosterRead) and at each one after: stale records go; a full read also runs the one-time wipe of
-- foreign records (d1605) and drops the records this domain holds (those with a rev) whose key is off the roster.
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

-- Store.lua calls this when a daily game ends: mint the own record, only for MyKey and only when it started the day.
function ns.OnFinished()
  local key, t = ns.MyKey(), ns.Now()
  if key and t and isOwn(key) then M.Sync.Changed(DOMAIN, key, t) end
end

-- Today's results in the guild: { { key, name, class, tries (0 = X), rows = { codes }, streak, at, you }, ... },
-- in Core.ByResult's order. A row over a limit (L1, L2) or of a hidden player is left out.
function ns.GuildToday()
  local d = ns.Today()
  if not d then return {} end
  local me, t, list = ns.MyKey(), ns.Now(), {}
  for key, r in pairs(records()) do
    local res = r.n == d.n and Core.ParseBody(r.body, d.n)
    if res and ns.Limits.WoWdle(res, t) and not (ns.IsHidden and ns.IsHidden(key)) then
      local row = ns.Member(key)
      list[#list + 1] = { key = key, name = row and row.name or key, class = row and row.class, tries = res.tries,
        rows = res.rows, streak = res.streak, at = r.rev, you = key == me }
    end
  end
  table.sort(list, Core.ByResult)
  return list
end
