-- GuildSyncGames CompanySync.lua (S13 Task 4, S14 Task 2): the Company rows on the "games_c" record domain on GSync,
-- the fourth and last domain of this module (games, games_g, games_v, games_c; CommRegistry MODULE_MAX_DOMAINS = 4).
-- S14: the put rule (PeopleStore.lua's store): only a key's own character sends its row, nobody relays it; 4 new revs
-- of one subject key in 600 s. A row is CC.PackRow's text (the body, then the officer's d item and hide entries,
-- CC.ParseRow against this week) and must pass ns.Limits.Company(..., "merge") by the receiver's clock. Records live in
-- ns.CompanyRecords() (db.guilds[guildKey].company, Store.lua) as { rev, hash, body }; msg.by is never read or stored.
-- Once ns.Now() >= GC.LAUNCH, records with a rev before it are dropped. The first full rosterRead with MyKey known
-- wipes every foreign record once per guild (ns.WipeForeignOnce, d1605: it wipes data).
-- Two readers, no shared fold (d1606), both over rows that pass the limits at the fold and are not hidden:
-- folded() groups by Person(key).main, newest row per group (gifts, donors, the look); ns.CompanyDrawRows(week) is
-- every stored record by its own key, plus the own account's tickets (company.tickets, under tickets.key / prevKey).
-- Officer authority (d1602): the officer of a section is the stored record's key; ns.CompanyHides and
-- ns.CompanyOfficerDraw scan every stored record whose key is an officer now (ns.IsOfficer at the read), plus the own
-- section when I am one, independent of the Person fold. ns.IsHidden(key) (memo one clock second): the key, the hidden
-- key's Person chars, or its saved set (Store.lua ns.HiddenChars, d1607) while its hide entry stands.
-- members (d1608): the largest full-read roster count this session, nil before one (ns.CompanyMembers).
-- Heard officers (d1609): the senders of any games_c H, D, R or P this session that are officers now.
-- Mints (d1585): ns.CompanyChanged() sets dirty; ns.CompanyTick(t) mints a dirty row at most once per 300 s, except
-- that the first tick at or after closeAt - 300 s mints it at once (once a week). The first tick with a key compares
-- the stored own row with the packed own row and sets dirty when they differ (the login mint). Never in demo.
-- ns.CompanyRaw = { projects, draw } holds the local functions before Demo.lua wraps the ns names (d1588); draw(week)
-- is the provisional view over the draw rows with a fixed salt (total and pot); the real draw is the officer's.

local _, ns = ...

if not ns.M then return end
local M, GC, K, CC, L = ns.M, ns.GrainCore, ns.SyncKit, ns.CompanyCore, ns.Limits

local DOMAIN = "games_c"
local MINT_EVERY = 300     -- a dirty row mints at most this often (s)
local CLOSE_LEAD = 300     -- ... except at the first tick this long before sales close (once a week)
local LIMIT_REVS = 4       -- new revs of one subject key ...
local LIMIT_WINDOW = 600   -- ... per this many seconds
local LIMIT_SUBJECTS = 2100 -- buckets the limit tracks at most (a memory bound: a full guild and its own buckets)
local SAVED_MAX = 16       -- characters a saved hidden-alt set holds (d1607)
local VIEW_SALT = 1        -- the provisional draw's salt (display only, never paid)

local members              -- the largest full-read roster count this session (d1608)
local lastReadFull = false -- the last rosterRead was full and known
local heard = {}           -- senders of a games_c message this session (d1609)
local hideAt, hideMemo     -- ns.IsHidden's resolve, one clock second
local lookAt, lookMemo     -- CompanyLook's fold, one clock second

local function forget() hideMemo, lookMemo = nil, nil end

-- GC.LAUNCH once the real clock is past it; nil before (the beta keeps its records) and without a clock.
local function cutoff()
  local t = ns.Now()
  if type(t) == "number" and t >= GC.LAUNCH then return GC.LAUNCH end
  return nil
end

local function offset()
  if ns.RealmOffset then return (ns.RealmOffset()) or 0 end
  return 0
end

-- The lottery week now, or nil without a clock.
local function weekNow()
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  return (CC.Week(t, offset()))
end

-- The records, with the preview-era ones (rev before GC.LAUNCH, after launch) dropped.
local function records()
  local recs, cut = ns.CompanyRecords(), cutoff()
  if cut then
    for k, r in pairs(recs) do
      if type(r) == "table" and type(r.rev) == "number" and r.rev < cut then recs[k] = nil end
    end
  end
  return recs
end

local function officerNow(key)
  return key ~= nil and ns.IsOfficer ~= nil and ns.IsOfficer(key) == true
end

-- The own officer section (CompanyStore.lua, T3), read at call time; nil for a member.
local function ownOfficer()
  local off = ns.CompanyOfficer and ns.CompanyOfficer()
  return type(off) == "table" and off or nil
end

-- The own row, read at call time (ns.CompanyBody and ns.CompanyOfficer, CompanyStore.lua).
local function ownBody()
  local b = ns.CompanyBody and ns.CompanyBody()
  return b and CC.PackRow(b, ownOfficer()) or nil
end

-- The own body alone, parsed against week w (never the packed row: its items are the officer's).
local function ownPlain(w)
  local b = ns.CompanyBody and ns.CompanyBody()
  return b and CC.ParseBody(CC.PackBody(b), w) or nil
end

local function isOwn(key)
  return key ~= nil and key == ns.MyKey() and ns.CompanyBody ~= nil and ns.CompanyBody() ~= nil
end

-- A stored record's row parsed against week w: b, off; nil when it does not parse.
local function parseRec(r, w)
  if type(r) ~= "table" or type(r.rev) ~= "number" or type(r.body) ~= "string" then return nil end
  return CC.ParseRow(r.body, w)
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
-- The hub's mint (own key) or a stored rev: the own record keeps the row its hash was made from.
function store.stamp(key, rev, hash)
  local recs = ns.CompanyRecords()
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
-- Refused (false, nothing kept): MyKey's row, a hash that is not the row's, no clock, a preview-era rev after launch,
-- a row CC.ParseRow refuses against this week, or one outside ns.Limits.Company(..., "merge").
function store.merge(msg)
  if msg.key == ns.MyKey() or type(msg.body) ~= "string" or msg.hash ~= K.adler(msg.body) then return false end
  local t, w, cut = ns.Now(), weekNow(), cutoff()
  if not w or (cut and msg.rev < cut) then return false end
  local b, off = CC.ParseRow(msg.body, w)
  if not b or not L.Company(b, t, off, members, "merge") then return false end
  ns.CompanyRecords()[msg.key] = { rev = msg.rev, hash = msg.hash, body = msg.body }
  forget()
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

-- Every H, D, R and P marks its sender heard this session (d1609), before the engine sees it.
local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }
local handle = {}
for kind, role in pairs(ROLE) do
  handle[kind] = function(msg, from, t)
    if type(from) == "string" then heard[from] = true end
    M.Sync.Handle(DOMAIN, role, msg, from, t)
  end
end

if M.Comm.Register({
  id = DOMAIN, prefix = "GSync", audience = "guild", owner = "self",
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "put" } },
  unpack = K.unpack, handle = handle, limit = limiter.limit,
}) then
  M.Sync.Attach(DOMAIN, store)
end

-- At each rosterRead: preview-era records go; a full, known read raises members, runs the one-time wipe and drops the
-- records whose key is off the roster.
M.On("rosterRead", function(partial)
  forget()
  local recs = records()
  local rows, isPartial, _, known = ns.Roster()
  limiter.setKnown(known)
  lastReadFull = not partial and known and not isPartial and type(rows) == "table" or false
  if not lastReadFull then return end
  local n = 0
  for _ in pairs(rows) do n = n + 1 end
  if not members or n > members then members = n end
  ns.WipeForeignOnce(DOMAIN, recs)
  for key, r in pairs(recs) do
    if not rows[key] and type(r) == "table" and type(r.rev) == "number" then recs[key] = nil end
  end
end)

function ns.CompanyMembers() return members end

-- ---------- officer sections, hides ----------

-- { { by = record key, hides, draw } } for every stored record whose key is an officer now, plus the own section when
-- I am one. A section counts when its body passes the fold limits; its d item only when the whole row does (L13).
local function sections(w, t)
  local list, me = {}, ns.MyKey()
  for key, r in pairs(records()) do
    if key ~= me and officerNow(key) then
      local b, off = parseRec(r, w)
      if b and off and L.Company(b, t, nil, members, "fold") then
        local d = off.draw and L.Company(b, t, off, members, "fold") and off.draw or nil
        list[#list + 1] = { by = key, hides = off.hides, draw = d }
      end
    end
  end
  local own = me and officerNow(me) and ownOfficer()
  if own then
    local b = ownPlain(w)
    local d = own.draw and b and L.Company(b, t, own, members, "fold") and own.draw or nil
    list[#list + 1] = { by = me, hides = own.hides or {}, draw = d }
  end
  return list
end

-- The resolved hides and the officer sections they came from (none without a clock).
local function resolvedHides()
  local t, w = ns.Now(), weekNow()
  if type(t) ~= "number" or not w then return {}, {} end
  local list = sections(w, t)
  return CC.ResolveHides(list, t), list
end

-- { [char key] = true } for the characters Person(key) links now.
local function charsOf(key)
  local out = {}
  local p = ns.Person and ns.Person(key)
  for _, c in ipairs(type(p) == "table" and type(p.chars) == "table" and p.chars or {}) do
    if type(c) == "table" and type(c.key) == "string" then out[c.key] = true end
  end
  return out
end

-- Adds the characters linked now to a saved set (a union); past SAVED_MAX the oldest saved ones not linked now go.
-- set.by is the record key of the officer whose standing entry it grew from (f7533).
local function grow(saved, hk, at, by)
  local set = saved[hk]
  if type(set) ~= "table" or type(set.chars) ~= "table" then set = { at = at, chars = {} } end
  if at > (set.at or 0) then set.at = at end
  set.by = by
  local now, have = charsOf(hk), {}
  for _, k in ipairs(set.chars) do have[k] = true end
  for k in pairs(now) do
    if not have[k] then set.chars[#set.chars + 1] = k end
  end
  local i = 1
  while #set.chars > SAVED_MAX and i <= #set.chars do
    if now[set.chars[i]] then i = i + 1 else table.remove(set.chars, i) end
  end
  saved[hk] = set
  return set
end

-- true when the holder's own evidence says it no longer carries hk (f7533): its record is gone, or it parses and has
-- no entry for hk. Never because the holder is not an officer now; no holder or an unreadable row says nothing.
local function dropped(holder, hk, w)
  if type(holder) ~= "string" or not w then return false end
  if holder == ns.MyKey() then
    local own = ownOfficer()
    return own ~= nil and type(own.hides) == "table" and own.hides[hk] == nil
  end
  local r = records()[holder]
  if r == nil then return true end
  local b, off = parseRec(r, w)
  if not b then return false end
  return not (off and off.hides and off.hides[hk])
end

-- One resolve a clock second: { [key] = by } for every hidden key, its Person chars and its saved set.
local function hidden()
  local t = ns.Now()
  if hideMemo and t == hideAt then return hideMemo end
  local resolved, list = resolvedHides()
  local set, saved = {}, ns.HiddenChars()
  for hk, h in pairs(resolved) do
    if h.on then
      set[hk] = h.by
      for _, k in ipairs(grow(saved, hk, h.at, h.by).chars) do set[k] = set[k] or h.by end
    else
      saved[hk] = nil -- an unhide from a standing officer entry
    end
  end
  -- A full, known read (d1607, f7522, f7533): a set with no standing entry goes only on its holder's own evidence.
  if type(t) == "number" and lastReadFull then
    local w = weekNow()
    for hk, sv in pairs(saved) do
      if not resolved[hk] and dropped(type(sv) == "table" and sv.by or nil, hk, w) then saved[hk] = nil end
    end
  end
  hideAt, hideMemo = t, set
  return set
end

function ns.IsHidden(key)
  return key ~= nil and hidden()[key] ~= nil
end

function ns.CompanyHides() return (resolvedHides()) end

-- The resolved officer draw for week (nil: the newest week any officer drew); d.by is the record key.
function ns.CompanyOfficerDraw(week)
  local t, w = ns.Now(), weekNow()
  if type(t) ~= "number" or not w then return nil end
  local list = {}
  for _, s in ipairs(sections(w, t)) do
    if s.draw then list[#list + 1] = { by = s.by, draw = s.draw } end
  end
  if week == nil then
    for _, e in ipairs(list) do if not week or e.draw.week > week then week = e.draw.week end end
  end
  local pick = {}
  for _, e in ipairs(list) do if e.draw.week == week then pick[#pick + 1] = e end end
  local best = CC.ResolveDraw(pick)
  if not best then return nil end
  local d = {}
  for k, v in pairs(best) do d[k] = v end
  for _, e in ipairs(pick) do if e.draw == best then d.by = e.by end end
  return d
end

-- Senders heard this session that are officers now, by key.
function ns.CompanyHeardOfficers()
  local out = {}
  for k in pairs(heard) do if officerNow(k) then out[#out + 1] = k end end
  table.sort(out)
  return out
end

local function nameOf(key)
  local m = ns.Member(key)
  return m and m.name or key, m and m.class
end

-- Every roster player: { key, name, class, hidden, byName, byKey } (read only), by name; byKey is the record key of
-- the officer whose entry stands (f7526).
function ns.GamesPlayers()
  local rows = ns.Roster()
  local set, out = hidden(), {}
  for key, m in pairs(type(rows) == "table" and rows or {}) do
    local by = set[key]
    out[#out + 1] = { key = key, name = m.name or key, class = m.class, hidden = by ~= nil,
      byName = by and (nameOf(by)) or nil, byKey = by }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- ---------- the two readers ----------

local dirty, mintedAt, forcedWeek, loginChecked = false, nil, nil, false

-- Gifts, donors and the look: one row per Person(key).main, the newest record's; rows pass the fold limits and are not
-- hidden. The own row (rev math.huge) is the own body.
local function folded()
  local t, w, me = ns.Now(), weekNow(), ns.MyKey()
  if not w then return {} end
  local by = {}
  local function add(key, rev, hash, b)
    if ns.IsHidden(key) then return end
    local p = ns.Person and ns.Person(key)
    local g = type(p) == "table" and p.main or key
    local cur = by[g]
    if not cur or K.newer(rev, hash, cur.rev, cur.hash) then by[g] = { key = key, rev = rev, hash = hash, b = b } end
  end
  for key, r in pairs(records()) do
    if key ~= me then
      local b = parseRec(r, w)
      if b and L.Company(b, t, nil, members, "fold") then add(key, r.rev, r.hash, b) end
    end
  end
  local ob = me and ownPlain(w)
  if ob then add(me, math.huge, "", ob) end
  local rows = {}
  for g, x in pairs(by) do rows[#rows + 1] = { key = x.key, group = g, b = x.b, you = x.key == me } end
  table.sort(rows, function(x, y) return x.group < y.group end)
  return rows
end

-- The draw rows for week: every stored record by its own key (fold limits, not hidden), the own account's records
-- under me, tickets.key and prevKey skipped, then the own account's tickets once (company.tickets).
local function drawRows(week)
  local t, w, me = ns.Now(), weekNow(), ns.MyKey()
  if not w then return {} end
  local st = ns.CompanyState and ns.CompanyState()
  local tk = type(st) == "table" and type(st.tickets) == "table" and st.tickets or nil
  local skip = {}
  if me then skip[me] = true end
  if tk then
    if tk.key then skip[tk.key] = true end
    if tk.prevKey then skip[tk.prevKey] = true end
  end
  local rows = {}
  for key, r in pairs(records()) do
    if not skip[key] then
      local b = parseRec(r, w)
      if b and L.Company(b, t, nil, members, "fold") and not ns.IsHidden(key) then rows[#rows + 1] = { key = key, b = b } end
    end
  end
  local own, n
  if tk then
    if tk.week == week and (tk.count or 0) > 0 then own, n = tk.key or me, tk.count
    elseif tk.prevWeek == week and (tk.prevCount or 0) > 0 then own, n = tk.prevKey or tk.key or me, tk.prevCount end
  else
    local b = ownPlain(w)
    if b and b.week == week and b.count > 0 then own, n = me, b.count
    elseif b and b.prevWeek == week and b.prevCount > 0 then own, n = me, b.prevCount end
  end
  if own and not ns.IsHidden(own) then
    rows[#rows + 1] = { key = own, b = { week = week, count = n, prevWeek = 0, prevCount = 0,
      gifts = { 0, 0, 0, 0, 0, 0 } } }
  end
  table.sort(rows, function(x, y) return x.key < y.key end)
  return rows
end
ns.CompanyDrawRows = drawRows

local function projects()
  local totals = CC.Totals(folded())
  local p = CC.Projects(totals)
  p.totals = totals
  return p
end

-- The provisional view (VIEW_SALT): who the draw rows would name; the paid draw is ns.CompanyOfficerDraw.
local function draw(week)
  local d = CC.Draw(week, drawRows(week), VIEW_SALT)
  if not d then return nil end
  d.name = (nameOf(d.key))
  return d
end

ns.CompanyProjects = projects
ns.CompanyDraw = draw
ns.CompanyRaw = { projects = projects, draw = draw }

-- Donors to project k: { { key, name, class, given, you } }, most given first.
function ns.CompanyDonors(k)
  local out = {}
  for _, r in ipairs(folded()) do
    local given = r.b.gifts[k] or 0
    if given > 0 then
      local name, class = nameOf(r.key)
      out[#out + 1] = { key = r.key, name = name, class = class, given = given, you = r.you }
    end
  end
  table.sort(out, function(a, b)
    if a.given ~= b.given then return a.given > b.given end
    return a.name < b.name
  end)
  return out
end

-- projects().done for CompanyLook, folded once per clock second, not once per drawn row (review f10, security f2).
local doneAt, doneMemo
local function doneNow()
  local t = ns.Now()
  if doneMemo == nil or t ~= doneAt then doneAt, doneMemo = t, projects().done end
  return doneMemo
end

-- The fold by group, once per clock second (and after a merge or a rosterRead).
local function groupsNow()
  local t = ns.Now()
  if lookMemo and t == lookAt then return lookMemo end
  local m = {}
  for _, r in ipairs(folded()) do m[r.group] = r.b end
  lookAt, lookMemo = t, m
  return m
end

-- The look a key's row wears: its group's newest row (Person main); title text, colour hex and badge icon from CC by
-- id; a project badge only when that row gave to the project and the project is complete here. nil without a row.
function ns.CompanyLook(key)
  local w = weekNow()
  if not w or key == nil then return nil end
  local p = ns.Person and ns.Person(key)
  local b = groupsNow()[type(p) == "table" and p.main or key]
  if not b then return nil end
  local look = {}
  if b.title > 0 then look.title = CC.Item(CC.WIRE_BASE.title + b.title).name end
  if b.colour > 0 then look.hex = CC.COLOURS[b.colour].hex end
  if b.badge > 4 then
    local k = b.badge - 4
    if b.gifts[k] > 0 and doneNow()[k] == true then look.badge = CC.PROJECTS[k].badge end
  elseif b.badge > 0 then
    look.badge = CC.Item(CC.WIRE_BASE.badge + b.badge).icon
  end
  return look
end

-- ---------- minting ----------

local function mint(t)
  local key = ns.MyKey()
  if type(t) ~= "number" or not key or M.Demo() or not ownBody() then return end
  dirty, mintedAt = false, t
  M.Sync.Changed(DOMAIN, key, t)
end

-- CompanyStore.lua calls this after a buy, a wear, a gift or a ticket: the next tick mints.
function ns.CompanyChanged()
  dirty = true
  lookMemo = nil
end

-- Grain.lua's tick: the login check once, the mint drain, then the settle.
function ns.CompanyTick(t)
  if type(t) ~= "number" or M.Demo() then return end
  local me = ns.MyKey()
  if me and not loginChecked then
    loginChecked = true
    local own, r = ownBody(), records()[me]
    if own and not (type(r) == "table" and r.body == own) then dirty = true end
  end
  if dirty then
    local w, closeAt = CC.Week(t, offset())
    if not mintedAt or t - mintedAt >= MINT_EVERY then
      mint(t)
    elseif t >= closeAt - CLOSE_LEAD and forcedWeek ~= w then
      forcedWeek = w
      mint(t)
    end
  end
  if ns.CompanySettle then ns.CompanySettle(t) end
end
