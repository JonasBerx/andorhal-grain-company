-- GuildSyncGames Page.lua: the Games page shell (plan Task 7, Seams). One tab per ns.GAMES entry ({ key, text, build,
-- refresh }; WoWdle first) through M.Kit.Tabs, else plain buttons in the same row; one holder per entry under the
-- 32-tall row, each built once at the page's build. ns.SelectGame(key) shows that holder; ns.OpenChat fills the chat box.
-- S11: Harvest and Kodo races follow WoWdle; a tab click records the game through ns.SetLastGame (Grain.lua), and
-- ns.ShownGame() answers the chosen key while the page is on screen. ns.UI holds the widget helpers both tabs use.
-- S14 Task 7: the holders end FOOT_H 16 above the page's foot, where one grey line says how a guildmate's row arrives.

local _, ns = ...

if not ns.M then return end
local M = ns.M

local TAB_H = 32 -- Kit.Tabs' holder height; the plain-button row takes the same room
local TAB_W = 96
local GREY = 0.6
local FOOT_H = 16 -- S14 (o1765, mock of-5): the put footer's room under every holder
local FOOT = "A guildmate's row shows once you were online together after they last changed it."

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
-- looked up at call time. The Vendor price tab is ns.VendorTab (Vendor.lua), the Company tab ns.CompanyTab (Company.lua).
-- The Harvest tab is ns.HarvestTab; ns.Harvest is Grain.lua's harvest action (f7201).
ns.GAMES = {
  { key = "wowdle", text = "WoWdle",
    build = function(f) if ns.WoWdle then ns.WoWdle.Build(f) end end,
    refresh = function(f) if ns.WoWdle then ns.WoWdle.Refresh(f) end end },
  { key = "harvest", text = "Harvest",
    build = function(f) if ns.HarvestTab then ns.HarvestTab.Build(f) end end,
    refresh = function(f) if ns.HarvestTab then ns.HarvestTab.Refresh(f) end end },
  { key = "races", text = "Kodo races",
    build = function(f) if ns.Races then ns.Races.Build(f) end end,
    refresh = function(f) if ns.Races then ns.Races.Refresh(f) end end },
  { key = "vendor", text = "Vendor price",
    build = function(f) if ns.VendorTab then ns.VendorTab.Build(f) end end,
    refresh = function(f) if ns.VendorTab then ns.VendorTab.Refresh(f) end end },
  { key = "company", text = "Company",
    build = function(f) if ns.CompanyTab then ns.CompanyTab.Build(f) end end,
    refresh = function(f) if ns.CompanyTab then ns.CompanyTab.Refresh(f) end end },
}

local P = { holders = {} } -- the built page: tabs or buttons, one holder per game, the chosen key

local function entryOf(key)
  for _, e in ipairs(ns.GAMES) do
    if e.key == key then return e end
  end
  return nil
end

-- Shows that game's holder (the others hidden first), marks its tab and redraws it.
local function choose(key)
  local e, holder = entryOf(key), P.holders[key]
  if not (e and holder) then return end
  P.chosen = key
  for k, h in pairs(P.holders) do
    if k ~= key then h:Hide() end
  end
  holder:Show()
  if P.tabs then P.tabs:Select(key) end
  for k, b in pairs(P.buttons or {}) do b:SetEnabled(k ~= key) end
  if e.refresh then M.Safe(e.refresh, holder) end
end
ns.SelectGame = choose

-- A tab or button click: the game is remembered (when Grain.lua is loaded), then shown. The build's own choose is not
-- a click and records nothing.
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

-- The game list is read now, at the page's build (an entry added before the window first opens gets its tab).
function ns.BuildPage(page)
  local entries = {}
  for i, e in ipairs(ns.GAMES) do entries[i] = { key = e.key, text = e.text } end
  P.tabs = M.Kit.Tabs(page, entries, clicked)
  if not P.tabs then
    P.buttons = {}
    for i, e in ipairs(ns.GAMES) do
      local key = e.key
      local b = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
      b:SetSize(TAB_W, 22)
      b:SetPoint("TOPLEFT", page, "TOPLEFT", 4 + (i - 1) * (TAB_W + 2), -4)
      b:SetText(e.text)
      b:SetScript("OnClick", function() M.Safe(clicked, key) end)
      P.buttons[key] = b
    end
  end
  for _, e in ipairs(ns.GAMES) do
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
  if ns.GAMES[1] then choose(P.chosen or ns.GAMES[1].key) end
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
