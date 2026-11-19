-- GuildSyncExpeditions TalentWindow.lua: the follower talent window (issue 13 spec, "Window", build step 4).
--   ns.TalentWindow.Open(owner, fid)     opens the window beside owner (the Followers tab frame) for that follower;
--                                        open on the same follower already, it closes instead (the Talents button)
--   ns.TalentWindow.Follow(owner, fid)   while open on owner: shows fid (nil closes); CharacterTab.Refresh calls it
--   ns.TalentWindow.Close()              drops the preview and hides; safe before the window is built
--   ns.TalentWindow.State() -> S         the window's parts, for the page test
-- The rules are TalentCore's and Talents.lua's; this file only shows them. A click asks ns.PreviewAdd / PreviewTake,
-- the foot asks ns.Learn / ns.ResetTalents / ns.PreviewCancel. A Learn or Reset that went through refreshes the
-- owner (CharacterTab.Refresh), so its Power, card marker and header line follow. Closing drops the preview: what
-- was not learned is gone. Texts are ns.W.Talent and ns.W.TalentFx (Words.lua). Every ns.* is read at call time.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local PANEL_W, PANEL_H = 300, 520
local SIDE_GAP, TOP_NUDGE = 16, 0 -- beside the owner's right edge
local LEVEL_ABOVE = 40
local TEXT_X, TEXT_W = 16, 268
local TREE_Y, WHO_Y, POINTS_Y = 14, 36, 54
local GRID_X, GRID_Y, CELL, ICON = 30, 76, 60, 40
local RANK_X, RANK_Y = 6, -4 -- the rank text's bottom right, from the icon's bottom right
local SHAFT_W, HEAD = 4, 20
local LINE_Y = GRID_Y + 6 * CELL + 6
local BUTTON_H, BUTTON_BOTTOM = 22, 14
local RESET_W, LEARN_W, CANCEL_W, BUTTON_GAP = 124, 64, 64, 8

local ICON_DIR = "Interface\\Icons\\"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local ARROW = "Interface\\TalentFrame\\UI-TalentArrows" -- the classic talent frame's arrow heads
local HEAD_COORDS = { gold = { 0, 0.5, 0, 0.5 }, grey = { 0, 0.5, 0.5, 1 } }

local GREEN, GOLD, GREY = { 0.1, 1, 0.1 }, { 1, 0.82, 0 }, { 0.5, 0.5, 0.5 }
local WHITE, RED, HINT = { 1, 1, 1 }, { 1, 0.13, 0.13 }, { 0.6, 0.6, 0.6 }
local DIM = { 0.6, 0.6, 0.6 } -- a locked icon's vertex colour, on top of desaturating it

-- The amount one rank gives, in the order a text's %d reads it.
local AMOUNT = { "power", "wound", "death", "gear", "broken", "rest", "xp", "grain", "salvage", "raise" }

local S = { cells = {}, arrows = {} }

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function perRank(t)
  for _, field in ipairs(AMOUNT) do
    local v = t.fx[field]
    if type(v) == "number" then return math.abs(v) end
  end
  if type(t.fx.find) == "table" then
    for _, v in pairs(t.fx.find) do return v end
  end
  return 0
end

local function effect(t, rank)
  local text = ns.W.TalentFx[t.id]
  if not text then return t.name end
  return string.format(text, perRank(t) * rank)
end

local function font(parent, template, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY", template)
  return fs
end

local function headText(panel, template, y)
  local fs = font(panel, template)
  fs:SetPoint("TOPLEFT", panel, "TOPLEFT", TEXT_X, -y)
  fs:SetWidth(TEXT_W)
  fs:SetJustifyH("CENTER")
  fs:SetWordWrap(false)
  return fs
end

local function footButton(panel, w, onClick)
  local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  b:SetSize(w, BUTTON_H)
  b:SetScript("OnClick", function() M.Safe(onClick) end)
  return b
end

-- What the follower's talents look like now, or nil when it has none (unknown, or a class with no tree).
local function talents()
  return S.fid and ns.Talents and ns.Talents(S.fid) or nil
end

local function setLine(text, colour)
  S.lineText = text
  S.lineColour = colour
end

-- ---------- Draw ----------

-- "locked" (rank 0 and no rank can go on), "full", or "part" (any other, 0 included while a rank can go on).
local function stateOf(view, t, i)
  local rank = view.preview[i]
  if rank >= t.max then return "full" end
  if rank == 0 and not ns.TalentCore.CanAdd(view.tree, view.preview, i, view.level) then return "locked" end
  return "part"
end

local function drawCell(cell, view, t, i)
  local rank = view.preview[i]
  local state = stateOf(view, t, i)
  cell.state = state
  cell.icon:SetTexture(t.icon and (ICON_DIR .. t.icon) or UNKNOWN_ICON)
  local locked = state == "locked"
  cell.icon:SetDesaturated(locked)
  local tint = locked and DIM or WHITE
  cell.icon:SetVertexColor(tint[1], tint[2], tint[3])
  cell.rank:SetText(rank .. "/" .. t.max)
  local c = (state == "full" and GOLD) or (locked and GREY) or GREEN
  cell.rank:SetTextColor(c[1], c[2], c[3])
  cell:Show()
end

local function newCell(i)
  local cell = CreateFrame("Button", nil, S.grid)
  cell:SetSize(CELL, CELL)
  cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  cell.back = cell:CreateTexture(nil, "BACKGROUND")
  cell.back:SetSize(ICON + 4, ICON + 4)
  cell.back:SetPoint("CENTER", cell, "CENTER", 0, 0)
  cell.back:SetColorTexture(0, 0, 0, 0.6)
  cell.icon = cell:CreateTexture(nil, "ARTWORK")
  cell.icon:SetSize(ICON, ICON)
  cell.icon:SetPoint("CENTER", cell, "CENTER", 0, 0)
  cell.rank = font(cell, "NumberFontNormalSmall")
  cell.rank:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", RANK_X, RANK_Y)
  cell.index = i
  cell:SetScript("OnClick", function(self, which) M.Safe(S.click, self, which) end)
  cell:SetScript("OnEnter", function(self) M.Safe(S.tip, self) end)
  cell:SetScript("OnLeave", function() M.Safe(hideTip) end)
  return cell
end

local function newArrow()
  local a = { shaft = S.grid:CreateTexture(nil, "BORDER"), head = S.grid:CreateTexture(nil, "BORDER", nil, 1) }
  a.shaft:SetWidth(SHAFT_W)
  a.head:SetSize(HEAD, HEAD)
  a.head:SetTexture(ARROW)
  return a
end

-- Straight down one column, from the talent above to the one that needs it: gold once the one above is full.
local function drawArrow(a, upper, lower, full)
  a.head:ClearAllPoints()
  a.head:SetPoint("BOTTOM", lower.icon, "TOP", 0, -4)
  a.shaft:ClearAllPoints()
  a.shaft:SetPoint("TOP", upper.icon, "BOTTOM", 0, 0)
  a.shaft:SetPoint("BOTTOM", a.head, "CENTER", 0, 0)
  local c = full and GOLD or GREY
  a.shaft:SetColorTexture(c[1], c[2], c[3], 1)
  local coords = HEAD_COORDS[full and "gold" or "grey"]
  a.head:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
  a.state = full and "gold" or "grey"
  a.from, a.to = upper.index, lower.index
  a.shaft:Show()
  a.head:Show()
end

local function draw()
  local T, TC = ns.W.Talent, ns.TalentCore
  local x = S.fid and ns.Follower(S.fid)
  local t = talents()
  if not x or not t then
    S.panel:Hide()
    return
  end
  local tree = t.tree
  local view = { tree = tree, preview = t.preview, level = x.level }
  S.treeText:SetText(tree.name)
  S.whoText:SetText(string.format(T.who, ns.Escape(x.name), x.level, x.class))
  S.pointsText:SetText(string.format(T.points, t.left, TC.Spent(tree, t.preview), tree.name))

  local byId = {}
  for i, talent in ipairs(tree.talents) do
    local cell = S.cells[i] or newCell(i)
    S.cells[i] = cell
    cell:ClearAllPoints()
    cell:SetPoint("TOPLEFT", S.grid, "TOPLEFT", (talent.col - 1) * CELL, -(talent.tier - 1) * CELL)
    drawCell(cell, view, talent, i)
    byId[talent.id] = i
  end
  for i = #tree.talents + 1, #S.cells do S.cells[i]:Hide() end

  local n = 0
  for i, talent in ipairs(tree.talents) do
    local j = talent.needs and byId[talent.needs]
    if j then
      n = n + 1
      S.arrows[n] = S.arrows[n] or newArrow()
      drawArrow(S.arrows[n], S.cells[j], S.cells[i], t.preview[j] >= tree.talents[j].max)
    end
  end
  for k = n + 1, #S.arrows do
    S.arrows[k].shaft:Hide()
    S.arrows[k].head:Hide()
    S.arrows[k].state = nil
  end

  local price = ns.TalentResetPrice(S.fid) or 0
  S.reset:SetText(price > 0 and string.format(T.resetPrice, price) or T.reset)
  S.line:SetText(S.lineText or T.hint)
  local c = S.lineColour or HINT
  S.line:SetTextColor(c[1], c[2], c[3])
end

-- ---------- The tooltip ----------

function S.tip(cell)
  local t = talents()
  local talent = t and t.tree.talents[cell.index]
  local tip = talent and M.Compat.Tooltip()
  if not tip then return end
  local T, TC = ns.W.Talent, ns.TalentCore
  local rank = t.preview[cell.index]
  tip:SetOwner(cell, "ANCHOR_RIGHT")
  tip:SetText(talent.name, WHITE[1], WHITE[2], WHITE[3])
  tip:AddLine(string.format(T.rank, rank, talent.max), WHITE[1], WHITE[2], WHITE[3])
  local need = TC.TierNeed(talent.tier)
  if TC.Above(t.tree, t.preview, talent.tier) < need then
    tip:AddLine(string.format(T.tier, need, t.tree.name), RED[1], RED[2], RED[3])
  end
  local j = talent.needs and TC.Index(t.tree, talent.needs)
  if j and t.preview[j] < t.tree.talents[j].max then
    local above = t.tree.talents[j]
    tip:AddLine(string.format(above.max == 1 and T.needsOne or T.needs, above.max, above.name), RED[1], RED[2], RED[3])
  end
  tip:AddLine(effect(talent, math.max(rank, 1)), GOLD[1], GOLD[2], GOLD[3], true)
  if rank > 0 and rank < talent.max then
    tip:AddLine(" ")
    tip:AddLine(T.nextRank, WHITE[1], WHITE[2], WHITE[3])
    tip:AddLine(effect(talent, rank + 1), GOLD[1], GOLD[2], GOLD[3], true)
  end
  tip:Show()
end

-- ---------- Clicks ----------

local function refuse(why, none)
  local R = ns.W.Talent.refuse
  local text
  if why == "none" then
    text = R[none]
  elseif R[why] then
    text = R[why]
  elseif why == "short" or why == "no purse" then
    text = ns.GrainLine(why)
  else
    text = R.other
  end
  setLine(text, RED)
end

-- A Learn or Reset changed the build: the Followers tab shows it too.
local function changed()
  setLine(nil)
  if S.owner and ns.CharacterTab then ns.CharacterTab.Refresh(S.owner) end
  if S.panel:IsShown() then draw() end
end

function S.click(cell, which)
  if not S.fid then return end
  if which == "RightButton" then
    local good, why = ns.PreviewTake(S.fid, cell.index)
    if good then setLine(nil) elseif why == "learned" then refuse(why) end
  else
    if ns.PreviewAdd(S.fid, cell.index) then setLine(nil) end
  end
  draw()
  S.tip(cell)
end

local function learnClick()
  if not S.fid then return end
  local good, why = ns.Learn(S.fid)
  if good then changed() return end
  refuse(why, "learnNone")
  draw()
end

local function resetNow(fid)
  if fid ~= S.fid then return end -- the window moved to another follower while the question was up
  local good, why = ns.ResetTalents(fid)
  if good then changed() return end
  refuse(why, "resetNone")
  if S.panel:IsShown() then draw() end
end

-- Asks first when grain would go; a reset that will be refused (nothing learned, away, the demo) says why at once.
local function resetClick()
  local fid = S.fid
  local x = fid and ns.Follower(fid)
  if not x then return end
  local price = ns.TalentResetPrice(fid) or 0
  if price == 0 or x.state == "out" or M.Demo() then
    resetNow(fid)
    return
  end
  M.Kit.Confirm("expeditions_talent_reset", string.format(ns.W.Talent.ask, ns.Escape(x.name), price), ns.W.Talent.reset,
    function() resetNow(fid) end)
end

local function cancelClick()
  if not S.fid then return end
  ns.PreviewCancel(S.fid)
  setLine(nil)
  draw()
end

-- ---------- Build ----------

local function build(owner)
  local T = ns.W.Talent
  local panel = M.Kit.Card(owner, PANEL_W, PANEL_H)
  panel:EnableMouse(true)
  -- The owner's strata, LEVEL_ABOVE it (Open): one unit with the GuildSync window, never over another addon's panel
  -- that sits above the window (DIALOG did that).
  panel:SetClampedToScreen(true)
  S.panel = panel
  S.treeText = headText(panel, "GameFontNormalLarge", TREE_Y)
  S.whoText = headText(panel, "GameFontHighlight", WHO_Y)
  S.pointsText = headText(panel, "GameFontNormal", POINTS_Y)
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
  close:SetScript("OnClick", function() M.Safe(ns.TalentWindow.Close) end)
  S.close = close

  S.grid = CreateFrame("Frame", nil, panel)
  S.grid:SetPoint("TOPLEFT", panel, "TOPLEFT", GRID_X, -GRID_Y)
  S.grid:SetSize(4 * CELL, 6 * CELL)

  S.line = font(panel, "GameFontHighlightSmall")
  S.line:SetPoint("TOPLEFT", panel, "TOPLEFT", TEXT_X, -LINE_Y)
  S.line:SetWidth(TEXT_W)
  S.line:SetJustifyH("LEFT")

  S.reset = footButton(panel, RESET_W, resetClick)
  S.reset:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", TEXT_X, BUTTON_BOTTOM)
  S.cancel = footButton(panel, CANCEL_W, cancelClick)
  S.cancel:SetText(T.cancel)
  S.cancel:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -TEXT_X, BUTTON_BOTTOM)
  S.learn = footButton(panel, LEARN_W, learnClick)
  S.learn:SetText(T.learn)
  S.learn:SetPoint("RIGHT", S.cancel, "LEFT", -BUTTON_GAP, 0)

  -- Also when the page hides with it: Hide clears the window's own shown flag, so it stays closed after.
  panel:SetScript("OnHide", function(self)
    M.Safe(function()
      if S.fid and ns.PreviewCancel then ns.PreviewCancel(S.fid) end
      S.fid = nil
      setLine(nil)
      hideTip()
      self:Hide()
    end)
  end)
  panel:Hide()
end

-- ---------- The API ----------

local TW = {}
ns.TalentWindow = TW

function TW.State() return S end

function TW.Close()
  if S.panel then S.panel:Hide() end
end

function TW.Open(owner, fid)
  if not fid or not ns.Talents or not ns.Talents(fid) then return end
  if S.panel and S.panel:IsShown() and S.owner == owner and S.fid == fid then
    TW.Close()
    return
  end
  if not S.panel then build(owner) end
  local panel = S.panel
  if S.fid and S.fid ~= fid then ns.PreviewCancel(S.fid) end
  S.owner, S.fid = owner, fid
  setLine(nil)
  panel:SetParent(owner)
  panel:ClearAllPoints()
  panel:SetPoint("TOPLEFT", owner, "TOPRIGHT", SIDE_GAP, TOP_NUDGE)
  panel:SetFrameLevel(owner:GetFrameLevel() + LEVEL_ABOVE)
  panel:Show()
  draw()
end

function TW.Follow(owner, fid)
  if not (S.panel and S.panel:IsShown() and S.owner == owner) then return end
  if not fid or not ns.Talents(fid) then
    TW.Close()
    return
  end
  if fid ~= S.fid then
    ns.PreviewCancel(S.fid)
    S.fid = fid
    setLine(nil)
  end
  draw()
end
