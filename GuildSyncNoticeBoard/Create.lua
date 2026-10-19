-- GuildSyncNoticeBoard: create a guild sign-up event in one click (brief AC19, AC20, AC23, AC25, AC43). Submit is called
-- only from a button's OnClick and runs the whole create sequence in that call; nothing here runs on a timer or an
-- event. Every client call goes through M.Compat and every value read from the client through GuildSync.Compat.Plain.
-- The banner (spec banners.md B5, B3): the tag of f.banner (else the type's default) is appended to the description
-- before Rules.CheckEvent, so the check counts it; after AddEvent the choice is remembered in the local banner cache.

local _, ns = ...
if not ns.M then return end

local M, C, Rules, Banners = ns.M, ns.C, ns.Rules, ns.Banners
local Plain = GuildSync.Compat.Plain
local Create = {}
ns.Create = Create

local NO_DATE_LINE = "The calendar has no date yet. Try again in a moment."
-- CanAddEvent returns only a boolean, so this line cannot name a field; Rules.CheckEvent has already named any
-- failing field before the first client write.
local REFUSED_LINE = "The game's calendar refused the event; the form's own checks passed."
local WAITING_LINE = "Waiting for the game's calendar."

local function call(dotted, ...) return M.Compat.call(dotted, ...) end
local function num(v) v = Plain(v) return type(v) == "number" and v or nil end
local function str(v) v = Plain(v) return type(v) == "string" and v or nil end

-- A calendar date from a client table, every field plained; nil when a part is missing.
local function calDate(t)
  t = Plain(t)
  if type(t) ~= "table" then return nil end
  local ct = { year = num(t.year), month = num(t.month), monthDay = num(t.monthDay), hour = num(t.hour) or 0,
    minute = num(t.minute) or 0 }
  if not (ct.year and ct.month and ct.monthDay) then return nil end
  return ct
end

-- today from calendar time; maxDate from GetMaxCreateDate, else today + C.CREATE_DAYS.
function Create.Range()
  local today = calDate(call("C_DateAndTime.GetCurrentCalendarTime"))
  if not today then return nil, nil end
  local maxDate = calDate(call("C_Calendar.GetMaxCreateDate"))
    or Rules.FromMinutes(Rules.Minutes(today) + C.CREATE_DAYS * 24 * 60)
  return today, maxDate
end

-- The board types whose game type the client lists now (AC20); never raid.
function Create.Types()
  local present = {}
  local list = Plain(call("C_Calendar.EventGetTypesDisplayOrdered"))
  if type(list) == "table" then
    for _, e in ipairs(list) do
      e = Plain(e)
      local t = type(e) == "table" and num(e.eventType) or nil
      if t then present[t] = true end
    end
  end
  local out = {}
  for _, boardType in ipairs(Rules.BOARD_TYPES) do
    if present[Rules.TypeToGame(boardType)] then out[#out + 1] = boardType end
  end
  return out
end

-- f4: capped at C.TITLE_STORE bytes after escaping, as Calendar.lua's storeTitle (cap, then escape; a cut never
-- splits a doubled pipe).
local function capTitle(raw)
  local n = C.TITLE_STORE
  local t = GuildSync.Escape(Rules.Cap(raw, n))
  while #t > C.TITLE_STORE and n > 0 do
    n = n - 1
    t = GuildSync.Escape(Rules.Cap(raw, n))
  end
  return t
end

-- The Dungeon textures as { index, title, icon }, title capped and escaped; nil (picker hidden) when the list is empty or
-- unreadable. index is the 1-based position EventSetTextureID takes.
function Create.Textures()
  local list = Plain(call("C_Calendar.EventGetTextures", 1))
  if type(list) ~= "table" or #list == 0 then return nil end
  local out = {}
  for i, e in ipairs(list) do
    e = Plain(e)
    if type(e) == "table" then
      local title = str(e.title)
      out[#out + 1] = { index = i, title = title and capTitle(title) or nil, icon = num(e.iconTexture) }
    end
  end
  return out
end

-- Security f2: true while the game's calendar has an action pending (anything but a plain false counts as pending).
-- False in demo, where Submit refuses before any client read.
function Create.Pending()
  if ns.InDemo() then return false end
  return Plain(call("C_Calendar.IsActionPending")) ~= false
end

-- f = { title, type, date = { year, month, monthDay }, hour, minute, description, texture, banner }; only from an
-- OnClick. f itself is not changed.
function Create.Submit(f)
  -- AC43: in demo, refuse before any client read (the date range, slot and closed checks all ask the client)
  if ns.InDemo() then
    ns.Inert()
    return false, "Demo: nothing is done to made-up members."
  end
  -- f2: a click while the last create is still pending (a double click on a slow client) makes no second event
  if Create.Pending() then return false, WAITING_LINE end
  local g = {}
  for k, v in pairs(f) do g[k] = v end
  g.description = Banners.WithTag(f.description or "", f.banner or Banners.Default(f.type))
  f = g
  ns.Cal.ClearError()
  local today, maxDate = Create.Range()
  if not today then return false, NO_DATE_LINE end
  local ok, why = Rules.CheckEvent(f, today, maxDate)
  if not ok then return false, why end
  local free, slotLine = ns.Cal.SlotFree()
  if not free then return false, slotLine end
  local closed, closedLine = ns.Cal.Closed()
  if closed then return false, closedLine end
  local gameType, prefix = Rules.TypeToGame(f.type)
  ns.Cal.Open("write")
  call("C_Calendar.CreateGuildSignUpEvent")
  call("C_Calendar.EventSetTitle", prefix .. f.title)
  call("C_Calendar.EventSetDescription", f.description)
  call("C_Calendar.EventSetType", gameType)
  if f.type == "dungeon" and type(f.texture) == "number" then call("C_Calendar.EventSetTextureID", f.texture) end
  call("C_Calendar.EventSetDate", f.date.month, f.date.monthDay, f.date.year)
  call("C_Calendar.EventSetTime", f.hour, f.minute)
  if Plain(call("C_Calendar.CanAddEvent")) ~= true then
    call("C_Calendar.CloseEvent")
    return false, REFUSED_LINE
  end
  call("C_Calendar.AddEvent")
  ns.Event.RememberBanner(prefix .. f.title, { year = f.date.year, month = f.date.month, monthDay = f.date.monthDay,
    hour = f.hour, minute = f.minute }, f.banner or Banners.Default(f.type))
  return true
end
