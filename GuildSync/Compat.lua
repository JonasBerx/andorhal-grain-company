-- GuildSync Compat: every client API call the addon makes lives in this file, wrapped and guarded.
-- No other file touches a Blizzard global. A missing function means "not recorded", never an error.
--
-- Every Blizzard function is reached through the local call() helper with a dotted name, which resolves it through _G,
-- returns nothing when it is absent, and runs it under pcall. Every name passed to call() must be listed in
-- Compat.APIS so the probe can report which ones this client really has.
-- Verified against build 1.60.1.69893: the generated API documentation and Blizzard's own interface code.

local ADDON, ns = ...

local Compat = {}
ns.Compat = Compat

-- A release version is X.Y.Z (digits only); anything else, or a non-string, reads as DEV_VERSION.
Compat.DEV_VERSION = "0.0.0-dev"
function Compat.ReleaseVersion(v)
  if type(v) == "string" and v:match("^%d+%.%d+%.%d+$") then return v end
  return Compat.DEV_VERSION
end

-- ---------- plumbing ----------

-- Functions Compat calls. The probe walks this list.
Compat.APIS = {
  "GetBuildInfo", "GetServerTime", "issecretvalue",
  "C_Timer.After",
  "C_RestrictedActions.IsAddOnRestrictionActive", "C_RestrictedActions.GetAddOnRestrictionState",
  "C_ChatInfo.InChatMessagingLockdown",
  "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", -- the comm core (CommQueue.lua)
  "C_GuildBank.IsGuildBankEnabled", "C_TradeSkillUI.IsGuildTradeSkillsEnabled",
  "C_DamageMeter.IsDamageMeterAvailable", "C_GameRules.IsHardcoreActive",
  "UnitName", "UnitGUID", "UnitClass", "UnitLevel", "GetRealmName", "GetMoney",
  "IsInGuild", "GetGuildInfo",
  "C_TradeSkillUI.IsTradeSkillReady", "C_TradeSkillUI.IsDataSourceChanging", "C_TradeSkillUI.IsTradeSkillLinked",
  "C_TradeSkillUI.IsTradeSkillGuild", "C_TradeSkillUI.IsTradeSkillGuildMember", "C_TradeSkillUI.IsNPCCrafting",
  "C_TradeSkillUI.IsRuneforging", "C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.GetChildProfessionInfo",
  "C_TradeSkillUI.GetFilteredRecipeIDs", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeSchematic",
  "C_TradeSkillUI.GetProfessionInfoByRecipeID", "GetProfessions", "GetProfessionInfo",
  "C_Club.GetGuildClubId", "C_Club.GetClubMembers", "C_Club.GetMemberInfo", "C_Club.FocusMembers",
  "C_CreatureInfo.GetClassInfo", "C_GuildInfo.GuildRoster", "C_GuildInfo.CanViewOfficerNote",
  "GuildControlGetNumRanks", "GuildControlGetRankName", "GetNumGuildMembers",
  "QueryGuildEventLog", "GetNumGuildEvents", "GetGuildEventInfo",
  "GetPlayerInfoByGUID",
  "InCombatLockdown", "CreateFrame",
  "GetCursorPosition", "C_ClassColor.GetClassColor",
  "C_Texture.GetAtlasInfo", -- Kit.Atlas (Kit.lua): set an atlas only when the client has it
  "C_XMLUtil.GetTemplateInfo", -- Kit.HasTemplate (Kit.lua): use a frame template only when the client has it
  -- officer actions (0.9): what this character may do, and the four calls the side panel's buttons make
  "IsGuildLeader", "C_GuildInfo.GuildControlGetRankFlags", "C_GuildInfo.CanEditOfficerNote",
  "C_GuildInfo.Promote", "C_GuildInfo.Demote", "C_GuildInfo.RemoveFromGuild", "C_GuildInfo.SetNote",
  "C_GuildInfo.GetGuildRankOrder", -- a member's rank read again at click time (Window.lua)
  "ChatFrameUtil.SendTell", "ChatFrameUtil.InsertLink", -- Compat.OpenWhisper (GuildSync.OpenWhisper)
  -- the game's Options window (Compat.SettingsHas, Compat.Options*, Compat.OpenOptions) and StaticPopup (Compat.Popup)
  "Settings.RegisterVerticalLayoutCategory", "Settings.RegisterVerticalLayoutSubcategory",
  "Settings.RegisterAddOnCategory", "Settings.RegisterProxySetting", "Settings.CreateCheckbox", "Settings.CreateDropdown",
  "Settings.CreateControlTextContainer", "CreateSettingsButtonInitializer", "Settings.RegisterCanvasLayoutCategory",
  "Settings.OpenToCategory", "StaticPopup_Show",
  -- the game's page tabs and anchored menus (Compat.SelectTab, Compat.TabResize, Compat.OpenMenu)
  "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_TabResize",
  "Menu.GetManager", "Menu.PopulateDescription", "MenuVariants.GetDefaultContextMenuMixin",
  "MenuUtil.CreateRootMenuDescription", "AnchorUtil.CreateAnchor",
  -- installed addons' TOC data (Compat.AddOn, the Modules page)
  "C_AddOns.GetAddOnMetadata", "C_AddOns.GetAddOnInfo", "C_AddOns.IsAddOnLoaded", "C_AddOns.DoesAddOnExist",
  -- kit art (API 6): the game's item button (Kit.SetItem) and the player's faction (Compat.Faction)
  "SetItemButtonTexture", "SetItemButtonQuality", "SetItemButtonCount", "UnitFactionGroup",
  "CreateColor", -- Compat.FadeHorizontal: the colours of the This character card's class art fade (d530)
}

-- Compat.APIS names Compat reads only when the client has them; a missing one loses a detail, nothing breaks.
-- /gsync selftest reports them inside Core's PASS ("optional missing: ..."), never as a FAIL.
Compat.OPTIONAL = {
  ["C_Timer.After"] = true,                            -- Compat.After: false without it, Core runs its own timers
  ["C_GuildBank.IsGuildBankEnabled"] = true,           -- Compat.Flags via flag(): nil when the client lacks it
  ["C_TradeSkillUI.IsGuildTradeSkillsEnabled"] = true, -- Compat.Flags via flag()
  ["C_DamageMeter.IsDamageMeterAvailable"] = true,     -- Compat.Flags via flag()
  ["C_GameRules.IsHardcoreActive"] = true,             -- Compat.Flags via flag()
  ["C_ClassColor.GetClassColor"] = true,               -- Compat.ClassColor: falls back to RAID_CLASS_COLORS
  ["C_Texture.GetAtlasInfo"] = true,                   -- Kit.Atlas: the fallback file or colour without it
  ["C_XMLUtil.GetTemplateInfo"] = true,                -- Kit.HasTemplate: the classic frame and plain panels without it
  ["ChatFrameUtil.SendTell"] = true,                   -- Compat.OpenWhisper: the deprecated alias, else the /w line
  ["ChatFrameUtil.InsertLink"] = true,                 -- Compat.OpenWhisper: same
  -- Options and popup: without them settings stay in GuildSync's own window, the confirm in Kit.Dialog
  ["Settings.RegisterVerticalLayoutCategory"] = true, ["Settings.RegisterVerticalLayoutSubcategory"] = true,
  ["Settings.RegisterAddOnCategory"] = true, ["Settings.RegisterProxySetting"] = true,
  ["Settings.CreateCheckbox"] = true, ["Settings.CreateDropdown"] = true, ["Settings.CreateControlTextContainer"] = true,
  ["CreateSettingsButtonInitializer"] = true, ["Settings.RegisterCanvasLayoutCategory"] = true,
  ["Settings.OpenToCategory"] = true, ["StaticPopup_Show"] = true,
  -- page tabs and anchored menus: without them Kit keeps its own buttons and plain lists
  ["PanelTemplates_SelectTab"] = true, ["PanelTemplates_DeselectTab"] = true, ["PanelTemplates_TabResize"] = true,
  ["Menu.GetManager"] = true, ["Menu.PopulateDescription"] = true, ["MenuVariants.GetDefaultContextMenuMixin"] = true,
  ["MenuUtil.CreateRootMenuDescription"] = true, ["AnchorUtil.CreateAnchor"] = true,
  -- Compat.AddOn: nil without DoesAddOnExist, a missing detail without the others
  ["C_AddOns.GetAddOnMetadata"] = true, ["C_AddOns.GetAddOnInfo"] = true,
  ["C_AddOns.IsAddOnLoaded"] = true, ["C_AddOns.DoesAddOnExist"] = true,
  -- Kit.SetItem: each missing one is skipped, the others still run; SetItem answers false
  ["SetItemButtonTexture"] = true, ["SetItemButtonQuality"] = true, ["SetItemButtonCount"] = true,
  ["CreateColor"] = true, -- Compat.FadeHorizontal: SetGradientAlpha, else the fading class art hidden
}

-- Names Compat does not call, recorded by the probe only, because they would be useful fallbacks if present.
Compat.WATCH = {
  "GetGuildRosterInfo", "GetGuildRosterLastOnline", "C_TradeSkillUI.GetAllRecipeIDs", "C_Club.AreMembersReady",
  -- Blizzard's guild roster asks these; not in the 1.60.1 API documentation, so only probed (officer actions, 0.9)
  "CanGuildPromote", "CanGuildDemote", "CanGuildRemove", "CanEditPublicNote",
}

-- Non-function globals and enums Compat reads. Also recorded by the probe.
Compat.VALUES = {
  "Enum.AddOnRestrictionType.Encounter", "Enum.ClubMemberPresence.Online", "UIParent",
  "Minimap", "GameTooltip", "UISpecialFrames", "AddonCompartmentFrame", "RAID_CLASS_COLORS",
  "ChatFrameUtil", "ChatFrame_SendTell", "ChatEdit_InsertLink", -- Compat.OpenWhisper
  -- Compat.ScrollList and Compat.MenuUtil hand these back to Kit (read, never called here)
  "CreateScrollBoxListLinearView", "CreateDataProvider", "ScrollUtil", "MenuUtil",
  "StaticPopupDialogs", -- Compat.Popup
}

local listed = {}
for _, name in ipairs(Compat.APIS) do listed[name] = true end

local function resolve(path)
  local obj = _G
  for part in string.gmatch(path, "[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
    if obj == nil then return nil end
  end
  return obj
end

local function pack(...) return { n = select("#", ...), ... } end

-- Calls a Blizzard function by dotted name. Returns nothing when it is missing or when it throws.
local function call(path, ...)
  if not listed[path] then return nil end
  local fn = resolve(path)
  if type(fn) ~= "function" then return nil end
  local r = pack(pcall(fn, ...))
  if not r[1] then return nil end
  return unpack(r, 2, r.n)
end

local function has(path) return type(resolve(path)) == "function" end

-- A value read while a restriction is active can be "secret": it errors on comparison, arithmetic and
-- string operations. plain() turns a secret into nil so the rest of the addon never sees one.
-- The secret test comes before anything else touches v: even "v == nil" is a comparison.
local function plain(v)
  local fn = resolve("issecretvalue")
  if type(fn) == "function" then
    local ok, secret = pcall(fn, v)
    if ok and secret then return nil end
  end
  return v
end
Compat.Plain = plain

local function isSecret(v)
  local fn = resolve("issecretvalue")
  if type(fn) ~= "function" then return false end
  local ok, secret = pcall(fn, v)
  return ok and secret and true or false
end

local function str(v)
  v = plain(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function num(v)
  v = plain(v)
  if type(v) == "number" then return v end
  return nil
end

function Compat.Has(path) return has(path) end

-- ---------- installed addons (the Modules page) ----------

local ADDON_TEXT_MAX = 1024 -- a TOC string longer than this is dropped, not cut

local function addonText(v)
  v = str(v)
  if v and #v <= ADDON_TEXT_MAX then return v end
  return nil
end

-- What the client says about an addon folder: { exists, loaded, version, reason }, or nil when the client has
-- no C_AddOns.DoesAddOnExist. Strings are raw (secrets become nil, over-long ones nil); escaping is the caller's job.
-- reason is GetAddOnInfo's (e.g. "DISABLED", "DEP_MISSING", "MISSING"); "disabled" is exists and not loaded.
function Compat.AddOn(folder)
  if type(folder) ~= "string" or not has("C_AddOns.DoesAddOnExist") then return nil end
  local out = { exists = plain(call("C_AddOns.DoesAddOnExist", folder)) == true }
  out.loaded = plain(call("C_AddOns.IsAddOnLoaded", folder)) == true
  out.reason = addonText(select(5, call("C_AddOns.GetAddOnInfo", folder)))
  if out.exists then
    local v = addonText(call("C_AddOns.GetAddOnMetadata", folder, "Version"))
    if v then out.version = Compat.ReleaseVersion(v) end
  end
  return out
end

-- ---------- module addons' client calls (Api.lua: M.Compat.call / Try) ----------
-- Client calls that act on another player (guild actions, invites, whispers, group, friends and ignore). While
-- /gsync demo is on, TryIn and the officer actions refuse them at call time whatever the arguments (a unit token or a
-- roster index names nobody), so nothing acts on a made-up member; outside demo they are unchanged.
-- The group and friend names are the Forever 1.60.1 dataset's (C_PartyInfo, C_FriendList); the classic globals of the
-- same group calls are listed too.
Compat.ACT_NAMES = {
  ["C_GuildInfo.Promote"] = true, ["C_GuildInfo.Demote"] = true, ["C_GuildInfo.RemoveFromGuild"] = true,
  ["C_GuildInfo.SetNote"] = true, ["C_GuildInfo.Invite"] = true, GuildInvite = true, InviteUnit = true,
  ["C_PartyInfo.InviteUnit"] = true, SendChatMessage = true, ["C_ChatInfo.SendChatMessage"] = true,
  ["ChatFrameUtil.SendTell"] = true, ChatFrame_SendTell = true,
  UninviteUnit = true, PromoteToLeader = true, PromoteToAssistant = true, ["C_PartyInfo.UninviteUnit"] = true,
  ["C_PartyInfo.PromoteToLeader"] = true, ["C_PartyInfo.PromoteToAssistant"] = true,
  ["C_PartyInfo.ConfirmInviteUnit"] = true, ["C_PartyInfo.RequestInviteFromUnit"] = true,
  ["C_FriendList.AddFriend"] = true, ["C_FriendList.RemoveFriend"] = true, ["C_FriendList.AddIgnore"] = true,
  ["C_FriendList.DelIgnore"] = true,
}

-- A module's own allow list, built from its apis. It never touches `listed`, so it widens neither the hub's call()
-- nor another module's list.
function Compat.CallList(names)
  local list = {}
  for _, name in ipairs(type(names) == "table" and names or {}) do
    if type(name) == "string" then list[name] = true end
  end
  return list
end

-- ok, then every return value plain (a secret becomes nil). ok false: not in list, missing, or it threw.
function Compat.TryIn(list, path, ...)
  if type(list) ~= "table" or not list[path] then return false end
  -- demo: no listed action, and no call of any kind that names a demo member (f1351)
  if ns.Demo and ns.Demo.On() and (Compat.ACT_NAMES[path] or ns.Demo.Mentions(...)) then return false end
  local fn = resolve(path)
  if type(fn) ~= "function" then return false end
  local r = pack(pcall(fn, ...))
  if not r[1] then return false end
  for i = 2, r.n do r[i] = plain(r[i]) end
  return true, unpack(r, 2, r.n)
end

-- TryIn's values, or nothing.
function Compat.CallIn(list, path, ...)
  local r = pack(Compat.TryIn(list, path, ...))
  if not r[1] then return end
  return unpack(r, 2, r.n)
end

-- { ["C_X.Fn"] = true|false } for every function Compat depends on, plus the watch list and the values.
function Compat.ApiPresence()
  local out = {}
  for _, name in ipairs(Compat.APIS) do out[name] = has(name) end
  for _, name in ipairs(Compat.WATCH) do out[name] = has(name) end
  for _, name in ipairs(Compat.VALUES) do out[name] = resolve(name) ~= nil end
  return out
end

-- ---------- client, time, restrictions ----------

-- version "1.60.1", build "69893", date, interface number
function Compat.BuildInfo()
  local version, build, date, interface = call("GetBuildInfo")
  return str(version), str(build), str(date), num(interface)
end

function Compat.ServerTime()
  return num(call("GetServerTime")) or time()
end

-- Returns false when the client has no timer API, so Core can fall back to its own.
function Compat.After(seconds, fn)
  if not has("C_Timer.After") then return false end
  local ok = pcall(resolve("C_Timer.After"), seconds, fn)
  return ok and true or false
end

-- True while data the addon reads may be secret: the Encounter restriction, or the chat messaging lockdown
-- (club member info and chat text are secret during the latter).
function Compat.EncounterRestricted()
  local kind = resolve("Enum.AddOnRestrictionType.Encounter")
  if kind ~= nil then
    local active = plain(call("C_RestrictedActions.IsAddOnRestrictionActive", kind))
    if active == true then return true end
  end
  local lockdown = plain(call("C_ChatInfo.InChatMessagingLockdown"))
  if lockdown == true then return true end
  return false
end

-- { Combat = 0|1|2, Encounter = ..., ... } (0 inactive, 1 activating, 2 active), or nil without the API.
function Compat.RestrictionStates()
  local kinds = resolve("Enum.AddOnRestrictionType")
  if type(kinds) ~= "table" or not has("C_RestrictedActions.GetAddOnRestrictionState") then return nil end
  local out = {}
  for name, value in pairs(kinds) do
    if type(name) == "string" then
      local state = num(call("C_RestrictedActions.GetAddOnRestrictionState", value))
      if state ~= nil then out[name] = state end
    end
  end
  return out
end

local function flag(path)
  if not has(path) then return nil end
  local v = plain(call(path))
  if v == nil then return nil end
  return v and true or false
end

function Compat.Flags()
  return {
    guildBank = flag("C_GuildBank.IsGuildBankEnabled"),
    guildTradeSkills = flag("C_TradeSkillUI.IsGuildTradeSkillsEnabled"),
    damageMeter = flag("C_DamageMeter.IsDamageMeterAvailable"),
    hardcore = flag("C_GameRules.IsHardcoreActive"),
  }
end

-- ---------- player ----------

-- { name, realm, guid, class, level, gold }. Any field can be nil.
function Compat.Player()
  local p = {}
  p.name = str((call("UnitName", "player")))
  p.realm = str((call("GetRealmName")))
  p.guid = str((call("UnitGUID", "player")))
  local _, classToken = call("UnitClass", "player")
  p.class = str(classToken)
  p.level = num((call("UnitLevel", "player")))
  p.gold = num((call("GetMoney")))
  return p
end

-- The player's faction: "Horde" or "Alliance"; nil for anything else, a throw or no UnitFactionGroup.
function Compat.Faction()
  local faction = str((call("UnitFactionGroup", "player")))
  if faction == "Horde" or faction == "Alliance" then return faction end
  return nil
end

function Compat.IsInGuild()
  return plain(call("IsInGuild")) == true
end

-- guild name, guild realm (nil when it is the player's own realm)
function Compat.GuildInfo()
  local name, _, _, realm = call("GetGuildInfo", "player")
  return str(name), str(realm)
end

-- "Name-Realm" -> "Name". The one place a realm suffix is stripped, so roster members and guild log names
-- agree. nil for anything that is not a string.
function Compat.ShortName(name)
  if type(name) ~= "string" then return nil end
  return string.match(name, "^([^-]+)") or name
end

-- ---------- professions ----------

-- True only when the open trade skill window shows the player's own, ready profession.
function Compat.TradeSkillIsOwn()
  if not has("C_TradeSkillUI.GetBaseProfessionInfo") or not has("C_TradeSkillUI.GetFilteredRecipeIDs") then return false end
  if has("C_TradeSkillUI.IsTradeSkillReady") and plain(call("C_TradeSkillUI.IsTradeSkillReady")) ~= true then return false end
  if plain(call("C_TradeSkillUI.IsDataSourceChanging")) == true then return false end
  -- never record somebody else's recipes: linked, guild and guild-member views, NPC crafting, runeforging
  local views = { "C_TradeSkillUI.IsTradeSkillLinked", "C_TradeSkillUI.IsTradeSkillGuild", "C_TradeSkillUI.IsTradeSkillGuildMember",
    "C_TradeSkillUI.IsNPCCrafting", "C_TradeSkillUI.IsRuneforging" }
  for _, path in ipairs(views) do
    if plain((call(path))) == true then return false end
  end
  return true
end

local function professionTable(info)
  info = plain(info)
  if type(info) ~= "table" then return nil end
  local id = num(info.professionID)
  if not id or id == 0 then return nil end
  local parent = num(info.parentProfessionID)
  return {
    id = id, name = str(info.professionName), rank = num(info.skillLevel) or 0, max = num(info.maxSkillLevel) or 0,
    parentID = (parent and parent ~= 0) and parent or nil, parentName = str(info.parentProfessionName),
  }
end

-- The open window's base profession: { id, name, rank, max }. When the base line carries no rank
-- (retail keeps ranks on the child lines), the currently shown child line's rank is used.
function Compat.TradeSkillBase()
  local base = professionTable(call("C_TradeSkillUI.GetBaseProfessionInfo"))
  if not base then return nil end
  if base.max == 0 then
    local child = professionTable(call("C_TradeSkillUI.GetChildProfessionInfo"))
    if child and child.max > 0 then base.rank, base.max = child.rank, child.max end
  end
  return { id = base.id, name = base.name, rank = base.rank, max = base.max }
end

function Compat.TradeSkillRecipeIDs()
  local ids = plain(call("C_TradeSkillUI.GetFilteredRecipeIDs"))
  if type(ids) ~= "table" then return nil end
  return ids
end

-- learned (bool), recipeID as the client reports it
function Compat.RecipeLearned(recipeID)
  local info = plain(call("C_TradeSkillUI.GetRecipeInfo", recipeID))
  if type(info) ~= "table" then return false, nil end
  return plain(info.learned) == true, num(info.recipeID)
end

-- Recipe name, for recipes that make no item (enchants).
function Compat.RecipeName(recipeID)
  local info = plain(call("C_TradeSkillUI.GetRecipeInfo", recipeID))
  if type(info) ~= "table" then return nil end
  local name = plain(info.name)
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

-- Output item id, or nil for recipes that make no item (enchants).
function Compat.RecipeOutput(recipeID)
  local schematic = plain(call("C_TradeSkillUI.GetRecipeSchematic", recipeID, false))
  if type(schematic) ~= "table" then return nil end
  local id = num(schematic.outputItemID)
  if id and id > 0 then return id end
  return nil
end

-- Base profession of a recipe, without the window: { id, name }
function Compat.RecipeProfession(recipeID)
  local p = professionTable(call("C_TradeSkillUI.GetProfessionInfoByRecipeID", recipeID))
  if not p then return nil end
  if p.parentID then return { id = p.parentID, name = p.parentName or p.name } end
  return { id = p.id, name = p.name }
end

-- Professions the character has, from the spellbook side: { { id = skillLine, name, rank, max }, ... }
function Compat.KnownProfessions()
  if not has("GetProfessions") or not has("GetProfessionInfo") then return nil end
  local r = pack(call("GetProfessions"))
  local out = {}
  for i = 1, r.n do
    local index = num(r[i])
    if index then
      local name, _, rank, maxRank, _, _, skillLine = call("GetProfessionInfo", index)
      skillLine = num(skillLine)
      if skillLine and skillLine ~= 0 then
        table.insert(out, { id = skillLine, name = str(name), rank = num(rank) or 0, max = num(maxRank) or 0 })
      end
    end
  end
  return out
end

-- ---------- guild roster ----------

function Compat.RequestGuildRoster() call("C_GuildInfo.GuildRoster") end

function Compat.CanViewOfficerNote()
  return plain(call("C_GuildInfo.CanViewOfficerNote")) == true
end

-- { "Guild Master", "Officer", ... }, or nil without the API
function Compat.GuildRanks()
  local n = num((call("GuildControlGetNumRanks")))
  if not n or n <= 0 or not has("GuildControlGetRankName") then return nil end
  local out = {}
  for i = 1, n do
    out[i] = str((call("GuildControlGetRankName", i))) or ("Rank " .. i)
  end
  return out
end

local classTokens = {}
local function classToken(classID)
  if not classID then return nil end
  if classTokens[classID] == nil then
    local info = plain(call("C_CreatureInfo.GetClassInfo", classID))
    classTokens[classID] = (type(info) == "table" and str(info.classFile)) or false
  end
  return classTokens[classID] or nil
end

local function isOnline(presence)
  if presence == nil then return false end
  local e = resolve("Enum.ClubMemberPresence")
  if type(e) == "table" then
    return presence == e.Online or presence == e.Away or presence == e.Busy
  end
  return presence == 1 or presence == 4 or presence == 5
end

-- Guild members from the guild's club member list:
--   { [guid] = { name, rank, rankIndex, level, class, zone, online, lastOnlineDays, note, officerNote, prof1, prof2 } }, count
-- rankIndex is zero-based (Guild Master = 0), as in GuildSync 0.2.
-- Returns nil, reason when the club API is missing, not initialised yet, or returned secrets.
-- The member list is focused before the first read of a club, the way Blizzard's guild pane does when a club is
-- selected (CommunitiesMemberList.lua OnClubSelected: C_Club.FocusMembers, then read). focus = true asks again.
-- The guild pane never unfocuses (only the chat channel frame calls UnfocusMembers), so neither does this.
local focusedClub = nil
function Compat.GuildMembers(withOfficerNotes, focus)
  if not has("C_Club.GetGuildClubId") or not has("C_Club.GetClubMembers") or not has("C_Club.GetMemberInfo") then
    return nil, "no club API"
  end
  local clubId = plain(call("C_Club.GetGuildClubId"))
  if clubId == nil then return nil, "guild club not loaded yet" end
  if focus or focusedClub ~= clubId then
    call("C_Club.FocusMembers", clubId)
    focusedClub = clubId
  end
  local ids = plain(call("C_Club.GetClubMembers", clubId))
  if type(ids) ~= "table" then return nil, "no member list" end
  local members, count = {}, 0
  for _, memberId in ipairs(ids) do
    local info = plain(call("C_Club.GetMemberInfo", clubId, memberId))
    if type(info) == "table" then
      local guid, name = str(info.guid), str(info.name)
      if guid and name then
        local presence = plain(info.presence)
        local online = isOnline(presence)
        local days
        local y, m, d, h = num(info.lastOnlineYear), num(info.lastOnlineMonth), num(info.lastOnlineDay), num(info.lastOnlineHour)
        if online then
          days = 0
        elseif y or m or d or h then
          days = (y or 0) * 365 + (m or 0) * 30 + (d or 0) + (((h or 0) >= 12) and 1 or 0)
        end
        local order = num(info.guildRankOrder)
        local member = {
          name = Compat.ShortName(name),
          rank = str(info.guildRank), rankIndex = order and (order - 1) or nil,
          level = num(info.level), class = classToken(num(info.classID)), zone = str(info.zone),
          online = online, lastOnlineDays = days,
          note = str(info.memberNote),
        }
        if withOfficerNotes then member.officerNote = str(info.officerNote) end
        local p1, p2 = num(info.profession1ID), num(info.profession2ID)
        if p1 and p1 ~= 0 then member.prof1 = { id = p1, name = str(info.profession1Name), rank = num(info.profession1Rank) } end
        if p2 and p2 ~= 0 then member.prof2 = { id = p2, name = str(info.profession2Name), rank = num(info.profession2Rank) } end
        members[guid] = member
        count = count + 1
      end
    end
  end
  if count == 0 then return nil, "member list empty" end
  return members, count
end

-- ---------- officer actions (0.9) ----------
-- C_GuildInfo.GuildControlGetRankFlags(rankOrder) answers a "permissions" table; the 1.60.1 documentation does not
-- describe its fields. These positions are the order the classic GuildControlGetRankFlags returned its flags in
-- (and the guild control panel's check boxes): 5 promote, 6 demote, 8 remove, 10 edit public note, 12 edit officer
-- note. A table without numbered entries counts as unreadable: nothing is allowed then, except to the guild leader.
Compat.RANK_FLAGS = { promote = 5, demote = 6, remove = 8, editPublic = 10, editOfficer = 12 }

-- The officer rule (run r-20261014-r8): a rank is an officer rank when it may listen to officer chat. The probe's Q4
-- labels put "Officerchat Listen" at GUILDCONTROL_OPTION3, so flag 3 is assumed when no label holds it. The send gate
-- also needs "Officerchat Speak" (the server checks it on a send), found by its label the same way, flag 4 assumed
-- when no label holds it (fix round 1, f4354).
Compat.OFFICER_CHAT_FLAG = 3
Compat.OFFICER_SPEAK_FLAG = 4
local OFFICER_LABEL = "Officerchat Listen"
local SPEAK_LABEL = "Officerchat Speak"
local officerIndex, officerConfirmed, speakIndex -- scanned once per session

local function officerFlagIndex()
  if officerIndex == nil then
    officerIndex, officerConfirmed, speakIndex = Compat.OFFICER_CHAT_FLAG, false, Compat.OFFICER_SPEAK_FLAG
    local speakFound = false
    for i = 1, 21 do
      local label = plain(resolve("GUILDCONTROL_OPTION" .. i))
      if not officerConfirmed and label == OFFICER_LABEL then officerIndex, officerConfirmed = i, true end
      if not speakFound and label == SPEAK_LABEL then speakIndex, speakFound = i, true end
    end
  end
  return officerIndex, officerConfirmed
end

-- ranks, how, why, index, confirmed. ranks = { [rankIndex] = true } | nil; how "flags" | "fallback" | "unknown";
-- why nil | "not ready" | "unreadable" | "secret" | "missing" | "empty" | "partial". maxRankIndex: the highest
-- rankIndex on the roster. Rank 0 always counts under "flags"; "fallback" is ranks 0-2. "unreadable" also covers a
-- flags table with numbered keys but nothing at the flag's index. speak (6th value, fix round 1 f4354) is the same
-- kind of map for Officerchat Speak: rank 0 and the ranks whose Speak flag reads on; under "fallback" ranks 0-2.
function Compat.OfficerRanks(maxRankIndex)
  local index, confirmed = officerFlagIndex()
  local function fallback(why)
    return { [0] = true, [1] = true, [2] = true }, "fallback", why, index, confirmed, { [0] = true, [1] = true, [2] = true }
  end
  local raw = call("GuildControlGetNumRanks")
  if isSecret(raw) then return fallback("secret") end
  local n = plain(raw)
  if type(n) ~= "number" then return fallback("unreadable") end
  if n < 1 then return nil, "unknown", "not ready", index, confirmed end
  if not has("C_GuildInfo.GuildControlGetRankFlags") then return fallback("missing") end
  local ranks, speak, readable, bad = { [0] = true }, { [0] = true }, 0, nil
  for order = 1, n do
    local flags, why = plain(call("C_GuildInfo.GuildControlGetRankFlags", order)), nil
    if type(flags) ~= "table" then
      why = "unreadable"
    else
      local any = false
      for i = 1, 32 do if isSecret(flags[i]) or flags[i] ~= nil then any = true break end end
      local v = plain(flags[index])
      if not any then why = "empty"
      elseif v == true or v == 1 then ranks[order - 1] = true
      elseif isSecret(flags[index]) then why = "secret"
      elseif v == nil then why = "unreadable"
      elseif v ~= false and v ~= 0 then why = "secret" end
      local s = plain(flags[speakIndex])
      if not why and (s == true or s == 1) then speak[order - 1] = true end
    end
    if why then bad = bad or why else readable = readable + 1 end
  end
  if bad then return fallback(readable > 0 and "partial" or bad) end
  if type(maxRankIndex) == "number" and n < maxRankIndex + 1 then return fallback("partial") end
  return ranks, "flags", nil, index, confirmed, speak
end

local function flagOn(flags, i)
  local v = plain(flags[i])
  return v == true or v == 1
end

-- What this character may do in its guild: { guid, rankIndex (0-based), leader, flagsRead, promote, demote, remove,
-- editPublic, editOfficer }, or nil out of a guild.
function Compat.GuildPermissions()
  if not Compat.IsInGuild() then return nil end
  local _, _, rankIndex = call("GetGuildInfo", "player")
  rankIndex = num(rankIndex)
  local me = { guid = str((call("UnitGUID", "player"))), rankIndex = rankIndex,
    leader = plain(call("IsGuildLeader")) == true, flagsRead = false }
  local flags = rankIndex and plain(call("C_GuildInfo.GuildControlGetRankFlags", rankIndex + 1)) or nil
  if type(flags) == "table" then
    for i = 1, 13 do if plain(flags[i]) ~= nil then me.flagsRead = true end end
  end
  for key, i in pairs(Compat.RANK_FLAGS) do
    me[key] = me.leader or (me.flagsRead and flagOn(flags, i)) or false
  end
  if has("C_GuildInfo.CanEditOfficerNote") then
    me.editOfficer = me.leader or plain(call("C_GuildInfo.CanEditOfficerNote")) == true
  end
  return me
end

-- One client call each, made from a click. True when the function exists and did not throw (the game's answer comes
-- later, as a roster update or a system message).
local function act(path, ...)
  if not listed[path] then return false end
  if ns.Demo and ns.Demo.On() and (Compat.ACT_NAMES[path] or ns.Demo.Mentions(...)) then return false end -- demo
  local fn = resolve(path)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...) and true or false
end

-- A member's rank as the client knows it now, 0-based (Guild Master = 0), or nil when it cannot be read.
function Compat.GuildRankIndex(guid)
  if type(guid) ~= "string" then return nil end
  local order = num((call("C_GuildInfo.GetGuildRankOrder", guid)))
  return order and (order - 1) or nil
end

-- A member's name with realm as the client gives it now ("Name" on the home realm, "Name-Realm" otherwise), for
-- Promote and Demote, which take a name. Nil when the client has nothing for that GUID.
function Compat.FullName(guid)
  if type(guid) ~= "string" then return nil end
  local _, _, _, _, _, name, realm = call("GetPlayerInfoByGUID", guid)
  name, realm = str(name), str(realm)
  if not name then return nil end
  if realm and not string.find(name, "-", 1, true) then return name .. "-" .. realm end
  return name
end

function Compat.GuildPromote(name) return act("C_GuildInfo.Promote", name) end
function Compat.GuildDemote(name) return act("C_GuildInfo.Demote", name) end
function Compat.GuildRemove(guid) return act("C_GuildInfo.RemoveFromGuild", guid) end
function Compat.GuildSetNote(guid, note, isPublic) return act("C_GuildInfo.SetNote", guid, note, isPublic and true or false) end

-- Total number of guild members the guild roster knows about, or nil. 0 until the roster has been requested.
function Compat.GuildMemberTotal()
  return num((call("GetNumGuildMembers")))
end

function Compat.RequestGuildEventLog() call("QueryGuildEventLog") end

-- Raw native guild log, oldest first: { { type, player1, player2, rank, year, month, day, hour }, ... }
-- player1/player2 are as the client gives them, possibly "Name-Realm": Roster strips them with Compat.ShortName.
-- year/month/day/hour are the entry's AGE, as Blizzard's guild log pane reads them.
function Compat.GuildEvents()
  if not has("GetNumGuildEvents") or not has("GetGuildEventInfo") then return nil end
  local n = num((call("GetNumGuildEvents")))
  if not n then return nil end
  local out = {}
  for i = 1, n do
    local kind, p1, p2, rank, y, m, d, h = call("GetGuildEventInfo", i)
    kind = str(kind)
    if kind then
      table.insert(out, { type = kind, player1 = str(p1), player2 = str(p2), rank = str(rank),
        year = num(y) or 0, month = num(m) or 0, day = num(d) or 0, hour = num(h) or 0 })
    end
  end
  return out
end

function Compat.InCombat()
  return plain(call("InCombatLockdown")) == true
end

-- ---------- addon messages (the comm core, CommQueue.lua) ----------
-- The only send path for addon messages; modules ask CommGate through the public API.
-- A module addon's apis may not name either of these (Api.lua refuses it).
Compat.SEND_NAMES = { "SendAddonMessage", "RegisterAddonMessagePrefix" }
-- Nor these: they run code GuildSync cannot check (a demo name could be built inside the script). Matched without case.
Compat.SCRIPT_NAMES = { "RunScript", "loadstring", "dostring" }

-- true when a gate answer says "closed": true, or a secret (unknown is treated as closed)
local function closed(v)
  if isSecret(v) then return true end
  return v == true
end

-- ok, why. why: "guild" | "time" | "roster not known" | "combat" | "lockdown" | "restricted (<kind>)".
-- Every Enum.AddOnRestrictionType kind must be inactive (state 0); activating (1) closes the gate too.
function Compat.CommGate(rosterKnown)
  if plain(call("IsInGuild")) ~= true then return false, "guild" end
  local t = num(call("GetServerTime"))
  if not t or t <= 0 then return false, "time" end
  if not rosterKnown then return false, "roster not known" end
  if closed(call("InCombatLockdown")) then return false, "combat" end
  if closed(call("C_ChatInfo.InChatMessagingLockdown")) then return false, "lockdown" end
  local kinds = resolve("Enum.AddOnRestrictionType")
  if type(kinds) == "table" and has("C_RestrictedActions.GetAddOnRestrictionState") then
    for kind, value in pairs(kinds) do
      if type(kind) == "string" then
        local state = call("C_RestrictedActions.GetAddOnRestrictionState", value)
        if isSecret(state) or (type(state) == "number" and state ~= 0) then
          return false, "restricted (" .. kind .. ")"
        end
      end
    end
  end
  return true
end

-- The raw result of registering an addon message prefix (0/1/true on, 2/3 refused), or nil without the API.
function Compat.RegisterAddonPrefix(prefix)
  return plain(call("C_ChatInfo.RegisterAddonMessagePrefix", prefix))
end

-- Sends one text. Plain values first: a secret prefix, text or channel is never passed on and answers nil
-- (not sent). Returns the raw result (a number on Forever), or nil without the API.
function Compat.SendAddon(prefix, text, channel)
  prefix, text, channel = plain(prefix), plain(text), plain(channel)
  if type(prefix) ~= "string" or type(text) ~= "string" or type(channel) ~= "string" then return nil end
  return plain(call("C_ChatInfo.SendAddonMessage", prefix, text, channel))
end

-- ---------- chat box (GuildSync.OpenWhisper; moved from CraftCompat.lua) ----------

-- the first of the names that resolves to a function
local function helper(primary, alias)
  local fn = resolve(primary)
  if type(fn) == "function" then return fn end
  fn = resolve(alias)
  if type(fn) == "function" then return fn end
  return nil
end

-- Opens a tell to name with text (a link or words) in the box; sends nothing. "tell" when done, "fallback" when the
-- helpers are missing (the caller then prints the /w line).
function Compat.OpenWhisper(name, text)
  if type(name) ~= "string" or name == "" then return "fallback" end
  local tell = helper("ChatFrame_SendTell", "ChatFrameUtil.SendTell")
  local insert = helper("ChatEdit_InsertLink", "ChatFrameUtil.InsertLink")
  if not tell or (text and not insert) then return "fallback" end
  if not pcall(tell, name) then return "fallback" end
  if text then pcall(insert, text) end
  return "tell"
end

-- ---------- window and minimap button (Window.lua) ----------
-- Window.lua builds its frames from these and only calls methods on what they return.

-- A frame, or nil when the client cannot make one. parent nil = UIParent.
function Compat.CreateFrame(kind, name, parent, template)
  return call("CreateFrame", kind, name, parent or resolve("UIParent"), template)
end

function Compat.Minimap()
  local m = resolve("Minimap")
  if type(m) == "table" then return m end
  return nil
end

function Compat.Tooltip()
  local t = resolve("GameTooltip")
  if type(t) == "table" then return t end
  return nil
end

-- Cursor position in screen pixels (divide by a frame's effective scale), or nil.
function Compat.CursorPosition()
  local x, y = call("GetCursorPosition")
  return num(x), num(y)
end

-- r, g, b of a class token ("WARRIOR"), or nil. C_ClassColor.GetClassColor first (a colour object with r, g, b),
-- then the RAID_CLASS_COLORS table.
function Compat.ClassColor(token)
  if type(token) ~= "string" then return nil end
  local c = plain(call("C_ClassColor.GetClassColor", token))
  if type(c) ~= "table" then
    local all = resolve("RAID_CLASS_COLORS")
    c = type(all) == "table" and plain(all[token]) or nil
  end
  if type(c) ~= "table" then return nil end
  local r, g, b = num(c.r), num(c.g), num(c.b)
  if r and g and b then return r, g, b end
  return nil
end

function Compat.UIParent()
  local p = resolve("UIParent")
  if type(p) == "table" then return p end
  return nil
end

-- Width and height of the screen in UI units (UIParent's size), or nil.
function Compat.ScreenSize()
  local p = Compat.UIParent()
  if not p or type(p.GetWidth) ~= "function" or type(p.GetHeight) ~= "function" then return nil end
  local ok, w, h = pcall(function() return p:GetWidth(), p:GetHeight() end)
  if not ok then return nil end
  w, h = num(w), num(h)
  if not w or not h or w <= 0 or h <= 0 then return nil end
  return w, h
end

-- Puts a texture file (or file id) on a texture region. A path the client refuses leaves the region hidden:
-- a missing icon shows nothing, never an error. trim cuts the border off an Interface\Icons icon.
function Compat.SetIcon(tex, path, trim)
  if type(tex) ~= "table" or type(tex.SetTexture) ~= "function" then return false end
  if path == nil then tex:Hide() return false end
  local ok, result = pcall(tex.SetTexture, tex, path)
  if not ok or result == false then tex:Hide() return false end
  if trim then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) else tex:SetTexCoord(0, 1, 0, 1) end
  tex:Show()
  return true
end

-- The table an info call gives for name, or nil.
local function infoTable(api, name)
  if type(name) ~= "string" then return nil end
  local info = plain(call(api, name))
  if type(info) == "table" then return info end
  return nil
end

-- What the client knows about a frame template (C_XMLUtil.GetTemplateInfo), or nil. Kit.HasTemplate reads it.
function Compat.TemplateInfo(name) return infoTable("C_XMLUtil.GetTemplateInfo", name) end

-- What the client knows about a texture atlas (C_Texture.GetAtlasInfo), or nil. Kit.Atlas reads it.
function Compat.AtlasInfo(name) return infoTable("C_Texture.GetAtlasInfo", name) end

-- A left-to-right alpha fade on texture, from alpha fromA to toA (white, so the texture keeps its colours): the modern
-- SetGradient with two CreateColor colours, else the older SetGradientAlpha. False when the client has neither or the
-- call throws; the caller then hides the texture.
function Compat.FadeHorizontal(tex, fromA, toA)
  if type(tex) ~= "table" then return false end
  local makeColor = listed.CreateColor and resolve("CreateColor")
  if type(makeColor) == "function" and type(tex.SetGradient) == "function" then
    local ok = pcall(function()
      tex:SetGradient("HORIZONTAL", makeColor(1, 1, 1, fromA), makeColor(1, 1, 1, toA))
    end)
    if ok then return true end
  end
  if type(tex.SetGradientAlpha) == "function" then
    return pcall(tex.SetGradientAlpha, tex, "HORIZONTAL", 1, 1, 1, fromA, 1, 1, 1, toA) and true or false
  end
  return false
end

local CLASS_FILES = { DEATHKNIGHT = "DeathKnight", DEMONHUNTER = "DemonHunter" }

-- The Interface\Icons\ClassIcon_Warrior file for a class token ("WARRIOR"). Nothing shows for an unknown class.
-- The class atlases are tried first by Kit.ClassIcon (Kit.lua), the only place that sets an atlas.
function Compat.SetClassIcon(tex, token)
  if type(tex) ~= "table" then return false end
  token = str(token)
  if not token then tex:Hide() return false end
  local file = CLASS_FILES[token] or (string.upper(string.sub(token, 1, 1)) .. string.lower(string.sub(token, 2)))
  return Compat.SetIcon(tex, "Interface\\Icons\\ClassIcon_" .. file, true)
end

-- Lets the user resize the frame with a grip, between the bounds. SetResizeBounds is the client's API for the
-- bounds (SetMinResize/SetMaxResize are gone from this client). False when the frame cannot be resized here.
function Compat.Resizable(f, minW, minH, maxW, maxH)
  if type(f) ~= "table" or type(f.SetResizable) ~= "function" or type(f.StartSizing) ~= "function" then return false end
  if not pcall(f.SetResizable, f, true) then return false end
  if type(f.SetResizeBounds) == "function" then pcall(f.SetResizeBounds, f, minW, minH, maxW, maxH) end
  return true
end

-- The ScrollBox list helpers (Blizzard_SharedXML: ScrollBoxLinearView, DataProvider, ScrollUtil), read at call time.
-- Nil unless all three are functions; Kit.List keeps today's scroll frame then.
function Compat.ScrollList()
  local linearView = resolve("CreateScrollBoxListLinearView")
  local dataProvider = resolve("CreateDataProvider")
  local initWithBar = resolve("ScrollUtil.InitScrollBoxListWithScrollBar")
  if type(linearView) ~= "function" or type(dataProvider) ~= "function" or type(initWithBar) ~= "function" then
    return nil
  end
  return { linearView = linearView, dataProvider = dataProvider, initWithBar = initWithBar }
end

-- Blizzard_Menu's MenuUtil, read at call time. Nil unless it can open a context menu.
function Compat.MenuUtil()
  local menu = resolve("MenuUtil")
  if type(menu) ~= "table" or type(menu.CreateContextMenu) ~= "function" then return nil end
  return menu
end

-- Escape closes the frame with this global name, like Blizzard's own panels.
function Compat.EscapeCloses(frameName)
  local list = resolve("UISpecialFrames")
  if type(list) ~= "table" then return end
  for _, n in ipairs(list) do if n == frameName then return end end
  table.insert(list, frameName)
end

-- Adds an entry to the AddOn compartment (the minimap's addon menu) when this client has one.
-- info = { text, icon, notCheckable, func }. Returns true when it was added.
function Compat.AddToCompartment(info)
  local cf = resolve("AddonCompartmentFrame")
  if type(cf) ~= "table" or type(cf.RegisterAddon) ~= "function" then return false end
  local ok = pcall(cf.RegisterAddon, cf, info)
  return ok and true or false
end

-- ---------- the game's Options window and StaticPopup (Window.lua, Kit.Confirm) ----------
-- Read at call time. A wrapper returns nil/false when a function is missing or a call returned nil: a silent fallback,
-- nothing recorded. A throw never raises here: it comes back as a falsy first value plus the error text, so the
-- caller's ns.Safe can record it. Method calls on what the client returns run inside the same pcall.

local VERTICAL_NEEDS = {
  "Settings.RegisterVerticalLayoutCategory", "Settings.RegisterVerticalLayoutSubcategory", "Settings.RegisterAddOnCategory",
  "Settings.RegisterProxySetting", "Settings.CreateCheckbox", "Settings.CreateDropdown",
  "Settings.CreateControlTextContainer", "CreateSettingsButtonInitializer",
}
local CANVAS_NEEDS = { "Settings.RegisterCanvasLayoutCategory", "Settings.RegisterAddOnCategory" }

-- "vertical" | "canvas": true only when every function that path calls is there now.
function Compat.SettingsHas(kind)
  local needs = (kind == "vertical" and VERTICAL_NEEDS) or (kind == "canvas" and CANVAS_NEEDS) or nil
  if not needs then return false end
  for _, path in ipairs(needs) do
    if not has(path) then return false end
  end
  return true
end

-- The listed client function at path, or nil.
local function fnAt(path)
  if not listed[path] then return nil end
  local fn = resolve(path)
  if type(fn) ~= "function" then return nil end
  return fn
end

-- body's first two values; nil when its first is falsy; nil plus the error text when it threw.
local function guarded(body, ...)
  local ok, a, b = pcall(body, ...)
  if not ok then return nil, tostring(a) end
  if not a then return nil end
  return a, b
end

-- The client function at path called with the arguments, through guarded.
local function callAt(path, ...)
  return guarded(function(...)
    local fn = fnAt(path)
    if fn then return fn(...) end
  end, ...)
end

-- category, layout
function Compat.OptionsCategory(name) return callAt("Settings.RegisterVerticalLayoutCategory", name) end
function Compat.OptionsSub(parent, name) return callAt("Settings.RegisterVerticalLayoutSubcategory", parent, name) end
function Compat.OptionsCanvas(frame, name) return callAt("Settings.RegisterCanvasLayoutCategory", frame, name) end

-- true once the category is in the AddOns list (the call returns nothing when it works)
function Compat.OptionsAddOn(category)
  local r, err = guarded(function()
    local fn = fnAt("Settings.RegisterAddOnCategory")
    if not fn then return nil end
    fn(category)
    return true
  end)
  return r and true or false, err
end

function Compat.OptionsProxy(category, variable, varType, name, default, get, set)
  return callAt("Settings.RegisterProxySetting", category, variable, varType, name, default, get, set)
end

function Compat.OptionsCheckbox(category, setting, tooltip)
  return callAt("Settings.CreateCheckbox", category, setting, tooltip)
end

-- values = { { value, label }, ... }, or a function returning that list, asked each time the game shows the options
function Compat.OptionsDropdown(category, setting, values, tooltip)
  return guarded(function()
    local box, create = fnAt("Settings.CreateControlTextContainer"), fnAt("Settings.CreateDropdown")
    if not box or not create then return nil end
    local function build(list)
      local container = box()
      if not container then return nil end
      for _, v in ipairs(type(list) == "table" and list or {}) do container:Add(v[1], v[2]) end
      return container:GetData()
    end
    if type(values) == "function" then
      return create(category, setting, function() return build(values()) or {} end, tooltip) -- f4523
    end
    local data = build(values)
    if not data then return nil end
    return create(category, setting, function() return data end, tooltip)
  end)
end

-- A button row on a vertical layout (addSearchTags true).
function Compat.OptionsButton(layout, name, buttonText, onClick, tooltip)
  return guarded(function()
    local fn = fnAt("CreateSettingsButtonInitializer")
    if not fn or type(layout) ~= "table" or type(layout.AddInitializer) ~= "function" then return nil end
    local init = fn(name, buttonText, onClick, tooltip, true)
    if not init then return nil end
    layout:AddInitializer(init)
    return init
  end)
end

-- Opens the Options window at the category. No combat check here: the caller guards with Compat.InCombat.
function Compat.OpenOptions(category)
  local r, err = guarded(function()
    local fn = fnAt("Settings.OpenToCategory")
    if not fn or type(category) ~= "table" then return nil end
    fn(category:GetID())
    return true
  end)
  return r and true or false, err
end

-- StaticPopupDialogs[which] = def, then StaticPopup_Show(which). True only when the show returned a frame.
function Compat.Popup(which, def)
  local dialogs, show = resolve("StaticPopupDialogs"), fnAt("StaticPopup_Show")
  if type(dialogs) ~= "table" or not show then return false end
  local ok = pcall(function() dialogs[which] = def end)
  if not ok then return false end
  local good, frame = pcall(show, which)
  return (good and frame ~= nil) and true or false
end

-- ---------- the game's page tabs and anchored menus (Kit.Tabs, Kit.MatchMenu) ----------
-- Same contract as the Options wrappers above: missing or nil = a silent false/nil; a throw = falsy plus the text.

-- True once the client function at path ran with the arguments.
local function ran(path, ...)
  local r, err = guarded(function(...)
    local fn = fnAt(path)
    if not fn then return nil end
    fn(...)
    return true
  end, ...)
  return r and true or false, err
end

-- Selects (and disables) or deselects a PanelTopTabButtonTemplate tab (SharedUIPanelTemplates.lua:598, :616).
function Compat.SelectTab(tab, on)
  return ran(on and "PanelTemplates_SelectTab" or "PanelTemplates_DeselectTab", tab)
end

-- Sizes a tab to its text (SharedUIPanelTemplates.lua:475; the absoluteSize slot stays nil).
function Compat.TabResize(tab, padding, minWidth, maxWidth)
  return ran("PanelTemplates_TabResize", tab, padding, nil, minWidth, maxWidth)
end

-- Runs the game's SetItemButton<part> (part "Texture", "Quality" or "Count") on an item button. True once it ran.
function Compat.SetItemButton(part, button, value)
  return (ran("SetItemButton" .. tostring(part), button, value))
end

-- A menu anchored to owner, built as MenuUtil.CreateContextMenu builds one (MenuUtil.lua:133-167) but opened with
-- Menu.GetManager():OpenMenu at an anchor (Menu.lua:2566-2578). generate(owner, rootDescription). Returns the menu.
function Compat.OpenMenu(owner, generate, point, relPoint, x, y)
  return guarded(function()
    local getManager, populate = fnAt("Menu.GetManager"), fnAt("Menu.PopulateDescription")
    local mixinOf, newRoot = fnAt("MenuVariants.GetDefaultContextMenuMixin"), fnAt("MenuUtil.CreateRootMenuDescription")
    local newAnchor = fnAt("AnchorUtil.CreateAnchor")
    if not (getManager and populate and mixinOf and newRoot and newAnchor) then return nil end
    local mixin = mixinOf()
    if not mixin then return nil end
    local desc = newRoot(mixin)
    if not desc then return nil end
    local anchor = newAnchor(point, owner, relPoint, x, y)
    if not anchor then return nil end
    local manager = getManager()
    if type(manager) ~= "table" or type(manager.OpenMenu) ~= "function" then return nil end
    populate(generate, owner, desc)
    local menu = manager:OpenMenu(owner, desc, anchor)
    return menu
  end)
end

-- Closes a menu OpenMenu returned. Safe with nil or a closed menu.
function Compat.CloseMenu(menu)
  if type(menu) == "table" and type(menu.Close) == "function" then pcall(menu.Close, menu) end
end
