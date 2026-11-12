-- GuildSyncExpeditions Page.lua: the Expeditions page in the GuildSync window (0.19 plan, slice V1, Seams 7, 13, 17).
-- The first view is the camp (ns.Camp); a click on a building opens that place, with one holder per place.
--   ns.BuildPage(page), ns.RefreshPage()     the hub's entries (Module.lua)
--   ns.GoTo(place, opts)                     "camp" or one of the seven places; does nothing until BuildPage has run.
--                                            A table opts goes once to that place's Refresh(frame, opts); anything else
--                                            is dropped, and so is opts while the page has no size (no openPlace).
-- page.holders[place], page.clip, page.box, page.place, page.band = { frame, back, name, sub, purse, label, icon, tick,
-- bar = { [place] = frame } }; the Quartermaster and Storage bars hold bar.barracks, a button to the Barracks' storage.
-- The band runs across the top of every view and is never scaled.
-- A place's tab is looked up at call time, because most load after this file. Each place builds once, on its first
-- visit; one whose Build threw stays empty under the band and is not refreshed again.
-- Followers settle when the page shows and every 30 s while it shows, never from ns.RefreshPage.
-- From login on, a 30 s check settles them while the page does not show: never in demo, and held while
-- InCombatLockdown answers anything but false. It only settles; the page redraws when it next shows.

local _, ns = ...

if not ns.M then return end
local M = ns.M

local BAND_H = 32
local FADE_S = 0.35
local BOX_W, BOX_H = 726, 508
local BACK_W, BACK_H, BACK_X, BACK_Y = 116, 22, 8, -5
local NAME_X_CAMP, NAME_X = 14, 134
local SUB_GAP = 10
local BAR_X, BAR_Y, BAR_H, BAR_LESS = 132, -5, 22, 256 -- the bar's width is the page's less BAR_LESS
local PURSE_W, PURSE_H, PURSE_X, PURSE_Y = 104, 18, -12, -8
local BARRACKS_W, BARRACKS_H, BARRACKS_X = 80, 22, -8 -- the band's Barracks button, right end of its bar
local WHEAT = 134058 -- INV_Misc_Food_Wheat_01, Games' purse icon
local PURSE_EVERY = 0.5 -- seconds between purse checks while the page shows
local TICK_EVERY = 30 -- seconds between settles while the page shows
local CHECK_EVERY = 30 -- seconds between background settles while the page does not show

local CAMP = "camp"
local PLACES = {
  camp = { tab = "Camp", title = "Company Camp" },
  barracks = { tab = "CharacterTab", title = "Barracks" },
  map = { tab = "MapTab", title = "Map Table" },
  quartermaster = { tab = "ShopTab", title = "Quartermaster" },
  storage = { tab = "BagGrid", title = "Storage" },
  book = { tab = "BookTab", title = "Book" },
  writs = { tab = "QuestTab", title = "Writs" },
  guild = { tab = "GuildTab", title = "Guild" },
}

-- built[place]: nil not built yet, true built, false its Build threw
local P = { built = {}, since = 0 }

-- 12480 -> "12,480"
local function fmt(n)
  local s, k = tostring(math.floor(n)), 0
  repeat s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end

local function drawPurse()
  local n = M.Purse()
  if type(n) ~= "number" then n = nil end
  if P.drawn and P.shownN == n then return end
  P.drawn, P.shownN = true, n
  P.page.band.label:SetText((n and fmt(n) or "-") .. " grain")
end

-- The page's size, nil while it has none yet.
local function pageSize(page)
  local w, h = page:GetWidth(), page:GetHeight()
  if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return nil end
  return w, h
end

local function layout(page)
  local w, h = pageSize(page)
  if not w then return end
  local k = math.min(w / BOX_W, h / BOX_H, 1)
  page.band.frame:SetSize(w, BAND_H)
  page.clip:SetSize(w, h)
  page.box:SetScale(k)
  for place, holder in pairs(page.holders) do
    if place == "map" then
      holder:SetScale(k)
    elseif place ~= CAMP then
      holder:SetSize(w, h - BAND_H)
    end
  end
  for _, bar in pairs(page.band.bar) do bar:SetSize(w - BAR_LESS, BAR_H) end
end

local function frameOf(place)
  if place == CAMP then return P.page.box end
  return P.page.holders[place]
end

local function refreshPlace(place, opts)
  if P.built[place] ~= true then return end
  local tab = ns[PLACES[place].tab]
  if type(tab) == "table" and type(tab.Refresh) == "function" then
    if type(opts) == "table" then
      M.Safe(tab.Refresh, frameOf(place), opts)
    else
      M.Safe(tab.Refresh, frameOf(place))
    end
  end
end

local function openPlace(place, opts)
  local tab = ns[PLACES[place].tab]
  if P.built[place] == nil and type(tab) == "table" and type(tab.Build) == "function" then
    P.built[place] = false
    if M.Safe(tab.Build, frameOf(place), P.page.band.bar[place]) then P.built[place] = true end
  end
  refreshPlace(place, opts)
end

local function setBand(page, place)
  local band = page.band
  local onCamp = place == CAMP
  band.name:SetText(PLACES[place].title)
  band.name:ClearAllPoints()
  band.name:SetPoint("LEFT", band.frame, "LEFT", onCamp and NAME_X_CAMP or NAME_X, 0)
  band.sub:SetShown(onCamp)
  band.back:SetShown(not onCamp)
  for key, bar in pairs(band.bar) do bar:SetShown(key == place) end
end

-- Decoration only: the end state is already set and this may be missing on a client.
local fades = {}
function ns.FadeIn(frame)
  if fades[frame] == nil then
    local fx = frame.CreateAnimationGroup and frame:CreateAnimationGroup() or false
    if fx then
      local alpha = fx:CreateAnimation("Alpha")
      alpha:SetFromAlpha(0)
      alpha:SetToAlpha(1)
      alpha:SetDuration(FADE_S)
    end
    fades[frame] = fx
  end
  if fades[frame] then
    fades[frame]:Stop()
    fades[frame]:Play()
  end
end

local function goTo(place, opts)
  if type(opts) ~= "table" then opts = nil end
  local page = P.page
  if not page or not PLACES[place] then return end
  if place == "guild" and type(ns.GuildTab) ~= "table" then return end
  for key, holder in pairs(page.holders) do
    if key ~= place then holder:Hide() end
  end
  local moved = page.place ~= place
  page.place = place
  layout(page)
  setBand(page, place)
  page.holders[place]:Show()
  if pageSize(page) then openPlace(place, opts) end
  if moved then M.Safe(ns.FadeIn, page.holders[place]) end
end

function ns.GoTo(place, opts)
  M.Safe(goTo, place, opts)
end

-- True when SettleDue answered a non-empty list.
local function settle()
  if type(ns.SettleDue) ~= "function" then return false end
  local good, due = M.Safe(ns.SettleDue, ns.Now())
  return good and type(due) == "table" and #due > 0
end

-- Holds unless InCombatLockdown plainly answers false (missing, throwing or nil all hold).
local function holdForCombat()
  local ran, v = M.Compat.Try("InCombatLockdown")
  return not (ran == true and v == false)
end

local function backgroundCheck()
  M.After(CHECK_EVERY, backgroundCheck)
  if M.Demo() then return end
  if P.page and P.page:IsVisible() then return end
  if holdForCombat() then return end
  settle()
end

local armed = false
ns.LoginHooks[#ns.LoginHooks + 1] = function()
  if armed then return end
  armed = true
  M.After(CHECK_EVERY, backgroundCheck)
end

local function showPendingRecruit()
  if type(ns.ShowPendingRecruit) == "function" then M.Safe(ns.ShowPendingRecruit) end
end

local function onTick(elapsed)
  local page = P.page
  if not page:IsVisible() then return end
  P.since = P.since + (elapsed or 0)
  if P.since < TICK_EVERY then return end
  P.since = 0
  local settled = settle()
  if settled or page.place == CAMP or page.place == "map" then refreshPlace(page.place) end
  if settled then showPendingRecruit() end
end

local function onPageShow()
  local page = P.page
  layout(page)
  P.since = 0
  if settle() then refreshPlace(page.place) end
  showPendingRecruit()
end

local function buildPurse(band)
  local f = CreateFrame("Frame", nil, band.frame)
  f:SetSize(PURSE_W, PURSE_H)
  f:SetPoint("TOPRIGHT", band.frame, "TOPRIGHT", PURSE_X, PURSE_Y)
  band.purse = f
  band.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  band.label:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  band.label:SetJustifyH("RIGHT")
  band.icon = f:CreateTexture(nil, "ARTWORK")
  band.icon:SetSize(16, 16)
  band.icon:SetTexture(WHEAT)
  band.icon:SetPoint("RIGHT", band.label, "LEFT", -4, 0)
  local since = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    since = since + (elapsed or 0)
    if since < PURSE_EVERY then return end
    since = 0
    M.Safe(drawPurse)
  end)
end

-- Opens the Barracks at its storage.
local function addBarracksButton(bar)
  local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  b:SetSize(BARRACKS_W, BARRACKS_H)
  b:SetPoint("RIGHT", bar, "RIGHT", BARRACKS_X, 0)
  b:SetText("Barracks")
  b:SetScript("OnClick", function() M.Safe(goTo, "barracks", { storage = true }) end)
  bar.barracks = b
end

local function buildBand(page)
  local frame = CreateFrame("Frame", nil, page)
  frame:SetHeight(BAND_H)
  frame:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  frame:SetFrameLevel(page:GetFrameLevel() + 40)
  local band = { frame = frame, bar = {} }
  page.band = band

  local strip = frame:CreateTexture(nil, "BACKGROUND")
  strip:SetAllPoints(frame)
  strip:SetColorTexture(10 / 255, 8 / 255, 6 / 255, 0.86)
  local line = frame:CreateTexture(nil, "BORDER")
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  line:SetColorTexture(1, 0.82, 0, 0.28)

  band.back = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  band.back:SetSize(BACK_W, BACK_H)
  band.back:SetPoint("TOPLEFT", frame, "TOPLEFT", BACK_X, BACK_Y)
  band.back:SetText("Back to Camp")
  band.back:SetScript("OnClick", function() M.Safe(goTo, CAMP) end)

  band.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  band.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  band.sub:SetPoint("LEFT", band.name, "RIGHT", SUB_GAP, 0)
  band.sub:SetText("Brill, Tirisfal Glades")

  buildPurse(band)

  for place in pairs(PLACES) do
    if place ~= CAMP then
      local bar = CreateFrame("Frame", nil, frame)
      bar:SetHeight(BAR_H)
      bar:SetPoint("TOPLEFT", frame, "TOPLEFT", BAR_X, BAR_Y)
      bar:Hide()
      if place == "quartermaster" or place == "storage" then addBarracksButton(bar) end
      band.bar[place] = bar
    end
  end

  band.tick = CreateFrame("Frame", nil, frame)
  band.tick:SetSize(1, 1)
  band.tick:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  band.tick:SetScript("OnUpdate", function(_, elapsed) M.Safe(onTick, elapsed) end)
end

local function buildHolder(page, place)
  local h = CreateFrame("Frame", nil, page)
  if place == "map" then
    h:SetSize(BOX_W, BOX_H)
    h:SetPoint("CENTER", page, "CENTER", 0, 0)
  else
    h:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -BAND_H)
  end
  h:Hide()
  return h
end

function ns.BuildPage(page)
  P.page = page
  page.place = CAMP
  buildBand(page)

  page.clip = CreateFrame("Frame", nil, page)
  page.clip:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  if page.clip.SetClipsChildren then page.clip:SetClipsChildren(true) end
  page.box = CreateFrame("Frame", nil, page.clip)
  page.box:SetSize(BOX_W, BOX_H)
  page.box:SetPoint("CENTER", page, "CENTER", 0, 0)

  page.holders = { [CAMP] = page.clip }
  for place in pairs(PLACES) do
    if place ~= CAMP then page.holders[place] = buildHolder(page, place) end
  end

  page:HookScript("OnSizeChanged", function() M.Safe(layout, page) end)
  page:HookScript("OnShow", function() M.Safe(onPageShow) end)

  layout(page)
  setBand(page, CAMP)
  drawPurse()
  openPlace(CAMP)
end

function ns.RefreshPage()
  if not P.page then return end
  drawPurse()
  refreshPlace(P.page.place)
  if M.Demo() then showPendingRecruit() end -- in demo that call only hides the window, so no real names stay up
end
