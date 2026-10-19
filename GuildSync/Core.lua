-- GuildSync Core: saved data, module registry, event dispatch, /gsync, chat output, error capture.
--
-- The game keeps GuildSyncDB3 in
--   WTF/Account/<ACCOUNT>/SavedVariables/GuildSync.lua
-- and writes it on /reload and logout. Everything the addon records is read back in game.
--
-- Slash commands:
--   /gsync                 this character in one line, then one status line per module
--   /gsync probe           record and print what this client offers (build, interface number, feature flags)
--   /gsync scan            rescan everything that can be scanned right now
--   /gsync errors          list module errors recorded on this client
--   /gsync ui              open or close the window (also /gsync window, or left-click the minimap button)
--   /gsync minimap         show or hide the minimap button
--   /gsync selftest        one PASS/WAIT/FAIL line per module, then a total
--
-- Each command is a function in ns.Commands, so the window's buttons run exactly what the slash command runs.
--
-- The core only records: it sends no addon or chat messages and never reads combat data. Addon messages go
-- through the comm core (Comm*.lua) only.

local ADDON, ns = ...
local Compat = ns.Compat

ns.VERSION = Compat.ReleaseVersion("@project-version@")
ns.PREFIX = "|cffd4a24cGuildSync|r: "
ns.modules = {}
ns.missingEvents = {}

local MAX_ERRORS = 50

-- ---------- chat ----------

function ns.Say(msg)
  msg = ns.PREFIX .. tostring(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(msg)
  elseif print then
    print(msg)
  end
end

-- text with every | doubled, so it shows as written and cannot colour, link or texture a chat line or a font string.
function ns.Escape(text) return (string.gsub(tostring(text), "|", "||")) end

-- v as a number from lo to hi; default when v is nil, not a number, or NaN (math.min and math.max do not catch NaN in
-- every Lua 5.1: the explicit v ~= v test does).
function ns.Limit(v, default, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v then return default end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function ns.Count(t)
  local n = 0
  if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
  return n
end

-- A deep copy of plain data (tables, strings, numbers, booleans); functions, table keys and cycles are dropped.
-- What module addons hand in and get back (Api.lua, CommRegistry.lua) crosses as such a copy.
function ns.PlainCopy(v, seen)
  if type(v) ~= "table" then
    if type(v) == "function" then return nil end
    return v
  end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    if type(k) ~= "table" and type(k) ~= "function" then out[k] = ns.PlainCopy(x, seen) end
  end
  seen[v] = nil
  return out
end

-- ---------- saved data ----------

function ns.DB()
  if type(GuildSyncDB3) ~= "table" then GuildSyncDB3 = {} end
  local db = GuildSyncDB3
  if type(db.errors) ~= "table" then db.errors = {} end
  if type(db.chars) ~= "table" then db.chars = {} end
  if type(db.settings) ~= "table" then db.settings = {} end
  return db
end

-- GuildSyncDB3 when it is a table, else nil. Never creates or fills anything (for selftests and other reads).
function ns.SavedDB()
  if type(GuildSyncDB3) == "table" then return GuildSyncDB3 end
  return nil
end

function ns.DateText(t)
  if type(t) ~= "number" then return "?" end
  return date("%Y-%m-%d %H:%M", t)
end

local charKey

-- This character's record, refreshed. Returns nil while the client cannot name the player yet.
function ns.Char()
  local db = ns.DB()
  local p = Compat.Player()
  if p.name and p.realm then charKey = p.name .. "-" .. p.realm end
  if not charKey then return nil end
  local c = db.chars[charKey]
  if type(c) ~= "table" then
    c = {}
    db.chars[charKey] = c
  end
  if p.name then c.name = p.name end
  if p.realm then c.realm = p.realm end
  if p.guid then c.guid = p.guid end
  if p.class then c.class = p.class end
  if p.level and p.level >= (type(c.level) == "number" and c.level or 0) then c.level = p.level end
  if p.gold then c.gold = p.gold end -- copper
  c.updated = time()
  return c, charKey
end

-- This character's record and key as ns.Char finds them, without creating the record or stamping it.
function ns.PeekChar()
  local p = Compat.Player()
  local key = (p.name and p.realm) and (p.name .. "-" .. p.realm) or charKey
  if not key then return nil, nil end
  local db = ns.SavedDB()
  local c = db and type(db.chars) == "table" and db.chars[key] or nil
  if type(c) ~= "table" then return nil, key end
  return c, key
end

function ns.CharKey()
  if not charKey then ns.Char() end
  return charKey
end

-- ---------- errors ----------

local printedErrors = {}
local sessionTotal, sessionByModule = 0, {} -- RecordError calls since this UI loaded, in memory only

-- An error a wrapper already recorded under its module (ns.Attributed) is rethrown as this string; RecordError skips it.
ns.ATTRIBUTED = "GuildSync: error already recorded"

function ns.RecordError(moduleName, err)
  if err == ns.ATTRIBUTED then return end
  local ok, message = pcall(tostring, err)
  if not ok or type(message) ~= "string" then message = "unprintable error" end
  if ns.Demo then message = ns.Demo.Scrub(message) end -- no demo name of this session reaches GuildSyncDB3.errors
  if #message > 300 then message = string.sub(message, 1, 300) end
  moduleName = tostring(moduleName or "?")
  sessionTotal = sessionTotal + 1
  sessionByModule[moduleName] = (sessionByModule[moduleName] or 0) + 1
  local errors = ns.DB().errors
  local found
  for _, e in ipairs(errors) do
    if type(e) == "table" and e.module == moduleName and e.message == message then found = e break end
  end
  if found then
    found.count = (found.count or 0) + 1
  elseif #errors < MAX_ERRORS then
    table.insert(errors, { module = moduleName, message = message, firstSeen = time(), count = 1 })
  end
  local key = moduleName .. "\n" .. message
  if not printedErrors[key] then
    printedErrors[key] = true
    -- every | doubled: a message can carry another player's text, which must not colour, link or texture the chat
    ns.Say("|cffff8800" .. ns.Escape(moduleName) .. " failed and was skipped:|r " .. ns.Escape(message))
  end
end

-- RecordError calls this session for that module, or for all modules when name is nil.
function ns.SessionErrors(name)
  if name == nil then return sessionTotal end
  return sessionByModule[tostring(name)] or 0
end

-- Runs fn under pcall on behalf of a module. Returns ok, and fn's first result.
function ns.Safe(moduleName, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    ns.RecordError(moduleName, result)
    return false
  end
  return true, result
end

-- Reads a Compat wrapper's (nil, err) result: Compat never raises (its Options and StaticPopup section), so a string
-- err is raised here for the ns.Safe around the caller to record. A nil/false with no err passes through as a silent fallback.
function ns.Need(v, err)
  if not v and type(err) == "string" then error(err, 0) end
  return v
end

-- A wrapper around fn: a throw is recorded under title, then rethrown as ns.ATTRIBUTED (which RecordError skips).
function ns.Attributed(title, fn)
  local function settle(ok, ...)
    if ok then return ... end
    ns.RecordError(title, (...))
    error(ns.ATTRIBUTED, 0)
  end
  return function(...) return settle(pcall(fn, ...)) end
end

-- ---------- timers ----------

local frame = CreateFrame("Frame")
local fallbackTimers = {}

local function onUpdate(_, elapsed)
  local n = #fallbackTimers
  if n == 0 then
    frame:SetScript("OnUpdate", nil)
    return
  end
  for i = n, 1, -1 do
    local t = fallbackTimers[i]
    t.left = t.left - (elapsed or 0)
    if t.left <= 0 then
      table.remove(fallbackTimers, i)
      t.fn()
    end
  end
end

-- Runs fn after a delay, under pcall, errors attributed to moduleName.
function ns.After(seconds, fn, moduleName)
  local function run() ns.Safe(moduleName or "Core", fn) end
  if not Compat.After(seconds, run) then
    table.insert(fallbackTimers, { left = seconds, fn = run })
    frame:SetScript("OnUpdate", onUpdate)
  end
end

-- Runs fn now, or as soon as the encounter restriction has cleared. One pending run per key.
local RETRY_SECONDS, MAX_TRIES = 5, 240
local pending = {}

function ns.WhenUnrestricted(key, fn, moduleName)
  if pending[key] then
    pending[key].fn = fn
    return
  end
  if not Compat.EncounterRestricted() then
    ns.Safe(moduleName, fn)
    return
  end
  local job = { fn = fn, tries = 0 }
  pending[key] = job
  local function attempt()
    job.tries = job.tries + 1
    if not Compat.EncounterRestricted() then
      pending[key] = nil
      job.fn()
    elseif job.tries < MAX_TRIES then
      ns.After(RETRY_SECONDS, attempt, moduleName)
    else
      pending[key] = nil
    end
  end
  ns.After(RETRY_SECONDS, attempt, moduleName)
end

-- ---------- modules and events ----------

local subscribers = {} -- event -> list of modules
local registered = {}
local hubEvents = {} -- events Core or a hub module asked for: only these redraw the window
local ready = false
local loggedIn = false

-- true once the saved variables have loaded (our ADDON_LOADED or PLAYER_LOGIN has run)
function ns.Loaded() return ready end

-- true once PLAYER_LOGIN has run (a module addon's files run after our ADDON_LOADED, so Loaded() is no guide)
function ns.LoggedIn() return loggedIn end

-- A refused event goes into `into` (a module addon's own list) or ns.missingEvents (Core's selftest).
local function registerEvent(event, into)
  if registered[event] == nil then
    local ok = pcall(frame.RegisterEvent, frame, event) -- unknown events throw
    registered[event] = ok and true or false
  end
  if not registered[event] then (into or ns.missingEvents)[event] = true end
  return registered[event]
end

-- A module addon's onLogin, at most once (at PLAYER_LOGIN, or at registration when login has passed).
local function runLogin(mod)
  if type(mod.onLogin) ~= "function" or mod.loginRan then return end
  mod.loginRan = true
  ns.Safe(mod.name, mod.onLogin)
end

-- { name =, events = { ... }, onEvent = function(event, ...) end, status = function() return "one line" end,
--   scan = function() end (optional, for /gsync scan),
--   selftest = function() return state, text end (optional, for /gsync selftest) }
-- selftest: state "pass" | "wait" (not ready yet) | "fail", text one line. It must be read-only (no sends, timers or
-- saved writes), cheap and callable before login. Any other state, a secret, or a throw prints FAIL. The label is
-- mod.name, the display name. A module with a selftest and no status gets no /gsync status row.
-- A module addon's record (Api.lua) also carries id, slash (for /gsync <id>), onLogin (run once at PLAYER_LOGIN, or at
-- once when login has passed) and missingEvents (its own refused events; its events never redraw the window).
-- e.g. ns.RegisterModule({ name = "Window", selftest = function() return "pass", "button shown" end })
function ns.RegisterModule(mod)
  if type(mod) ~= "table" or type(mod.name) ~= "string" then return end
  table.insert(ns.modules, mod)
  local own = type(mod.missingEvents) == "table" and mod.missingEvents or nil
  for _, event in ipairs(mod.events or {}) do
    if registerEvent(event, own) then
      if not own then hubEvents[event] = true end
      subscribers[event] = subscribers[event] or {}
      table.insert(subscribers[event], mod)
    end
  end
  if loggedIn then runLogin(mod) end
  if ns.Demo and ns.Demo.On() then ns.Demo.Joined(mod) end
end

-- ---------- hub events (module addons hear them through M.On; only the hub fires them) ----------

local HUB_EVENTS = { rosterRead = true, commGate = true, windowOpened = true, demo = true, professions = true,
  links = true }
local listeners = {} -- event -> { { fn =, title = }, ... }
local gate -- { open =, why = }: the last Compat.CommGate answer, kept only while a commGate listener exists

local function gateNow()
  if ns.Demo and ns.Demo.On() then return { open = false, why = "demo" } end -- demo sends nothing
  local known = false
  if ns.Comm and type(ns.Comm.Roster) == "function" then known = select(4, ns.Comm.Roster()) and true or false end
  local open, why = Compat.CommGate(known)
  return { open = open and true or false, why = why }
end

-- true, or nil and why. title: the module a throwing listener is recorded under.
-- e.g. ns.On("rosterRead", function(partial, count) end, "Fixture")
function ns.On(name, fn, title)
  if not HUB_EVENTS[name] then return nil, "unknown hub event: " .. tostring(name) end
  if type(fn) ~= "function" then return nil, "the listener is not a function" end
  listeners[name] = listeners[name] or {}
  table.insert(listeners[name], { fn = fn, title = tostring(title or "?") })
  if name == "commGate" and not gate then gate = gateNow() end -- the first listener seeds the answer, no fire
  return true
end

-- Runs every listener under pcall; a throw is recorded under that listener's module and the rest still run.
function ns.Fire(name, ...)
  for _, l in ipairs(listeners[name] or {}) do
    local ok, err = pcall(l.fn, ...)
    if not ok then ns.RecordError(l.title, err) end
  end
end

-- Fires "commGate"(open, why) when Compat.CommGate's answer changed. Asks nothing while no listener exists.
function ns.CheckGate()
  if not listeners.commGate then return end
  local now = gateNow()
  if gate and gate.open == now.open and gate.why == now.why then return end
  gate = now
  ns.Fire("commGate", now.open, now.why)
end

-- Core's selftest: missing client functions and refused events fail; then waits for the saved data and the character.
-- A missing name in Compat.OPTIONAL is only named inside the PASS text.
local MAX_NAMES = 5

local function coreSelftest()
  local fails, missing, optional = {}, {}, {}
  for _, name in ipairs(Compat.APIS) do
    if not Compat.Has(name) then table.insert(Compat.OPTIONAL[name] and optional or missing, name) end
  end
  if #missing > 0 then
    local shown = {}
    for i = 1, math.min(#missing, MAX_NAMES) do shown[i] = missing[i] end
    local text = "missing API: " .. table.concat(shown, ", ")
    if #missing > MAX_NAMES then text = text .. " and " .. (#missing - MAX_NAMES) .. " more" end
    table.insert(fails, text)
  end
  local events = {}
  for event in pairs(ns.missingEvents) do table.insert(events, tostring(event)) end
  if #events > 0 then
    table.sort(events)
    table.insert(fails, "events refused: " .. table.concat(events, ", "))
  end
  if #fails > 0 then return "fail", table.concat(fails, "; ") end
  if not ns.Loaded() then return "wait", "saved data not loaded" end
  if not ns.PeekChar() then return "wait", "character not known yet" end
  local _, _, _, interface = Compat.BuildInfo()
  local text = ns.VERSION .. ", interface " .. tostring(interface or "?") .. ", errors this session: " .. ns.SessionErrors()
  if #optional > 0 then text = text .. ", optional missing: " .. table.concat(optional, ", ") end
  return "pass", text
end

ns.RegisterModule({ name = "Core", selftest = coreSelftest })

local function dispatch(event, ...)
  local list = subscribers[event]
  if not list then return end
  for _, mod in ipairs(list) do
    if type(mod.onEvent) == "function" then
      local ok, err = pcall(mod.onEvent, event, ...)
      if not ok then ns.RecordError(mod.name, err) end
    end
  end
end

-- Keys an older GuildSync wrote and nothing reads any more: dropped once, when the saved file has loaded.
local DEAD_KEYS = { "version", "addon", "items", "kills", "loot", "bags", "bank", "guildBank", "lockouts" }
local DEAD_CHAR_KEYS = { "isBank", "bags", "bank", "bankScanned", "lockouts", "lockoutsScanned" }

local function dropDead(db)
  if type(db) ~= "table" then return end
  for _, k in ipairs(DEAD_KEYS) do db[k] = nil end
  if type(db.settings) == "table" then
    db.settings.lootQuality = nil
    db.settings.lootAnyInstance = nil
  end
  if type(db.probe) == "table" then db.probe.atLogout = nil end
  if type(db.chars) == "table" then
    for _, c in pairs(db.chars) do
      if type(c) == "table" then
        for _, k in ipairs(DEAD_CHAR_KEYS) do c[k] = nil end
      end
    end
  end
end

local function stampBuild()
  local db = ns.DB()
  local version, build, _, interface = Compat.BuildInfo()
  if version and build then db.build = version .. "." .. build end
  if interface then db.interface = interface end
end

local function onCoreEvent(event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return false end
    ready = true
    dropDead(GuildSyncDB3)
    stampBuild()
    return false
  elseif event == "PLAYER_LOGIN" then
    ready = true
    loggedIn = true
    stampBuild()
    ns.Char()
    ns.Say("loaded (" .. ns.VERSION .. "). Open each profession window once to record recipes. /gsync for status.")
    if ns.Demo then ns.Safe("Demo", ns.Demo.Login) end -- before Window.Login: the first draw already shows demo
    if ns.Window and ns.Window.Login then ns.Safe("Window", ns.Window.Login) end
    for _, mod in ipairs(ns.modules) do runLogin(mod) end
  elseif event == "PLAYER_LEVEL_UP" then
    local c = ns.Char()
    local level = Compat.Plain(arg1)
    if c and type(level) == "number" then c.level = level end
  elseif event == "PLAYER_MONEY" then
    ns.Char()
  end
  return true
end

-- PLAYER_REGEN_DISABLED / ENABLED: combat starts and ends; nothing to do here, but like every event they redraw the
-- open window (Window.Changed below), so the officer actions hide in combat and come back after it.
-- No PLAYER_LOGOUT: on the Forever client the player data is already gone at logout (UnitLevel answers 1, GetMoney
-- 0), so refreshing the character then would overwrite the real values. Every change refreshes it when it happens.
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "PLAYER_MONEY",
  "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
  registerEvent(event)
  hubEvents[event] = true
end

frame:SetScript("OnEvent", function(_, event, ...)
  local ok, forward = pcall(onCoreEvent, event, ...)
  if not ok then ns.RecordError("Core", forward) end
  if ok and forward == false then return end
  if not ready then return end -- saved variables are not loaded before our ADDON_LOADED
  dispatch(event, ...)
  if not hubEvents[event] then return end -- a module's own events neither redraw the window nor ask the gate
  if ns.Window and ns.Window.Changed then ns.Safe("Window", ns.Window.Changed) end
  ns.Safe("Core", ns.CheckGate)
end)

-- ---------- slash command ----------

local function trim(s) return (string.gsub(string.gsub(s or "", "^%s+", ""), "%s+$", "")) end

local function demoStatus()
  if ns.Demo and ns.Demo.On() then ns.Say(ns.Demo.LINES.status) end
end

local function printStatus()
  demoStatus()
  local c = ns.Char()
  -- professions are not repeated here: the Professions module's status line below lists them
  ns.Say(ns.View.CharacterLine(c))
  for _, row in ipairs(ns.View.ModuleRows(ns.modules)) do ns.Say(row[1] .. ": " .. row[2]) end
  local nErrors = #ns.DB().errors
  if nErrors > 0 then ns.Say("|cffff8800" .. nErrors .. " module error(s) recorded.|r /gsync errors to list them.") end
end

local function printErrors()
  local errors = ns.DB().errors
  if #errors == 0 then ns.Say("no module errors recorded.") return end
  for _, e in ipairs(errors) do
    if type(e) == "table" then
      ns.Say(ns.Escape(e.module) .. " x" .. tostring(e.count) .. " (first " .. date("%Y-%m-%d %H:%M", e.firstSeen or 0) .. "): " .. ns.Escape(e.message))
    end
  end
end

local Commands = {}
ns.Commands = Commands

Commands.Status = printStatus
Commands.Errors = printErrors

function Commands.Scan()
  for _, mod in ipairs(ns.modules) do
    if type(mod.scan) == "function" then ns.Safe(mod.name, mod.scan) end
  end
  ns.Say("rescanned.")
  printStatus()
end

function Commands.Probe()
  if ns.Probe and ns.Probe.Run then
    ns.Safe("Probe", ns.Probe.Run)
    ns.Safe("Probe", ns.Probe.Print)
  end
end

-- One PASS/WAIT/FAIL line per module with a selftest, then the total. Read only: writes and schedules nothing.
function Commands.Selftest()
  demoStatus()
  for _, line in ipairs((ns.View.SelftestLines(ns.modules, Compat.Plain))) do ns.Say(line) end
end

function Commands.Window()
  if ns.Window and ns.Window.Toggle then ns.Window.Toggle() end
end

function Commands.Minimap()
  if ns.Window and ns.Window.ToggleMinimap then ns.Window.ToggleMinimap() end
end

SLASH_GUILDSYNC1 = "/gsync"
SlashCmdList.GUILDSYNC = function(msg)
  local redraw = true
  local ok, err = pcall(function()
    local cmd, rest = string.match(trim(msg), "^(%S+)%s*(.-)$")
    cmd = string.lower(cmd or "") -- only the command word: a module's rest keeps its case
    local mod -- a module addon's record for /gsync <id> (hub modules have no id)
    for _, m in ipairs(ns.modules) do
      if m.id ~= nil and m.id == cmd and type(m.slash) == "function" then mod = m break end
    end
    if cmd == "scan" then
      Commands.Scan()
    elseif cmd == "probe" then
      Commands.Probe()
    elseif cmd == "errors" then
      Commands.Errors()
    elseif cmd == "ui" or cmd == "window" then
      Commands.Window()
    elseif cmd == "minimap" then
      Commands.Minimap()
    elseif cmd == "selftest" then
      Commands.Selftest()
      redraw = false -- Window.Changed arms a timer, and selftest changes nothing
    elseif cmd == "demo" then
      local D, word = ns.Demo, string.lower(rest)
      if word == "off" and not D.On() then
        ns.Say(D.LINES.notOn)
      elseif word == "on" and D.On() then
        ns.Say(D.LINES.status)
      elseif word == "off" or word == "on" or rest == "" then
        local want = word == "on" or (rest == "" and not D.On())
        if D.Set(want) then ns.Say(want and D.LINES.on or D.LINES.off) end
      else
        Commands.Status()
      end
    elseif cmd == "versions" then
      if ns.Comm and ns.Comm.Version and ns.Comm.Version.Print then ns.Comm.Version.Print() end
    elseif mod then
      ns.Safe(mod.name, mod.slash, rest)
    else
      Commands.Status()
    end
  end)
  if not ok then ns.RecordError("Core", err) end
  if redraw and ns.Window and ns.Window.Changed then ns.Safe("Window", ns.Window.Changed) end
end
