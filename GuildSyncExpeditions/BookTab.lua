-- GuildSyncExpeditions BookTab.lua: the Book, ns.BookTab (0.19 plan, Seams 8).
--   BookTab.Build(f, bar)   builds the page inside f; bar is unused and there is no grain display here
--   BookTab.Refresh(f)      lays out for f's size and refills the open cards; a locked card reads no data
-- ns.Regions, ns.BookData, ns.W and the Book reads are taken at call time: ns.W loads after this file.

local _, ns = ...
if not ns.M then return end
local M = ns.M

-- Fixed per size: a row never stretches with the frame.
local BIG = { slot = 36, slotY = 26, lineY = 68, line = 18, open = 164, locked = 48, pad = 44 }
local SMALL = { slot = 26, slotY = 24, lineY = 54, line = 14, open = 130, locked = 40, pad = 34 }
local BIG_W, BIG_H = 700, 450
local GAP, SUMMARY_H = 6, 18
local SHEET_Y, BAND, BAND_GAP = 4, 48 / 381, 4
local INSET, SLOT_GAP, HEAD_Y = 8, 4, -6
local INK, SUB_INK, LABEL_INK = "2b1a0a", "3b2610", "45200a" -- dark ink on the parchment
local INK_QUALITY = { [0] = "3a3a3a", [1] = "2b1a0a", [2] = "143c00", [3] = "00306a" } -- item quality on parchment
local LINES = { "setLine", "mapLine", "heldLine", "heldHint", "badge" }

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function asKeys(list)
  local out = {}
  for _, v in ipairs(list) do out[v] = true end
  return out
end

local function setFor(region)
  for _, s in ipairs(ns.BookData.sets) do
    if s.region == region then return s end
  end
  return nil
end

local function showTip(owner, s)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  local n = ns.StackCount("relic", s.relic)
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(s.name, 1, 1, 1)
  tip:AddLine("Relic", 1, 0.82, 0)
  tip:AddLine("In " .. ns.W.Name["Company bag"] .. ": " .. n, 1, 1, 1)
  if n >= 1 then tip:AddLine("<Right Click to Break Down>", 0, 1, 0) end
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function refuse(why)
  if why == "demo" then return end -- ns.Inert has said its line
  if why == "full" then
    ns.Say(ns.W.Name["Company bag"] .. " is full.")
  else
    ns.Say("Cannot break that down now.")
  end
end

local function label(parent, font, ink)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:SetTextColor(rgb(ink))
  return fs
end

local function edge(frame, a, b, across)
  local t = frame:CreateTexture(nil, "BORDER")
  t:SetPoint(a, frame, a, 0, 0)
  t:SetPoint(b, frame, b, 0, 0)
  if across then t:SetHeight(1) else t:SetWidth(1) end
  t:SetColorTexture(rgb(SUB_INK))
end

local function newFrame(f)
  local frame = CreateFrame("Frame", nil, f)
  edge(frame, "TOPLEFT", "TOPRIGHT", true)
  edge(frame, "BOTTOMLEFT", "BOTTOMRIGHT", true)
  edge(frame, "TOPLEFT", "BOTTOMLEFT")
  edge(frame, "TOPRIGHT", "BOTTOMRIGHT")
  return frame
end

local function placeOpen(card, size, w)
  for i, s in ipairs(card.slots) do
    s.btn:SetSize(size.slot, size.slot)
    s.btn:ClearAllPoints()
    s.btn:SetPoint("TOPLEFT", card.frame, "TOPLEFT", INSET + (i - 1) * (size.slot + SLOT_GAP), -size.slotY)
  end
  for i, key in ipairs(LINES) do
    card[key]:ClearAllPoints()
    card[key]:SetPoint("TOPLEFT", card.frame, "TOPLEFT", INSET, -(size.lineY + (i - 1) * size.line))
    card[key]:SetWidth(w - 2 * INSET)
  end
end

local function place(f)
  local ui = f.book
  local width, height = f:GetWidth(), f:GetHeight()
  local size = (width >= BIG_W and height >= BIG_H) and BIG or SMALL
  local PAD = size.pad
  local SUMMARY_Y = math.floor(SHEET_Y + (height - 2 * SHEET_Y) * BAND) + BAND_GAP
  local TOP = SUMMARY_Y + SUMMARY_H
  local w = math.floor((width - 2 * PAD - GAP) / 2)
  ui.summary:ClearAllPoints()
  ui.summary:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -SUMMARY_Y)
  ui.summary:SetWidth(width - 2 * PAD)
  local list, y = ns.Regions.LIST, TOP
  for i = 1, #list, 2 do
    local last = math.min(i + 1, #list)
    local rowH = size.locked
    for j = i, last do
      if list[j].open then rowH = size.open end
    end
    for j = i, last do
      local card = ui.cards[list[j].id]
      card.frame:ClearAllPoints()
      card.frame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (j - i) * (w + GAP), -y)
      card.frame:SetSize(w, rowH)
      if card.slots then placeOpen(card, size, w) end
    end
    y = y + rowH + GAP
  end
end

local BookTab = {}
ns.BookTab = BookTab

local function fillOpen(card, region, ctx)
  local have = 0
  for _, s in ipairs(card.slots) do
    s.found = ctx.found[s.relic]
    if s.found then
      have = have + 1
      s.icon:Show()
    else
      s.icon:Hide()
    end
    local n = ns.StackCount("relic", s.relic)
    s.count:SetText(n >= 1 and tostring(n) or "")
  end
  card.relicWords:SetText(have .. " of " .. #card.slots .. " Relics")

  local set = setFor(region.id)
  card.setLine:SetText(set.name .. " " .. ns.SetOwned(region.id) .. " of " .. #set.pieces)
  local map = ctx.maps[region.id]
  card.mapLine:SetText("Map: " .. (map and "Found" or "Not Found"))

  local held = ctx.held[region.id]
  if held then
    local row = ns.GearData.Row(held.row)
    card.heldLine:SetText(row.name .. " (" .. ns.W.Quality(row.q) .. ")")
    card.heldLine:SetTextColor(rgb(INK_QUALITY[row.q] or INK))
    card.heldHint:SetText(ns.W.Name["Company bag"] .. " is full. Free a slot.")
  else
    card.heldLine:SetText("")
    card.heldHint:SetText("")
  end
  card.badge:SetText(ctx.badges[region.id] and (region.name .. " Antiquarian") or "")
  return map and 1 or 0
end

function BookTab.Refresh(f)
  local ui = f.book
  place(f)
  local book = ns.Collection()
  local ctx = { found = asKeys(book.relics), badges = asKeys(book.badges), held = {},
    maps = asKeys(ns.HeldMaps and ns.HeldMaps() or {}) }
  for _, h in ipairs(ns.HeldEpics()) do
    ctx.held[h.region] = ctx.held[h.region] or h -- lowest id first
  end
  local maps, regions = 0, 0
  for _, region in ipairs(ns.Regions.LIST) do
    if region.open then
      regions = regions + 1
      maps = maps + fillOpen(ui.cards[region.id], region, ctx)
    end
  end
  ui.summary:SetText("Relics " .. #book.relics .. " of " .. #ns.BookData.relics .. ", Maps " .. maps .. " of " .. regions)
end

local function newSlot(f, card, relic)
  local btn = CreateFrame("Button", nil, card.frame)
  local s = { btn = btn, relic = relic.id, name = relic.name }
  local plate = btn:CreateTexture(nil, "BACKGROUND")
  plate:SetAllPoints(btn)
  plate:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  plate:SetTexCoord(0.1875, 0.8125, 0.1875, 0.8125)
  s.icon = btn:CreateTexture(nil, "ARTWORK")
  s.icon:SetAllPoints(btn)
  s.icon:SetTexture(relic.icon)
  s.count = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  s.count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
  btn:RegisterForClicks("RightButtonUp")
  btn:SetScript("OnEnter", function(self)
    s.hover = true
    if s.found then M.Safe(showTip, self, s) end
  end)
  btn:SetScript("OnLeave", function()
    s.hover = false
    hideTip()
  end)
  btn:SetScript("OnClick", function(self, button)
    if button ~= "RightButton" or not s.found then return end
    M.Safe(function()
      if ns.StackCount("relic", s.relic) < 1 then return end
      local done, why = ns.BreakRelic(s.relic, 1)
      if not done then refuse(why) end
      BookTab.Refresh(f)
      if s.hover then showTip(self, s) end
    end)
  end)
  return s
end

local function newCard(f, region)
  local card = { frame = newFrame(f) }
  card.name = label(card.frame, "GameFontBlack", region.open and INK or SUB_INK)
  card.name:SetText(region.name)
  card.levels = label(card.frame, "GameFontBlackSmall", region.open and LABEL_INK or SUB_INK)
  if not region.open then
    card.name:SetPoint("LEFT", card.frame, "LEFT", INSET, 0)
    card.levels:SetPoint("RIGHT", card.frame, "RIGHT", -INSET, 0)
    card.levels:SetText("Coming Later")
    return card
  end
  card.name:SetPoint("TOPLEFT", card.frame, "TOPLEFT", INSET, HEAD_Y)
  card.levels:SetPoint("TOPRIGHT", card.frame, "TOPRIGHT", -INSET, HEAD_Y)
  card.levels:SetText("Levels " .. region.lo .. "-" .. region.hi .. ", Open")
  card.slots = {}
  for _, relic in ipairs(ns.BookData.relics) do
    if relic.region == region.id then card.slots[#card.slots + 1] = newSlot(f, card, relic) end
  end
  card.relicWords = label(card.frame, "GameFontBlack", INK)
  card.relicWords:SetPoint("LEFT", card.slots[#card.slots].btn, "RIGHT", 8, 0)
  for _, key in ipairs(LINES) do card[key] = label(card.frame, "GameFontBlackSmall", INK) end
  return card
end

function BookTab.Build(f, bar)
  local ui = { cards = {} }
  f.book = ui

  local sheet = f:CreateTexture(nil, "BACKGROUND")
  sheet:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -4)
  sheet:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)
  M.Kit.Atlas(sheet, "loottab-background", { 0.80, 0.70, 0.52, 1 })
  -- The same art once more, additive: the sheet is a mid-tone and ink needs a lighter page.
  local glow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  glow:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -4)
  glow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)
  if M.Kit.Atlas(glow, "loottab-background", nil) then
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.35)
  end

  ui.summary = label(f, "GameFontBlack", INK)
  for _, region in ipairs(ns.Regions.LIST) do ui.cards[region.id] = newCard(f, region) end

  f:SetScript("OnSizeChanged", function(self) M.Safe(place, self) end)
end
