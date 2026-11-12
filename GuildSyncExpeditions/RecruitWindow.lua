-- GuildSyncExpeditions RecruitWindow.lua: the recruit choice window (0.19 plan, Seams 16; slice R).
--   ns.ShowPendingRecruit(f) -> true when shown | nil   f optional: else the last frame it was given or ns.BuildPage's
--   ns.HideRecruitWindow()                              hides the window and clears `left`; safe before it is built
--   ns.RecruitColumn.New(parent, x, y, h, stats) -> view   the column look, no button; stats adds Power and kit score
--   ns.RecruitColumn.Fill(view, head, who, fid, nameText, power, score)   ns.RecruitColumn.PERK[race] -> text
-- The window is built once and drawn again on every show. The X keeps the recruit waiting and holds the window closed
-- (`left`) until the page hides or the recruit is answered. Every ns.* it calls is read at call time.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local PANEL_W, PANEL_H = 586, 344
local LEVEL_ABOVE = 40
local BAND_NUDGE = -16 -- centres under V1's 32 px band on the hub page
local COL_X, COL_STEP, COL_Y, COL_W, COL_H = 16, 188, 56, 176, 250
local TEXT_W = 170
local BUTTON_Y, BUTTON_W, BUTTON_H = 310, 170, 22

local RING = "Map_Faction_Ring"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local GREEN = { 0.098, 1, 0.098 }

local PERK = {
  Forsaken = "Undying: 10% less likely to die",
  Orc = "Hardy: 10% less likely to be wounded",
  Tauren = "Steady: 2% less likely to break gear",
  Troll = "Regeneration: rests 1 hour less",
}
local ROAD = { Might = "assaults", Cunning = "scouting", Lore = "rituals" }

local TRAIT_ROWS = 3

local S = { columns = {}, hooked = {} }

-- The round mask, where the client has one (CharacterTab's locals are not exported).
local function circle(owner, tex)
  if not owner.CreateMaskTexture or not tex.AddMaskTexture then return end
  pcall(function()
    local mask = owner:CreateMaskTexture()
    if not mask then return end
    mask:SetAllPoints(tex)
    mask:SetTexture(MASK)
    tex:AddMaskTexture(mask)
  end)
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function showReplaceTip(owner, name)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_TOP")
  tip:SetText("Replace " .. name, 1, 1, 1)
  tip:AddLine(name .. " leaves the Company. Their gear goes to " .. ns.W.Name["Company bag"] .. ".", 1, 1, 1, true)
  tip:Show()
end

-- Replacing dismisses the follower, so it asks first, as Dismiss does.
local function askReplace(view)
  local fid, name = view.fid, view.nameShown
  M.Kit.Confirm("expeditions_replace", "Replace " .. name .. "? Their gear goes to " .. ns.W.Name["Company bag"] .. ".", "Replace", function()
    ns.ReplaceWithRecruit(fid)
  end)
end

local function text(parent, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template)
  fs:SetJustifyH("LEFT")
  return fs
end

-- One font string under another, so a wrap moves what follows.
local function chained(parent, template, above, gap)
  local fs = text(parent, template)
  fs:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -gap)
  fs:SetWidth(TEXT_W)
  return fs
end

local function button(panel, x, label, onClick)
  local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  b:SetSize(BUTTON_W, BUTTON_H)
  b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -BUTTON_Y)
  if label then b:SetText(label) end
  b:SetScript("OnClick", function() M.Safe(onClick) end)
  return b
end

-- A label on the left and its value at the column's right.
local function statRow(col, above, gap)
  local label = above and chained(col, "GameFontNormal", above, gap) or text(col, "GameFontNormal")
  local value = text(col, "GameFontHighlight")
  value:SetJustifyH("RIGHT")
  value:SetPoint("TOPRIGHT", label, "TOPLEFT", TEXT_W, 0)
  return label, value
end

local function newView(parent, x, y, h, stats)
  local col = CreateFrame("Frame", nil, parent)
  col:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  col:SetSize(COL_W, h)

  local view = { frame = col }
  view.head = text(col, "GameFontDisableSmall")
  view.head:SetPoint("TOPLEFT", col, "TOPLEFT", 0, 0)
  view.face = col:CreateTexture(nil, "ARTWORK")
  view.face:SetSize(38, 38)
  view.face:SetPoint("TOPLEFT", col, "TOPLEFT", 6, -20)
  circle(col, view.face)
  local ring = col:CreateTexture(nil, "OVERLAY")
  M.Kit.Atlas(ring, RING, nil)
  ring:SetSize(50, 50)
  ring:SetPoint("TOPLEFT", col, "TOPLEFT", 0, -14)

  view.name = text(col, "GameFontNormal")
  view.name:SetPoint("TOPLEFT", col, "TOPLEFT", 54, -16)
  view.name:SetWidth(TEXT_W - 54)
  view.name:SetWordWrap(false)
  view.level = chained(col, "GameFontHighlightSmall", view.name, 2)
  view.level:SetWidth(TEXT_W - 54)
  view.level:SetWordWrap(false)
  view.class = chained(col, "GameFontHighlightSmall", view.level, 1)
  view.class:SetWidth(TEXT_W - 54)
  view.class:SetWordWrap(false)

  if stats then
    view.power, view.powerValue = statRow(col)
    view.power:SetPoint("TOPLEFT", col, "TOPLEFT", 0, -68)
    view.score, view.scoreValue = statRow(col, view.power, 1)
    view.kind = chained(col, "GameFontHighlightSmall", view.score, 3)
  else
    view.kind = text(col, "GameFontHighlightSmall")
    view.kind:SetPoint("TOPLEFT", col, "TOPLEFT", 0, -68)
    view.kind:SetWidth(TEXT_W)
  end
  view.perk = chained(col, "GameFontHighlightSmall", view.kind, 3)
  view.perk:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
  view.traits = {}
  local above = view.perk
  for t = 1, TRAIT_ROWS do
    view.traits[t] = chained(col, "GameFontHighlightSmall", above, 3)
    view.traits[t]:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    above = view.traits[t]
  end
  return view
end

-- i = 0 is the recruit, 1 and up the reserve followers.
local function newColumn(panel, i)
  local x = COL_X + i * COL_STEP
  local view = newView(panel, x, COL_Y, COL_H, true)
  if i == 0 then
    view.button = button(panel, x, "Turn Away", function() ns.TurnAwayRecruit() end)
  else
    view.button = button(panel, x, nil, function() askReplace(view) end)
    view.button:SetScript("OnEnter", function(self) M.Safe(showReplaceTip, self, view.nameShown) end)
    view.button:SetScript("OnLeave", function() M.Safe(hideTip) end)
  end
  return view
end

local function build(f)
  local panel = M.Kit.Card(f, PANEL_W, PANEL_H)
  panel:EnableMouse(true)
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", panel, "TOP", 0, -12)
  title:SetText("A Recruit Wants to Join")
  local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  sub:SetPoint("TOP", panel, "TOP", 0, -33)
  sub:SetText("Your reserve is full.")
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
  close:SetScript("OnClick", function()
    M.Safe(function()
      S.left = true
      panel:Hide()
    end)
  end)
  S.panel = panel
end

-- who is the spec (the recruit) or a follower row; fid is nil for the recruit.
local function fillColumn(view, head, who, fid, nameText, power, score)
  local D, W = ns.FollowerData, ns.W
  view.fid = fid
  view.nameShown = nameText
  view.head:SetText(head)
  ns.ShowPortrait(view.face, fid or who)
  view.name:SetText(nameText)
  view.level:SetText("Level " .. who.level .. " " .. who.race)
  view.class:SetText(who.class)
  if view.power then
    view.power:SetText("Power")
    view.powerValue:SetText(tostring(power))
    view.score:SetText(W.Name["kit score"])
    view.scoreValue:SetText(tostring(score))
  end
  local kind = D.KIND[who.class]
  view.kind:SetText(kind .. ": +" .. D.AFFINITY .. " Power on " .. ROAD[kind])
  view.perk:SetText(PERK[who.race] or "")
  local n = 0
  for _, id in ipairs(who.traits) do
    local info = ns.TraitInfo(id)
    if info and n < TRAIT_ROWS then
      n = n + 1
      view.traits[n]:SetText(info.name .. ": " .. info.text)
      view.traits[n]:Show()
    end
  end
  for t = n + 1, TRAIT_ROWS do
    view.traits[t]:SetText("")
    view.traits[t]:Hide()
  end
  view.frame:Show()
  if view.button then view.button:Show() end
end

ns.RecruitColumn = { New = newView, Fill = fillColumn, PERK = PERK }

local function draw(spec)
  local D = ns.FollowerData
  S.columns[0] = S.columns[0] or newColumn(S.panel, 0)
  fillColumn(S.columns[0], "Recruit", spec, nil, spec.name, ns.FollowerCore.SpecPower(spec), 0)
  local reserve = {}
  for _, x in ipairs(ns.Followers()) do
    if x.reserve == true and #reserve < D.CAP_RESERVE then reserve[#reserve + 1] = x end
  end
  for i = 1, math.max(#reserve, #S.columns) do
    local x = reserve[i]
    if x then
      S.columns[i] = S.columns[i] or newColumn(S.panel, i)
      local view = S.columns[i]
      local name = ns.Escape(x.name)
      fillColumn(view, "In reserve", x, x.id, name, ns.PowerOf(x.id), ns.KitScore(x.id))
      view.button:SetText("Replace " .. name)
    else
      S.columns[i].frame:Hide()
      S.columns[i].button:Hide()
    end
  end
end

-- Hooked once per frame: a page that hides ends the X's hold.
local function remember(f)
  S.last = f
  if S.hooked[f] then return end
  S.hooked[f] = true
  f:HookScript("OnHide", function() S.left = nil end)
end

function ns.ShowPendingRecruit(f)
  if M.Demo() then
    if S.panel then S.panel:Hide() end
    return nil
  end
  if f then remember(f) else f = S.last end
  if not f or S.left then return nil end
  local spec = ns.PendingRecruit()
  if not spec then
    if S.panel then S.panel:Hide() end
    return nil
  end
  if not S.panel then build(f) end
  local panel = S.panel
  panel:SetParent(f)
  panel:ClearAllPoints()
  panel:SetPoint("CENTER", f, "CENTER", 0, f == S.hub and BAND_NUDGE or 0)
  panel:SetFrameLevel(f:GetFrameLevel() + LEVEL_ABOVE)
  draw(spec)
  panel:Show()
  return true
end

function ns.HideRecruitWindow()
  S.left = nil
  if S.panel then S.panel:Hide() end
end

-- From a login hook, not at file load, so V1 may define or replace ns.BuildPage in any file loaded before login.
ns.LoginHooks[#ns.LoginHooks + 1] = function()
  local real = ns.BuildPage
  if not real then return end
  ns.BuildPage = function(frame)
    S.hub = frame
    remember(frame)
    return real(frame)
  end
end
