local _, ns = ...
if not ns.M then return end

-- The "raids_n" domain (officer rule) over GuildSyncRaidsDB.notes: the store the engine syncs (Store.lua's form), the
-- read API the Notes tab and the job card use, the kind B reader on raids_r and the redraw that waits out combat
-- (ticket 61, N1 and N2). The store is quiet while it holds no record: round and digest answer nil (plan "The quiet
-- rule"). Exports ns.NotesDB, ns.NotesAfterFight, ns.NotesView, ns.NotesFor, ns.NotesCalled, ns.notesStore (test
-- seam) and ns.RaidsR.B. Nothing here sends: no Comm.Send, no SendRaidsR, no Sync.Changed. Attach copies the store at
-- the call, so the file ends with the registration and the attach.

local M, NC, NR = ns.M, ns.NotesCodec, ns.NotesRules
local Plain = GuildSync.Compat.Plain
local call = M.Compat.call
local ID, SEP = "raids_n", "~"
local DAY, X_DAYS, GONE_DAYS, MAX_RECORDS, BY_MAX, HASH_MAX = 86400, 60, 60, 90, 60, 16
local FUTURE, CEIL, KEYMAX = 300, 4102444800, 48
local GONE_MAX, WINDOW = 2 * MAX_RECORDS, 7200
local RECV = NC.LIMITS.RECV

local function now()
  local v = call("GetServerTime")
  return tonumber(v) or 0
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- GuildSyncRaidsDB.notes; each of the four tables is made {} when missing or not a table. v and the top-level
-- records and gone are never touched.
function ns.NotesDB()
  local d = ns.DB()
  if type(d.notes) ~= "table" then d.notes = {} end
  local n = d.notes
  for _, k in ipairs({ "records", "gone", "drafts", "card" }) do
    if type(n[k]) ~= "table" then n[k] = {} end
  end
  return n
end

-- A read never adds the notes key to the SavedVariable (the engine's rounds and demo read it): with no saved notes it
-- answers an empty shape that is not kept.
local function held()
  if type(ns.DB().notes) ~= "table" then return { records = {}, gone = {} } end
  return ns.NotesDB()
end

-- gone holds at most GONE_MAX entries: the oldest at goes first.
local function capGone(gone)
  local list = {}
  for key, g in pairs(gone) do list[#list + 1] = { key = key, at = tonumber(type(g) == "table" and g.at) or 0 } end
  if #list <= GONE_MAX then return end
  table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.key < b.key end)
  for i = 1, #list - GONE_MAX do gone[list[i].key] = nil end
end

-- Live notes never expire. An X (deleted mark) more than X_DAYS past its gen goes to gone with its rev; gone entries
-- are kept GONE_DAYS, at most GONE_MAX of them.
local function prune(t)
  local n = held()
  for key, r in pairs(n.records) do
    if type(r) == "table" and type(r.body) == "string" and string.sub(r.body, 1, 2) == "X," then
      local rec = NC.Decode(key, r.body)
      if rec and rec.kind == "x" and rec.gen < t - X_DAYS * DAY then
        n.records[key] = nil
        n.gone[key] = { at = t, rev = tonumber(r.rev) or 0 }
      end
    end
  end
  for key, g in pairs(n.gone) do
    if type(g) ~= "table" or (tonumber(g.at) or 0) <= t - GONE_DAYS * DAY then n.gone[key] = nil end
  end
  capGone(n.gone)
  return n
end

-- ---------- the deferred redraw (Pulls.lua's wait for the end of combat) ----------

local dirty, waiting = false, false
local function changed()
  local v = call("InCombatLockdown")
  if v ~= false then
    dirty = true
    -- The card holds its own refresh behind its combat gate, so it is redrawn at PLAYER_REGEN_ENABLED before it is
    -- shown again (no wait for the redraw below).
    local f = ns.JobCardDataChanged
    if type(f) == "function" then f() end
    return
  end
  if waiting then return end
  waiting = true
  M.After(1, function()
    waiting = false
    local again = call("InCombatLockdown")
    if again ~= false then
      dirty = true
      return
    end
    dirty = false
    M.RefreshPage()
    local f = ns.JobCardDataChanged
    if type(f) == "function" then f() end
  end)
end

-- Called by ns.OnFightEvent at PLAYER_REGEN_ENABLED: the change held back in combat, through the same path.
function ns.NotesAfterFight()
  if not dirty then return end
  local v = call("InCombatLockdown")
  if v ~= false then return end
  dirty = false
  changed()
end

-- ---------- logical codec (Store.lua's, with the notes keys; every text cleaned on receipt) ----------

local function packMsg(m)
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

-- A received rev: 1 to 16 digits, else nil.
local function revOf(s)
  if type(s) ~= "string" or #s < 1 or #s > 16 or not string.match(s, "^%d+$") then return nil end
  return tonumber(s)
end

local function unpackMsg(logical)
  if type(logical) ~= "string" then return nil end
  local f = {}
  for x in (logical .. SEP):gmatch("([^~]*)~") do f[#f + 1] = x end
  local t = f[1]
  if t == "P" then
    local rev = revOf(f[3])
    if not rev or not NC.ValidKey(f[2]) then return nil end
    return { t = "P", key = f[2], rev = rev, hash = NC.Clean(f[4], HASH_MAX) or "", by = NC.Clean(f[5], BY_MAX) or "",
      body = f[6] or "" }
  end
  if t == "H" then return { t = "H", hash = NC.Clean(f[2], HASH_MAX) or "" } end
  if t == "D" or t == "R" then
    local entries = {}
    for e in ((f[2] or "") .. ";"):gmatch("([^;]*);") do
      local k, r, h = e:match("^([^,]*),([^,]*),(.*)$")
      local rev = k and revOf(r)
      if rev and NC.ValidKey(k) then entries[#entries + 1] = { key = k, rev = rev, hash = NC.Clean(h, HASH_MAX) or "" } end
    end
    return { t = t, entries = entries }
  end
  return nil
end

-- ---------- the store (CommSync.lua:7-10) ----------

local store = { recordRule = "officer", kinds = { round = "H", digest = "D", ask = "R", record = "P" },
  maxRecords = MAX_RECORDS, maxEntries = 2 * MAX_RECORDS }

local function listKeys(t)
  local n = prune(t)
  local list = {}
  for k, r in pairs(n.records) do if type(r) == "table" and r.rev then list[#list + 1] = k end end
  table.sort(list)
  return list, n
end

function store.get(key) return held().records[key] end
function store.keys() return (listKeys(now())) end
function store.content(key)
  local r = held().records[key]
  return r and ((r.by or "") .. SEP .. (r.body or "")) or nil
end
function store.stamp(key, rev, hash)
  local recs = ns.NotesDB().records
  local r = recs[key] or {}
  recs[key] = r
  r.rev, r.hash = rev, hash
end
function store.isOwn() return false end
function store.heardOwn() end
function store.build(key, t)
  local r = prune(t).records[key]
  if type(r) ~= "table" or not r.rev then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, by = r.by, body = r.body }
end

-- A rev at or below the gone rev is dropped, and so is a rev below the held one; a new key is not stored while
-- MAX_RECORDS are held. A refused body (over RECV, undecodable, a gen beyond t + FUTURE) goes to gone with its rev.
function store.merge(msg, t)
  local key = msg.key
  if not NC.ValidKey(key) then return true end
  prune(t)
  local n = ns.NotesDB()
  local rev = tonumber(msg.rev) or 0
  local g = n.gone[key]
  if g and rev <= (tonumber(g.rev) or 0) then return true end
  local cur = n.records[key]
  if cur and rev < (tonumber(cur.rev) or 0) then return true end
  if not cur and count(n.records) >= MAX_RECORDS then return true end
  local body = msg.body
  local rec = type(body) == "string" and #body <= RECV and NC.Decode(key, body)
  if not rec or rec.gen > t + FUTURE then
    n.records[key] = nil
    n.gone[key] = { at = t, rev = rev }
    capGone(n.gone)
  else
    n.records[key] = { rev = rev, hash = NC.Clean(msg.hash, HASH_MAX) or "", by = NC.Clean(msg.by, BY_MAX) or "",
      body = body }
    n.gone[key] = nil
  end
  changed()
  return true
end

-- The quiet rule: nil while no record is held.
function store.round(t)
  local list, n = listKeys(t)
  if next(n.records) == nil then return nil end
  local parts = {}
  for _, k in ipairs(list) do parts[#parts + 1] = k .. "=" .. n.records[k].rev .. "=" .. (n.records[k].hash or "") end
  return { t = "H", hash = ns.Adler(table.concat(parts, "/")) }
end
function store.digest(t)
  local list, n = listKeys(t)
  if next(n.records) == nil then return nil end
  local entries = {}
  for _, k in ipairs(list) do entries[#entries + 1] = { key = k, rev = n.records[k].rev, hash = n.records[k].hash } end
  return { t = "D", entries = entries }
end

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

-- Rules.Compare's rule over the notes keys; a full store asks for no key it does not hold.
function store.compare(msg, t)
  local n = prune(t)
  local records, gone = n.records, n.gone
  local full = count(records) >= MAX_RECORDS
  local send, ask, theirs = {}, {}, {}
  for _, e in ipairs(type(msg.entries) == "table" and msg.entries or {}) do
    if type(e) == "table" and NC.ValidKey(e.key) then
      theirs[e.key] = e
      local r, g = records[e.key], gone[e.key]
      local rev = tonumber(e.rev) or 0
      if type(r) == "table" and r.rev then
        if newer(rev, e.hash, tonumber(r.rev), r.hash) then ask[#ask + 1] = { key = e.key, rev = r.rev } end
      elseif not full and rev > (g and tonumber(g.rev) or 0) then
        ask[#ask + 1] = { key = e.key, rev = 0 }
      end
    end
  end
  local mine = {}
  for key, r in pairs(records) do
    if NC.ValidKey(key) and type(r) == "table" and r.rev then mine[#mine + 1] = key end
  end
  table.sort(mine)
  for _, key in ipairs(mine) do
    local e, r = theirs[key], records[key]
    if not e or newer(tonumber(r.rev), r.hash, tonumber(e.rev) or 0, e.hash) then send[#send + 1] = key end
  end
  return send, ask
end
function store.stillWanted(w, t)
  local r = prune(t).records[w.subject]
  if w.t == "P" then return type(r) == "table" and r.rev == tonumber(w.version) end
  if w.t == "R" then return ((type(r) == "table" and r.rev) or 0) == (tonumber(w.version) or 0) end
  return true
end
store.pack = packMsg
function store.parts(msg) return { msg } end
function store.subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end
ns.notesStore = store -- the table attached below (test seam)

local handle = {}
for kind, role in pairs({ H = "round", D = "digest", R = "ask", P = "record" }) do
  handle[kind] = function(msg, from, t) M.Sync.Handle(ID, role, msg, from, t) end
end

-- ---------- read API ----------

-- Demo: the made-up notes over the made-up guild, cached in the demo state (memory only, never saved).
local function demoRecords(d)
  if not d.notes then
    local keys, names = {}, {}
    for k in pairs(type(d.rows) == "table" and d.rows or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local r = d.rows[k]
      if type(r) == "table" and type(r.name) == "string" then names[#names + 1] = r.name end
    end
    local me
    if type(M.MyCharacters) == "function" then
      local chars = M.MyCharacters()
      local first = type(chars) == "table" and chars[1]
      local name = type(first) == "table" and first.name or nil
      me = Plain(name)
    end
    if type(me) ~= "string" then
      local unit = call("UnitName", "player")
      me = Plain(unit)
    end
    d.notes = NR.Demo(names, type(me) == "string" and me or nil, tonumber(d.now) or now())
  end
  return d.notes
end

function ns.NotesView()
  local d = ns.DemoData and ns.DemoData()
  if d then return NR.View(demoRecords(d), tonumber(d.now) or now()) end
  return NR.View(held().records, now())
end

function ns.NotesFor(ev) return NR.ForEvent(ns.NotesView(), ev) end

-- The one rule for "my keys" (the tab and the job card): { [key] = true } for the logged-in character (ns.MyKey, so
-- it works before the first full roster read) and each of M.MyCharacters, keyed with ns.Key(name) as
-- NotesRules.YourJobs keys a holder's name. Every hub result goes into a local first (it can answer no value).
function ns.NotesMyKeys()
  local keys = {}
  local me = ns.MyKey and ns.MyKey()
  if type(me) == "string" then keys[me] = true end
  local chars
  if type(M.MyCharacters) == "function" then chars = M.MyCharacters() end
  for _, ch in ipairs(type(chars) == "table" and chars or {}) do
    local name = type(ch) == "table" and ch.name or nil
    local k = type(name) == "string" and ns.Key(name) or nil
    if type(k) == "string" then keys[k] = true end
  end
  return keys
end

-- The called boss per event id (memory only). In demo, Magmadar is called on the first demo event that holds him.
local called = {}
local function calledMap()
  local d = ns.DemoData and ns.DemoData()
  if not d then return called end
  if not d.notesCalled then
    d.notesCalled = {}
    for _, ev in ipairs(ns.View().events or {}) do
      local raid = ns.NotesFor(ev)
      for _, b in ipairs(type(raid) == "table" and raid.bosses or {}) do
        if b.name == "Magmadar" then
          d.notesCalled[tostring(ev.id)] = { raid = raid.id, boss = b.id }
          return d.notesCalled
        end
      end
    end
  end
  return d.notesCalled
end

function ns.NotesCalled(eventId)
  local c = calledMap()[tostring(eventId)]
  return type(c) == "table" and c.boss or nil
end

-- ---------- kind B on raids_r (plan "Kind B text") ----------

local function digits(s, max) return type(s) == "string" and #s >= 1 and #s <= max and string.match(s, "^%d+$") ~= nil end

local function holderNames(s)
  local list = {}
  for name in (s .. "/"):gmatch("([^/]*)/") do
    if #name < 1 or #name > NC.LIMITS.NAME or string.find(name, "[~,=/%%|%c]") or NC.Utf8(name) ~= name then
      return nil
    end
    list[#list + 1] = name
  end
  if #list < 1 or #list > NC.LIMITS.HOLDERS then return nil end
  return list
end

local B = { v = 1 }

function B.unpack(logical)
  if type(logical) ~= "string" or #logical > RECV then return nil end
  local f = {}
  for x in (logical .. SEP):gmatch("([^~]*)~") do f[#f + 1] = x end
  if #f < 8 or #f > 16 or f[1] ~= "B" then return nil end
  local by = f[2]
  if #by < 1 or #by > KEYMAX or string.find(by, ",", 1, true) or ns.Key(by) ~= by then return nil end
  local at = digits(f[3], 10) and tonumber(f[3])
  if not at or at > CEIL then return nil end
  if not digits(f[4], 20) or not digits(f[5], 20) or not digits(f[6], 20) or not digits(f[7], 16) then return nil end
  local holders, n = {}, 0
  if f[8] ~= "" then
    for entry in (f[8] .. ","):gmatch("([^,]*),") do
      local no, names = string.match(entry, "^(%d%d?)=(.*)$")
      no = tonumber(no)
      if not no or no < 1 or no > 20 or holders[no] then return nil end
      local list = holderNames(names)
      if not list then return nil end
      holders[no] = list
      n = n + 1
      if n > 20 then return nil end
    end
  end
  return { t = "B", by = by, at = at, event = f[4], raid = f[5], boss = f[6], ver = f[7], holders = holders }
end

function B.pack(msg)
  if type(msg) ~= "table" or msg.t ~= "B" or type(msg.holders) ~= "table" then return nil end
  local nos = {}
  for no, list in pairs(msg.holders) do
    if type(no) ~= "number" or type(list) ~= "table" then return nil end
    nos[#nos + 1] = no
  end
  table.sort(nos)
  local entries = {}
  for _, no in ipairs(nos) do
    local list = msg.holders[no]
    for _, name in ipairs(list) do if type(name) ~= "string" or NC.Utf8(name) ~= name then return nil end end
    entries[#entries + 1] = no .. "=" .. table.concat(list, "/")
  end
  local fields = { "B", msg.by, msg.at, msg.event, msg.raid, msg.boss, msg.ver }
  for i = 2, 7 do
    if type(fields[i]) ~= "string" and type(fields[i]) ~= "number" then return nil end
    fields[i] = tostring(fields[i])
  end
  fields[8] = table.concat(entries, ",")
  local text = table.concat(fields, SEP)
  if not B.unpack(text) then return nil end
  return text
end

function B.subject(msg) return "call:" .. msg.event, msg.at end

-- Only a call from the raid's leader (a plain true), for a held event whose notes raid is the call's raid and holds
-- the boss; ns.Night is called only after that.
function B.handle(msg, from, t)
  local leads = ns.LeadsMyRaid
  if type(leads) ~= "function" then return end
  local isLeader = leads(from)
  if isLeader ~= true then return end
  local ev
  for _, e in ipairs(ns.View().events or {}) do
    if type(e) == "table" and tostring(e.id) == msg.event then
      ev = e
      break
    end
  end
  if not ev then return end
  local raid = ns.NotesFor(ev)
  if type(raid) ~= "table" or raid.id ~= msg.raid then return end
  -- The call counts only inside the event's window, WINDOW seconds either side; no number start, no call.
  local start = ev.start
  if type(start) ~= "number" then return end
  local finish = type(ev.finish) == "number" and ev.finish or start
  if type(t) ~= "number" or t < start - WINDOW or t > finish + WINDOW then return end
  local found
  for _, b in ipairs(raid.bosses or {}) do if b.id == msg.boss then found = b end end
  if not found then return end
  local isJob = {}
  for _, j in ipairs(found.jobs or {}) do isJob[j.no] = true end
  calledMap()[tostring(ev.id)] = { raid = msg.raid, boss = msg.boss, ver = msg.ver, at = msg.at, by = from }
  local night = type(ns.Night) == "function" and ns.Night(ev.id)
  if type(night) == "table" then
    if type(night.holders) ~= "table" then night.holders = {} end
    local copy = {}
    for no, list in pairs(msg.holders or {}) do
      if type(list) == "table" and isJob[no] then
        local names = {}
        for i, name in ipairs(list) do names[i] = name end
        copy[no] = names
      end
    end
    night.holders[msg.boss] = copy
  end
  changed()
  local arrived = ns.NotesCallArrived
  if type(arrived) == "function" then arrived(ev, msg.boss) end
end

if type(ns.RaidsR) == "table" then ns.RaidsR.B = B end

-- ---------- the domain: register, then attach, last ----------

local okRegister = M.Comm.Register({
  id = ID, prefix = "GSync", audience = "guild", owner = "officer", maxChunks = 16,
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "officer" } },
  unpack = unpackMsg, handle = handle,
})
if okRegister then M.Sync.Attach(ID, store) end
