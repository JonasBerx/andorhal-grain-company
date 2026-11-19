-- GuildSyncExpeditions ShopTab.lua: the Quartermaster, ns.ShopTab (0.19 plan, Seams 9).
--   ShopTab.Build(f, bar)   builds the page inside f; bar is unused and there is no grain display here
--   ShopTab.Refresh(f, opts) lays out for f's size and refills the rows; opts.supplies (ns.GoTo("quartermaster",
--                           { supplies = true })) opens the Supplies tab
-- Two views share one 2-column grid: the gear wares (the tier and quality tabs pick them) and the Supplies tab, which
-- shows only the supplies on sale (GC.SupplyOnSale). The gear wares are the first view. The green (Uncommon) tab shows
-- only once the Forge is open; the quality tabs shown stand at the band's right end. Prices are GC.ShopPrice.
-- ns.GearCore, ns.GearData and ns.W are read at call time: ns.W loads after this file.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local BIG = { row = 42, icon = 37, pad = 28 }
local SMALL = { row = 31, icon = 28, pad = 22 }
local BIG_W, BIG_H = 700, 450
local GAP = 12
local SHEET_Y, BAND, BAND_GAP = 4, 48 / 381, 4 -- the sheet's top inset; the art's header strip is 48 of its 381 px
local TAB_W, TAB_H, TAB_X, TAB_Y = 84, 22, 22, -8
local RIGHT_W = 100 -- price, wheat and Buy at the row's right end
local WHEAT = 134058
local QUALITIES = { 0, 1, 2 }
local INK, SUB_INK = "2b1a0a", "3b2610" -- dark ink on the parchment

local SLOT_LABEL = { head = "Head", neck = "Neck", shoulder = "Shoulder", back = "Back", chest = "Chest",
  wrist = "Wrist", hands = "Hands", waist = "Waist", legs = "Legs", feet = "Feet", finger = "Finger",
  trinket = "Trinket", mainhand = "Main Hand", offhand = "Off Hand" }

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- At least 1, so the first tier stays open with no follower.
local function reach()
  local top = 1
  for _, x in ipairs(ns.Followers()) do top = math.max(top, x.level) end
  return top
end

local function showTip(owner, row)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  local GC, W = ns.GearCore, ns.W
  local need = GC.WearLevel(row.tier)
  local r, g, b = rgb(GC.QUALITY_COLOUR[row.q])
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(row.name, r, g, b)
  tip:AddLine(SLOT_LABEL[GC.KIND[row.slot]], 1, 1, 1)
  tip:AddLine(W.Name["piece value"] .. " " .. GC.Value({ row = row.code }), 1, 0.82, 0)
  ns.BagGrid.StatLines(tip, { row = row.code })
  tip:AddLine(W.Requires(need, reach() >= need), 1, 1, 1)
  local sell = GC.Sellable(row) -- nil for green: it sells as a drop does
  if sell and sell > 0 then tip:AddLine("Sell Price: " .. sell .. " grain", 1, 1, 1) end
  ns.BagGrid.Compare(tip, { row = row.code, temper = 0 })
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
  elseif why == "short" or why == "no purse" or why == "suite" or why == "busy" or why == "failed" then
    ns.Say(ns.GrainLine(why))
  else
    ns.Say("Cannot buy that now.")
  end
end

local function edge(frame, a, b, across)
  local t = frame:CreateTexture(nil, "BORDER")
  t:SetPoint(a, frame, a, 0, 0)
  t:SetPoint(b, frame, b, 0, 0)
  if across then t:SetHeight(1) else t:SetWidth(1) end
  return t
end

local function newRow(f)
  local frame = CreateFrame("Frame", nil, f)
  local r = { frame = frame, btn = CreateFrame("Button", nil, frame) }
  r.btn:SetPoint("LEFT", frame, "LEFT", 2, 0)
  local plate = r.btn:CreateTexture(nil, "BACKGROUND")
  plate:SetAllPoints(r.btn)
  plate:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  plate:SetTexCoord(0.1875, 0.8125, 0.1875, 0.8125)
  r.icon = r.btn:CreateTexture(nil, "ARTWORK")
  r.icon:SetAllPoints(r.btn)
  r.edges = { edge(frame, "TOPLEFT", "TOPRIGHT", true), edge(frame, "BOTTOMLEFT", "BOTTOMRIGHT", true),
    edge(frame, "TOPLEFT", "BOTTOMLEFT"), edge(frame, "TOPRIGHT", "BOTTOMRIGHT") }
  r.name = frame:CreateFontString(nil, "OVERLAY", "GameFontBlack")
  r.name:SetPoint("TOPLEFT", r.btn, "TOPRIGHT", 6, -1)
  r.name:SetJustifyH("LEFT")
  r.name:SetWordWrap(false)
  r.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
  r.sub:SetPoint("BOTTOMLEFT", r.btn, "BOTTOMRIGHT", 6, 1)
  r.sub:SetJustifyH("LEFT")
  r.sub:SetWordWrap(false)
  r.buy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  r.buy:SetSize(44, 22)
  r.buy:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
  r.buy:SetText("Buy")
  local wheat = frame:CreateTexture(nil, "ARTWORK")
  wheat:SetSize(14, 14)
  wheat:SetTexture(WHEAT)
  wheat:SetPoint("RIGHT", r.buy, "LEFT", -4, 0)
  r.price = frame:CreateFontString(nil, "OVERLAY", "GameFontBlack")
  r.price:SetPoint("RIGHT", wheat, "LEFT", -2, 0)
  return r
end

local function fill(r, icon, name, sub, price, hex)
  local red, green, blue = rgb(hex)
  r.icon:SetTexture(icon)
  r.name:SetText(name)
  r.name:SetTextColor(rgb(INK))
  r.sub:SetText(sub)
  r.sub:SetTextColor(rgb(SUB_INK))
  r.price:SetText(price)
  r.price:SetTextColor(rgb(INK))
  for _, t in ipairs(r.edges) do t:SetColorTexture(red, green, blue) end
end

local function place(f)
  local ui = f.shop
  local width, height = f:GetWidth(), f:GetHeight()
  local size = (width >= BIG_W and height >= BIG_H) and BIG or SMALL
  local PAD = size.pad
  local TOP = math.floor(SHEET_Y + (height - 2 * SHEET_Y) * BAND) + BAND_GAP
  local w = math.floor((width - 2 * PAD - GAP) / 2)
  local pitch = size.row + 2
  local textW = w - size.icon - 8 - RIGHT_W
  local function put(r, col, y)
    r.frame:ClearAllPoints()
    r.frame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + col * (w + GAP), -y)
    r.frame:SetSize(w, size.row)
    r.btn:SetSize(size.icon, size.icon)
    r.name:SetWidth(textW)
    r.sub:SetWidth(textW)
  end
  local n = 0
  for _, list in ipairs({ ui.wares, ui.supplies }) do
    for _, r in ipairs(list) do
      if not r.off then
        put(r, n % 2, TOP + math.floor(n / 2) * pitch)
        n = n + 1
      end
    end
  end
  local tabY = TOP - BAND_GAP - TAB_H - 6
  for i, b in ipairs(ui.tierTabs) do
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (TAB_W + 4), -tabY)
  end
  ui.supplyTab:ClearAllPoints()
  ui.supplyTab:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + #ui.tierTabs * (TAB_W + 4), -tabY)
  local right = 0
  for i = #ui.qualityTabs, 1, -1 do
    local b = ui.qualityTabs[i]
    b:ClearAllPoints()
    b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - right * (TAB_W + 4), -tabY)
    if b:IsShown() then right = right + 1 end
  end
end

local ShopTab = {}
ns.ShopTab = ShopTab

function ShopTab.Refresh(f, opts)
  local GC, GD = ns.GearCore, ns.GearData
  local ui = f.shop
  if type(opts) == "table" and opts.supplies then ui.supplyView = true end
  local gear = not ui.supplyView
  local level, tier = reach(), 1
  for t, b in ipairs(ui.tierTabs) do
    local open = level >= GC.WearLevel(t)
    b:SetEnabled(open)
    if open then tier = t end
  end
  if ui.pick and level >= GC.WearLevel(ui.pick) then tier = ui.pick end
  for t, b in ipairs(ui.tierTabs) do
    if gear and t == tier then b:LockHighlight() else b:UnlockHighlight() end
  end
  if gear then ui.supplyTab:UnlockHighlight() else ui.supplyTab:LockHighlight() end
  local GREEN = GC.GREEN
  local open = { [0] = true } -- the qualities this tier has on sale; green only with the Forge (ns.OnSale)
  for _, r in ipairs(ui.wares) do
    for k = 1, GREEN do open[k] = open[k] or ns.OnSale(GD.Find(r.slot, tier, k)) end
  end
  local forge = false -- the green tab shows while some tier sells green, which is while the Forge is open
  for t = 1, #ui.tierTabs do forge = forge or ns.OnSale(GD.Find(ui.wares[1].slot, t, GREEN)) end
  local q = ui.q -- never written back, so White is the default again once it opens
  if q == GREEN and not open[GREEN] then q = 1 end
  if q == 1 and not open[1] then q = 0 end
  for i, b in ipairs(ui.qualityTabs) do
    b:SetShown(QUALITIES[i] ~= GREEN or forge)
    b:SetEnabled(open[QUALITIES[i]] == true)
    if gear and QUALITIES[i] == q then b:LockHighlight() else b:UnlockHighlight() end
  end
  for _, r in ipairs(ui.wares) do
    local row = GD.Find(r.slot, tier, q)
    r.off = not gear or not ns.OnSale(row)
    if r.off then
      r.row = nil
      r.frame:Hide()
    else
      r.row = row
      fill(r, row.icon, row.name, SLOT_LABEL[GC.KIND[row.slot]], GC.ShopPrice(row), GC.QUALITY_COLOUR[row.q])
      r.frame:Show()
    end
  end
  for _, r in ipairs(ui.supplies) do
    r.off = gear or not GC.SupplyOnSale(r.supply, ns.Opened)
    if r.off then r.frame:Hide() else r.frame:Show() end
    r.buy:SetEnabled(ns.BuySupply ~= nil)
  end
  place(f)
end

local function tab(f, text, onClick)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(TAB_W, TAB_H)
  b:SetText(text)
  b:SetScript("OnClick", function()
    M.Safe(function()
      onClick()
      ShopTab.Refresh(f)
    end)
  end)
  return b
end

function ShopTab.Build(f, bar)
  local GC, W = ns.GearCore, ns.W
  local ui = { q = 1, tierTabs = {}, qualityTabs = {}, wares = {}, supplies = {} }
  f.shop = ui

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

  for i, key in ipairs({ "T1", "T2" }) do
    local b = tab(f, W.Name[key], function() ui.pick, ui.supplyView = i, nil end)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", TAB_X + (i - 1) * (TAB_W + 4), TAB_Y)
    ui.tierTabs[i] = b
  end
  for i, q in ipairs(QUALITIES) do
    local b = tab(f, W.Quality(q), function() ui.q, ui.supplyView = q, nil end)
    b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -TAB_X - (#QUALITIES - i) * (TAB_W + 4), TAB_Y)
    ui.qualityTabs[i] = b
  end

  local seen = {}
  for _, s in ipairs(ns.GearData.SLOTS) do
    local kind = GC.KIND[s.key]
    if not seen[kind] then
      seen[kind] = true
      local r = newRow(f)
      r.slot = s.key
      local function enter(self)
        if r.row then M.Safe(showTip, self, r.row) end
      end
      r.frame:EnableMouse(true)
      r.frame:SetScript("OnEnter", enter)
      r.frame:SetScript("OnLeave", hideTip)
      r.btn:SetScript("OnEnter", enter)
      r.btn:SetScript("OnLeave", hideTip)
      r.buy:SetScript("OnClick", function()
        if not r.row then return end -- Refresh has not filled this row yet
        M.Safe(function()
          local id, why, said = ns.Buy(r.row.code)
          if not id and not said then refuse(why) end
        end)
      end)
      ui.wares[#ui.wares + 1] = r
    end
  end

  ui.supplyTab = tab(f, "Supplies", function() ui.supplyView = true end)
  ui.supplyTab:SetPoint("TOPLEFT", f, "TOPLEFT", TAB_X + #ui.tierTabs * (TAB_W + 4), TAB_Y)
  for i, s in ipairs(GC.SHOP_SUPPLIES) do
    local r = newRow(f)
    local id = s.id
    r.supply = s
    fill(r, s.icon, s.name, s.note, s.price, "ffffff")
    r.buy:SetScript("OnClick", function()
      if not ns.BuySupply then return end
      M.Safe(function()
        local done, why, said = ns.BuySupply(id)
        if not done and not said then refuse(why) end
      end)
    end)
    ui.supplies[i] = r
  end

  f:SetScript("OnSizeChanged", function(self) M.Safe(place, self) end)
end
