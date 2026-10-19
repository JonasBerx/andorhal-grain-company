-- CommQueue: the GuildSync comm core's one send queue (plan r-20261005-guildsync-comm-core, sections 1 and 5).
-- Each prefix has its own state, pacing (one chunk per gap, no burst), backoff and stats, shared by every source on it
-- (d243). Sources take turns per entry, round robin in the order they were added: an entry's chunks stay together, and
-- a source is asked for its next entry only on its turn. The queue sends a source's chunks as given and never
-- re-encodes them. Sends go through Compat.SendAddon only.
--
-- Results: 0 sent; 3 or 8 retry after 1, 2 and 4 s, then abort (entry.onDrop); 11 held without counting a try; anything
-- else aborts. A closed gate holds the entry; PLAYER_REGEN_ENABLED, ADDON_RESTRICTION_STATE_CHANGED and a tick
-- (5 s, backing off to 60 s while an entry is held) resume it. A prefix the client refuses with 2 or 3 is off (D7):
-- nothing is sent on it.

local ADDON, ns = ...
ns.Comm = ns.Comm or {}
local Queue = ns.Comm.Queue or {}
ns.Comm.Queue = Queue

local MODULE = "Comms"
local TICK = 5
-- The channel each core prefix goes on (plan section 2). A source on another channel is refused.
local CHANNELS = { GSync = "GUILD", GSyncO = "OFFICER", GSyncB = "GUILD" }

local P = {}       -- prefix -> { on, refused, channel, sources, turn, current, from, cooling, stats }
local order = {}   -- prefixes in the order they were added
local mid = 0
local ticking = false

local function Wire() return ns.Comm.Wire end
local function now() return ns.Compat.ServerTime() end

-- Roster known: Comm.Roster's this-session table (CommRegistry.lua). Fails closed without it.
local function rosterKnown()
  if type(ns.Comm.Roster) ~= "function" then return false end
  return select(4, ns.Comm.Roster()) and true or false
end

-- ---------- status line and selftest ----------

local statusRegistered = false
-- The Comms entry is registered at load (its selftest is set below), its status line only once there is something to show.
local module = { name = MODULE }
ns.RegisterModule(module)

local function prefixState()
  local off = {}
  for _, prefix in ipairs(order) do
    local s = P[prefix]
    if not s.on then off[#off + 1] = "off, prefix refused (" .. tostring(s.refused) .. "): " .. prefix end
  end
  if #off > 0 then return table.concat(off, "; ") end
  local parts = {}
  for _, prefix in ipairs(order) do parts[#parts + 1] = prefix .. " sent " .. P[prefix].stats.sent end
  return "on, " .. table.concat(parts, ", ")
end

-- The Comms line: the prefix state above, then the refusals CommRegistry counted (f1084).
local function statusLine()
  local line = prefixState()
  local refused = 0
  local st = type(ns.Comm.Stats) == "function" and ns.Comm.Stats() or nil
  for reason, n in pairs(st and st.refused or {}) do
    -- a domain this client lacks is not a fault (f1317); nor is a chatty honest peer a module's limit held back
    if reason ~= "unknown" and reason ~= "limited" then refused = refused + n end
  end
  return line .. ", refused " .. refused
end

-- ---------- public ----------

function Queue.NextMid()
  mid = mid % Wire().MAX_MID + 1
  return mid
end

-- The channel a core prefix is fixed to, or nil for a prefix not named here (Comm.Register checks it, f4352).
function Queue.ChannelOf(prefix) return CHANNELS[prefix] end

function Queue.PrefixOn(prefix)
  local s = P[prefix]
  return (s and s.on) and true or false
end

-- ok, why. why: "prefix off" or Compat.CommGate's reason.
function Queue.Gate(prefix)
  if not Queue.PrefixOn(prefix) then return false, "prefix off" end
  if ns.Demo and ns.Demo.On() then return false, "demo" end -- demo sends nothing; entries wait in their sources
  return ns.Compat.CommGate(rosterKnown())
end

function Queue.Stats(prefix)
  local s = P[prefix]
  if not s then return { sent = 0, attempts = 0, aborted = 0, depth = 0 } end
  local st = s.stats
  return { sent = st.sent, attempts = st.attempts, lastResult = st.lastResult, aborted = st.aborted,
           depth = s.current and 1 or 0 }
end

local pumpPrefix

local function cool(prefix, s, seconds)
  s.cooling = true
  ns.After(seconds, function()
    s.cooling = false
    pumpPrefix(prefix)
  end, MODULE)
end

-- The backstop while the gate is closed: one tick at a time. A Pump, an event or a new source that finds the gate
-- closed arms it. A prefix that holds an entry behind the closed gate (s.current, or a source's has()) is held: it
-- keeps the tick going, with one global backoff of 5 s doubling to 60 s, reset when a pump finds the gate open or a
-- tick finds nothing held (f1187, f1212). A prefix that holds nothing is bounded (f1177, d249): after MISSES ticks in a
-- row that find its gate still closed, it arms no more ticks until a pump sees its gate open, so an idle queue behind a
-- gate that stays closed runs no timer; ADDON_RESTRICTION_STATE_CHANGED, PLAYER_REGEN_ENABLED and the next Pump resume
-- it. The sources are never asked for an entry while the gate is closed (has() only reads).
local MISSES = 2
local MAX_BACKOFF = 60
local inTick = false
local backoff = nil

local function anyHeld()
  for _, p in ipairs(order) do
    if P[p].held then return true end
  end
  return false
end

local function hold()
  if ticking then return end
  local delay = TICK
  if anyHeld() then
    backoff = backoff or TICK
    delay = backoff
  else
    backoff = nil
  end
  ticking = true
  ns.After(delay, function()
    ticking = false
    if anyHeld() then
      backoff = math.min((backoff or TICK) * 2, MAX_BACKOFF)
    else
      backoff = nil
    end
    inTick = true
    local good, err = pcall(Queue.Pump)
    inTick = false
    if not good then error(err, 0) end
  end, MODULE)
end

-- The next entry, from the source whose turn it is first; one with nothing to send passes the turn on.
local function take(s, t)
  local n = #s.sources
  for k = 0, n - 1 do
    local idx = (s.turn - 1 + k) % n + 1
    local e = s.sources[idx].next(t)
    if e then
      s.from, s.turn = s.sources[idx], idx % n + 1
      e.i, e.tries = e.i or 1, e.tries or 0
      s.current = e
      return e
    end
  end
  return nil
end

-- Sends at most one chunk on this prefix, then cools down for the source's gap (or the retry delay).
pumpPrefix = function(prefix)
  local s = P[prefix]
  if not s or not s.on or #s.sources == 0 or s.cooling then return end
  local t = now()
  local W = Wire()
  if not Queue.Gate(prefix) then
    local held = s.current ~= nil
    for _, src in ipairs(s.sources) do
      if not held and src.has and src.has() then held = true end
    end
    s.held = held or nil
    if inTick then s.misses = (s.misses or 0) + 1 end
    if held or (s.misses or 0) < MISSES then hold() end
    return
  end
  s.held, s.misses, backoff = nil, nil, nil
  local e = s.current
  if not e then
    e = take(s, t)
    if not e then return end
  end
  local src = s.from
  if e.i > 1 and e.lastAt and t - e.lastAt >= W.PARTIAL_TIMEOUT
     and not (src.resplit and src.resplit(e, Queue.NextMid())) then
    s.current = nil
    if e.onDrop then e.onDrop(e, t) end
    return pumpPrefix(prefix)
  end
  local result = ns.Compat.SendAddon(prefix, e.chunks[e.i], s.channel)
  local st = s.stats
  st.attempts = st.attempts + 1
  if src.tried then src.tried(e, t) end
  st.lastResult = result
  local outcome = W.SendOutcome(result, e.tries + 1)
  local wait = src.gap or 1
  if outcome == "ok" then
    st.sent = st.sent + 1
    if src.sent then src.sent(e, e.i, t) end
    e.lastAt, e.tries, e.i = t, 0, e.i + 1
    if e.i > #e.chunks then
      s.current = nil
      if e.done then e.done(e.msg, t) end
    end
  elseif outcome == "retry" then
    e.tries = e.tries + 1
    wait = W.RetryDelay(e.tries)
  elseif outcome == "lockdown" then
    hold()
  else
    s.current = nil
    st.aborted = st.aborted + 1
    if e.onDrop then e.onDrop(e, t) end
  end
  cool(prefix, s, wait)
end

-- Pump(prefix) tries one prefix; Pump() tries every prefix once.
function Queue.Pump(prefix)
  if prefix then return pumpPrefix(prefix) end
  for _, p in ipairs(order) do pumpPrefix(p) end
end

-- source = { channel = "GUILD"|"OFFICER", gap = 1, next = fn(t) -> entry, resplit = fn(entry, mid) -> bool,
--            sent = fn(entry, i, t), tried = fn(entry, t) (optional, every send whatever its result),
--            has = fn() -> bool }. has is optional and read-only: true when next(t) would
-- return an entry now or the source holds one; it keeps the tick going while the gate is closed. Registers the
-- prefix; true, or nil and why. Several sources may share a prefix (and its channel); each is added once.
function Queue.AddSource(prefix, source)
  if type(prefix) ~= "string" or type(source) ~= "table" or type(source.next) ~= "function" then return nil, "bad source" end
  local want = CHANNELS[prefix]
  if source.channel ~= "GUILD" and source.channel ~= "OFFICER" then return nil, "bad channel" end
  if want and source.channel ~= want then return nil, "wrong channel" end
  Queue.EnsurePrefix(prefix)
  local s = P[prefix]
  if s.channel and source.channel ~= s.channel then return nil, "wrong channel" end
  local known = false
  for _, other in ipairs(s.sources) do if other == source then known = true end end
  if not known then s.sources[#s.sources + 1] = source end
  s.channel = source.channel
  -- gate closed: the tick tries the new source once it opens; gate open: the caller's Pump sends it, so nothing idle
  -- stays armed (f1187)
  if s.on and not Queue.Gate(prefix) then hold() end
  return s.on and true or nil, (not s.on) and "prefix off" or nil
end

-- Shows the one Comms status line, the first time there is something to show: a prefix off, a refusal.
function Queue.ShowStatus()
  if statusRegistered then return end
  statusRegistered = true
  module.status = statusLine
end

-- /gsync selftest: read only (has() only reads, by the source contract above). The refusal check walks `order`, so a
-- prefix nobody has registered is not checked: GSyncO is named in CHANNELS but registered only by module officers
-- domains (audience officers, run r-20261014-r8), and only then can a refused GSyncO show here.
function module.selftest()
  local fails, refused = {}, {}
  for _, prefix in ipairs(order) do
    local s = P[prefix]
    if not s.on then refused[#refused + 1] = prefix .. " (" .. tostring(s.refused) .. ")" end
  end
  if #refused > 0 then fails[#fails + 1] = "prefix refused: " .. table.concat(refused, ", ") end
  local Version = ns.Comm.Version
  local sent, dropped = false, nil
  if Version and Version.AdvertSent then sent, dropped = Version.AdvertSent() end
  if dropped ~= nil then fails[#fails + 1] = "advert dropped (result " .. tostring(dropped) .. ")" end
  if #fails > 0 then return "fail", table.concat(fails, "; ") end
  if ns.Demo and ns.Demo.On() then return "wait", "demo on: sends held" end
  local open, why = ns.Compat.CommGate(true)
  if not open then
    -- IsInGuild may come back secret under a restriction (q208): say so, as Roster.lua does, not "not in a guild"
    if why == "guild" and ns.Compat.EncounterRestricted() then return "wait", "restricted (lockdown or encounter)" end
    if why == "guild" then return "wait", "not in a guild" end
    if why == "time" then return "wait", "no server time" end
    return "wait", tostring(why)
  end
  if not rosterKnown() then return "wait", "roster not known" end
  if not sent then return "wait", "version advert not sent yet" end
  local queued = 0
  for _, prefix in ipairs(order) do
    local s = P[prefix]
    if s.current then queued = queued + 1 end
    for _, src in ipairs(s.sources) do
      if src.has and src.has() then queued = queued + 1 end
    end
  end
  local _, partial = ns.Comm.Roster()
  local how, confirmed = ns.Comm.OfficerRule()
  local rule = how == "flags" and (confirmed and "rank flags" or "rank flags, flag 3 assumed")
    or how == "fallback" and "fallback: top three ranks" or "unknown: ranks not ready"
  local officer = partial and ("unknown (partial roster, " .. rule .. ")")
    or ((ns.Comm.SelfIsOfficer() and "yes" or "no") .. " (" .. rule .. ")")
  return "pass", "advert sent, queue " .. queued .. ", officer " .. officer
end

-- Registers a prefix with the client once (send and receive share it) and records whether it is on (D7).
-- Returns PrefixOn(prefix).
function Queue.EnsurePrefix(prefix)
  if P[prefix] then return P[prefix].on end
  local r = ns.Compat.RegisterAddonPrefix(prefix)
  local s = { on = not (r == 2 or r == 3), refused = r, sources = {}, turn = 1,
              stats = { sent = 0, attempts = 0, aborted = 0 } }
  P[prefix] = s
  order[#order + 1] = prefix
  if not s.on then Queue.ShowStatus() end
  return s.on
end

-- ---------- events (own frame, D8) ----------

local spec = { events = { "PLAYER_REGEN_ENABLED", "ADDON_RESTRICTION_STATE_CHANGED" } }

local function onEvent()
  Queue.Pump()
  ns.CheckGate() -- module addons hear a gate change (M.On "commGate")
end

local frame = ns.Compat.CreateFrame("Frame")
if frame then
  for _, event in ipairs(spec.events) do pcall(frame.RegisterEvent, frame, event) end -- unknown events throw
  frame:SetScript("OnEvent", function(...) ns.Safe(MODULE, onEvent, ...) end)
end
