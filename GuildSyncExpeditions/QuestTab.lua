-- GuildSyncExpeditions QuestTab.lua: the Writs page, ns.QuestTab (slice H plan, Seams 3).
--   QuestTab.Build(f, bar)   builds the page inside f; bar is unused and there is no grain display here
--   QuestTab.Refresh(f)      fills and lays out for f's size; reads only, so a bag count at need finishes nothing here
--   QuestTab.frame           f once built; a finished writ refreshes it while it is visible
-- ns.QuestData, ns.OpenWrits and ns.BringCount are read at call time.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local BIG = { row = 96, rowGap = 7, pad = 8, gap = 6, line = 18, side = 44 }
local SMALL = { row = 78, rowGap = 1, pad = 2, gap = 2, line = 14, side = 34 }
local BIG_W, BIG_H = 700, 450
local INDENT, FLAIR_GAP = 8, 6
local SHEET_Y, BAND, BAND_GAP = 4, 48 / 381, 4
local ROWS = 3
local INK, SUB_INK, LABEL_INK = "2b1a0a", "3b2610", "45200a" -- dark ink on the parchment

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function showTip(owner, line)
  if #line.names == 0 then return end
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(line.label, 1, 0.82, 0)
  for _, name in ipairs(line.names) do tip:AddLine(name, 1, 1, 1) end
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function label(parent, font, hex)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetJustifyH("LEFT")
  fs:SetTextColor(rgb(hex))
  return fs
end

local function oneLine(parent, font, hex)
  local fs = label(parent, font, hex)
  fs:SetWordWrap(false)
  return fs
end

local function newRow(f)
  local frame = CreateFrame("Frame", nil, f)
  local r = { frame = frame }
  r.name = oneLine(frame, "GameFontBlack", LABEL_INK)
  r.text = label(frame, "GameFontBlack", INK)
  r.text:SetMaxLines(2)
  r.goal = oneLine(frame, "GameFontBlack", INK)
  r.reward = oneLine(frame, "GameFontBlack", SUB_INK)
  return r
end

local function newFlairLine(f, title)
  local frame = CreateFrame("Frame", nil, f)
  local line = { frame = frame, label = title, names = {} }
  line.text = oneLine(frame, "GameFontBlack", INK)
  line.text:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  frame:EnableMouse(true)
  frame:SetScript("OnEnter", function(self) M.Safe(showTip, self, line) end)
  frame:SetScript("OnLeave", hideTip)
  return line
end

-- "Label: a, b and 3 more", as many names as the width holds, always at least one.
local function fit(line, width)
  local names = line.names
  if #names == 0 then
    line.text:SetText(line.label .. ": None")
    return
  end
  local function write(keep)
    local shown = {}
    for i = 1, keep do shown[i] = names[i] end
    local out = line.label .. ": " .. table.concat(shown, ", ")
    if keep < #names then out = out .. " and " .. (#names - keep) .. " more" end
    line.text:SetText(out)
  end
  local keep = #names
  write(keep)
  while keep > 1 and (line.text:GetStringWidth() or 0) > width do
    keep = keep - 1
    write(keep)
  end
end

local function place(f)
  local ui = f.writs
  local width, height = f:GetWidth(), f:GetHeight()
  local size = (width >= BIG_W and height >= BIG_H) and BIG or SMALL
  local PAD = size.side
  local top = math.floor(SHEET_Y + (height - 2 * SHEET_Y) * BAND) + BAND_GAP
  local rowW = width - 2 * PAD
  local textW = rowW - 2 * INDENT
  local function under(fs, above)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -size.gap)
    fs:SetWidth(textW)
  end
  for i, r in ipairs(ui.rows) do
    r.frame:ClearAllPoints()
    r.frame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(top + (i - 1) * (size.row + size.rowGap)))
    r.frame:SetSize(rowW, size.row)
    r.name:ClearAllPoints()
    r.name:SetPoint("TOPLEFT", r.frame, "TOPLEFT", INDENT, -size.pad)
    r.name:SetWidth(textW)
    under(r.text, r.name)
    under(r.goal, r.text)
    under(r.reward, r.goal)
  end
  ui.empty:ClearAllPoints()
  ui.empty:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + INDENT, -(top + size.pad))
  ui.empty:SetWidth(textW)

  local y = top + ROWS * size.row + (ROWS - 1) * size.rowGap + FLAIR_GAP
  for i, line in ipairs(ui.lines) do
    line.frame:ClearAllPoints()
    line.frame:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + INDENT, -(y + (i - 1) * size.line))
    line.frame:SetSize(textW, size.line)
    line.text:SetWidth(textW)
    fit(line, textW)
  end
  ui.done:ClearAllPoints()
  ui.done:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + INDENT, -(y + #ui.lines * size.line))
  ui.done:SetWidth(textW)
end

-- Where the goods are meant to go, nil until a bank character is known. Escaped: a name is player text.
local function deliverTo()
  local ask = ns.BankRecipient
  if type(ask) ~= "function" then return nil end
  local ok, name = pcall(ask)
  if not ok then return nil end
  name = GuildSync.Compat.Plain(name)
  if type(name) == "string" and name ~= "" then return ns.Escape(name) end
  return nil
end

local function goal(w, open)
  if w.kind == "go" then return "Find " .. w.place end
  if w.kind == "talk" then return "Speak with " .. w.who end
  if w.kind == "kill" then return "Slain: " .. open.progress .. "/" .. w.need end
  local text = w.itemName .. ": " .. math.min(ns.BringCount(w) or 0, w.need) .. "/" .. w.need
  local name = deliverTo()
  if name then text = text .. ". Deliver to " .. name end
  return text
end

local function titleName(D, id)
  if D.BY_ID[id] then return D.BY_ID[id].flairName end
  for _, s in ipairs(D.STORY_TITLES) do
    if s.id == id then return s.name end
  end
  return nil
end

local function namesOf(ids, name)
  local out = {}
  for _, id in ipairs(ids) do out[#out + 1] = name(id) end
  return out
end

local QuestTab = {}
ns.QuestTab = QuestTab

function QuestTab.Refresh(f)
  local D = ns.QuestData
  local ui = f.writs
  local open = ns.OpenWrits()
  for i, r in ipairs(ui.rows) do
    local row = open[i]
    if row then
      local w = D.BY_ID[row.id]
      r.name:SetText(w.name)
      r.text:SetText(w.text)
      r.goal:SetText(goal(w, row))
      local trophy = w.trophyName ~= w.flairName and ", " .. w.trophyName or ""
      r.reward:SetText("Reward: " .. w.flairName .. ", " .. w.lookName .. trophy)
      r.frame:Show()
    else
      r.frame:Hide()
    end
  end
  if #open == 0 then ui.empty:Show() else ui.empty:Hide() end

  local flair = ns.Flair()
  ui.lines[1].names = namesOf(ns.EarnedTitles(), function(id) return titleName(D, id) end)
  ui.lines[2].names = namesOf(flair.badges, function(id) return D.BY_ID[id].flairName end)
  ui.lines[3].names = namesOf(flair.trophies, function(id) return D.BY_ID[id].trophyName end)
  ui.done:SetText("Writs done: " .. flair.quests)
  place(f)
end

function QuestTab.Build(f, bar)
  local ui = { rows = {}, lines = {} }
  f.writs = ui
  QuestTab.frame = f

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

  for i = 1, ROWS do ui.rows[i] = newRow(f) end
  ui.empty = oneLine(f, "GameFontBlack", SUB_INK)
  ui.empty:SetText("You carry no writs. An expedition may bring one.")
  for i, title in ipairs({ "Titles", "Badges", "Trophies" }) do ui.lines[i] = newFlairLine(f, title) end
  ui.done = oneLine(f, "GameFontBlack", LABEL_INK)

  f:SetScript("OnSizeChanged", function(self) M.Safe(place, self) end)
end
