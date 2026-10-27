-- GuildSyncPeople: a personal profile card shared with the guild.
-- This file registers the module through GuildSync's public API (API.md), captures the hub reads every file uses, and
-- owns /gspeople. Every field handed to RegisterModule is a closure that looks up its ns.* function when it is called
-- and does nothing while it is missing: the later files (Roster, Store, Hooks, Grid, Profile, Section, Page) load after this one,
-- and a module registered after login gets its settings at once (design review f10).

local _, ns = ...

local function slash(rest)
  rest = rest or ""
  if string.find(rest, "^%s*$") then
    ns.M.OpenPage()
  elseif ns.Slash then
    ns.Slash(rest)
  end
end

local M = GuildSync and GuildSync.RegisterModule({
  id = "people",
  title = "People",
  version = "0.4",
  needs = 8,
  -- C_Secrets and the chat lockdown are optional (f13 ruling): a missing guard reads as secret / in lockdown.
  apis = { "GetServerTime", "GetGameTime", "GetGuildInfo", "C_Club.GetGuildClubId", "C_Club.GetClubInfo",
    "C_Club.GetClubMembers", "C_Club.GetMemberInfo", "UnitGUID", "UnitIsPlayer", "UnitIsInMyGuild",
    "C_DateAndTime.GetCurrentCalendarTime", "C_AddOns.IsAddOnLoaded",
    optional = { "C_CreatureInfo.GetRaceInfo", "C_CreatureInfo.GetClassInfo", "C_ClassColor.GetClassColor",
      "C_Secrets.ShouldUnitIdentityBeSecret", "C_ChatInfo.InChatMessagingLockdown", "InCombatLockdown" } },
  page = {
    title = "People",
    icon = "Interface\\Icons\\INV_Misc_GroupNeedMore",
    build = function(frame) if ns.BuildPage then ns.BuildPage(frame) end end,
    refresh = function(frame) if ns.RefreshPage then ns.RefreshPage(frame) end end,
  },
  -- API 7: the section under the Roster's member panel (PeopleSection.lua); it draws into frame and sets its height only.
  member = {
    build = function(frame) if ns.BuildSection then ns.BuildSection(frame) end end,
    refresh = function(frame, key) if ns.RefreshSection then ns.RefreshSection(frame, key) end end,
  },
  slash = slash,
  selftest = function()
    if ns.Selftest then return ns.Selftest() end
    return "wait", "still loading"
  end,
  status = function()
    if ns.Status then return ns.Status() end
    return "still loading"
  end,
  demo = function(guild, now)
    if ns.Demo and ns.Demo.Build then return ns.Demo.Build(guild, now) end
    return nil
  end,
  settings = function(S)
    S.Checkbox("hover", "People: show the card on hover", true,
      function() if ns.Hover then return ns.Hover() end return nil end,
      function(v) if ns.SetHover then ns.SetHover(v) end end)
  end,
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code

-- The hub reads every file uses, captured once right after the guard (API.md; Hello.lua:96-98).
ns.Escape = GuildSync.Escape
ns.MyKey = GuildSync.Comm.MyKey
ns.Member = GuildSync.Comm.Member
ns.Key = GuildSync.Comm.Key
ns.Person = GuildSync.Comm.Person

-- Its own slash command; /gsync people ... runs the same handler.
SLASH_GSPEOPLE1 = "/gspeople"
SlashCmdList.GSPEOPLE = function(msg) M.Safe(slash, msg) end
