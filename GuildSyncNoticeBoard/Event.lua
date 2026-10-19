-- GuildSyncNoticeBoard: one event's detail, who is coming, and the respond buttons (brief AC21-AC24, AC43). The open
-- event is one slot shared with the game's calendar: Select opens it, CALENDAR_OPEN_EVENT checks it is ours, and every
-- respond click re-checks it in the same call. Respond calls run only from a button's OnClick, never in demo. Every
-- client call goes through M.Compat and every field of a returned table through GuildSync.Compat.Plain (AC4).
-- Banners (banners.md B2, B3): the open event's description carries the tag; the id is remembered in SavedVariables
-- as GuildSyncNoticeBoardDB.banners[guild] = { n = <counter>, map = { [rawTitle .. "\n" .. Minutes(time)] =
-- { id, at = <event minutes>, n } } }, guild = ns.DB().guild (nothing read, written or deleted while nil). At most
-- BANNER_CAP entries (the smallest n goes); a list read drops entries older than now - C.EVENT_AFTER_MIN. An entry is
-- stored only for a known tag this client wrote (Create) or read (an open description), never for an untagged
-- description's default. A readable open description with no known tag deletes the entry; an unreadable one (not a
-- string) leaves it. detail.description is the shown description, escaped. Never OpenEvent for it.

local _, ns = ...
if not ns.M then return end

local M, C, Rules, Banners = ns.M, ns.C, ns.Rules, ns.Banners
local Plain = GuildSync.Compat.Plain
local Event = {}
ns.Event = Event

local COULD_NOT = "Could not open this event"
local LOADING = "Loading names"
local LOCKED = "Who is coming is not readable now"
local WAITING = "Waiting for the game's calendar."
local CLICK_AGAIN = "Click again"
local GROUPS = { "coming", "standby", "tentative", "notcoming", "unanswered", "other" }
local BANNER_CAP = 200

local detail = nil          -- the selected event's detail (Seams), nil before any Select
local expect = nil          -- { monthDay, eventIndex } passed to OpenEvent for the detail's row
local indexField = nil      -- "offsetMonths" | "offsetMonth": which field the last selection read used
local counts = {}           -- eventID -> { coming, tentative, at }
local statuses = {}         -- eventID -> my status, latest of the list and the open event
local readInvites           -- who is coming, defined below; CALENDAR_OPEN_EVENT reads it too (f2)

local function call(dotted, ...) return M.Compat.call(dotted, ...) end
local function num(v) v = Plain(v) return type(v) == "number" and v or nil end
local function str(v) v = Plain(v) return type(v) == "string" and v or nil end

local function calTime(t)
  t = Plain(t)
  if type(t) ~= "table" then return nil end
  local ct = { year = num(t.year), month = num(t.month), monthDay = num(t.monthDay), hour = num(t.hour),
    minute = num(t.minute) }
  if not (ct.year and ct.month and ct.monthDay and ct.hour and ct.minute) then return nil end
  return ct
end

local function sameTime(a, b)
  return a and b and a.year == b.year and a.month == b.month and a.monthDay == b.monthDay and a.hour == b.hour
    and a.minute == b.minute
end

local function emptyGroups()
  local g = {}
  for _, k in ipairs(GROUPS) do g[k] = {} end
  return g
end

-- ---------- banner cache (B3) ----------

local function bannerKey(rawTitle, time)
  if type(rawTitle) ~= "string" or type(time) ~= "table" then return nil end
  local m = Rules.Minutes(time)
  return rawTitle .. "\n" .. m, m
end

-- This guild's cache, made when make is set; nil while the guild is unknown.
local function bannerCache(make)
  local db = ns.DB()
  local guild = db and db.guild
  if guild == nil then return nil end
  if type(db.banners) ~= "table" then
    if not make then return nil end
    db.banners = {}
  end
  local b = db.banners[guild]
  if type(b) ~= "table" or type(b.map) ~= "table" then
    if not make then return nil end
    b = { n = 0, map = {} }
    db.banners[guild] = b
  end
  return b
end

function Event.RememberBanner(rawTitle, time, id)
  local key, at = bannerKey(rawTitle, time)
  if not key or not Banners.Known(id) then return end
  local b = bannerCache(true)
  if not b then return end
  b.n = (tonumber(b.n) or 0) + 1
  b.map[key] = { id = id, at = at, n = b.n }
  local count, oldKey, oldN = 0, nil, nil
  for k, e in pairs(b.map) do
    count = count + 1
    local en = type(e) == "table" and tonumber(e.n) or 0
    if oldN == nil or en < oldN then oldKey, oldN = k, en end
  end
  if count > BANNER_CAP then b.map[oldKey] = nil end
end

local function forgetBanner(rawTitle, time)
  local key = bannerKey(rawTitle, time)
  local b = key and bannerCache(false)
  if b then b.map[key] = nil end
end

function Event.Banner(row)
  if type(row) ~= "table" then return Banners.Default(nil) end
  if Banners.Known(row.banner) then return row.banner end
  local key = bannerKey(row.rawTitle, row.time)
  local b = key and bannerCache(false)
  local e = b and b.map[key]
  if type(e) == "table" and Banners.Known(e.id) then return e.id end
  return Banners.Default(row.kind)
end

-- ---------- open (AC22, AC23) ----------

local function fail(line)
  detail.state, detail.line, detail.canRespond = "failed", line, false
  expect = nil
end

-- SetAbsMonth from calendar time, then the selection info, then OpenEvent; the detail is "loading" until
-- CALENDAR_OPEN_EVENT, or "failed".
local function openRow(row)
  detail = { row = row, state = "loading", groups = emptyGroups(), status = statuses[row.eventID],
    canRespond = false, pending = detail and detail.pending or false, banner = Event.Banner(row) }
  expect = nil
  local closed, closedLine = ns.Cal.Closed()
  if closed then return fail(closedLine) end
  local free, slotLine = ns.Cal.SlotFree()
  if not free then
    detail.state, detail.line = "slot", slotLine
    return
  end
  local now = calTime(call("C_DateAndTime.GetCurrentCalendarTime"))
  if not now then return fail(COULD_NOT) end
  call("C_Calendar.SetAbsMonth", now.month, now.year)
  local sel = call("C_Calendar.GetGuildEventSelectionInfo", row.index)
  if type(sel) ~= "table" then return fail(COULD_NOT) end
  local offset
  if Plain(sel.offsetMonths) ~= nil then
    indexField, offset = "offsetMonths", num(sel.offsetMonths)
  else
    indexField, offset = "offsetMonth", num(sel.offsetMonth)
  end
  local monthDay, eventIndex = num(sel.monthDay), num(sel.eventIndex)
  if not (offset and monthDay and eventIndex) then return fail(COULD_NOT) end
  if call("C_Calendar.OpenEvent", offset, monthDay, eventIndex) ~= true then return fail(COULD_NOT) end
  expect = { monthDay = monthDay, eventIndex = eventIndex }
end

-- The open event's info when the slot still holds the selected row (index, title and time); else nil.
local function ours()
  if not (detail and expect) then return nil end
  local idx = call("C_Calendar.GetEventIndex")
  local info = call("C_Calendar.GetEventInfo")
  if type(idx) ~= "table" or type(info) ~= "table" then return nil end
  if num(idx.monthDay) ~= expect.monthDay or num(idx.eventIndex) ~= expect.eventIndex then return nil end
  local row = detail.row
  if row.rawTitle == nil or str(info.title) ~= row.rawTitle then return nil end
  if not sameTime(calTime(info.time), row.time) then return nil end
  return info
end

-- Buttons only for a future guild sign-up event while my status is one I may answer from (AC24).
local function readInfo(info)
  local row = detail.row
  local status = num(info.inviteStatus)
  local now = calTime(call("C_DateAndTime.GetCurrentCalendarTime"))
  local time = calTime(info.time)
  detail.status = status
  detail.inviteType = num(info.inviteType)
  detail.canRespond = row.calendarType == "GUILD_EVENT" and str(info.calendarType) == "GUILD_EVENT"
    and detail.inviteType == 1 and status ~= nil and Rules.CanRespond(status) and now ~= nil and time ~= nil
    and Rules.Minutes(time) > Rules.Minutes(now)
  if status ~= nil then statuses[row.eventID] = status end
  -- the organiser only when readable (a secret reads nil): the titles' fit (control characters as spaces, capped,
  -- escaped, shrunk until the escaped text is at most C.TITLE_STORE bytes)
  local creator = str(info.creator)
  detail.organiser = creator and creator ~= "" and ns.Cal.StoreTitle(creator) or nil
  local raw = str(info.description)
  if raw == nil then
    -- unreadable or filtered: says nothing about the tag, so the stored entry stays
    detail.banner, detail.description = Event.Banner(row), nil
    return
  end
  local id, shown, tagged = Banners.Read(raw, row.kind)
  -- LF kept (the description's own lines); CR, TAB and the other control bytes become spaces before the escape
  detail.banner, detail.description = id, GuildSync.Escape((shown:gsub("[%z\1-\9\11-\31\127]", " ")))
  if tagged then Event.RememberBanner(row.rawTitle, row.time, id) else forgetBanner(row.rawTitle, row.time) end
end

function Event.Select(row)
  if type(row) ~= "table" then return end
  if ns.InDemo() then
    -- AC43: the demo row shows; nothing is asked of the client
    detail = { row = row, state = "open", groups = emptyGroups(), status = row.status, pending = false,
      banner = Event.Banner(row),
      canRespond = row.calendarType == "GUILD_EVENT" and row.status ~= nil and Rules.CanRespond(row.status) }
    expect = nil
    M.RefreshPage()
    return
  end
  openRow(row)
  M.RefreshPage()
end

function Event.Detail()
  if detail and expect and not ns.InDemo() then detail.pending = call("C_Calendar.IsActionPending") ~= false end
  return detail
end

function Event.Close()
  if not detail then return end
  local demo = ns.InDemo()
  detail, expect = nil, nil
  -- the shared slot (AC23): while the game's calendar is shown the open event may be its own; drop only ours
  if not demo and ns.Cal.SlotFree() then call("C_Calendar.CloseEvent") end
  M.RefreshPage()
end

function Event.IndexField() return indexField end

-- AC43: demo on or off drops the selected event (a demo row's index is not a real list index). No CloseEvent here:
-- in demo the client is not asked, and out of it the slot may hold the game's own event.
M.On("demo", function()
  detail, expect = nil, nil
  M.RefreshPage()
end)

ns.Listen("CALENDAR_OPEN_EVENT", function()
  if not (detail and expect) or ns.InDemo() then return end
  local info = ours()
  if not info then
    fail(COULD_NOT)
  else
    detail.state, detail.line = "open", nil
    readInfo(info)
    readInvites()
  end
  M.RefreshPage()
end)

ns.Listen("CALENDAR_CLOSE_EVENT", function()
  if not detail or ns.InDemo() then return end
  detail.state, detail.canRespond = "closed", false
  expect = nil
  M.RefreshPage()
end)

-- ---------- who is coming (AC21, AC22) ----------

function readInvites()
  if call("C_Calendar.AreNamesReady") ~= true then
    detail.line = LOADING
    return
  end
  local groups = emptyGroups()
  local n = num(call("C_Calendar.GetNumInvites")) or 0
  for i = 1, n do
    -- EventGetInvite is secret in chat lockdown; nil (a secret) counts as locked
    if call("C_ChatInfo.InChatMessagingLockdown") ~= false then
      detail.line = LOCKED
      return
    end
    local inv = call("C_Calendar.EventGetInvite", i)
    local name = type(inv) == "table" and str(inv.name) or nil
    if name then
      local group = Rules.Status(num(inv.inviteStatus))
      local member = GuildSync.Comm.Member(name)
      local list = groups[group] or groups.other
      list[#list + 1] = { name = GuildSync.Escape(Rules.Cap((name:gsub("%c", " ")), C.TITLE_STORE)),
        online = type(member) == "table" and member.online == true or false }
    end
  end
  detail.groups, detail.line = groups, nil
  counts[detail.row.eventID] = { coming = #groups.coming, tentative = #groups.tentative, at = ns.Now() }
end

ns.Listen("CALENDAR_UPDATE_INVITE_LIST", function()
  if not (detail and expect and detail.state == "open") or ns.InDemo() then return end
  readInvites()
  M.RefreshPage()
end)

function Event.Counts(eventID) return counts[eventID] end

-- ---------- my status (AC24) ----------

function Event.MyStatus(eventID)
  if ns.InDemo() then return nil end
  return statuses[eventID]
end

ns.Cal.OnList(function(rows)
  for _, row in ipairs(rows) do
    if row.status ~= nil then statuses[row.eventID] = row.status end
  end
  -- B3: past entries go; nothing pruned while the clock or the guild is unreadable
  local now = calTime(call("C_DateAndTime.GetCurrentCalendarTime"))
  local b = now and bannerCache(false)
  if not b then return end
  local oldest = Rules.Minutes(now) - C.EVENT_AFTER_MIN
  for k, e in pairs(b.map) do
    if type(e) ~= "table" or type(e.at) ~= "number" or e.at < oldest then b.map[k] = nil end
  end
end)

ns.Listen("CALENDAR_UPDATE_EVENT", function()
  if not (detail and expect and detail.state == "open") or ns.InDemo() then return end
  local info = ours()
  if info then readInfo(info) end
  M.RefreshPage()
end)

ns.Listen("CALENDAR_ACTION_PENDING", function()
  if not detail or ns.InDemo() then return end
  detail.pending = call("C_Calendar.IsActionPending") ~= false
  if not detail.pending and detail.line == WAITING then detail.line = nil end
  M.RefreshPage()
end)

-- ---------- respond (AC24, AC43) ----------

-- "signup" | "tentative" | "decline"; only from a button's OnClick. Every check runs in this one call.
function Event.Respond(which)
  ns.Cal.ClearError()
  if ns.InDemo() then ns.Inert() return end
  if not detail then return end
  if call("C_Calendar.IsActionPending") ~= false then
    detail.pending, detail.line = true, WAITING
    M.RefreshPage()
    return
  end
  detail.pending = false
  local free, slotLine = ns.Cal.SlotFree()
  if not free then
    detail.line = slotLine
    M.RefreshPage()
    return
  end
  local info = call("C_Calendar.IsEventOpen") == true and ours() or nil
  if not info then
    -- the slot closed or holds another event: open ours again, the next click answers
    openRow(detail.row)
    if detail.state == "loading" then detail.line = CLICK_AGAIN end
    M.RefreshPage()
    return
  end
  -- AC24 again at the click: the status or the clock may have moved since the buttons were drawn
  readInfo(info)
  if not detail.canRespond then
    M.RefreshPage()
    return
  end
  -- canRespond holds only for a guild sign-up event (inviteType 1); a Normal invite gets no buttons (AC24)
  local fn
  if which == "signup" then
    fn = "C_Calendar.EventSignUp"
  elseif which == "tentative" then
    fn = "C_Calendar.EventTentative"
  elseif which == "decline" then
    fn = "C_Calendar.EventDecline"
  end
  if not fn then return end
  ns.Cal.Open("write")
  call(fn)
end
