-- GuildSyncExpeditions CampSoon.lua: the camp's five ladder buildings, ns.CampSoon (0.19 plan, slice V2; issue 6).
--   CampSoon.Build(f)     the five buildings on f, the 726 x 508 box Page.lua scales
--   CampSoon.Refresh(f)   greys and locks each building again, or opens it; Camp.Refresh calls it
-- f.soon = { [key] = button }, each button with art, hl, lock, label, and fx once clicked.
-- Each building has an influence step (unlock) and the place it opens (opens, a ns.GoTo place). While ns.Opened(unlock)
-- is false it is greyed and locked, its tooltip names the Games project that opens it (or a later update, for a step
-- reached before its content shipped), and a click shakes it. Once open, a click calls ns.GoTo(opens, opts). Nothing is saved.
-- ns.Opened, ns.Unlocked and ns.InfluenceCore are read at call time: Influence.lua loads after this file.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local SOON_W = 108
local LOCK_ATLAS = "worldquest-tracker-lock"
local LOCK_FILL = { 0.85, 0.72, 0.25, 1 } -- for a client without the lock atlas, as MapTab's locked zones
local SHAKE_X = { -5, 10, -9, 7, -3 } -- each step's move; they sum to 0, so the building ends where it began
local SHAKE_S = 0.08
local LOCKED_SHADE = 0.95

local SOON = {
  { key = "mill", name = "Mill", atlas = "GarrBuilding_LumberMill_1_H_Map", x = 345, y = 130, h = 80,
    icon = "Interface\\Icons\\INV_Misc_Food_59", unlock = "supplies", opens = "quartermaster", opts = { supplies = true },
    about = "More supplies at the Quartermaster.", click = "<Click to open the Quartermaster's supplies>" },
  { key = "apothecary", name = "Apothecary", atlas = "GarrBuilding_Alchemy_1_H_Map", x = 245, y = 262, h = 79,
    icon = "Interface\\Icons\\Trade_Alchemy", unlock = "apothecary", opens = "quartermaster",
    about = "Herbs and charms for the road.", click = "<Click to open the Quartermaster>" },
  { key = "tavern", name = "Tavern", atlas = "GarrBuilding_Inn_1_H_Map", x = 345, y = 345, h = 88,
    icon = "Interface\\Icons\\INV_Drink_05", unlock = "tavern", opens = "writs",
    about = "A fourth writ fits on the board.", click = "<Click to open Writs>" },
  { key = "forge", name = "Forge", atlas = "GarrBuilding_Blacksmith_1_H_Map", x = 508, y = 298, h = 78,
    icon = "Interface\\Icons\\Trade_BlackSmithing", unlock = "forge", opens = "quartermaster",
    about = "Green gear at the Quartermaster.", click = "<Click to open the Quartermaster>" },
  { key = "arena", name = "Arena", atlas = "GarrBuilding_SparringArena_2_H_Map", x = 105, y = 392, h = 76,
    icon = "Interface\\Icons\\INV_Sword_04", unlock = "arena", opens = "guild",
    about = "See how the guild's followers fare.", click = "<Click to open Guild>" },
}

local function opened(row)
  return type(ns.Opened) == "function" and ns.Opened(row.unlock) == true
end

-- goal, pct, as GranaryDoor.lua reads Games' facts; nil without Games.
local function granary()
  local goal, pct = M.Fact("games", "granarygoal"), M.Fact("games", "granarypct")
  if type(goal) == "string" and type(pct) == "number" then return goal, pct end
  return nil
end

-- A step reached before its content shipped names no project: the project is already built.
local function lockedTip(tip, row)
  if type(ns.Unlocked) == "function" and ns.Unlocked(row.unlock) then
    tip:AddLine("Coming with a later update.", 0.62, 0.62, 0.62)
    return
  end
  local IC = ns.InfluenceCore
  local need = IC and IC.Need(row.unlock)
  local project = need and IC.Project(need)
  if project then tip:AddLine("Opens when the Company finishes: " .. project, 0.62, 0.62, 0.62) end
  local goal, pct = granary()
  if not goal then
    tip:AddLine("Requires Games", 1, 0.1, 0.1)
  elseif goal ~= "done" then
    tip:AddLine("Granary: " .. pct .. "% of " .. ns.Escape(goal), 1, 1, 1)
  end
end

local function showTip(owner, row)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(row.name)
  if opened(row) then
    tip:AddLine(row.about, 1, 1, 1)
    tip:AddLine(row.click, 0.1, 1, 0.1)
  else
    lockedTip(tip, row)
  end
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

-- Greyed with the lock, or in full colour without it. After the atlas, so a fallback icon is grey too.
local function drawLook(b, row)
  local open = opened(row)
  local shade = open and 1 or LOCKED_SHADE
  b.art:SetDesaturated(not open)
  b.art:SetVertexColor(shade, shade, shade)
  b.hl:SetDesaturated(not open)
  b.lock:SetShown(not open)
end

-- Read fresh, so a building opened since the last Refresh opens on its first click: ns.Opened reads the stored latch,
-- so a click raises it from Games first (one read per click, not per draw).
local function click(b, row)
  if type(ns.Influence) == "function" then ns.Influence() end
  if not opened(row) then return shake(b) end
  if type(ns.GoTo) == "function" then ns.GoTo(row.opens, row.opts) end
end

local function newBuilding(f, row)
  local b = CreateFrame("Button", nil, f)
  b:SetSize(SOON_W, row.h)
  b:SetPoint("CENTER", f, "TOPLEFT", row.x, -row.y)

  b.art = b:CreateTexture(nil, "ARTWORK")
  b.art:SetAllPoints(b)
  M.Kit.Atlas(b.art, row.atlas, row.icon)

  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints(b)
  M.Kit.Atlas(b.hl, row.atlas, row.icon)
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

  M.Safe(drawLook, b, row)
  b:SetScript("OnClick", function(self) M.Safe(click, self, row) end)
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

function CampSoon.Refresh(f)
  if type(f.soon) ~= "table" then return end
  for _, row in ipairs(SOON) do
    if f.soon[row.key] then drawLook(f.soon[row.key], row) end
  end
end
