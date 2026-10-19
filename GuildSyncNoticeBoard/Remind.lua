-- GuildSyncNoticeBoard: the reminders (brief AC28, AC29, AC33 as sliced by ui-slice.md). Local chat lines only,
-- nothing sent. The login line follows the first guild event list after the roster read (a list event, or the
-- LIST_WAIT read when it holds a row); the second line (notices
-- since my last login, open polls without my vote) comes SECOND_WAIT seconds after the roster read; the before-start
-- line comes `lead` minutes before each event I am signed up or tentative for, once per event per session, unless the
-- game's own CALENDAR_EVENT_ALARM named it. Titles are the rows' escaped titles (escaped once, in Calendar.lua).

local _, ns = ...
if not ns.M then return end

local M, C, Rules = ns.M, ns.C, ns.Rules
local Plain = GuildSync.Compat.Plain
local Remind = {}
ns.Remind = Remind

local rosterSeen, loginDone = false, false
local scheduled = {} -- eventID -> true once its before-start timer is set (or its line shown)
local alarmed = {}   -- eventID -> true when the game's alarm named it inside the lead window

local function say(text) GuildSync.Say(text) end

local MAX_LEAD = 1440 -- one day, in minutes

local function lead()
  local n = ns.DB().lead
  if type(n) ~= "number" then return C.LEAD end
  return n
end

-- Stores a lead of 0..1440 minutes (floored) and returns true; anything else (inf, NaN, out of range) is refused:
-- false, db.lead unchanged.
function Remind.SetLead(n)
  n = tonumber(n)
  if not n or n ~= n or n < 0 or n > MAX_LEAD then return false end
  ns.DB().lead = math.floor(n)
  return true
end

-- The calendar "now" in minutes, or nil.
local function nowMinutes()
  local t = Plain(M.Compat.call("C_DateAndTime.GetCurrentCalendarTime"))
  if type(t) ~= "table" then return nil end
  local ct = { year = Plain(t.year), month = Plain(t.month), monthDay = Plain(t.monthDay), hour = Plain(t.hour),
    minute = Plain(t.minute) }
  for _, k in ipairs({ "year", "month", "monthDay", "hour", "minute" }) do
    if type(ct[k]) ~= "number" then return nil end
  end
  return Rules.Minutes(ct)
end

-- My status for the row, read at use: the event module's answer when it is there, else the row's.
local function myStatus(row)
  local Ev = ns.Event
  return Ev and Ev.MyStatus and Ev.MyStatus(row.eventID) or row.status
end

local function isEvent(row) return row.readable and row.kind ~= "announcement" end

local function findRow(id)
  for _, row in ipairs((ns.Cal.RealRows())) do
    if row.eventID == id then return row end
  end
end

-- ---------- AC28: the login line ----------

local function loginLine(rows)
  local nowMin = nowMinutes()
  if not nowMin then return end
  local first, n = nil, 0
  for _, row in ipairs(rows) do
    if isEvent(row) and row.minutes >= nowMin and row.minutes <= nowMin + C.LOGIN_HOURS * 60 then
      n = n + 1
      if not first or row.minutes < first.minutes then first = row end
    end
  end
  if not first then return end
  local line = string.format("%d guild event%s in the next %d hours. First: %s at %02d:%02d", n,
    n == 1 and "" or "s", C.LOGIN_HOURS, first.title, first.time.hour, first.time.minute)
  local status = myStatus(first)
  if status ~= nil then line = line .. ", you: " .. select(2, Rules.Status(status)) end
  say(line .. ".")
end

-- ---------- AC29: the before-start line ----------

local function beforeStart(id)
  if lead() <= 0 or alarmed[id] then return end
  local row = findRow(id)
  local nowMin = nowMinutes()
  if not row or not isEvent(row) or not nowMin then return end
  local group = Rules.Status(myStatus(row))
  if group ~= "coming" and group ~= "tentative" then return end
  local left = row.minutes - nowMin
  if left < 0 then return end
  say(string.format("%s starts in %d minute%s.", row.title, left, left == 1 and "" or "s"))
end

local function schedule(rows)
  local n = lead()
  local nowMin = nowMinutes()
  if n <= 0 or not nowMin then return end
  for _, row in ipairs(rows) do
    local id = row.eventID
    if isEvent(row) and not scheduled[id] and row.minutes > nowMin then
      local group = Rules.Status(myStatus(row))
      if group == "coming" or group == "tentative" then
        scheduled[id] = true
        M.After(math.max(0, (row.minutes - n - nowMin) * 60), function() beforeStart(id) end)
      end
    end
  end
end

ns.Listen("CALENDAR_EVENT_ALARM", function(title)
  title = Plain(title)
  if type(title) ~= "string" then return end
  local nowMin = nowMinutes()
  if not nowMin then return end
  for _, row in ipairs((ns.Cal.RealRows())) do
    if row.rawTitle == title and row.minutes and row.minutes >= nowMin and row.minutes - nowMin <= lead() then
      alarmed[row.eventID] = true
    end
  end
end)

-- The first list is a list event's, or the LIST_WAIT read when it holds a row (Forever may send no list event, f6);
-- an empty wait read leaves the line to the retry's list.
ns.Cal.OnList(function(rows, source)
  local first = source == "event" or (source == "wait" and #rows > 0)
  if rosterSeen and not loginDone and first then
    loginDone = true
    loginLine(rows)
  end
  schedule(rows)
end)

-- ---------- AC28: the second line ----------

M.On("rosterRead", function()
  if rosterSeen then return end
  rosterSeen = true
  -- AC28: Calendar.lua retries at LIST_WAIT; when no list has come by another LIST_WAIT, the event line is skipped
  -- this session (a list event much later, say the page opened an hour on, prints no late login line).
  M.After(2 * C.LIST_WAIT, function() loginDone = true end)
  M.After(C.SECOND_WAIT, function()
    -- f3: demo's counts are made up; skip the line, in step with MarkSeen (which skips in demo too).
    if ns.InDemo() then return end
    local notices, polls = ns.Store.SinceLastLogin(), ns.Store.OpenUnvoted()
    local parts = {}
    if notices > 0 then
      parts[#parts + 1] = string.format("%d new notice%s since your last login", notices, notices == 1 and "" or "s")
    end
    if polls > 0 then
      parts[#parts + 1] = string.format("%d open poll%s without your vote", polls, polls == 1 and "" or "s")
    end
    if #parts > 0 then say("You have " .. table.concat(parts, " and ") .. ".") end
    ns.Store.MarkSeen() -- the line has told me: later counts start from now
  end)
end)
