local _, ns = ...
if not ns.M then return end

-- The "raids" domain (officer rule) over the SavedVariable: the store the engine syncs, its logical codec, the
-- officer's share, the view, the selftest and the status line. Records live in ns.DB().records, read at every call
-- (the SavedVariable is set only after the files ran). Every function that gets t or reads the time prunes expired
-- records into gone[key] = { at, rev } first (plan "Expiry, gone, compare").
-- Attach copies the store at the call (CommSync.lua:577-591): everything is defined above, and the file ends with the
-- domain's registration and the attach.

local M, Codec, Rules = ns.M, ns.Codec, ns.Rules
local ID, SEP = "raids", "~"
local DAY, GONE_DAYS, BY_MAX, RECV_MAX = 86400, 16, 60, 3000

local okRegister, whyRegister, okAttach, whyAttach

local function now() return M.Compat.call("GetServerTime") or 0 end

local function db()
  local d = ns.DB()
  d.records = d.records or {}
  d.gone = d.gone or {}
  return d
end

local adler, clean = ns.Adler, Codec.Clean

-- Expired records go to gone with their rev; gone entries are kept GONE_DAYS.
local function prune(t)
  local d = db()
  for key, r in pairs(d.records) do
    if type(r.body) == "string" and Codec.Expired(r.body, t) then
      d.records[key] = nil
      d.gone[key] = { at = t, rev = tonumber(r.rev) or 0 }
    end
  end
  for key, g in pairs(d.gone) do
    if (tonumber(g.at) or 0) <= t - GONE_DAYS * DAY then d.gone[key] = nil end
  end
  return d
end

-- ---------- logical codec (Hello.lua's packMsg/unpackMsg with the key checks) ----------

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
    if not rev or not Codec.ValidKey(f[2]) then return nil end
    return { t = "P", key = f[2], rev = rev, hash = f[4], by = f[5], body = f[6] or "" }
  end
  if t == "H" then return { t = "H", hash = f[2] or "" } end
  if t == "D" or t == "R" then
    local entries = {}
    for e in ((f[2] or "") .. ";"):gmatch("([^;]*);") do
      local k, r, h = e:match("^([^,]*),([^,]*),(.*)$")
      if k and Codec.ValidKey(k) then entries[#entries + 1] = { key = k, rev = tonumber(r) or 0, hash = h } end
    end
    return { t = t, entries = entries }
  end
  return nil
end

-- ---------- the store (CommSync.lua:7-10) ----------

local refreshing = false
local function refreshSoon()
  if refreshing then return end
  refreshing = true
  M.After(1, function()
    refreshing = false
    M.RefreshPage()
  end)
end

local store = { recordRule = "officer", kinds = { round = "H", digest = "D", ask = "R", record = "P" }, maxRecords = 100,
  maxEntries = 2 * Rules.MAX_SHARE } -- f1493: a larger digest or ask is refused whole

local function listKeys(t)
  local d = prune(t)
  local list = {}
  for k, r in pairs(d.records) do if r.rev then list[#list + 1] = k end end
  table.sort(list)
  return list, d
end

function store.get(key) return db().records[key] end
function store.keys() return (listKeys(now())) end
function store.content(key)
  local r = db().records[key]
  return r and ((r.by or "") .. SEP .. (r.body or "")) or nil
end
function store.stamp(key, rev, hash)
  local d = db()
  local r = d.records[key] or {}
  d.records[key] = r
  r.rev, r.hash = rev, hash
end
-- Never own: an officer's copy of another officer's newer record must not be re-minted (plan Findings).
function store.isOwn() return false end
function store.heardOwn() end
function store.build(key, t)
  local r = prune(t).records[key]
  if not r or not r.rev then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, by = r.by, body = r.body }
end

-- A refused body (too big, undecodable) or an expired one is not stored: its key goes to gone with its rev, so a
-- digest offering that rev is not asked again. A live record clears its gone entry. A rev at or below the gone rev is
-- dropped (f1492); a gen or at above t + FUTURE counts as refused (f1491).
function store.merge(msg, t)
  local d = prune(t)
  local g = d.gone[msg.key]
  if g and (tonumber(msg.rev) or 0) <= (tonumber(g.rev) or 0) then return true end
  local body = msg.body
  local rec = type(body) == "string" and #body <= RECV_MAX and Codec.Decode(body)
  if not rec or Codec.Expired(body, t) or rec.gen > t + Rules.FUTURE or (rec.at or 0) > t + Rules.FUTURE then
    d.records[msg.key] = nil
    d.gone[msg.key] = { at = t, rev = msg.rev }
  else
    d.records[msg.key] = { rev = msg.rev, hash = msg.hash, by = clean(msg.by, BY_MAX), body = body }
    d.gone[msg.key] = nil
  end
  refreshSoon()
  return true
end

function store.round(t)
  local list, d = listKeys(t)
  local parts = {}
  for _, k in ipairs(list) do parts[#parts + 1] = k .. "=" .. d.records[k].rev .. "=" .. (d.records[k].hash or "") end
  return { t = "H", hash = adler(table.concat(parts, "/")) }
end
function store.digest(t)
  local list, d = listKeys(t)
  local entries = {}
  for _, k in ipairs(list) do entries[#entries + 1] = { key = k, rev = d.records[k].rev, hash = d.records[k].hash } end
  return { t = "D", entries = entries }
end
function store.compare(msg, t)
  local d = prune(t)
  return Rules.Compare(d.records, d.gone, msg.entries, t)
end
function store.stillWanted(w, t)
  local r = prune(t).records[w.subject]
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
ns.store = store -- the table attached below (test seam)

local handle = {}
for kind, role in pairs({ H = "round", D = "digest", R = "ask", P = "record" }) do
  handle[kind] = function(msg, from, t) M.Sync.Handle(ID, role, msg, from, t) end
end

-- ---------- share, view, selftest, status ----------

-- An officer's paste: Rules.Plan, then by and body updated in the held record table (so the mint sees the held rev,
-- f1455) and one Changed per put key.
function ns.Share(cal)
  local me = ns.MyKey()
  if not me or not ns.IsOfficer(me) then return nil, "officer" end
  if ns.DemoData and ns.DemoData() then return nil, "demo: nothing is shared" end
  local t = now()
  local d = db()
  local plan, why, info = Rules.Plan(cal, d.records, t, me)
  if not plan then return nil, why, info end
  for key, body in pairs(plan.put) do
    local r = d.records[key]
    if not r then
      r = {}
      d.records[key] = r
    end
    r.by, r.body = me, body
    d.gone[key] = nil
    M.Sync.Changed(ID, key, t)
  end
  refreshSoon()
  return true, plan.readback
end

-- In demo the view is the made-up calendar (ns.DemoData, Tools.lua); the store is neither read nor written.
function ns.View()
  local d = ns.DemoData and ns.DemoData()
  return Rules.View(d and d.records or db().records, now(), ns.Key)
end

function ns.Selftest()
  return Rules.SelfCheck({ attached = okAttach, why = whyRegister or whyAttach, known = select(4, ns.Roster()),
    view = ns.View(), now = now() })
end

-- "12 raids (1 incomplete), 3 teams, data 40 min old by Kara Vell" or "no raid data yet".
function ns.Status()
  local view = ns.View()
  if not view.held then return "no raid data yet" end
  local n, teams = #view.events, 0
  for _ in pairs(view.teams) do teams = teams + 1 end
  local row = ns.Member(view.held.by)
  local who = (row and row.name) or tostring(view.held.by or "?")
  return n .. (n == 1 and " raid" or " raids")
    .. (view.incomplete > 0 and (" (" .. view.incomplete .. " incomplete)") or "")
    .. ", " .. teams .. (teams == 1 and " team" or " teams")
    .. ", " .. (Rules.Age(view.held, now())) .. " by " .. who
end

function ns.Login() prune(now()) end

-- ---------- the domain: register, then attach, last ----------

okRegister, whyRegister = M.Comm.Register({
  id = ID, prefix = "GSync", audience = "guild", owner = "officer", maxChunks = 16,
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "officer" } },
  unpack = unpackMsg, handle = handle,
})
if okRegister then okAttach, whyAttach = M.Sync.Attach(ID, store) end
