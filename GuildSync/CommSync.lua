-- CommSync: the GuildSync comm core's engine for record domains (plan r-20261005-guildsync-comm-core, sections 1, 3
-- and 5, Task 6). A domain registered with Comm.Register attaches a store; the engine mints the owner's rev and hash,
-- merges by the record rule, answers digests and asks through a pull-model guard, and sends rounds.
-- Copied, not moved, from CraftSync.lua (wants, batching, the H/D/R/P handlers, heardChunk, scheduleH) and
-- CraftStore.lua (AnswerDelay, the guard); crafting keeps its own copies until the follow-up task (R6).
--
-- store = { recordRule = "put"|"copy"|"officer", kinds = { round, digest, ask, record } (kind letters),
--           hEvery = 900, hJitter = 300, get(key), keys(), content(key), stamp(key, rev, hash), build(key, t),
--           merge(msg, t), round(t), digest(t), compare(dmsg, t) -> sendKeys, askEntries, stillWanted(want, t),
--           isOwn(key), heardOwn(msg, t), pack(msg), parts(msg), subject(msg) -> subject, version }
--   round(t).hash is one 8-hex hash, packed verbatim (the engine may send n part hashes concatenated in its place).
--   stillWanted may get a D want whose subject is a part id "p.n"; it must not interpret D subjects (f1217).
--   Officer-domain keys must not look like "<int>.<int>": served marks are keyed by subject only (f1216).
-- Messages: P { t, key, rev, hash, by, body }; H { t, hash }; D and R { t, entries = { { key, rev, hash } } }.
-- Digest parts (f1199, d254): a digest that does not fit maxChunks goes as n hash buckets (n a power of two, at most
-- MAX_PARTS), partOf(key, n) = Sync.PartOf (a mixed hash of the key's bytes, % n + 1; f1241), each part a D with
-- header subject "p.n",
-- version 0. Its round then carries the n part hashes (Wire.Hash of key=rev=hash joined by "/" over the bucket's
-- sorted keys) concatenated. A digest that fits stays one message with subject "-" and the store's round hash.
-- Merge: a higher rev wins, then the higher hash; a rev beyond now + Wire.FUTURE is ignored (f1078, f1079).
-- Officer domains: only an officer answers with records (R5: catch-up needs an officer online).

local _, ns = ...
ns.Comm = ns.Comm or {}
local Comm = ns.Comm
local Sync = Comm.Sync or {}
Comm.Sync = Sync

local MODULE = "Comms"
local TICK = 5               -- roster-known check until every domain has started
local SERVED_WINDOW = 600    -- the (subject, asker) answer throttle (copy of CraftStore's)
local PEER_WINDOW = 900      -- peers = distinct senders heard in the last 15 min
local ASK_BATCH = 16         -- asks batched into one R
local HEADER_CAP = 4         -- unfinished messages per sender whose headers may cancel wants (f1066)
local HEADER_WINDOW = 60     -- seconds an unfinished message counts after its last chunk
local HEADER_BUDGET = 20     -- messages per sender per HEADER_WINDOW whose first header may cancel wants
-- Caps (f1192, d247). Self domains (put, copy) hold one record per roster member, so the roster bounds them. Officer
-- domains: a record's author (msg.by) must be an officer, each (sender, author) pair introduces at most store.maxRecords
-- (default MAX_RECORDS) new keys (f1186, d255), and each sender at most 2 x maxRecords in all (d261). A digest or ask with more entries than store.maxEntries (default
-- MAX_ENTRIES, roster-sized) is refused whole.
local MAX_RECORDS = 100
local MAX_ENTRIES = 500
local MIN_HEVERY = 300 -- a module addon's store (AttachModule) adverts at most this often, in seconds
local MAX_REV = 2 ^ 53
local MAX_PARTS = 64         -- digest parts at most (f1199)
local REFUSED_WINDOW = 3600  -- a record refused for the officer cap is not asked for again from that sender (f1262)

-- A rev or version off the wire: a finite number from 0 to 2^53 (f1191: nan, inf and negatives are refused).
-- Fractions are not refused: a pinned test (f1166 restore) sends a header at a fractional time.
local function validRev(v)
  return type(v) == "number" and v == v and v >= 0 and v < MAX_REV
end

local D = {}                 -- id -> domain state
local ticking = false

local function Wire() return ns.Comm.Wire end
local function Queue() return ns.Comm.Queue end
local floor = math.floor

-- Higher rev wins, then the higher hash (plan section 3).
local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

-- ---------- the guard (copy of CraftStore.NewGuard) ----------

local Guard = {}
Guard.__index = Guard

-- record: the store's record kind letter, whose wants are covered only by a rev >= the wanted one.
local function newGuard(record) return setmetatable({ wants = {}, served = {}, seq = 0, record = record }, Guard) end
local function wantKey(t, subject) return tostring(t) .. "\0" .. tostring(subject) end

local function markServed(g, w, now)
  local s = g.served[w.subject]
  if not s then s = {} g.served[w.subject] = s end
  for asker in pairs(w.askers) do s[asker] = now end
end

function Guard:Want(t, subject, version, asker, due)
  local k = wantKey(t, subject)
  local w = self.wants[k]
  if not w then
    self.seq = self.seq + 1
    w = { t = t, subject = subject, version = version, askers = {}, due = due, seq = self.seq }
    self.wants[k] = w
  else
    w.version = version
    if due < w.due then w.due = due end
  end
  if asker then w.askers[asker] = true end
end

-- Covering: a record kind with a rev >= the wanted one; anything else of the same (t, subject).
function Guard:Heard(t, subject, version, now)
  local k = wantKey(t, subject)
  local w = self.wants[k]
  if not w then return end
  if t == self.record and (tonumber(version) or -1) < (tonumber(w.version) or 0) then return end
  self.wants[k] = nil
  markServed(self, w, now)
end

function Guard:Recent(subject, asker, now)
  local at = self.served[subject] and self.served[subject][asker]
  return at ~= nil and now - at <= SERVED_WINDOW
end

function Guard:Next(now, check)
  for subject, s in pairs(self.served) do
    for asker, at in pairs(s) do if now - at > SERVED_WINDOW then s[asker] = nil end end
    if next(s) == nil then self.served[subject] = nil end
  end
  local due = {}
  for k, w in pairs(self.wants) do
    if w.due <= now then due[#due + 1] = { k = k, w = w } end
  end
  table.sort(due, function(a, b)
    if a.w.due ~= b.w.due then return a.w.due < b.w.due end
    return a.w.seq < b.w.seq
  end)
  for _, d in ipairs(due) do
    local w = d.w
    self.wants[d.k] = nil
    for asker in pairs(w.askers) do
      if self:Recent(w.subject, asker, now) then w.askers[asker] = nil end
    end
    if next(w.askers) ~= nil and check(w) then
      markServed(self, w, now)
      return { t = w.t, subject = w.subject, version = w.version, askers = w.askers }
    end
  end
  return nil
end

-- Copy of CraftStore.AnswerDelay: the owner answers first; others spread over the peers.
local function answerDelay(r, peers, isOwner)
  if isOwner then return 0.5 end
  peers = math.min(tonumber(peers) or 0, 60)
  return 2 + r * math.max(4, 2 * peers)
end

-- ---------- helpers ----------

local function peerCount(st, t)
  local n = 0
  for from, at in pairs(st.heard) do
    if t - at <= PEER_WINDOW then n = n + 1 else st.heard[from] = nil end
  end
  return n
end

-- This character is an officer: its roster row by GUID (UnitName can be the first name only), else its name.
local function iAmOfficer()
  local p = ns.Compat.Player()
  local g = ns.DB and ns.DB().guild
  local m = p.guid and type(g) == "table" and type(g.members) == "table" and g.members[p.guid] or nil
  return Comm.IsOfficer(type(m) == "table" and m.name or p.name)
end

-- The send gate (run r-20261014-r8): a domain on OFFICER sends nothing while this character is not an officer (a
-- partial roster included) or while its rank lacks Officerchat Speak (the server refuses the send; fix round 1,
-- f4354). The attach stays, so a rank that gains the flags joins with no /reload.
local function sendClosed(st) return st.channel == "OFFICER" and not (iAmOfficer() and Comm.SelfMaySpeak()) end

local function pump(st) Queue().Pump(st.prefix) end

-- One timer per domain that pumps when the earliest want falls due (the queue goes idle while the source has
-- nothing), then re-arms for the next one (copy of CraftSync's wake and wakeForWants).
local function addDue(st, due, t)
  if st.wakeAt and st.wakeAt > t and st.wakeAt <= due then return end
  st.wakeAt = due
  local token = {}
  st.wakeToken = token
  ns.After(math.max(0, math.ceil(due) - t), function()
    if st.wakeToken ~= token then return end
    st.wakeAt = nil
    pump(st)
    local now, min = ns.Compat.ServerTime(), nil
    for _, w in pairs(st.guard.wants) do
      if w.due > now and (not min or w.due < min) then min = w.due end
    end
    if min then addDue(st, min, now) end
  end, MODULE)
end

-- Splits every part of an entry, each with its own mid (the first part takes firstMid). false when a part is too big.
local function split(st, e, firstMid)
  local chunks = {}
  for i, p in ipairs(e.parts) do
    local c = Wire().Split(Wire().PROTOCOL, i == 1 and firstMid or Queue().NextMid(), p.T, p.subject, p.version, p.logical)
    if not c or #c > st.maxChunks then return false end
    for _, x in ipairs(c) do chunks[#chunks + 1] = x end
  end
  e.chunks, e.i, e.tries, e.lastAt = chunks, 1, 0, nil
  return true
end

-- ---------- digest parts (f1199, d254) ----------

-- f1241: Adler-32 % n reads only the byte sum, so keys like "member 001".."member 500" pile into a few buckets. The
-- bucket comes from a polynomial hash of the bytes (mod 2^32), multiplied by 0x9E3779B1 (mod 2^32, exact in doubles
-- through 16-bit halves); its upper 16 bits % n. n is a power of two, so bucket q at 2n lies in bucket p at n exactly
-- when (q - 1) mod n = p - 1.
local function partValue(key)
  local x = 0
  for i = 1, #key do x = (x * 33 + key:byte(i)) % 4294967296 end
  local lo, hi = x % 65536, floor(x / 65536)
  local m = (lo * 0x79B1 + ((lo * 0x9E37 + hi * 0x79B1) % 65536) * 65536) % 4294967296
  return floor(m / 65536)
end

local function partOf(key, n) return partValue(key) % n + 1 end
Sync.PartOf = partOf

local function validParts(n)
  if type(n) ~= "number" or n < 2 or n > MAX_PARTS then return false end
  while n > 1 do
    if n % 2 ~= 0 then return false end
    n = n / 2
  end
  return true
end

-- "p.n" -> p, n when canonical (no leading zeros, n a power of two from 2 to MAX_PARTS, 1 <= p <= n), else nil.
local function partId(s)
  if type(s) ~= "string" then return nil end
  local p, n = s:match("^(%d+)%.(%d+)$")
  p, n = tonumber(p), tonumber(n)
  if not p or tostring(p) .. "." .. tostring(n) ~= s or not validParts(n) or p < 1 or p > n then return nil end
  return p, n
end

-- The header subject and version of a message: a digest part carries its part id, version 0.
local function wireSubject(st, msg)
  if msg.t == st.kinds.digest and msg.part then return msg.part, 0 end
  return st.store.subject(msg)
end

-- The entries of digest d that have a string key, in order.
local function keyedEntries(d)
  local es = {}
  for _, e in ipairs(type(d) == "table" and type(d.entries) == "table" and d.entries or {}) do
    if type(e) == "table" and type(e.key) == "string" then es[#es + 1] = e end
  end
  return es
end

-- Bucket p at n of digest d: a copy of d holding only the entries in that bucket, marked with its part id.
local function partMsg(d, p, n)
  local m, list = {}, {}
  for k, v in pairs(d) do m[k] = v end
  for _, e in ipairs(keyedEntries(d)) do
    if partOf(e.key, n) == p then list[#list + 1] = e end
  end
  m.entries, m.part = list, p .. "." .. n
  return m
end

-- The message packs to at most `limit` chunks (counted with the widest mid).
local function fits(st, msg, limit)
  local logical = st.store.pack(msg)
  if type(logical) ~= "string" then return false end
  local subject, version = wireSubject(st, msg)
  local W = Wire()
  local c = W.Split(W.PROTOCOL, W.MAX_MID, st.id .. "." .. tostring(msg.t), subject or "-", version or 0, logical)
  return c ~= nil and #c <= limit
end

-- My part count for digest d: 1 when it fits maxChunks whole; else the smallest power of two (2 to MAX_PARTS) at
-- which every part fits half of maxChunks.
local function partCount(st, d)
  if type(d) ~= "table" or fits(st, d, st.maxChunks) then return 1 end
  local n, half = 2, floor(st.maxChunks / 2)
  while n < MAX_PARTS do
    local all = true
    for p = 1, n do
      if not fits(st, partMsg(d, p, n), half) then all = false break end
    end
    if all then return n end
    n = n * 2
  end
  return n
end

-- The n part hashes of digest d: Wire.Hash of key=rev=hash joined by "/" over each bucket's sorted keys.
local function partHashes(d, n)
  local es = keyedEntries(d)
  table.sort(es, function(a, b) return a.key < b.key end)
  local lists = {}
  for p = 1, n do lists[p] = {} end
  for _, e in ipairs(es) do
    local l = lists[partOf(e.key, n)]
    l[#l + 1] = e.key .. "=" .. tostring(e.rev) .. "=" .. tostring(e.hash or "")
  end
  local out = {}
  for p = 1, n do out[p] = Wire().Hash(table.concat(lists[p], "/")) end
  return out
end

-- My round: the store's, or with n > 1 parts the n part hashes concatenated.
local function roundMsg(st, t)
  local r = st.store.round(t)
  if type(r) ~= "table" then return r end
  local d = st.store.digest(t)
  local n = partCount(st, d)
  if n == 1 then return r end
  local m = {}
  for k, v in pairs(r) do m[k] = v end
  m.hash = table.concat(partHashes(d, n))
  return m
end

-- A message -> a queue entry: the store's parts (or the given list), each packed by the store, T = "<id>.<msg.t>".
-- A whole digest that does not fit maxChunks goes as its n parts, each with its own mid.
local function makeEntry(st, msg, kind, parts)
  if type(msg) ~= "table" then return nil end
  local store = st.store
  if not parts and msg.t == st.kinds.digest and not msg.part then
    local n = partCount(st, msg)
    if n > 1 then
      parts = {}
      for p = 1, n do parts[p] = partMsg(msg, p, n) end
    end
  end
  parts = parts or (store.parts and store.parts(msg)) or { msg }
  local list = {}
  for _, part in ipairs(parts) do
    local logical = store.pack(part)
    if type(logical) ~= "string" then return nil end
    local subject, version = wireSubject(st, part)
    list[#list + 1] = { T = st.id .. "." .. tostring(part.t), subject = subject or "-", version = version or 0,
                        logical = logical }
  end
  if #list == 0 then return nil end
  local e = { kind = kind, msg = msg, parts = list, t = msg.t, subject = list[1].subject, version = list[1].version }
  if not split(st, e, Queue().NextMid()) then return nil end
  return e
end

local function enqueue(st, item, pos)
  if sendClosed(st) then return end
  table.insert(st.queue, pos or #st.queue + 1, item)
  pump(st)
end

local OWN_RETRY_SLACK = 5 -- an own rev at most this far past now + FUTURE waits until in range; further, no send (f1067, d543)

local function queueOwnP(st, key)
  if st.ownQueued[key] or sendClosed(st) then return end
  local r, now = st.store.get(key), ns.Compat.ServerTime()
  local ahead = (r and validRev(r.rev) and now) and (r.rev - (now + Wire().FUTURE)) or 0
  if ahead > OWN_RETRY_SLACK then return end
  st.ownQueued[key] = true
  if ahead > 0 then
    ns.After(math.ceil(ahead) + 0.5, function()
      st.ownQueued[key] = nil
      queueOwnP(st, key)
    end, MODULE)
    return
  end
  enqueue(st, { kind = "own", build = function(t)
    st.ownQueued[key] = nil
    return st.store.build(key, t)
  end })
end

-- The owner's rev and hash: rev above both now and `above`, hash of the store's content.
local function mint(st, key, t, above)
  local r = st.store.get(key)
  local rev = math.max(floor(t), ((r and r.rev) or 0) + 1, (above or 0) + 1)
  st.store.stamp(key, rev, Wire().Hash(st.store.content(key) or ""))
end

local scheduleH

local function start(st, t)
  st.started = true
  enqueue(st, { kind = "own", build = function(bt) return st.store.digest(bt) end })
  for key in pairs(st.pending) do queueOwnP(st, key) end
  st.pending = {}
  scheduleH(st)
end

local function known() return select(4, Comm.Roster()) and true or false end

local function tick()
  ticking = false
  local t = ns.Compat.ServerTime()
  local waiting = false
  for _, st in pairs(D) do
    if not st.started then
      if known() then start(st, t) else waiting = true end
    end
  end
  if waiting then
    ticking = true
    ns.After(TICK, tick, MODULE)
  end
end

-- Hearing any round restarts my window, so a same-hash round suppresses mine (copy of CraftSync's scheduleH).
function scheduleH(st)
  st.hGen = st.hGen + 1
  local gen = st.hGen
  ns.After((st.store.hEvery or 900) + math.random() * (st.store.hJitter or 300), function()
    if gen ~= st.hGen then return end
    scheduleH(st)
    enqueue(st, { kind = "own", build = function(t) return roundMsg(st, t) end })
  end, MODULE)
end

-- A P want for a key I hold. Officer domains: officers only; put domains: own records only.
local function wantP(st, key, asker, t, peers)
  local r = st.store.get(key)
  if not r or not r.rev or st.guard:Recent(key, asker, t) then return end
  local own = st.store.isOwn(key) and true or false
  if st.rule == "officer" and not iAmOfficer() then return end
  if st.rule == "put" and not own then return end
  local due = t + answerDelay(math.random(), peers, own)
  st.guard:Want(st.kinds.record, key, r.rev, asker, due)
  addDue(st, due, t)
end

-- ---------- handlers ----------

local H = {}

H.record = function(st, msg, from, t)
  if type(msg.key) ~= "string" or not validRev(msg.rev) then return end
  if msg.rev > t + Wire().FUTURE then return end -- f1078: never merged, never moves the owner
  local store, rk = st.store, st.kinds.record
  local mine = store.get(msg.key)
  local isNewer = not (mine and mine.rev) or newer(msg.rev, msg.hash, mine.rev, mine.hash)
  if isNewer then st.guard:Heard(st.kinds.ask, msg.key, 0, t) end
  st.guard:Heard(rk, msg.key, msg.rev, t)
  if store.isOwn(msg.key) then
    -- a copy that would beat mine: the owner re-mints above it and sends her own content again
    if mine and mine.rev and isNewer then
      if store.heardOwn then store.heardOwn(msg, t) end
      mint(st, msg.key, t, msg.rev)
      queueOwnP(st, msg.key)
    end
    return
  end
  if isNewer then
    if not mine and st.rule == "officer" then
      local author = Wire().Key(msg.by)
      if author and from then
        local q = from .. "\0" .. author
        st.introduced[q] = (st.introduced[q] or 0) + 1
        st.sentNew[from] = (st.sentNew[from] or 0) + 1
      end
    end
    store.merge(msg, t)
  end
end

H.digest = function(st, msg, from, t)
  st.guard:Heard(st.kinds.digest, msg.part or "-", 0, t)
  local send, ask = st.store.compare(msg, t)
  local peers = peerCount(st, t)
  local p, n = partId(msg.part)
  for _, key in ipairs(send or {}) do
    -- a part names only its bucket: keys outside it are not missing from the sender
    if not p or partOf(key, n) == p then wantP(st, key, from, t, peers) end
  end
  local due = t + answerDelay(math.random(), peers, false)
  local added = false
  for _, e in ipairs(ask or {}) do
    local rk = tostring(e.key) .. "\0" .. tostring(from)
    local no = st.refused[rk]
    if no and (t - no.at > REFUSED_WINDOW or (tonumber(e.rev) or 0) > no.rev) then
      st.refused[rk], st.refusedN, no = nil, st.refusedN - 1, nil
    end
    if not no and not st.store.isOwn(e.key) and not st.guard:Recent(e.key, from, t) then
      st.guard:Want(st.kinds.ask, e.key, e.rev or 0, from, due)
      added = true
    end
  end
  if added then addDue(st, due, t) end
end

H.ask = function(st, msg, from, t)
  local peers = peerCount(st, t)
  for _, e in ipairs(msg.entries or {}) do
    st.guard:Heard(st.kinds.ask, e.key, e.rev, t)
    local r = type(e.key) == "string" and st.store.get(e.key)
    if r and r.rev and newer(r.rev, r.hash, e.rev, e.hash) then wantP(st, e.key, from, t, peers) end
  end
end

-- A one-hash round that differs: my whole digest ("-"), or with n' > 1 parts each part p.n' (f1210). A round of n
-- part hashes: my bucket p at the sender's n for each hash that differs.
-- f1261: each asker draws D wants from me at most once per SERVED_WINDOW, so rounds forged at every n cost one
-- digest's worth, not one per n.
H.round = function(st, msg, from, t)
  scheduleH(st)
  local drawn = from and st.drawn[from]
  if drawn and t - drawn <= SERVED_WINDOW then return end
  local wanted = {}
  if type(msg.hash) == "string" and #msg.hash > 8 then
    local n = #msg.hash / 8
    if #msg.hash % 8 ~= 0 or not validParts(n) then return end -- f4541: Accept's rule, here too
    local mine = partHashes(st.store.digest(t), n)
    for p = 1, n do
      if msg.hash:sub(p * 8 - 7, p * 8) ~= mine[p] then wanted[#wanted + 1] = p .. "." .. n end
    end
  else
    local mine = st.store.round(t)
    if not mine or msg.hash == mine.hash then return end
    local n = partCount(st, st.store.digest(t))
    if n == 1 then wanted[1] = "-" else for p = 1, n do wanted[p] = p .. "." .. n end end
  end
  -- each part draws its own answer delay, so holders that fall due in the same second take different parts and the
  -- first header of each part cancels the others' want for it (with one delay they would send the same parts in step)
  if from then
    for k, at in pairs(st.drawn) do if t - at > SERVED_WINDOW then st.drawn[k] = nil end end
    st.drawn[from] = t
  end
  local peers = peerCount(st, t)
  for _, s in ipairs(wanted) do
    if not st.guard:Recent(s, from, t) then
      local due = t + answerDelay(math.random(), peers, false)
      st.guard:Want(st.kinds.digest, s, 0, from, due)
      addDue(st, due, t)
    end
  end
end

-- ---------- public ----------

-- A module domain's queue-facing callback: a throw (already recorded under the module by its wrapped store, or recorded
-- here) answers `fail` and never reaches the queue tick, so the version advert and the other domains go on.
local function caught(title, fn, fail)
  if not title then return fn end
  return function(...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    ns.RecordError(title, r) -- skips ns.ATTRIBUTED
    return fail
  end
end

-- pull: a pull store (Sync.AttachPull) instead of a record store; st.pull holds it, st.store is nil, and the domain
-- counts as started (no digest, no round: the module sends what it wants through Sync.Send).
local function attach(id, store, title, pull)
  local spec = Comm.Registry.Domain and Comm.Registry.Domain(id)
  if not spec or type(store or pull) ~= "table" then return nil, "not registered" end
  if D[id] then return nil, "already attached" end -- f1178: one store and one queue source per domain
  local kinds = not pull and (store.kinds or { round = "H", digest = "D", ask = "R", record = "P" }) or {}
  local st = {
    id = id, store = store, pull = pull, prefix = spec.prefix, rule = store and store.recordRule,
    channel = spec.audience == "officers" and "OFFICER" or "GUILD", maxChunks = spec.maxChunks or 16,
    kinds = kinds,
    guard = newGuard(not pull and (kinds.record or "P") or nil), queue = {}, held = nil, ownQueued = {}, pending = {}, heard = {}, hGen = 0, started = pull and true or false,
    open = {}, cancels = {}, introduced = {}, dropped = 0, refused = {}, refusedN = 0, refusedSeq = 0, sentNew = {}, drawn = {},
    user = 0, sent = 0, attempts = 0, limited = 0,
  }
  D[id] = st
  local added, why = Queue().AddSource(st.prefix, {
    channel = st.channel, gap = 1,
    next = caught(title, function(t) if sendClosed(st) then return nil end return Sync.Next(id, t) end, nil),
    resplit = caught(title, function(e, mid) return split(st, e, mid) end, false),
    sent = function(e, i, t)
      st.guard:Heard(e.t, e.subject, e.version, t)
      if i == #e.chunks then st.sent = st.sent + 1 end -- messages (entries), not chunks
    end,
    tried = function() st.attempts = st.attempts + 1 end, -- every send of a chunk, whatever its result (f1026)
    -- read-only (f1187, f1240): own messages waiting, a held want, or a guard want already due
    has = caught(title, function()
      if sendClosed(st) then return false end
      if #st.queue > 0 or st.held ~= nil then return true end
      local now = ns.Compat.ServerTime()
      for _, w in pairs(st.guard.wants) do
        if w.due <= now then return true end
      end
      return false
    end, false),
  })
  -- f1178: a prefix the client refused (or a wrong channel) means this domain never sends; say so
  st.on = added and true or false
  if not added then
    st.why = tostring(why or "no source") .. " (" .. tostring(st.prefix) .. ")"
    return nil, st.why
  end
  if not ticking and not pull then
    ticking = true
    ns.After(TICK, tick, MODULE)
  end
  return true
end

-- Attach(id, store): the domain must be registered (Comm.Register). Adds the domain's queue source on its prefix.
function Sync.Attach(id, store) return attach(id, store, nil) end

-- AttachModule(title, id, store): a module addon's store (Api.lua: M.Sync.Attach), for a domain that module registered.
-- The hub keeps a copy: every function wrapped (a throw is recorded under title), kinds copied, and the limits clamped
-- and frozen now: hEvery at least MIN_HEVERY, maxRecords at most MAX_RECORDS, maxEntries at most MAX_ENTRIES.
function Sync.AttachModule(title, id, store)
  if type(Comm.ModuleOf) ~= "function" or Comm.ModuleOf(id) ~= title then return nil, "not this module's domain" end
  if type(store) ~= "table" then return nil, "bad store" end
  local copy = {}
  for k, v in pairs(store) do
    if type(v) == "function" then copy[k] = ns.Attributed(title, v) end
  end
  local kinds = {}
  for role, letter in pairs(type(store.kinds) == "table" and store.kinds or {}) do
    if type(role) == "string" and type(letter) == "string" then kinds[role] = letter end
  end
  copy.kinds = next(kinds) and kinds or nil
  copy.recordRule = type(store.recordRule) == "string" and store.recordRule or nil
  copy.hEvery = ns.Limit(store.hEvery, 900, MIN_HEVERY, math.huge)
  copy.hJitter = ns.Limit(store.hJitter, 300, 0, 3600)
  copy.maxRecords = ns.Limit(store.maxRecords, MAX_RECORDS, 1, MAX_RECORDS)
  copy.maxEntries = ns.Limit(store.maxEntries, MAX_ENTRIES, 1, MAX_ENTRIES)
  copy.askBatch = floor(ns.Limit(store.askBatch, ASK_BATCH, 1, 250))
  return attach(id, copy, title)
end

-- ---------- pull stores (API 5: M.Sync.Pull, M.Comm.Send, M.Sync.Want) ----------

local PULL_NEEDS = { "pack", "subject", "build", "stillWanted" }
local USER_WINDOW = 60 -- seconds over which userPerMinute counts a domain's user sends

-- A pull function run by the engine: a throw is recorded under the module (ns.Attributed) and answers nil.
local function settle(ok, ...)
  if ok then return ... end
  return nil
end
local function call(fn, ...) return settle(pcall(fn, ...)) end

-- AttachPull(title, id, pull): a pull store for a domain the module registered. The hub keeps a copy: the functions
-- wrapped under title, the limits clamped and frozen now (queueCap, wantCap, askerShare, userPerMinute, batch,
-- maxParts).
function Sync.AttachPull(title, id, pull)
  if type(Comm.ModuleOf) ~= "function" or Comm.ModuleOf(id) ~= title then return nil, "not this module's domain" end
  if D[id] then return nil, "already attached" end
  if type(pull) ~= "table" then return nil, "bad store" end
  for _, k in ipairs(PULL_NEEDS) do
    if type(pull[k]) ~= "function" then return nil, "bad store" end
  end
  local copy = { userAt = {} }
  for _, k in ipairs(PULL_NEEDS) do copy[k] = ns.Attributed(title, pull[k]) end
  if type(pull.covers) == "function" then copy.covers = ns.Attributed(title, pull.covers) end
  if type(pull.coversVersion) == "function" then copy.coversVersion = ns.Attributed(title, pull.coversVersion) end
  copy.batch = {}
  for kind, n in pairs(type(pull.batch) == "table" and pull.batch or {}) do
    if type(kind) == "string" then copy.batch[kind] = floor(ns.Limit(n, 1, 1, 250)) end
  end
  copy.maxParts = floor(ns.Limit(pull.maxParts, 8, 1, 8))
  copy.queueCap = floor(ns.Limit(pull.queueCap, 400, 1, 400))
  copy.wantCap = floor(ns.Limit(pull.wantCap, 400, 1, 400))
  -- f4391, d524: the pending wants one asker may originate; 200 holds a full board's catch-up (135 + 50 provisional)
  copy.askerShare = floor(ns.Limit(pull.askerShare, math.min(200, copy.wantCap), 1, copy.wantCap))
  copy.userPerMinute = floor(ns.Limit(pull.userPerMinute, 30, 1, 30))
  return attach(id, nil, title, copy)
end

-- The pull domain st for this module's id, or nil, why.
local function pullOf(title, id)
  if type(Comm.ModuleOf) ~= "function" or Comm.ModuleOf(id) ~= title then return nil, "not this module's domain" end
  local st = D[id]
  if not st then return nil, "no store" end
  if not st.pull then return nil, "not a pull domain" end
  return st
end

-- One part of a pull entry: { T, subject, version, logical }, or nil, why: "unpackable" when it does not pack, "bad
-- subject" when pull.subject gives nil or more than 64 bytes (no receiver accepts it; f4372).
local function pullPart(st, msg, t)
  if type(msg) ~= "table" or type(msg.t) ~= "string" then return nil, "unpackable" end
  local logical = call(st.pull.pack, msg)
  if type(logical) ~= "string" then return nil, "unpackable" end
  local subject, version = call(st.pull.subject, msg, t)
  if subject == nil or #tostring(subject) > 64 then return nil, "bad subject" end
  return { T = st.id .. "." .. msg.t, subject = tostring(subject), version = version or 0, logical = logical }
end

-- Send(title, id, msg, priority, t): queues one message of a pull domain. user entries go after the last user entry
-- and ahead of every own; at queueCap the oldest own goes (counted); with no own left, an own send is dropped
-- (counted, answers true; f4368) and a user send is refused "full" (f4394, d524). Through enqueue, so an officers
-- domain this client may not speak on drops it (R8's sendClosed, d523); a closed queue gate keeps it.
function Sync.Send(title, id, msg, priority, t)
  local st, why = pullOf(title, id)
  if not st then return nil, why end
  if not st.on then return nil, "prefix off" end
  if priority ~= "user" and priority ~= "own" then return nil, "bad priority" end
  if ns.Demo and ns.Demo.On() then return nil, "demo" end
  msg = ns.PlainCopy(msg)
  local part, bad = pullPart(st, msg, t)
  if not part then return nil, bad end
  local W = Wire()
  local c = W.Split(W.PROTOCOL, W.MAX_MID, part.T, part.subject, part.version, part.logical)
  if not c or #c > st.maxChunks then return nil, "too big" end
  local p = st.pull
  if priority == "user" then
    local kept = {}
    for _, at in ipairs(p.userAt) do if t - at < USER_WINDOW then kept[#kept + 1] = at end end
    p.userAt = kept
    if #kept >= p.userPerMinute then return nil, "too many user sends" end
  end
  local q = st.queue
  if #q >= p.queueCap then
    local oldest
    for i, item in ipairs(q) do if item.kind == "own" then oldest = i break end end
    if not oldest and priority == "user" then return nil, "full" end
    st.dropped = st.dropped + 1
    if oldest then table.remove(q, oldest) else return true end
  end
  if priority == "user" then p.userAt[#p.userAt + 1] = t end
  local pos
  if priority == "user" then
    pos = 1
    for i, item in ipairs(q) do if item.kind == "user" then pos = i + 1 end end
    if not sendClosed(st) then st.user = st.user + 1 end
  end
  enqueue(st, { kind = priority, msg = msg, parts = { part } }, pos)
  return true
end

-- The kinds table of a registered domain, or {}.
local function kindsOf(id)
  local spec = Comm.Registry.Domain(id)
  return spec and spec.kinds or {}
end

-- An action kind of a pull domain (rule "action" in its spec): its messages cancel and cover nothing.
local function actionKind(id, kind)
  local k = kindsOf(id)[kind]
  return type(k) == "table" and k.rule == "action"
end

-- d524 (f4390): a heard version covers the want of (kind, subject) when pull.coversVersion(kind, heard, wanted) says
-- so (a throw is recorded under the module and covers nothing); without it, when the versions are equal or the wanted
-- one is 0 or nil. Covered: the want goes and its askers are marked served.
local function pullHeard(st, kind, subject, version, t)
  local g = st.guard
  local w = g.wants[wantKey(kind, subject)]
  if not w then return end
  local covered
  if st.pull.coversVersion then
    covered = call(st.pull.coversVersion, kind, version, w.version) and true or false
  else
    covered = w.version == nil or tostring(w.version) == "0" or tostring(version) == tostring(w.version)
  end
  if covered then g:Heard(kind, subject, version, t) end
end

-- A pull message heard for (kind, subject, version): its want, and the want pull.covers maps it to, by d524's rule.
local function pullCover(st, kind, subject, version, t)
  pullHeard(st, kind, subject, version, t)
  if st.pull.covers then
    local k2, s2 = call(st.pull.covers, kind, subject, version)
    if type(k2) == "string" and s2 ~= nil then pullHeard(st, k2, s2, version, t) end
  end
end

-- HeardFor(title, id, kind, subject, version, t): someone else covered (kind, subject) inside a message the hub cannot
-- read (an R's ids): the want goes and its askers are marked served.
function Sync.HeardFor(title, id, kind, subject, version, t)
  local st, why = pullOf(title, id)
  if not st then return nil, why end
  if type(kind) ~= "string" or kindsOf(id)[kind] == nil or type(subject) ~= "string" then return nil, "bad want" end
  pullCover(st, kind, subject, version, t)
  return true
end

-- Recent(title, id, subject, asker, t): this client served subject to asker within SERVED_WINDOW.
function Sync.Recent(title, id, subject, asker, t)
  local st = pullOf(title, id)
  if not st then return false end
  return st.guard:Recent(subject, asker, t) and true or false
end

-- NoteLimited(id): the registry refused a message of this domain at its limit (record and pull domains).
function Sync.NoteLimited(id)
  local st = D[id]
  if st then st.limited = st.limited + 1 end
end

-- Want(title, id, kind, subject, version, asker, role, t): adds or joins a want in the domain's guard, due after the
-- hub's answer delay (owner 0.5 s, peer by the peers heard); the wake pumps when it falls due.
function Sync.Want(title, id, kind, subject, version, asker, role, t)
  local st, why = pullOf(title, id)
  if not st then return nil, why end
  if role ~= "owner" and role ~= "peer" then return nil, "bad role" end
  if type(kind) ~= "string" or kindsOf(id)[kind] == nil or type(subject) ~= "string" or #subject < 1 or #subject > 64
     or type(asker) ~= "string" then
    return nil, "bad want"
  end
  local g = st.guard
  local k = wantKey(kind, subject)
  local new = not g.wants[k]
  if new then
    -- wantCap bounds the domain; askerShare bounds the wants one asker originates (f4391, d524)
    local n, mine = 0, 0
    for _, w in pairs(g.wants) do
      n = n + 1
      if w.origin == asker then mine = mine + 1 end
    end
    if n >= st.pull.wantCap or mine >= st.pull.askerShare then return nil, "full" end
  end
  local due = t + answerDelay(math.random(), peerCount(st, t), role == "owner")
  g:Want(kind, subject, version, asker, due)
  if new then g.wants[k].origin = asker end
  addDue(st, due, t)
  return true
end

-- ---------- chunk headers (copy of CraftSync's mayCancel, cancelFor, restore and expireOpen; f1066, f1166) ----------
-- A header of a message in several chunks cancels covering wants before assembly. Each sender gets that for at most
-- HEADER_CAP unfinished messages at a time and HEADER_BUDGET new messages per HEADER_WINDOW; past either the header
-- cancels nothing. Later chunks of a message cancel only for what its first counted chunk named. What a header
-- cancelled comes back, and its askers lose the served mark it set, when the message does not complete within
-- PARTIAL_TIMEOUT. st.open[from][mid] = { at, what, undo = { { k, w, at }, ... } }; st.cancels[from] = { at, ... }.

local function whatOf(kind, subject, version)
  return tostring(kind) .. ":" .. tostring(subject) .. ":" .. tostring(version)
end

local function restore(st, o)
  local g = st.guard
  for _, u in ipairs(o.undo or {}) do
    if g.wants[u.k] == nil then g.wants[u.k] = u.w end
    local s = g.served[u.w.subject]
    for asker in pairs(u.w.askers) do
      if s and s[asker] == u.at then s[asker] = nil end
    end
  end
  o.undo = nil
end

-- Messages open PARTIAL_TIMEOUT or longer are given up: what their headers cancelled comes back. true if any did.
local function expireOpen(st, t)
  local back = false
  for from, open in pairs(st.open) do
    for mid, o in pairs(open) do
      if o.undo and t - o.at >= Wire().PARTIAL_TIMEOUT then
        restore(st, o)
        back = true
      end
      if t - o.at > HEADER_WINDOW then open[mid] = nil end
    end
    if next(open) == nil then st.open[from] = nil end
  end
  return back
end

local function armExpiry(st)
  if st.expiring then return end
  st.expiring = true
  ns.After(Wire().PARTIAL_TIMEOUT, function()
    st.expiring = false
    local t = ns.Compat.ServerTime()
    if expireOpen(st, t) then addDue(st, t, t) end
    for _, open in pairs(st.open) do
      for _, o in pairs(open) do if o.undo then return armExpiry(st) end end
    end
  end, MODULE)
end

local function mayCancel(st, from, h, what, t)
  expireOpen(st, t)
  local open = st.open[from]
  if not open then
    open = {}
    st.open[from] = open
  end
  local o = open[h.mid]
  if o then
    if o.what ~= what then return nil end
    o.at = t
    return o
  end
  local n = 0
  for _ in pairs(open) do n = n + 1 end
  local kept = {}
  for _, at in ipairs(st.cancels[from] or {}) do
    if t - at < HEADER_WINDOW then kept[#kept + 1] = at end
  end
  st.cancels[from] = kept
  if n >= HEADER_CAP or #kept >= HEADER_BUDGET then return nil end
  kept[#kept + 1] = t
  o = { at = t, what = what }
  open[h.mid] = o
  return o
end

-- A finished message from `from` closes its open headers: nothing to restore.
local function closeOpen(st, from, msg)
  local open = from and st.open[from]
  if not open then return end
  local subject, version = wireSubject(st, msg)
  local what = whatOf(msg.t, subject, version)
  for mid, o in pairs(open) do
    if o.what == what then open[mid] = nil end
  end
end

-- role = "round" | "digest" | "ask" | "record"; called from the domain's handle (after the registry's checks).
function Sync.Handle(id, role, msg, fromKey, t)
  local st = D[id]
  local h = st and st.store and H[role]
  if not h or type(msg) ~= "table" then return end
  if fromKey then st.heard[fromKey] = t end
  closeOpen(st, fromKey, msg)
  h(st, msg, fromKey, t)
  pump(st)
end

-- HeardChunk(id, header, t, fromKey): the registry calls it for each chunk of a message in several chunks, before
-- assembly and before the authority check, so the record rule is applied here: put needs subject == sender, officer
-- needs an officer sender. A record header with a version beyond now + FUTURE cancels nothing (f1078).
function Sync.HeardChunk(id, h, t, from)
  local st = D[id]
  if not st or not (st.store or st.pull) or type(h) ~= "table" or type(from) ~= "string" then return end
  local kind = tostring(h.t):match("%.(.+)$")
  if not kind then return end
  local subject, version = h.subject, h.version
  if st.pull then
    -- an action kind cancels nothing; a put or officer kind only from a sender its rule allows (f4373, f4392)
    local k = kindsOf(id)[kind]
    local rule = type(k) == "table" and k.rule
    if rule == "action" then return end
    if rule == "put" and Wire().Key(subject) ~= from then return end
    if rule == "officer" and not Comm.IsOfficer(from) then return end
  end
  if kind == st.kinds.record then
    version = tonumber(version)
    if not validRev(version) or version > t + Wire().FUTURE then return end
    if st.rule == "put" and Wire().Key(subject) ~= from then return end
    if st.rule == "officer" and not Comm.IsOfficer(from) then return end
  end
  local o = mayCancel(st, from, h, whatOf(kind, subject, version), t)
  if not o then return end
  local g, before = st.guard, {}
  for k, w in pairs(g.wants) do before[k] = w end
  if kind == st.kinds.record then
    local mine = st.store.get(subject)
    if version > ((mine and mine.rev) or 0) then g:Heard(st.kinds.ask, subject, 0, t) end
  end
  if st.pull then pullCover(st, kind, subject, version, t) else g:Heard(kind, subject, version, t) end
  for k, w in pairs(before) do
    if g.wants[k] ~= w then
      o.undo = o.undo or {}
      o.undo[#o.undo + 1] = { k = k, w = w, at = t }
    end
  end
  if o.undo then armExpiry(st) end
end

-- The owner edited records[key]: mint a rev and hash now; the record goes out once the roster is known.
local function maxRecords(st) return tonumber(st.store.maxRecords) or MAX_RECORDS end

local function acceptable(st, h, msg, from)
  local k = st.kinds
  if msg.t ~= tostring(h.t):match("%.(.+)$") then return false end
  -- a digest part names its part id in the header subject (f1199); Handle gets it as msg.part
  if msg.t == k.digest and tostring(h.subject) ~= "-" then
    if not partId(h.subject) then return false end
    msg.part = h.subject
  end
  local subject, version = wireSubject(st, msg)
  if tostring(subject) ~= tostring(h.subject) or tostring(version) ~= tostring(h.version) then return false end
  if msg.t == k.round then
    -- one hash, or n 8-hex part hashes with n a power of two from 2 to MAX_PARTS
    local hash = msg.hash
    if type(hash) == "string" and #hash > 8
       and (#hash % 8 ~= 0 or not validParts(#hash / 8) or not hash:match("^%x+$")) then
      return false
    end
  elseif msg.t == k.record then
    if type(msg.key) ~= "string" or not validRev(msg.rev) then return false end
    if st.rule == "officer" then
      -- d255: the record's author must be an officer. d247 (d): each (sender, author) pair introduces at most
      -- maxRecords new keys: per author, so a relay of other officers' records does not spend the sender's own (f1186);
      -- per sender too, so an officer who forges `by` spends only his own pair, never the named officer's (f1260)
      local author = Wire().Key(msg.by)
      if not author or not Comm.IsOfficer(author) then return false end
      -- d261: and each sender introduces at most 2 x maxRecords new keys across all authors (counted per sender, so
      -- bounded by the roster), so forgers spending their pairs never block the named officer's own records (f1270)
      if not st.store.get(msg.key) and ((st.introduced[tostring(from) .. "\0" .. author] or 0) >= maxRecords(st)
                                        or (st.sentNew[tostring(from)] or 0) >= 2 * maxRecords(st)) then
        return "cap"
      end
    else
      -- d247 (a, b): a self record's key is its author, on this session's roster; put: the sender, exactly
      if st.rule == "put" and msg.key ~= from then return false end
      local rows, _, _, known = Comm.Roster()
      if not known or not rows[msg.key] then return false end
    end
  elseif msg.t == k.digest or msg.t == k.ask then
    local entries = type(msg.entries) == "table" and msg.entries or {}
    if #entries > (tonumber(st.store.maxEntries) or MAX_ENTRIES) then return false end
    for _, e in ipairs(entries) do
      if type(e) ~= "table" or not validRev(e.rev) then return false end
    end
  end
  return true
end

-- A refused message: what its open header cancelled comes back at once.
local function restoreOpen(st, h, from, t)
  local open = from and st.open[from]
  local o = open and open[h.mid]
  if o then
    open[h.mid] = nil
    if o.undo then
      restore(st, o)
      addDue(st, t, t)
    end
  end
end

-- Accept(id, header, msg, fromKey, t) -> false when refused. The registry calls it after unpack, before the authority
-- check. The header must name what the payload holds (subject, version, kind; f1175), a put record's key must be the
-- sender's, revs must be valid (f1191), and the record and entry caps hold (f1192). What this message's headers
-- cancelled comes back at once when it is refused.
function Sync.Accept(id, h, msg, from, t)
  local st = D[id]
  if not st or not (st.store or st.pull) or type(h) ~= "table" then return true end
  local verdict
  if st.pull then
    -- f1175: the header names what the payload holds, through pull.subject(msg, t)
    local kind = tostring(h.t):match("%.(.+)$")
    local s, v
    if type(msg) == "table" and msg.t == kind then s, v = call(st.pull.subject, msg, t) end
    verdict = s ~= nil and tostring(s) == tostring(h.subject) and tostring(v or 0) == tostring(h.version)
  else
    verdict = acceptable(st, h, msg, from)
  end
  if verdict == true then return true end
  if verdict == "cap" and from and msg.rev <= t + Wire().FUTURE then
    -- f1262, d258: a record refused for the cap would be asked for again at every digest from that sender; remember
    -- (key, sender) so asks toward that sender stop for REFUSED_WINDOW. Another sender's copy is still asked for
    -- (f1264), nothing is listed in my own digest (f1265, f1268), and the table holds at most maxEntries (f1266).
    local rk = msg.key .. "\0" .. from
    if not st.refused[rk] then st.refusedN = st.refusedN + 1 end
    st.refusedSeq = st.refusedSeq + 1
    st.refused[rk] = { rev = msg.rev, at = t, seq = st.refusedSeq }
    local cap = tonumber(st.store.maxEntries) or MAX_ENTRIES
    local oldest
    for k, r in pairs(st.refused) do
      if t - r.at > REFUSED_WINDOW then
        st.refused[k], st.refusedN = nil, st.refusedN - 1
      elseif not oldest or r.seq < st.refused[oldest].seq then
        oldest = k
      end
    end
    if st.refusedN > cap and oldest then st.refused[oldest], st.refusedN = nil, st.refusedN - 1 end
  end
  restoreOpen(st, h, from, t)
  return false
end

-- Refused(id, h, from, t): the registry refused a message at unpack or authority; what its headers cancelled comes
-- back at once (f4373, f4392; record domains too, f4545).
function Sync.Refused(id, h, from, t)
  local st = D[id]
  if not st or type(h) ~= "table" then return end -- pull and record domains alike (f4545)
  restoreOpen(st, h, from, t)
end

-- Delivered(id, h, msg, from, t): a pull message passed Accept and the authority check, just before its handle. Its
-- sender counts as a peer, its open headers close (nothing to restore), and the message covers its wants (f4371).
function Sync.Delivered(id, h, msg, from, t)
  local st = D[id]
  if not st or not st.pull or type(h) ~= "table" then return end
  if from then st.heard[from] = t end
  local kind = tostring(h.t):match("%.(.+)$")
  if not kind or actionKind(id, kind) then return end
  local open = from and st.open[from]
  if open then
    local what = whatOf(kind, h.subject, h.version)
    for mid, o in pairs(open) do
      if o.what == what then open[mid] = nil end
    end
  end
  pullCover(st, kind, h.subject, h.version, t)
end

function Sync.Changed(id, key, t)
  local st = D[id]
  if not st or not st.store then return end
  mint(st, key, t)
  if not st.started and known() then start(st, t) end
  if st.started then queueOwnP(st, key) else st.pending[key] = true end
end

-- Still(id, want, t): the want is still worth sending. Never pulls from the guard.
function Sync.Still(id, want, t)
  local st = D[id]
  return (st and st.store and st.store.stillWanted(want, t)) and true or false
end

-- Build(id, want, t) -> entry | nil. Never pulls from the guard.
function Sync.Build(id, want, t)
  local st = D[id]
  if not st or not st.store or type(want) ~= "table" then return nil end
  local k = st.kinds
  if want.t == k.record then return makeEntry(st, st.store.build(want.subject, t), "answer") end
  if want.t == k.digest then
    local d, e = st.store.digest(t)
    local p, n = partId(want.subject)
    if not p then
      e = makeEntry(st, d, "answer")
    elseif type(d) == "table" then
      e = makeEntry(st, partMsg(d, p, n), "answer")
      local n2 = not e and partCount(st, d)
      if n2 and n2 > n then
        -- bucket p at the asker's n is too big: my finer parts q.n2 inside it, as one entry (f1211)
        local list = {}
        for q = p, n2, n do list[#list + 1] = partMsg(d, q, n2) end
        e = makeEntry(st, d, "answer", list)
      end
    end
    if not e then st.dropped = st.dropped + 1 end
    return e
  end
  if want.t == k.ask then
    local r = st.store.get(want.subject)
    return makeEntry(st, { t = k.ask, entries = { { key = want.subject, rev = tonumber(want.version) or 0,
                                                    hash = r and r.hash } } }, "answer")
  end
  return nil
end

-- A pull domain's next entry: Send entries in queue order (split now, each with its own mid), then the due wants:
-- stillWanted, then build (up to batch[kind] consecutive due wants of a batched kind in one build; a different want met
-- on the way waits in st.held). build answers a message or a list of up to maxParts messages (one entry of parts).
local function pullEntry(st, kind, msg, parts)
  local e = { kind = kind, msg = msg, parts = parts, t = msg.t, subject = parts[1].subject, version = parts[1].version }
  if split(st, e, Queue().NextMid()) then return e end
end

-- The first want of a Next: the held one while still wanted, else the guard's next due one.
local function firstWant(st, t, check)
  local w = st.held
  st.held = nil
  if w and not check(w) then w = nil end
  return w or st.guard:Next(t, check)
end

local function pullNext(st, t)
  local q = st.queue
  while #q > 0 do
    local item = table.remove(q, 1)
    local e = pullEntry(st, item.kind, item.msg, item.parts)
    if e then return e end
    st.dropped = st.dropped + 1
  end
  local p = st.pull
  local function check(w) return call(p.stillWanted, w, t) and true or false end
  local w = firstWant(st, t, check)
  while w do
    local wants, n = { w }, p.batch[w.t] or 1
    while #wants < n do
      local x = st.guard:Next(t, check)
      if not x then break end
      if x.t ~= w.t then st.held = x break end
      wants[#wants + 1] = x
    end
    local r = call(p.build, wants, t)
    local msgs = type(r) == "table" and (type(r.t) == "string" and { r } or r) or {}
    local parts = {}
    for i = 1, math.min(#msgs, p.maxParts) do
      local part = pullPart(st, msgs[i], t)
      if not part then parts = {} break end
      parts[#parts + 1] = part
    end
    if #parts > 0 then
      local e = pullEntry(st, "answer", msgs[1], parts)
      if e then return e end
    end
    w = st.held
    st.held = nil
    if not w then w = st.guard:Next(t, check) end
  end
  return nil
end

-- Next(id, t) -> entry | nil: own messages first, then the due wants (pulled from the guard). Consecutive due asks
-- go out as one R; a different want met on the way waits in st.held (copy of CraftSync's takeNext and batchAsks).
function Sync.Next(id, t)
  local st = D[id]
  if not st then return nil end
  if st.pull then return pullNext(st, t) end
  local q = st.queue
  while #q > 0 do
    local item = table.remove(q, 1)
    local e = makeEntry(st, item.msg or (item.build and item.build(t)), item.kind)
    if e then return e end
    st.dropped = st.dropped + 1 -- an own message that cannot be packed or split (over maxChunks): dropped, counted
  end
  local function check(w) return Sync.Still(id, w, t) end
  local w = firstWant(st, t, check)
  while w do
    local e
    if w.t == st.kinds.ask then
      local entries = {}
      local x = w
      while x do
        local r = st.store.get(x.subject)
        entries[#entries + 1] = { key = x.subject, rev = tonumber(x.version) or 0, hash = r and r.hash }
        if #entries >= (st.store.askBatch or ASK_BATCH) then break end
        x = st.guard:Next(t, check)
        if x and x.t ~= st.kinds.ask then st.held = x x = nil end
      end
      e = makeEntry(st, { t = st.kinds.ask, entries = entries }, "answer")
    else
      e = Sync.Build(id, w, t)
    end
    if e then return e end
    w = st.guard:Next(t, check)
  end
  return nil
end

function Sync.Guard(id)
  local st = D[id]
  return st and st.guard or nil
end

-- { open, cancels }: the header-cancel bookkeeping (st.open[from][mid], st.cancels[from]).
function Sync.Open(id)
  local st = D[id]
  return st and { open = st.open, cancels = st.cancels } or nil
end

function Sync.Stats(id)
  local st = D[id]
  if not st then return nil end
  local n = 0
  for _ in pairs(st.guard.wants) do n = n + 1 end
  return { on = st.on, why = st.why, started = st.started, wants = n, queued = #st.queue, dropped = st.dropped,
           refused = st.refusedN, user = st.user, sent = st.sent, attempts = st.attempts, limited = st.limited }
end
