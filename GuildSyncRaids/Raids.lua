-- GuildSyncRaids: the guild's raid calendar (Raid-Helper) in the GuildSync window. An officer pastes the string the
-- website's /officers/ "Copy for the game" builds; the module shares it on GuildSync's comms (domain "raids") and every
-- member sees the raids, sign-ups and team lists read-only. This file is the host: it registers the module, captures
-- the GuildSync reads the other files use, owns the SavedVariable and the slash command.
-- Files (TOC order): Raids (host), Decode (GSR1 decoder), Codec (record bodies), Rules (pure rules), PullRules (pure
-- pull rules), ReadyData (the ready check's buff table), ReadyRules (pure ready rules), Store (domain, share), Pulls
-- (the pull recorder), Ready (the ready check: own read, state), Page (the Raids page), RaidList, RaidView, Signups,
-- PullsView (the Pulls tab), ReadyView (the Ready tab), Paste (its cards), Tools (officers' tools, reminder, demo),
-- Search (the hub search's Raids group).
-- Stubs from F1, each filled by its owner ticket (TOC order): RosterRules (56), WishRules (58), LootRules (59),
-- RollRules (60), NotesCodec (61), NotesRules (61), InviteRules (57), Items, Group, Nights, Chat (F's libraries),
-- WishStore (58), Loot (59), SessionWire (60), LootPolicy (60), NotesStore (61), GroupsView (56), RosterEdit (56),
-- WishCard (58), LootView (59), LootWindow (60), RollPopup (60), NotesView (61), JobCard (61), InvitesView (57).

local _, ns = ...

-- Delegates are looked up at call time: later files define them, and a test may replace them.
local function slash(rest) if ns.Slash then ns.Slash(rest) end end
-- The pull recorder's events, exactly main's; no new event reaches it.
local PULL = { GROUP_ROSTER_UPDATE = true, PLAYER_REGEN_ENABLED = true, PLAYER_ENTERING_WORLD = true,
  ENCOUNTER_START = true, ENCOUNTER_END = true }
-- The new events, each to its owner's delegate (WIRE.md): chat (F Chat), items (F Items), the loot window (60), the
-- boss loot (59), the fight (61), the blocked guard (57), the worn and carried items (58, the "has it" mark). Two old
-- events are routed too, after the pull recorder and the ready check took them: the fight's end (61) and the roster
-- change (57, a page redraw).
local ROUTE = { CHAT_MSG_LOOT = "OnChatEvent", CHAT_MSG_SYSTEM = "OnChatEvent", CHAT_MSG_RAID = "OnChatEvent",
  CHAT_MSG_RAID_LEADER = "OnChatEvent", CHAT_MSG_RAID_WARNING = "OnChatEvent", CHAT_MSG_PARTY = "OnChatEvent",
  CHAT_MSG_PARTY_LEADER = "OnChatEvent", GET_ITEM_INFO_RECEIVED = "OnItemEvent", ITEM_DATA_LOAD_RESULT = "OnItemEvent",
  LOOT_OPENED = "OnLootWindow", LOOT_CLOSED = "OnLootWindow", ENCOUNTER_LOOT_RECEIVED = "OnEncounterLoot",
  PLAYER_REGEN_DISABLED = "OnFightEvent", PLAYER_REGEN_ENABLED = "OnFightEvent",
  ADDON_ACTION_BLOCKED = "OnBlockedEvent", ADDON_ACTION_FORBIDDEN = "OnBlockedEvent",
  PLAYER_EQUIPMENT_CHANGED = "OnWishEvent", BAG_UPDATE_DELAYED = "OnWishEvent",
  GROUP_ROSTER_UPDATE = "OnGroupEvent" }
-- The listeners of ns.AfterCombat (below): each runs when a fight ends, after the delegates above.
local afterCombat = {}
-- Each delegate runs under M.Safe on its own, so a failing pull recorder never stops the ready check, or the reverse.
local function onEvent(event, ...)
  if PULL[event] and ns.OnPullEvent then ns.M.Safe(ns.OnPullEvent, event, ...) end
  if (event == "READY_CHECK" or event == "GROUP_ROSTER_UPDATE") and ns.OnReadyEvent then
    ns.M.Safe(ns.OnReadyEvent, event, ...)
  end
  local fn = ROUTE[event] and ns[ROUTE[event]]
  if type(fn) == "function" then ns.M.Safe(fn, event, ...) end
  if event == "PLAYER_REGEN_ENABLED" then
    for _, listener in ipairs(afterCombat) do ns.M.Safe(listener) end
  end
end

local M = GuildSync and GuildSync.RegisterModule({
  id = "raids",
  title = "Raids",
  version = "0.5",
  needs = 11,
  page = {
    title = "Raids",
    icon = "Interface\\Icons\\INV_Misc_Book_11",
    build = function(frame) if ns.BuildPage then ns.BuildPage(frame) end end,
    refresh = function(frame) if ns.RefreshPage then ns.RefreshPage(frame) end end,
  },
  slash = slash,
  -- The pull recorder (Pulls.lua): the group snapshot out of combat, and the boss pulls. The ready check (Ready.lua):
  -- READY_CHECK, and the raid roster on GROUP_ROSTER_UPDATE. Then the new events in ROUTE above.
  events = { "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "ENCOUNTER_START", "ENCOUNTER_END",
    "READY_CHECK", "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "LOOT_OPENED",
    "LOOT_CLOSED", "ENCOUNTER_LOOT_RECEIVED", "PLAYER_REGEN_DISABLED", "ADDON_ACTION_BLOCKED",
    "ADDON_ACTION_FORBIDDEN", "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED" },
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
    if ns.NightsLogin then ns.M.Safe(ns.NightsLogin) end
    if ns.Login then ns.Login() end
    if ns.PullsLogin then ns.PullsLogin() end
    if ns.LootLogin then ns.M.Safe(ns.LootLogin) end -- the loot log's prune (59)
    if ns.WishLogin then ns.M.Safe(ns.WishLogin) end -- the wish list's "has it" marks (58)
  end,
  -- /gsync demo: the hub's made-up guild and its time; Tools.lua builds the calendar from them on first read
  -- (ns.DemoData), so a call made while this file registers still works. Never saved, never sent.
  demo = function(guild, now) return { guild = guild, now = now } end,
  apis = { "GetServerTime", optional = { "C_PartyInfo.InviteUnit", "C_PartyInfo.ConvertToRaid",
    "C_PartyInfo.IsPartyFull", "UnitInParty", "UnitInRaid", "UnitIsGroupLeader", "UnitIsGroupAssistant",
    "ChatFrameUtil.OpenChat", "ChatFrame_OpenChat", "UnitGUID", "UnitName", "UnitExists", "InCombatLockdown",
    "IsInInstance", "C_InstanceEncounter.IsEncounterInProgress", "C_UnitAuras.GetAuraDataByIndex",
    "C_Secrets.ShouldAurasBeSecret", "C_Secrets.ShouldUnitAuraIndexBeSecret", "UnitResistance",
    "C_ChatInfo.InChatMessagingLockdown", "C_Item.GetItemInfo", "C_Item.GetItemInfoInstant",
    "C_Item.RequestLoadItemDataByID", "GetNumLootItems", "GetLootSlotLink", "GetRaidRosterInfo", "GetNumGroupMembers",
    "IsInRaid", "C_PartyInfo.CanInvite", "C_PartyInfo.AllowedToDoPartyConversion", "hooksecurefunc",
    "C_Item.IsItemDataCachedByID", "C_Item.GetItemIconByID", "C_Item.DoesItemExistByID", "UnitIsConnected",
    "C_ChatInfo.SendChatMessage", "C_RestrictedActions.IsAddOnRestrictionActive", "C_Item.GetItemQualityColor",
    "RandomRoll", "C_Item.GetItemCount", "C_Item.IsEquippedItem", "GetInstanceInfo" } },
  -- The invite batch, the ready check's Options, the roll session's (60) and the job card's (61). get reads the
  -- SavedVariable directly and writes nothing (it may run before the files ran); set goes through ns.SetBatch,
  -- ns.SetReadyOption, ns.SetSessionOption or ns.SetCardOption, looked up at call time.
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
    -- GuildSyncRaidsDB[a][b] or [a][b][c], nil unless v == 1 and each nested value is a table
    local function saved(a, b, c)
      local t = GuildSyncRaidsDB
      if type(t) ~= "table" or t.v ~= 1 or type(t[a]) ~= "table" then return nil end
      t = t[a]
      if c == nil then return t[b] end
      if type(t[b]) ~= "table" then return nil end
      return t[b][c]
    end
    local function setSession(key)
      return function(v) if ns.SetSessionOption then ns.SetSessionOption(key, v) end end
    end
    local function setCard(key) return function(v) if ns.SetCardOption then ns.SetCardOption(key, v) end end end
    local seconds = {}
    for n = 10, 60, 5 do seconds[#seconds + 1] = { n, tostring(n) } end
    S.Dropdown("rolltime", "Raids: roll time (seconds)", 20, seconds,
      function() return saved("session", "rollTime") end, setSession("rollTime"), "How long a loot roll stays open.")
    S.Checkbox("rollsend", "Raids: Start roll sends the line", false, function() return saved("session", "send") end,
      setSession("send"), "Start roll also says the roll line in raid chat.")
    S.Checkbox("cardoncall", "Raids: open the job card on the leader's call", true,
      function() return saved("notes", "card", "onCall") end, setCard("onCall"),
      "The job card opens when the raid leader calls the jobs.")
    S.Checkbox("cardfight", "Raids: hide the job card in a fight", true,
      function() return saved("notes", "card", "hideInFight") end, setCard("hideInFight"),
      "The job card hides while you are in combat.")
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

-- After a fight: fn() runs at every PLAYER_REGEN_ENABLED, under M.Safe on its own, in the order added. For a view
-- that held a redraw back in combat. true, or nil and "fn".
function ns.AfterCombat(fn)
  if type(fn) ~= "function" then return nil, "fn" end
  afterCombat[#afterCombat + 1] = fn
  return true
end

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
  if type(db.nights) ~= "table" then db.nights = {} end
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
  elseif cmd == "loot" and ns.LootSlash then
    ns.LootSlash(arg)
  elseif cmd == "roll" and ns.RollSlash then
    ns.RollSlash(arg)
  else
    -- loot and roll are named only while their owner's delegate is there (a word with none prints this line)
    local help = "/gsraids opens the page; /gsraids batch <1-40> sets how many invites one click sends; /gsraids pulls"
      .. " lists the last 5 pulls"
    if ns.LootSlash then help = help .. "; /gsraids loot lists the last loot awards" end
    if ns.RollSlash then help = help .. "; /gsraids roll opens the loot window" end
    say(help)
  end
end

SLASH_GSRAIDS1 = "/gsraids"
SlashCmdList.GSRAIDS = function(msg) M.Safe(slash, msg) end
