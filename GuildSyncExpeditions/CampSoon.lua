-- GuildSyncExpeditions CampSoon.lua: the camp's four coming-soon buildings, ns.CampSoon (0.19 plan, slice V2).
--   CampSoon.Build(f)   the four greyed buildings on f, the 726 x 508 box Page.lua scales
-- f.soon = { [key] = button }, each button with art, hl, lock, label, and fx once clicked.
-- A building shows a tooltip and shakes when clicked. It opens nothing and saves nothing.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local SOON_W = 108
local LOCK_ATLAS = "worldquest-tracker-lock"
local LOCK_FILL = { 0.85, 0.72, 0.25, 1 } -- for a client without the lock atlas, as MapTab's locked zones
local SHAKE_X = { -5, 10, -9, 7, -3 } -- each step's move; they sum to 0, so the building ends where it began
local SHAKE_S = 0.08

local SOON = {
  { key = "apothecary", name = "Apothecary", atlas = "GarrBuilding_Alchemy_1_H_Map", x = 245, y = 262, h = 79,
    icon = "Interface\\Icons\\Trade_Alchemy" },
  { key = "tavern", name = "Tavern", atlas = "GarrBuilding_Inn_1_H_Map", x = 345, y = 345, h = 88,
    icon = "Interface\\Icons\\INV_Drink_05" },
  { key = "forge", name = "Forge", atlas = "GarrBuilding_Blacksmith_1_H_Map", x = 508, y = 298, h = 78,
    icon = "Interface\\Icons\\Trade_BlackSmithing" },
  { key = "arena", name = "Arena", atlas = "GarrBuilding_SparringArena_2_H_Map", x = 105, y = 392, h = 76,
    icon = "Interface\\Icons\\INV_Sword_04" },
}

local function showTip(owner, row)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(row.name)
  tip:AddLine("Coming soon", 0.62, 0.62, 0.62)
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

-- The group, or false on a client that gives none.
local function newShake(b)
  local fx = b.CreateAnimationGroup and b:CreateAnimationGroup() or false
  if not fx then return false end
  for i, dx in ipairs(SHAKE_X) do
    local step = fx:CreateAnimation("Translation")
    step:SetOffset(dx, 0)
    step:SetDuration(SHAKE_S)
    step:SetOrder(i)
  end
  return fx
end

-- Decoration only: the building's point is set once, at build. rawget because an unset field may read as a method.
local function shake(b)
  if rawget(b, "fx") == nil then b.fx = newShake(b) end
  if not b.fx then return end
  b.fx:Stop()
  b.fx:Play()
end

local function newBuilding(f, row)
  local b = CreateFrame("Button", nil, f)
  b:SetSize(SOON_W, row.h)
  b:SetPoint("CENTER", f, "TOPLEFT", row.x, -row.y)

  b.art = b:CreateTexture(nil, "ARTWORK")
  b.art:SetAllPoints(b)
  M.Kit.Atlas(b.art, row.atlas, row.icon)
  b.art:SetDesaturated(true) -- after the atlas, so a fallback icon is grey too
  b.art:SetVertexColor(0.95, 0.95, 0.95)

  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints(b)
  M.Kit.Atlas(b.hl, row.atlas, row.icon)
  b.hl:SetDesaturated(true)
  b.hl:SetBlendMode("ADD")
  b.hl:SetAlpha(0.25)

  b.lock = b:CreateTexture(nil, "OVERLAY")
  b.lock:SetSize(20, 26)
  b.lock:SetPoint("CENTER", b, "TOPLEFT", SOON_W / 2, -0.34 * row.h)
  M.Kit.Atlas(b.lock, LOCK_ATLAS, LOCK_FILL)

  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  -- outlined, so the name stays readable on the pale plan
  local file, size = b.label:GetFont()
  if file then b.label:SetFont(file, size, "OUTLINE") end
  b.label:SetPoint("TOP", b, "TOP", 0, -(row.h - 11))
  b.label:SetText(row.name)
  b.label:SetTextColor(0.85, 0.82, 0.75)

  b:SetScript("OnClick", function(self) M.Safe(shake, self) end)
  b:SetScript("OnEnter", function(self) M.Safe(showTip, self, row) end)
  b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  return b
end

local CampSoon = {}
ns.CampSoon = CampSoon

function CampSoon.Build(f)
  f.soon = {}
  for _, row in ipairs(SOON) do f.soon[row.key] = newBuilding(f, row) end
end
