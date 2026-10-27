-- GuildSyncGames Boards.lua (Task 4, S14 Task 5): the guild boards on the "games_g" record domain on GSync and
-- ns.GuildBoards. S14: the put rule (PeopleStore.lua's store): each player's board row under their roster key, sent
-- only by that key's own character, never relayed; 4 new revs of one subject key in 600 s; a body is
-- GrainCore.PackBoard's text ("harvested^won^big^hour^pay", 80 bytes at most, GC.ParseBoard) and must pass
-- ns.Limits.Board (L7-L10) by the receiver's clock, on merge and again at the fold. The purse and bets are never in it
-- (AC2). The first full rosterRead with MyKey known wipes every foreign record once per guild (ns.WipeForeignOnce: it
-- wipes data). A hidden key (ns.IsHidden) leaves the boards. Records live in ns.BoardRecords()
-- (db.guilds[guildKey].boards, Store.lua) as { rev, hash, body }.
-- Only MyKey is minted, once grain was ever harvested or won, through the tick: ns.BoardsDirty() sets a flag and
-- ns.BoardsTick(now) (Grain.lua's tick, d1547) drains it at most once per 300 s, never in demo. There is no prune by
-- day; once ns.Now() >= GC.LAUNCH, records with a rev before it are dropped in keys, merge, compare and stillWanted
-- together (q1550, f7172). Rows fold by GuildSync.Comm.Person(key).main (q1547): grain is per account.
-- The own record's body is the one stamped at the mint, so a build always matches its hash (a board row changes
-- between mints; Sync.lua's day body does not).

local _, ns = ...

if not ns.M then return end
local M, GC, K = ns.M, ns.GrainCore, ns.SyncKit

local DOMAIN = "games_g"
local HOUR = 3600
local MINT_EVERY = 300     -- the own record is minted at most this often (s)
local LIMIT_REVS = 4       -- new revs of one subject key ...
local LIMIT_WINDOW = 600   -- ... per this many seconds (f7061)
local LIMIT_SUBJECTS = 2100 -- buckets the limit tracks at most (a memory bound: a full guild and its own buckets)

-- GC.LAUNCH once the real clock is past it; nil before (the beta keeps its records) and without a clock.
local function cutoff()
  local t = ns.Now()
  if type(t) == "number" and t >= GC.LAUNCH then return GC.LAUNCH end
  return nil
end

local function hourNow()
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  return math.floor(t / HOUR)
end

-- The records, with the preview-era ones (rev before GC.LAUNCH, after launch) dropped.
local function records()
  local recs, cut = ns.BoardRecords(), cutoff()
  if cut then
    for k, r in pairs(recs) do
      if type(r) == "table" and type(r.rev) == "number" and r.rev < cut then recs[k] = nil end
    end
  end
  return recs
end

-- The own body, from the real grain only; nil until grain was ever harvested or won.
local function ownBody()
  local b = ns.BoardBody()
  return b and GC.PackBoard(b) or nil
end

local function isOwn(key)
  return key ~= nil and key == ns.MyKey() and ownBody() ~= nil
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
  local recs = ns.BoardRecords()
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
-- Refused (false, nothing kept) for a preview-era rev after launch, no clock, or a body GC.ParseBoard refuses (over 80
-- bytes, not five digit fields, a field over 9 digits, big > won, an hour past hourNow + 1).
-- A row over the limit table (ns.Limits.Board, L7-L10, by the receiver's clock) is refused too. MyKey is never taken
-- (only this client mints it), nor a row whose hash is not its body's.
function store.merge(msg)
  if msg.key == ns.MyKey() or type(msg.body) ~= "string" or msg.hash ~= K.adler(msg.body) then return false end
  local hn, cut = hourNow(), cutoff()
  if not hn or (cut and msg.rev < cut) then return false end
  local b = GC.ParseBoard(msg.body, hn)
  if not b or not ns.Limits.Board(b, ns.Now()) then return false end
  ns.BoardRecords()[msg.key] = { rev = msg.rev, hash = msg.hash, body = msg.body }
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
-- A preview-era rev in a peer's digest is never asked for (f7172).
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

-- At each rosterRead: preview-era records go; a full read also drops the records whose key is off the roster (another
-- guild's boards go with its entry, Store.lua).
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

-- ---------- the mint throttle ----------

local dirty, mintedAt = false, nil

-- Grain.lua calls this after a harvest or a settle; the next tick mints.
function ns.BoardsDirty() dirty = true end

-- Grain.lua's tick (outside demo): mints the own record when it changed, at most once per MINT_EVERY, only for MyKey.
-- A stored own body that is not the current one (a change before a reload) counts as dirty.
function ns.BoardsTick(t)
  if type(t) ~= "number" or M.Demo() then return end
  local key = ns.MyKey()
  if not key then return end
  local body = ownBody()
  if not body then
    dirty = false
    return
  end
  local r = records()[key]
  if not dirty and r and r.body == body then return end
  if mintedAt and t - mintedAt < MINT_EVERY then return end
  dirty, mintedAt = false, t
  M.Sync.Changed(DOMAIN, key, t)
end

-- ---------- the boards ----------

local function byName(a, b) return a.name < b.name end

-- One row per person (Person(key).main), the newest record's; the own row is the live grain. A stored row over the
-- limit table and a hidden key (ns.IsHidden, an officer's hide) are left out.
local function folded()
  local hn, me, by, t = hourNow(), ns.MyKey(), {}, ns.Now()
  if not hn then return {} end
  local function add(key, rev, hash, b)
    if ns.IsHidden and ns.IsHidden(key) then return end
    local p = type(ns.Person) == "function" and ns.Person(key) or nil
    local main = type(p) == "table" and p.main or key
    local cur = by[main]
    if not cur or K.newer(rev, hash, cur.rev, cur.hash) then by[main] = { key = key, rev = rev, hash = hash, b = b } end
  end
  for key, r in pairs(records()) do
    if key ~= me and type(r) == "table" and type(r.rev) == "number" then
      local b = GC.ParseBoard(r.body, hn)
      if b and ns.Limits.Board(b, t) then add(key, r.rev, r.hash, b) end
    end
  end
  local own = me and ns.BoardBody()
  if own then add(me, math.huge, "", own) end
  local rows = {}
  for _, x in pairs(by) do
    local m = ns.Member(x.key)
    rows[#rows + 1] = { key = x.key, name = m and m.name or x.key, class = m and m.class, b = x.b, you = x.key == me }
  end
  return rows
end

-- The newest row hour at or before the clock's last finished race (GC.RaceAt(now - GC.RUN)); a row naming a later race
-- (ParseBoard admits hourNow + 1) never moves it (f7209, f7188). nil without a clock or a qualifying row.
local function lastHourOf(rows)
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  local cap, last = (GC.RaceAt(t - GC.RUN)), nil
  for _, r in ipairs(rows) do
    local h = r.b.hour
    if h > 0 and h <= cap and (not last or h > last) then last = h end
  end
  return last
end

-- { harvest = { { key, name, class, harvested, you } } by harvested, lastHour = h | nil, winners = { { key, name,
-- class, pay, pays, you } } of lastHour's race by pay (pays: that race's winning lane), biggest = { { key, name, class,
-- big, you } } by big } (fix round 1's contract, f7219).
function ns.GuildBoards()
  local rows, out = folded(), { harvest = {}, winners = {}, biggest = {} }
  local last = lastHourOf(rows)
  local pays
  if last then
    local race = GC.Race(last)
    pays = race.field[race.winner].pays
  end
  out.lastHour = last
  for _, r in ipairs(rows) do
    out.harvest[#out.harvest + 1] = { key = r.key, name = r.name, class = r.class, harvested = r.b.harvested, you = r.you }
    if last and r.b.hour == last and r.b.pay > 0 then
      out.winners[#out.winners + 1] = { key = r.key, name = r.name, class = r.class, pay = r.b.pay, pays = pays,
        you = r.you }
    end
    if r.b.big > 0 then
      out.biggest[#out.biggest + 1] = { key = r.key, name = r.name, class = r.class, big = r.b.big, you = r.you }
    end
  end
  table.sort(out.harvest, function(a, b)
    if a.harvested ~= b.harvested then return a.harvested > b.harvested end
    return byName(a, b)
  end)
  table.sort(out.winners, function(a, b)
    if a.pay ~= b.pay then return a.pay > b.pay end
    return byName(a, b)
  end)
  table.sort(out.biggest, function(a, b)
    if a.big ~= b.big then return a.big > b.big end
    return byName(a, b)
  end)
  return out
end
