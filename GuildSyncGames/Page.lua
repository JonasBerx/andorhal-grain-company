-- GuildSyncGames Page.lua: the Games page shell (plan Task 7, Seams). One tab per ns.GAMES entry ({ key, text, build,
-- refresh }; WoWdle first) through M.Kit.Tabs, else plain buttons in the same row; one holder per entry under the
-- 32-tall row, each built once at the page's build. ns.SelectGame(key) shows that holder; ns.OpenChat fills the chat box.
-- S11: Harvest and Kodo races follow WoWdle; a tab click records the game through ns.SetLastGame (Grain.lua), and
-- ns.ShownGame() answers the chosen key while the page is on screen. ns.UI holds the widget helpers both tabs use.
-- S14 Task 7: the holders end FOOT_H 16 above the page's foot, where one grey line says how a guildmate's row arrives.
-- S22 Task 6 (o2200): the tab row is a game menu, M.Kit.Dropdown in the same 32-tall row, else plain prev and next
-- buttons around the chosen name. An entry's optional shown() is read at the build: a hidden entry gets no menu line,
-- no holder and no build.
-- o2650 Task 1: P.chosen nil is the home (P.home on the holder anchors, filled by ns.Home when loaded). The build, every
-- window open and the page's OnShow go home and record nothing; a pick (menu, plain step, ns.OpenGame) records the game.
-- The row: All games, the menu, the purse (a throttled OnUpdate redraws it on a change), the "i".

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
local ALL_W = 84 -- o2650: the row's All games button
local ROW_X = 10 + ALL_W + 6 -- the menu (or the plain prev) right of All games
local WHEAT = 134058 -- INV_Misc_Food_Wheat_01
local PURSE_W = 130 -- the purse's mouse area (icon and label right-aligned in it)
local PURSE_EVERY, HOME_EVERY = 0.5, 5 -- o2655: the purse check; the home's redraw while it shows
local HOME_TEXT = "Choose a game"
local PURSE_TIP = { "Your grain", "One purse for every game: what you win, harvest and spend.",
  "Grain is play money: never gold, never traded." }
local HOME_INFO = { "Your field grows grain; press Harvest to put it in your purse.",
  "Grain pays for bets, the store and the lottery.", "Daily puzzles: right picks earn grain; Endless pays none.",
  PURSE_TIP[2], PURSE_TIP[3] }

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
  if P.home then P.home:Hide() end
  holder:Show()
  if P.all then P.all:SetEnabled(true) end
  if P.menu and M.Kit and M.Kit.DropdownText then M.Kit.DropdownText(P.menu, e.text) end
  if P.name then P.name:SetText(e.text) end
  if e.refresh then M.Safe(e.refresh, holder) end
  if P.info and P.info:IsShown() then P.fillInfo() end
end
ns.SelectGame = choose

-- The home's cards, drawn now (when Home.lua is loaded and the home shows).
local function drawHome()
  P.homeDirty, P.homeSince = false, 0
  local H = ns.Home
  if P.home and P.chosen == nil and type(H) == "table" and H.Draw then M.Safe(H.Draw, P.home) end
end

-- The home: every holder hidden, the home frame shown, nothing recorded. Cheap and idempotent (it runs on the window's
-- open and on the page's OnShow).
local function goHome()
  if not P.home then return end
  P.chosen = nil
  for _, h in pairs(P.holders) do h:Hide() end
  P.home:Show()
  if P.menu and M.Kit and M.Kit.DropdownText then M.Kit.DropdownText(P.menu, HOME_TEXT) end
  if P.name then P.name:SetText(HOME_TEXT) end
  if P.all then P.all:SetEnabled(false) end
  drawHome()
  if P.info and P.info:IsShown() then M.Safe(P.fillInfo) end
end

-- A menu pick, a prev / next click or ns.OpenGame: a shown game is remembered (when Grain.lua is loaded), then shown.
-- The build's own choose is not a click and records nothing; an unknown or hidden key does nothing.
local function clicked(key)
  if not P.holders[key] then return end
  if ns.SetLastGame then ns.SetLastGame(key) end
  choose(key)
end
ns.OpenGame = clicked

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

-- The plain fallback's step: the shown game by off from the chosen one, round the list; from the home the first (next)
-- or the last (prev).
local function step(off)
  local n = #P.games
  if P.chosen == nil then
    local e = P.games[off > 0 and 1 or n]
    if e then clicked(e.key) end
    return
  end
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

-- The row purse: redrawn only when ns.Purse() changed.
local function drawPurse()
  local n = ns.Purse and ns.Purse()
  if P.purseLabel and type(n) == "number" and n ~= P.purseShown then
    P.purseShown = n
    P.purseLabel:SetText(UI.fmt(n) .. " grain")
  end
end

local function purseTip(self)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
  GameTooltip:SetText(PURSE_TIP[1])
  for i = 2, #PURSE_TIP do GameTooltip:AddLine(PURSE_TIP[i], 1, 1, 1, true) end
  GameTooltip:Show()
end

-- The purse right of the menu, 8 left of the "i" (b): wheat 16x16 then "<n> grain".
local function buildPurse(page, b)
  local f = CreateFrame("Frame", nil, page)
  f:SetSize(PURSE_W, 20)
  f:SetPoint("RIGHT", b, "LEFT", -8, 0)
  f:EnableMouse(true)
  P.purse = f
  P.purseLabel = UI.label(f, "GameFontHighlight")
  P.purseLabel:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  P.purseLabel:SetJustifyH("RIGHT")
  P.purseLabel:SetWordWrap(false)
  local icon = f:CreateTexture(nil, "ARTWORK")
  icon:SetSize(16, 16)
  icon:SetTexture(WHEAT)
  icon:SetPoint("RIGHT", P.purseLabel, "LEFT", -4, 0)
  f:SetScript("OnEnter", function(self) M.Safe(purseTip, self) end)
  f:SetScript("OnLeave", function() if type(GameTooltip) == "table" then GameTooltip:Hide() end end)
  drawPurse()
end

-- o2655: every PURSE_EVERY the purse redraws on a change and a dirty home draws; while the home shows it is marked dirty
-- every HOME_EVERY.
local function tick(since)
  P.homeSince = (P.homeSince or 0) + since
  drawPurse()
  if P.chosen == nil and P.homeSince >= HOME_EVERY then P.homeDirty = true end
  if P.homeDirty and P.chosen == nil then drawHome() end
end

-- The game list and each entry's shown() are read now, at the page's build (an entry added before the window first
-- opens gets its menu line).
function ns.BuildPage(page)
  for _, e in ipairs(ns.GAMES) do
    if type(e.shown) ~= "function" or e.shown() then P.games[#P.games + 1] = e end
  end
  P.all = UI.button(page, "All games", ALL_W)
  P.all:SetPoint("TOPLEFT", page, "TOPLEFT", 10, -5)
  P.all:SetScript("OnClick", function() M.Safe(goHome) end)
  P.menu = M.Kit and M.Kit.Dropdown and M.Kit.Dropdown(page, MENU_W, function(_, root)
    for _, e in ipairs(P.games) do
      root:CreateRadio(e.text, function(k) return P.chosen == k end, function(k) M.Safe(clicked, k) end, e.key)
    end
  end)
  if P.menu then
    P.menu:SetPoint("TOPLEFT", page, "TOPLEFT", ROW_X, -3) -- mock mn-1: at x 8 the open list's art left the page
  else
    local prev = stepButton(page, "<", ROW_X, -1)
    local nxt = stepButton(page, ">", ROW_X + STEP_W + NAME_W, 1)
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
  -- the home, on the holder anchors; Home.lua (looked up now) builds its cards
  P.home = CreateFrame("Frame", nil, page)
  P.home:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -TAB_H)
  P.home:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, FOOT_H)
  P.home:Hide()
  local H = ns.Home
  if type(H) == "table" and H.Build then
    local shown = {}
    for _, e in ipairs(P.games) do shown[e.key] = true end
    shown.flights = shown.vendor
    M.Safe(H.Build, P.home, shown)
  end
  P.buildInfo(page)
  buildPurse(page, P.infoButton)
  page:HookScript("OnShow", function() M.Safe(goHome) end)
  page:HookScript("OnUpdate", function(_, elapsed) -- the throttle before the pcall (Races.lua:742-747)
    P.since = (P.since or 0) + (elapsed or 0)
    if P.since < PURSE_EVERY then return end
    local since = P.since
    P.since = 0
    M.Safe(tick, since)
  end)
  goHome()
end

-- Every window open goes home (the page's OnShow covers a hub page switch); Flight's Play and Toast's Watch choose their
-- game after the open.
if M.On then M.On("windowOpened", function() M.Safe(goHome) end) end

-- S28b Task 5: the "i" at the menu row's right end toggles GuildSyncGamesInfo, the chosen game's info lines (one
-- FontString per line, up to INFO_MAX). The panel is in UISpecialFrames, as Toast.lua's: modules cannot reach the hub's
-- Compat.EscapeCloses (S28 f6), and Escape then also closes the GuildSync window (f11). The page's hide closes it.
local function infoHeight(lines) return 16 + INFO_LINE * lines end

function P.fillInfo()
  local e = P.chosen and entryOf(P.chosen)
  local info = e and e.info or (P.chosen == nil and HOME_INFO) or {}
  P.infoTitle:SetText(e and e.text or (P.chosen == nil and "Games") or "") -- a11y f5: the panel names its game
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
  f:EnableMouse(true) -- A#f2: a click on the panel stays on it, never reaching a home card under it
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
    GameTooltip:SetText(P.chosen == nil and "About the games" or "About this game")
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function()
    if f:IsShown() then f:Hide() else M.Safe(P.fillInfo); f:Show() end
  end)
  page:HookScript("OnHide", function() f:Hide() end)
  P.infoButton = b
end

-- The purse and the shown game now; on the home only a mark (f12: the next tick draws it once).
function ns.RefreshPage()
  M.Safe(drawPurse)
  if P.chosen == nil then P.homeDirty = true return end
  local e = entryOf(P.chosen)
  if e and e.refresh and P.holders[P.chosen] then M.Safe(e.refresh, P.holders[P.chosen]) end
end

-- Opens the chat box with text (its "/g " prefix switches the box to guild). Both calls are FrameXML and optional apis
-- (GuildSyncRaids/Tools.lua:160-164); true when one ran. Nothing is sent: the player presses Enter.
function ns.OpenChat(text)
  if M.Compat.Try("ChatFrameUtil.OpenChat", text) then return true end
  return M.Compat.Try("ChatFrame_OpenChat", text) and true or false
end
