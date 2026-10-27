-- Notice Board: a GuildSync module addon (brief noticeboard/brief.md, sliced by ui-slice.md). It reads guild events
-- from the game's calendar (MODE "calendar", needs = 8 for the search field) and syncs officer notices, polls and
-- members' votes on the board, board_m and board_o domains (Store.lua).
-- Config.lua loads first. At load it only sets the constants, the client function and event lists, registers the
-- module and defines the shared helpers: no frame, no client call. Every module field is a thin closure that finds the
-- later file's seam at call time and does nothing while that file is absent.

local _, ns = ...

ns.MODE = "calendar"

-- Every cap and default lives here, once.
ns.C = { READER = "guild", NOTICE_TITLE = 60, NOTICE_BODY = 1000, NOTICE_DAYS = 14, NOTICE_DAYS_MAX = 60,
  NOTICES_LIVE = 30, NOTICES_HELD = 60, AUTHOR_KEY_MAX = 53, POLL_Q = 120, POLL_OPT = 40, POLL_OPTS_MIN = 2,
  POLL_OPTS_MAX = 6, POLL_HOURS = 72, POLL_HOURS_MIN = 1, POLL_HOURS_MAX = 336, POLLS_OPEN = 10, POLLS_HELD = 20,
  POLL_KEEP_DAYS = 7, VOTES_MAX = 20, EVENT_DAYS = 14, EVENT_AFTER_MIN = 180, EVENT_TITLE = 31, EVENT_DESC = 255,
  TITLE_STORE = 64, CREATE_DAYS = 30, MINUTE_STEP = 5, LIST_WAIT = 30, LOGIN_HOURS = 24, LEAD = 15, SECOND_WAIT = 120,
  QUICK_TIMES = { { 19, 0 }, { 19, 45 }, { 20, 0 }, { 21, 0 } } }

-- The client functions this module calls, all through M.Compat (AC4). Never RemoveEvent, ContextMenuEventRemove or
-- CanEditGuildEvent.
local APIS = {
  "C_Calendar.OpenCalendar", "C_Calendar.GetNumGuildEvents", "C_Calendar.GetGuildEventInfo",
  "C_Calendar.GetGuildEventSelectionInfo", "C_Calendar.SetAbsMonth", "C_Calendar.OpenEvent",
  "C_Calendar.GetEventIndex", "C_Calendar.GetEventInfo", "C_Calendar.IsEventOpen", "C_Calendar.CloseEvent",
  "C_Calendar.AreNamesReady", "C_Calendar.GetNumInvites", "C_Calendar.EventGetInvite", "C_Calendar.EventSignUp",
  "C_Calendar.EventTentative", "C_Calendar.EventDecline", "C_Calendar.EventAvailable", "C_Calendar.IsActionPending",
  "C_Calendar.CanAddEvent", "C_Calendar.CreateGuildSignUpEvent", "C_Calendar.EventSetTitle",
  "C_Calendar.EventSetDescription", "C_Calendar.EventSetType", "C_Calendar.EventSetTextureID",
  "C_Calendar.EventSetDate", "C_Calendar.EventSetTime", "C_Calendar.AddEvent", "C_Calendar.GetMaxCreateDate",
  "C_Calendar.EventGetTypesDisplayOrdered", "C_Calendar.EventGetTextures",
  "C_DateAndTime.GetCurrentCalendarTime", "C_GuildInfo.AreGuildEventsEnabled", "C_ChatInfo.InChatMessagingLockdown",
  "GetServerTime",
  -- GetGuildInfo (security f1, Store.lua): optional because it is absent from the API dataset; nil clears nothing.
  optional = { "C_GameRules.IsGameRuleActive", "C_Calendar.GetClubCalendarEvents", "C_Club.GetGuildClubId",
    "GetGuildInfo",
    -- Look.lua: a template or an atlas is used only when the client has it, else the fallback.
    "C_XMLUtil.GetTemplateInfo", "C_Texture.GetAtlasInfo",
    -- Look.Gradient: the colours of a gradient shade; without it the shade is flat.
    "CreateColor" },
}

local EVENTS = {
  "CALENDAR_UPDATE_GUILD_EVENTS", "CALENDAR_UPDATE_EVENT_LIST", "CALENDAR_OPEN_EVENT", "CALENDAR_CLOSE_EVENT",
  "CALENDAR_UPDATE_INVITE_LIST", "CALENDAR_UPDATE_EVENT", "CALENDAR_ACTION_PENDING", "CALENDAR_UPDATE_ERROR",
  "CALENDAR_UPDATE_ERROR_WITH_COUNT", "CALENDAR_UPDATE_ERROR_WITH_PLAYER_NAME", "CALENDAR_EVENT_ALARM",
}

local M = GuildSync and GuildSync.RegisterModule({
  id = "board",
  title = "Notice Board",
  version = "0.4",
  needs = 8,
  apis = APIS,
  events = EVENTS,
  onEvent = function(event, ...) ns.Dispatch(event, ...) end,
  page = {
    icon = "Interface\\Icons\\INV_Misc_Note_01",
    build = function(f) if ns.Page then ns.Page.Build(f) end end,
    refresh = function(f) if ns.Page then ns.Page.Refresh(f) end end,
  },
  -- API 8: the hub's search box (Search.lua)
  search = { find = function(text) return ns.SearchFind and ns.SearchFind(text) end },
  slash = function(rest) if ns.Status then ns.Status.Slash(rest) end end,
  selftest = function()
    if ns.Status then return ns.Status.Selftest() end
    return "wait", "loading"
  end,
  status = function() return ns.Status and ns.Status.Line() or "" end,
  -- AC19: login only sets a flag; the calendar opens on the first roster read (Calendar.lua).
  onLogin = function() ns.loggedIn = true end,
  -- API 2: /gsync demo hands the builder a copy of the made-up guild; its state replaces the real data while on.
  demo = function(guild, now) if ns.Demo then return ns.Demo.Build(guild, now) end end,
  -- The before-start lead on Options > GuildSync > Notice Board (d705); writes the same GuildSyncNoticeBoardDB.lead as
  -- /gsboard lead. The hub calls this at login, after SavedVariables load, so a saved value the list lacks (set with
  -- the slash) gets its own entry here. A board loaded after login would miss that entry (f4910).
  settings = function(S)
    local values = { { 0, "Off" } }
    for _, n in ipairs({ 5, 10, 15, 30, 45, 60, 90, 120, 180, 360, 720, 1440 }) do
      values[#values + 1] = { n, n .. " minutes before" }
    end
    local function lead() return ns.DB and ns.DB() and ns.DB().lead end
    local saved = lead()
    if type(saved) == "number" then
      local at = #values + 1
      for i, v in ipairs(values) do
        if v[1] == saved then at = nil break end
        if v[1] > saved then at = i break end
      end
      if at then table.insert(values, at, { saved, saved .. " minutes (set with /gsboard lead)" }) end
    end
    S.Dropdown("lead", "Notice Board: before-start line", ns.C.LEAD, values, lead,
      function(v) if ns.Remind then ns.Remind.SetLead(v) end end)
  end,
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code

-- ---------- shared helpers ----------

-- Subscribers per EVENTS name, fed by the hub through onEvent above.
local listeners = {}

-- fn(...) on that event.
function ns.Listen(event, fn)
  local list = listeners[event]
  if not list then
    list = {}
    listeners[event] = list
  end
  list[#list + 1] = fn
end

-- Calls every ns.Listen fn for event, in the order they subscribed; a throw in one is recorded and the rest still run.
function ns.Dispatch(event, ...)
  local list = listeners[event]
  if not list then return end
  for _, fn in ipairs(list) do M.Safe(fn, ...) end
end

-- Server time, or nil when the client does not answer.
function ns.Now() return M.Compat.call("GetServerTime") end

function ns.InDemo()
  local on = M.Demo()
  return on and true or false
end

-- What this module's demo builder returned at demo start (nil when demo is off).
function ns.DemoState()
  local _, state = M.Demo()
  return state
end

-- f1510: a member's display name. Real members come from the roster; while demo is on, the made-up members the demo
-- builder used (DemoState().names) are not in it, so their names come from there; else the key.
function ns.MemberName(key)
  local row = GuildSync.Comm.Member(key)
  if row and row.name then return row.name end
  local state = ns.InDemo() and ns.DemoState()
  local names = type(state) == "table" and state.names
  return type(names) == "table" and names[key] or key
end

-- The one line every write says while demo is on.
function ns.Inert() GuildSync.Say("Demo: nothing is done to made-up members.") end
