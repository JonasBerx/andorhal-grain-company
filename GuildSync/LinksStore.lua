-- LinksStore: the hub's R9 alt-link records (plan r-20261018-o696-one-list-the-roster-api-7-member-pa, "R9", Task 3).
-- One put-rule domain "links" (CommVersion.lua's Comm.Register form, shaped like GuildSyncPeople/PeopleStore.lua): each
-- character sends this account's visible characters in this guild under its own roster key, and the engine takes a
-- record only from its owner. The pure rules are Links.lua's. Saved in GuildSyncDB3.links[<guild>-<realm>] =
-- { records = { [key] = { rev, hash, body, newer, held } }, pick = <guid> | nil, hidden = { [guid] = true }, sig,
-- linksAt }. The own record, the sig and linksAt, the own-key set and prune move only at a full rosterRead (R1); a partial
-- read changes nothing. The "links" hub event fires once per tick after a merge, a full read or an own change.
local _, ns = ...
local Links = ns.Links
local Store = {}
Links.Store = Store

local DOMAIN = "links"
local MODULE = "Alt links"
local RAW_BYTES = 16 * 250 -- a newer-format body is kept up to the wire bound (maxChunks x Wire.MAX)

local Comm = ns.Comm
local function Wire() return ns.Comm.Wire end
local function serverNow() return ns.Compat.ServerTime() end

local memory = {}     -- records heard before the guild key is known
local parsed = {}     -- key -> { body, rec }: parsed bodies, session only
local guildKey        -- "<guild>-<realm>" from this session's last rosterRead with a guild name
local full = false    -- a full rosterRead has run for guildKey this session
local own = {}        -- the own-key set from the last full read: key -> guid (each key once)

-- ---------- saved data ----------

-- This guild's saved table (created to write), or nil while the guild key is unknown (nothing is written then).
local function guild()
  if not guildKey then return nil end
  local db = ns.DB()
  if type(db.links) ~= "table" then db.links = {} end
  local g = db.links[guildKey]
  if type(g) ~= "table" then
    g = {}
    db.links[guildKey] = g
  end
  if type(g.records) ~= "table" then g.records = {} end
  if type(g.hidden) ~= "table" then g.hidden = {} end
  return g
end

-- Reads only: this guild's saved table or nil (selftest and status).
local function peek()
  local db = ns.SavedDB()
  local g = guildKey and db and type(db.links) == "table" and db.links[guildKey]
  return type(g) == "table" and g or nil
end

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

-- The records in use: the guild's saved ones once the key is known (memory moves in), else memory.
local function records()
  local g = guild()
  if not g then return memory end
  if next(memory) then
    for k, r in pairs(memory) do
      local had = g.records[k]
      if not had or newer(r.rev, r.hash, had.rev, had.hash) then g.records[k] = r end
    end
    memory = {}
  end
  return g.records
end

local function readRecords()
  local g = peek()
  return g and type(g.records) == "table" and g.records or memory
end

-- ---------- the "links" event: once per tick ----------

local armed = false
local function changed()
  if armed then return end
  armed = true
  ns.After(0, function()
    armed = false
    ns.Fire("links")
  end, MODULE)
end

-- ---------- the store (CommSync.lua's header) ----------

-- Messages (PeopleRecord.lua's codec shape): P~key~rev~hash~body, H~hash, D|R~key,rev,hash;... The P body is the rest
-- of the line, kept whole (it holds "~" between keys).
local SEP = "~"
local function packMsg(m)
  if m.t == "P" then return table.concat({ "P", m.key, tostring(m.rev), m.hash or "", m.body or "" }, SEP) end
  if m.t == "H" then return "H" .. SEP .. (m.hash or "") end
  if m.t == "D" or m.t == "R" then
    local list = {}
    for _, e in ipairs(m.entries or {}) do list[#list + 1] = e.key .. "," .. tostring(e.rev or 0) .. "," .. (e.hash or "") end
    return m.t .. SEP .. table.concat(list, ";")
  end
  return nil
end

local function unpackMsg(text)
  if type(text) ~= "string" then return nil end
  local t = text:sub(1, 2)
  if t == "P~" then
    local key, rev, hash, body = text:match("^P~([^~]*)~([^~]*)~([^~]*)~(.*)$")
    rev = tonumber(rev)
    if not key or key == "" or not rev then return nil end
    return { t = "P", key = key, rev = rev, hash = hash, body = body }
  end
  if t == "H~" then return { t = "H", hash = text:sub(3) } end
  if t == "D~" or t == "R~" then
    local entries = {}
    for e in (text:sub(3) .. ";"):gmatch("([^;]*);") do
      local key, rev, hash = e:match("^([^,]*),([^,]*),(.*)$")
      if key then entries[#entries + 1] = { key = key, rev = tonumber(rev) or 0, hash = hash } end
    end
    return { t = text:sub(1, 1), entries = entries }
  end
  return nil
end

local store = { recordRule = "put", kinds = { round = "H", digest = "D", ask = "R", record = "P" } }
local function keys()
  local list = {}
  for k, r in pairs(records()) do if r.rev then list[#list + 1] = k end end
  table.sort(list)
  return list
end
store.keys = keys
function store.get(key) return records()[key] end
function store.content(key)
  local r = records()[key]
  return r and r.body or nil
end
function store.stamp(key, rev, hash)
  local list = records()
  local r = list[key] or {}
  list[key] = r
  r.rev, r.hash = rev, hash
end
function store.isOwn(key) return key ~= nil and key == Comm.MyKey() end
function store.build(key)
  local r = records()[key]
  if not r or not r.rev or type(r.body) ~= "string" then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, body = r.body }
end
-- Refused (false, nothing kept) unless the body parses (Links.Parse: the caps); a newer format is kept raw with the
-- body held before.
function store.merge(msg, t)
  local rec, why = Links.Parse(msg.body, serverNow() or t)
  local list = records()
  if rec then
    list[msg.key] = { rev = msg.rev, hash = msg.hash, body = msg.body }
  elseif why == "newer" then
    local had, held = list[msg.key], nil
    if had then
      if had.newer then held = had.held else held = had.body end
    end
    list[msg.key] = { rev = msg.rev, hash = msg.hash, body = string.sub(msg.body, 1, RAW_BYTES), newer = true,
      held = held }
  else
    return false
  end
  changed()
  return true
end
local function setHash()
  local list, parts = records(), {}
  for _, k in ipairs(keys()) do parts[#parts + 1] = k .. "=" .. list[k].rev .. "=" .. (list[k].hash or "") end
  return Wire().Hash(table.concat(parts, "/"))
end
function store.round() return { t = "H", hash = setHash() } end
function store.digest()
  local list, entries = records(), {}
  for _, k in ipairs(keys()) do entries[#entries + 1] = { key = k, rev = list[k].rev, hash = list[k].hash } end
  return { t = "D", entries = entries }
end
function store.compare(msg)
  local list, send, ask, theirs = records(), {}, {}, {}
  for _, e in ipairs(msg.entries or {}) do
    theirs[e.key] = e
    local r = list[e.key]
    if not r or not r.rev or newer(e.rev, e.hash, r.rev, r.hash) then ask[#ask + 1] = { key = e.key, rev = r and r.rev or 0 } end
  end
  for _, k in ipairs(keys()) do
    local e, r = theirs[k], list[k]
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
function store.pack(msg) return packMsg(msg) end
function store.parts(msg) return { msg } end
function store.subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }
local handle = {}
for kind, role in pairs(ROLE) do
  handle[kind] = function(msg, from, t) Comm.Sync.Handle(DOMAIN, role, msg, from, t) end
end

local attached = false
if Comm.Register({
  id = DOMAIN, prefix = "GSync", audience = "guild", owner = "self",
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "put" } },
  unpack = unpackMsg, handle = handle,
}) then
  attached = Comm.Sync.Attach(DOMAIN, store) and true or false
end

-- ---------- this account: the own-key set, the sig and the own record ----------

-- key -> guid for this account's characters on the roster, by GUID (Professions.lua's match): a rename keeps the
-- GUID, so two db.chars entries give the key once.
local function ownKeys()
  local db = ns.DB()
  local g = type(db.guild) == "table" and db.guild or nil
  local members = g and type(g.members) == "table" and g.members or {}
  local out = {}
  for _, c in pairs(db.chars) do
    local m = type(c) == "table" and type(c.guid) == "string" and members[c.guid] or nil
    local key = type(m) == "table" and Wire().Key(m.name) or nil
    if key then out[key] = c.guid end
  end
  return out
end

-- The visible own keys (sorted) and the pick as a key (nil unless visible).
local function visible(g)
  local list, pick = {}, nil
  for key, guid in pairs(own) do
    if not g.hidden[guid] then
      list[#list + 1] = key
      if g.pick == guid then pick = key end
    end
  end
  table.sort(list)
  return list, pick
end

-- A changed sig stamps max(ServerTime, stored + 1) (R7, f12); an unchanged one keeps the stored linksAt, so every
-- character of the account carries the same linksAt for the same change. A stored linksAt past now + Wire.FUTURE
-- (every receiver refuses it) restamps to floor(ServerTime), sig changed or not (f5603).
local function restamp(g)
  local list, pick = visible(g)
  local sig = table.concat(list, "~") .. "|" .. (pick or "")
  local now = math.floor(serverNow())
  local future = type(g.linksAt) == "number" and g.linksAt > now + Wire().FUTURE
  if sig ~= g.sig or type(g.linksAt) ~= "number" or future then
    g.linksAt = future and now or math.max(now, (tonumber(g.linksAt) or 0) + 1)
    g.sig = sig
  end
end

-- This character's body: self plus the first 15 others by key, hidden ones left out; a hidden character's lists itself
-- alone (f5600, d837).
local function sendOwn(g)
  local me = Comm.MyKey()
  if not me or not own[me] then return false end
  local body
  if g.hidden[own[me]] then
    body = Links.Pack(g.linksAt, nil, { me })
  else
    local list, pick = visible(g)
    local keysOut = { me }
    for _, k in ipairs(list) do
      if k ~= me and #keysOut < Links.MAX_LINKS then keysOut[#keysOut + 1] = k end
    end
    body = Links.Pack(g.linksAt, pick, keysOut)
  end
  local list = records()
  local r = list[me]
  if r and r.body == body and not r.newer then return false end
  r = r or {}
  r.body, r.newer, r.held = body, nil, nil
  list[me] = r
  Comm.Sync.Changed(DOMAIN, me, serverNow())
  return true
end

-- At each rosterRead: the guild key from Compat.GuildInfo, whose realm is nil for a guild on the player's own realm
-- (Compat.lua:349), so the player's realm stands in and the key reads "<guild>-<realm>" either way. No guild name:
-- nothing is written or sent (never db.guild's old name). A partial read changes nothing (R1); a full one sets
-- the own-key set, prunes the records of members who left, restamps and sends the own record.
local function onRosterRead(partial)
  local name, realm = ns.Compat.GuildInfo()
  if not name then return end
  realm = realm or ns.Compat.Player().realm
  if not realm then return end
  local key = name .. "-" .. realm
  if key ~= guildKey then
    guildKey, full, own, parsed = key, false, {}, {}
  end
  if partial then return end
  local rows, isPartial, _, known = Comm.Roster()
  if not known or isPartial then return end
  local g = guild()
  local list = records()
  for k in pairs(list) do
    if not rows[k] then
      list[k] = nil
      parsed[k] = nil
    end
  end
  own, full = ownKeys(), true
  restamp(g)
  sendOwn(g)
  changed()
end

ns.On("rosterRead", onRosterRead, MODULE)

-- ---------- reads and the own setting (Api.lua wraps them) ----------

-- The parsed record of key: its body, or for a newer-format record the body held before it.
local function recOf(key, r)
  local body
  if r.newer then body = r.held else body = r.body end
  if type(body) ~= "string" then return nil end
  local p = parsed[key]
  if not p or p.body ~= body then
    p = { body = body, rec = Links.Parse(body, math.huge) }
    parsed[key] = p
  end
  return p.rec
end

local function levels()
  local db = ns.SavedDB()
  local g = db and type(db.guild) == "table" and db.guild or nil
  local out = {}
  for _, m in pairs(g and type(g.members) == "table" and g.members or {}) do
    local key = type(m) == "table" and Wire().Key(m.name) or nil
    if key then out[key] = { name = m.name, level = m.level, class = m.class } end
  end
  return out
end

local function mine()
  local g = peek()
  if not full or not g then return nil end
  local keysSet, hidden, pick = {}, {}, nil
  for key, guid in pairs(own) do
    keysSet[key] = true
    if type(g.hidden) == "table" and g.hidden[guid] then hidden[key] = true end
    if g.pick == guid then pick = key end
  end
  return { keys = keysSet, hidden = hidden, pick = pick }
end

local function parsedRecords()
  local recs = {}
  for k, r in pairs(readRecords()) do
    local rec = type(r) == "table" and recOf(k, r)
    if rec then recs[k] = rec end
  end
  return recs
end

-- Store.Person(key) -> Links.PersonOf's answer (keys) for key over the held records and the roster, or nil.
function Store.Person(key)
  return Links.PersonOf(key, parsedRecords(), levels(), mine())
end

-- Store.Levels() -> { [key] = { name, level, class } }: the viewer's roster as the rules read it (a fresh table).
Store.Levels = levels

-- Store.Mine() -> { { key, hidden, pick }, ... } sorted by key: this account's characters in this guild from the last
-- full read, hidden ones included; {} before it.
function Store.Mine()
  local g = peek()
  local out = {}
  if not full then return out end
  for key, guid in pairs(own) do
    out[#out + 1] = { key = key, hidden = (g and type(g.hidden) == "table" and g.hidden[guid]) and true or false, pick = (g and g.pick == guid) or false }
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- Store.Set(pick, hidden) -> true | nil, why. pick: an own key or nil (automatic); hidden: the full hidden set
-- { [key] = true } of own keys. Unchanged: true, nothing sent. Before a full read: nil, "roster".
function Store.Set(pick, hidden)
  if not full or not guildKey then return nil, "roster" end
  if pick ~= nil and (type(pick) ~= "string" or not own[pick]) then return nil, "bad pick" end
  if type(hidden) ~= "table" then return nil, "bad hidden" end
  local guids = {}
  for key, on in pairs(hidden) do
    if type(key) ~= "string" or not own[key] then return nil, "bad hidden" end
    if on then guids[own[key]] = true end
  end
  local g = guild()
  records()
  local pickGuid = pick and own[pick] or nil
  local same = g.pick == pickGuid
  for guid in pairs(guids) do if not g.hidden[guid] then same = false end end
  for guid in pairs(g.hidden) do if not guids[guid] then same = false end end
  if same then return true end
  g.pick, g.hidden = pickGuid, guids
  restamp(g)
  sendOwn(g)
  changed()
  return true
end

-- ---------- selftest and status ----------

local function counts()
  local n = 0
  for _, r in pairs(readRecords()) do if type(r) == "table" and r.rev then n = n + 1 end end
  local me = Comm.MyKey()
  local r = me and readRecords()[me]
  return n, (type(r) == "table" and r.rev) and "set" or "not set"
end

ns.RegisterModule({
  name = MODULE,
  id = DOMAIN,
  status = function()
    local n, set = counts()
    return "records " .. n .. ", my record " .. set
  end,
  selftest = function()
    if not attached then return "fail", "links domain not attached" end
    if not full then return "wait", "roster not read yet" end
    local n, set = counts()
    local m = 0
    for _ in pairs(own) do m = m + 1 end
    return "pass", "records " .. n .. ", my characters " .. m .. ", my record " .. set
  end,
})
