-- GuildSyncExpeditions: registers the Expeditions module through GuildSync's public API (API.md, needs 9 for the hub
-- purse) on the Games closure pattern: every field handed to RegisterModule is a closure that looks up its ns.*
-- function when it is called and does nothing while it is missing. Store, Demo, Probe, Page and the later slices'
-- files load after this one (the TOC's groups) and define those functions.
-- The apis, events and facts are the 0.19 plan's Seams 13 lists. The four facts answer nil until slice I.
-- /gsync expeditions opens the page; /gsync expeditions probe ... runs the in-game probe (Probe.lua).

local _, ns = ...

local function say(text)
  if GuildSync and GuildSync.Say then GuildSync.Say("Expeditions: " .. text) end
end

local USAGE = "/gsync expeditions opens the page; /gsync expeditions probe [arm <place|mail|kill|talk> | model <race>"
  .. " <sex> | model next] runs the probe."

local function slash(rest)
  local cmd, more = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "" then
    ns.M.OpenPage()
  elseif cmd == "probe" and ns.Probe then
    ns.Probe(more or "")
  else
    say(USAGE)
  end
end

local function fact(name)
  return function(key)
    local f = ns.Fact and ns.Fact[name]
    if f then return f(key) end
    return nil
  end
end

-- Each function under its own Safe, so one throw does not stop the next. Core.lua:334 can call onLogin during
-- registration, before ns.M is set.
local function walk(first, hooks, ...)
  if not ns.M then return end
  if first then ns.M.Safe(first, ...) end
  for _, hook in ipairs(hooks) do ns.M.Safe(hook, ...) end
end

local M = GuildSync and GuildSync.RegisterModule({
  id = "expeditions",
  title = "Expeditions",
  version = "0.1",
  needs = 9,
  -- Seams 13. The probe (Probe.lua) calls each one through M.Compat.Try; later slices read them through M.Compat.call.
  apis = { "GetServerTime",
    optional = { "C_DateAndTime.GetSecondsUntilDailyReset", "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition",
      "C_Map.GetMapInfo", "GetSendMailItem", "C_Item.GetItemCount", "C_Item.GetItemInfo", "UnitGUID", "UnitName",
      "UnitRace", "UnitSex", "UnitIsDead", "C_QuestLog.IsQuestFlaggedCompleted",
      "C_Map.GetMapArtLayerTextures", "C_Map.GetMapArtLayers", "C_Map.GetMapRectOnMap",
      "C_MapExplorationInfo.GetExploredMapTextures", "PlaySound", "C_Sound.PlaySound",
      "InCombatLockdown" } },
  events = { "ZONE_CHANGED_NEW_AREA", "MAIL_SHOW", "MAIL_SEND_INFO_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED",
    "MAIL_CLOSED", "PARTY_KILL", "PLAYER_TARGET_CHANGED", "GOSSIP_SHOW", "QUEST_GREETING", "MERCHANT_SHOW" },
  onEvent = function(event, ...) walk(ns.OnProbeEvent, ns.EventHooks, event, ...) end,
  onLogin = function() walk(ns.OnLogin, ns.LoginHooks) end,
  page = {
    title = "Expeditions",
    icon = "Interface\\Icons\\INV_Misc_Map_01",
    build = function(frame) if ns.BuildPage then ns.BuildPage(frame) end end,
    refresh = function(frame) if ns.RefreshPage then ns.RefreshPage(frame) end end,
  },
  slash = slash,
  demo = function(guild, now)
    if ns.DemoState then return ns.DemoState(guild, now) end
    return nil
  end,
  facts = { best = fact("best"), flair = fact("flair"), quests = fact("quests"), deadly = fact("deadly") },
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code
ns.LoginHooks, ns.EventHooks = {}, {}

-- The hub reads every file uses, captured once right after the guard (API.md).
ns.Escape = GuildSync.Escape
ns.Say = say
