-- GuildSyncGames Page.lua: the Games page shell (plan Task 7, Seams). One tab per ns.GAMES entry ({ key, text, build,
-- refresh }; WoWdle first) through M.Kit.Tabs, else plain buttons in the same row; one holder per entry under the
-- 32-tall row, each built once at the page's build. ns.SelectGame(key) shows that holder; ns.OpenChat fills the chat box.
-- S11: Harvest and Kodo races follow WoWdle; a tab click records the game through ns.SetLastGame (Grain.lua), and
-- ns.ShownGame() answers the chosen key while the page is on screen. ns.UI holds the widget helpers both tabs use.
-- S14 Task 7: the holders end FOOT_H 16 above the page's foot, where one grey line says how a guildmate's row arrives.
-- S22 Task 6 (o2200): the tab row is a game menu, M.Kit.Dropdown in the same 32-tall row, else plain prev and next
-- buttons around the chosen name. An entry's optional shown() is read at the build: a hidden entry gets no menu line,
-- no holder and no build. The build opens on ns.LastGame() when that game is shown, else WoWdle.

local _, ns = ...

if not ns.M then return end
local M = ns.M

local TAB_H = 32 -- the menu row's height (once Kit.Tabs'); the plain fallback takes the same room
local MENU_W = 180 -- the dropdown (25 tall)
local STEP_W = 22  -- the plain fallback's prev and next buttons
local NAME_W = 140 -- the chosen name between them
local GREY = 0.6
local FOOT_H = 16 -- S14 (o1765, mock of-5): the put footer's room under every holder
local FOOT = "A guildmate's row shows once you were online together after they last changed it."
local INFO_W, INFO_LINE = 400, 14 -- S28b Task 5 (q1911): the info panel under the menu row's "i", right-aligned
local INFO_MAX = 6 -- info lines per game, at most
local INFO_ART = "Interface\\common\\help-i" -- file id 616343

-- ---------- the widget helpers Harvest.lua and Races.lua share (ns.UI; WoWdle.lua keeps its own) ----------

local UI = {}
ns.UI = UI

function UI.grey(fs) fs:SetTextColor(GREY, GREY, GREY) end

function UI.label(parent, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  return fs
end

function UI.button(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

-- 12480 -> "12,480": thousands with commas.
function UI.fmt(n)
  local s, k = tostring(math.floor(n or 0)), 0
  repeat s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

-- A name in its class colour, white for no class or no colour table.
function UI.classColour(fs, class)
  local cc = class and type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[class]
  if cc then fs:SetTextColor(cc.r, cc.g, cc.b) else fs:SetTextColor(1, 1, 1) end
end

-- The kit's inset over all of f, one frame level below it (its rim shows); nothing when the kit answers nil.
function UI.inset(f)
  local inset = M.Kit.Inset(f)
  if inset then
    inset:SetAllPoints(f)
    inset:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
  end
end

-- WoWdle.lua, Harvest.lua, Races.lua, Vendor.lua and Company.lua load after this file: their build and refresh are
-- looked up at call time. The Higher or lower tab (key "vendor") is ns.VendorTab (Vendor.lua), the Company tab
-- ns.CompanyTab (Company.lua).
-- The Harvest tab is ns.HarvestTab; ns.Harvest is Grain.lua's harvest action (f7201).
ns.GAMES = {
  { key = "wowdle", text = "WoWdle",
    build = function(f) if ns.WoWdle then ns.WoWdle.Build(f) end end,
    refresh = function(f) if ns.WoWdle then ns.WoWdle.Refresh(f) end end,
    info = { "Guess the day's WoW word in six tries. Type or click, then Enter.",
      "Yellow: wrong place. Grey: not in the word. Third colour: right place.",
      "A hint costs 20 grain; in practice it is free.",
      "A * after the tries means the hint was used.", "The guild sees your colours, never your letters." } },
  { key = "harvest", text = "Harvest",
    build = function(f) if ns.HarvestTab then ns.HarvestTab.Build(f) end end,
    refresh = function(f) if ns.HarvestTab then ns.HarvestTab.Refresh(f) end end,
    info = { "Your field grows grain over time.", "Press Harvest to put the grown grain in your purse.",
      "Upgrades make the field grow more.", "Grain pays for bets, the store and the lottery.",
      "The guild board shows everyone's harvest." } },
  { key = "races", text = "Kodo races",
    build = function(f) if ns.Races then ns.Races.Build(f) end end,
    refresh = function(f) if ns.Races then ns.Races.Refresh(f) end end,
    info = { "Six kodos run the Gold Road through the Barrens.", "Bet grain on one kodo before the race starts.",
      "A winning bet pays out in grain.", "Earlier races can be watched again.",
      "The guild sees the winners and the biggest wins." } },
  { key = "vendor", text = "Higher or lower",
    build = function(f) if ns.VendorTab then ns.VendorTab.Build(f) end end,
    refresh = function(f) if ns.VendorTab then ns.VendorTab.Refresh(f) end end,
    info = { "Two pools: Vendor price and Flights.", "Vendor price: which item sells for more to a vendor?",
      "Flights: which takes longer, costs more or stops more?", "Daily: ten pairs a day, right picks earn grain.",
      "Endless: pick until you miss, for no grain.", "Today in the guild shows everyone's daily score." } },
  { key = "company", text = "Company",
    build = function(f) if ns.CompanyTab then ns.CompanyTab.Build(f) end end,
    refresh = function(f) if ns.CompanyTab then ns.CompanyTab.Refresh(f) end end,
    info = { "Spend grain on titles, colours and badges.", "Give grain to the granary goal with the guild.",
      "Buy tickets for the weekly lottery.", "An officer runs the lottery draw and can hide a row.",
      "An officer's hide or draw reaches you once you", "have been online at the same time as an officer." } },
  { key = "who", text = "Who said it?", shown = function() return ns.WhoAvailable and ns.WhoAvailable() end,
    build = function(f) if ns.WhoTab then ns.WhoTab.Build(f) end end,
    refresh = function(f) if ns.WhoTab then ns.WhoTab.Refresh(f) end end,
    info = { "Play a voice line, then pick who said it.", "The names open once the line has played.",
      "Daily: ten lines, right picks earn grain.", "Endless: keep going until a wrong pick.",
      "The guild sees each day's scores and streaks." } },
}

-- The built page: the menu or the plain row, the shown games, one holder each, the chosen key.
local P = { holders = {}, games = {} }

local function entryOf(key)
  for _, e in ipairs(ns.GAMES) do
    if e.key == key then return e end
  end
  return nil
end

-- Shows that game's holder (the others hidden first), names it on the menu and redraws it.
local function choose(key)
  local e, holder = entryOf(key), P.holders[key]
  if not (e and holder) then return end
  P.chosen = key
  for k, h in pairs(P.holders) do
    if k ~= key then h:Hide() end
  end
  holder:Show()
  if P.menu then M.Kit.DropdownText(P.menu, e.text) end
  if P.name then P.name:SetText(e.text) end
  if e.refresh then M.Safe(e.refresh, holder) end
  if P.info and P.info:IsShown() then P.fillInfo() end
end
ns.SelectGame = choose

-- A menu pick or a prev / next click: the game is remembered (when Grain.lua is loaded), then shown. The build's own
-- choose is not a click and records nothing.
local function clicked(key)
  if ns.SetLastGame then ns.SetLastGame(key) end
  choose(key)
end

-- The chosen key while its holder and every ancestor are shown, else nil. The walk stops at UIParent or at a parent
-- that is not a frame (the sim answers a function for a missing one); only an IsShown of false counts as hidden.
function ns.ShownGame()
  local key = P.chosen
  local f = key and P.holders[key]
  if not f then return nil end
  while type(f) == "table" and f ~= UIParent do
    if f:IsShown() == false then return nil end
    f = f:GetParent()
  end
  return key
end

-- The plain fallback's step: the shown game by off from the chosen one, round the list.
local function step(off)
  local n = #P.games
  for i, e in ipairs(P.games) do
    if e.key == P.chosen then return clicked(P.games[ns.Core.Mod(i - 1 + off, n) + 1].key) end
  end
end

local function stepButton(page, text, x, off)
  local b = UI.button(page, text, STEP_W)
  b:SetPoint("TOPLEFT", page, "TOPLEFT", x, -4)
  b:SetScript("OnClick", function() M.Safe(step, off) end)
  return b
end

-- The game list and each entry's shown() are read now, at the page's build (an entry added before the window first
-- opens gets its menu line).
function ns.BuildPage(page)
  for _, e in ipairs(ns.GAMES) do
    if type(e.shown) ~= "function" or e.shown() then P.games[#P.games + 1] = e end
  end
  P.menu = M.Kit.Dropdown(page, MENU_W, function(_, root)
    for _, e in ipairs(P.games) do
      root:CreateRadio(e.text, function(k) return P.chosen == k end, function(k) M.Safe(clicked, k) end, e.key)
    end
  end)
  if P.menu then
    P.menu:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -3) -- mock mn-1: at x 8 the open list's art left the page
  else
    local prev = stepButton(page, "<", 4, -1)
    local nxt = stepButton(page, ">", 4 + STEP_W + NAME_W, 1)
    P.name = UI.label(page, "GameFontNormal")
    P.name:SetPoint("LEFT", prev, "RIGHT", 0, 0)
    P.name:SetPoint("RIGHT", nxt, "LEFT", 0, 0)
    P.name:SetJustifyH("CENTER")
    P.name:SetWordWrap(false)
  end
  for _, e in ipairs(P.games) do
    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -TAB_H)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, FOOT_H)
    holder:Hide()
    P.holders[e.key] = holder
    if e.build then M.Safe(e.build, holder) end
  end
  -- One grey line on the page under the holders, the same for every tab (games rows travel by put, S14).
  local foot = UI.label(page)
  foot:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 8, 2)
  foot:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -8, 2)
  foot:SetWordWrap(false)
  foot:SetText(FOOT)
  UI.grey(foot)
  P.buildInfo(page)
  local last = ns.LastGame and ns.LastGame()
  if P.holders[last] then choose(last) elseif P.games[1] then choose(P.games[1].key) end
end

-- S28b Task 5: the "i" at the menu row's right end toggles GuildSyncGamesInfo, the chosen game's info lines (one
-- FontString per line, up to INFO_MAX). The panel is in UISpecialFrames, as Toast.lua's: modules cannot reach the hub's
-- Compat.EscapeCloses (S28 f6), and Escape then also closes the GuildSync window (f11). The page's hide closes it.
local function infoHeight(lines) return 16 + INFO_LINE * lines end

function P.fillInfo()
  local e = P.chosen and entryOf(P.chosen)
  local info = e and e.info or {}
  P.infoTitle:SetText(e and e.text or "") -- a11y f5: the panel names its game
  for i, fs in ipairs(P.infoLines) do fs:SetText(info[i] or ""); fs:SetShown(info[i] ~= nil) end
  P.info:SetHeight(infoHeight(#info + 1))
  if P.infoBody ~= P.info then P.infoBody:SetHeight(infoHeight(#info + 1)) end
end

function P.buildInfo(page)
  local b = CreateFrame("Button", nil, page)
  b:SetSize(24, 24)
  b:SetPoint("TOPRIGHT", page, "TOPRIGHT", -4, -4)
  b:SetNormalTexture(INFO_ART)
  b:SetHighlightTexture(INFO_ART, "ADD")
  local f = CreateFrame("Frame", "GuildSyncGamesInfo", page)
  f:SetSize(INFO_W, infoHeight(INFO_MAX + 1))
  f:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, 0)
  f:SetFrameStrata("DIALOG") -- over the game area (q1911)
  f:Hide()
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GuildSyncGamesInfo") end
  local body = M.Kit.Card(f, INFO_W, infoHeight(INFO_MAX + 1)) or f
  if body ~= f then body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end
  P.info, P.infoBody, P.infoLines = f, body, {}
  P.infoTitle = UI.label(body)
  P.infoTitle:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -8)
  P.infoTitle:SetWidth(INFO_W - 16)
  P.infoTitle:SetWordWrap(false)
  for i = 1, INFO_MAX do
    local fs = UI.label(body)
    fs:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -8 - INFO_LINE * i)
    fs:SetWidth(INFO_W - 16)
    fs:SetWordWrap(false)
    P.infoLines[i] = fs
  end
  b:SetScript("OnEnter", function(self) -- a11y f4: the icon says what it opens
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("About this game")
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function()
    if f:IsShown() then f:Hide() else M.Safe(P.fillInfo); f:Show() end
  end)
  page:HookScript("OnHide", function() f:Hide() end)
end

function ns.RefreshPage()
  local e = P.chosen and entryOf(P.chosen)
  if e and e.refresh and P.holders[P.chosen] then M.Safe(e.refresh, P.holders[P.chosen]) end
end

-- Opens the chat box with text (its "/g " prefix switches the box to guild). Both calls are FrameXML and optional apis
-- (GuildSyncRaids/Tools.lua:160-164); true when one ran. Nothing is sent: the player presses Enter.
function ns.OpenChat(text)
  if M.Compat.Try("ChatFrameUtil.OpenChat", text) then return true end
  return M.Compat.Try("ChatFrame_OpenChat", text) and true or false
end
