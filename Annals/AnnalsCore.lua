-- Annals AnnalsCore: the driver. Events -> roster reads -> AnnalsStore, throttled to one read a minute with one
-- trailing read (as GuildSync's Roster.lua:21-44, 120-137), the login schedule and the 10 s retry (plan D9), own
-- dings and the once-per-session do-not-invite line for officers. The demo is GuildSync's (M.Demo, window plan D7);
-- /annals lives in AnnalsModule. Runs only when GuildSync registered the module (D2): without M it sets ns.AnnalsCore
-- and stops before registering any event.
-- Reads only ns.Annals* and the Lua whitelist; every client call goes through ns.AnnalsHost.
local _, ns = ...
local Rules, Store, Host = ns.AnnalsRules, ns.AnnalsStore, ns.AnnalsHost
local Feats = ns.AnnalsFeats -- Feats.Check is looked up at each call
local Core = {}
ns.AnnalsCore = Core

local M = ns.AnnalsModule and ns.AnnalsModule.M

local T_DNI = "Do not invite: %s is in the guild. %s"

-- `|` doubled, as View escapes every row text (security s1), so the chat frame draws it as a plain character
-- (review f11).
local function esc(v)
  return (string.gsub(tostring(v), "|", "||"))
end

local lastRead = nil        -- server time of the last applied read (the throttle)
local trailingQueued = false
local retryQueued = false
local failures = 0
local firstOfSession = true -- cleared only after Store.ApplyRead ran (D6, G2)
local lastLog, lastLogAt = nil, nil
local said = {}             -- do-not-invite ids already said this session
local demoGen = 0           -- +1 each time M.Demo()'s (on, state) changes; never saved (C2, window plan D7)
local seenOn, seenState = false, nil
local logSeen = false       -- this session ran Store.ApplyLog (phase B D4)
local riseRv = false        -- G.rv at the last full read check; false so the session's first check sees rises (D4)
local requests = 0          -- roster requests this session (request() below)
local afk = nil             -- Rules.AfkRuns' answer at the last applied read; never saved (D10)
Core.readDone = false       -- an applied read this session (the selftest, D14)

function Core.Now() return Host.Now() end
function Core.MaxLevel() return Rules.MaxLevel(Host.MaxLevels()) end
-- Whose journey is "yours" on the Journey page (plan D7): the demo's own self while the demo is on.
function Core.JourneySelf()
  if Core.Demo() then return Rules.DEMO_SELF end
  return Host.MyGuid()
end

-- The current guild's data, or nil while the guild name is unknown (nothing is stored then, f5).
function Core.G()
  local name = Host.Guild()
  if not name then return nil end
  return Store.Guild(Host.DB(), name)
end

-- The demo is GuildSync's /gsync demo (window plan D7): M.Demo() gives on and the state Annals' demo() returned. The
-- pages read Core.PageG(); reads, own dings and the do-not-invite chat line stay on the real store (AC4, D6).
function Core.Demo()
  if not M then return false end
  return (M.Demo()) == true
end

-- Rises when M.Demo()'s pair (on, state) differs by identity from the last one seen; no listener involved.
function Core.DemoGen()
  if not M then return demoGen end
  local on, state = M.Demo()
  on = on == true
  if on ~= seenOn or state ~= seenState then
    seenOn, seenState = on, state
    demoGen = demoGen + 1
  end
  return demoGen
end

-- What the pages show: the demo state while the demo is on (nil when demo() threw), else the real G.
function Core.PageG()
  if not Core.Demo() then return Core.G() end
  local _, state = M.Demo()
  if type(state) == "table" then return state end
  return nil
end

function Core.DniAdd(name, guid, reason)
  local G = Core.PageG()
  if not G then return nil, "not in a guild" end
  local id, err = Store.DniAdd(G, name, guid, reason, Host.Now())
  if id then Host.Refresh() end
  return id, err
end

function Core.DniRemove(id)
  local G = Core.PageG()
  if not G then return end
  Store.DniRemove(G, id)
  if not Core.Demo() then said[id] = nil end -- a demo remove leaves the real session's lines alone (R3)
  Host.Refresh()
end

if not M then return end -- not registered: no event, no read (D2)

local read

local function retry()
  failures = failures + 1
  if retryQueued or failures > Rules.RETRY_MAX then return end
  retryQueued = true
  Host.After(Rules.RETRY_GAP, function()
    retryQueued = false
    read()
  end)
end

local function sayHits(G)
  if not Host.IsOfficer() then return end
  for _, hit in ipairs(Store.DniHits(G)) do
    if not said[hit.id] then
      said[hit.id] = true
      Host.Say(string.format(T_DNI, esc(hit.name), esc(hit.why or "")))
    end
  end
end

-- Feats.Check on the real G (never the demo G, D13) with D4's ctx; answers the error when it throws, so the caller
-- finishes its work first.
local function check(G, now, isRead, members)
  local ctx = { read = isRead, full = isRead and not G.lastPartial, hour = isRead and Host.ServerHour() or nil,
    self = Host.MyGuid(), rises = G.rv ~= riseRv, logSeen = logSeen,
    logCycle = requests > Rules.LOG_REQUEST_EVERY, maxLevel = Core.MaxLevel(),
    members = isRead and members or nil, afk = isRead and afk or nil }
  local good, err = pcall(Feats.Check, G, now, ctx)
  if not good then return err end
  if ctx.read and ctx.full then riseRv = G.rv end
  return nil
end

read = function()
  local now = Host.Now()
  if lastRead and now - lastRead < Rules.READ_GAP then
    if not trailingQueued then
      trailingQueued = true
      Host.After(Rules.READ_GAP - (now - lastRead) + 1, function()
        trailingQueued = false
        read()
      end)
    end
    return
  end
  local name = Host.Guild()
  if not name then return retry() end
  local members, count, total = Host.Members()
  if not members then return retry() end
  failures = 0
  local prevAt = lastRead
  lastRead = now
  afk = Rules.AfkRuns(afk, prevAt, members, now)
  local G = Store.Guild(Host.DB(), name)
  Store.ApplyRead(G, members, count, total, now, firstOfSession)
  firstOfSession = false
  Core.readDone = true
  if lastLog then
    Store.ApplyLog(G, lastLog, lastLogAt)
    logSeen = true
  end
  Store.Prune(G, now)
  local err = check(G, now, true, members)
  sayHits(G)
  Host.Refresh()
  if err then error(err, 0) end -- recorded by the Host once the read is done
end

-- One request now, then the next one Rules.REQUEST_GAP later, for as long as the session runs. Out of a guild nothing is
-- asked, but the timer keeps going so a joined guild is picked up.
local function request()
  if Host.Guild() then
    if requests % Rules.LOG_REQUEST_EVERY == 0 then Host.RequestGuildLog() end
    Host.RequestRoster()
    requests = requests + 1
  end
  Host.After(Rules.REQUEST_GAP, request)
end

local function onEvent(event, ...)
  if event == "PLAYER_LOGIN" then
    Host.After(Rules.LOGIN_REQUEST, request)
    Host.After(Rules.LOGIN_READ, read)
  elseif event == "GUILD_EVENT_LOG_UPDATE" then
    -- kept and applied after each read, with the time it was read (the entries carry ages)
    local log = Host.GuildLog()
    if log then lastLog, lastLogAt = log, Host.Now() end
  elseif event == "PLAYER_LEVEL_UP" then
    local G = Core.G()
    local guid = Host.MyGuid()
    if not G or not guid then return end
    local level = tonumber((...)) or Host.MyLevel()
    local now = Host.Now()
    if Store.OwnDing(G, guid, level, now) then
      local err = check(G, now, false)
      Host.Refresh()
      if err then error(err, 0) end
    end
  else -- GUILD_ROSTER_UPDATE, CLUB_MEMBERS_UPDATED, CLUB_MEMBER_UPDATED, PLAYER_GUILD_UPDATE
    read()
  end
end

local mod = { events = { "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "CLUB_MEMBERS_UPDATED", "CLUB_MEMBER_UPDATED",
  "PLAYER_GUILD_UPDATE", "GUILD_EVENT_LOG_UPDATE", "PLAYER_LEVEL_UP" } }
Core.mod = mod
for _, event in ipairs(mod.events) do Host.On(event, onEvent) end
