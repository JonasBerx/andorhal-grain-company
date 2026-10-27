-- Annals, AnnalsHost: the ONE host file. It is the only Annals file that touches a client global: the event
-- frame, the saved table, the slash command, timers, chat, the tooltip and the GuildSync hub. Every client function is
-- reached through the local call() with a dotted name listed in Host.APIS (copied, not required, from GuildSync's
-- Compat.lua:17-108); every other client value through resolve() with a name listed in Host.VALUES. Beyond the Lua
-- whitelist, the only globals named directly are _G (for resolve), time (the fallback of Host.Now), AnnalsDB,
-- SlashCmdList and SLASH_ANNALS1.
--
-- Annals is a GuildSync module (window plan D2-D4): the page lives in the GuildSync window. Host.RegisterModule hands
-- the spec to GuildSync.RegisterModule; AnnalsModule.lua builds the page and sets what Host.Refresh runs
-- (Host.SetRefresh). Host.HubSlash reaches the hub's /gsync handler for the /annals demo alias until API 4 has a
-- public demo switch.

local ADDON, ns = ...

local Host = {}
ns.AnnalsHost = Host

-- ---------- plumbing (Compat.lua:17-108, only the names this file uses) ----------

Host.APIS = {
  "GetServerTime", "GetGameTime", "issecretvalue",
  "C_Timer.After",
  "C_RestrictedActions.IsAddOnRestrictionActive",
  "UnitGUID", "UnitLevel",
  "IsInGuild", "GetGuildInfo",
  "C_Club.GetGuildClubId", "C_Club.GetClubMembers", "C_Club.GetMemberInfo", "C_Club.FocusMembers",
  "C_CreatureInfo.GetClassInfo", "C_CreatureInfo.GetRaceInfo", "C_GuildInfo.GuildRoster", "C_GuildInfo.CanViewOfficerNote",
  "GetNumGuildMembers", "QueryGuildEventLog", "GetNumGuildEvents", "GetGuildEventInfo",
  "GetMaxPlayerLevel", "GetMaxLevelForPlayerExpansion",
  "CreateFrame", "C_ClassColor.GetClassColor",
  "GetMoney", "GetZoneText", "C_ChatInfo.InChatMessagingLockdown",
  "date",
}

-- Non-function globals and enums this file reads.
Host.VALUES = {
  "Enum.AddOnRestrictionType.Encounter", "Enum.ClubMemberPresence.Online", "UIParent",
  "RAID_CLASS_COLORS", "DEFAULT_CHAT_FRAME", "GuildSync", "GameTooltip",
}

Host.errors = {}

local PREFIX = "|cffd4a24cAnnals|r: "
local MAX_ERRORS = 50

local listed = {}
for _, name in ipairs(Host.APIS) do listed[name] = true end

local function resolve(path)
  local obj = _G
  for part in string.gmatch(path, "[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
    if obj == nil then return nil end
  end
  return obj
end

local function pack(...) return { n = select("#", ...), ... } end

-- Calls a client function by dotted name. Returns nothing when it is missing or when it throws.
local function call(path, ...)
  if not listed[path] then return nil end
  local fn = resolve(path)
  if type(fn) ~= "function" then return nil end
  local r = pack(pcall(fn, ...))
  if not r[1] then return nil end
  return unpack(r, 2, r.n)
end

local function has(path) return type(resolve(path)) == "function" end

-- A secret value (read under a restriction) becomes nil before anything compares it.
local function plain(v)
  local fn = resolve("issecretvalue")
  if type(fn) == "function" then
    local good, secret = pcall(fn, v)
    if good and secret then return nil end
  end
  return v
end

local function str(v)
  v = plain(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function num(v)
  v = plain(v)
  if type(v) == "number" then return v end
  return nil
end

-- ---------- chat, errors, time, timers ----------

function Host.Say(text)
  local frame = resolve("DEFAULT_CHAT_FRAME")
  if type(frame) == "table" and type(frame.AddMessage) == "function" then
    frame:AddMessage(PREFIX .. tostring(text))
  end
end

-- Records an error once in Host.errors and says it in the own chat frame the first time it is seen.
local function record(where, err)
  local msg = tostring(where) .. ": " .. tostring(err)
  for _, e in ipairs(Host.errors) do if e == msg then return end end
  if #Host.errors >= MAX_ERRORS then table.remove(Host.errors, 1) end
  table.insert(Host.errors, msg)
  Host.Say("error in " .. msg)
end

local function safe(where, fn, ...)
  local r = pack(pcall(fn, ...))
  if not r[1] then record(where, r[2]) return nil end
  return unpack(r, 2, r.n)
end

-- The client's local time, through the client's date(): Host.Date(fmt, t) as date(fmt, t) ("*t" gives a table).
-- Times stay server (UTC) seconds everywhere else; this is only for showing them.
function Host.Date(fmt, t)
  local v = call("date", fmt, t)
  if type(v) == "string" or type(v) == "table" then return v end
  return nil
end

function Host.Now()
  return num(call("GetServerTime")) or time()
end

-- The realm clock's hour (GetGameTime's first return): an integer 0-23, else nil.
function Host.ServerHour()
  local h = num((call("GetGameTime")))
  if h and h >= 0 and h <= 23 and h == math.floor(h) then return h end
  return nil
end

-- Realm time minus UTC in seconds (D2): GetGameTime against GetServerTime, rounded to 15 minutes, in -10 h..+14 h;
-- Rules.REALM_OFFSET_FALLBACK when the realm clock cannot be read. It moves with daylight saving time.
function Host.RealmOffset()
  local h, m = call("GetGameTime")
  h, m = num(h), num(m)
  -- f3560: a clock out of range (not whole hours 0..23 and minutes 0..59) cannot be read either.
  if not h or not m or h < 0 or h > 23 or m < 0 or m > 59 or h ~= math.floor(h) or m ~= math.floor(m) then
    return ns.AnnalsRules.REALM_OFFSET_FALLBACK
  end
  local minutes = ((h * 60 + m) - math.floor((Host.Now() % 86400) / 60)) % 1440
  minutes = math.floor(minutes / 15 + 0.5) * 15
  if minutes > 840 then minutes = minutes - 1440 end
  return minutes * 60
end

function Host.After(seconds, fn)
  call("C_Timer.After", seconds, function() safe("timer", fn) end)
end

-- ---------- saved data ----------

local function ensureDB()
  if type(AnnalsDB) ~= "table" then AnnalsDB = { v = ns.AnnalsRules.DB_VERSION, guilds = {} } end
  if type(AnnalsDB.guilds) ~= "table" then AnnalsDB.guilds = {} end
  if AnnalsDB.v == nil then AnnalsDB.v = 1 end
  return AnnalsDB
end

function Host.DB() return ensureDB() end

-- ---------- events and the slash command ----------

local handlers = {}

function Host.CreateFrame(kind, name, parent, template)
  return call("CreateFrame", kind, name, parent or resolve("UIParent"), template)
end

local host = { events = { "ADDON_LOADED" } }

local eventFrame = Host.CreateFrame("Frame")

local function dispatch(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for _, fn in ipairs(list) do safe(event, fn, event, ...) end
end

if eventFrame then eventFrame:SetScript("OnEvent", dispatch) end

-- fn(event, ...) runs on every `event`; an error is recorded, never raised.
function Host.On(event, fn)
  if type(event) ~= "string" or type(fn) ~= "function" then return end
  if not handlers[event] then
    handlers[event] = {}
    if eventFrame then eventFrame:RegisterEvent(event) end
  end
  table.insert(handlers[event], fn)
end

for _, event in ipairs(host.events) do
  Host.On(event, function(_, name)
    if name ~= ADDON then return end
    ensureDB()
    -- Once per session: the realm offset, then the earned-string conversion (d518), whatever v is.
    local offset = Host.RealmOffset()
    ns.AnnalsFeats.SetRealmOffset(offset)
    ns.AnnalsStore.Upgrade(AnnalsDB, offset)
  end)
end

-- "/annals": fn(msg)
function Host.Slash(fn)
  SLASH_ANNALS1 = "/annals"
  SlashCmdList.ANNALS = function(msg) safe("/annals", fn, msg or "") end
end

-- ---------- the guild ----------

local function inGuild() return plain(call("IsInGuild")) == true end

function Host.Guild()
  if not inGuild() then return nil end
  return str((call("GetGuildInfo", "player")))
end

function Host.MyRankIndex()
  if not inGuild() then return nil end
  local _, _, rankIndex = call("GetGuildInfo", "player")
  return num(rankIndex)
end

function Host.MyGuid() return str((call("UnitGUID", "player"))) end
function Host.MyLevel() return num((call("UnitLevel", "player"))) end

-- An officer is whoever the hub counts as one: GuildSync.Comm.IsOfficer(GuildSync.Comm.MyKey()) (API.md, D240).
-- False with no hub, no Comm, no IsOfficer or MyKey, or no key yet.
function Host.IsOfficer()
  local comm = resolve("GuildSync.Comm")
  if type(comm) ~= "table" or type(comm.IsOfficer) ~= "function" or type(comm.MyKey) ~= "function" then return false end
  local key = comm.MyKey()
  if key == nil then return false end
  return comm.IsOfficer(key) == true
end

function Host.MaxLevels()
  return num((call("GetMaxPlayerLevel"))), num((call("GetMaxLevelForPlayerExpansion")))
end

function Host.CanViewOfficerNote() return plain(call("C_GuildInfo.CanViewOfficerNote")) == true end

function Host.RequestRoster() call("C_GuildInfo.GuildRoster") end
function Host.RequestGuildLog() call("QueryGuildEventLog") end

-- The Encounter restriction only (Compat.lua:142-147 without the chat lockdown: this addon never sends, and the
-- lockdown is on during PvP, plan G5).
local function encounterRestricted()
  local kind = resolve("Enum.AddOnRestrictionType.Encounter")
  if kind == nil then return false end
  return plain(call("C_RestrictedActions.IsAddOnRestrictionActive", kind)) == true
end

-- The own character's money in copper, else nil (a secret value reads as nil).
function Host.Money() return num((call("GetMoney"))) end

-- The zone text the client shows, else nil.
function Host.Zone() return str((call("GetZoneText"))) end

-- True only for a guild chat line whose sender guid (payload 12; the text is never read) is plainly the own guid,
-- outside the chat lockdown and the Encounter restriction. The sender is compared first, so another member's line
-- makes no lockdown or restriction call (f6690).
function Host.OwnGuildLine(senderGuid)
  local guid = str(senderGuid)
  local me = Host.MyGuid()
  if guid == nil or me == nil or guid ~= me then return false end
  if plain(call("C_ChatInfo.InChatMessagingLockdown")) == true then return false end
  if encounterRestricted() then return false end
  return true
end

local classTokens = {}
local function classToken(classID)
  if not classID then return nil end
  if classTokens[classID] == nil then
    local info = plain(call("C_CreatureInfo.GetClassInfo", classID))
    classTokens[classID] = (type(info) == "table" and str(info.classFile)) or false
  end
  return classTokens[classID] or nil
end

-- The race name for a ClubMemberInfo race id, cached by id as classToken is. A missing GetRaceInfo gives nil (R10).
local raceNames = {}
local function raceName(raceID)
  if not raceID then return nil end
  if raceNames[raceID] == nil then
    local info = plain(call("C_CreatureInfo.GetRaceInfo", raceID))
    raceNames[raceID] = (type(info) == "table" and str(info.raceName)) or false
  end
  return raceNames[raceID] or nil
end

local function isOnline(presence)
  if presence == nil then return false end
  local e = resolve("Enum.ClubMemberPresence")
  if type(e) == "table" then
    return presence == e.Online or presence == e.Away or presence == e.Busy
  end
  return presence == 1 or presence == 4 or presence == 5
end

local function isAway(presence)
  if presence == nil then return false end
  local e = resolve("Enum.ClubMemberPresence")
  if type(e) == "table" then return presence == e.Away end
  return presence == 4
end

local function shortName(name)
  if type(name) ~= "string" then return nil end
  return string.match(name, "^([^-]+)") or name
end

-- Compat.GuildMembers (Compat.lua:331-404) plus the total:
--   { [guid] = { name, rank, rankIndex, level, class, zone, race, online, lastOnlineDays, note, officerNote } }, count, total
-- nil, reason out of a guild, while the club or its member list is not ready, or under the Encounter restriction.
-- total is GetNumGuildMembers' answer as given (nil when missing); Store decides what is partial.
-- The club is focused before the first read and again on every third empty answer in a row (Roster.lua:51).
local focusedClub = nil
local emptyAnswers = 0
local function emptyAnswer(clubId, reason)
  emptyAnswers = emptyAnswers + 1
  if emptyAnswers % 3 == 0 then call("C_Club.FocusMembers", clubId) end
  return nil, reason
end
function Host.Members()
  if not has("C_Club.GetGuildClubId") or not has("C_Club.GetClubMembers") or not has("C_Club.GetMemberInfo") then
    return nil, "no club API"
  end
  if not inGuild() then return nil, "not in a guild" end
  if encounterRestricted() then return nil, "encounter restriction" end
  local clubId = plain(call("C_Club.GetGuildClubId"))
  if clubId == nil then return nil, "guild club not loaded yet" end
  if focusedClub ~= clubId then
    call("C_Club.FocusMembers", clubId)
    focusedClub = clubId
  end
  local ids = plain(call("C_Club.GetClubMembers", clubId))
  if type(ids) ~= "table" then return emptyAnswer(clubId, "no member list") end
  local withOfficerNotes = Host.CanViewOfficerNote()
  local members, count = {}, 0
  for _, memberId in ipairs(ids) do
    local info = plain(call("C_Club.GetMemberInfo", clubId, memberId))
    if type(info) == "table" then
      local guid, name = str(info.guid), str(info.name)
      if guid and name then
        local presence = plain(info.presence)
        local online = isOnline(presence)
        local ap = num(info.achievementPoints)
        local days
        local y, m, d, h = num(info.lastOnlineYear), num(info.lastOnlineMonth), num(info.lastOnlineDay), num(info.lastOnlineHour)
        if online then
          days = 0
        elseif y or m or d or h then
          days = (y or 0) * 365 + (m or 0) * 30 + (d or 0) + (((h or 0) >= 12) and 1 or 0)
        end
        local order = num(info.guildRankOrder)
        local member = {
          name = shortName(name),
          rank = str(info.guildRank), rankIndex = order and (order - 1) or nil,
          level = num(info.level), class = classToken(num(info.classID)), zone = str(info.zone),
          race = raceName(num(info.race)),
          online = online, lastOnlineDays = days,
          ap = (ap and ap > 0) and ap or nil, away = isAway(presence),
          note = str(info.memberNote),
        }
        if withOfficerNotes then member.officerNote = str(info.officerNote) end
        members[guid] = member
        count = count + 1
      end
    end
  end
  if count == 0 then return emptyAnswer(clubId, "member list empty") end
  emptyAnswers = 0
  return members, count, num((call("GetNumGuildMembers")))
end

-- Compat.GuildEvents (Compat.lua:481-495): the raw guild log, oldest first, names as the client gives them,
-- year/month/day/hour the entry's age.
function Host.GuildLog()
  if not has("GetNumGuildEvents") or not has("GetGuildEventInfo") then return nil end
  local n = num((call("GetNumGuildEvents")))
  if not n then return nil end
  local out = {}
  for i = 1, n do
    local kind, p1, p2, rank, y, m, d, h = call("GetGuildEventInfo", i)
    kind = str(kind)
    if kind then
      table.insert(out, { type = kind, player1 = str(p1), player2 = str(p2), rank = str(rank),
        year = num(y) or 0, month = num(m) or 0, day = num(d) or 0, hour = num(h) or 0 })
    end
  end
  return out
end

function Host.ClassColor(token)
  if type(token) ~= "string" then return nil end
  local c = plain(call("C_ClassColor.GetClassColor", token))
  if type(c) ~= "table" then
    local all = resolve("RAID_CLASS_COLORS")
    c = type(all) == "table" and plain(all[token]) or nil
  end
  if type(c) ~= "table" then return nil end
  local r, g, b = num(c.r), num(c.g), num(c.b)
  if r and g and b then return r, g, b end
  return nil
end

-- ---------- the GuildSync hub (window plan D2, D5, D18) ----------

-- GuildSync.RegisterModule(spec): the handle M, or nil when GuildSync is missing or refuses.
function Host.RegisterModule(spec)
  local gs = resolve("GuildSync")
  if type(gs) ~= "table" or type(gs.RegisterModule) ~= "function" then return nil end
  local M = gs.RegisterModule(spec)
  if type(M) == "table" then return M end
  return nil
end

-- The hub's /gsync handler with msg; false when there is none (not API: the director request asks for M.SetDemo).
function Host.HubSlash(msg)
  local fn = type(SlashCmdList) == "table" and SlashCmdList.GUILDSYNC or nil
  if type(fn) ~= "function" then return false end
  fn(msg)
  return true
end

-- The game tooltip on `owner`: title, then each of lines.
function Host.Tooltip(owner, title, lines)
  local tip = resolve("GameTooltip")
  if type(tip) ~= "table" or type(tip.SetOwner) ~= "function" then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(tostring(title or ""))
  for _, line in ipairs(type(lines) == "table" and lines or {}) do tip:AddLine(tostring(line), 1, 1, 1) end
  tip:Show()
end

function Host.TooltipHide()
  local tip = resolve("GameTooltip")
  if type(tip) == "table" and type(tip.Hide) == "function" then tip:Hide() end
end

local refreshFn = nil

-- fn() is what Host.Refresh runs (the module's page refresh).
function Host.SetRefresh(fn) refreshFn = fn end

-- Redraws the page; a no-op before SetRefresh.
function Host.Refresh()
  if type(refreshFn) == "function" then safe("refresh", refreshFn) end
end
