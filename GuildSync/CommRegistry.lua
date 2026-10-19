-- CommRegistry: the GuildSync comm core's receive side (plan r-20261005-guildsync-comm-core, section 3).
-- Comm.Register takes a domain (or a whole-prefix family), Comm.Roster is this session's roster, Comm.IsOfficer the
-- officer rule (rank flags, Comm.OfficerRule). One CHAT_MSG_ADDON frame of its own (D8) runs the section 3 checks in
-- order; a refused message is ignored and counted in Comm.Stats().refused[reason], never in the module error log
-- (f1084). The count shows on the Comms line (CommQueue.lua).
--
-- Roster "known": the GuildSyncDB3.guild table differs from the one saved from the last session (seen when the
-- saved variables load), as in CraftHost.lua. Until then everything fails closed: the roster check refuses,
-- IsOfficer is false and Comm.Queue.Gate answers "roster not known".

local ADDON, ns = ...
ns.Comm = ns.Comm or {}
local Comm = ns.Comm
local Registry = Comm.Registry or {}
Comm.Registry = Registry

local MODULE = "Comms"
local CHANNELS = { guild = "GUILD", officers = "OFFICER" } -- audience -> channel (plan section 2)

local domains = {}   -- id -> spec
local prefixes = {}  -- prefix -> { channel, family = spec | nil, proto }
local refused = {}   -- reason -> count

local function Wire() return ns.Comm.Wire end
local function now() return ns.Compat.ServerTime() end

-- ---------- roster ----------

local loginGuild, snapped = nil, false -- the guild table saved from the last session
local cache = { ref = nil, rows = {} }

local function guildTable() -- reads only: never creates GuildSyncDB3 (selftests run before it loads)
  local db = ns.SavedDB and ns.SavedDB()
  local g = db and db.guild
  if type(g) == "table" then return g end
  return nil
end

-- rows, partial, tableRef, known. rows = { [key] = { name, class, online, prof1, prof2, rankIndex } }.
function Comm.Roster()
  local g = guildTable()
  if not g then return {}, false, nil, false end
  if cache.ref ~= g then
    local rows = {}
    for _, m in pairs(type(g.members) == "table" and g.members or {}) do
      local key = type(m) == "table" and Wire().Key(m.name) or nil
      if key then
        rows[key] = { name = m.name, class = m.class, online = m.online and true or false, prof1 = m.prof1,
                      prof2 = m.prof2, rankIndex = m.rankIndex }
      end
    end
    cache.ref, cache.rows = g, rows
  end
  return cache.rows, g.partial and true or false, g, (snapped and g ~= loginGuild) and true or false
end

-- The officer rule (run r-20261014-r8, plan Seams): Compat.OfficerRanks reads the rank flags; this keeps the session
-- state. It re-reads once per event: a new guild table, GUILD_RANKS_UPDATE, GUILD_ROSTER_UPDATE or PLAYER_GUILD_UPDATE
-- marks it dirty; a read that is not "flags" retries on the next event. Once "flags" has been read in this guild any
-- other answer (fallback, or unknown with numRanks 0) keeps the last good map (the rule never drops to the top three
-- mid-session). Before that, "unknown" holds no map. The map is kept per guild name..realm: a different guild resets
-- the rule (fix round 1, f4351). speak is the Officerchat Speak map read with it (the send gate, f4354).
local rule = { ref = nil, dirty = true, map = nil, how = "unknown", confirmed = false, good = false, guild = nil,
  speak = nil }

local function officerRule()
  local rows, _, g, known = Comm.Roster()
  if not known then return nil, "unknown", false, nil end -- reads nothing until this session's roster
  if g ~= rule.ref then rule.ref, rule.dirty = g, true end
  local guild = tostring(g.name) .. ".." .. tostring(g.realm)
  if guild ~= rule.guild then
    rule.guild, rule.good, rule.map, rule.how, rule.confirmed, rule.speak = guild, false, nil, "unknown", false, nil
    rule.dirty = true
  end
  if rule.dirty then
    local top
    for _, r in pairs(rows) do
      if type(r.rankIndex) == "number" and (not top or r.rankIndex > top) then top = r.rankIndex end
    end
    local ranks, how, _, _, confirmed, speak = ns.Compat.OfficerRanks(top)
    rule.dirty = false
    if how == "flags" or not rule.good then
      rule.map, rule.how, rule.confirmed, rule.speak = ranks, how, confirmed, speak
      rule.good = rule.good or how == "flags"
    end
  end
  return rule.map, rule.how, rule.confirmed, rule.speak
end

-- how ("flags" | "fallback" | "unknown"), confirmed (a client label names the flag). On ns only, not the public API.
function Comm.OfficerRule()
  local _, how, confirmed = officerRule()
  return how, confirmed
end

-- The roster must be known and not partial (fail closed), then the member's rank must be in the rule's map.
local function officerKey(key)
  local rows, partial, _, known = Comm.Roster()
  local r = key and rows[key]
  if not (known and not partial and r and type(r.rankIndex) == "number") then return false end
  local map = officerRule()
  return (map and map[r.rankIndex]) and true or false
end

-- true when the roster is known, the table is not partial and the member's rank is an officer rank (the flags rule).
function Comm.IsOfficer(name)
  return officerKey(Wire().Key(name))
end

-- This character's key: its roster row by GUID (Forever's UnitName can be the first name only), else its name.
-- Recomputed only when the roster table changes.
local mine = { ref = false, key = nil }
local function myKey()
  local g = guildTable()
  if mine.ref == g and mine.key then return mine.key end
  local p = ns.Compat.Player()
  local m = p.guid and g and type(g.members) == "table" and g.members[p.guid] or nil
  local key
  if type(m) == "table" and m.name then key = Wire().Key(m.name) else key = p.name and Wire().Key(p.name) or nil end
  mine.ref, mine.key = g, key
  return key
end

-- true when this character counts as an officer (IsOfficer's rule, for the Comms selftest).
function Comm.SelfIsOfficer()
  return officerKey(myKey())
end

-- true when this character's rank may speak in officer chat (the send gate, CommSync.lua; fix round 1 f4354). On ns
-- only. Fails closed like officerKey: the roster must be known and not partial.
function Comm.SelfMaySpeak()
  local rows, partial, _, known = Comm.Roster()
  local key = myKey()
  local r = key and rows[key]
  if not (known and not partial and r and type(r.rankIndex) == "number") then return false end
  local _, _, _, speak = officerRule()
  return (speak and speak[r.rankIndex]) and true or false
end

-- ---------- register ----------

-- Comm.Register(spec) -> spec | nil, why. A spec with receive is a whole-prefix family and gets the raw text.
function Comm.Register(spec)
  if type(spec) ~= "table" or type(spec.id) ~= "string" or type(spec.prefix) ~= "string" then return nil, "bad spec" end
  local audience = rawget(spec, "audience") -- read once, raw (fix round 1, f4352)
  local channel = CHANNELS[audience]
  if not channel then return nil, "bad audience" end
  local fixed = ns.Comm.Queue.ChannelOf and ns.Comm.Queue.ChannelOf(spec.prefix)
  if fixed and fixed ~= channel then return nil, "audience " .. audience .. " is not on " .. spec.prefix .. "'s channel" end
  if domains[spec.id] then return nil, "duplicate" end
  local family = type(spec.receive) == "function"
  if not family and (type(spec.kinds) ~= "table" or type(spec.unpack) ~= "function" or type(spec.handle) ~= "table") then
    return nil, "bad spec"
  end
  local p = prefixes[spec.prefix]
  if p and (p.channel ~= channel or p.family or (family and next(p.ids))) then return nil, "prefix taken" end
  if not p then
    p = { channel = channel, proto = 1, ids = {}, asm = Wire().NewAssembler() } -- one assembler per prefix: MAX_PARTIALS per sender per prefix
    prefixes[spec.prefix] = p
  end
  if family then p.family = spec end
  p.ids[spec.id] = true
  p.proto = math.max(p.proto, tonumber(spec.proto) or 1)
  domains[spec.id] = spec
  ns.Comm.Queue.EnsurePrefix(spec.prefix)
  return spec
end

-- This character's key (GuildSync.Comm.MyKey).
function Comm.MyKey() return myKey() end

-- ---------- module addons' domains (Api.lua: M.Comm.Register) ----------

local MODULE_PREFIX = { guild = "GSync", officers = "GSyncO" } -- audience -> the one prefix open to modules for it
local MODULE_MAX_CHUNKS = 16
local BULK_PREFIX, BULK_MAX_CHUNKS = "GSyncB", 64 -- bulk = true: guild audience only, its own lane (API 5)
local MODULE_MAX_DOMAINS = 4    -- per module: one module cannot crowd the GSync round-robin
local moduleOf = {}             -- domain id -> the title of the module that registered it

-- true | nil, why. The hub keeps its own copy: kinds and actions deep-copied, proto dropped, maxChunks clamped to 16,
-- unpack and every handle wrapped so a throw is recorded under the module's title. The id is the module id or
-- "<module id>_<1 to 4 letters or digits>". Audience guild on prefix GSync, or officers on GSyncO (run r8; Api.lua
-- gates officers to API 4); no receive family. bulk = true (API 5, guild only) rides GSyncB with maxChunks 1-64
-- (default 64); GSyncB is registered with the first bulk domain.
function Comm.RegisterModuleDomain(moduleId, title, spec)
  if type(spec) ~= "table" or type(moduleId) ~= "string" then return nil, "bad spec" end
  local id = spec.id
  local tail = type(id) == "string" and string.sub(id, 1, #moduleId + 1) == moduleId .. "_" and string.sub(id, #moduleId + 2) or nil
  if id ~= moduleId and not (tail and string.find(tail, "^[a-z0-9]+$") and #tail <= 4) then
    return nil, "the domain id must be \"" .. moduleId .. "\" or \"" .. moduleId .. "_\" and 1 to 4 letters or digits"
  end
  local audience = rawget(spec, "audience") -- read once, raw (fix round 1, f4352)
  local prefix = MODULE_PREFIX[audience]
  if not prefix then return nil, "audience " .. tostring(audience) .. " is not open to modules" end
  -- bulk, limit and maxChunks read raw too, so a field reached only through __index stays unseen, as the needs < 5
  -- filter sees it (fix round 1, f4393)
  local bulk, limit, maxChunks = rawget(spec, "bulk") == true, rawget(spec, "limit"), rawget(spec, "maxChunks")
  if bulk then
    if audience ~= "guild" then return nil, "bulk is open only to the guild audience" end
    if spec.prefix ~= nil and spec.prefix ~= BULK_PREFIX then return nil, "a bulk domain rides GSyncB" end
    prefix = BULK_PREFIX
  elseif spec.prefix ~= nil and spec.prefix ~= prefix then
    if spec.prefix == MODULE_PREFIX.guild or spec.prefix == MODULE_PREFIX.officers then
      return nil, "audience " .. audience .. " uses the prefix " .. prefix
    end
    return nil, "only the prefixes GSync and GSyncO are open to modules"
  end
  if spec.receive ~= nil then return nil, "a receive family is not open to modules" end
  if type(spec.kinds) ~= "table" or type(spec.unpack) ~= "function" or type(spec.handle) ~= "table" then
    return nil, "bad spec"
  end
  if limit ~= nil and type(limit) ~= "function" then return nil, "limit must be a function" end
  local handle = {}
  for kind, fn in pairs(spec.handle) do
    if type(fn) == "function" then handle[kind] = ns.Attributed(title, fn) end
  end
  local count = 0
  for _, owner in pairs(moduleOf) do if owner == title then count = count + 1 end end
  if count >= MODULE_MAX_DOMAINS then return nil, "too many domains" end
  local cap = bulk and BULK_MAX_CHUNKS or MODULE_MAX_CHUNKS
  local copy = {
    id = id, prefix = prefix, audience = audience, owner = ns.PlainCopy(spec.owner),
    kinds = ns.PlainCopy(spec.kinds), actions = ns.PlainCopy(spec.actions),
    maxChunks = math.floor(ns.Limit(maxChunks, cap, 1, cap)),
    unpack = ns.Attributed(title, spec.unpack), handle = handle,
    limit = limit and ns.Attributed(title, limit) or nil, -- a throw is recorded under the module (API 5)
  }
  local ok, why = Comm.Register(copy)
  if not ok then return nil, why end
  moduleOf[id] = title
  return true
end

-- The title of the module that registered domain id, or nil (a hub domain or none).
function Comm.ModuleOf(id) return moduleOf[id] end

-- A read-only view of a registered domain: { id, prefix, audience, owner, kinds, maxChunks } | nil.
function Registry.Domain(id)
  local spec = domains[id]
  if not spec then return nil end
  local kinds = {}
  for kind, k in pairs(type(spec.kinds) == "table" and spec.kinds or {}) do
    kinds[kind] = type(k) == "table" and { rule = k.rule } or k
  end
  return { id = spec.id, prefix = spec.prefix, audience = spec.audience, owner = spec.owner, kinds = kinds,
           maxChunks = spec.maxChunks }
end

-- A sender on a newer protocol. CommVersion.lua replaces this with the one that keeps it (Task 5).
function Comm.NoteNewer() end

function Comm.Stats()
  local out = {}
  for reason, n in pairs(refused) do out[reason] = n end
  return { refused = out }
end

-- ---------- receive (section 3) ----------

local function refuse(reason)
  refused[reason] = (refused[reason] or 0) + 1
  ns.Comm.Queue.ShowStatus()
end

-- Last seen: any accepted message on any prefix (plan section 4); Comm.Version keeps it.
local function seen(key, t)
  local V = ns.Comm.Version
  if key and V and type(V.Seen) == "function" then V.Seen(key, t) end
end

-- The authority rule for one kind; true when the message may be handled.
local function allowed(spec, kind, rule, h, msg, from)
  if rule == "put" then return Wire().Key(h.subject) == from end
  if rule == "officer" then return officerKey(from) end
  if rule == "action" then
    local a = type(spec.actions) == "table" and spec.actions[kind]
    if type(a) ~= "table" then return false end
    if a.actor == "sender" then return type(msg) == "table" and Wire().Key(msg[a.field]) == from end
    return a.actor == "domain"
  end
  return rule == "copy" or rule == "round" or rule == "digest" or rule == "ask"
end

-- A module domain's limit (API 5): true when the chunk may go on, or false, why ("limited" | "mismatch"). Called once
-- per (sender, mid) at the first chunk seen; a message in several chunks keeps its verdict, bound to that chunk's
-- t, subject, version and n, in p.verdicts[from][mid], at most Wire.MAX_PARTIALS per sender (oldest out). A verdict
-- ends on completion, PARTIAL_TIMEOUT after its last chunk, or (a true one) when the assembler no longer holds its
-- partial. A throw (recorded under the module by Attributed) counts as false.
local function limitVerdict(p, spec, kind, h, from, t)
  local W = Wire()
  p.verdicts = p.verdicts or {}
  local per = p.verdicts[from]
  local v = per and per[h.mid]
  if v then
    if t - v.last >= W.PARTIAL_TIMEOUT or (v.ok and not p.asm:Has(from, h.mid)) then
      per[h.mid], v = nil, nil
    elseif v.t ~= h.t or v.subject ~= h.subject or v.version ~= h.version or v.n ~= h.n then
      per[h.mid] = nil -- as the assembler does: drop the partial, seed none
      p.asm:Drop(from, h.mid)
      return false, "mismatch"
    else
      v.last = t
      return v.ok, "limited"
    end
  end
  local done, answer = pcall(spec.limit, from, kind, h.subject, h.version, h.n, t)
  local ok = done and answer == true
  if h.n > 1 then
    if not per then per = {} p.verdicts[from] = per end
    local count, oldestMid, oldestSeq = 0, nil, nil
    for mid, q in pairs(per) do
      count = count + 1
      if not oldestSeq or q.seq < oldestSeq then oldestMid, oldestSeq = mid, q.seq end
    end
    if count >= W.MAX_PARTIALS then per[oldestMid] = nil end
    p.verdictSeq = (p.verdictSeq or 0) + 1
    per[h.mid] = { ok = ok, t = h.t, subject = h.subject, version = h.version, n = h.n, last = t, seq = p.verdictSeq }
  end
  return ok, "limited"
end

local function onAddonMessage(prefix, text, channel, sender)
  local Plain = ns.Compat.Plain
  prefix, text, channel, sender = Plain(prefix), Plain(text), Plain(channel), Plain(sender)
  if type(prefix) ~= "string" then return end
  local p = prefixes[prefix]
  if not p then return end -- not ours: not counted
  if type(text) ~= "string" or type(sender) ~= "string" then return refuse("value") end
  if channel ~= p.channel or not ns.Comm.Queue.PrefixOn(prefix) then return refuse("channel") end
  local t = now()
  if p.family then
    -- the family's true return marks the sender as seen (f1164)
    if p.family.receive(text, sender, channel, t) == true then seen(Wire().Key(sender), t) end
    return
  end
  local from = Wire().Key(sender)
  if not from or from == myKey() then return end -- our own echo: not counted
  local rows, _, _, known = Comm.Roster()
  if not known or not rows[from] then return refuse("roster") end
  -- OFFICER is for officers only (run r-20261014-r8). A family returned above, but no OFFICER family exists and
  -- modules cannot register one. On a partial roster officerKey fails closed, so even an officer's OFFICER traffic
  -- is refused here until the roster is whole (f4206); a refused header cancels no want (HeardChunk comes later).
  if p.channel == "OFFICER" and not officerKey(from) then return refuse("officer") end
  local h, why = Wire().Header(text, p.proto)
  if not h then
    if why == "newer" then ns.Comm.NoteNewer(prefix, from, tonumber(text:match("^(%d+):"))) end
    return refuse(why or "format")
  end
  local id, kind = h.t:match("^([^.]+)%.(.+)$")
  local spec = id and domains[id]
  -- a well-formed message for a domain this client lacks (a module it does not run) is counted under its own reason,
  -- "unknown", which the Comms line leaves out of its refused sum (f1317): no climbing count for traffic that is fine
  if not spec then return refuse("unknown") end
  if spec.prefix ~= prefix then return refuse("domain") end
  local k = spec.kinds[kind]
  if type(k) ~= "table" or type(spec.handle[kind]) ~= "function" then return refuse("kind") end
  if h.n > (spec.maxChunks or 16) then return refuse("size") end
  -- a module's limit runs before HeardChunk and the assembler: a limited message cancels nothing and buffers nothing
  if spec.limit then
    local go, why = limitVerdict(p, spec, kind, h, from, t)
    if not go then
      if why == "limited" and ns.Comm.Sync and type(ns.Comm.Sync.NoteLimited) == "function" then ns.Comm.Sync.NoteLimited(id) end
      return refuse(why)
    end
  end
  -- a chunk of a message in several chunks may cancel wants before it is assembled (Comm.Sync, f1066)
  if h.n > 1 and ns.Comm.Sync and type(ns.Comm.Sync.HeardChunk) == "function" then ns.Comm.Sync.HeardChunk(id, h, t, from) end
  local logical, mismatch = p.asm:Add(from, text, t, p.proto)
  if not logical then
    if mismatch then return refuse(mismatch) end -- a chunk that disagrees with its mid's first chunk
    return -- more chunks to come
  end
  if p.verdicts and p.verdicts[from] then -- complete: its verdict ends
    p.verdicts[from][h.mid] = nil
    if next(p.verdicts[from]) == nil then p.verdicts[from] = nil end
  end
  local msg = spec.unpack(logical, h.proto, t)
  local Sync = ns.Comm.Sync
  if msg == nil then -- an unpack refusal gives back what its header cancelled, like the authority refusal (f4395)
    if Sync and type(Sync.Refused) == "function" then Sync.Refused(id, h, from, t) end
    return refuse("unpack")
  end
  -- a sync domain ties the header to the payload and bounds it (f1175, f1191, f1192)
  if Sync and type(Sync.Accept) == "function" and Sync.Accept(id, h, msg, from, t) == false then return refuse("sync") end
  if not allowed(spec, kind, k.rule, h, msg, from) then
    if Sync and type(Sync.Refused) == "function" then Sync.Refused(id, h, from, t) end
    return refuse("authority")
  end
  if Sync and type(Sync.Delivered) == "function" then Sync.Delivered(id, h, msg, from, t) end
  seen(from, t)
  spec.handle[kind](msg, from, t)
end

-- ---------- events (own frame, D8) ----------

local spec = { events = { "ADDON_LOADED", "PLAYER_LOGIN", "CHAT_MSG_ADDON", "GUILD_RANKS_UPDATE", "GUILD_ROSTER_UPDATE",
  "PLAYER_GUILD_UPDATE" } }

local function onEvent(_, event, arg1, ...)
  if event == "CHAT_MSG_ADDON" then
    onAddonMessage(arg1, ...)
  elseif event == "ADDON_LOADED" then
    if arg1 ~= ADDON or snapped then return end
    loginGuild, snapped = guildTable(), true
  elseif event == "PLAYER_LOGIN" then
    if not snapped then loginGuild, snapped = guildTable(), true end
  else -- GUILD_RANKS_UPDATE, GUILD_ROSTER_UPDATE, PLAYER_GUILD_UPDATE: re-read the officer rule on the next ask
    rule.dirty = true
  end
end

ns.Comm.Queue.EnsurePrefix("GSync") -- the core's guild prefix (plan section 2); the version advert rides it

local frame = ns.Compat.CreateFrame("Frame")
if frame then
  for _, event in ipairs(spec.events) do pcall(frame.RegisterEvent, frame, event) end -- unknown events throw
  frame:SetScript("OnEvent", function(...) ns.Safe(MODULE, onEvent, ...) end)
end
