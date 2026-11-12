-- GuildSyncExpeditions GranaryDoor.lua: the Granary on the camp, ns.GranaryDoor (0.19 plan, slice V3).
--   GranaryDoor.Build(f)   the door on f, the 726 x 508 box Page.lua scales; Camp.Build calls it
-- f.granary = button with art, hl, label, lock. It is not one of the camp's places.
-- The door reads Games' two facts and opens Games on its Company tab, nothing more. The facts are read fresh every time:
-- the look on Build and OnShow, the tooltip on hover, the gate on click. Without both facts the door is locked.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local NAME = "Granary"
local ATLAS = "GarrBuilding_Farm_1_H_Map"
local ICON = "Interface\\Icons\\INV_Misc_Bag_11"
local DOOR_W, DOOR_H = 108, 94
local DOOR_X, DOOR_Y = 85, 175
local LOCK_W, LOCK_H = 20, 26
local LOCK_Y = 32
local LOCK_FILL = { 0.85, 0.72, 0.25, 1 }
local LOCKED_TINT = 0.75

-- goal, pct; nil when the door is locked. A percent of 0 is open.
local function facts()
  local goal = M.Fact("games", "granarygoal")
  local pct = M.Fact("games", "granarypct")
  if type(goal) == "string" and type(pct) == "number" then return goal, pct end
  return nil
end

local function tint(tex, shade, locked)
  tex:SetVertexColor(shade, shade, shade)
  if tex.SetDesaturated then tex:SetDesaturated(locked) end
end

local function drawLook(b)
  local locked = not facts()
  local shade = locked and LOCKED_TINT or 1
  tint(b.art, shade, locked)
  tint(b.hl, shade, locked)
  b.lock:SetShown(locked)
end

local function showTip(owner)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(NAME)
  local goal, pct = facts()
  if goal then
    tip:AddLine(goal == "done" and "All projects rebuilt" or ns.Escape(goal), 1, 1, 1)
    tip:AddDoubleLine("Guild goal", pct .. "%")
    tip:AddLine("<Click to open in Games>", 0.1, 1, 0.1)
  else
    tip:AddLine("Requires Games", 1, 0.1, 0.1)
  end
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

-- The answer is ignored: a door that cannot open stays quiet.
local function open()
  if not facts() then return end
  if type(M.OpenModule) ~= "function" then return end
  M.Safe(M.OpenModule, "games", "company")
end

local GranaryDoor = {}
ns.GranaryDoor = GranaryDoor

function GranaryDoor.Build(f)
  local b = CreateFrame("Button", nil, f)
  b:SetSize(DOOR_W, DOOR_H)
  b:SetPoint("CENTER", f, "TOPLEFT", DOOR_X, -DOOR_Y)

  b.art = b:CreateTexture(nil, "ARTWORK")
  b.art:SetAllPoints(b)
  M.Kit.Atlas(b.art, ATLAS, ICON)

  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints(b)
  M.Kit.Atlas(b.hl, ATLAS, ICON)
  b.hl:SetBlendMode("ADD")
  b.hl:SetAlpha(0.3)

  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  -- outlined, so the name stays readable on the pale plan
  local file, size = b.label:GetFont()
  if file then b.label:SetFont(file, size, "OUTLINE") end
  b.label:SetPoint("TOP", b, "TOP", 0, -(DOOR_H - 12))
  b.label:SetText(NAME)

  b.lock = b:CreateTexture(nil, "OVERLAY")
  b.lock:SetSize(LOCK_W, LOCK_H)
  b.lock:SetPoint("CENTER", b, "TOP", 0, -LOCK_Y)
  M.Kit.Atlas(b.lock, "worldquest-tracker-lock", LOCK_FILL)
  b.lock:Hide()

  b:SetScript("OnClick", function() M.Safe(open) end)
  b:SetScript("OnEnter", function(self) M.Safe(showTip, self) end)
  b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  b:SetScript("OnShow", function(self) M.Safe(drawLook, self) end)

  f.granary = b
  drawLook(b)
end
