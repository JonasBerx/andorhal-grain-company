-- GuildSync's public API (API 8 adds the search and facts fields, M.Fact, M.FactsChanged and the "facts" hub event;
-- API 7 the member field, M.RefreshMember, Comm.Person, M.MyCharacters and M.SetLinks; API 6 the kit art; API 5 the
-- pull store, bulk, limit and the menu and book-row kit pieces; API 4 the officers audience; API 3
-- M.Kit; API 2 the demo field, M.Demo and the "demo" hub event): the one global,
-- GuildSync, for module addons in their own folders (`## Dependencies: GuildSync`). Last in the TOC: the global is assigned as this file's last statement, so it exists
-- only after every hub file has run. Internal code keeps using ns; the global is a chosen subset, never ns itself.
--
--   local M = GuildSync and GuildSync.RegisterModule{ id = "hello", title = "Hello", version = "1", needs = 1 }
--   if not M then return end
--
-- RegisterModule answers a per-module handle M, or nil after exactly one chat line. Everything module-scoped goes
-- through M (events, timers, Safe, page, comms, client calls), so a module never names itself again and cannot act as
-- another. What crosses the boundary: closures that look ns up when called, deep copies of data going out, copies of
-- what comes in. API.md documents every field.

local ADDON, ns = ...

local API, MIN_API = 8, 1
local MAX_NEEDS = 99 -- a needs above this is a mistake, not a future API (math.huge passes the whole-number check)
local MAX_ID, MAX_TITLE, MAX_NAMES = 12, 32, 5
-- /gsync words a module id may not take (Core.lua's slash command)
local WORDS = { scan = true, probe = true, errors = true, ui = true, window = true, minimap = true, selftest = true,
  versions = true, demo = true }
local FUNCTION_FIELDS = { "slash", "selftest", "status", "scan", "onEvent", "onLogin" }

local function say(text) ns.Say(text) end
local function refuse(why) say("a module was refused: " .. why .. ".") end

-- A list of strings copied from t (nil when t is not a table or holds anything else).
local function stringList(t)
  if t == nil then return {} end
  if type(t) ~= "table" then return nil end
  local out = {}
  for _, v in ipairs(t) do
    if type(v) ~= "string" or v == "" then return nil end
    out[#out + 1] = v
  end
  return out
end

-- s without surrounding whitespace when it is a string; anything else unchanged (and refused later by its check).
local function trim(s)
  if type(s) ~= "string" then return s end
  return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- The module's status line with every | doubled (it can carry other players' text); a throw is passed on escaped,
-- so View's "status failed: ..." row is escaped too.
local function escapedStatus(status)
  if not status then return nil end
  return function()
    local ok, r = pcall(status)
    r = ns.Compat.Plain(r)
    if not ok then error(ns.Escape(r), 0) end
    return ns.Escape(r)
  end
end

local function namesSend(name)
  for _, word in ipairs(ns.Compat.SEND_NAMES or {}) do
    if string.find(name, word, 1, true) then return word end
  end
  return nil
end

local function namesScript(name)
  for _, word in ipairs(ns.Compat.SCRIPT_NAMES or {}) do
    if string.find(string.lower(name), string.lower(word), 1, true) then return word end
  end
  return nil
end

local function shortList(names)
  local shown = {}
  for i = 1, math.min(#names, MAX_NAMES) do shown[i] = names[i] end
  local text = table.concat(shown, ", ")
  if #names > MAX_NAMES then text = text .. " and " .. (#names - MAX_NAMES) .. " more" end
  return text
end

-- The module's selftest behind its own checks: required client functions, then its refused events, then its own
-- selftest (not wrapped: a throw is a FAIL line and nothing is recorded, as for hub modules).
local function wrapSelftest(rec, own, required, optional)
  return function()
    local Compat, fails, missing, optMissing = ns.Compat, {}, {}, {}
    for _, name in ipairs(required) do if not Compat.Has(name) then missing[#missing + 1] = name end end
    for _, name in ipairs(optional) do if not Compat.Has(name) then optMissing[#optMissing + 1] = name end end
    if #missing > 0 then fails[#fails + 1] = "missing API: " .. shortList(missing) end
    local events = {}
    for event in pairs(rec.missingEvents) do events[#events + 1] = tostring(event) end
    if #events > 0 then
      table.sort(events)
      fails[#fails + 1] = "events refused: " .. table.concat(events, ", ")
    end
    if #fails > 0 then return "fail", table.concat(fails, "; ") end
    local state, text = "pass", "client functions present"
    if own then state, text = own() end
    if #optMissing > 0 and Compat.Plain(state) == "pass" then
      text = Compat.Plain(text)
      text = (text == nil or text == "") and "no reason given" or tostring(text)
      text = text .. ", optional missing: " .. table.concat(optMissing, ", ")
    end
    return state, text
  end
end

-- The first missing hub piece, or nil when GuildSync loaded fully.
local function missingPiece()
  if type(ns.RegisterModule) ~= "function" then return "RegisterModule" end
  if type(ns.Window) ~= "table" then return "Window" end
  if type(ns.Comm) ~= "table" or type(ns.Comm.Sync) ~= "table" then return "Comm.Sync" end
  if type(ns.Comm.Queue) ~= "table" then return "Comm.Queue" end
  if type(ns.Compat) ~= "table" then return "Compat" end
  if type(ns.Kit) ~= "table" then return "Kit" end
  return nil
end

-- The hub's own module names, refused as titles whether or not that hub module has registered yet.
local RESERVED = { core = true, comms = true, version = true, window = true, roster = true,
  professions = true, probe = true, guildsync = true, demo = true, ["alt links"] = true, ["?"] = true }

local function titleTaken(title)
  local low = string.lower(title)
  if RESERVED[low] then return true end
  for _, m in ipairs(ns.modules) do
    if type(m.name) == "string" and string.lower(m.name) == low then return true end
  end
  return false
end

local function idTaken(id)
  for _, m in ipairs(ns.modules) do if m.id == id then return true end end
  return false
end

-- A read-only view of t: reads go through, every write throws, and getmetatable answers false. Not a sandbox: it only
-- stops one addon replacing what another calls.
local function readOnly(t)
  return setmetatable({}, { __index = t, __metatable = false,
    __newindex = function() error("GuildSync is read-only", 2) end })
end

-- ---------- the kit (API 3) ----------

-- M.Kit's pieces that take no module function: each a closure that calls ns.Kit's piece at call time.
local KIT_PLAIN = { "Atlas", "ClassIcon", "Inset", "HeaderBar", "StatBar", "Card", "Divider", "ListHover", "SortArrow",
  "DropdownText", "SearchBox", "InputBox", "Checkbox", "Pill", "SetPill", "SectionHeader" }

-- API 5: the kit pieces that take no module function (MatchMenu, which takes onPick, is below).
local KIT_PLAIN_5 = { "CloseMenu", "FavouriteStar", "SetFavourite", "BookRow", "SetBookRow", "CloseDropdown" }

-- Kit.Tabs' own fields: a module tab with one of these keys would overwrite it, so M.Kit.Tabs answers nil.
local TAB_FIELDS = { holder = true, keys = true, selected = true, Select = true }

-- API 6 (the kit art): plain pass-throughs like KIT_PLAIN, on needs >= 6 handles only.
local KIT_ART = { "ItemButton", "SetItem", "SetCardProfession", "ClassBackground" }

-- One module's kit backing table (23 names, Kit.lua's header; 30 from needs 5; 34 from needs 6 with KIT_ART). Every
-- function the module hands in runs under its title and returns nothing; popup names are scoped to the module:
-- GUILDSYNC_M_<ID>_<WHICH>.
local function newKit(id, title, needs)
  local function cb(fn)
    return function(...) if type(fn) == "function" then ns.Safe(title, fn, ...) end end
  end
  -- which: 1-24 letters, digits or _; anything else answers nil (the piece then answers false).
  local function popupName(which)
    if type(which) ~= "string" or #which < 1 or #which > 24 or not string.find(which, "^[%w_]+$") then return nil end
    return "GUILDSYNC_M_" .. string.upper(id) .. "_" .. string.upper(which)
  end
  local kit = {}
  for _, name in ipairs(KIT_PLAIN) do kit[name] = function(...) return ns.Kit[name](...) end end
  function kit.ColumnHeader(parent, text, onClick) return ns.Kit.ColumnHeader(parent, text, cb(onClick)) end
  function kit.Tabs(parent, entries, onSelect)
    for _, e in ipairs(type(entries) == "table" and entries or {}) do
      if type(e) == "table" and TAB_FIELDS[e.key] then return nil end
    end
    return ns.Kit.Tabs(parent, entries, cb(onSelect))
  end
  function kit.List(parent, rowH, build, init) return ns.Kit.List(parent, rowH, cb(build), cb(init)) end
  function kit.Dropdown(parent, width, generate) return ns.Kit.Dropdown(parent, width, cb(generate)) end
  function kit.ContextMenu(owner, generate) return ns.Kit.ContextMenu(owner, cb(generate)) end
  function kit.Confirm(which, text, okText, onOk)
    local name = popupName(which)
    if not name then return false end
    return ns.Kit.Confirm(name, text, okText, cb(onOk))
  end
  function kit.Ask(which, text, okText, cancelText, onOk)
    local name = popupName(which)
    if not name then return false end
    return ns.Kit.Ask(name, text, okText, cancelText, cb(onOk))
  end
  if needs >= 5 then
    for _, name in ipairs(KIT_PLAIN_5) do kit[name] = function(...) return ns.Kit[name](...) end end
    function kit.MatchMenu(owner, entries, onPick, emptyText)
      return ns.Kit.MatchMenu(owner, entries, cb(onPick), emptyText)
    end
  end
  if needs >= 6 then
    for _, name in ipairs(KIT_ART) do kit[name] = function(...) return ns.Kit[name](...) end end
  end
  return kit
end

-- ---------- settings sub-pages (API 3) ----------

-- The add function for Window.AddModuleSettings: the module's sub-category under GuildSync's, then settings(S) once
-- under its title. S is open only during that call. A setter acts only once the path is "vertical" and the call
-- finished, and says the inert line in demo; a getter answers its value clamped, else the default.
local function settingsAdder(id, title, settings, needs)
  return function(cat)
    local Compat = ns.Compat
    local sub, layout = Compat.OptionsSub(cat, title)
    if not ns.Need(sub, layout) then return end
    local open, done, keys, S = true, false, {}, {}
    local function setter(set)
      return function(v)
        local W = ns.Window
        if not (done and W and W.SettingsPath() == "vertical") then return end
        if ns.Demo and ns.Demo.On() then say(ns.Demo.LINES.inert) return end
        ns.Safe(title, set, v)
      end
    end
    -- nil, why when S is closed, the key is bad or taken, get/set are not functions, text is not a string or
    -- tooltip is neither a string nor nil. The key is taken only once its setting is made.
    local function check(key, get, set, text, tooltip)
      if not open then return "closed" end
      if type(key) ~= "string" or #key > 16 or not string.find(key, "^[a-z][a-z0-9]*$") then return "bad key" end
      if keys[key] then return "taken" end
      if type(get) ~= "function" or type(set) ~= "function" then return "get and set must be functions" end
      if type(text) ~= "string" then return "bad text" end
      if tooltip ~= nil and type(tooltip) ~= "string" then return "bad tooltip" end
      return nil
    end
    local function variable(key) return "GUILDSYNC_M_" .. string.upper(id) .. "_" .. string.upper(key) end
    function S.Checkbox(key, text, default, get, set, tooltip)
      local why = check(key, get, set, text, tooltip)
      if why then return nil, why end
      default = default and true or false
      local function getter()
        local good, v = ns.Safe(title, get)
        if not good or v == nil then return default end
        return v and true or false
      end
      local s = Compat.OptionsProxy(sub, variable(key), "boolean", text, default, getter, setter(set))
      if s then keys[key] = true end
      if not s or not Compat.OptionsCheckbox(sub, s, tooltip) then return nil, "failed" end
      return true
    end
    function S.Dropdown(key, text, default, values, get, set, tooltip)
      local why = check(key, get, set, text, tooltip)
      if why then return nil, why end
      local kind = type(default)
      if kind ~= "boolean" and kind ~= "number" and kind ~= "string" then return nil, "bad default" end
      local function listOf(vals)
        local l, has = {}, false
        for _, v in ipairs(type(vals) == "table" and vals or {}) do
          -- raw reads: a row's metamethods never run here, outside ns.Safe (f4544)
          local val, label = type(v) == "table" and rawget(v, 1), type(v) == "table" and rawget(v, 2)
          if type(v) == "table" and type(val) == kind and type(label) == "string" then
            l[#l + 1] = { val, label }
            if val == default then has = true end
          end
        end
        return l, has
      end
      -- values may be a function (asked each time the options show, under ns.Safe; a throw keeps the last good list)
      local lazy = type(values) == "function" and values or nil
      local function current()
        if not lazy then return values end
        local good, v = ns.Safe(title, lazy)
        return good and v
      end
      local list, listed = listOf(current())
      if not listed then return nil, "bad default" end
      local options = list
      if lazy then
        options = function()
          local l, has = listOf(current())
          if has then list = l end
          return list
        end
      end
      local function getter()
        local good, v = ns.Safe(title, get)
        if good then
          for _, e in ipairs(list) do if e[1] == v then return v end end
        end
        return default
      end
      local s = Compat.OptionsProxy(sub, variable(key), type(default), text, default, getter, setter(set))
      if s then keys[key] = true end
      if not s or not Compat.OptionsDropdown(sub, s, options, tooltip) then return nil, "failed" end
      return true
    end
    -- API 5: a button row; onClick() follows the setter rule (vertical path, settings finished, inert in demo).
    if needs >= 5 then
      function S.Button(key, text, buttonText, onClick, tooltip)
        local why = check(key, onClick, onClick, text, tooltip) -- onClick stands in for get and set
        if why == "get and set must be functions" then why = "onClick must be a function" end
        if not why and type(buttonText) ~= "string" then why = "bad text" end
        if why then return nil, why end
        local init = Compat.OptionsButton(layout, text, buttonText, setter(function() onClick() end), tooltip)
        if not init then return nil, "failed" end
        keys[key] = true
        return true
      end
    end
    local good = ns.Safe(title, settings, readOnly(S))
    open, done = false, good == true
  end
end

-- ---------- the handle ----------

local NOT_MINE, MISSING = "not this module's domain", "not available in this GuildSync"
local STATS_FIELDS = { "queued", "user", "sent", "attempts", "dropped", "limited", "wants", "refused" }

-- t without the fields drop(k, v) names: t itself when it has none (raw fields, as the registry's copy reads), else a
-- shallow copy. API 5's fields under a lower needs are ignored this way, never refused (plan Revision 2, f4104).
local function without(t, drop)
  if type(t) ~= "table" then return t end
  local found = false
  for k, v in pairs(t) do if drop(k, v) then found = true break end end
  if not found then return t end
  local out = {}
  for k, v in pairs(t) do if not drop(k, v) then out[k] = v end end
  return out
end
local function api5Spec(k, v) return k == "bulk" or k == "limit" or (k == "maxChunks" and type(v) == "number" and v > 16) end
local function api5Store(k) return k == "askBatch" end

-- API 5's handle names (needs >= 5). Each domain name answers for this module's own domains only, checked before
-- the hub piece it calls; a hub piece missing from this GuildSync answers nil, MISSING.
local function addApi5(M, id, title, mine)
  local function sync(name)
    local S = ns.Comm.Sync
    local f = S and S[name]
    return type(f) == "function" and f or nil
  end
  local function now() return ns.Compat.ServerTime() end
  -- Comm.Sync[name](title, domainId, ...) for this module's own domain.
  local function relay(name, domainId, ...)
    if not mine(domainId) then return nil, NOT_MINE end
    local f = sync(name)
    if not f then return nil, MISSING end
    return f(title, domainId, ...)
  end

  -- priority "user" | "own"
  function M.Comm.Send(domainId, msg, priority) return relay("Send", domainId, msg, priority, now()) end
  -- Whether the hub would send for this domain now: its prefix's gate (read-only).
  function M.Comm.Gate(domainId)
    if not mine(domainId) then return false, NOT_MINE end
    local dom = ns.Comm.Registry.Domain(domainId)
    if not dom then return false, NOT_MINE end
    return ns.Comm.Queue.Gate(dom.prefix)
  end
  function M.Sync.Pull(domainId, pull) return relay("AttachPull", domainId, pull) end
  -- role "owner" | "peer"
  function M.Sync.Want(domainId, kind, subject, version, asker, role)
    return relay("Want", domainId, kind, subject, version, asker, role, now())
  end
  function M.Sync.Heard(domainId, kind, subject, version)
    return relay("HeardFor", domainId, kind, subject, version, now())
  end
  -- true when this client served subject to asker within the served window; false for another module's domain.
  function M.Sync.Recent(domainId, subject, asker)
    if not mine(domainId) then return false end
    local f = sync("Recent")
    if not f then return nil, MISSING end
    return f(title, domainId, subject, asker, now()) and true or false
  end
  -- A copy of the domain's counters (STATS_FIELDS only), or nil for another module's domain.
  function M.Sync.Stats(domainId)
    if not mine(domainId) then return nil end
    local f = sync("Stats")
    local s = f and f(domainId)
    if type(s) ~= "table" then return nil end
    local out = {}
    for _, k in ipairs(STATS_FIELDS) do if type(s[k]) == "number" then out[k] = s[k] end end
    return out
  end
  -- chars, serial: a deep copy of this account's recorded professions.
  function M.Professions()
    local f = ns.ProfessionsCopy
    if type(f) ~= "function" then return nil, MISSING end
    return f()
  end
  -- This module's hold on the minimap button's glow.
  function M.Glow(on)
    local W = ns.Window
    local f = W and W.HoldGlow
    if type(f) ~= "function" then return nil, MISSING end
    return f(title, on and true or false)
  end
  function M.Compat.Tooltip() return ns.Compat.Tooltip() end
end

-- ---------- R9 alt links (API 7): LinksStore's answers as fresh rows ----------

local function linksStore()
  local L = ns.Links
  return type(L) == "table" and type(L.Store) == "table" and L.Store or nil
end

local function linkRow(lv, key)
  local r = type(lv[key]) == "table" and lv[key] or {}
  return { key = key, name = r.name, level = r.level, class = r.class }
end

-- Level desc, a tie to the lowest key.
local function byLevel(a, b)
  local la, lb = tonumber(a.level) or 0, tonumber(b.level) or 0
  if la ~= lb then return la > lb end
  return a.key < b.key
end

-- A store person (keys) as Comm.Person's rows over the roster read lv: the main first, then level desc.
local function personRows(p, lv)
  local chars, unconfirmed = {}, {}
  for _, k in ipairs(p.chars) do chars[#chars + 1] = linkRow(lv, k) end
  table.sort(chars, function(a, b)
    if (a.key == p.main) ~= (b.key == p.main) then return a.key == p.main end
    return byLevel(a, b)
  end)
  for _, k in ipairs(p.unconfirmed) do unconfirmed[#unconfirmed + 1] = linkRow(lv, k) end
  return { key = p.key, main = p.main, chars = chars, unconfirmed = unconfirmed }
end

-- Comm.Person's answer, built new per call; nil off the roster or for a non-string.
local function personOf(nameOrKey)
  local S = linksStore()
  if type(nameOrKey) ~= "string" or not S then return nil end
  local key = ns.Comm.Wire.Key(nameOrKey)
  local p = key and S.Person(key)
  if type(p) ~= "table" then return nil end
  return personRows(p, S.Levels())
end

-- Hub-only (Search.lua, f6242): { [key] = Comm.Person's answer } for a list of keys, the store read once for all.
function ns.PeopleOf(keyList)
  local S, out = linksStore(), {}
  if not S then return out end
  local persons, lv = S.Persons(keyList)
  for key, p in pairs(persons) do out[key] = personRows(p, lv) end
  return out
end

-- M.MyCharacters' answer: this account's characters in this guild (last full read), level order, and the pick.
local function myCharacters()
  local S = linksStore()
  if not S then return {}, nil end
  local lv, list, pick, first = S.Levels(), {}, nil, nil
  for _, m in ipairs(S.Mine()) do
    local row = linkRow(lv, m.key)
    row.hidden = m.hidden and true or false
    if m.pick then pick = m.key end
    if not row.hidden and not first then first = m.key end
    list[#list + 1] = row
  end
  local p = first and S.Person(first)
  for _, row in ipairs(list) do row.main = type(p) == "table" and p.main == row.key end
  table.sort(list, byLevel)
  return list, pick
end

-- ---------- API 8: module facts ----------

local MAX_FACTS, MAX_FACT_NAME, MAX_FACT_TEXT, MAX_FACT_KEY = 8, 16, 64, 64

-- A fact's answer as the reader gets it: a string (the text rule, ns.PlainLine), a finite number or a boolean;
-- anything else nil.
local function plainFact(v)
  v = ns.Compat.Plain(v)
  local t = type(v)
  if t == "string" then return ns.PlainLine(v, MAX_FACT_TEXT) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
  end
  if t == "boolean" then return v end
  return nil
end

-- RegisterModule's facts field -> a copy { [name] = fn }, or nil and the refusal. Walked with the global next over
-- the raw table (no __index, no __pairs), name before value, and it stops at the 9th name.
local function copyFacts(title, facts)
  if type(facts) ~= "table" then return nil, title .. ": facts is not a table" end
  local copy, n = {}, 0
  local name, fn = next(facts)
  while name ~= nil do
    n = n + 1
    if n > MAX_FACTS then return nil, title .. ": facts has more than " .. MAX_FACTS .. " names" end
    if type(name) ~= "string" or #name > MAX_FACT_NAME or not string.find(name, "^[a-z][a-z0-9]*$") then
      return nil, title .. ": facts has a bad name"
    end
    if type(fn) ~= "function" then return nil, title .. ": facts." .. name .. " is not a function" end
    copy[name] = fn
    name, fn = next(facts, name)
  end
  return copy
end

-- "facts"(id) for one module, at most once per frame: every fire cause goes through here (LinksStore's pattern).
local function factsChanged(rec)
  -- a change signalled while one of its facts runs is covered by that read (f6241: no read-nudge-read loop)
  if not rec.facts or rec.factsArmed or rec.factsBusy then return end
  rec.factsArmed = true
  ns.After(0, function()
    rec.factsArmed = false
    ns.Fire("facts", rec.id)
  end, rec.name)
end

-- Core runs this at PLAYER_LOGIN: once, a frame later, "facts" for every module that declared facts before login.
function ns.FactsLogin()
  ns.After(0, function()
    for _, rec in ipairs(ns.modules) do
      if rec.factsEarly then factsChanged(rec) end
    end
  end, "Core")
end

-- M.Fact's answer: module id's fact name run with key under that module's title; nil for a bad call, a throw, a
-- value that is not plain, or a re-entrant call into the same module while one of its facts runs.
local function readFact(id, name, key)
  if type(id) ~= "string" or type(name) ~= "string" then return nil end
  if key ~= nil and (type(key) ~= "string" or #key > MAX_FACT_KEY) then return nil end
  local rec
  for _, m in ipairs(ns.modules) do if m.id == id then rec = m break end end
  local fn = rec and rec.facts and rec.facts[name]
  if type(fn) ~= "function" or rec.factsBusy then return nil end
  rec.factsBusy = true
  local ok, v = ns.Safe(rec.name, fn, key)
  rec.factsBusy = false
  if not ok then return nil end
  return plainFact(v)
end

local function newHandle(rec, calls, needs)
  local id, title = rec.id, rec.name
  local M = { id = id, title = title, Comm = {}, Sync = {}, Compat = {} }

  -- event: "rosterRead"(partial, count) | "commGate"(open, why) | "windowOpened"(). true, or nil and why.
  function M.On(event, fn) return ns.On(event, fn, title) end
  function M.After(seconds, fn) ns.After(seconds, fn, title) end
  function M.Safe(fn, ...) return ns.Safe(title, fn, ...) end
  -- API 2: on (demo running), then what this module's demo returned this session (nil without one, and when off).
  function M.Demo()
    local D = ns.Demo
    if not (D and D.On()) then return false end
    return true, D.StateOf(rec)
  end
  function M.OpenPage()
    local W = ns.Window
    if W and type(W.ShowModulePage) == "function" then return ns.Safe(title, W.ShowModulePage, "m:" .. id) end
  end
  -- Redraws this module's page (its refresh) when it is the current page of the open window; else nothing.
  function M.RefreshPage()
    local W = ns.Window
    if W and type(W.RefreshModulePage) == "function" then ns.Safe(title, W.RefreshModulePage, "m:" .. id) end
  end

  local function mine(domainId)
    local Comm = ns.Comm
    return type(Comm.ModuleOf) == "function" and Comm.ModuleOf(domainId) == title
  end

  -- API 4: audience "officers" (prefix GSyncO) only with needs >= 4; a non-table spec goes on to the registry, which
  -- answers "bad spec".
  function M.Comm.Register(spec)
    local f = ns.Comm.RegisterModuleDomain
    if type(f) ~= "function" then return nil, "not available in this GuildSync" end
    if type(spec) == "table" and rawget(spec, "audience") == "officers" and needs < 4 then -- raw (fix round 1, f4352)
      return nil, "audience officers needs API 4 (declare needs = 4)"
    end
    if needs < 5 then spec = without(spec, api5Spec) end
    local ok, why = f(id, title, spec)
    if ok then return true end
    return nil, why
  end
  function M.Sync.Attach(domainId, store)
    local f = ns.Comm.Sync.AttachModule
    if type(f) ~= "function" then return nil, "not available in this GuildSync" end
    if needs < 5 then store = without(store, api5Store) end
    local ok, why = f(title, domainId, store)
    if ok then return true end
    return nil, why
  end
  -- A throw inside (the module's own store, already recorded under its title) never reaches the module's call.
  function M.Sync.Handle(domainId, role, msg, from, t)
    if not mine(domainId) then return nil, "not this module's domain" end
    local ok, err = pcall(ns.Comm.Sync.Handle, domainId, role, msg, from, t)
    if not ok then ns.RecordError(title, err) return nil, "failed" end
    return true
  end
  function M.Sync.Changed(domainId, key, t)
    if not mine(domainId) then return nil, "not this module's domain" end
    local ok, err = pcall(ns.Comm.Sync.Changed, domainId, key, t)
    if not ok then ns.RecordError(title, err) return nil, "failed" end
    return true
  end

  -- Only names in this module's apis; every return value plain (a secret comes back nil).
  function M.Compat.call(dotted, ...)
    local f = ns.Compat.CallIn
    if not calls or type(f) ~= "function" then return end
    return f(calls, dotted, ...)
  end
  function M.Compat.Try(dotted, ...)
    local f = ns.Compat.TryIn
    if not calls or type(f) ~= "function" then return false end
    return f(calls, dotted, ...)
  end
  -- API 3: the hub's kit, per module and read-only (handles from needs 1 and 2 have no Kit).
  if needs >= 3 then M.Kit = readOnly(newKit(id, title, needs)) end
  if needs >= 5 then addApi5(M, id, title, mine) end
  -- API 7: re-runs this module's member section for the selected member while the Roster page shows.
  if needs >= 7 then
    function M.RefreshMember()
      local W = ns.Window
      if W and type(W.RefreshMemberSection) == "function" then ns.Safe(title, W.RefreshMemberSection, id) end
    end
    -- R9: chars ({ key, name, level, class, hidden, main }, level desc), pick; {} and nil before the first full read.
    function M.MyCharacters() return myCharacters() end
    -- R9: pick (an own key or nil) and hidden (the full set). true | nil, why ("demo", "roster", "bad pick",
    -- "bad hidden"); the same setting again stores, stamps and sends nothing.
    function M.SetLinks(pick, hidden)
      if ns.Demo and ns.Demo.On() then say(ns.Demo.LINES.inert) return nil, "demo" end
      local S = linksStore()
      if not S then return nil, MISSING end
      if pick ~= nil and type(hidden) == "table" and hidden[pick] then return nil, "bad pick" end
      return S.Set(pick, hidden)
    end
  end
  -- API 8: another module's fact, and "facts" for this module's own (nothing without facts).
  if needs >= 8 then
    function M.Fact(factId, name, key) return readFact(factId, name, key) end
    function M.FactsChanged() factsChanged(rec) end
  end
  return M
end

-- ---------- the global ----------

-- The global's backing tables; the global itself is a read-only proxy over them (readOnly above).
local comm, compat = {}, {}

-- Modules refused because they need a newer API: { [id] = needs }, only for an id that passes the id rule and MAX_ID
-- (a bad id is refused with no entry). A module registering a suite id with a too-high needs marks that id's row, so
-- the row is only as trustworthy as the addons loaded on this client. Hub-only, read by the Modules page;
-- never on the global or a handle (d404).
ns.NeedsNewer = ns.NeedsNewer or {}
ns.API = API -- hub-only, for the Modules page's "API <n>" (never on the global or a handle)
local api = { API = API, MinAPI = MIN_API, Version = ns.VERSION }

-- The version the needs-newer refusal names: a suite module's TOC version as the Modules tooltip shows it, so chat and
-- tooltip read the same (q319, d854); an id outside the suite keeps its RegisterModule version.
local function shownVersion(id, version)
  for _, e in ipairs(ns.SUITE or {}) do
    if not e.hub and e.id == id then
      local a = ns.Compat.AddOn(e.folder)
      return a and a.version
    end
  end
  return version
end

-- mod = { id, title, version, needs, page, slash, selftest, status, scan, events, onEvent, onLogin, apis }.
-- Returns the handle M, or nil after exactly one chat line.
function api.RegisterModule(mod)
  if type(mod) ~= "table" then refuse("RegisterModule takes a table") return nil end
  -- one rule for names: title and id are trimmed of surrounding spaces first, and every check sees the trimmed value
  local title = trim(mod.title)
  -- the name in this function's chat lines: cut to MAX_TITLE, then every | doubled once here (f3350, f3351); raw goes
  -- to NeedsNewerLine, which escapes it itself
  local raw = (type(title) == "string" and title or tostring(mod.id or "a module")):sub(1, MAX_TITLE)
  local label = ns.Escape(raw)
  local piece = missingPiece()
  if piece then say("GuildSync did not load fully (" .. piece .. "); " .. label .. " was not loaded.") return nil end

  local needs = mod.needs == nil and 1 or mod.needs
  if type(needs) ~= "number" or needs ~= math.floor(needs) then refuse(label .. ": needs is not a whole number") return nil end
  if needs > MAX_NEEDS then refuse(label .. ": needs " .. needs .. " is above " .. MAX_NEEDS) return nil end
  if needs > API then
    local id = trim(mod.id)
    if type(id) == "string" and string.find(id, "^[a-z][a-z0-9]*$") and #id <= MAX_ID then ns.NeedsNewer[id] = needs end
    say(ns.View.NeedsNewerLine(raw, shownVersion(id, mod.version), needs, ns.VERSION, API)) -- the Modules tooltip's wording (q319)
    return nil
  end
  if needs < MIN_API then
    refuse(label .. " needs GuildSync API " .. needs .. ", older than this GuildSync's oldest (" .. MIN_API .. ")")
    return nil
  end

  local id = trim(mod.id)
  if type(id) ~= "string" or not string.find(id, "^[a-z][a-z0-9]*$") then
    refuse(label .. ": the id must be lower-case letters and digits, starting with a letter") return nil
  end
  if #id > MAX_ID then refuse(label .. ": the id \"" .. id .. "\" is longer than " .. MAX_ID .. " characters") return nil end
  if WORDS[id] then refuse(label .. ": the id \"" .. id .. "\" is a /gsync command") return nil end
  if idTaken(id) then say("module \"" .. id .. "\" is already registered; the second one was not loaded.") return nil end

  if type(title) ~= "string" or title == "" or #title > MAX_TITLE then
    refuse(id .. ": the title must be 1 to " .. MAX_TITLE .. " characters") return nil
  end
  -- printable ASCII (0x20-0x7E) without |: a title cannot colour or link a line, nor look like another (NBSP, accents)
  if string.find(title, "[^\032-\123\125\126]") then
    refuse(id .. ": the title may hold only printable ASCII letters, digits, spaces and punctuation, no |") return nil
  end
  if titleTaken(title) then refuse(id .. ": the title \"" .. title .. "\" is taken") return nil end

  for _, field in ipairs(FUNCTION_FIELDS) do
    if mod[field] ~= nil and type(mod[field]) ~= "function" then refuse(title .. ": " .. field .. " is not a function") return nil end
  end
  if mod.page ~= nil and type(mod.page) ~= "table" then refuse(title .. ": page is not a table") return nil end
  -- API 2: demo(guild, now) -> state. API 1 ignores unknown fields, so a needs-1 module's demo is never read.
  local demo = needs >= 2 and mod.demo or nil
  if demo ~= nil and type(demo) ~= "function" then refuse(title .. ": demo is not a function") return nil end
  -- API 3: settings(S) adds the module's sub-page under GuildSync in the game's Options (needs 1 and 2 ignore it).
  local settings = needs >= 3 and mod.settings or nil
  if settings ~= nil and type(settings) ~= "function" then
    refuse(title .. ": settings is not a function") return nil
  end
  -- API 7: member = { build(frame), refresh(frame, key) }, a section in the Roster member panel (needs 1-6 ignore it).
  -- Read once, its two fields raw (f4352), copied here.
  local member = needs >= 7 and mod.member or nil
  if member ~= nil then
    if type(member) ~= "table" then refuse(title .. ": member is not a table") return nil end
    local build, refresh = rawget(member, "build"), rawget(member, "refresh")
    if type(build) ~= "function" then refuse(title .. ": member.build is not a function") return nil end
    if type(refresh) ~= "function" then refuse(title .. ": member.refresh is not a function") return nil end
    member = { id = id, title = title, build = build, refresh = refresh }
  end
  -- API 8: facts = { <name> = function(key) return value end }, read once and copied (needs 1-7 ignore it).
  local facts = needs >= 8 and mod.facts or nil
  if facts ~= nil then
    local why
    facts, why = copyFacts(title, facts)
    if not facts then refuse(why) return nil end
    if next(facts) == nil then facts = nil end -- an empty table declares no facts (f6219): no fires, FactsChanged inert
  end
  -- API 8: search = { find(text) -> rows }, read once and find raw once (f4352); Search.lua runs it (needs 1-7 ignore it).
  local search = needs >= 8 and mod.search or nil
  if search ~= nil then
    if type(search) ~= "table" then refuse(title .. ": search is not a table") return nil end
    search = rawget(search, "find")
    if type(search) ~= "function" then refuse(title .. ": search.find is not a function") return nil end
  end

  local events = stringList(mod.events)
  if not events then refuse(title .. ": events is not a list of event names") return nil end
  for _, name in ipairs(events) do
    if name == "ADDON_LOADED" then refuse(title .. ": ADDON_LOADED is not open to modules") return nil end
  end

  local apis = mod.apis
  if apis ~= nil and type(apis) ~= "table" then refuse(title .. ": apis is not a table") return nil end
  local required = stringList(apis)
  local optional = stringList(apis and apis.optional)
  if not required or not optional then refuse(title .. ": apis is not a list of function names") return nil end
  for _, list in ipairs({ required, optional }) do
    for _, name in ipairs(list) do
      if namesSend(name) then refuse(title .. ": apis may not name " .. name .. " (only GuildSync sends)") return nil end
      if namesScript(name) then refuse(title .. ": apis may not name " .. name .. " (it runs code)") return nil end
    end
  end

  local rec = { name = title, id = id, status = escapedStatus(mod.status), scan = mod.scan, slash = mod.slash, events = events,
    onEvent = mod.onEvent, onLogin = mod.onLogin, demo = demo, missingEvents = {},
    facts = facts, factsEarly = facts ~= nil and not ns.LoggedIn(), search = search }
  if mod.selftest or apis or #events > 0 then
    rec.selftest = wrapSelftest(rec, mod.selftest, required, optional)
  end
  local all = {}
  for _, name in ipairs(required) do all[#all + 1] = name end
  for _, name in ipairs(optional) do all[#all + 1] = name end
  local calls = type(ns.Compat.CallList) == "function" and ns.Compat.CallList(all) or nil

  ns.RegisterModule(rec)
  if facts and not rec.factsEarly then factsChanged(rec) end -- a provider that loaded after login
  local page = mod.page
  local W = ns.Window
  if page and type(W.AddModulePage) == "function" then
    local ok = W.AddModulePage({ key = "m:" .. id, title = title, label = title, icon = page.icon,
      build = page.build, refresh = page.refresh })
    if ok then rec.page = "m:" .. id -- Search.lua's Modules rows open it
    else say(title .. ": page skipped, the window was already built; /reload shows it.") end
  end
  if settings and type(W.AddModuleSettings) == "function" then
    W.AddModuleSettings({ title = title, add = settingsAdder(id, title, settings, needs) })
  end
  -- Only the late case has a line; any other refusal by Window leaves the module without a section, quietly.
  if member and type(W.AddMemberSection) == "function" then
    local _, why = W.AddMemberSection(member)
    if why == "section after window built" then
      say(title .. ": member section skipped, the window was already built; /reload shows it.")
    end
  end
  return newHandle(rec, calls, needs)
end

function api.Say(text) ns.Say(text) end

-- text with every | doubled: how another player's text is shown in chat or on a page.
function api.Escape(text) return ns.Escape(text) end

-- "tell" | "fallback": opens a whisper to name with text ready in the chat box.
-- While /gsync demo is on it says the inert line and opens nothing (the names on screen are made up).
function api.OpenWhisper(name, text)
  if ns.Demo and ns.Demo.On() then say(ns.Demo.LINES.inert) return nil end
  local f = ns.Compat.OpenWhisper
  if type(f) ~= "function" then return nil end
  return f(name, text)
end

-- rows (a fresh deep copy per call), partial, serial (rises when the hub reads a new roster), known.
local lastRef, serial = nil, 0
function comm.Roster()
  local rows, partial, ref, known = ns.Comm.Roster()
  if ref ~= lastRef then lastRef, serial = ref, serial + 1 end
  return ns.PlainCopy(rows), partial and true or false, serial, known and true or false
end
-- A copy of one member's roster row, or nil (cheaper than Roster() for one name).
function comm.Member(name)
  if type(name) ~= "string" then return nil end
  local key = ns.Comm.Wire.Key(name)
  local row = key and (ns.Comm.Roster())[key]
  return row and ns.PlainCopy(row) or nil
end
function comm.IsOfficer(name) return ns.Comm.IsOfficer(name) and true or false end
function comm.Key(name) return ns.Comm.Wire.Key(name) end
-- API 7 (R9): the person nameOrKey belongs to, by d835 after the roster filter; a deep copy, or nil.
function comm.Person(nameOrKey) return personOf(nameOrKey) end
function comm.MyKey()
  local f = ns.Comm.MyKey
  if type(f) ~= "function" then return nil end
  return f()
end

function compat.Has(dotted) return ns.Compat.Has(dotted) end
function compat.Plain(v) return ns.Compat.Plain(v) end

api.Comm, api.Compat = readOnly(comm), readOnly(compat)
ns.GuildSync = api -- the hub's own reference, never the writable global name
_G.GuildSync = readOnly(api) -- through _G, so the global is a real global, not a file local
