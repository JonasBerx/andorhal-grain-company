-- GuildSync crafting, CraftSync: the glue between the hub and the stored data. The directory is the hub's bulk record
-- domain "crafting" (M.Sync.Attach) and the work board its pull domain "crafting_b" (M.Sync.Pull); the hub packs,
-- splits, gates, paces, guards and assembles. Here: the stores, the board H timer, the digest window limits, the
-- login B, own records and the in-memory names table.
-- The directory half comes first; the board half at the end of the file adds its handlers to HANDLE and BOARD and
-- uses the locals declared above it.
--
-- Own characters are mirrored into GuildSyncCraftDir.crafters (a tombstone while sharing is off), so digests,
-- compares and answers treat them like any record; CraftStore.Merge refuses them from the wire.
local _, ns = ...
local CraftSync = {}
ns.CraftSync = CraftSync

local CraftWire, CraftStore, CraftBoard = ns.CraftWire, ns.CraftStore, ns.CraftBoard
local CraftView, CraftCompat, CraftHost = ns.CraftView, ns.CraftCompat, ns.CraftHost

local TICK = 5               -- roster check and own-record check
local OWN_DEBOUNCE = 10      -- a changed own record goes out 10 s after the change
local H_EVERY, H_JITTER = 900, 300
local PRUNE_EVERY = 3600
local DAY = 86400
local EMPTY_HASH = CraftStore.Adler32("")

local S = {
  loggedIn = false, started = false, rosterRef = nil, ownPending = false,
  did = 0, hGen = 0, dirty = false, version = 0,
  bAnswered = {}, selfCancelled = {}, selfCancels = {}, sessionStart = nil,
  stats = { received = 0, lastDigest = nil, newer = 0, fApplied = 0, fProvisional = 0, fHint = 0, userRefused = 0 },
}
-- version: raised by every new name; spellVersion: by a new spell name only (the recipe book reads spell names).
local names = { items = {}, spells = {}, version = 0, spellVersion = 0 }

-- HANDLE[T](msg, fromKey, now) for a board message the hub hands to crafting_b; the board half fills it.
local HANDLE = {}
-- Board half hooks: login(t) after the roster read, probe() at login, guildChat(text) on CHAT_MSG_GUILD, prune(t) hourly.
local BOARD = {}

-- ---------- small helpers ----------

local function crafters() return CraftCompat.Dir().crafters end
local function db() return CraftCompat.DB() end
local function floor(t) return math.floor(t) end

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function retention()
  local r = tonumber(db().settings.retention)
  if not r then return 30 end
  return r
end

local function stale(seen, t)
  local r = retention()
  return r > 0 and t - (tonumber(seen) or 0) > r * DAY
end

local function sharing() return db().settings.share ~= false end

-- An error inside a crafting handler is recorded as a module error (through CraftHost.After's ns.Safe) and never
-- stops the caller.
local function report(err)
  CraftHost.After(0, function() error(err, 0) end)
end

local function guarded(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then report(err) end
end

-- A late name: the UI's dirty flag, and the coalesced window refresh. The directory version stays.
local function namesChanged()
  S.dirty = true
  CraftHost.Changed()
end

-- A stored change: also a new directory version (CraftSync.Version), so the UI's id index is rebuilt.
local function changed()
  S.version = S.version + 1
  namesChanged()
end

-- Names of a stored directory record: recipe spell names, and item names already in the client's cache. Raises
-- names.version when one is new. Items not cached wait for late data (drawn rows ask for them); CraftCompat.ItemInfo
-- does not look up an uncached item, so learning a record never starts an item load (f1018).
local function learnRecord(rec)
  if type(rec) ~= "table" or type(rec.profs) ~= "table" then return false end
  local before = names.version
  for _, p in pairs(rec.profs) do
    for spell, item in string.gmatch(type(p) == "table" and p.packed or "", "(%d+)=(%d+)") do
      spell, item = tonumber(spell), tonumber(item)
      if not names.spells[spell] then
        local n = CraftCompat.SpellName(spell)
        if n then
          names.spells[spell] = n
          names.version, names.spellVersion = names.version + 1, names.spellVersion + 1
        end
      end
      if item ~= 0 and not names.items[item] then
        local n = CraftCompat.ItemInfo(item)
        if n then names.items[item] = n names.version = names.version + 1 end
      end
    end
  end
  return names.version ~= before
end

local function learnAll()
  local any = false
  for _, rec in pairs(CraftCompat.Dir().crafters) do
    if learnRecord(rec) then any = true end
  end
  return any
end

-- ---------- own records ----------

-- Professions.lua's table -> { [skill] = { rank, max, packed } }. A recipe that makes no item is "spell=0".
-- A profession keeps its first CraftWire.MAX_ROWS recipes by spell id, so its P still decodes on peers (d548); the
-- status line then says "capped".
local function ownProfs(profs)
  local out = {}
  for skill, p in pairs(type(profs) == "table" and profs or {}) do
    if type(skill) == "number" and type(p) == "table" and type(p.recipes) == "table" then
      local ids = {}
      for id in pairs(p.recipes) do if type(id) == "number" then ids[#ids + 1] = id end end
      table.sort(ids)
      if #ids > CraftWire.MAX_ROWS then
        for i = #ids, CraftWire.MAX_ROWS + 1, -1 do ids[i] = nil end
        S.capped = true
      end
      local parts = {}
      for i, id in ipairs(ids) do
        local item = p.recipes[id]
        parts[i] = string.format("%d=%d", id, type(item) == "number" and item or 0)
      end
      out[skill] = { rank = floor(tonumber(p.rank) or 0), max = floor(tonumber(p.max) or 0), packed = table.concat(parts, "/") }
    end
  end
  return out
end

-- The directory copy of an own character.
local function mirror(c, profs)
  local o = db().own[c.key]
  if not o then return end
  local share = sharing()
  crafters()[c.key] = { name = c.name, class = c.class or "", stamp = o.stamp, seen = o.seen or o.stamp,
                        gone = (not share) or nil, profs = share and profs or {} }
  learnRecord(crafters()[c.key])
end

local function nextDid()
  S.did = S.did % 9999 + 1
  return S.did
end

local function buildP(key)
  local r = crafters()[key]
  if not r or type(r.name) ~= "string" then return nil end
  local list = {}
  if not r.gone then
    local skills = {}
    for skill in pairs(r.profs or {}) do skills[#skills + 1] = skill end
    table.sort(skills)
    for _, skill in ipairs(skills) do
      local p = r.profs[skill]
      list[#list + 1] = { skill = skill, rank = p.rank, max = p.max, packed = p.packed }
    end
  end
  return { t = "P", name = r.name, class = r.class or "", stamp = r.stamp, seen = r.seen or r.stamp, profs = list }
end

-- The module handle once CraftSync.Attach has attached the directory domain "crafting" (M.Sync), else nil.
local dirM
-- The module handle once the board domain "crafting_b" is registered with its pull store, else nil; attachBoard is
-- set in the board half below.
local boardM, attachBoard

-- An own record whose profs hash changed goes to the hub, which mints its rev through store.stamp (D13, f4503).
local function publish(key, ts)
  if dirM then dirM.Sync.Changed("crafting", key, ts) end
end

-- One stamping path (f4518): with the directory on the hub, the hub's mint is the only bump, so the stamp
-- OwnRecord or Tombstone just set is put back to the one before (the mint then takes max(now, old + 1)).
local function keepStamp(o, old)
  if dirM and o then o.stamp = old end
end

-- Own records from GuildSyncDB3.chars. At login every own character gets seen = now (OwnRecord); otherwise only a
-- changed one is re-stamped. Sharing off turns each into a tombstone once. Only a changed hash is published
-- (OwnRecord's rule; the tombstone is a change to empty profs).
local function refreshOwn(ts, login)
  local own, share = db().own, sharing()
  for _, c in ipairs(CraftHost.MyChars()) do
    local profs = ownProfs(c.profs)
    local o = own[c.key]
    if share then
      if o or next(profs) ~= nil then
        local moved = not o or o.hash ~= CraftStore.ProfsHash(profs)
        local old = o and o.stamp
        if login or moved then CraftStore.OwnRecord(own, c.key, profs, ts) end
        if moved then keepStamp(own[c.key], old) end
        mirror(c, profs)
        if moved then publish(c.key, ts) end
      end
    elseif o then
      local moved = o.hash ~= EMPTY_HASH
      local old = o.stamp
      if moved then CraftStore.Tombstone(own, c.key, ts) keepStamp(o, old) end
      mirror(c, profs)
      if moved then publish(c.key, ts) end
    end
  end
end

-- The board H (D15): the board hash for crafting_b's round, sent by crafting's own timer.
local function sendH(t)
  if not boardM or not t then return end
  local _, dirHash = CraftStore.Digest(crafters(), t)
  local _, boardHash = CraftBoard.Digest(db().board, t)
  boardM.Comm.Send("crafting_b", { t = "H", dirHash = dirHash, boardHash = boardHash },
    "own")
end

-- ---------- names (late data) ----------

local function learnItem(itemID)
  itemID = CraftCompat.Plain(itemID)
  if type(itemID) ~= "number" then return end
  local name = CraftCompat.ItemInfo(itemID)
  if name and names.items[itemID] ~= name then
    names.items[itemID] = name
    names.version = names.version + 1
    namesChanged()
  end
end

local function learnSpell(spellID)
  spellID = CraftCompat.Plain(spellID)
  if type(spellID) ~= "number" then return end
  local name = CraftCompat.SpellName(spellID)
  if name and names.spells[spellID] ~= name then
    names.spells[spellID] = name
    names.version, names.spellVersion = names.version + 1, names.spellVersion + 1
    namesChanged()
  end
end

-- ---------- roster, login, timers ----------

-- Any heard board H restarts the window (HANDLE.Hboard), so a same-hash H suppresses mine.
local function scheduleH()
  S.hGen = S.hGen + 1
  local gen = S.hGen
  CraftHost.After(H_EVERY + math.random() * H_JITTER, function()
    if gen ~= S.hGen then return end
    scheduleH()
    sendH(CraftCompat.Now())
  end)
end

local function prune(t)
  local keys, partial = CraftHost.Roster()
  if #CraftStore.Prune(crafters(), keys, partial, t, retention()) > 0 then changed() end
  CraftBoard.Cleanup(db().board, db().alerted, t, CraftHost.MyKeys())
  if BOARD.prune then BOARD.prune(t) end
end

local function schedulePrune()
  CraftHost.After(PRUNE_EVERY, function()
    schedulePrune()
    local t = CraftCompat.Now()
    if t then prune(t) end
  end)
end

local function onFirstKnown(t)
  S.started = true
  S.sessionStart = S.sessionStart or floor(t)
  local ts = floor(t)
  learnAll() -- the saved directory's names
  refreshOwn(ts, true)
  prune(t)
  if BOARD.login then BOARD.login(t) end
  scheduleH()
  schedulePrune()
  changed()
end

-- A new GuildSyncDB3.guild table: leavers go (not on a partial table), online members count as seen now.
local function checkRoster(t)
  local keys, partial, ref, known = CraftHost.Roster()
  if not known or ref == S.rosterRef then return end
  S.rosterRef = ref
  local ts, cr, mine = floor(t), crafters(), CraftHost.MyKeys()
  for key, row in pairs(keys) do
    local r = cr[key]
    if r and row.online and not mine[key] and (r.seen or 0) < ts then r.seen = ts end
  end
  if not partial then
    local fav = db().favourites
    for key in pairs(fav) do if not keys[key] then fav[key] = nil end end
    if not S.started then return onFirstKnown(t) end
    if #CraftStore.Prune(cr, keys, false, t, retention()) > 0 then changed() end
  elseif not S.started then
    onFirstKnown(t)
  end
end

-- An own record that changed during the session goes out OWN_DEBOUNCE s later.
local function watchOwn()
  if S.ownPending or not sharing() then return end
  local own = db().own
  for _, c in ipairs(CraftHost.MyChars()) do
    local profs = ownProfs(c.profs)
    local o = own[c.key]
    if (o and o.hash ~= CraftStore.ProfsHash(profs)) or (not o and next(profs) ~= nil) then
      S.ownPending = true
      CraftHost.After(OWN_DEBOUNCE, function()
        S.ownPending = false
        local t = CraftCompat.Now()
        if not t then return end
        refreshOwn(floor(t), false)
        changed()
      end)
      return
    end
  end
end

local function tick()
  CraftHost.After(TICK, tick)
  local t = CraftCompat.Now()
  if t then
    checkRoster(t)
    if S.started then watchOwn() end
  end
end

local function onLogin()
  if S.loggedIn then return end
  S.loggedIn = true
  if BOARD.probe then guarded(BOARD.probe) end
  learnAll() -- the saved directory's names, with or without sync (d538)
  -- the directory lifecycle (roster, prune, own records) runs once the directory domain is attached (M.Sync)
  if not dirM then return end
  CraftHost.After(TICK, tick)
  local t = CraftCompat.Now()
  S.sessionStart = t and floor(t) or nil -- this character's login (d211)
  if t then checkRoster(t) end
end

-- ---------- public ----------

function CraftSync.Names() return names end
-- The directory version: raised by every stored change, not by a late name (the UI rebuilds its id index on it).
function CraftSync.Version() return S.version end
-- Read and clear: true once after each stored change (R9; the UI draws when it reads true).
function CraftSync.Dirty()
  local d = S.dirty
  S.dirty = false
  return d
end

-- The share switch changed: own records become tombstones (off) or real again (on), and go out.
function CraftSync.ShareChanged()
  local t = CraftCompat.Now()
  if not t or not S.started then return end
  refreshOwn(floor(t), false)
  changed()
end

-- "Clear recipes on this character": empties this character's directory; own records are mirrored back.
function CraftSync.ClearRecipes()
  CraftCompat.Dir().crafters = {}
  local t = CraftCompat.Now()
  if t then refreshOwn(floor(t), false) end
  changed()
end

-- The status counters (M6): received, newer, lastDigest and the F outcomes are counted here; sent, queue and
-- limited, refused come from M.Sync.Stats of each domain.
function CraftSync.Stats()
  local sent, attempts, queue, limited, refused = 0, 0, 0, 0, 0
  for id, M in pairs({ crafting = dirM or false, crafting_b = boardM or false }) do
    local st = M and M.Sync.Stats(id)
    if type(st) == "table" then
      sent = sent + (tonumber(st.sent) or 0)
      attempts = attempts + (tonumber(st.attempts) or 0)
      queue = queue + (tonumber(st.queued) or 0)
      limited = limited + (tonumber(st.limited) or 0)
      refused = refused + (tonumber(st.refused) or 0)
    end
  end
  local last = S.stats.lastDigest
  return {
    crafters = count(crafters()),
    lastDigest = last and date("%H:%M", floor(last)) or nil,
    sent = sent, attempts = attempts, received = S.stats.received, queue = queue,
    limited = limited, refused = refused, newer = S.stats.newer, now = CraftCompat.Now(),
    dirWhy = S.dirWhy, boardWhy = S.boardWhy,
  }
end

local function statusLine()
  local stats = CraftSync.Stats()
  local line = CraftView.StatusLine(stats)
  if stats.limited > 0 then line = line .. ", ignored by limit " .. stats.limited end
  if stats.refused > 0 then line = line .. ", refused " .. stats.refused end
  if stats.newer > 0 then line = line .. ", newer records " .. stats.newer end
  -- clicks the hub would not queue (f4520): "too many user sends" or "full"
  if S.stats.userRefused > 0 then line = line .. ", sends refused " .. S.stats.userRefused end
  if S.capped then line = line .. ", own recipes capped at " .. CraftWire.MAX_ROWS .. " per profession" end
  -- a refused domain (f4519): its why, e.g. "prefix off (GSyncB)"
  if stats.dirWhy then line = line .. ", directory not synced: " .. stats.dirWhy end
  if stats.boardWhy then line = line .. ", work board not synced: " .. stats.boardWhy end
  local s = S.stats
  if s.fApplied + s.fProvisional + s.fHint > 0 then
    -- what the F messages heard did (d207): taken, held as unconfirmed, or kept only as a "reported" hint
    line = line .. ", F applied " .. s.fApplied .. ", provisional " .. s.fProvisional .. ", hint " .. s.fHint
  end
  return line
end

-- ---------- events ----------

-- Addon messages and the send retries live on the comm core's own frames (D8, d245); this frame keeps late data and
-- guild chat.
local frameSpec = { events = { "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "SPELL_DATA_LOAD_RESULT",
                               "CHAT_MSG_GUILD" } }

local function onFrameEvent(_, event, ...)
  if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
    learnItem((...))
  elseif event == "SPELL_DATA_LOAD_RESULT" then
    learnSpell((...))
  elseif event == "CHAT_MSG_GUILD" then
    if BOARD.guildChat then BOARD.guildChat((...)) end
  end
end

-- ---------- the directory domain "crafting" (D13, D22, API 5) ----------
-- A bulk record domain on the hub's engine (CommSync): the hub runs digests, asks, rounds, the guard and the queue;
-- this store adapts the directory. stamp <-> rev: a record's rev is its stamp; its hash is CraftStore.ProfsHash of its
-- profs (own keys: the own hash, kept in the hub's form). Logical payloads: P is CraftWire's TYPES.P;
-- H is "H:<hash>", D "D:key,rev,hash,seen;...", R "R:key,rev;...".

local DIR_ROLE = { H = "round", D = "digest", R = "ask", P = "record" }

local function newerRev(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

local function dirKeys()
  local list = {}
  for key in pairs(crafters()) do list[#list + 1] = key end
  table.sort(list)
  return list
end

local function recordHash(key, r)
  local o = CraftHost.MyKeys()[key] and db().own[key]
  return (o and o.hash) or CraftStore.ProfsHash(r.profs or {})
end

local function encodeEntries(entries, full)
  local out = {}
  for i, e in ipairs(entries or {}) do
    local f = CraftWire.Escape(tostring(e.key)) .. "," .. floor(tonumber(e.rev) or 0)
    if full then f = f .. "," .. tostring(e.hash or "") .. "," .. floor(tonumber(e.seen) or 0) end
    out[i] = f
  end
  return table.concat(out, ";")
end

local dirStore = { recordRule = "copy", askBatch = 250,
                   kinds = { round = "H", digest = "D", ask = "R", record = "P" } }

function dirStore.get(key)
  local r = type(key) == "string" and crafters()[key]
  if not r then return nil end
  return { rev = r.stamp, hash = recordHash(key, r), seen = r.seen }
end

function dirStore.keys() return dirKeys() end

function dirStore.content(key)
  local r = crafters()[key]
  return r and CraftStore.ProfsString(r.profs or {}) or nil
end

-- The hub's mint: the own stamp and its directory mirror take the rev; the hash is the hub's form (D13).
function dirStore.stamp(key, rev, hash)
  local o = db().own[key]
  if o then o.stamp, o.hash = rev, hash end
  local r = crafters()[key]
  if r then r.stamp = rev end
  changed()
end

function dirStore.build(key) return buildP(key) end

function dirStore.merge(msg, t)
  if stale(msg.seen, t) then return false end
  local result = CraftStore.Merge(crafters(), msg, t, (CraftHost.Roster()), CraftHost.MyKeys())
  if result ~= "new" and result ~= "newer" then return false end
  S.stats.newer = S.stats.newer + 1
  learnRecord(crafters()[msg.key])
  changed()
  return true
end

function dirStore.round(t)
  local _, dirHash = CraftStore.Digest(crafters(), t)
  return { t = "H", hash = dirHash }
end

-- Entries { key, rev = stamp, hash, seen }; own keys report seen = t (f4505).
function dirStore.digest(t)
  local mine, entries = CraftHost.MyKeys(), {}
  for i, e in ipairs((CraftStore.Digest(crafters(), t))) do
    local r = crafters()[e.key]
    entries[i] = { key = e.key, rev = floor(tonumber(e.stamp) or 0), hash = recordHash(e.key, r),
                   seen = mine[e.key] and floor(t) or floor(tonumber(e.seen) or 0) }
  end
  return { t = "D", entries = entries }
end

-- CraftStore.Compare spoken in rev; ask entries { key, rev }, never for an own key or one off the roster (f1069).
function dirStore.compare(msg, t)
  S.stats.lastDigest = t
  local part = { t = msg.t, entries = {} }
  for i, e in ipairs(msg.entries or {}) do
    part.entries[i] = { key = e.key, stamp = tonumber(e.rev) or 0, seen = tonumber(e.seen) or 0 }
  end
  local send, ask = CraftStore.Compare(crafters(), part, t, retention())
  local roster, mine, out = (CraftHost.Roster()), CraftHost.MyKeys(), {}
  for _, a in ipairs(ask) do
    if roster[a.key] and not mine[a.key] then out[#out + 1] = { key = a.key, rev = a.stamp } end
  end
  return send, out
end

function dirStore.stillWanted(w, t) return CraftStore.StillWanted(crafters(), w, t) end

function dirStore.isOwn(key) return key ~= nil and CraftHost.MyKeys()[key] ~= nil end

-- A copy that beats mine: the hub re-mints above it from content(key), which is already my own profs.
function dirStore.heardOwn() end

function dirStore.pack(msg)
  if type(msg) ~= "table" then return nil end
  if msg.t == "P" then return (CraftWire.Pack(msg, CraftCompat.Now() or msg.stamp)) end
  if msg.t == "H" then return "H:" .. tostring(msg.hash or "") end
  if msg.t == "D" then return "D:" .. encodeEntries(msg.entries, true) end
  if msg.t == "R" then return "R:" .. encodeEntries(msg.entries, false) end
  return nil
end

function dirStore.subject(msg)
  if msg.t == "P" then return CraftStore.Key(msg.name), msg.stamp end
  return "-", 0
end

local MAX_PARTS = 64 -- the hub's digest part count at most (CommSync MAX_PARTS)
local function future(s, t) return tonumber(t) ~= nil and tonumber(s) > t + CraftWire.FUTURE end

local function dirUnpack(logical, _, t)
  if type(logical) ~= "string" then return nil end
  local kind, rest = logical:match("^(%u):(.*)$")
  if kind == "P" then
    local msg = CraftWire.Unpack(logical, t or CraftCompat.Now() or 0)
    local key = msg and CraftStore.Key(msg.name)
    if not key then return nil end
    msg.key, msg.rev, msg.hash = key, msg.stamp, CraftStore.ProfsHash(CraftStore.ProfsMap(msg.profs))
    return msg
  end
  if kind == "H" then
    -- one 8-hex hash, or 8-hex part hashes up to the hub's MAX_PARTS (f4541)
    if not rest:find("^%x+$") or #rest % 8 ~= 0 or #rest > 8 * MAX_PARTS then return nil end
    return { t = "H", hash = rest }
  end
  if kind == "D" or kind == "R" then
    local entries = {}
    for e in (rest .. ";"):gmatch("([^;]*);") do
      if e ~= "" then
        local k, r, h, s = e:match("^([^,]*),(%d+),?([^,]*),?(%d*)$")
        k = k and CraftWire.Unescape(k)
        if not k or k == "" then return nil end
        -- f4540: rev and seen of at most INT_DIGITS digits and a D hash of 8 hex, or the message is refused; an entry
        -- whose rev or seen lies past t + FUTURE is dropped (CraftWire's int and future rules)
        if #r > CraftWire.INT_DIGITS or #s > CraftWire.INT_DIGITS then return nil end
        if kind == "D" and not h:find("^%x%x%x%x%x%x%x%x$") then return nil end
        if not future(r, t) and not (s ~= "" and future(s, t)) then
          entries[#entries + 1] = { key = k, rev = tonumber(r), hash = kind == "D" and h or nil, seen = tonumber(s) or 0 }
        end
      end
    end
    return { t = kind, entries = entries }
  end
  return nil
end

-- Each kind counts received and goes to the hub; P first runs the own-key precheck (D13): an equal rev with another,
-- lower hash is re-minted here (the hub re-mints itself only when the copy is newer).
local function dirHandle(M)
  local handle = {}
  for kind, role in pairs(DIR_ROLE) do
    handle[kind] = function(msg, from, t)
      S.stats.received = S.stats.received + 1
      if kind == "P" and dirStore.isOwn(msg.key) then
        local mine = dirStore.get(msg.key)
        if mine and msg.rev == mine.rev and msg.hash ~= mine.hash
           and not newerRev(msg.rev, msg.hash, mine.rev, mine.hash) then
          publish(msg.key, t)
        end
      end
      M.Sync.Handle("crafting", role, msg, from, t)
    end
  end
  return handle
end

-- D16 (f4103, f4113): each domain's limit, with its own counters (CraftStore.NewLimit).
local DIR_RATES, DIR_WINDOW = { R = 6, P = 60 }, { round = "H", digest = "D", parts = true }
local BOARD_RATES, BOARD_WINDOW = { W = 6, C = 20, X = "C", F = 60, R = 6 }, { round = "H", digest = "B", parts = false }

local function attachDirectory(M)
  local ok, why = M.Comm.Register({
    id = "crafting", audience = "guild", bulk = true, maxChunks = 64,
    kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "copy" } },
    unpack = dirUnpack, handle = dirHandle(M),
    limit = CraftStore.NewLimit(DIR_RATES, DIR_WINDOW),
  })
  -- a refusal is not an error: "prefix off" (the client refused GSyncB) leaves the directory local
  if ok then ok, why = M.Sync.Attach("crafting", dirStore) end
  if ok then dirM = M else S.dirWhy = tostring(why) end
end

local attached = false -- CraftSync.Attach ran and made its frame

-- Called by CraftHost.Register with the module's handle M: makes the late-data and guild-chat frame (D9). Its events
-- are registered under pcall, never through the module's events (a refused event would fail the selftest).
function CraftSync.Attach(M)
  if attached or type(M) ~= "table" then return attached end
  if not dirM then attachDirectory(M) end
  if not boardM then attachBoard(M) end
  -- own characters' recipes (M.Professions through CraftHost.MyChars) reach the directory before sync runs (d538);
  -- and a changed one is published at once (the hub fires the event after recording); watchOwn is the backstop
  M.On("professions", function()
    local t = CraftCompat.Now()
    if not t then return end
    refreshOwn(floor(t), false)
    changed()
  end)
  local frame = CraftCompat.CreateFrame("Frame")
  if frame then
    for _, event in ipairs(frameSpec.events) do pcall(frame.RegisterEvent, frame, event) end -- unknown events throw
    frame:SetScript("OnEvent", function(...) guarded(onFrameEvent, ...) end)
    attached = true
  end
  return attached
end

CraftHost.RegisterModule({
  name = "Crafting",
  demo = CraftView.DemoState, -- /gsync demo: made-up crafters, recipes and work board (session only)
  events = { "PLAYER_LOGIN" },
  onEvent = function(event) if event == "PLAYER_LOGIN" then onLogin() end end,
  status = statusLine,
  -- /gsync selftest: read only (the saved variables are read raw; DB() and Dir() would create them)
  selftest = function()
    local sdb, sdir = CraftCompat.Saved()
    if not CraftHost.LoggedIn() then return "wait", "not logged in yet" end
    if type(sdb) ~= "table" or type(sdir) ~= "table" then return "fail", "saved tables not tables" end
    if not attached then return "wait", "not attached yet" end
    if not select(4, CraftHost.Roster()) then return "wait", "roster not known" end
    local t = CraftCompat.Now()
    if not t then return "wait", "no server time" end
    local crafters, open = 0, 0
    for _ in pairs(type(sdir) == "table" and type(sdir.crafters) == "table" and sdir.crafters or {}) do
      crafters = crafters + 1
    end
    for _, req in pairs(type(sdb) == "table" and type(sdb.board) == "table" and sdb.board or {}) do
      if type(req) == "table" and type(req.expiresAt) == "number" then
        local state = CraftBoard.State(req, t)
        if state == "open" or state == "claimed" then open = open + 1 end
      end
    end
    return "pass", "crafters " .. crafters .. ", open requests " .. open
  end,
})

-- ---------- board half ----------
-- W, C and X are bound to their sender (CraftBoard.Apply); F is relayed and joined. User actions are applied here
-- first, then queued ahead of every answer. Catch-up: a B goes out at login and on a differing H board hash; a peer
-- answers with F for each id that differs or that the asker lacks (inside the part's range) and asks with R:b for
-- the ids it lacks. One hash per request, CraftBoard.Hash, everywhere: F wants, the F chunk header (buildF sets
-- msg.hash, which CraftWire.Subject uses as the version, so hearing any chunk of the same F cancels a want), B and
-- R:b entries, and CraftBoard.StillWanted.

local ALERT_GAP = 30      -- chat line, sound and popup at most once per 30 s, each on its own clock
local CATCH_UP = 60       -- F learned this long after the login digest is batched into one line
local NO_HASH = "00000000" -- the R:b hash of an id I do not hold
local LINK_MAX = 500
local SELF_CANCEL_CAP, SELF_CANCEL_WINDOW = 10, 600 -- self-defence X cancels (d212)
local B_ONCE = 6 * 3600   -- a B entry is answered once per (id, asker, their hash) in this window (d209)

local A = { lastChat = nil, lastSound = nil, lastPopup = nil, catchUntil = nil, batch = {}, flushing = false }

local function board() return db().board end

-- A click's message (W, C, X, Keep's F, the self-defence X) on the board domain; the hub packs, paces and retries it.
-- A refusal is counted for the status line (f4520) and returned, so the click's answer does not claim it went out.
local function sendB(msg)
  local sent, why
  if boardM then sent, why = boardM.Comm.Send("crafting_b", msg, "user") else why = "not attached" end
  if not sent then S.stats.userRefused = S.stats.userRefused + 1 end
  return sent, why
end

-- A click's answer when the hub refused its send: the change stands here and reaches the guild at the next round.
-- With no board domain (the hub refused crafting_b) nothing will send it (f4529).
local function heldLine(why)
  if why == "not attached" then return "Saved here only: the work board is not syncing." end
  return "Saved here, but not sent now (" .. tostring(why) .. "). The guild sees it at the next sync."
end

-- The character playing now (CraftHost.Me), once the roster is known and lists it: key, name without realm.
local function me()
  local keys, _, _, known = CraftHost.Roster()
  local key, name = CraftHost.Me()
  if not known or not key or not keys[key] then return nil end
  return key, name
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- The canonical F of a stored request. A drop carries the dropper's key as its name (Apply keys it again).
local function buildF(req)
  local claims, drops = {}, {}
  for _, k in ipairs(sortedKeys(req.claims)) do claims[#claims + 1] = { name = req.claims[k].name, at = req.claims[k].at } end
  for _, k in ipairs(sortedKeys(req.drops)) do drops[#drops + 1] = { name = k, at = req.drops[k] } end
  return { t = "F", id = req.id, byName = req.byName, what = req.what, qty = req.qty, mats = req.mats, tip = req.tip,
           postedAt = req.postedAt, expiresAt = req.expiresAt, note = req.note ~= "" and req.note or nil,
           claims = claims, drops = drops, releasedAt = req.releasedAt or 0,
           finalKind = req.final and req.final.kind or nil, finalAt = req.final and req.final.at or nil,
           hash = CraftBoard.Hash(req) }
end

local function isOpen(req, t)
  local st = CraftBoard.State(req, t)
  return st == "open" or st == "claimed"
end

-- ---------- wants ----------

-- Is the character playing now the requester? Only its F is taken whole by holders (d206), so only it gets the
-- owner slot (f1032), and only it can send an X for its request.
local function isRequester(req)
  local key = CraftHost.Me()
  return key ~= nil and req ~= nil and key == req.by
end

-- An F answer. The requester's client answers in the owner slot (d206): its copy is the one others take whole.
-- A provisional copy is never relayed: the requester's word confirms it, not mine.
local function wantF(id, asker, t)
  local req = board()[id]
  if not req or req.provisional or not boardM or boardM.Sync.Recent("crafting_b", id, asker) then return end
  boardM.Sync.Want("crafting_b", "F", id, CraftBoard.Hash(req), asker, isRequester(req) and "owner" or "peer")
end

local function boardAsk(w) return { id = w.subject, hash = NO_HASH } end

-- The board B (f4508): one message of every entry, subject "-" (at most 185 entries, D15).
local function boardB(t)
  return { t = "B", did = nextDid(), pi = 1, pn = 1, entries = (CraftBoard.Digest(board(), t)) }
end

-- ---------- alerts ----------

-- Sound, glow and popup for one alert (or one batched line). Each switch is read now. The glow is set on every
-- alert, also when the saved flag is on already (the texture may be gone after a reload, f1017).
local function ring(req, t)
  local d = db()
  local s = d.settings
  if s.alertSound and (not A.lastSound or t - A.lastSound >= ALERT_GAP) then
    A.lastSound = t
    CraftCompat.PlaySound()
  end
  if s.alertGlow then
    d.glow = true
    CraftHost.SetGlow(true)
  end
  local ui = ns.CraftUI
  if s.alertPopup and type(ui) == "table" and type(ui.ShowAlert) == "function"
     and (not A.lastPopup or t - A.lastPopup >= ALERT_GAP) then
    A.lastPopup = t
    guarded(ui.ShowAlert, req)
  end
end

-- One chat line per ALERT_GAP (f1060); a held line is not printed later. The requester is named by the roster.
local function alertOne(req, t)
  db().alerted[req.id] = req.expiresAt
  if db().settings.alertChat and (not A.lastChat or t - A.lastChat >= ALERT_GAP) then
    A.lastChat = t
    CraftHost.Say(CraftView.AlertLine(req, names, (CraftHost.Roster())))
  end
  ring(req, t)
end

local function flushBatch()
  A.flushing = false
  local batch = A.batch
  A.batch = {}
  if #batch == 0 then return end
  local t = CraftCompat.Now() or batch[1].postedAt
  if db().settings.alertChat then
    A.lastChat = t -- the summary always prints (one per login); a line right after it waits for the gap
    CraftHost.Say(CraftView.CatchUpLine(#batch))
  end
  ring(batch[1], t)
end

-- A request this client just learned: alert when it is for me and not alerted yet. learnedBy "F" inside the
-- catch-up window joins the batch (one line when the window ends).
local function maybeAlert(req, t, learnedBy)
  if not CraftBoard.ShouldAlert(req, t, CraftHost.MyKeys(), CraftHost.CanMake, db().alerted) then return end
  if learnedBy == "F" and A.catchUntil and t <= A.catchUntil then
    db().alerted[req.id] = req.expiresAt
    A.batch[#A.batch + 1] = req
    if not A.flushing then
      A.flushing = true
      CraftHost.After(math.max(0, A.catchUntil - t), flushBatch)
    end
    return
  end
  alertOne(req, t)
end

-- ---------- receive ----------

local function apply(msg, from, t)
  local existed = board()[msg.id] ~= nil
  local didChange, why = CraftBoard.Apply(board(), msg, from, (CraftHost.Roster()), t, db().alerted, CraftHost.MyKeys())
  if didChange then changed() end
  return didChange, why, existed
end

-- d207 part 3 (d211, d212): a provisional copy in the name of the character playing now, not in
-- GuildSyncCraftDB.posted (d210) and posted after this session's login, is a provable forgery: this character is
-- online only here, and Post writes posted at once. One X cancel per id, at most SELF_CANCEL_CAP per
-- SELF_CANCEL_WINDOW; past the cap the copy is dropped here and nothing is sent. An older one is never cancelled on
-- its own: Mine shows it with Keep and Cancel. Only the requester's character can send an X its peers accept, so
-- alts do not answer.
local function selfDefend(id, t)
  local req = board()[id]
  if not req or not req.provisional or req.final then return end
  local key, name = me()
  if not key or req.by ~= key then return end
  if db().posted[id] then
    -- my own request, relayed back after a clear: my posted set is the requester's word, so it is confirmed (d210)
    if CraftBoard.Promote(board(), id, req.by, CraftBoard.Hash(req), t, db().alerted) or not board()[id] then changed() end
    return
  end
  if not S.sessionStart or req.postedAt < S.sessionStart then return end
  local now = floor(t)
  local msg = { t = "X", id = id, kind = "cancel", name = name,
                at = math.max(now, math.min(req.postedAt, now + CraftWire.FUTURE)) }
  if not S.selfCancelled[id] then
    local kept = {}
    for _, at in ipairs(S.selfCancels) do if t - at < SELF_CANCEL_WINDOW then kept[#kept + 1] = at end end
    S.selfCancels = kept
    if #kept >= SELF_CANCEL_CAP then
      board()[id] = nil
      db().alerted[id] = nil
      changed()
      return
    end
    kept[#kept + 1] = t
    S.selfCancelled[id] = t
    sendB(msg)
  end
  -- also a copy that arrives again after the X went out
  if CraftBoard.Apply(board(), msg, key, (CraftHost.Roster()), t, db().alerted, CraftHost.MyKeys()) then changed() end
end

-- The three F outcomes for /gsync status (d207): held as unconfirmed, kept only as a hint, or taken.
local function countF(req, from, didChange)
  local s = S.stats
  if req.provisional then
    s.fProvisional = s.fProvisional + 1
  elseif didChange and req.reported and req.reported.by == from then
    s.fHint = s.fHint + 1
  elseif didChange then
    s.fApplied = s.fApplied + 1
  end
end

HANDLE.W = function(msg, from, t)
  local didChange = apply(msg, from, t)
  local req = board()[msg.id]
  if didChange and req then maybeAlert(req, t, "W") end
end

HANDLE.C = function(msg, from, t) apply(msg, from, t) end
HANDLE.X = function(msg, from, t) apply(msg, from, t) end

HANDLE.F = function(msg, from, t)
  local didChange, why = apply(msg, from, t)
  if why ~= nil then return end -- refused: never answered back, so a refused F cannot ping-pong
  local req = board()[msg.id]
  if not req then return end
  countF(req, from, didChange)
  selfDefend(msg.id, t)
  if didChange then maybeAlert(req, t, "F") end
  if req.provisional then return end -- an unconfirmed copy has nothing to give back
  -- answer only when my F would change their copy under their rules (d207 part 1, f1031). The requester also
  -- answers a relayed final it never made: its F clears their "reported" hint (d208).
  local back = CraftBoard.WouldChange(msg, buildF(req), (CraftHost.Me()), (CraftHost.Roster()), t)
  if back or (isRequester(req) and msg.finalKind ~= nil and not req.final) then wantF(msg.id, from, t) end
end

-- An F for a B entry that differs from my copy or that the asker lacks. A client that is not the requester answers
-- one (id, asker, their hash) once per B_ONCE: a holder that will not take my F (the requester is offline) is not
-- offered it again every round (d209, f1031).
local function answerB(id, asker, theirHash, t)
  local req = board()[id]
  if not req then return end
  if not isRequester(req) then
    local k = id .. "\n" .. asker .. "\n" .. tostring(theirHash or "-")
    local at = S.bAnswered[k]
    if at and t - at < B_ONCE then return end
    S.bAnswered[k] = t
  end
  wantF(id, asker, t)
end

HANDLE.B = function(msg, from, t)
  local theirs = {}
  for _, e in ipairs(msg.entries or {}) do
    theirs[e.id] = e.hash
    -- the requester listing my provisional copy with the same hash confirms it (d207 part 2)
    local had = board()[e.id] ~= nil
    if CraftBoard.Promote(board(), e.id, from, e.hash, t, db().alerted) or (had and not board()[e.id]) then changed() end
  end
  local send, ask = CraftBoard.Compare(board(), msg, t)
  for _, id in ipairs(send) do answerB(id, from, theirs[id], t) end
  local roster = (CraftHost.Roster())
  for _, e in ipairs(ask) do
    -- an id whose requester is off the roster is never asked for (f1069), nor one I cancelled as a forgery
    local by = type(e.id) == "string" and string.match(e.id, "^%d+%-(.+)$") or nil
    if boardM and by and roster[by] and not S.selfCancelled[e.id] and not boardM.Sync.Recent("crafting_b", e.id, from) then
      boardM.Sync.Want("crafting_b", "R", e.id, 0, from, "peer")
    end
  end
end

HANDLE.Rb = function(msg, from, t)
  for _, e in ipairs(msg.entries) do
    if boardM then boardM.Sync.Heard("crafting_b", "R", e.id, 0) end -- someone asked already
    local req = board()[e.id]
    if req and CraftBoard.Hash(req) ~= e.hash then wantF(e.id, from, t) end
  end
end

HANDLE.Hboard = function(msg, from, t)
  scheduleH() -- any heard board H restarts my window (f4507)
  local _, boardHash = CraftBoard.Digest(board(), t)
  if boardM and msg.boardHash ~= boardHash and not boardM.Sync.Recent("crafting_b", "-", from) then
    boardM.Sync.Want("crafting_b", "B", "-", 0, from, "peer")
  end
end

-- ---------- the board domain crafting_b (D14, D15, D18, D22) ----------

-- d541: the hub's rules (W, C and X stay bound to their sender by CraftBoard.Apply, d203)
local BOARD_KINDS = { H = { rule = "round" }, B = { rule = "digest" }, R = { rule = "ask" }, F = { rule = "copy" },
                      W = { rule = "action" }, C = { rule = "action" }, X = { rule = "action" } }

local boardPull = { batch = { R = 250 }, queueCap = 400, wantCap = 400, askerShare = 200, userPerMinute = 30 }

function boardPull.pack(msg) return (CraftWire.Pack(msg, CraftCompat.Now() or 0)) end

-- One function for send and receive (D14, gate A correction 1): an F's version is the hash of what it makes when
-- applied to a scratch board under its requester's key (the hash is not on the wire); a B is "-".
function boardPull.subject(msg, t)
  if type(msg) ~= "table" then return nil end
  if msg.t == "F" then
    local by, tmp = CraftStore.Key(msg.byName), {}
    if not by or not CraftBoard.Apply(tmp, msg, by, (CraftHost.Roster()), t or CraftCompat.Now() or 0)
       or not tmp[msg.id] then return nil end
    return msg.id, CraftBoard.Hash(tmp[msg.id])
  end
  return CraftWire.Subject(msg)
end

function boardPull.build(wants, t)
  local w = wants[1]
  if w.t == "F" then
    local req = board()[w.subject]
    return req and buildF(req) or nil
  end
  if w.t == "B" then return boardB(t) end
  if w.t == "R" then
    local entries = {}
    for i, x in ipairs(wants) do entries[i] = boardAsk(x) end
    return { t = "R", kind = "b", entries = entries }
  end
  return nil
end

function boardPull.stillWanted(w, t)
  if w.t == "R" then return board()[w.subject] == nil end
  return CraftBoard.StillWanted(board(), w, t)
end

-- a heard F covers my ask for that id (d540: the board ask is R on crafting_b)
function boardPull.covers(kind, subject)
  if kind == "F" then return "R", subject end
  return nil
end

-- d524: an F covers only an F want of the same hash; every other kind covers on any version
function boardPull.coversVersion(kind, heard, wanted)
  if kind == "F" then return tostring(heard) == tostring(wanted) end
  return true
end

local function boardUnpack(logical, _, t)
  local msg = CraftWire.Unpack(logical, t or CraftCompat.Now() or 0)
  if type(msg) ~= "table" or not BOARD_KINDS[msg.t] or (msg.t == "R" and msg.kind ~= "b") then return nil end
  return msg
end

local function boardHandle(fn)
  return function(msg, from, t)
    S.stats.received = S.stats.received + 1
    fn(msg, from, t)
  end
end

attachBoard = function(M)
  local ok, why = M.Comm.Register({
    id = "crafting_b", audience = "guild", bulk = true, maxChunks = 64, kinds = BOARD_KINDS,
    actions = { W = { actor = "domain" }, C = { actor = "domain" }, X = { actor = "domain" } },
    unpack = boardUnpack,
    handle = { H = boardHandle(HANDLE.Hboard), B = boardHandle(HANDLE.B), R = boardHandle(HANDLE.Rb),
               F = boardHandle(HANDLE.F), W = boardHandle(HANDLE.W), C = boardHandle(HANDLE.C),
               X = boardHandle(HANDLE.X) },
    limit = CraftStore.NewLimit(BOARD_RATES, BOARD_WINDOW),
  })
  -- "prefix off" (the client refused GSyncB) leaves the board local, as for the directory
  if ok then ok, why = M.Sync.Pull("crafting_b", boardPull) end
  if ok then boardM = M else S.boardWhy = tostring(why) end
end

-- ---------- login, probe, guild chat ----------

BOARD.prune = function(t)
  for k, at in pairs(S.bAnswered) do if t - at >= B_ONCE then S.bAnswered[k] = nil end end
  for id, at in pairs(S.selfCancelled) do if t - at >= B_ONCE then S.selfCancelled[id] = nil end end
  local posted = db().posted
  for id, exp in pairs(posted) do
    if type(exp) ~= "number" or t > exp + 2 * DAY then posted[id] = nil end -- 2 days after expiry (d210)
  end
end

BOARD.login = function(t)
  CraftBoard.Cleanup(board(), db().alerted, t, CraftHost.MyKeys())
  if boardM then boardM.Comm.Send("crafting_b", boardB(t), "own") end
  A.catchUntil = t + CATCH_UP
end

-- Once per build: what the client offers for crafting orders and guild recipe lookups. Records only.
BOARD.probe = function()
  local d = db()
  local p = CraftCompat.Probe()
  local probe = type(d.probe) == "table" and d.probe or {}
  d.probe = probe
  if probe.checked and probe.build == p.build then return end
  probe.checked, probe.build = p.checked, p.build
  probe.craftingOrders = p.craftingOrders
  probe.guildRecipeLookup = p.guildRecipeLookup and true or false
  probe.guildTradeSkills, probe.guildRecipeQuery = p.guildTradeSkills, p.guildRecipeQuery
end

local LINK_TYPES = { trade = true, enchant = true, spell = true }

-- The first trade, enchant or spell link seen in guild chat. A secret text is skipped. Records only.
BOARD.guildChat = function(text)
  local d = db()
  if type(d.probe) == "table" and d.probe.firstLink then return end
  text = CraftCompat.Plain(text)
  if type(text) ~= "string" then return end
  text = text:sub(1, LINK_MAX)
  for link, kind in text:gmatch("(|H(%a+):[^|]*|h%[[^%]]*%]|h)") do
    if LINK_TYPES[kind] then
      if type(d.probe) ~= "table" then d.probe = {} end
      d.probe.firstLink = { text = link, at = CraftCompat.Now() or 0 }
      return
    end
  end
end

-- ---------- public: board actions ----------

local function ready()
  local t = CraftCompat.Now()
  if not t or not S.started then return nil, "Crafting sync has not started yet: the guild roster is not read." end
  local key, name = me()
  if not key then return nil, "Your character is not on the guild roster yet." end
  return floor(t), key, name
end

local POST_REFUSED = {
  ["too many open"] = "You have 10 open requests. Close one before you post another.",
  ["too many kept"] = "You have 15 open requests. Mark one done or cancel it before you post another.",
  ["same second"] = "You just posted. Wait a second and post again.",
  duration = "A request stays up 1, 4, 12, 24 or 48 hours.",
}

-- fields = { what, qty, mats, tip, hours, note } -> ok, line
function CraftSync.Post(fields)
  local t, key, name = ready()
  if not t then return false, key end
  if type(fields) ~= "table" then return false, "The request was not posted." end
  local req, why = CraftBoard.Post(board(), { by = key, byName = name, what = fields.what, qty = fields.qty,
    mats = fields.mats and true or false, tip = fields.tip or 0, hours = fields.hours, note = fields.note }, t)
  if not req then return false, POST_REFUSED[why] or "The request was not posted: check the item, quantity and tip." end
  db().posted[req.id] = req.expiresAt -- kept by Clear work board; tells my real requests from forged ones (d210)
  local sent, why = sendB({ t = "W", id = req.id, byName = req.byName, what = req.what, qty = req.qty,
    mats = req.mats, tip = req.tip, postedAt = req.postedAt, expiresAt = req.expiresAt,
    note = req.note ~= "" and req.note or nil })
  changed()
  if not sent then return true, heldLine(why) end
  return true, "Posted on the Work board."
end

-- Applies my own C or X here, then queues it. A refusal sends nothing and returns false; a send the hub refused
-- returns true and its why (f4520).
local function act(msg, key, t)
  local didChange, why = CraftBoard.Apply(board(), msg, key, (CraftHost.Roster()), t, db().alerted, CraftHost.MyKeys())
  if why ~= nil then return false end
  local sent, sendWhy = true, nil
  if didChange then
    sent, sendWhy = sendB(msg)
    changed()
  end
  return true, not sent and sendWhy or nil
end

function CraftSync.Claim(id)
  local t, key, name = ready()
  if not t then return false, key end
  local req = board()[id]
  if not req then return false, "That request is no longer on the Work board." end
  if req.by == key then return false, "You cannot take your own request." end
  if not isOpen(req, t) then return false, "That request is closed." end
  local holder = CraftBoard.Effective(req)
  local ok, held = act({ t = "C", id = id, name = name, at = t }, key, t)
  if not ok then return false, "That request cannot be taken now." end
  if held then return true, heldLine(held) end
  if holder and holder.key ~= key then
    -- the earlier claim stays the effective one; mine is next in line (f1024)
    local row = (CraftHost.Roster())[holder.key]
    return true, tostring(row and row.name or "Someone who left the guild")
      .. " is already making it; you are next if they drop it."
  end
  return true, "You are making it. The requester sees it now."
end

local CHANGE_LINE = {
  drop = "You dropped it. It is open again.",
  release = "Released. The request is open again.",
  done = "Marked done.",
  cancel = "Cancelled.",
}

-- d211: Keep on a request in my name that this computer never posted. It goes into my posted set, and my F, sent
-- as the requester, confirms it on every peer.
function CraftSync.Keep(id)
  local t, key = ready()
  if not t then return false, key end
  local req = board()[id]
  if not req then return false, "That request is no longer on the Work board." end
  if req.by ~= key or req.final then return false, "That request cannot be kept from this character." end
  if req.provisional and not CraftBoard.Promote(board(), id, req.by, CraftBoard.Hash(req), t, db().alerted) then
    changed() -- refused (f1080): the copy is gone from my board
    return false, POST_REFUSED["too many open"]
  end
  db().posted[id] = req.expiresAt
  local sent, why = sendB(buildF(req))
  changed()
  if not sent then return true, heldLine(why) end
  return true, "Kept. The guild now sees it as your request."
end

-- kind: drop (the claimer), release, done or cancel (the requester, from the character that posted).
function CraftSync.Change(id, kind)
  local t, key, name = ready()
  if not t then return false, key end
  local req = board()[id]
  if not req then return false, "That request is no longer on the Work board." end
  if not CHANGE_LINE[kind] then return false, "That change is not known." end
  if kind == "drop" then
    local c = req.claims and req.claims[key]
    if not c or c.at <= (req.drops[key] or -1) or c.at <= (req.releasedAt or 0) or req.final then
      return false, "You are not making that request."
    end
  else
    if req.by ~= key then
      local row = (CraftHost.Roster())[req.by]
      return false, "Log in on " .. tostring(row and row.name or CraftView.SafeText(req.byName)) .. " to change it."
    end
    if req.final then return false, "That request is closed." end
  end
  local ok, held = act({ t = "X", id = id, kind = kind, name = name, at = t }, key, t)
  if not ok then return false, "That change cannot be made now." end
  if held then return true, heldLine(held) end
  return true, CHANGE_LINE[kind]
end

-- "Clear work board and favourites (all your characters)".
function CraftSync.ClearBoard()
  local d = db()
  for _, k in ipairs({ "board", "alerted", "favourites" }) do
    for id in pairs(d[k]) do d[k][id] = nil end
  end
  A.batch = {}
  changed()
end
