-- GuildSync Demo: the /gsync demo switch (t40 R5). While on, every page draws the made-up guild (DemoGuild.lua), the
-- comm queue sends nothing (CommQueue's Gate answers "demo"), guild actions are refused at the client call (Compat's
-- ACT_NAMES) and errors are scrubbed of demo names before they are saved.
-- Saved: only GuildSyncDB3.demo (true or nil), account-wide, so /reload keeps demo until it is turned off. The demo guild,
-- its log and each module's demo state live in this file's locals only and are never written to saved data.

local _, ns = ...

local Demo = {}
ns.Demo = Demo

Demo.LINES = {
  on = "Demo on: a made-up guild fills every page. Nothing is sent or saved. /gsync demo off ends it.",
  off = "Demo off: the real pages are back.",
  notOn = "Demo is not on.",
  status = "Demo is on (a made-up guild). /gsync demo off ends it.",
  failed = "Demo could not start and is off.",
  inert = "Demo: nothing is done to made-up members.",
  banner = "DEMO: a made-up guild. Nothing is sent or saved.",
}

-- Compat.GuildPermissions' shape for a guild leader: in demo every officer part shows to every rank (q213), and every
-- action it offers is refused (ACT_NAMES), since no demo member is real.
Demo.PERMS = { rankIndex = 0, leader = true, flagsRead = true, promote = true, demote = true, remove = true,
  editPublic = true, editOfficer = true }

local on, guild, log, now, names = false, nil, nil, nil, nil
local serial = 0
local building, announced = false, false -- inside start(); the "demo"(true) event went out for this session
local lowered = {} -- every demo name lower-cased, and without spaces (a realm-suffixed key), while on
local scrubs = {} -- case-insensitive patterns of every demo name built this UI session; kept after off (f1352)
local called, states = {}, {} -- module record -> true / its demo state, this session only

function Demo.On() return on end
function Demo.Serial() return serial end
function Demo.StateOf(rec) if on then return states[rec] end return nil end

-- guild, log, perms: the demo ones while on, else the real saved roster, log and this character's permissions.
function Demo.Source()
  if on then return guild, log, Demo.PERMS end
  local db = ns.DB()
  return db.guild, db.guildLog, ns.Compat.GuildPermissions()
end

-- text with every demo name of this UI session replaced by <demo>, in any case (nothing before the first demo).
-- Kept after off, so a module's late timer cannot save a demo name either.
function Demo.Scrub(text)
  text = tostring(text)
  for _, pattern in ipairs(scrubs) do text = string.gsub(text, pattern, "<demo>") end
  return text
end

-- true while demo is on when any string argument holds a demo name, in any case, with or without its space
-- ("Name-Realm", "NameSurname-Realm", inside a chat line). Compat refuses such a client call, whatever the function.
function Demo.Mentions(...)
  if not on then return false end
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" then
      local low = string.lower(v)
      for _, n in ipairs(lowered) do
        if string.find(low, n, 1, true) then return true end
      end
    end
  end
  return false
end

local function anyCase(text)
  return (string.gsub(string.gsub(text, "%p", "%%%0"), "%a",
    function(ch) return "[" .. string.lower(ch) .. string.upper(ch) .. "]" end))
end

local scrubbed = {} -- name -> true once its patterns are in scrubs: each name once per UI session, however many toggles

local function learn(list)
  lowered = {}
  for _, name in ipairs(list) do
    local squeezed = string.gsub(name, " ", "")
    lowered[#lowered + 1] = string.lower(name)
    lowered[#lowered + 1] = string.lower(squeezed)
    if not scrubbed[name] then
      scrubbed[name] = true
      scrubs[#scrubs + 1] = anyCase(name)
      scrubs[#scrubs + 1] = anyCase(squeezed)
    end
  end
end

-- A module record's demo(guild, now), once per session, on its own copy of the guild (the log rides as guild.log).
function Demo.Joined(rec)
  if not on or type(rec) ~= "table" or type(rec.demo) ~= "function" or called[rec] then return end
  called[rec] = true
  local copy = ns.PlainCopy(guild)
  copy.log = ns.PlainCopy(log)
  local ok, state = pcall(rec.demo, copy, now)
  if ok then states[rec] = state else ns.RecordError(rec.title or rec.name, state) end
end

-- Ends the session and the saved flag.
local function clear()
  on, guild, log, now, names = false, nil, nil, nil, nil
  called, states, lowered = {}, {}, {}
  building, announced = false, false
  ns.DB().demo = nil
end

-- Undoes a start that threw: listeners that heard "demo"(true) hear "demo"(false) (f1347).
local function undo()
  local heard = announced
  clear()
  if heard then
    serial = serial + 1
    ns.Fire("demo", false)
    pcall(ns.CheckGate)
  end
end

-- Builds the session (throws when the build does) and hands every module its state.
local function start()
  local t = ns.Compat.ServerTime() or time()
  local g, l = ns.DemoGuild.Build(t)
  g.by = ns.CharKey() -- Window's own-roster check passes for the demo guild
  guild, log, now, names = g, l, t, ns.DemoGuild.Names(g)
  learn(names)
  on = true
  serial = serial + 1
  building = true -- a builder that toggles demo is refused (f1354)
  for _, rec in ipairs(ns.modules) do Demo.Joined(rec) end
  building = false
  announced = true
  ns.Fire("demo", true)
  ns.CheckGate()
end

-- Turns demo on or off; true when it changed. Off pumps the held sends (paced: one chunk per gap per prefix).
function Demo.Set(want)
  want = want and true or false
  if building or want == on then return false end
  if want then
    ns.DB().demo = true
    local ok, err = pcall(start)
    if not ok then
      undo()
      error(err, 0)
    end
  else
    clear()
    serial = serial + 1
    ns.Fire("demo", false)
    ns.CheckGate()
    if ns.Comm and ns.Comm.Queue and ns.Comm.Queue.Pump then ns.Comm.Queue.Pump() end
  end
  return true
end

-- PLAYER_LOGIN, before Window.Login: a saved flag restores demo (times from this login), or clears itself on a throw.
function Demo.Login()
  if ns.DB().demo ~= true then ns.DB().demo = nil return end
  local ok, err = pcall(start)
  if ok then ns.Say(Demo.LINES.status) return end
  undo()
  ns.RecordError("Demo", err)
  ns.Say(Demo.LINES.failed)
end

return Demo
