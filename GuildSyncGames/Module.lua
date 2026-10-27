-- GuildSyncGames: registers the Games module through GuildSync's public API (API.md) and captures the hub reads the
-- other files use. Every field handed to RegisterModule is a closure that looks up its ns.* function when it is called
-- and does nothing while it is missing (the People pattern): Store, SyncKit, Sync, Grain, Boards, Page, WoWdle,
-- Harvest, Races, Flight, Toast, Demo and Facts load after this file and define those functions (plan Seams).
-- Words.lua, Core.lua and GrainCore.lua load before it.
-- The page is the Games window page (a tab row, WoWdle first). There is no slash command of its own:
-- /gsync games opens the page, /gsync games flight on|off turns the flight prompt on or off.

local _, ns = ...

local function say(text)
  if GuildSync and GuildSync.Say then GuildSync.Say("Games: " .. text) end
end

local function slash(rest)
  local cmd, arg = string.match(string.lower(rest or ""), "^%s*(%S*)%s*(%S*)")
  if cmd == nil or cmd == "" then
    ns.M.OpenPage()
  elseif cmd == "flight" and (arg == "on" or arg == "off") then
    if ns.SetFlight then
      ns.SetFlight(arg == "on")
      say("the flight prompt is " .. arg .. ".")
    end
  else
    say("/gsync games opens the page; /gsync games flight on|off turns the flight prompt on or off.")
  end
end

local M = GuildSync and GuildSync.RegisterModule({
  id = "games",
  title = "Games",
  version = "0.1",
  needs = 8,
  -- The flight checks and the chat box are optional (f7075): a missing one means no prompt, or the plain share line.
  apis = { "GetServerTime",
    -- GetGuildInfo (f7100, Store.lua): optional because it is absent from the API dataset, as in NoticeBoard.
    optional = { "UnitOnTaxi", "IsInInstance", "InCombatLockdown", "C_DateAndTime.GetSecondsUntilDailyReset",
      "ChatFrameUtil.OpenChat", "ChatFrame_OpenChat", "GetGuildInfo",
      -- GetGameTime (S11): the realm hour in a race's label; missing, the label says UTC.
      "GetGameTime",
      -- UnitClass, UnitName (d1720, S17): the own-card preview reads them through M.Compat.call; missing, it draws with no name or icon.
      "UnitClass", "UnitName" } },
  -- PLAYER_REGEN_DISABLED (S11): the race toast's combat check (Toast.lua).
  events = { "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED", "PLAYER_REGEN_DISABLED" },
  onEvent = function(event, ...)
    if ns.OnEvent then ns.OnEvent(event, ...) end
    if ns.OnToastEvent then ns.OnToastEvent(event, ...) end
  end,
  -- Grain.lua's ns.OnLogin settles a past bet, arms the toast and starts the tick (idempotent, f7157).
  onLogin = function() if ns.OnLogin then ns.OnLogin() end end,
  page = {
    title = "Games",
    icon = "Interface\\Icons\\INV_Misc_Dice_01",
    build = function(frame) if ns.BuildPage then ns.BuildPage(frame) end end,
    refresh = function(frame) if ns.RefreshPage then ns.RefreshPage(frame) end end,
  },
  slash = slash,
  demo = function(guild, now)
    if ns.DemoState then return ns.DemoState(guild, now) end
    return nil
  end,
  settings = function(S)
    S.Checkbox("flight", "Games: offer a game on flights", true,
      function() if ns.FlightOn then return ns.FlightOn() end return nil end,
      function(v) if ns.SetFlight then ns.SetFlight(v) end end)
  end,
  facts = {
    streak = function(key) if ns.FactStreak then return ns.FactStreak(key) end return nil end,
    wins = function(key) if ns.FactWins then return ns.FactWins(key) end return nil end,
  },
  -- The hub checks the apis and events first; this adds the day, or why there is none.
  selftest = function()
    if type(ns.WORDS) ~= "table" then return "pass", "no words" end
    local today = ns.Today and ns.Today()
    if type(today) ~= "table" then return "pass", "words loaded" end
    return "pass", "today " .. tostring(today.label)
  end,
  status = function()
    local today = ns.Today and ns.Today()
    if type(today) ~= "table" then return "no word today" end
    local tries = type(today.rows) == "table" and #today.rows or 0
    if today.done then return tostring(today.label) .. (today.won and (" solved in " .. tries) or " not solved") end
    return tostring(today.label) .. ", " .. tries .. " of 6 tries"
  end,
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code

-- The hub reads every file uses, captured once right after the guard (API.md).
ns.Escape = GuildSync.Escape
ns.MyKey = GuildSync.Comm.MyKey
ns.Roster = GuildSync.Comm.Roster
ns.Member = GuildSync.Comm.Member
ns.Key = GuildSync.Comm.Key
ns.Person = GuildSync.Comm.Person -- API 7: the boards fold a player's characters under their main (q1547)
ns.IsOfficer = GuildSync.Comm.IsOfficer -- S14: the officer of a games_c section is the stored record's key (d1602)
