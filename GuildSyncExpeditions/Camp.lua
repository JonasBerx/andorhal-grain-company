-- GuildSyncExpeditions Camp.lua: the camp, the first view of the page, ns.Camp (0.19 plan, slice V1, Seams 7, 17).
--   Camp.Build(f)     the plan backdrop and the seven places on f, the 726 x 508 box Page.lua scales
--   Camp.Refresh(f)   re-reads the counts on the places, the unseen results and who is due back next
-- f.camp = { backdrop, places = { [key] = button }, out = button }, each place with art, hl, label, count;
-- out is the line at the bottom left, with face, ring, title, text, mode. Mode "back" while ns.Unseen lists a
-- result (newest first; a click calls ns.SeeAll and opens the History list), else "out": the run due back first
-- (a click shows its zone with the pin ringed), hidden while ns.OutNow answers nil.
-- Every read is looked up at call time: files load after this one, and the optional seams (IsReserve,
-- CampSoon, GranaryDoor) come with later slices. A read that is missing leaves its count hidden.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local PLAN_FILE = 978203 -- the garrison plan, for a client without the Garr_Map_Frostfire atlases
local PLAN_U, PLAN_V = 672 / 1024, 468 / 512
local PLAN_W, PLAN_H, PLAN_X = 782, 508, -28
local PLACE_W = 108
local BAG_CELLS = 64
local WRIT_SLOTS = 3
local OUT_W, OUT_H, OUT_X, OUT_Y, OUT_TEXT_X = 300, 40, 12, 12, 38
local FACE, RING = 22, 36
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- fn's answer, nil when fn is missing or threw (M.Safe records the throw).
local function read(fn, ...)
  if type(fn) ~= "function" then return nil end
  local good, value = M.Safe(fn, ...)
  if good then return value end
  return nil
end

local function isReserve(row)
  if type(ns.IsReserve) == "function" then return read(ns.IsReserve, row.id) end
  return row.reserve == true
end

-- A resting or dead follower is in use but neither ready nor away.
local function roster()
  local rows = read(ns.Followers)
  if type(rows) ~= "table" then return nil end
  local out = { used = 0, ready = 0, away = 0, reserve = 0 }
  for _, row in ipairs(rows) do
    if isReserve(row) then
      out.reserve = out.reserve + 1
    else
      out.used = out.used + 1
      if row.state == "idle" then out.ready = out.ready + 1 end
      if row.state == "out" then out.away = out.away + 1 end
    end
  end
  return out
end

local function expeditions()
  local rows = read(ns.TodayRows)
  if type(rows) ~= "table" then return nil end
  return #rows
end

local function bagUsed()
  local bag = read(ns.Bag)
  if type(bag) ~= "table" then return nil end
  local n = 0
  for _ in pairs(bag) do n = n + 1 end
  return n
end

-- found, total
local function relics()
  local have = read(ns.Collection)
  if type(have) ~= "table" or type(have.relics) ~= "table" then return nil end
  if type(ns.BookData) ~= "table" or type(ns.BookData.relics) ~= "table" then return nil end
  return #have.relics, #ns.BookData.relics
end

local function writs()
  local open = read(ns.OpenWrits)
  if type(open) ~= "table" then return nil end
  return #open
end

local function barracksTip(tip)
  local r = roster()
  if not r then return end
  local cap = type(ns.FollowerData) == "table" and ns.FollowerData.CAP_USE or 3
  tip:AddLine(r.used .. "/" .. cap .. " Followers", 1, 1, 1)
  tip:AddLine(r.ready .. " ready", 0.1, 1, 0.1)
  tip:AddLine(r.away .. " away", 1, 0.82, 0)
  tip:AddLine(r.reserve .. " in reserve", 0.62, 0.62, 0.62)
end

local function mapTip(tip)
  local n = expeditions()
  if n then tip:AddLine(n .. (n == 1 and " expedition" or " expeditions"), 1, 1, 1) end
  local left = read(ns.NextRefresh)
  if type(left) == "number" then tip:AddLine("New expeditions in " .. ns.W.Time(left), 1, 1, 1) end
end

local function storageTip(tip)
  local n = bagUsed()
  if n then tip:AddLine(n .. "/" .. BAG_CELLS .. " slots", 1, 1, 1) end
end

local function quartermasterTip(tip)
  tip:AddLine("Gear and supplies", 1, 1, 1)
end

local function bookTip(tip)
  local found, total = relics()
  if found then tip:AddLine(found .. "/" .. total .. " relics", 1, 1, 1) end
end

local function writsTip(tip)
  local n = writs()
  if n then tip:AddLine(n .. "/" .. WRIT_SLOTS .. " writs", 1, 1, 1) end
end

local function barracksCount()
  local r = roster()
  return r and tostring(r.ready)
end

local function mapCount()
  local n = expeditions()
  return n and tostring(n)
end

local function storageCount()
  local n = bagUsed()
  return n and (n .. "/" .. BAG_CELLS)
end

local function bookCount()
  local found, total = relics()
  return found and (found .. "/" .. total)
end

local function writsCount()
  local n = writs()
  return n and (n .. "/" .. WRIT_SLOTS)
end

local PLACES = {
  { key = "barracks", name = "Barracks", atlas = "GarrBuilding_Barracks_1_H_Map", x = 202, y = 150, h = 86,
    icon = "Interface\\Icons\\INV_Stone_SharpeningStone_01", count = barracksCount, tip = barracksTip },
  { key = "map", name = "Map Table", atlas = "GarrBuilding_TownHall_1_H_Map", x = 392, y = 238, h = 102,
    icon = "Interface\\Icons\\INV_Misc_Map_01", count = mapCount, tip = mapTip },
  { key = "quartermaster", name = "Quartermaster", atlas = "GarrBuilding_TradingPost_2_H_Map", x = 490, y = 140, h = 95,
    icon = "Interface\\Icons\\INV_Misc_Gear_02", tip = quartermasterTip },
  { key = "storage", name = "Storage", atlas = "GarrBuilding_Storehouse_1_H_Map", x = 607, y = 226, h = 80,
    icon = "Interface\\Icons\\INV_Ingot_Iron", count = storageCount, tip = storageTip },
  { key = "book", name = "Book", atlas = "GarrBuilding_Inscription_1_H_Map", x = 598, y = 140, h = 78,
    icon = "Interface\\Icons\\INV_Misc_Candle_01", count = bookCount, tip = bookTip },
  { key = "writs", name = "Writs", atlas = "GarrBuilding_Armory_1_H_Map", x = 224, y = 376, h = 81,
    icon = "Interface\\Icons\\INV_Misc_Bandage_12", count = writsCount, tip = writsTip },
  { key = "guild", name = "Guild", atlas = "GarrBuilding_MageTower_1_H_Map", x = 85, y = 295, h = 90,
    icon = "Interface\\Icons\\INV_Misc_Herb_07", count = function()
      local demo = ns.DemoGuildRows()
      if demo then return tostring(#demo) end
      return ns.GuildCount and ns.GuildCount()
    end },
}

local function showTip(owner, pl)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(pl.name)
  if pl.tip then pl.tip(tip) end
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function go(key, opts)
  if type(ns.GoTo) ~= "function" then return end
  if opts then ns.GoTo(key, opts) else ns.GoTo(key) end
end

local function drawBackdrop(tex)
  if M.Kit.Atlas(tex, "Garr_Map_Frostfire3_H") then return end
  tex:SetTexture(PLAN_FILE)
  tex:SetTexCoord(0, PLAN_U, 0, PLAN_V)
  tex:Show()
end

local function newPlace(f, pl)
  local b = CreateFrame("Button", nil, f)
  b:SetSize(PLACE_W, pl.h)
  b:SetPoint("CENTER", f, "TOPLEFT", pl.x, -pl.y)

  b.art = b:CreateTexture(nil, "ARTWORK")
  b.art:SetAllPoints(b)
  M.Kit.Atlas(b.art, pl.atlas, pl.icon)

  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints(b)
  M.Kit.Atlas(b.hl, pl.atlas, pl.icon)
  b.hl:SetBlendMode("ADD")
  b.hl:SetAlpha(0.3)

  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  -- outlined, so the name stays readable on the pale plan
  local file, size = b.label:GetFont()
  if file then b.label:SetFont(file, size, "OUTLINE") end
  b.label:SetPoint("TOP", b, "TOP", 0, -(pl.h - 12))
  b.label:SetText(pl.name)

  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.count:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -2)
  b.count:Hide()

  b:SetScript("OnClick", function() M.Safe(go, pl.key) end)
  b:SetScript("OnEnter", function(self) M.Safe(showTip, self, pl) end)
  b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  return b
end

-- The run due back first and its time left; nil with nobody out or no clock.
local function outNow()
  local out, now = read(ns.OutNow), read(ns.Now)
  if type(out) ~= "table" or type(now) ~= "number" then return nil end
  return out, ns.W.Time(out.untilT - now)
end

-- "<place>, <region>", or the one of them there is; a dungeon's place is its region.
local function whereLine(out)
  local region
  for _, info in ipairs(ns.Regions.LIST) do
    if info.id == out.region then region = info.name end
  end
  local place = out.place ~= "" and out.place or nil
  if place and region and place ~= region then return place .. ", " .. region end
  return place or region
end

local function showOut(owner)
  local out, left = outNow()
  if not out then return end
  showTip(owner, { name = out.title, tip = function(tip)
    local where = whereLine(out)
    if where then tip:AddLine(where, 1, 1, 1) end
    local who = read(ns.Follower, out.fid)
    if who then tip:AddLine(who.name .. ", Level " .. who.level .. " " .. who.race .. " " .. who.class, 1, 1, 1) end
    tip:AddLine("Returns in " .. left, 1, 0.82, 0)
    tip:AddLine("Click to show on map", 0.1, 1, 0.1)
  end })
end

-- Back: clear the unseen results and open the History list. Out: show the run due back first on the map.
local function clickOut(b)
  if b.mode == "back" then
    read(ns.SeeAll)
    go("map", { history = true })
    return
  end
  local out = outNow()
  if out then go("map", { region = out.region, ring = out.rowId }) else go("map") end
end

-- CharacterTab's round mask, where the client has one.
local function round(owner, tex)
  if not owner.CreateMaskTexture or not tex.AddMaskTexture then return end
  pcall(function()
    local mask = owner:CreateMaskTexture()
    if not mask then return end
    mask:SetAllPoints(tex)
    mask:SetTexture(MASK)
    tex:AddMaskTexture(mask)
  end)
end

local function newOutLine(f)
  local b = CreateFrame("Button", nil, f)
  b:SetSize(OUT_W, OUT_H)
  b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", OUT_X, OUT_Y)
  b:Hide()

  b.face = b:CreateTexture(nil, "ARTWORK")
  b.face:SetSize(FACE, FACE)
  b.face:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -8)
  round(b, b.face)

  b.ring = b:CreateTexture(nil, "OVERLAY")
  b.ring:SetSize(RING, RING)
  b.ring:SetPoint("TOPLEFT", b, "TOPLEFT", -3, -1)
  M.Kit.Atlas(b.ring, "map_faction_ring")

  b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.title:SetPoint("TOPLEFT", b, "TOPLEFT", OUT_TEXT_X, -8)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  b.text:SetPoint("TOPLEFT", b, "TOPLEFT", OUT_TEXT_X, -24)
  -- one line each, cut with an ellipsis inside the button (a11y f1)
  for _, fs in ipairs({ b.title, b.text }) do
    fs:SetWidth(OUT_W - OUT_TEXT_X - 4)
    fs:SetWordWrap(false)
  end

  b:SetScript("OnClick", function(self) M.Safe(clickOut, self) end)
  b:SetScript("OnEnter", function(self) if self.mode ~= "back" then M.Safe(showOut, self) end end)
  b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  return b
end

-- The back line (an unseen result) stands in the out line's place, also with nobody out.
local function drawOut(b)
  local list = read(ns.Unseen)
  if type(list) == "table" and list[1] then
    local u = list[1]
    b.mode = "back"
    b:Show()
    b.title:SetText(ns.Escape(u.title))
    local text = ns.Escape(u.who) .. " is back: " .. u.word
    if #list > 1 then text = text .. " and " .. (#list - 1) .. " more" end
    b.text:SetText(text)
    b.face:SetShown(read(ns.ShowPortrait, b.face, u.fid) == "portrait")
    return
  end
  b.mode = "out"
  local out, left = outNow()
  b:SetShown(out ~= nil)
  if not out then return end
  b.title:SetText(out.title)
  b.text:SetText(out.name .. " returns in " .. left)
  b.face:SetShown(read(ns.ShowPortrait, b.face, out.fid) == "portrait")
end

local Camp = {}
ns.Camp = Camp

local function callBuild(part, f)
  if type(part) == "table" and type(part.Build) == "function" then M.Safe(part.Build, f) end
end

function Camp.Build(f)
  local ui = { places = {} }
  f.camp = ui

  ui.backdrop = f:CreateTexture(nil, "BACKGROUND")
  ui.backdrop:SetSize(PLAN_W, PLAN_H)
  ui.backdrop:SetPoint("TOPLEFT", f, "TOPLEFT", PLAN_X, 0)

  for _, pl in ipairs(PLACES) do ui.places[pl.key] = newPlace(f, pl) end
  ui.out = newOutLine(f)

  callBuild(ns.CampSoon, f)
  callBuild(ns.GranaryDoor, f)
end

function Camp.Refresh(f)
  local ui = f.camp
  if type(ui) ~= "table" then return end
  drawBackdrop(ui.backdrop)
  for _, pl in ipairs(PLACES) do
    local count = ui.places[pl.key].count
    local text = read(pl.count)
    if text then
      count:SetText(text)
      count:Show()
    else
      count:Hide()
    end
  end
  drawOut(ui.out)
end
