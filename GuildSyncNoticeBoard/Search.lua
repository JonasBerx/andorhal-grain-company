-- GuildSyncNoticeBoard: the search provider (API 8, addon/API.md "What API 8 adds"; run r-20261020-s6, d1151, d1152).
-- ns.SearchFind(text) answers the hub's search box from what the tabs list: Page.Events(), PageBoard.Notices() and
-- PageBoard.Polls(), each read once per call, removed records dropped. Read-only and cheap: no send, timer, saved
-- write, frame, window or C_Calendar call; the one client read is the realm calendar's now, once per call. One
-- "\n"-joined lower-cased haystack per record, so a query never matches across two fields (f6557). An event matches on
-- its title, type label, the card's when text, the full weekday and month of its day, and "today"/"tonight" or
-- "tomorrow" by whole calendar days against the realm calendar's today (o1287, d1154). Row texts are plain: the hub
-- escapes at draw, so an event row shows its raw title (f6572).
-- Order: events (soonest first), notices (pinned, then newest), polls (open, then newest); at most 25 rows.

local _, ns = ...
if not ns.M then return end

local M, Rules = ns.M, ns.Rules
local Plain = GuildSync.Compat.Plain
local MAX = 25 -- the hub reads rows 1..25
local DOT = " \194\183 " -- " · "

-- English, as the Board's own day texts (Rules.FromMinutes: weekday 1 = Sunday).
local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
  "November", "December" }

local function str(v) return type(v) == "string" and v or nil end
local function num(v) v = Plain(v) return type(v) == "number" and v or nil end

-- The realm calendar's today in whole days of Rules.Minutes, every field plained and checked as Calendar.lua's
-- calTime does; nil when unreadable (then no relative word is added).
local function calendarDay()
  local t = M.Compat.call("C_DateAndTime.GetCurrentCalendarTime")
  if type(t) ~= "table" then return nil end
  local ct = { year = num(t.year), month = num(t.month), monthDay = num(t.monthDay), hour = num(t.hour),
    minute = num(t.minute) }
  if not (ct.year and ct.month and ct.monthDay and ct.hour and ct.minute) then return nil end
  return math.floor(Rules.Minutes(ct) / 1440)
end

local function hit(parts, text) return string.find(string.lower(table.concat(parts, "\n")), text, 1, true) ~= nil end

-- "<label> · <author>", or the label alone when the record names no author.
local function byLine(label, rec)
  local who = str(rec.author) and ns.MemberName(rec.author)
  return type(who) == "string" and (label .. DOT .. who) or label
end

-- open(): the page first (the hub builds it with the window on first show), then the tab or the event (f6556);
-- a notice or poll lands on its tab only (d1152).
local function openTab(tab) return function() M.OpenPage() ns.Page.Show(tab) end end

function ns.SearchFind(text)
  local rows = {}
  if type(text) ~= "string" or text == "" then return rows end
  local function add(row)
    rows[#rows + 1] = row
    return #rows >= MAX
  end

  local today = calendarDay()
  for _, ev in ipairs(ns.Page.Events()) do
    local title = str(ev.rawTitle)
    if title and type(ev.minutes) == "number" and type(ev.time) == "table" then
      local label, when = Rules.TypeLabel(str(ev.kind)), ns.Page.When(ev)
      local day = Rules.FromMinutes(ev.minutes)
      local parts = { title, label, when, WEEKDAYS[day.weekday], MONTHS[day.month] }
      local ahead = today and (math.floor(ev.minutes / 1440) - today)
      if ahead == 0 then
        parts[#parts + 1] = "today"
        parts[#parts + 1] = "tonight"
      elseif ahead == 1 then
        parts[#parts + 1] = "tomorrow"
      end
      if hit(parts, text) then
        local detail = label .. DOT .. when
        if add({ text = title, detail = detail, open = function() M.OpenPage() ns.Page.OpenEvent(ev) end }) then
          return rows
        end
      end
    end
  end

  for _, rec in ipairs(ns.PageBoard.Notices()) do
    local title = str(rec.title)
    if not rec.removed and title and hit({ title, str(rec.body) or "" }, text) then
      -- f6590: the card's red "Officers only" pill (PageBoard fillNotice), so an officer never quotes one as public
      local label = (rec.pinned and "Pinned notice" or "Notice") .. (rec.officers and (DOT .. "Officers only") or "")
      local detail = byLine(label, rec)
      if add({ text = title, detail = detail, open = openTab("notices") }) then return rows end
    end
  end

  local t = math.floor(ns.Now() or 0)
  for _, rec in ipairs(ns.PageBoard.Polls()) do
    local question = str(rec.question)
    if not rec.removed and question then
      local parts = { question }
      if type(rec.options) == "table" then
        for _, o in ipairs(rec.options) do
          if str(o) then parts[#parts + 1] = o end
        end
      end
      if hit(parts, text) then
        local closes = ns.PageBoard.ClosesIn(rec, t)
        local detail = byLine("Poll" .. DOT .. (closes or "closed"), rec)
        if add({ text = question, detail = detail, open = openTab("polls") }) then return rows end
      end
    end
  end
  return rows
end
