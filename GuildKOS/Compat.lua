-- GuildKOS Compat: the only file that touches a Blizzard function (GuildSync's pattern, not a copy of its file).
-- Every client function is reached through call() by a dotted name listed in APIS, and runs under pcall.
-- plain() turns a secret value into nil, and runs before anything else touches the value (even "v == nil").
-- Names checked against the Forever dataset (addon/tools/forever-api-1.60.1.69893.json).
local _, ns = ...
local Compat = {}
ns.Compat = Compat

Compat.APIS = {
  "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", "C_ChatInfo.IsAddonMessagePrefixRegistered",
  "C_ChatInfo.InChatMessagingLockdown",
  "C_Secrets.ShouldUnitIdentityBeSecret", "issecretvalue", "canaccessvalue",
  "UnitName", "UnitIsPlayer", "UnitIsEnemy", "UnitCanAttack",
  "GetZoneText", "GetSubZoneText", "GetRealZoneText",
  "C_Sound.PlaySound", "PlaySound",
  "C_Club.GetGuildClubId", "C_Club.GetClubMembers", "C_Club.GetMemberInfo", "C_Club.GetMemberInfoForSelf",
  "C_Club.AreMembersReady", "C_Club.FocusMembers",
  "C_GuildInfo.GuildRoster", "IsInGuild",
  "C_Timer.After", "GetServerTime", "GetNormalizedRealmName",
  "GetCursorPosition", "UnitFactionGroup",
  "C_XMLUtil.GetTemplateInfo", "C_Texture.GetAtlasInfo",
}

-- Blizzard frames and tables the window and minimap button use (FrameXML, not in the API dataset); nil when absent.
Compat.FRAMES = { "Minimap", "GameTooltip", "UISpecialFrames", "AddonCompartmentFrame" }

local listed = {}
for _, name in ipairs(Compat.APIS) do listed[name] = true end
local frames = {}
for _, name in ipairs(Compat.FRAMES) do frames[name] = true end

local function resolve(path)
  local obj = _G
  for part in string.gmatch(path, "[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
    if obj == nil then return nil end
  end
  return obj
end

-- ok, ... : false for a name not in APIS, a missing function, or an error.
function Compat.call(name, ...)
  if not listed[name] then return false end
  local fn = resolve(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

-- A frame or table listed in FRAMES, or nil (not listed, absent on this client, or not a table).
function Compat.frame(name)
  if not frames[name] then return nil end
  local v = resolve(name)
  if type(v) ~= "table" then return nil end
  return v
end

-- v, or nil when v is secret.
function Compat.plain(v)
  local fn = resolve("issecretvalue")
  if type(fn) == "function" then
    local ok, secret = pcall(fn, v)
    if not ok or secret then return nil end
  end
  return v
end

function Compat.str(v)
  v = Compat.plain(v)
  if type(v) == "string" then return v end
  return nil
end

function Compat.num(v)
  v = Compat.plain(v)
  if type(v) == "number" then return v end
  return nil
end

-- The table an info call gives for name, or nil (not a string, absent API, an error, or a secret).
local function infoTable(api, name)
  if type(name) ~= "string" then return nil end
  local ok, info = Compat.call(api, name)
  if not ok then return nil end
  info = Compat.plain(info)
  if type(info) == "table" then return info end
  return nil
end

-- True when the client has this frame template.
function Compat.HasTemplate(name)
  return infoTable("C_XMLUtil.GetTemplateInfo", name) ~= nil
end

-- What the client knows about a texture atlas, or nil.
function Compat.AtlasInfo(name)
  return infoTable("C_Texture.GetAtlasInfo", name)
end

local function hasMethod(obj, name) return type(obj) == "table" and type(obj[name]) == "function" end

-- The atlas when the client has it, else the fallback: a file path (texcoords reset), { r, g, b, a } (a colour),
-- or nil (the texture hides). True only when the atlas was set.
function Compat.Atlas(tex, name, fallback)
  if type(tex) ~= "table" then return false end
  if hasMethod(tex, "SetAtlas") and Compat.AtlasInfo(name) and pcall(tex.SetAtlas, tex, name) then
    tex:Show()
    return true
  end
  if type(fallback) == "table" then
    if hasMethod(tex, "SetColorTexture") then
      pcall(tex.SetColorTexture, tex, fallback[1], fallback[2], fallback[3], fallback[4])
      tex:Show()
    end
  elseif fallback ~= nil and hasMethod(tex, "SetTexture") and pcall(tex.SetTexture, tex, fallback) then
    tex:SetTexCoord(0, 1, 0, 1)
    tex:Show()
  elseif hasMethod(tex, "Hide") then
    tex:Hide()
  end
  return false
end

return Compat
