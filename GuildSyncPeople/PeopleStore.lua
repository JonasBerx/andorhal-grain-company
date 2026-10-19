-- GuildSyncPeople: the saved records, the people domain, the profile and Save (plan Task 3, base spec items 6-9).
-- One put-rule domain "people": each character publishes the account's profile for this guild under its own roster key,
-- and the engine takes a record only from its owner (CommSync.lua:707, :764). Records stay in memory until the guild
-- key is known, then live in GuildSyncPeopleDB.guilds[<guild key>].records; the profile in .profile. A body in a newer
-- format is kept raw (capped at the wire bound) with rev, hash and newer = true, and shows the body held before, if any
-- (gate A f3). editedAt, Changed's time and the receive bound use GetServerTime (design review f6).

local _, ns = ...
if not ns.M then return end

local DOMAIN = "people"
local INERT = "Demo: nothing is done to made-up members." -- the hub's own demo line (GuildSync/Demo.lua:18)
local RAW_BYTES = 16 * 250 -- a newer body is kept up to the wire bound (maxChunks x Wire.MAX)
-- A v1 body is kept up to the largest honest one: "1^" + 10-digit editedAt + "^" + 42-digit mask + "^" + 24 tag bytes
-- + "^" + 560 note bytes = 641 (S-f2).
local V1_BYTES = 650

local memory = {}  -- records heard before the guild key is known
local pending      -- a profile saved before the guild key is known
local parsed = {}  -- key -> { body, rec }: parsed bodies, session only

local function say(text) GuildSync.Say("People: " .. text) end
local function serverNow() return ns.M.Compat.call("GetServerTime") end

-- GuildSyncPeopleDB is set by the client at ADDON_LOADED: read it at call time, create it only to write.
local function db()
  if type(GuildSyncPeopleDB) ~= "table" then GuildSyncPeopleDB = {} end
  return GuildSyncPeopleDB
end

-- This guild's saved table, or nil while the key is unknown (nothing is written then).
local function guild()
  local key = ns.GuildKey and ns.GuildKey()
  if not key then return nil end
  local d = db()
  if type(d.guilds) ~= "table" then d.guilds = {} end
  local g = d.guilds[key]
  if type(g) ~= "table" then
    g = {}
    d.guilds[key] = g
  end
  if type(g.records) ~= "table" then g.records = {} end
  return g
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
  if pending then
    if type(g.profile) ~= "table" or (tonumber(g.profile.editedAt) or 0) <= (pending.editedAt or 0) then
      g.profile = pending
    end
    pending = nil
  end
  return g.records
end

-- ---------- reads for the other files ----------

function ns.Profile()
  local g = guild()
  if g then
    records()
    return type(g.profile) == "table" and g.profile or nil
  end
  return pending
end

function ns.HasRecord(key) return records()[key] ~= nil end

-- The record shown for key: its body parsed, or for a newer-format record the body held before it.
function ns.RecOf(key)
  local r = records()[key]
  if type(r) ~= "table" then return nil end
  local body
  if r.newer then body = r.held else body = r.body end
  if type(body) ~= "string" then return nil end
  local p = parsed[key]
  if not p or p.body ~= body then
    p = { body = body, rec = ns.Record.Parse(body, math.huge) }
    parsed[key] = p
  end
  return p.rec
end

-- ---------- the store (CommSync.lua's header) ----------

local function adler(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
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
function store.isOwn(key) return key ~= nil and key == ns.MyKey() end
function store.build(key)
  local r = records()[key]
  if not r or not r.rev or type(r.body) ~= "string" then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, body = r.body }
end
-- Refused (false, nothing kept) unless the body parses; a newer format is kept raw (f3).
function store.merge(msg, t)
  local rec, why = ns.Record.Parse(msg.body, serverNow() or t)
  local list = records()
  if rec then
    list[msg.key] = { rev = msg.rev, hash = msg.hash, body = ns.Rules.CutBytes(msg.body, V1_BYTES) }
  elseif why == "newer" then
    local had, held = list[msg.key], nil
    if had then
      if had.newer then held = had.held else held = had.body end
    end
    list[msg.key] = { rev = msg.rev, hash = msg.hash, body = ns.Rules.CutBytes(msg.body, RAW_BYTES), newer = true,
      held = held }
  else
    return false
  end
  ns.M.RefreshPage()
  ns.M.RefreshMember()
  return true
end
local function setHash()
  local list, parts = records(), {}
  for _, k in ipairs(keys()) do parts[#parts + 1] = k .. "=" .. list[k].rev .. "=" .. (list[k].hash or "") end
  return adler(table.concat(parts, "/"))
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
function store.pack(msg) return ns.Record.PackMsg(msg) end
function store.parts(msg) return { msg } end
function store.subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }
local handle = {}
for kind, role in pairs(ROLE) do
  handle[kind] = function(msg, from, t) ns.M.Sync.Handle(DOMAIN, role, msg, from, t) end
end

local attached = false
if ns.M.Comm.Register({
  id = DOMAIN, prefix = "GSync", audience = "guild", owner = "self",
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "put" } },
  unpack = function(text) return ns.Record.UnpackMsg(text) end, handle = handle,
}) then
  attached = ns.M.Sync.Attach(DOMAIN, store) and true or false
end

-- ---------- publishing the own record ----------

-- After the session's first rosterRead MyKey() is the roster key: write the own record from the profile when it is
-- missing or differs, and hand it to the engine once.
local function publish(t)
  if not (ns.RosterSeen and ns.RosterSeen()) then return false end
  local key, prof = ns.MyKey(), ns.Profile()
  if not key or not prof then return false end
  local list, body = records(), ns.Record.Pack(prof)
  local r = list[key]
  if r and r.body == body and not r.newer then return false end
  r = r or {}
  r.body, r.newer, r.held = body, nil, nil
  list[key] = r
  ns.M.Sync.Changed(DOMAIN, key, t or serverNow())
  return true
end

-- PeopleRoster.lua calls this at each rosterRead, after its own read; prune and publish only when that read
-- succeeded (S-f3: after a guild change the hub roster and the key may still be the old guild's).
function ns.RosterRead(partial, readOk)
  if not readOk then return ns.M.RefreshPage() end
  local list = records()
  if not partial then
    local rows, isPartial, _, known = GuildSync.Comm.Roster()
    if known and not isPartial and type(rows) == "table" and list ~= memory then
      for key in pairs(list) do
        if not rows[key] then
          list[key] = nil
          parsed[key] = nil
        end
      end
    end
  end
  publish()
  ns.M.RefreshPage()
end

-- Save(note, tags, mask) -> true | nil, why. Before the first rosterRead only the profile is stored; after it, with
-- no guild key nothing can be stored (S-f8: it would be lost at /reload), so Save says so and answers nil, "guild".
function ns.Save(note, tags, mask)
  local on = ns.M.Demo()
  if on then
    GuildSync.Say(INERT)
    return nil, "demo"
  end
  local now = serverNow()
  if type(now) ~= "number" then return nil, "time" end
  local list = {}
  for _, code in ipairs(type(tags) == "table" and tags or {}) do
    if ns.Rules.LABEL[code] then list[#list + 1] = code end
  end
  if not ns.Rules.ValidMask(mask) then mask = "" end
  local prof = { note = ns.Rules.CleanNote(note), tags = list, mask = mask, editedAt = now }
  local g = guild()
  if g then
    records()
    g.profile = prof
  elseif ns.RosterSeen and ns.RosterSeen() then
    say("no guild yet, so the profile was not saved. Try again in a moment.")
    return nil, "guild"
  else
    pending = prof
  end
  publish(now)
  ns.M.RefreshPage()
  return true
end

-- ---------- the hover setting (item 26): GuildSyncPeopleDB.hover, default on ----------

function ns.Hover()
  local d = GuildSyncPeopleDB
  if type(d) ~= "table" or d.hover == nil then return true end
  return d.hover == true
end

function ns.SetHover(on) db().hover = on and true or false end

-- ---------- the guild-chat tag setting (items 27-30): GuildSyncPeopleDB.tag, default on ----------

function ns.Tag()
  local d = GuildSyncPeopleDB
  if type(d) ~= "table" or d.tag == nil then return true end
  return d.tag == true
end

function ns.SetTag(on) db().tag = on and true or false end

-- ---------- selftest, status, /gspeople ----------

local function counts()
  local profiles = 0
  for key in pairs(records()) do if ns.RecOf(key) then profiles = profiles + 1 end end
  return "profiles " .. profiles .. ", people " .. ((ns.PeopleCount and ns.PeopleCount()) or 0)
end

-- ", no hook: <name>" per missing hook (fixed order), then the missing guards (crosscheck C2).
local HOOKS = { "unit card", "chat name card", "roster card", "chat tag" }
local function missing()
  local out, miss = {}, {}
  for _, n in ipairs(ns.HookMissing and ns.HookMissing() or {}) do miss[n] = true end
  for _, n in ipairs(HOOKS) do if miss[n] then out[#out + 1] = ", no hook: " .. n end end
  local Has = GuildSync.Compat.Has
  if not Has("C_Secrets.ShouldUnitIdentityBeSecret") then out[#out + 1] = ", no guard: secrets" end
  if not Has("C_ChatInfo.InChatMessagingLockdown") then out[#out + 1] = ", no guard: lockdown" end
  return table.concat(out)
end

function ns.Selftest()
  if not attached then return "fail", "people domain not attached" end
  if not (ns.RosterSeen and ns.RosterSeen()) then return "wait", "roster not read yet" end
  local key = ns.MyKey()
  local mine = key and records()[key]
  return "pass", counts() .. ", my record " .. ((mine and mine.rev) and "set" or "not set") .. missing()
end

function ns.Status()
  local tag = ns.Tag() and ns.TagWired and ns.TagWired()
  return counts() .. ", card on hover " .. (ns.Hover() and "on" or "off") .. ", chat tag " .. (tag and "on" or "off")
    .. missing()
end

function ns.Slash(rest)
  local cmd, arg = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd, arg = string.lower(cmd or ""), string.lower(arg or "")
  if cmd == "hover" then
    if arg == "on" or arg == "off" then ns.SetHover(arg == "on") end
    say("card on hover " .. (ns.Hover() and "on" or "off"))
  elseif cmd == "tag" then
    if arg == "on" or arg == "off" then ns.SetTag(arg == "on") end
    say("chat tag " .. (ns.Tag() and "on" or "off"))
  elseif cmd == "time" then
    local cal = ns.Now()
    local h, m = ns.M.Compat.call("GetGameTime")
    say(string.format("calendar: weekday %d, %02d:%02d; game time: %02d:%02d", cal.weekday, cal.hour, cal.minute,
      tonumber(h) or 0, tonumber(m) or 0))
  else
    say("/gspeople opens the page; /gspeople hover on|off; /gspeople tag on|off; /gspeople time")
  end
end
