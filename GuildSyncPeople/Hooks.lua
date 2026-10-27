-- GuildSyncPeople: the places the card shows on hover (plan Task 4, base spec items 23-26; gate A items 2-4, f13 ruling).
--   - unit tooltips: one TooltipDataProcessor post-call for Enum.TooltipDataType.Unit; without it a small frame under
--     GameTooltip on UPDATE_MOUSEOVER_UNIT, hidden with GameTooltip;
--   - guild roster rows: ScrollUtil.AddAcquiredFrameCallback on CommunitiesFrame.MemberList.ScrollBox (rows already made
--     and every later acquire) and one HookScript("OnEnter") per row, remembered in a weak-keyed table of People's own;
--     no field is ever written on a Blizzard frame, no OnLeave (Blizzard's hides the tooltip);
--   - player names in chat: EventRegistry "ChatFrame.OnHyperlinkEnter" / "ChatFrame.OnHyperlinkLeave";
--   - the guild-chat tag (items 27-29): one message filter, registered once, for CHAT_MSG_GUILD only, through
--     ChatFrameUtil.AddMessageEventFilter, else the ChatFrame_AddMessageEventFilter alias. Every path but a tag returns
--     false alone. Forever's caller (Blizzard_ChatFrameBase/Mainline/ChatFrameOverrides.lua:312-313) passes payload
--     fields 1-14 only, so discordInfo (field 18) is nil there and the fromDiscord check runs only if a later client
--     passes it (d846).
-- Every callback runs under M.Safe, every GameTooltip method under pcall, every client global is looked up when it is
-- called. A missing guard function or a nil answer reads as secret / in lockdown: nothing is shown.

local _, ns = ...
if not ns.M then return end

local GOLD_R, GOLD_G, GOLD_B = 0.94, 0.84, 0.55 -- soft gold (q312)

local unitWired, chatWired, rosterWired = false, false, false
local hookedRows = setmetatable({}, { __mode = "k" }) -- rows that carry People's OnEnter hook
local chatOwner                                      -- the chat frame People's card is owned by, while shown
local fallback                                       -- the frame under GameTooltip when there is no post-call

local events = CreateFrame("Frame")

local function plain(v) return GuildSync.Compat.Plain(v) end

local function tip(tt, method, ...)
  local fn = type(tt) == "table" and tt[method] or nil
  if type(fn) ~= "function" then return false end
  return pcall(fn, tt, ...)
end

-- True only when the hover setting is on, the secrets guard exists and the client says, plainly, that the chat
-- lockdown is off (f13 ruling: a missing guard reads as secret / in lockdown on every path).
local function open()
  if not (ns.Hover and ns.Hover()) then return false end
  if not GuildSync.Compat.Has("C_Secrets.ShouldUnitIdentityBeSecret") then return false end
  return ns.Unlocked()
end

-- In combat People shows no card of its own and adds nothing to a roster row (S-f5); a missing InCombatLockdown or
-- an answer that is not plainly false reads as in combat.
local function inCombat()
  local ok, on = ns.M.Compat.Try("InCombatLockdown")
  return not ok or on ~= false
end

-- GameTooltip is shown and owned by owner.
local function shownFor(owner)
  local tt = GameTooltip
  local ok1, shown = tip(tt, "IsShown")
  local ok2, current = tip(tt, "GetOwner")
  return ok1 and ok2 and shown and current == owner
end

-- The card's lines for a roster key (none without a record or a main/alt line, d832). The person is the hub's
-- Comm.Person even in demo: hover cards are on real players, so a real alt keeps its line (f5550).
local function linesOf(key, withHeader)
  if type(key) ~= "string" or not ns.ViewOf then return nil end
  local view = ns.ViewOf(key)
  if type(view) ~= "table" then return nil end
  -- No standing in demo: Annals answers demo keys then, and hovers are on real players (f6531).
  local demo = ns.M.Demo()
  local lines = ns.Card.Tooltip(view, ns.Now(), withHeader, ns.Person and ns.Person(key) or nil,
    not demo and ns.Standing and ns.Standing(key) or nil)
  if type(lines) ~= "table" or #lines <= (withHeader and 1 or 0) then return nil end
  return lines
end

local function addLines(tt, lines, from)
  for i = from or 1, #lines do tip(tt, "AddLine", lines[i], GOLD_R, GOLD_G, GOLD_B) end
end

-- People's own card: owned to owner, header line, the lines, shown.
local function ownCard(owner, anchor, lines)
  local tt = GameTooltip
  if not tip(tt, "SetOwner", owner, anchor) then return false end
  tip(tt, "AddLine", lines[1], 1, 1, 1)
  addLines(tt, lines, 2)
  tip(tt, "Show")
  return true
end

-- A unit token -> roster key: plain token, identity not secret, a player in my guild, a plain guid.
local function keyOfUnit(token)
  token = plain(token)
  if type(token) ~= "string" or token == "" then return nil end
  local call, Try = ns.M.Compat.call, ns.M.Compat.Try
  local ok, secret = Try("C_Secrets.ShouldUnitIdentityBeSecret", token)
  if not ok or secret ~= false then return nil end
  if call("UnitIsPlayer", token) ~= true or call("UnitIsInMyGuild", token) ~= true then return nil end
  local guid = plain(call("UnitGUID", token))
  if type(guid) ~= "string" then return nil end
  return ns.KeyOfGuid(guid)
end

-- ---------- unit tooltips (item 23) ----------

local function unitPost(tooltip, data)
  if tooltip ~= GameTooltip or not open() then return end
  local guid = type(data) == "table" and plain(data.guid) or nil
  local key
  if type(guid) == "string" then
    key = ns.KeyOfGuid(guid)
  elseif type(tooltip.GetUnit) == "function" then
    local ok, _, token = pcall(tooltip.GetUnit, tooltip)
    if ok then key = keyOfUnit(token) end
  end
  local lines = linesOf(key, false)
  if lines then addLines(tooltip, lines) end
end

local function hideFallback()
  if fallback then fallback:Hide() end
end

local function mouseover()
  if not fallback then return end
  local lines = open() and linesOf(keyOfUnit("mouseover"), false) or nil
  if not lines then return hideFallback() end
  for i, fs in ipairs(fallback.lines) do fs:SetText(lines[i] or "") end
  for i = #fallback.lines + 1, #lines do
    local fs = fallback:CreateFontString(nil, "OVERLAY", "GameTooltipText")
    fs:SetPoint("TOPLEFT", fallback, "TOPLEFT", 8, -6 - (i - 1) * 14)
    fs:SetTextColor(GOLD_R, GOLD_G, GOLD_B)
    fs:SetText(lines[i])
    fallback.lines[i] = fs
  end
  local ok, width = tip(GameTooltip, "GetWidth")
  width = plain(width) -- a secret width reads as none (S-f6)
  fallback:SetSize(ok and type(width) == "number" and width > 0 and width or 260, #lines * 14 + 12)
  fallback:Show()
end

local function buildFallback()
  local tt = GameTooltip
  if type(tt) ~= "table" or type(tt.HookScript) ~= "function" then return end
  fallback = CreateFrame("Frame", nil, UIParent)
  fallback:Hide()
  fallback:SetFrameStrata("TOOLTIP")
  fallback:SetPoint("TOPLEFT", tt, "BOTTOMLEFT", 0, -2)
  local bg = fallback:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(fallback)
  bg:SetColorTexture(0, 0, 0, 0.8)
  fallback.lines = {}
  pcall(tt.HookScript, tt, "OnHide", function() ns.M.Safe(hideFallback) end)
  events:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
end

local function wireUnit()
  local tdp, kinds = TooltipDataProcessor, Enum and Enum.TooltipDataType
  local unit = type(kinds) == "table" and kinds.Unit or nil
  if type(tdp) == "table" and type(tdp.AddTooltipPostCall) == "function" and unit ~= nil then
    unitWired = pcall(tdp.AddTooltipPostCall, unit, function(tooltip, data) ns.M.Safe(unitPost, tooltip, data) end)
  end
  if not unitWired then buildFallback() end
end

-- ---------- guild roster rows (item 24) ----------

local function rowEnter(entry)
  if not open() or inCombat() or type(entry.GetMemberInfo) ~= "function" then return end
  local info = plain(entry:GetMemberInfo())
  if type(info) ~= "table" then return end
  local guid = plain(info.guid)
  if type(guid) ~= "string" then return end
  local lines = linesOf(ns.KeyOfGuid(guid), true)
  if not lines then return end
  if shownFor(entry) then
    local tt = GameTooltip
    addLines(tt, lines, 2) -- Blizzard's tooltip already names the member
    tip(tt, "Show")
  else
    ownCard(entry, "ANCHOR_RIGHT", lines)
  end
end

local function onRowEnter(entry) ns.M.Safe(rowEnter, entry) end

local function hookRow(frame)
  if type(frame) ~= "table" or hookedRows[frame] or type(frame.HookScript) ~= "function" then return end
  hookedRows[frame] = true
  frame:HookScript("OnEnter", onRowEnter)
end

-- Two call shapes: (frame, elementData) for rows already made, (owner, frame, elementData, new) for later acquires.
local function onRow(a, b)
  if a == events then a = b end
  ns.M.Safe(hookRow, a)
end

local function wireRoster()
  if rosterWired then return end
  local cf, util = CommunitiesFrame, ScrollUtil
  local list = type(cf) == "table" and cf.MemberList or nil
  local box = type(list) == "table" and list.ScrollBox or nil
  if type(box) ~= "table" or type(util) ~= "table" or type(util.AddAcquiredFrameCallback) ~= "function" then return end
  rosterWired = pcall(util.AddAcquiredFrameCallback, box, onRow, events, true) -- a throw leaves it unwired (S-f4)
end

local function communitiesLoaded()
  return ns.M.Compat.call("C_AddOns.IsAddOnLoaded", "Blizzard_Communities") == true or type(CommunitiesFrame) == "table"
end

-- ---------- player names in chat (item 25, path a) ----------

local function chatEnter(_, chatFrame, link)
  if not open() or inCombat() then return end
  local name = ns.Card.LinkName(plain(link))
  local lines = name and linesOf(ns.Key(name), true)
  if lines and ownCard(chatFrame, "ANCHOR_CURSOR", lines) then chatOwner = chatFrame end
end

-- Hides only the card People showed (f14): still shown and still owned by the same chat frame.
local function chatLeave()
  local owner = chatOwner
  chatOwner = nil
  if owner and shownFor(owner) then tip(GameTooltip, "Hide") end
end

local function wireChat()
  local reg = EventRegistry
  if type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then return end
  local okEnter = pcall(reg.RegisterCallback, reg, "ChatFrame.OnHyperlinkEnter",
    function(...) ns.M.Safe(chatEnter, ...) end, events)
  local okLeave = pcall(reg.RegisterCallback, reg, "ChatFrame.OnHyperlinkLeave",
    function(...) ns.M.Safe(chatLeave, ...) end, events)
  chatWired = okEnter and okLeave
end

-- ---------- the guild-chat tag (items 27-29) ----------

local tagWired = false

-- ns.Card.ChatTag is looked up at call time; the person is the hub's Comm.Person, never the demo's (ns.PersonOf).
-- Cache reads only.
local function decide(text, ...)
  return ns.Card.ChatTag({
    on = ns.Tag and ns.Tag() == true,
    lockdown = function() return ns.M.Compat.Try("C_ChatInfo.InChatMessagingLockdown") end,
    plain = GuildSync.Compat.Plain,
    text = text,
    playerName = (select(1, ...)),
    guid = (select(11, ...)),
    discordInfo = (select(17, ...)),
    keyOfGuid = ns.KeyOfGuid,
    key = ns.Key,
    person = ns.Person,
    member = ns.Member,
    escape = ns.Escape,
  })
end

local function chatFilter(_, event, text, ...)
  if event ~= "CHAT_MSG_GUILD" then return false end
  local _, tag = ns.M.Safe(decide, text, ...)
  if type(tag) == "string" then return false, tag .. text, ... end
  return false
end

local function wireTag()
  if GuildSync.Compat.Has("ChatFrameUtil.AddMessageEventFilter") then
    tagWired = pcall(ChatFrameUtil.AddMessageEventFilter, "CHAT_MSG_GUILD", chatFilter)
  elseif type(ChatFrame_AddMessageEventFilter) == "function" then
    tagWired = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_GUILD", chatFilter)
  end
end

-- ---------- wiring and the selftest's list ----------

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, event, name)
  if event == "UPDATE_MOUSEOVER_UNIT" then
    ns.M.Safe(mouseover)
  elseif event == "ADDON_LOADED" and name == "Blizzard_Communities" then
    ns.M.Safe(wireRoster)
  end
end)

ns.M.Safe(wireUnit)
ns.M.Safe(wireChat)
ns.M.Safe(wireRoster)
ns.M.Safe(wireTag)

-- The hook paths not wired, in the selftest's order. The roster card counts as missing only once Blizzard_Communities
-- is loaded (it loads on demand).
function ns.HookMissing()
  local out = {}
  if not unitWired then out[#out + 1] = "unit card" end
  if not chatWired then out[#out + 1] = "chat name card" end
  if not rosterWired and communitiesLoaded() then out[#out + 1] = "roster card" end
  if not tagWired then out[#out + 1] = "chat tag" end
  return out
end

function ns.TagWired() return tagWired end
