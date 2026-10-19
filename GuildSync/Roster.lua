-- GuildSync Roster: the guild member list (keyed by GUID, with both professions of every member) and the
-- game's own guild event log. Read from the guild's club member list, the way Blizzard's guild pane does:
-- Compat focuses the member list before the first read, and again on every third empty answer.
-- Member names and guild log names (actor, target) are stored without the realm suffix (Compat.ShortName).
-- Officer notes are only recorded when this character can see them. Throttled to once a minute.
-- After an officer action (Window.lua) the next roster event is read at once, past the throttle (ns.Roster).

local ADDON, ns = ...
local Compat = ns.Compat

local THROTTLE = 60
local lastScan = 0
local trailingQueued = false
local failures = 0
local lastReason = nil
local MAX_RETRIES = 12
local ACCEPT_PARTIAL_AFTER = 5
local scanRoster
local forceNext = false -- an officer action just ran: the next roster event scans at once, past the throttle

-- The club member list arrives some time after login. Look again shortly instead of waiting for the next event.
local function retrySoon()
  lastScan = 0
  if failures > MAX_RETRIES then return end
  ns.After(10, function()
    ns.WhenUnrestricted("roster", function() scanRoster(false) end, "Roster")
  end, "Roster")
end

scanRoster = function(force)
  if not Compat.IsInGuild() then return end
  local now = time()
  if not force and now - lastScan < THROTTLE then
    -- GUILD_ROSTER_UPDATE fires a lot: remember to look once more when the minute is over
    if not trailingQueued then
      trailingQueued = true
      ns.After(THROTTLE - (now - lastScan) + 1, function()
        trailingQueued = false
        ns.WhenUnrestricted("roster", function() scanRoster(false) end, "Roster")
      end, "Roster")
    end
    return
  end
  lastScan = now

  local canSeeOfficerNotes = Compat.CanViewOfficerNote()
  -- Compat focuses the list before the first read; after a few empty answers, ask the client to stream it again
  local members, countOrReason = Compat.GuildMembers(canSeeOfficerNotes, failures >= 3 and failures % 3 == 0)
  if not members then
    failures = failures + 1
    lastReason = countOrReason
    retrySoon()
    return
  end
  -- a half-loaded list would look like a wave of people leaving: wait for the full one
  local expected = Compat.GuildMemberTotal()
  local partial = expected ~= nil and expected > 0 and countOrReason < expected
  if partial and failures < ACCEPT_PARTIAL_AFTER then
    failures = failures + 1
    lastReason = "member list incomplete, " .. countOrReason .. " of " .. expected
    retrySoon()
    return
  end
  failures, lastReason = 0, nil

  local db = ns.DB()
  local guildName, guildRealm = Compat.GuildInfo()
  local c = ns.Char()
  local old = type(db.guild) == "table" and db.guild or {}
  db.guild = {
    name = guildName or old.name,
    realm = guildRealm or (c and c.realm) or old.realm,
    by = ns.CharKey(),
    canSeeOfficerNotes = canSeeOfficerNotes,
    ranks = Compat.GuildRanks() or old.ranks,
    members = members,
    count = countOrReason,
    partial = partial or nil, -- true: fewer members than the guild has, do not read absences as leaves
  }
  ns.Fire("rosterRead", partial and true or false, countOrReason) -- module addons hear the read (M.On)
  ns.CheckGate() -- a known roster can open the comm gate
end

-- Native guild log entry -> { type, actor, target, rank, ts }, read the way Blizzard's guild log pane reads it:
-- invite, promote, demote, remove: player1 acts on player2. join, quit: player1 is the member, nobody acts.
local ACTED = { invite = true, promote = true, demote = true, remove = true }
local SOLO = { join = true, quit = true }

local function scanGuildLog()
  if not Compat.IsInGuild() then return end
  local raw = Compat.GuildEvents()
  if not raw or #raw == 0 then return end
  local now = time()
  local entries = {}
  for _, e in ipairs(raw) do
    local hoursAgo = ((((e.year * 12) + e.month) * 30.5 + e.day) * 24 + e.hour)
    local ts = math.floor((now - hoursAgo * 3600) / 3600 + 0.5) * 3600
    if ACTED[e.type] then
      table.insert(entries, { type = e.type, actor = Compat.ShortName(e.player1), target = Compat.ShortName(e.player2), rank = e.rank, ts = ts })
    elseif SOLO[e.type] then
      table.insert(entries, { type = e.type, target = Compat.ShortName(e.player1), ts = ts })
    end
  end
  ns.DB().guildLog = { entries = entries }
end

-- Officer actions (Window.lua, 0.9): ask for a fresh roster and read the next update at once, and scan now on demand.
ns.Roster = {
  ExpectChange = function()
    forceNext = true
    Compat.RequestGuildRoster()
    Compat.RequestGuildEventLog()
  end,
  ScanNow = function()
    if not Compat.EncounterRestricted() then scanRoster(true) end
  end,
}

ns.RegisterModule({
  name = "Roster",
  events = { "PLAYER_LOGIN", "GUILD_ROSTER_UPDATE", "CLUB_MEMBERS_UPDATED", "INITIAL_CLUBS_LOADED", "PLAYER_GUILD_UPDATE", "GUILD_EVENT_LOG_UPDATE" },
  onEvent = function(event)
    if event == "PLAYER_LOGIN" then
      ns.After(5, function()
        if not Compat.IsInGuild() then return end
        Compat.RequestGuildRoster()
        Compat.RequestGuildEventLog()
      end, "Roster")
      ns.After(12, function()
        ns.WhenUnrestricted("roster", function() scanRoster(false) end, "Roster")
      end, "Roster")
    elseif event == "GUILD_EVENT_LOG_UPDATE" then
      ns.WhenUnrestricted("guildlog", scanGuildLog, "Roster")
    else
      local force = forceNext
      forceNext = false
      ns.WhenUnrestricted("roster", function() scanRoster(force) end, "Roster")
    end
  end,
  scan = function()
    if not Compat.IsInGuild() then return end
    Compat.RequestGuildRoster()
    Compat.RequestGuildEventLog()
    if not Compat.EncounterRestricted() then
      scanRoster(true)
      scanGuildLog()
    end
  end,
  status = function()
    local db = ns.DB()
    local g, log = db.guild, db.guildLog
    if not Compat.IsInGuild() and type(g) ~= "table" then return "not in a guild" end
    local line
    if type(g) == "table" then
      line = tostring(g.count or ns.Count(g.members)) .. " members of " .. tostring(g.name or "?")
        .. ", officer notes " .. (g.canSeeOfficerNotes and "visible" or "not visible")
    else
      line = "roster not recorded yet" .. (lastReason and (" (" .. lastReason .. ")") or "")
    end
    if type(log) == "table" and type(log.entries) == "table" then
      line = line .. ", guild log " .. #log.entries .. " entries"
    else
      line = line .. ", guild log not read yet"
    end
    return line
  end,
  -- /gsync selftest: read only (Comm.Roster's "known" is this session's read; the guild table is read raw)
  selftest = function()
    local known = ns.Comm and ns.Comm.Roster and select(4, ns.Comm.Roster())
    if not known then
      if Compat.EncounterRestricted() then return "wait", "restricted" end
      if not Compat.IsInGuild() then return "fail", "not in a guild" end
      return "wait", "roster not read yet" .. (lastReason and (" (" .. tostring(lastReason) .. ")") or "")
    end
    local db = ns.SavedDB()
    local g = db and type(db.guild) == "table" and db.guild or {}
    local members = type(g.members) == "table" and g.members or {}
    local n = type(g.count) == "number" and g.count or ns.Count(members)
    if g.partial then return "wait", "roster partial, " .. n .. " read" end
    local online = 0
    for _, m in pairs(members) do
      if type(m) == "table" and m.online then online = online + 1 end
    end
    return "pass", n .. " members, " .. online .. " online"
  end,
})
