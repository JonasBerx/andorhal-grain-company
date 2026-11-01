-- GuildKOS Store: the three record domains on GuildSync's record engine (R6 Task B2; plan Decisions "Domains",
-- "Keys", "Own record", "Sends while not ready"). kos (targets, key "t" .. GUID) and kos_h (hunters, key "h" ..
-- member key) take only officers' records (kinds.P rule officer and recordRule officer); kos_m (one record per
-- member, key the member key) is a copy domain. Records live in GuildKOSDB.guilds[guild key] (Core.Guild), each entry
-- { rev, hash, by, rec, at }: rec is the RulesRecords shape, at the local time it was written or merged.
-- The store functions read the client only through the GuildSync global and Core (ns.Hub), never through M, so a
-- second load with another handle reads the same saved data (and never the demo state).
local _, ns = ...
local Store = {}
ns.Store = Store

local SEP = "~"
local KIND = { kos = "t", kos_h = "h", kos_m = "m" }
local RULE = { kos = "officer", kos_h = "officer", kos_m = "copy" }
local IDS = { "kos", "kos_h", "kos_m" }

local M                 -- the handle given to Register
local held = {}         -- own edits made before Ready() ({ edit, guild }), applied in order once it holds
local HELD_MAX = 20      -- held own edits, oldest out (f5439)
local polling = false
local listener          -- OnHunterMerged's one listener
local targetListener    -- OnTargetMerged's one listener
local memberListener    -- OnMemberMerged's one listener

local function Records() return ns.RulesRecords end
local function comm() return type(GuildSync) == "table" and GuildSync.Comm or nil end
local function myKey()
  local c = comm()
  return c and c.MyKey() or nil
end

-- This guild's table for domain id, or nil while the guild name is unread.
local function recs(id)
  local g = ns.Core and ns.Core.Guild()
  if not g then return nil end
  if type(g[id]) ~= "table" then g[id] = {} end
  return g[id]
end

-- This guild's gone set for domain id: key -> { rev, hash } (d757 items 2, 3, 6; gate-a-advisor item 2).
local GONE_MAX = 500           -- keys per domain, oldest rev out
local BOUND = 100              -- records per officer domain, open targets last
local OPEN_MAX = 60            -- open targets held, own and learned (brief sizes, plan f5202 c)
Store.OPEN_MAX = OPEN_MAX
local STATUS = { open = true, removed = true, rejected = true } -- the only stored target statuses (AC12)
local KEEP = { rejected = 7 * 86400, removed = 30 * 86400 } -- kos keep times after decidedAt
local LEFT_KEEP = 30 * 86400   -- a leaver's kos_m record, after its key left the roster

local function goneSet(id)
  local g = ns.Core and ns.Core.Guild()
  if not g then return nil end
  if type(g.gone) ~= "table" then g.gone = {} end
  if type(g.gone[id]) ~= "table" then g.gone[id] = {} end
  return g.gone[id]
end

-- Remembers key at rev and hash; past GONE_MAX the lowest rev (then key) leaves.
-- refused: a refused body for a key not held, which suppresses only its exact rev and hash (f5441).
local function bury(id, key, rev, hash, refused)
  local gone = goneSet(id)
  if not gone or type(rev) ~= "number" then return end
  gone[key] = { rev = rev, hash = hash, refused = refused or nil }
  local n, low, lowK = 0, nil, nil
  for k, e in pairs(gone) do
    n = n + 1
    if not low or e.rev < low or (e.rev == low and k < lowK) then low, lowK = e.rev, k end
  end
  if n > GONE_MAX then gone[lowK] = nil end
end

-- Prune order (pure): true when key a with entry ea leaves before key b with entry eb. kos: non-open first, then
-- oldest decidedAt (markedAt for open), then key. kos_h (d769): lowest total, then oldest newest kept kill (no kills:
-- the start of the since week, since * 604800 + 345600), then key.
local function pruneBefore(id, a, ea, b, eb)
  local ra, rb = ea.rec or {}, eb.rec or {}
  local ta, tb
  if id == "kos" then
    local oa, ob = ra.status == "open", rb.status == "open"
    if oa ~= ob then return ob end
    ta = tonumber(oa and ra.markedAt or ra.decidedAt) or 0
    tb = tonumber(ob and rb.markedAt or rb.decidedAt) or 0
  else
    local na, nb = tonumber(ra.total) or 0, tonumber(rb.total) or 0
    if na ~= nb then return na < nb end
    local function last(r)
      local x
      for _, k in ipairs(type(r.kills) == "table" and r.kills or {}) do
        local t = type(k) == "table" and tonumber(k.time)
        if t and (not x or t > x) then x = t end
      end
      if x then return x end
      local since = tonumber(r.since)
      return since and since * 604800 + 345600 or 0
    end
    ta, tb = last(ra), last(rb)
  end
  if ta ~= tb then return ta < tb end
  return a < b
end

-- Keep-time expiry (kos) and the bound (kos, kos_h) after a write or merge at time t; each key out goes to gone.
local function tidy(id, t)
  if id == "kos_m" then return end
  local r = recs(id)
  if not r then return end
  local list = {}
  for k, e in pairs(r) do
    if type(e) == "table" and e.rev then
      local rec = type(e.rec) == "table" and e.rec or {}
      local keep = id == "kos" and KEEP[rec.status]
      if keep and type(t) == "number" and (tonumber(rec.decidedAt) or 0) + keep < t then
        r[k] = nil
        bury(id, k, e.rev, e.hash)
      else
        list[#list + 1] = k
      end
    end
  end
  if #list <= BOUND then return end
  table.sort(list, function(a, b) return pruneBefore(id, a, r[a], b, r[b]) end)
  for i = 1, #list - BOUND do
    local e = r[list[i]]
    r[list[i]] = nil
    bury(id, list[i], e.rev, e.hash)
  end
end

local function adler(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

-- ---------- Ready: roster known and whole, guild name read ----------

function Store.Ready()
  local c = comm()
  if not c then return false, "roster" end
  local ok, _, partial, _, known = pcall(c.Roster)
  if not ok or not known or partial then return false, "roster" end
  if not (ns.Core and ns.Core.GuildKey()) then return false, "guild" end
  return true
end

-- ---------- wire messages (as GuildSyncHello's) ----------

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

local function unpackMsg(logical)
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

-- ---------- one store per domain ----------

local function newStore(id)
  local kind = KIND[id]
  local store = { recordRule = RULE[id], kinds = { round = "H", digest = "D", ask = "R", record = "P" },
    hEvery = 900, maxRecords = 100, maxEntries = 500 }

  -- kos_m keys off the roster are neither offered nor asked for (a leaver's record, AC7b)
  local function onRoster()
    if id ~= "kos_m" then return nil end
    local c = comm()
    local rows = c and c.Roster() or {}
    return function(key) return rows[key] ~= nil end
  end

  local function keys()
    local list, r = {}, recs(id)
    if not r then return list end
    local keep = onRoster()
    for k, e in pairs(r) do
      if type(e) == "table" and e.rev and (not keep or keep(k)) then list[#list + 1] = k end
    end
    table.sort(list)
    return list
  end

  -- a gone key answers its tombstone: { rev, hash } and nothing else
  function store.get(key)
    local r = recs(id)
    if r and r[key] then return r[key] end
    local gone = goneSet(id)
    local g = gone and gone[key]
    if type(g) == "table" and not g.refused then return { rev = g.rev, hash = g.hash } end
    return nil
  end
  function store.keys() return keys() end
  function store.content(key)
    local r = recs(id)
    local e = r and r[key]
    if not e or type(e.rec) ~= "table" then return nil end
    return (e.by or "") .. SEP .. (Records().Pack(kind, e.rec) or "")
  end
  function store.stamp(key, rev, hash)
    local r = recs(id)
    if not r then return end
    local e = r[key] or {}
    r[key] = e
    e.rev, e.hash = rev, hash
  end
  function store.isOwn(key) return key ~= nil and key == myKey() end
  function store.heardOwn() end
  function store.build(key)
    local r = recs(id)
    local e = r and r[key]
    if not e or not e.rev or type(e.rec) ~= "table" then return nil end
    return { t = "P", key = key, rev = e.rev, hash = e.hash, by = e.by, body = Records().Pack(kind, e.rec) }
  end
  function store.merge(msg, t)
    local r = recs(id)
    if not r then return end
    local rec = Records().Parse(kind, msg.key, msg.body or "", t)
    if not rec then -- refused body: stored nowhere, its rev marked in gone; a held record stays served (d765)
      local gone = goneSet(id)
      local g = gone and gone[msg.key]
      -- no record and no tombstone held: only this exact rev and hash is marked (f5441)
      local only = not r[msg.key] and not (type(g) == "table" and not g.refused)
      bury(id, msg.key, msg.rev, msg.hash, only)
      return
    end
    if id == "kos" then rec.level = rec.level or "" end -- a target's level is a number or "" (AC12)
    -- by: the hub already checked it (an officer's key on kos and kos_h); kos_m's identity is the record key
    r[msg.key] = { rev = msg.rev, hash = msg.hash, by = type(msg.by) == "string" and msg.by or nil, rec = rec, at = t }
    local gone = goneSet(id)
    local g = gone and gone[msg.key]
    if g and newer(msg.rev, msg.hash, g.rev, g.hash) then gone[msg.key] = nil end
    tidy(id, t)
    if id == "kos_h" and listener and r[msg.key] then listener(msg.key, rec) end
    if id == "kos" and targetListener and r[msg.key] then targetListener(msg.key, rec) end
    if id == "kos_m" and memberListener and r[msg.key] then memberListener(msg.key, rec) end
    return true
  end
  function store.round(t)
    if not Store.Ready() then return nil end
    if id == "kos_m" then Store.Leavers(t) end
    local parts = {}
    for _, k in ipairs(keys()) do
      local e = store.get(k)
      parts[#parts + 1] = k .. "=" .. e.rev .. "=" .. (e.hash or "")
    end
    return { t = "H", hash = adler(table.concat(parts, "/")) }
  end
  function store.digest()
    if not Store.Ready() then return nil end
    local entries = {}
    for _, k in ipairs(keys()) do
      local e = store.get(k)
      entries[#entries + 1] = { key = k, rev = e.rev, hash = e.hash }
    end
    return { t = "D", entries = entries }
  end
  function store.compare(msg)
    if not Store.Ready() then return nil end
    local send, ask, theirs = {}, {}, {}
    local keep = onRoster()
    for _, e in ipairs(msg.entries or {}) do
      theirs[e.key] = e
      local mine = store.get(e.key)
      local gone = goneSet(id)
      local g = gone and gone[e.key] -- a refused rev over a held record: nothing at or below it is asked for (d765)
      local barred = g and (g.refused and e.rev == g.rev and e.hash == g.hash
        or not g.refused and not newer(e.rev, e.hash, g.rev, g.hash))
      if (not keep or keep(e.key)) and (not mine or not mine.rev or newer(e.rev, e.hash, mine.rev, mine.hash))
         and not barred then
        ask[#ask + 1] = { key = e.key, rev = mine and mine.rev or 0 }
      end
    end
    for _, k in ipairs(keys()) do
      local e, mine = theirs[k], store.get(k)
      if not e or newer(mine.rev, mine.hash, e.rev, e.hash) then send[#send + 1] = k end
    end
    return send, ask
  end
  function store.stillWanted(w)
    local e = store.get(w.subject)
    if w.t == "P" then return e ~= nil and e.rev == tonumber(w.version) end
    if w.t == "R" then return ((e and e.rev) or 0) == (tonumber(w.version) or 0) end
    return true
  end
  function store.pack(msg) return packMsg(msg) end
  function store.parts(msg) return { msg } end
  function store.subject(msg)
    if msg.t == "P" then return msg.key, msg.rev end
    return "-", 0
  end
  return store
end

-- ---------- registration ----------

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }

function Store.Register(handle)
  M = handle
  for _, id in ipairs(IDS) do
    local h = {}
    for k, role in pairs(ROLE) do
      h[k] = function(msg, from, t) M.Sync.Handle(id, role, msg, from, t) end
    end
    local ok, why = M.Comm.Register({
      id = id, prefix = "GSync", audience = "guild", owner = "self",
      kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = RULE[id] } },
      unpack = unpackMsg, handle = h,
    })
    if not ok then return nil, id .. ": " .. tostring(why) end
    ok, why = M.Sync.Attach(id, newStore(id))
    if not ok then return nil, id .. ": " .. tostring(why) end
  end
  M.On("rosterRead", function()
    Store.Flush()
    Store.Leavers(ns.Core and ns.Core.Now() or nil)
  end)
  return true
end

-- ---------- readers ----------

local function read(id, key)
  local r = key and recs(id)
  local e = r and r[key]
  return type(e) == "table" and e.rec or nil
end

function Store.Target(guid) return read("kos", type(guid) == "string" and "t" .. guid or nil) end
function Store.Hunter(key) return read("kos_h", type(key) == "string" and "h" .. key or nil) end
function Store.Member(key) return read("kos_m", key) end

-- ---------- writes ----------

local function now() return ns.Core and ns.Core.Now() or 0 end

function Store.CanWriteOfficer()
  if not Store.Ready() then return false, "roster" end
  if M and (M.Demo()) then return false, "demo" end
  local c = comm()
  if not (c and c.IsOfficer(myKey())) then return false, "officer" end
  return true
end

-- rec trimmed to the kind's budget, then packed and parsed back (the caps and refusals a receiver applies).
-- A target's level is a number or "": "??", nil and "" cross the wire as an empty field and read back as "" (AC12).
local function settle(kind, key, rec, t)
  local R = Records()
  local trimmed = R.Trim(kind, rec, R.BUDGET[kind])
  if kind == "t" then trimmed.level = tonumber(trimmed.level) end
  local parsed, why = R.Parse(kind, key, R.Pack(kind, trimmed) or "", t)
  if parsed and kind == "t" then parsed.level = parsed.level or "" end
  return parsed, why
end

-- Open targets held (own and learned), the key being written aside.
local function openCount(r, except)
  local n = 0
  for k, e in pairs(r) do
    if k ~= except and type(e) == "table" and type(e.rec) == "table" and e.rec.status == "open" then n = n + 1 end
  end
  return n
end

-- Store.CanWrite(id, key, rec, t) -> parsed | nil, why: would an officer write of rec under key take? In order: args,
-- the guild table ("guild" while it is unread), settle, the kos status, the open cap with key aside. Answers the
-- record as a receiver would hold it. The officer gate is CanWriteOfficer's (writeOfficer and Confirm.Strike).
function Store.CanWrite(id, key, rec, t)
  if not KIND[id] or not key or type(rec) ~= "table" or type(t) ~= "number" then return nil, "args" end
  local r = recs(id)
  if not r then return nil, "guild" end
  local parsed, bad = settle(KIND[id], key, rec, t)
  if not parsed then return nil, bad end
  if id == "kos" then
    if not STATUS[parsed.status] then return nil, "status" end
    if parsed.status == "open" and openCount(r, key) >= OPEN_MAX then return nil, "open" end
  end
  return parsed
end

local function writeOfficer(id, key, rec, t)
  local can, why = Store.CanWriteOfficer()
  if not can then return nil, why end
  local parsed, bad = Store.CanWrite(id, key, rec, t)
  if not parsed then return nil, bad end
  local r, gone = recs(id), goneSet(id)
  -- a gone key comes back as a full record minted from its gone rev + 1 (d757 item 6)
  local e = r[key] or (gone and gone[key]) or {}
  r[key] = { rev = e.rev, hash = e.hash, by = myKey(), rec = parsed, at = t }
  if gone then gone[key] = nil end
  M.Sync.Changed(id, key, t)
  tidy(id, t)
  return true
end

function Store.WriteTarget(guid, rec, t)
  local key, why = ns.RulesRecords.TargetKey(guid)
  if not key then return nil, why end
  return writeOfficer("kos", key, rec, t)
end

function Store.WriteHunter(memberKey, rec, t)
  local key, why = ns.RulesRecords.HunterKey(memberKey)
  if not key then return nil, why end
  return writeOfficer("kos_h", key, rec, t)
end

local function poll()
  polling = false
  Store.Flush()
  if #held > 0 and M then
    polling = true
    M.After(5, poll)
  end
end

-- edit(rec) changes this character's own kos_m record. Before Ready() (no full key yet, or no guild) the edit is
-- held and applied under the full key once it holds (AC7a).
function Store.WriteOwn(edit, t)
  if type(edit) ~= "function" then return nil, "args" end
  if M and (M.Demo()) then return nil, "demo" end
  if not Store.Ready() then
    held[#held + 1] = { edit = edit, guild = ns.Core and ns.Core.GuildKey() or nil }
    if #held > HELD_MAX then table.remove(held, 1) end
    if not polling and M then
      polling = true
      M.After(5, poll)
    end
    return "held"
  end
  local key = myKey()
  local r = recs("kos_m")
  if not key or not r then return nil, "roster" end
  local e = r[key] or {}
  local rec = type(e.rec) == "table" and e.rec or {}
  local copy = { guid = rec.guid }
  for _, list in ipairs({ "marks", "claims", "witness", "sightings" }) do
    copy[list] = {}
    for i, x in ipairs(rec[list] or {}) do
      local c = {}
      for k, v in pairs(x) do c[k] = v end
      copy[list][i] = c
    end
  end
  edit(copy)
  local parsed, bad = settle("m", key, copy, t)
  if not parsed then return nil, bad end
  r[key] = { rev = e.rev, hash = e.hash, by = key, rec = parsed, at = t }
  M.Sync.Changed("kos_m", key, t)
  return true
end

-- Applies the held own edits once Ready() holds.
function Store.Flush()
  if #held == 0 or not Store.Ready() then return end
  if M and M.Demo() then return end -- held kept under the demo (WriteOwn refuses there); the poll re-arms (f8517)
  local list = held
  held = {}
  local t = now()
  local gk = ns.Core and ns.Core.GuildKey()
  -- an edit held under another guild is dropped (f5439); one held before any guild was read applies here
  for _, h in ipairs(list) do
    if h.guild == nil or h.guild == gk then Store.WriteOwn(h.edit, t) end
  end
end

-- A kos_m record whose key has been off the whole roster for LEFT_KEEP is dropped (f5220, q765), counted from the
-- last time this client saw the key on the roster (seen), or the record's local time when never seen. No gone entry.
-- Runs on each roster read and each round (the hub's timer), whichever comes first.
function Store.Leavers(t)
  if not Store.Ready() or type(t) ~= "number" then return end
  local r, c = recs("kos_m"), comm()
  local rows = c and c.Roster() or {}
  for k, e in pairs(r or {}) do
    if type(e) == "table" then
      if rows[k] ~= nil then
        e.seen = t
      elseif t - (tonumber(e.seen) or tonumber(e.at) or t) >= LEFT_KEEP then
        r[k] = nil
      end
    end
  end
end

-- One listener, called with the record key and record after every merged (not own) kos_h record (o865).
function Store.OnHunterMerged(fn)
  listener = type(fn) == "function" and fn or nil
end

-- One listener, called with the record key and record after every merged (not own) kos record (Task D: the marker's
-- cleanup, ns.Mark).
function Store.OnTargetMerged(fn)
  targetListener = type(fn) == "function" and fn or nil
end

-- One listener, called with the record key and record after every merged (not own) kos_m record (Task E: heard
-- sightings, ns.Spot).
function Store.OnMemberMerged(fn)
  memberListener = type(fn) == "function" and fn or nil
end
