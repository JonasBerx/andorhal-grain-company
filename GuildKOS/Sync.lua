-- GuildKOS Sync: guild addon messages. Sightings out and in, offers, list pushes, the roster names.
-- Officers are GuildSync's (GuildSync.Comm.IsOfficer, read at call time, D240); a list waits for both rosters.
-- Thin on purpose: it registers events, reads the server time, starts timers, and takes every delay, window,
-- retry, hold and drop decision from ns.Rules and ns.Wire. It holds no timing number.
-- Sends go on "GUILD" only, never with combat data: a sighting is target, zone, subzone and the spotter's name.
local _, ns = ...
local Sync = {}
ns.Sync = Sync

local C, Rules, Wire, Codec, Core = ns.Compat, ns.Rules, ns.Wire, ns.Codec, ns.Core

local asm = Wire.NewAssembler()
local names = {}            -- SenderKey -> the roster's spelling of the name, for printed lines
local heard = { pair = {}, sender = {} } -- Rules.HeardAllowed state; bounded by roster x list (gated after Find)
local rosterReady = false   -- C_Club's guild roster is read
local lastReady = false     -- ready() at the last Sync.ReadyChanged
local offered = false       -- the login offer went out
local focusedClub
local lastBuild, buildPending
local held = {}             -- complete lists waiting for the roster (Rules.Hold)
local answers = {}          -- Rules.Throttle table for offers sent as answers or re-offers
local passed = {}           -- senderKey -> version whose chunks passed the gate
local offerFrom = {}        -- Rules.Throttle table: senderKey -> last push scheduled for that member's offer (D84)
local owed = {}             -- pushes owed to members refused by that throttle (Rules.Owe)
local lastPush
local pushState             -- nil | "scheduled" | "running" | "lockdown"
local pushGen = 0           -- bumped to cancel a scheduled or running push
local answerPending = false
local answerGen = 0

-- ---------- helpers ----------

local function after(delay, fn) C.call("C_Timer.After", delay, fn) end

local function mine()
  local list = Core.DB().list
  return list and list.version
end

local function realm()
  local ok, r = C.call("GetNormalizedRealmName")
  return (ok and C.str(r)) or nil
end

local function me()
  local ok, name = C.call("UnitName", "player")
  return (ok and C.str(name)) or nil
end

local function isTrue(name, ...)
  local ok, v = C.call(name, ...)
  return ok and C.plain(v) == true
end

local function lockedDown()
  local ok, v = C.call("C_ChatInfo.InChatMessagingLockdown")
  return not ok or C.plain(v) ~= false
end

-- outcome, result. outcome is Wire.SendOutcome's, or "lockdown"/"abort" when nothing was sent.
-- Demo mode sends nothing at all: the demo never reaches the guild (brief 8), and anything dropped is caught up by
-- the offer AfterDemo sends.
local function send(text, tries)
  if ns.Hub and ns.Hub.InDemo() then return "abort" end
  if lockedDown() then return "lockdown" end
  if not isTrue("IsInGuild") then return "abort" end
  local ok, result = C.call("C_ChatInfo.SendAddonMessage", Wire.PREFIX, text, "GUILD")
  if not ok then return "abort" end
  result = C.plain(result)
  return Wire.SendOutcome(result, tries), result
end

-- A throttle result is one that SendOutcome would retry on a first try.
local function throttled(result)
  return Wire.SendOutcome(result, 1) == "retry"
end

-- The hub's officer rule (GuildSync.Comm, API 4), read at call time. Without it nobody is an officer.
local function hasComm()
  return type(GuildSync) == "table" and type(GuildSync.Comm) == "table"
    and type(GuildSync.Comm.IsOfficer) == "function" and type(GuildSync.Comm.MyKey) == "function"
end

local function isOfficer(sender)
  return hasComm() and GuildSync.Comm.IsOfficer(sender) == true
end

local function iAmOfficer()
  if not hasComm() then return false end
  local k = GuildSync.Comm.MyKey()
  return k ~= nil and GuildSync.Comm.IsOfficer(k) == true
end

function Sync.IAmOfficer() return iAmOfficer() end

-- A list is judged only when C_Club's roster and the hub's (ns.Hub.Ready, Hub.lua) are both read; until then it waits.
local function ready()
  return rosterReady and (not ns.Hub or ns.Hub.Ready())
end

-- ---------- sightings ----------

function Sync.SendSighting(target, zone, subzone)
  local name = me()
  if not name then return end
  send(Wire.PackSighting(name, target, zone, subzone), 1) -- lockdown or failure: dropped, never queued
end

local function onSighting(msg, from, r)
  if Rules.SenderKey(msg.spotter, r) ~= from then return end
  local list = Core.DB().list
  local entry = list and Rules.Find(list.targets, msg.target)
  if not entry then return end
  if not Rules.HeardAllowed(heard, from, Rules.Key(entry.target), Core.Now()) then return end
  Core.Report(entry, msg.zone, msg.subzone, "heard", names[from] or msg.spotter, from)
end

-- ---------- pushing the list (officers) ----------

local runPush

local function schedule(delay)
  pushGen = pushGen + 1
  local gen = pushGen
  pushState = "scheduled"
  after(delay, function() if gen == pushGen then runPush() end end)
end

local function schedulePush()
  if pushState then return end -- a push already scheduled or under way covers this one
  local now = Core.Now()
  schedule(Rules.NextSlot(lastPush, now + Rules.PushDelay(math.random()), Rules.WINDOW) - now)
end

local function cancelPush()
  pushGen = pushGen + 1
  pushState = nil
end

runPush = function()
  pushGen = pushGen + 1
  local gen = pushGen
  pushState = "running"
  local list = Core.DB().list
  if not list or not iAmOfficer() then pushState = nil return end
  local chunks = Wire.SplitList(list.version, list.text)
  if not chunks then
    pushState = nil
    print("KOS: This list is too long to send to the guild, so it isn't spread. Members can still import it.")
    return
  end
  lastPush = Core.Now()
  local function step(i, tries)
    if gen ~= pushGen then return end
    if not chunks[i] then pushState = nil return end
    local outcome, result = send(chunks[i], tries)
    if outcome == "ok" then
      after(Wire.CHUNK_GAP, function() step(i + 1, 1) end)
    elseif outcome == "retry" then
      after(Wire.RETRY_GAP, function() step(i, tries + 1) end)
    elseif outcome == "lockdown" then
      pushState = "lockdown" -- the whole push starts again when the lockdown ends
    elseif throttled(result) then
      local now = Core.Now()
      schedule(Rules.NextSlot(lastPush, now, Rules.WINDOW) - now)
    else
      pushState = nil
    end
  end
  step(1, 1)
end

local function onRestrictionChanged()
  if pushState == "lockdown" and not lockedDown() then runPush() end
end

-- ---------- offers ----------

local function sendOfferWithinLimit()
  if Rules.Throttle(answers, "offer", Core.Now(), Rules.WINDOW) then send(Wire.PackOffer(mine()), 1) end
end

local function answerLater()
  if answerPending then return end
  answerPending = true
  answerGen = answerGen + 1
  local gen = answerGen
  after(Rules.AnswerDelay(math.random()), function()
    if gen ~= answerGen then return end
    answerPending = false
    sendOfferWithinLimit()
  end)
end

-- A member's offer makes a push once per PUSH_PER_SENDER per sender; a refused one is owed to the window end (D84).
local function onOffer(msg, sender, from)
  local now = Core.Now()
  local officer = isOfficer(sender)
  local what = Rules.OnOffer(mine(), msg.version, iAmOfficer(), officer, now)
  if what == "offer" then answerLater() return end
  if what ~= "push" then return end
  if officer then
    schedulePush()
  elseif pushState then
    return -- the push under way covers this member
  elseif Rules.Throttle(offerFrom, from, now, Rules.PUSH_PER_SENDER) then
    schedulePush()
  else
    Rules.Owe(owed, from, msg.version, offerFrom[from] + Rules.PUSH_PER_SENDER)
  end
end

-- ---------- receiving the list ----------

local function takeList(from, sender, list)
  local ok, why = Rules.AcceptList("GUILD", isOfficer(sender) and 0 or nil, 0, mine(), list.version, ready(), Core.Now())
  if ok then
    Core.Store(list, "guild")
    if not Core.DB().muted then print(Rules.ReceivedLine(names[from] or sender, #list.targets, Core.DateText(list.version))) end
  elseif why == "wait" then
    Rules.Hold(held, from, { from = from, sender = sender, list = list }, Core.Now())
  end
end

local function cancelAnswer()
  answerGen = answerGen + 1
  answerPending = false
end

-- Only an officer's chunk cancels a scheduled push: same or newer version, not future (f300, f320; f311, f328 so
-- officers holding the same list still coalesce). A pending answer is cancelled only by a chunk that passed the gate.
local function onChunk(msg, sender, from)
  local now = Core.Now()
  if pushState == "scheduled" and ready() and isOfficer(sender)
    and Rules.ImportVerdict(nil, msg.version, now) ~= "future" and Rules.CancelPush(mine(), msg.version) then
    cancelPush()
  end
  local ok, why = Rules.AcceptList("GUILD", isOfficer(sender) and 0 or nil, 0, mine(), msg.version, ready(), now)
  if ok and answerPending and Rules.CancelAnswer(mine(), msg) then cancelAnswer() end
  if not ok and why ~= "wait" then return end
  if ok then passed[from] = msg.version end
  local text = asm:Add(from, msg, now)
  if not text then return end
  local list = Codec.Decode(text)
  if not list or list.version ~= msg.version then return end
  takeList(from, sender, list)
end

local function sweep()
  local now = Core.Now()
  for _, expired in ipairs(asm:Expired(now)) do
    local gated = passed[expired.sender] == expired.version
    passed[expired.sender] = nil
    if Rules.ShouldReoffer(expired, mine(), gated) then sendOfferWithinLimit() end
  end
  for _, item in ipairs(Rules.TakeOwed(owed, now)) do
    if not pushState and Rules.OnOffer(mine(), item.version, iAmOfficer(), false, now) == "push"
      and Rules.Throttle(offerFrom, item.sender, now, Rules.PUSH_PER_SENDER) then
      schedulePush()
    end
  end
  after(Wire.SWEEP_EVERY, sweep)
end

local function onAddonMessage(prefix, text, channel, sender)
  prefix, text, channel, sender = C.plain(prefix), C.plain(text), C.plain(channel), C.plain(sender)
  if prefix ~= Wire.PREFIX or channel ~= "GUILD" then return end
  if type(text) ~= "string" or type(sender) ~= "string" then return end
  local r = realm()
  local from = Rules.SenderKey(sender, r)
  if not from or from == Rules.SenderKey(me(), r) then return end
  local msg = Wire.Unpack(text)
  if not msg then return end
  if msg.kind == "S" then
    onSighting(msg, from, r)
    return
  end
  if msg.kind == "O" then
    if answerPending and isOfficer(sender) and Rules.CancelAnswer(mine(), msg) then cancelAnswer() end
    onOffer(msg, sender, from)
  else
    onChunk(msg, sender, from)
  end
end

-- ---------- the roster names and readiness ----------

-- Called by buildMap (C_Club's side) and by Hub.lua's rosterRead listener (the hub's side). When the combined
-- readiness flips false -> true, the held lists are judged again.
function Sync.ReadyChanged()
  local isReady = ready()
  local was = lastReady
  lastReady = isReady
  if isReady and not was then
    for _, item in ipairs(Rules.TakeHeld(held, Core.Now())) do takeList(item.from, item.sender, item.list) end
  end
end

local function buildMap()
  buildPending = false
  lastBuild = Core.Now()
  local okId, id = C.call("C_Club.GetGuildClubId")
  local clubId = (okId and C.plain(id)) or nil
  if clubId == nil then return end
  if clubId ~= focusedClub then
    C.call("C_Club.FocusMembers", clubId)
    focusedClub = clubId
  end
  local ready = isTrue("C_Club.AreMembersReady", clubId)
  local r = realm()

  local okIds, ids = C.call("C_Club.GetClubMembers", clubId)
  ids = (okIds and C.plain(ids)) or nil
  if type(ids) == "table" then
    local spelled, count = {}, 0
    for _, memberId in ipairs(ids) do
      local okInfo, info = C.call("C_Club.GetMemberInfo", clubId, memberId)
      info = (okInfo and C.plain(info)) or nil
      if type(info) == "table" then
        local name = C.str(info.name)
        local key, order = Rules.SenderKey(name, r), C.num(info.guildRankOrder)
        if key and order and not spelled[key] then
          spelled[key] = name
          count = count + 1
        end
      end
    end
    if count > 0 then names = spelled end -- an empty or failed read keeps the last good names
  end

  rosterReady = ready
  if not ready then Sync.ReadyChanged() return end
  if not offered then offered = send(Wire.PackOffer(mine()), 1) == "ok" end
  Sync.ReadyChanged()
end

local function requestBuild()
  if buildPending then return end
  buildPending = true
  local now = Core.Now()
  after(Rules.NextSlot(lastBuild, now, Rules.REBUILD_EVERY) - now, buildMap)
end

-- ---------- after an import ----------

function Sync.AfterImport()
  send(Wire.PackOffer(mine()), 1)
  if iAmOfficer() then
    cancelPush()
    schedulePush()
  end
end

-- ---------- after the demo ----------

-- Offers our list again so peers and officers catch up on what was dropped while the demo ran.
function Sync.AfterDemo()
  sendOfferWithinLimit()
end

-- ---------- events ----------

C.call("C_ChatInfo.RegisterAddonMessagePrefix", Wire.PREFIX)

local frame = CreateFrame("Frame")
local handlers = {
  CHAT_MSG_ADDON = onAddonMessage,
  INITIAL_CLUBS_LOADED = requestBuild,
  CLUB_MEMBERS_UPDATED = requestBuild,
  GUILD_ROSTER_UPDATE = requestBuild,
  PLAYER_ENTERING_WORLD = function()
    C.call("C_GuildInfo.GuildRoster")
    requestBuild()
  end,
  ADDON_RESTRICTION_STATE_CHANGED = onRestrictionChanged,
}
for event in pairs(handlers) do pcall(frame.RegisterEvent, frame, event) end
frame:SetScript("OnEvent", function(_, event, ...)
  local fn = handlers[event]
  if fn then fn(...) end
end)

after(Wire.SWEEP_EVERY, sweep)

return Sync
