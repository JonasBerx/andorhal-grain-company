-- CommVersion: the GuildSync comm core's version advert (plan r-20261005-guildsync-comm-core, section 4).
-- One ver.A on GSync per login, U(5, 30) s after the roster is known, and only while GSync is on (D7: the crafting
-- worlds keep it off, so they send nothing). Payload ver.A:<addonVersion>:<proto list>. No ask (ver.Q is dropped).
-- Last seen: any accepted message on any prefix (CommRegistry calls Version.Seen). Kept in memory and written to
-- GuildSyncDB3.comm.versions[guildKey] at PLAYER_LOGOUT only (D4). Per guild (API 8, f6201): guildKey is LinksStore's
-- "<guild>-<realm>" from the last rosterRead with a guild name; no name, no load, prune or write. The saved table of
-- that guild merges in at that rosterRead; a full read prunes keys off the roster. versionsFormat 2 marks the per-guild
-- shape; an older flat table is dropped once at login (pre-launch, no migration).
-- Module list (R7 Task 5): a second queue entry right after ver.A on hub domain ver-m, payload
-- ver-m.L:<id>=<version>,... (loaded suite addons from ns.SUITE, never the hub) or ver-m.L:-. A ver.A clears the
-- sender's list; a 0.12 client counts ver-m.L as "unknown" and goes on.
-- Update available: a newer proto from anyone (NoteNewer), or a higher addon version from an officer only (R8).
-- One ns.Say per session; after that the Version status line says it.

local _, ns = ...
ns.Comm = ns.Comm or {}
local Comm = ns.Comm
local Version = Comm.Version or {}
Comm.Version = Version

local MODULE = "Version"
local PREFIX = "GSync"
local POLL, POLL_MAX = 1, 60 -- looks for "roster known": after 1 s, then doubling up to once a minute (f1177)
local MAX_VERSION = 16 -- bytes in an addon version (f1194)
local MAX_MODS = 8 -- id=version pairs in one ver-m.L, counted before the suite filter (f3114)

local versions = {} -- key -> { name, addon, proto, seen, mods = { [suite id] = version } }
local update = false
local armed = false
local pending = {} -- the advert entries (ver.A, then ver-m.L), until the queue takes them
local advertSent, advertDropped = false, nil -- this login's advert: sent, or dropped with that send result
local guildKey -- "<guild>-<realm>" of the guild the in-memory map belongs to, or nil before a rosterRead with a name

local function Wire() return Comm.Wire end
local function now() return ns.Compat.ServerTime() end

-- -1 | 0 | 1, numeric per dotted part; a missing part counts as 0 ("0.9" == "0.9.0").
function Version.Compare(a, b)
  local pa, pb = {}, {}
  for part in tostring(a or ""):gmatch("[^.]+") do pa[#pa + 1] = tonumber(part) or 0 end
  for part in tostring(b or ""):gmatch("[^.]+") do pb[#pb + 1] = tonumber(part) or 0 end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  return 0
end

local function entry(key)
  local e = versions[key]
  if not e then
    local rows = Comm.Roster()
    e = { name = rows[key] and rows[key].name or key }
    versions[key] = e
  end
  return e
end

-- ns.SUITE, read at call time, or {}.
local function suiteList() return type(ns.SUITE) == "table" and ns.SUITE or {} end

-- The non-hub suite entry with this id, or nil.
local function suiteMod(id)
  for _, s in ipairs(suiteList()) do
    if type(s) == "table" and not s.hub and s.id == id then return s end
  end
end

local function copyMods(m)
  if type(m) ~= "table" then return nil end
  local out = {}
  for id, v in pairs(m) do out[id] = v end
  return out
end

local function copyEntry(e)
  return { name = e.name, addon = e.addon, proto = e.proto, seen = e.seen, mods = copyMods(e.mods) }
end

-- A copy: key -> { name, addon, proto, seen, mods } (mods a new table).
function Version.Versions()
  local out = {}
  for key, e in pairs(versions) do out[key] = copyEntry(e) end
  return out
end

function Version.UpdateAvailable() return update end

function Version.Seen(key, t)
  if type(key) ~= "string" then return end
  entry(key).seen = t or now()
end

local function flagUpdate()
  if update then return end
  update = true
  ns.Say("update available: a guild member runs a newer GuildSync.")
  ns.RegisterModule({ name = MODULE, status = function() return "update available" end })
end

-- A sender on a newer protocol (the registry refused its header as "newer"; crafting calls it too).
function Comm.NoteNewer(prefix, fromKey, proto)
  if type(prefix) ~= "string" or type(fromKey) ~= "string" or type(proto) ~= "number" then return end
  local e = entry(fromKey)
  if (tonumber(e.proto) or 0) < proto then e.proto = proto end
  if proto > Wire().PROTOCOL then flagUpdate() end
end

-- An addon version we accept: up to MAX_VERSION letters, digits, dots, dashes or underscores; so no "|" escape (f1194).
local function goodVersion(v)
  return type(v) == "string" and #v <= MAX_VERSION and v:match("^[%w%.%-_]+$") ~= nil
end

-- Chat text with every "|" doubled, so a stored string cannot open a texture, colour or link escape.
local function plain(v)
  return (tostring(v):gsub("|", "||"))
end

-- ver.A:<addonVersion>:<proto list> -> { addon, proto }
function Version.Unpack(logical)
  if type(logical) ~= "string" then return nil, "format" end
  local addon, list = logical:match("^ver%.A:([^:]+):([%d,]+)$")
  if not goodVersion(addon) then return nil, "format" end
  local top = 0
  for p in list:gmatch("%d+") do top = math.max(top, tonumber(p)) end
  if top < 1 then return nil, "format" end
  return { addon = addon, proto = top }
end

-- ver-m.L:- | ver-m.L:<id>=<version>,... -> { mods = { [suite id] = version } }. More than MAX_MODS pairs, a bad pair
-- or a bad version refuses the whole message; a well-formed id that is not in ns.SUITE is skipped.
function Version.UnpackMods(logical)
  if type(logical) ~= "string" then return nil end
  local list = logical:match("^ver%-m%.L:(.+)$")
  if not list then return nil end
  local mods = {}
  if list == "-" then return { mods = mods } end
  local n = 0
  for pair in (list .. ","):gmatch("([^,]*),") do
    n = n + 1
    if n > MAX_MODS then return nil end
    local id, v = pair:match("^([a-z][a-z0-9]*)=(.+)$")
    if not id or not goodVersion(v) then return nil end
    if suiteMod(id) then mods[id] = v end
  end
  return { mods = mods }
end

-- The open window redraws (debounced) after a heard advert, so the Guildmates tab follows it (f6207).
local function nudge()
  ns.Safe("Window", function() if ns.Window and ns.Window.Changed then ns.Window.Changed() end end)
end

Version.HANDLE = {
  A = function(msg, fromKey, t)
    local e = entry(fromKey)
    e.addon, e.proto, e.seen, e.mods = msg.addon, msg.proto, t, nil
    if Version.Compare(msg.addon, ns.VERSION) > 0 and Comm.IsOfficer(fromKey) then flagUpdate() end
    nudge()
  end,
}

Version.HANDLE_MODS = {
  L = function(msg, fromKey)
    entry(fromKey).mods = msg.mods
    nudge()
  end,
}

Comm.Register({ id = "ver", prefix = PREFIX, proto = 1, audience = "guild", owner = "round",
  kinds = { A = { rule = "round" } }, unpack = Version.Unpack, handle = Version.HANDLE })
Comm.Register({ id = "ver-m", prefix = PREFIX, proto = 1, audience = "guild", owner = "round", maxChunks = 2,
  kinds = { L = { rule = "round" } }, unpack = Version.UnpackMods, handle = Version.HANDLE_MODS })

-- ---------- the advert ----------

-- One more GSync source beside CommSync's; the queue shares the prefix's pace between them (d243). Each advert entry
-- is its own queue entry, so a closed gate between them cannot drop ver.A's partial (f3100).
local source = { channel = "GUILD", gap = 1, next = function()
  return table.remove(pending, 1)
end, has = function() return pending[1] ~= nil end }

-- { { id, version }, ... } in suite order: the loaded suite addons (never the hub) whose TOC version passes
-- goodVersion, at most MAX_MODS.
local function loadedMods()
  local out = {}
  local read = ns.Compat.AddOn
  for _, s in ipairs(suiteList()) do
    local a = type(s) == "table" and not s.hub and type(read) == "function" and read(s.folder)
    if a and a.loaded and goodVersion(a.version) and #out < MAX_MODS then out[#out + 1] = { s.id, a.version } end
  end
  return out
end

-- "<id>=<version>,..." for loadedMods(), or "-".
local function modList()
  local out = {}
  for _, m in ipairs(loadedMods()) do out[#out + 1] = m[1] .. "=" .. m[2] end
  return #out > 0 and table.concat(out, ",") or "-"
end

-- This client's own entry, built locally (its own advert echo is dropped): the roster name, ns.VERSION, its loaded
-- modules (the advert's list), seen now. The Guildmates tab and the Addons tab's counts merge it in.
function Version.Mine()
  local p = ns.Compat.Player()
  local g = ns.DB and ns.DB().guild
  local me = p.guid and type(g) == "table" and type(g.members) == "table" and g.members[p.guid]
  local mods = {}
  for _, m in ipairs(loadedMods()) do mods[m[1]] = m[2] end
  return { name = type(me) == "table" and me.name or p.name, addon = ns.VERSION, seen = now(), mods = mods }
end

local function sendAdvert()
  local chunks = Wire().Split(Wire().PROTOCOL, Comm.Queue.NextMid(), "ver.A", "-", 0,
    "ver.A:" .. tostring(ns.VERSION) .. ":" .. Wire().PROTOCOL)
  if not chunks then return end
  pending = { { chunks = chunks, kind = "own",
    done = function() advertSent = true end,
    onDrop = function() advertDropped = Comm.Queue.Stats(PREFIX).lastResult or "?" end } }
  local mods = Wire().Split(Wire().PROTOCOL, Comm.Queue.NextMid(), "ver-m.L", "-", 0, "ver-m.L:" .. modList())
  if mods then pending[2] = { chunks = mods, kind = "own" } end
  Comm.Queue.AddSource(PREFIX, source)
  Comm.Queue.Pump(PREFIX)
end

-- sent, droppedResult: whether this login's advert went out, or the send result it was dropped on (selftest).
function Version.AdvertSent()
  return advertSent, advertDropped
end

-- Arms the advert once, the first time the roster is known; true when armed.
local function arm()
  if armed then return true end
  if not select(4, Comm.Roster()) then return false end
  armed = true
  ns.After(5 + math.random() * 25, sendAdvert, MODULE)
  return true
end

-- Looks for "roster known" with a backoff (1, 2, 4 ... 60 s) so a client with no guild does not tick every second
-- (f1177). A roster event also looks (onEvent), so a late roster is seen without waiting for the next poll.
local function poll(delay)
  if arm() then return end
  ns.After(delay, function() poll(math.min(delay * 2, POLL_MAX)) end, MODULE)
end

-- One member's line: "Name: GuildSync 0.13, People 0.1, Annals 0.2, seen 20:14". Module names from ns.SUITE in
-- suite order (an id not in the suite is never printed); every stored value escaped once here.
function Version.Line(e, at)
  local parts = { plain(e.name or "?") .. ": GuildSync " .. plain(e.addon or "?") }
  if type(e.mods) == "table" then
    for _, s in ipairs(suiteList()) do
      local v = type(s) == "table" and not s.hub and e.mods[s.id]
      if v then parts[#parts + 1] = plain(s.name) .. " " .. plain(v) end
    end
  end
  local seen
  if e.seen then
    seen = date("%Y-%m-%d", e.seen) == date("%Y-%m-%d", at) and date("%H:%M", e.seen) or date("%Y-%m-%d %H:%M", e.seen)
  end
  parts[#parts + 1] = "seen " .. (seen or "?") -- date() answers nil for a time it cannot show (f6240)
  return table.concat(parts, ", ")
end

-- /gsync versions, open to everyone (q1041): one line per guildmate heard (never this client's own row).
function Version.Print()
  local keys = {}
  for key in pairs(versions) do keys[#keys + 1] = key end
  table.sort(keys)
  if #keys == 0 then ns.Say("versions: nobody heard yet.") return end
  local t = now()
  for _, key in ipairs(keys) do ns.Say(Version.Line(versions[key], t)) end
end

-- ---------- events (own frame, D8) ----------

local spec = { events = { "PLAYER_LOGIN", "PLAYER_LOGOUT", "GUILD_ROSTER_UPDATE" } }

-- comm.versions[guildKey] when it exists, else nil; never creates db.comm (D4).
local function savedTable()
  local db = ns.DB()
  local all = guildKey and type(db.comm) == "table" and type(db.comm.versions) == "table" and db.comm.versions
  return all and type(all[guildKey]) == "table" and all[guildKey] or nil
end

-- Drops every key not in rosterKeys ({ [key] = true }) from the in-memory map and from comm.versions[guildKey] only;
-- nothing without a guild key. -> the number of keys dropped from memory.
function Version.Prune(rosterKeys)
  if not guildKey or type(rosterKeys) ~= "table" then return 0 end
  local dropped = 0
  for key in pairs(versions) do
    if not rosterKeys[key] then versions[key], dropped = nil, dropped + 1 end
  end
  local saved = savedTable()
  for key in pairs(saved or {}) do
    if not rosterKeys[key] then saved[key] = nil end
  end
  return dropped
end

-- The versions saved by earlier sessions in this guild (f1176), checked like a heard advert; this session's entries win.
local function loadSaved()
  for key, e in pairs(savedTable() or {}) do
    if type(key) == "string" and type(e) == "table" and not versions[key] then
      -- f6240: seen only when finite, from 0 to a day ahead; the name plain and capped, else the key
      local seen, name = tonumber(e.seen), type(e.name) == "string" and ns.PlainLine(e.name, 48) or ""
      if seen and not (seen >= 0 and seen <= now() + 86400) then seen = nil end
      versions[key] = { name = name ~= "" and name or key,
                        addon = goodVersion(e.addon) and e.addon or nil,
                        proto = tonumber(e.proto), seen = seen }
      if type(e.mods) == "table" then
        local mods, n = {}, 0
        for id, v in pairs(e.mods) do
          if n < MAX_MODS and type(id) == "string" and suiteMod(id) and goodVersion(v) then mods[id], n = v, n + 1 end
        end
        if n > 0 then versions[key].mods = mods end
      end
    end
  end
end

-- The in-memory map into comm.versions[guildKey] (the other guilds' tables untouched); nothing without a guild key.
local function save()
  if not guildKey then return end
  local db = ns.DB()
  db.comm = type(db.comm) == "table" and db.comm or {}
  if db.comm.versionsFormat ~= 2 or type(db.comm.versions) ~= "table" then
    db.comm.versions, db.comm.versionsFormat = {}, 2
  end
  local out = {}
  for key, e in pairs(versions) do out[key] = copyEntry(e) end
  db.comm.versions[guildKey] = out
end

-- At each rosterRead (Roster.lua:80), the guild key as LinksStore derives it (LinksStore.lua:290-302). A new key
-- saves the old guild's map under the old key and starts the new one; the first key keeps what was heard before it.
-- A full read prunes the keys off the roster (AC11); a partial one prunes nothing.
local function onRosterRead(partial)
  local name, realm = ns.Compat.GuildInfo()
  if not name then return end
  realm = realm or ns.Compat.Player().realm
  if not realm then return end
  local key = name .. "-" .. realm
  if key ~= guildKey then
    if guildKey then
      save()
      versions = {}
    end
    guildKey = key
    loadSaved()
  end
  if partial then return end
  local rows, isPartial, _, known = Comm.Roster()
  if not known or isPartial then return end
  local keys = {}
  for k in pairs(rows) do keys[k] = true end
  Version.Prune(keys)
end
ns.On("rosterRead", onRosterRead, MODULE)

local function onEvent(_, event)
  if event == "PLAYER_LOGIN" then
    local db = ns.DB() -- the old flat table is dropped once (f6201); db.comm is never created here (D4)
    if type(db.comm) == "table" and db.comm.versionsFormat ~= 2 then db.comm.versions, db.comm.versionsFormat = {}, 2 end
    if Comm.Queue.PrefixOn(PREFIX) then poll(POLL) end
  elseif event == "GUILD_ROSTER_UPDATE" then
    if Comm.Queue.PrefixOn(PREFIX) then arm() end
  elseif event == "PLAYER_LOGOUT" then
    save()
  end
end

local frame = ns.Compat.CreateFrame("Frame")
if frame then
  for _, event in ipairs(spec.events) do pcall(frame.RegisterEvent, frame, event) end
  frame:SetScript("OnEvent", function(...) ns.Safe(MODULE, onEvent, ...) end)
end
