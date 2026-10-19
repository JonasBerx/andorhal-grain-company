-- GuildSyncBank stores and sync (t42 plan sections 2, 4 and 5). The only file that reaches M.Comm and M.Sync.
-- Saved: ns.DB().records[domain][key] = { rev, hash, by, at, text, body, heard? }: text is the canonical encoded body
-- (ns.Codec), body its cleaned table, rev and hash come from the hub's stamp (Put never bumps a rev).
--   ns.Store.All() -> records                  the live table, read only by convention
--   ns.Store.IsOwn(key) -> bool                the key's author part == GuildSync.Comm.MyKey(); never roster-gated (f5328)
--   ns.Store.Put(key, body, now) -> true | nil, why   own keys only; "roster" while MyKey has no row; Clean on every
--                                              write; a real change is saved and published; an emptied body is kept
--   ns.Store.Mine() -> { [ownKey] = copy of body }   b1, l1, t1 and a1 hold their whole family (d772)
--   ns.Store.Fit(family, author, body) -> { body1, ... } | nil, "full"
--   ns.Store.SaveMine(own, now) -> changedKeys | nil, "full" | "tfull" | "held" | "fullroster" | "catchup"
--   ns.Store.FreeSlot(view, now) -> n | nil    an empty own q slot, else the lowest closed long enough ago
--   ns.Sync.Publish(key, now) ; Attached() ; Heard(memberKey) ; RoundHash(domain) ; Stashed(family) ;
--   CatchingUp(domain) ; WaitingRoster(now) ; UnheldScan(family) ; Adopt(now) ; Fresh()
-- Four domains (plan section 2): bank, bank_q and bank_a on GSync (P rule officer), bank_m on GSyncB (bulk, copy).
-- ns.DB() is read inside each call, never at load.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Store = {}
ns.Store = Store
local Sync = {}
ns.Sync = Sync

local KINDS = { round = "H", digest = "D", ask = "R", record = "P" }
local DOMAINS = { "bank", "bank_q", "bank_a", "bank_m" }
local OFFICER = { bank = true, bank_q = true, bank_a = true } -- P rule officer; bank_m is copy
local MERGED = { b = true, l = true, t = true, a = true }       -- families Mine() joins into n = 1 (d772)
-- families only a bank character writes (d777, AC5); x (any officer) and m (any member) are not among them
local BANK_FAMILY = { b = true, k = true, g = true, t = true, q = true, l = true, a = true }
local LISTS = { "receipts", "unpledges", "unsends" }
local REFUSED_MAX = 500
local REFRESH_DELAY = 0.5

-- ---------- helpers ----------

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Bytewise string order (the client's `<` on strings may follow the locale); numbers before strings for map keys.
local byteLess, order = ns.Codec.ByteLess, ns.Codec.Order

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

local function serverNow() return M.Compat and M.Compat.call("GetServerTime") end
local function demo() return M.Demo() and true or false end
local function myKey() return GuildSync.Comm.MyKey() end

-- This character's key and roster row, or nil while the roster has no row for MyKey (R3).
local function me()
  local Comm = GuildSync.Comm
  local key = Comm.MyKey()
  local row = key and Comm.Member(key)
  if not row then return nil end
  return key, row
end

-- The roster is read and whole (f5348).
local function whole()
  local _, partial, _, known = GuildSync.Comm.Roster()
  return known and not partial and true or false
end

local function ranksReady() return ns.Ranks ~= nil and ns.Ranks.State() == "ready" end

local function domainRecords(domain)
  local records = ns.DB().records
  if type(records[domain]) ~= "table" then records[domain] = {} end
  return records[domain]
end

-- One page refresh per REFRESH_DELAY however many writes land (f5302).
local refreshDue = false
local function refresh()
  if not M.After then return M.RefreshPage() end
  if refreshDue then return end
  refreshDue = true
  M.After(REFRESH_DELAY, function()
    refreshDue = false
    M.RefreshPage()
  end)
end

-- ---------- session state (never saved) ----------

local refused, refusedN, refusedSeq = {}, 0, 0 -- key -> { rev, hash, seq } (d785)
local pendingHeard                             -- { key, rev, hash, text } while M.Sync.Handle runs (d783)
local peersSeen = {}                           -- from -> last time heard on any Bank domain (d784 window size)
local attached = {}                            -- domain -> true | why
local stores = {}                              -- domain -> the store handed to M.Sync.Attach
local unheld = {}                              -- family -> { [key] = true } (d784, f5336)
-- d784, all session-only
local GUARDED = { l = true, t = true, a = true, q = true }
local FUTURE = 300           -- seconds a rev may lie ahead of now (the hub's Wire.FUTURE, CommWire.lua:16)
local PEER_WINDOW = 900      -- the hub's PEER_WINDOW (CommSync.lua:32)
local LONG_WINDOW = 900 + 300 -- the stores' hEvery + hJitter: the first window after a partial first read (f5329)
local startedEmpty           -- family -> true: no own record of it in the saved file (f5324); nil until computed
local stash = {}             -- family -> { [key] = { rev, hash, by, text, senders = { [fromKey] = true }, conflict } }
local listed = {}            -- family -> { [key] = true }: own keys an officer D listed
local dropped = {}           -- family -> { [key] = true }: adopt dropped it (guard d)
local windowEnd = {}         -- officer domain -> time the catch-up window ends
local longWindow = {}        -- officer domain -> true while the window is the first long one (partial start)
local lifted = {}            -- officer domain -> true once an officer D or an equal-hash officer H was heard
local firstPartial           -- the Bank's first rosterRead of the session was partial
local fullSeen = false       -- the first full roster read of the session happened (guard b holds until then, f5285)
local firstPartialAt         -- server time of the partial first read; nil until a number is known (f5314)
local wrote = {}             -- family -> true once a SaveMine changed an own key of it this session (f5318, f5349)

-- A refused (rev, hash) for key: skipped by compare for the session, at most REFUSED_MAX keys, oldest out.
local function refuse(key, rev, hash)
  if type(key) ~= "string" or #key > 64 then return false end -- such a key is never valid, so never asked
  if not refused[key] then refusedN = refusedN + 1 end
  refusedSeq = refusedSeq + 1
  -- only an 8-hex hash is kept; any other value is stored as false, which a D entry never matches (f5309)
  local h = type(hash) == "string" and #hash == 8 and not hash:find("[^%x]") and hash or false
  refused[key] = { rev = rev, hash = h, seq = refusedSeq }
  if refusedN > REFUSED_MAX then
    local oldest
    for k, r in pairs(refused) do
      if not oldest or r.seq < refused[oldest].seq then oldest = k end
    end
    refused[oldest], refusedN = nil, refusedN - 1
  end
  return false
end

local function isRefused(key, rev, hash)
  local r = refused[key]
  return r ~= nil and r.rev == rev and r.hash == hash
end

-- ---------- local stores ----------

function Store.All() return ns.DB().records end

function Store.IsOwn(key)
  if type(key) ~= "string" then return false end
  local mine = myKey()
  if not mine then return false end
  local family, _, author = ns.ParseKey(key)
  return (family and ns.DOMAIN[family] and author == mine) and true or false
end

function Store.Put(key, body, now)
  local mine, row = me()
  if not mine then return nil, "roster" end
  if not Store.IsOwn(key) then return nil, "notown" end
  if type(body) ~= "table" then return nil, "body" end
  local family = ns.ParseKey(key)
  local view, why = ns.Codec.Clean(family, body, now)
  if not view then return nil, why end
  local text = ns.Codec.Encode(view)
  local list = domainRecords(ns.DOMAIN[family])
  local old = list[key]
  if old and old.text == text then return true end
  list[key] = { rev = old and old.rev, hash = old and old.hash, at = now, text = text, body = view,
    by = type(row.name) == "string" and row.name or mine }
  M.RefreshPage() -- an own write redraws at once; merges coalesce (f5302)
  Sync.Publish(key, now)
  return true
end

-- Adds body (one record of family) into the joined body `into`.
local function join(family, into, body)
  if type(body) ~= "table" then return end
  if family == "b" then
    for k, v in pairs(body) do
      if k == "items" and type(v) == "table" then
        into.items = into.items or {}
        for id, n in pairs(v) do if into.items[id] == nil then into.items[id] = n end end
      elseif into[k] == nil then
        into[k] = copy(v)
      end
    end
  elseif family == "t" then
    for member, e in pairs(body) do if into[member] == nil then into[member] = copy(e) end end
  elseif family == "l" then
    for name, list in pairs(body) do
      if type(list) == "table" then
        into[name] = into[name] or {}
        for _, e in ipairs(list) do into[name][#into[name] + 1] = copy(e) end
      end
    end
  else
    for _, e in ipairs(body) do into[#into + 1] = copy(e) end
  end
end

function Store.Mine()
  local own, groups = {}, {}
  local mine = me()
  if not mine then return own end
  for _, byKey in pairs(ns.DB().records) do
    for key, rec in pairs(byKey) do
      if Store.IsOwn(key) then
        local family, n = ns.ParseKey(key)
        if MERGED[family] then
          groups[family] = groups[family] or {}
          if n then groups[family][n] = rec.body end
        else
          own[key] = copy(rec.body)
        end
      end
    end
  end
  for family, byN in pairs(groups) do
    local into = {}
    for n = 1, ns.CAPS[family] do join(family, into, byN[n]) end
    own[ns.Key(family, 1, mine)] = into
  end
  return own
end

-- The units of a merged family's body in Fit's total order (d772): items by id, totals by member, list entries by
-- at then encoded text.
local function units(family, body, skeleton)
  local list = {}
  if family == "b" then
    for k, v in pairs(body) do if k ~= "items" then skeleton[k] = copy(v) end end
    for id, n in pairs(type(body.items) == "table" and body.items or {}) do list[#list + 1] = { k = id, v = n } end
    table.sort(list, function(x, y) return order(x.k, y.k) end)
  elseif family == "t" then
    for member, e in pairs(body) do list[#list + 1] = { k = member, v = e } end
    table.sort(list, function(x, y) return order(x.k, y.k) end)
  else
    local names = family == "l" and LISTS or { false }
    for _, name in ipairs(names) do
      local src = name and body[name] or (not name and body)
      if type(src) == "table" then
        if name then skeleton[name] = {} end
        local part = {}
        for _, e in ipairs(src) do
          part[#part + 1] = { into = name, v = e, at = type(e) == "table" and tonumber(e.at) or 0,
            text = ns.Codec.Encode(type(e) == "table" and e or {}) or "" }
        end
        table.sort(part, function(x, y)
          if x.at ~= y.at then return x.at < y.at end
          return byteLess(x.text, y.text)
        end)
        for _, u in ipairs(part) do list[#list + 1] = u end
      end
    end
  end
  return list
end

-- Splits an own family body into the records <f>1..<f>n so each packed P fits its domain (d772). Families that are
-- not merged give one record or "full".
function Store.Fit(family, author, body)
  local domain = family and ns.DOMAIN[family]
  local fit = domain and ns.Codec.FIT[domain]
  if not fit or type(author) ~= "string" then return nil, "family" end
  if type(body) ~= "table" then return nil, "body" end
  -- P~<key>~<rev 16 digits>~<hash 8>~<by at most 48>~<body>
  local room = fit - (2 + #ns.Key(family, 1, author) + 1 + 16 + 1 + 8 + 1 + 48 + 1)
  if not MERGED[family] then
    if #ns.Codec.Encode(body) > room then return nil, "full" end
    return { body }
  end
  local skeleton = {}
  local list = units(family, body, skeleton)
  local pieces, piece, used, count = {}, nil, 0, 0
  local function open(first)
    piece = first and copy(skeleton) or {}
    if family == "b" then
      piece.items = {}
      piece.scanned = skeleton.scanned -- every b piece carries its scan time (f5283); money stays in the first
    end
    used, count = #ns.Codec.Encode(piece), 0
    pieces[#pieces + 1] = piece
  end
  open(true)
  for _, u in ipairs(list) do
    local cost
    if family == "b" or family == "t" then
      cost = #ns.Codec.Encode({ [u.k] = u.v }) - 2 + 1
    else
      cost = #u.text + 6 -- "#<index>=" and a comma
      if u.into and not piece[u.into] then cost = cost + #u.into + 5 end
    end
    if count > 0 and used + cost > room then open(false) end
    if family == "b" then
      piece.items[u.k] = u.v
    elseif family == "t" then
      piece[u.k] = u.v
    elseif u.into then
      piece[u.into] = piece[u.into] or {}
      table.insert(piece[u.into], u.v)
    else
      piece[#piece + 1] = u.v
    end
    used, count = used + cost, count + 1
  end
  if #pieces > ns.CAPS[family] then return nil, "full" end
  return pieces
end

local function isEmpty(body) return type(body) ~= "table" or next(body) == nil end

-- ---------- d784: stash, guard, catch-up ----------

local function heldRec(key)
  local family = ns.ParseKey(key)
  local list = family and ns.DB().records[ns.DOMAIN[family]]
  return list ~= nil and list[key] or nil
end

local function held(key) return heldRec(key) ~= nil end

-- startedEmpty, computed once per session (before any own l, t, a or q write; f5324). Nil while MyKey is unknown.
local function emptyAtStart()
  if startedEmpty then return startedEmpty end
  local mine = myKey()
  if not mine then return nil end
  startedEmpty = { l = true, t = true, a = true, q = true }
  for _, byKey in pairs(ns.DB().records) do
    for key in pairs(byKey) do
      local family, _, author = ns.ParseKey(key)
      if author == mine and GUARDED[family] then startedEmpty[family] = nil end
    end
  end
  return startedEmpty
end

-- An officer other than me is online (only officers answer on officer domains, CommSync.lua:408).
local function officerOnline()
  local rows = GuildSync.Comm.Roster()
  local mine = myKey()
  for key, r in pairs(type(rows) == "table" and rows or {}) do
    if key ~= mine and r.online and GuildSync.Comm.IsOfficer(r.name or key) then return true end
  end
  return false
end

-- W = clamp(2 + max(4, 2 x peers) + 30, 60, 300); peers seen on any Bank domain in the last PEER_WINDOW, at least 1.
local function windowSize(now)
  local peers = 0
  for _, at in pairs(peersSeen) do if now - at <= PEER_WINDOW then peers = peers + 1 end end
  if peers < 1 then peers = 1 end
  local w = 2 + math.max(4, 2 * peers) + 30
  if w < 60 then w = 60 elseif w > 300 then w = 300 end
  return w
end

-- An own key of family F that an officer D listed, not held and not stashed.
local function inFlight(F, key) return not held(key) and not (stash[F] and stash[F][key]) end

-- The stash holds a copy of key newer than the held record, or the key is not held (f5281, f5287).
local function stashNewer(F, key)
  local e = stash[F] and stash[F][key]
  local c = e and e.copies[1] -- newest first
  if not c then return false end
  local r = heldRec(key)
  return not r or newer(c.rev, c.hash, r.rev, r.hash)
end

-- The families an own write changes (keys of own whose body differs from what Mine() holds).
local function writtenFamilies(own)
  local cur, out = Store.Mine(), {}
  for key, body in pairs(own or {}) do
    local family = ns.ParseKey(key)
    if GUARDED[family] and Store.IsOwn(key) then
      local a = type(body) == "table" and ns.Codec.Encode(body) or ""
      local b = type(cur[key]) == "table" and ns.Codec.Encode(cur[key]) or ""
      if a ~= b then out[family] = true end
    end
  end
  return out
end

-- The first roster read was partial, no full read happened yet, and LONG_WINDOW has not passed since that read
-- (f5314). While the read's time or now is unknown it holds; the first numeric now stands in for a missing read time.
local function waitingRoster(now)
  if firstPartial ~= true or fullSeen then return false end
  if firstPartialAt == nil and type(now) == "number" then firstPartialAt = now end
  if type(now) ~= "number" or type(firstPartialAt) ~= "number" then return true end
  return now < firstPartialAt + LONG_WINDOW
end

-- The d784 guard over a set of families: nil, or "held" (a, d), "fullroster" (b, partial first read) or "catchup"
-- (b, c). (b) and (c) end at the family's first own write (f5318 fix 1).
local function guard(families, now)
  local empty = emptyAtStart() or {}
  local why
  for F in pairs(families) do
    for key in pairs(stash[F] or {}) do if stashNewer(F, key) then return "held" end end -- (a)
    if next(dropped[F] or {}) then return "held" end                                     -- (d)
    if empty[F] and not wrote[F] and why ~= "fullroster" then
      -- (b): the partial first read, capped (f5314); a full first read before afterRead (f5316); the officer catch-up
      if waitingRoster(now) then
        why = "fullroster"
      else
        if (firstPartial == false and not fullSeen) or (officerOnline() and Sync.CatchingUp(ns.DOMAIN[F])) then
          why = "catchup"
        end
        for key in pairs(listed[F] or {}) do if inFlight(F, key) then why = "catchup" end end -- (c)
      end
    end
  end
  return why
end

function Store.SaveMine(own, now)
  local asked = writtenFamilies(own)
  local why = guard(asked, now)
  if why then return nil, why end
  local plan = {}
  local mine = myKey()
  for key, body in pairs(own or {}) do
    local family, n, author = ns.ParseKey(key)
    if family and ns.DOMAIN[family] then
      local pieces, full = Store.Fit(family, author, body)
      if not pieces then
        if full == "full" then return nil, family == "t" and "tfull" or "full" end
      elseif MERGED[family] then
        if n == 1 then
          for i, p in ipairs(pieces) do plan[#plan + 1] = { ns.Key(family, i, author), p } end
          local list = ns.DB().records[ns.DOMAIN[family]] or {}
          for i = #pieces + 1, ns.CAPS[family] do
            local k = ns.Key(family, i, author)
            if author == mine and list[k] and not isEmpty(list[k].body) then plan[#plan + 1] = { k, {} } end
          end
        end
      else
        plan[#plan + 1] = { key, body }
      end
    end
  end
  -- all or nothing (f5289): every piece passes Put's checks before any is written; the first refusal answers
  if plan[1] and not me() then return nil, "roster" end
  local extra = {} -- guarded families a piece will really change that the raw bodies did not name (a re-fit, f5318 fix 2)
  for _, p in ipairs(plan) do
    if not Store.IsOwn(p[1]) then return nil, "notown" end
    if type(p[2]) ~= "table" then return nil, "body" end
    local family = ns.ParseKey(p[1])
    local view, bad = ns.Codec.Clean(family, p[2], now)
    if not view then return nil, bad end
    local old = (ns.DB().records[ns.DOMAIN[family]] or {})[p[1]]
    if GUARDED[family] and not asked[family] and not (old and old.text == ns.Codec.Encode(view)) then
      extra[family] = true
    end
  end
  why = guard(extra, now)
  if why then return nil, why end
  local changed = {}
  for _, p in ipairs(plan) do
    local key = p[1]
    local domain = ns.DOMAIN[ns.ParseKey(key)]
    local records = ns.DB().records
    local before = records[domain] and records[domain][key]
    if Store.Put(key, p[2], now) then
      local after = ns.DB().records[domain][key]
      if after ~= before then changed[#changed + 1] = key end
    end
  end
  -- an own write ends the empty-start stash and the listing (f5318); only a family the caller wrote, not a re-fit
  for _, key in ipairs(changed) do
    local F = ns.ParseKey(key)
    if asked[F] then wrote[F], listed[F] = true, nil end
  end
  return changed
end

function Store.FreeSlot(view, now)
  local mine = me()
  if not mine then return nil end
  local L = ns.LIMITS
  local q = ns.DB().records.bank_q or {}
  local shown = {}
  for _, req in ipairs(view and view.reqs or {}) do shown[req.key] = req end
  for n = 1, L.slots do
    local rec = q[ns.Key("q", n, mine)]
    if not rec or isEmpty(rec.body) then return n end
  end
  for n = 1, L.slots do
    local req = shown[ns.Key("q", n, mine)]
    if not req or (req.status ~= "open" and type(req.closedAt) == "number"
      and now - req.closedAt > L.keepClosedDays * 86400) then
      return n
    end
  end
  return nil
end

-- ---------- merge (d788, d783, d777, f5328) ----------

-- The checks every foreign record passes (merge steps 2 to 6): the cleaned body, or nil (recorded in `refused`).
-- A `by` of the wrong shape: not a string, over 48 bytes, a '|' or a control byte (also the stash's test, f5308).
local function badBy(by) return type(by) ~= "string" or #by > 48 or by:find("[%z\1-\31|]") ~= nil end

local function check(domain, msg, t)
  local key = msg.key
  local fail = function() return refuse(key, msg.rev, msg.hash) and nil end
  if not ns.ValidKey(domain, key) then return fail() end
  local family, _, author = ns.ParseKey(key)
  local by = msg.by
  if badBy(by) then return fail() end
  if GuildSync.Comm.Key(by) ~= author then return fail() end
  if not GuildSync.Comm.Member(author) then return fail() end
  if BANK_FAMILY[family] and ranksReady() and not ns.Ranks.IsBankChar(author) then return fail() end -- notbank
  local text = msg.body
  if type(text) ~= "string" then return fail() end
  local body = ns.Codec.Decode(text)
  if not body or ns.Codec.Encode(body) ~= text or ns.Codec.Hash(text) ~= msg.hash then return fail() end
  local view = ns.Codec.Clean(family, body, t)
  if not view then return fail() end
  return view
end

local function ownAuthor(key)
  local mine = myKey()
  if not mine or type(key) ~= "string" then return false end
  local _, _, author = ns.ParseKey(key)
  return author == mine
end

local function merge(domain, msg, t)
  if type(msg) ~= "table" or ownAuthor(msg.key) then return false end -- own keys never merge (f5328)
  t = tonumber(t) or serverNow() or 0
  local view = check(domain, msg, t)
  if not view then return false end
  local p = pendingHeard
  local heard = p ~= nil and p.key == msg.key and p.rev == msg.rev and p.hash == msg.hash and p.text == msg.body
  domainRecords(domain)[msg.key] = { rev = msg.rev, hash = msg.hash, by = msg.by, at = t, text = msg.body,
    body = view, heard = domain == "bank_m" and heard or nil }
  refresh()
  return true
end

-- ---------- the store per domain (CommSync.lua's header; PeopleStore as the precedent) ----------

local function keysOf(domain)
  local list = {}
  for k, r in pairs(ns.DB().records[domain] or {}) do if r.rev then list[#list + 1] = k end end
  table.sort(list, byteLess)
  return list
end

-- A key compare may ask for: valid, not own, its author an officer (officer domains) or on the roster (bank_m).
local function askable(domain, key)
  if not ns.ValidKey(domain, key) or ownAuthor(key) then return false end
  local _, _, author = ns.ParseKey(key)
  if OFFICER[domain] then return GuildSync.Comm.IsOfficer(author) and true or false end
  return GuildSync.Comm.Member(author) ~= nil
end

local function newStore(domain)
  local store = { recordRule = OFFICER[domain] and "officer" or "copy", kinds = copy(KINDS), hEvery = 900,
    hJitter = 300, maxEntries = 500 }
  local function list() return ns.DB().records[domain] or {} end
  function store.get(key) return list()[key] end
  function store.keys() return keysOf(domain) end
  function store.content(key)
    local r = list()[key]
    return r and r.text or nil
  end
  function store.stamp(key, rev, hash)
    local records = domainRecords(domain)
    local r = records[key] or {}
    records[key] = r
    r.rev, r.hash = rev, hash
  end
  function store.isOwn(key) return ownAuthor(key) end
  function store.heardOwn() end
  function store.build(key)
    local r = list()[key]
    if not r or not r.rev or type(r.text) ~= "string" then return nil end
    return { t = "P", key = key, rev = r.rev, hash = r.hash, by = r.by, body = r.text }
  end
  function store.merge(msg, t) return merge(domain, msg, t) end
  function store.round()
    if not whole() then return nil end
    local records, parts = list(), {}
    for _, k in ipairs(keysOf(domain)) do
      parts[#parts + 1] = k .. "=" .. tostring(records[k].rev) .. "=" .. tostring(records[k].hash or "")
    end
    return { t = "H", hash = ns.Codec.Hash(table.concat(parts, "/")) }
  end
  function store.digest()
    if not whole() then return nil end
    local records, entries = list(), {}
    for _, k in ipairs(keysOf(domain)) do
      entries[#entries + 1] = { key = k, rev = records[k].rev, hash = records[k].hash }
    end
    return { t = "D", entries = entries }
  end
  function store.compare(dmsg)
    if not whole() then return nil end
    local records, send, ask, theirs = list(), {}, {}, {}
    for _, e in ipairs(type(dmsg) == "table" and type(dmsg.entries) == "table" and dmsg.entries or {}) do
      if type(e) == "table" and type(e.key) == "string" then
        theirs[e.key] = e
        local r = records[e.key]
        if askable(domain, e.key) and not isRefused(e.key, e.rev, e.hash)
           and (not r or not r.rev or newer(e.rev, e.hash, r.rev, r.hash)) then
          ask[#ask + 1] = { key = e.key, rev = r and r.rev or 0 }
        end
      end
    end
    for _, k in ipairs(keysOf(domain)) do
      local e, r = theirs[k], records[k]
      if not e or newer(r.rev, r.hash, e.rev, e.hash) then send[#send + 1] = k end
    end
    return send, ask
  end
  function store.stillWanted(w)
    local r = list()[w.subject]
    if w.t == "P" then return r ~= nil and r.rev == tonumber(w.version) end
    if w.t == "R" then return ((r and r.rev) or 0) == (tonumber(w.version) or 0) end
    return true
  end
  function store.pack(msg) return ns.Codec.Pack(msg) end
  function store.parts(msg) return { msg } end
  function store.subject(msg)
    if msg.t == "P" then return msg.key, msg.rev end
    return "-", 0
  end
  return store
end

-- ---------- handlers ----------

-- d783: the owner's own P on bank_m. Equal (rev, hash): heard, and the owner's text replaces a different held text
-- once it passes the merge checks (f5340). Newer: pendingHeard, which merge reads while M.Sync.Handle runs.
local function ownerHeard(msg, t)
  local rec = (ns.DB().records.bank_m or {})[msg.key]
  if rec and rec.rev == msg.rev and rec.hash == msg.hash then
    if msg.body == rec.text then
      rec.heard = true
    elseif not ownAuthor(msg.key) then
      local view = check("bank_m", msg, tonumber(t) or serverNow() or 0)
      if view then
        rec.text, rec.body, rec.by, rec.heard = msg.body, view, msg.by, true
        refresh()
      end
    end
  elseif not rec or newer(msg.rev, msg.hash, rec.rev, rec.hash) then
    pendingHeard = { key = msg.key, rev = msg.rev, hash = msg.hash, text = msg.body }
  end
end

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }

local STASH_COPIES = 4 -- different (rev, hash) copies kept per stashed key, newest first

local function stashPut(F, msg, from)
  stash[F] = stash[F] or {}
  local e = stash[F][msg.key]
  if not e then
    e = { copies = {} }
    stash[F][msg.key] = e
  end
  for _, c in ipairs(e.copies) do
    if c.rev == msg.rev and c.hash == msg.hash then
      if from then c.senders[from] = true end
      return
    end
  end
  local c = { rev = msg.rev, hash = msg.hash, by = msg.by, text = msg.body, senders = from and { [from] = true } or {} }
  table.insert(e.copies, c)
  table.sort(e.copies, function(x, y) return newer(x.rev, x.hash, y.rev, y.hash) end)
  while #e.copies > STASH_COPIES do table.remove(e.copies) end
  for _, x in ipairs(e.copies) do if x == c then return true end end -- a new copy was kept
end

-- d784: an own-keyed P on an officer domain, before M.Sync.Handle. b, k and g go to the session set; l, t, a and q
-- are stashed (family started empty, rev <= t, no own write of it yet), refused, or refuted (Put {} and the hub mints
-- above the foreign rev). After my first own write in an empty-start family a held key goes to the hub's own path and
-- an unheld slot is refuted without took (f5318, f5319).
-- -> drop (keep it from M.Sync.Handle), took (a new copy was stashed or a key of mine newly delivered: f5282's restart)
local function ownArrival(domain, msg, from, t)
  local mine = myKey()
  local F = ns.ParseKey(msg.key)
  local rev = tonumber(msg.rev)
  if badBy(msg.by) or GuildSync.Comm.Key(msg.by) ~= mine or not rev then
    return refuse(msg.key, msg.rev, msg.hash)
  end
  if F == "b" or F == "k" or F == "g" then
    if not held(msg.key) then
      unheld[F] = unheld[F] or {}
      local new = not unheld[F][msg.key]
      unheld[F][msg.key] = true
      return false, new
    end
    return
  end
  if not GUARDED[F] then return end
  if rev > t + FUTURE then return refuse(msg.key, msg.rev, msg.hash) end
  local empty = emptyAtStart() or {}
  if empty[F] and not wrote[F] then
    local r = heldRec(msg.key)
    if r and newer(rev, msg.hash, r.rev, r.hash) then
      -- a held key's newer copy is kept from the hub, which would re-mint my older text above it (f5281)
      if rev > t then return true, refuse(msg.key, msg.rev, msg.hash) end
      return true, stashPut(F, msg, from)
    end
    if rev > t then return refuse(msg.key, msg.rev, msg.hash) end
    if not r then return false, stashPut(F, msg, from) end
    return -- an older or equal copy of a held key is neither stashed nor counted (f5307, f5287)
  end
  -- a key I hold is defended by the hub's own path (re-mint above it, resend my content, CommSync.lua:427-435)
  if held(msg.key) then return end
  stores[domain].stamp(msg.key, rev, msg.hash)
  domainRecords(domain)[msg.key].text = nil -- Put writes {} even over an equal text, and Changed mints above rev
  local put = Store.Put(msg.key, {}, t) == true
  if empty[F] then return false, false end -- after my first own write: a refuted copy does not move the window
  return false, put
end

local function fromOfficer(from) return from ~= nil and GuildSync.Comm.IsOfficer(from) and true or false end

local function newHandle(domain)
  local handle = {}
  local function seen(from, t)
    if from and from ~= myKey() then peersSeen[from] = t end
  end
  for kind, role in pairs(ROLE) do
    handle[kind] = function(msg, from, t)
      seen(from, t)
      M.Sync.Handle(domain, role, msg, from, t)
    end
  end
  if OFFICER[domain] then
    -- an officer's single-hash H equal to my round hash ends the catch-up (f5327: a multi-part H does not)
    handle.H = function(msg, from, t)
      seen(from, t)
      if type(msg) == "table" and fromOfficer(from) and type(msg.hash) == "string" and #msg.hash == 8
         and msg.hash == Sync.RoundHash(domain) then
        lifted[domain] = true
      end
      M.Sync.Handle(domain, "round", msg, from, t)
    end
    -- an officer's D ends the catch-up and names the own keys it holds (guard c)
    handle.D = function(msg, from, t)
      seen(from, t)
      if type(msg) == "table" and fromOfficer(from) then
        if msg.part == nil then lifted[domain] = true end -- a D part lists one bucket only (f5286)
        for _, e in ipairs(type(msg.entries) == "table" and msg.entries or {}) do
          local key = type(e) == "table" and e.key
          if ns.ValidKey(domain, key) and ownAuthor(key) then
            local F = ns.ParseKey(key)
            if GUARDED[F] and not wrote[F] then
              listed[F] = listed[F] or {}
              listed[F][key] = true
            end
          end
        end
      end
      M.Sync.Handle(domain, "digest", msg, from, t)
    end
  end
  handle.P = function(msg, from, t)
    seen(from, t)
    if type(msg) ~= "table" then return end
    -- d785 early drop (f5264, R7-6): a bad key, or an officer domain's key by a non-officer author, never reaches
    -- the hub's counters
    if not ns.ValidKey(domain, msg.key) then return refuse(msg.key, msg.rev, msg.hash) end
    local _, _, author = ns.ParseKey(msg.key)
    if OFFICER[domain] and not GuildSync.Comm.IsOfficer(author) then return refuse(msg.key, msg.rev, msg.hash) end
    local drop, took
    if OFFICER[domain] and ownAuthor(msg.key) then drop, took = ownArrival(domain, msg, from, t) end
    if took and fromOfficer(from) and windowEnd[domain] then
      -- an officer P that newly stashed or delivered a copy of my key restarts the window; the first replaces the long
      -- first window (f5282). Only accepted own copies move it: not a refused or repeated copy, nor any copy in an
      -- empty-start family after my first own write there (f5318).
      local w = windowSize(t)
      if longWindow[domain] then
        windowEnd[domain], longWindow[domain] = t + w, nil
      else
        windowEnd[domain] = math.max(windowEnd[domain], t + w)
      end
    end
    if drop then return end -- a held key's newer copy, kept from the hub
    if domain == "bank_m" and from ~= nil and from == msg.key then ownerHeard(msg, t) end
    M.Sync.Handle(domain, "record", msg, from, t)
    pendingHeard = nil
  end
  return handle
end

for _, domain in ipairs(DOMAINS) do
  local bulk = domain == "bank_m"
  local rule = OFFICER[domain] and "officer" or "copy"
  local ok, why = M.Comm.Register({
    id = domain, prefix = bulk and "GSyncB" or "GSync", audience = "guild", owner = "self", bulk = bulk or nil,
    maxChunks = bulk and 64 or 16,
    kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = rule } },
    unpack = function(text) return ns.Codec.Unpack(text) end,
    handle = newHandle(domain),
  })
  if ok then
    stores[domain] = newStore(domain)
    ok, why = M.Sync.Attach(domain, stores[domain])
  end
  attached[domain] = ok and true or tostring(why or "refused")
end

-- ---------- ns.Sync ----------

function Sync.Publish(key, now)
  if demo() or type(key) ~= "string" then return end
  local family = ns.ParseKey(key)
  local domain = family and ns.DOMAIN[family]
  if not domain then return end
  M.Sync.Changed(domain, key, now or serverNow())
end

function Sync.Attached() return copy(attached) end

function Sync.Heard(memberKey)
  local r = (ns.DB().records.bank_m or {})[memberKey]
  return r ~= nil and r.heard == true
end

function Sync.RoundHash(domain)
  local st = stores[domain]
  local r = st and st.round()
  return r and r.hash or nil
end

-- d784 seams.
-- The stashed own keys of family plus the own keys an officer D listed that are neither held nor stashed (R7-5).
function Sync.Stashed(family)
  local n = 0
  for key in pairs(stash[family] or {}) do if stashNewer(family, key) then n = n + 1 end end
  if not wrote[family] then
    for key in pairs(listed[family] or {}) do if inFlight(family, key) then n = n + 1 end end
  end
  return n
end

-- The catch-up window on an officer domain is open and no officer D or equal-hash officer H has ended it.
function Sync.CatchingUp(domain)
  local now = serverNow()
  return windowEnd[domain] ~= nil and not lifted[domain] and now ~= nil and now < windowEnd[domain]
end

-- The capped partial-first-read clause of guard (b) (f5314); now defaults to the server time.
function Sync.WaitingRoster(now)
  return waitingRoster(tonumber(now) or serverNow())
end

function Sync.UnheldScan(family)
  unheld[family] = unheld[family] or {}
  return unheld[family]
end

-- /gsbank adopt: for each stashed key the newest copy that passes the checks becomes own with its rev, hash, by and
-- text; a key with none is dropped and marked (guard d). -> n taken, sorted sender display names, conflicting keys.
function Sync.Adopt(now)
  now = tonumber(now) or serverNow() or 0
  local n, conflicts, names, list = 0, 0, {}, {}
  for F, byKey in pairs(stash) do
    for key, e in pairs(byKey) do
      local domain = ns.DOMAIN[F]
      local took
      local r = heldRec(key) -- only a copy newer than the held record is taken (f5281)
      for _, c in ipairs(e.copies) do
        local body = ns.ValidKey(domain, key) and type(c.text) == "string" and not badBy(c.by)
          and (not r or newer(c.rev, c.hash, r.rev, r.hash)) and ns.Codec.Decode(c.text)
        local view = body and ns.Codec.Encode(body) == c.text and ns.Codec.Hash(c.text) == c.hash
          and type(c.rev) == "number" and c.rev <= now and ns.Codec.Clean(F, body, now)
        if view then
          domainRecords(domain)[key] = { rev = c.rev, hash = c.hash, by = c.by, at = now, text = c.text, body = view }
          took = c
          break
        end
      end
      if took then
        n = n + 1
        if dropped[F] then dropped[F][key] = nil end
        for from in pairs(took.senders) do names[from] = true end
        local senders, distinct = {}, 0
        for _, c in ipairs(e.copies) do
          for from in pairs(c.senders) do
            if not senders[from] then senders[from], distinct = true, distinct + 1 end
          end
        end
        if #e.copies > 1 and distinct > 1 then conflicts = conflicts + 1 end
      elseif not r then -- a held key keeps its record, so it is not dropped
        dropped[F] = dropped[F] or {}
        dropped[F][key] = true
      end
      byKey[key] = nil
    end
  end
  for from in pairs(names) do
    local row = GuildSync.Comm.Member(from)
    list[#list + 1] = row and type(row.name) == "string" and row.name or from
  end
  table.sort(list, byteLess)
  if n > 0 then refresh() end
  return n, list, conflicts
end

-- /gsbank fresh: clears the stash, listed, the (d) marks and the windows; own arrivals are refuted from now on.
function Sync.Fresh()
  stash, listed, dropped, windowEnd, longWindow = {}, {}, {}, {}, {}
  startedEmpty = {}
end

-- ---------- hooks: mint (d782), self-heal (d786), prune (d777) ----------

-- d786: every own record whose hash is not its text's, or that has no rev, is published once.
local function selfHeal(now)
  if demo() then return end
  for _, byKey in pairs(ns.DB().records) do
    for key, r in pairs(byKey) do
      if Store.IsOwn(key) and (not r.rev or ns.Codec.Hash(r.text or "") ~= r.hash) then Sync.Publish(key, now) end
    end
  end
end

-- d782: the own m once per session, at the first full read.
local function mintOwn(now)
  if demo() then return end
  local mine = me()
  if not mine then return end
  if (ns.DB().records.bank_m or {})[mine] then
    Sync.Publish(mine, now)
  else
    Store.Put(mine, {}, now)
  end
end

-- d777: off-roster authors' records go; once rank names are known, so do bank-family records of authors who are not
-- bank characters (x is kept).
local function prune(rows)
  local bankRule = ranksReady()
  local removed = false
  for _, byKey in pairs(ns.DB().records) do
    for key in pairs(byKey) do
      local family, _, author = ns.ParseKey(key)
      if not rows[author] or (bankRule and BANK_FAMILY[family] and not ns.Ranks.IsBankChar(author)) then
        byKey[key] = nil
        removed = true
      end
    end
  end
  if removed then refresh() end
end

local lastPartial
local function afterRead()
  if lastPartial then return end
  local rows, partial, _, known = GuildSync.Comm.Roster()
  if partial or not known or type(rows) ~= "table" then return end
  prune(rows)
  if not fullSeen then
    fullSeen = true
    local now = serverNow()
    emptyAtStart()
    -- d784: the catch-up window opens at the first full read (1200 s after a partial first read, f5329)
    for domain in pairs(OFFICER) do
      windowEnd[domain] = (now or 0) + (firstPartial and LONG_WINDOW or windowSize(now or 0))
      longWindow[domain] = firstPartial or nil
    end
    mintOwn(now)
    selfHeal(now)
  end
end

-- Ranks.lua loads after this file, and its rosterRead listener refreshes the bank-character set; the d777 prune and
-- the first-read work run after it, through Ranks.OnChange (hooked at the first read).
local hooked = false
M.On("rosterRead", function(partial)
  lastPartial = partial and true or false
  if firstPartial == nil then
    firstPartial = lastPartial
    if lastPartial then firstPartialAt = serverNow() end
  end
  if hooked then return end
  if ns.Ranks and ns.Ranks.OnChange then
    hooked = true
    ns.Ranks.OnChange(afterRead)
  else
    afterRead()
  end
end)

M.On("demo", function(on)
  if not on then selfHeal(serverNow()) end
end)
