-- GuildSyncNoticeBoard: the guild event list from the game's calendar (brief AC18, AC19, AC23, AC26, AC27). Reads only:
-- availability, the list, the shared-slot check and the error line. The first OpenCalendar runs on the first roster
-- read; list events rebuild the list and never call OpenCalendar. Every client call goes through M.Compat and every
-- field read from a returned table goes through GuildSync.Compat.Plain (AC4).

local _, ns = ...
if not ns.M then return end

local M, C, Rules = ns.M, ns.C, ns.Rules
local Plain = GuildSync.Compat.Plain
local Cal = {}
ns.Cal = Cal

local CLOSED_LINE = "The game's calendar is closed here."
local SLOT_LINE = "Close the game's calendar to use the board."
local KEPT = { GUILD_EVENT = true, GUILD_ANNOUNCEMENT = true }

local rows, readAt = {}, nil
local good = {}             -- eventID -> the last readable row (a later unreadable read never replaces it)
local subscribers = {}
local closed, enabled = false, nil
local started, listCame = false, false
local errorLine = nil

local function call(dotted, ...) return M.Compat.call(dotted, ...) end

-- ---------- availability (AC18) ----------

local function readAvailability()
  enabled = call("C_GuildInfo.AreGuildEventsEnabled") -- recorded only: false on Forever while sign-ups work (d352)
  local rule = Enum and Enum.GameRule and Enum.GameRule.IngameCalendarDisabled
  if rule ~= nil and call("C_GameRules.IsGameRuleActive", rule) == true then closed = true end
end

function Cal.Closed()
  if closed then return true, CLOSED_LINE end
  return false
end

function Cal.GuildEventsEnabled() return enabled end

function Cal.Open(why)
  if closed then return end
  call("C_Calendar.OpenCalendar")
end

-- ---------- the list (AC19) ----------

local function num(v) v = Plain(v) return type(v) == "number" and v or nil end
local function str(v) v = Plain(v) return type(v) == "string" and v or nil end

-- Calendar time from a table, every field plained; nil when any part is missing.
local function calTime(t)
  if type(t) ~= "table" then return nil end
  local ct = { year = num(t.year), month = num(t.month), monthDay = num(t.monthDay), hour = num(t.hour),
    minute = num(t.minute) }
  if not (ct.year and ct.month and ct.monthDay and ct.hour and ct.minute) then return nil end
  ct.weekday = num(t.weekday) or Rules.FromMinutes(Rules.Minutes(ct)).weekday
  return ct
end

-- Control characters (a newline would fake a second chat line) become spaces, before the cap and the escape.
local function noControl(s) return (s:gsub("%c", " ")) end

-- The escaped title, at most TITLE_STORE bytes, never cut inside a doubled pipe; control characters made spaces.
local function storeTitle(raw)
  raw = noControl(raw)
  local n = C.TITLE_STORE
  local t = GuildSync.Escape(Rules.Cap(raw, n))
  while #t > C.TITLE_STORE and n > 0 do
    n = n - 1
    t = GuildSync.Escape(Rules.Cap(raw, n))
  end
  return t
end
Cal.StoreTitle = storeTitle -- the same fit for other short game texts (the organiser, Event.lua)

-- A row from one event table (guild info or club day event, time already read); nil to leave it off.
local function makeRow(index, e, time)
  local id = num(e.eventID)
  if id == nil then return nil end
  local calendarType = str(e.calendarType)
  local eventType = num(e.eventType)
  if (calendarType == nil or eventType == nil) and good[id] then -- f6: an unreadable type never drops a good row
    local cached = good[id]
    cached.index = index
    return cached
  end
  if not KEPT[calendarType] or eventType == 0 then return nil end
  local raw = str(e.title)
  local row = { index = index, eventID = id, calendarType = calendarType, status = num(e.inviteStatus),
    rawTitle = raw, time = time, minutes = time and Rules.Minutes(time) or nil }
  row.readable = raw ~= nil and time ~= nil
  row.title = raw and storeTitle(raw) or nil
  if calendarType == "GUILD_ANNOUNCEMENT" then row.kind = "announcement"
  else row.kind = Rules.TypeFromGame(eventType, raw) end
  if not row.readable and good[id] then
    local cached = good[id]
    cached.index = index
    return cached
  end
  if row.readable then good[id] = row end
  return row
end

-- From now - EVENT_AFTER_MIN to now + EVENT_DAYS, in calendar minutes; a row without a time is kept (not readable).
local function inWindow(row, nowMin)
  if not row.minutes or not nowMin then return true end
  return row.minutes >= nowMin - C.EVENT_AFTER_MIN and row.minutes <= nowMin + C.EVENT_DAYS * 1440
end

-- The readers return true when the read could be made; false (nil count, no club id, chat locked, no table) leaves
-- the previous rows and readAt in place (AC19: an unreadable read never replaces a good cached read). The second
-- result is the number of event tables the read saw (rebuild keeps good rows when none of them gave a readable row).
local function readGuild(out)
  local n = num(call("C_Calendar.GetNumGuildEvents"))
  if n == nil then return false end
  local tables = 0
  for i = 1, n do
    local e = call("C_Calendar.GetGuildEventInfo", i)
    if type(e) == "table" then
      tables = tables + 1
      local row = makeRow(i, e, calTime(e))
      if row then out[#out + 1] = row end
    end
  end
  return true, tables
end

-- The alternative reader (AC19): only when ns.C.READER is "club"; nothing while the club id is nil or chat is locked.
local function readClub(out, now)
  local clubId = call("C_Club.GetGuildClubId")
  if clubId == nil or not now then return false end
  if call("C_ChatInfo.InChatMessagingLockdown") ~= false then return false end
  local last = Rules.FromMinutes(Rules.Minutes(now) + C.EVENT_DAYS * 1440)
  local list = call("C_Calendar.GetClubCalendarEvents", clubId, now, last)
  if type(list) ~= "table" then return false end
  local tables = 0
  for i, e in ipairs(list) do
    e = Plain(e)
    if type(e) == "table" then
      tables = tables + 1
      local row = makeRow(i, e, calTime(Plain(e.startTime)))
      if row then out[#out + 1] = row end
    end
  end
  return true, tables
end

local function anyReadable(list)
  for _, row in ipairs(list) do if row.readable then return true end end
  return false
end

local function readList(source)
  if closed then return end
  local now = calTime(call("C_DateAndTime.GetCurrentCalendarTime"))
  local nowMin = now and Rules.Minutes(now) or nil
  local out = {}
  local readable, tables
  if C.READER == "club" then readable, tables = readClub(out, now) else readable, tables = readGuild(out) end
  if not readable then return end
  -- events were there but none gave a readable row (f6, a chat lockdown): the previous good rows stay
  if tables > 0 and not anyReadable(out) and anyReadable(rows) then return end
  rows = {}
  for _, row in ipairs(out) do
    if inWindow(row, nowMin) then rows[#rows + 1] = row end
  end
  readAt = ns.Now()
  if source == "event" then errorLine = nil end -- a list the game sent after an error: the error is old news
  for _, fn in ipairs(subscribers) do M.Safe(fn, rows, source) end
  M.RefreshPage()
end

-- A list event during a read was fired by the game from inside a call that read made (its own, a subscriber's or the
-- page's): followed into, the read re-entered itself until the C stack ran out (beta 2026-10-16). It is not followed:
-- the read runs once more after it, and list events during that second read are dropped. A throw still clears the flag.
local reading, again = false, nil
local function rebuild(source)
  if reading then
    again = source
    return
  end
  reading = true
  local ok, err = pcall(readList, source)
  if ok and again then ok, err = pcall(readList, again) end
  reading, again = false, nil
  if not ok then error(err, 0) end
end

function Cal.Rows()
  if ns.InDemo() then
    local state = ns.DemoState()
    return state and state.events or {}, ns.Now()
  end
  return rows, readAt
end

-- The game's rows whatever demo says: the reminders' timers and the alarm match real events (f5).
function Cal.RealRows() return rows, readAt end

function Cal.OnList(fn) subscribers[#subscribers + 1] = fn end

local function onList()
  listCame = true
  rebuild("event")
end
ns.Listen("CALENDAR_UPDATE_GUILD_EVENTS", onList)
ns.Listen("CALENDAR_UPDATE_EVENT_LIST", onList)

-- The first roster read: availability, then OpenCalendar once; LIST_WAIT later with no list event, read the list
-- once (the event may never come) and call OpenCalendar once more.
M.On("rosterRead", function()
  if started then return end
  started = true
  readAvailability()
  if closed then return end
  Cal.Open("roster")
  M.After(C.LIST_WAIT, function()
    if listCame or closed then return end
    rebuild("wait")
    Cal.Open("retry")
  end)
end)

-- ---------- shared slot (AC23) ----------

function Cal.SlotFree()
  local f = CalendarFrame
  if type(f) == "table" and type(f.IsShown) == "function" then
    local ok, shown = pcall(f.IsShown, f)
    if ok and shown then return false, SLOT_LINE end
  end
  return true
end

-- ---------- errors (AC26) ----------

-- The global string the reason names, formatted under pcall with arg when given; else the reason name. Escaped.
local function setError(reason, formatted, arg)
  reason = str(reason)
  if not reason then return end
  local text = reason
  local global = _G[reason]
  if type(global) == "string" then
    text = global
    if formatted then
      local ok, result = pcall(string.format, global, arg)
      text = ok and result or reason
    end
  end
  errorLine = GuildSync.Escape(text)
  M.RefreshPage()
end

function Cal.ErrorLine() return errorLine end

-- A new write (Create.Submit, Event.Respond) starts with no error line.
function Cal.ClearError()
  if errorLine == nil then return end
  errorLine = nil
  M.RefreshPage()
end

ns.Listen("CALENDAR_UPDATE_ERROR", function(reason) setError(reason) end)
ns.Listen("CALENDAR_UPDATE_ERROR_WITH_COUNT", function(reason, count) setError(reason, true, num(count)) end)
ns.Listen("CALENDAR_UPDATE_ERROR_WITH_PLAYER_NAME", function(reason, name)
  local who = str(name)
  setError(reason, true, who and GuildSync.Escape(noControl(who)) or "")
end)
