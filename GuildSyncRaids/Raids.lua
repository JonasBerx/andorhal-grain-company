-- GuildSyncRaids: the guild's raid calendar (Raid-Helper) in the GuildSync window. An officer pastes the string the
-- website's /officers/ "Copy for the game" builds; the module shares it on GuildSync's comms (domain "raids") and every
-- member sees the raids, sign-ups and team lists read-only. This file is the host: it registers the module, captures
-- the GuildSync reads the other files use, owns the SavedVariable and the slash command.
-- Files (TOC order): Raids (host), Decode (GSR1 decoder), Codec (record bodies), Rules (pure rules), PullRules (pure
-- pull rules), ReadyData (the ready check's buff table), ReadyRules (pure ready rules), Store (domain, share), Pulls
-- (the pull recorder), Ready (the ready check: own read, state), Page (the Raids page), RaidList, RaidView, Signups,
-- PullsView (the Pulls tab), ReadyView (the Ready tab), Paste (its cards), Tools (officers' tools, reminder, demo),
-- Search (the hub search's Raids group).

local _, ns = ...

-- Delegates are looked up at call time: later files define them, and a test may replace them.
local function slash(rest) if ns.Slash then ns.Slash(rest) end end
-- Each delegate runs under M.Safe on its own, so a failing pull recorder never stops the ready check, or the reverse.
local function onEvent(event, ...)
  if event ~= "READY_CHECK" and ns.OnPullEvent then ns.M.Safe(ns.OnPullEvent, event, ...) end
  if (event == "READY_CHECK" or event == "GROUP_ROSTER_UPDATE") and ns.OnReadyEvent then
    ns.M.Safe(ns.OnReadyEvent, event, ...)
  end
end

local M = GuildSync and GuildSync.RegisterModule({
  id = "raids",
  title = "Raids",
  version = "0.5",
  needs = 8,
  page = {
    title = "Raids",
    icon = "Interface\\Icons\\INV_Misc_Book_11",
    build = function(frame) if ns.BuildPage then ns.BuildPage(frame) end end,
    refresh = function(frame) if ns.RefreshPage then ns.RefreshPage(frame) end end,
  },
  slash = slash,
  -- The pull recorder (Pulls.lua): the group snapshot out of combat, and the boss pulls. The ready check (Ready.lua):
  -- READY_CHECK, and the raid roster on GROUP_ROSTER_UPDATE.
  events = { "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ENCOUNTER_START", "ENCOUNTER_END",
    "READY_CHECK" },
  onEvent = onEvent,
  -- The hub search (API 8): ns.SearchFind (Search.lua), looked up at call time.
  search = { find = function(text) return ns.SearchFind and ns.SearchFind(text) end },
  selftest = function()
    if not ns.Selftest then return "wait", "not ready" end
    return ns.Selftest()
  end,
  status = function()
    if not ns.Status then return "no raid data yet" end
    return ns.Status()
  end,
  onLogin = function()
    if ns.Login then ns.Login() end
    if ns.PullsLogin then ns.PullsLogin() end
  end,
  -- /gsync demo: the hub's made-up guild and its time; Tools.lua builds the calendar from them on first read
  -- (ns.DemoData), so a call made while this file registers still works. Never saved, never sent.
  demo = function(guild, now) return { guild = guild, now = now } end,
  apis = { "GetServerTime", optional = { "C_PartyInfo.InviteUnit", "C_PartyInfo.ConvertToRaid",
    "C_PartyInfo.IsPartyFull", "UnitInParty", "UnitInRaid", "UnitIsGroupLeader", "UnitIsGroupAssistant",
    "ChatFrameUtil.OpenChat", "ChatFrame_OpenChat", "UnitGUID", "UnitName", "UnitExists", "InCombatLockdown",
    "IsInInstance", "C_InstanceEncounter.IsEncounterInProgress", "C_UnitAuras.GetAuraDataByIndex",
    "C_Secrets.ShouldAurasBeSecret", "C_Secrets.ShouldUnitAuraIndexBeSecret", "UnitResistance" } },
  -- The invite batch and the ready check's Options. get reads the SavedVariable directly and writes nothing (it may
  -- run before the files ran); set goes through ns.SetBatch or ns.SetReadyOption, looked up at call time.
  settings = function(S)
    local values = {}
    for n = 1, 40 do values[n] = { n, tostring(n) } end
    S.Dropdown("batch", "Raids: invite batch", 5, values,
      function()
        local db = GuildSyncRaidsDB
        if type(db) == "table" and db.v == 1 then return db.batch end
        return nil
      end,
      function(v) if ns.SetBatch then ns.SetBatch(v) end end,
      "How many invites one click on the invite button sends.")
    local function ready(key)
      local db = GuildSyncRaidsDB
      if type(db) == "table" and db.v == 1 and type(db.ready) == "table" then return db.ready[key] end
      return nil
    end
    local function setReady(key) return function(v) if ns.SetReadyOption then ns.SetReadyOption(key, v) end end end
    for _, c in ipairs({ { "flask", "a flask", true }, { "elixir", "elixirs", true }, { "food", "buff food", true },
      { "world", "world buffs", false } }) do
      S.Checkbox(c[1], "Raids: ready check counts " .. c[2], c[3], function() return ready(c[1]) end, setReady(c[1]),
        "On the Ready tab, a raid member without " .. c[2] .. " shows as missing it.")
    end
    local marks = { { 0, "Off" } }
    for n = 50, 300, 50 do marks[#marks + 1] = { n, tostring(n) } end
    S.Dropdown("fire", "Raids: fire resistance mark", 0, marks, function() return ready("fire") end, setReady("fire"),
      "On the Ready tab, fire resistance at or above this shows green.")
  end,
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code

-- The reads this addon uses, captured once right after the guard (API.md: capture what you need at load).
ns.Say, ns.Escape, ns.OpenWhisper = GuildSync.Say, GuildSync.Escape, GuildSync.OpenWhisper
ns.Roster, ns.Member, ns.Key = GuildSync.Comm.Roster, GuildSync.Comm.Member, GuildSync.Comm.Key
ns.MyKey, ns.IsOfficer = GuildSync.Comm.MyKey, GuildSync.Comm.IsOfficer

-- In demo the roster reads answer from the made-up guild (the player's own rank stays the real one: IsOfficer).
local realRoster, realMember = ns.Roster, ns.Member
function ns.Roster()
  local d = ns.DemoData and ns.DemoData()
  if d then return d.rows, false, 0, true end
  return realRoster()
end
function ns.Member(name)
  local d = ns.DemoData and ns.DemoData()
  if not d then return realMember(name) end
  local r = type(name) == "string" and d.rows[ns.Key(name) or ""]
  return r and { name = r.name, class = r.class, online = r.online, rankIndex = r.rankIndex } or nil
end

local function say(text) ns.Say("Raids: " .. text) end

-- The saved data, bound lazily: the SavedVariable is set only after the files ran. A missing or other version
-- starts empty (nothing to migrate).
function ns.DB()
  local db = GuildSyncRaidsDB
  if type(db) ~= "table" or db.v ~= 1 then
    db = { v = 1, records = {}, gone = {}, batch = 5, pulls = {} }
    GuildSyncRaidsDB = db
  end
  -- pre-launch: a missing or broken pulls field starts empty (no migration; PULLS-FORMAT.md)
  if type(db.pulls) ~= "table" then db.pulls = {} end
  return db
end

-- /gsraids (and /gsync raids ...): open the page, set the invite batch, or list the last pulls.
function ns.Slash(rest)
  local cmd, arg = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "" then
    M.OpenPage()
  elseif cmd == "batch" and ns.SetBatch then
    local okBatch, why = ns.SetBatch(tonumber(arg))
    if okBatch then say("invite batch set to " .. tostring(tonumber(arg))) else say(tostring(why)) end
  elseif cmd == "pulls" and ns.PullsChat then
    ns.PullsChat()
  else
    say("/gsraids opens the page; /gsraids batch <1-40> sets how many invites one click sends; /gsraids pulls lists"
      .. " the last 5 pulls")
  end
end

SLASH_GSRAIDS1 = "/gsraids"
SlashCmdList.GSRAIDS = function(msg) M.Safe(slash, msg) end
