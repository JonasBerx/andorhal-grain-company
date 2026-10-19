-- Annals AnnalsJourney: the Journey tab on the Annals page in the GuildSync window (window plan Task 3, an-1 and an-2).
-- A header card (class icon, name in class colour, who line, join line, title, points line, the Legacy points shield),
-- then one section header and one card per month, rows 22 apart with date, tag pill, text and precision. Your own
-- Journey from /annals; someone else's from a name (A.OpenJourney), with Back to your journey.
-- Reaches only ns.AnnalsModule (the seam), ns.AnnalsView and ns.AnnalsRules. State is never saved.
local _, ns = ...
if not (ns.AnnalsModule and ns.AnnalsModule.M) then ns.AnnalsJourney = {} return end

local A, View = ns.AnnalsModule, ns.AnnalsView
local Kit = A.Kit

local T_BACK = "Back to your journey"
local T_ONLY_GUILD = "Only the achievements the whole guild can see count here."
local DOT = " \194\183 "
local TAGS = { level = "Level", rank = "Rank", feat = "Feat", joined = "Joined" }
-- Pill text colours (mock an-1): Level white, Rank gold, Feat orange, Joined blue.
local TONES = { level = { 1, 1, 1 }, rank = { 1, 0.82, 0 }, feat = { 1, 0.55, 0.1 }, joined = { 0.4, 0.7, 1 } }
local GREY = { 0.6, 0.6, 0.6 }

local BACK_W = 160
local BUTTON_H = 22
local GAP = 8
local HEADER_H = 86
local ICON = 40
local SHIELD_W, SHIELD_H = 46, 66
local SECTION_H = 26
local ROW_H = 22
local CARD_PAD = 4
local DATE_X, PILL_X, TEXT_X = 14, 96, 170
local PILL_W = 62
local RIGHT_W = 140
local TEXT_MIN = 80
local TITLE_W = 160 -- the header's right column (title and points line), left of the shield
local LEFT_X = 64

-- guid: whose Journey (nil = yours); opened: the fold keys clicked open.
local state = { guid = nil, opened = {} }
local ui = nil

local function home()
  state.guid = nil
  state.opened = {}
end

local function open(guid)
  state.guid = guid
  state.opened = {}
end

local function grey(fs) fs:SetTextColor(GREY[1], GREY[2], GREY[3]) end

-- Every text is one line cut to its column; the whole texts show in a tooltip on the row or card (tipTitle, tip).
local function tipOn(f)
  if f.EnableMouse then f:EnableMouse(true) end
  A.HoverTip(f, function(self) if self.tipTitle then return self.tipTitle, self.tip end end)
end

local function rightLabel(parent, font, width)
  local fs = A.Label(parent, "", font, width)
  fs:SetJustifyH("RIGHT")
  return fs
end

local function buildHeader(content)
  local card = Kit.Card(content, A.Layout().inner, HEADER_H)
  if not card then return nil end
  local h = { card = card }
  h.icon = card:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(ICON, ICON)
  h.icon:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -12)
  h.name = A.Label(card, "", "GameFontNormalLarge")
  h.name:SetPoint("TOPLEFT", card, "TOPLEFT", 64, -12)
  h.who = A.Label(card, "", "GameFontHighlight")
  h.who:SetPoint("TOPLEFT", card, "TOPLEFT", 64, -36)
  h.join = A.Label(card, "", "GameFontHighlightSmall")
  h.join:SetPoint("TOPLEFT", card, "TOPLEFT", 64, -56)
  grey(h.join)
  h.shield = card:CreateTexture(nil, "ARTWORK")
  h.shield:SetSize(SHIELD_W, SHIELD_H)
  h.shield:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -10)
  Kit.Atlas(h.shield, "UI-Legacy-Points-icon-c60")
  h.points = A.Label(card, "", "GameFontNormalMed3", SHIELD_W)
  h.points:SetJustifyH("CENTER")
  h.points:SetPoint("CENTER", h.shield, "TOP", 0, -31)
  h.title = rightLabel(card, "GameFontNormalLarge", TITLE_W)
  h.title:SetPoint("TOPRIGHT", h.shield, "TOPLEFT", -10, -6)
  h.line = rightLabel(card, "GameFontHighlightSmall", TITLE_W)
  h.line:SetPoint("TOPRIGHT", h.shield, "TOPLEFT", -10, -30)
  tipOn(card)
  return h
end

local function build(holder)
  local scroll, content = A.Scroll(holder)
  if not content then return end
  content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
  ui = { content = content, months = {} }
  ui.back = A.Button(content, T_BACK, BACK_W, function()
    home()
    A.Select("journey")
  end)
  ui.header = buildHeader(content)
  ui.only = A.Label(content, T_ONLY_GUILD, "GameFontHighlightSmall")
  grey(ui.only)
  ui.note = A.Label(content, "", "GameFontHighlight")
end

-- One row of a month card: its own Button, so a fold row takes a click.
local function newRow(card)
  local row = A.Frame(card, "Button")
  if not row then return nil end
  row:SetHeight(ROW_H)
  row.date = A.Label(row, "", "GameFontHighlightSmall", PILL_X - DATE_X - 4)
  row.date:SetPoint("LEFT", row, "LEFT", DATE_X, 0)
  grey(row.date)
  row.pill = Kit.Pill(row, "", "gold")
  if row.pill then row.pill:SetPoint("LEFT", row, "LEFT", PILL_X, 0) end
  row.text = A.Label(row, "", "GameFontHighlight")
  row.text:SetPoint("LEFT", row, "LEFT", TEXT_X, 0)
  row.right = rightLabel(row, "GameFontHighlightSmall", RIGHT_W)
  row.right:SetPoint("RIGHT", row, "RIGHT", -12, 0)
  grey(row.right)
  tipOn(row)
  return row
end

local function setRow(row, r, inner, onFold)
  row:SetWidth(inner)
  row.text:SetWidth(math.max(TEXT_MIN, inner - TEXT_X - RIGHT_W - 12))
  row.tipTitle = r.text or ""
  row.tip = { r.when, r.kind ~= "fold" and r.right or nil }
  if r.kind == "fold" then
    row.date:SetText("")
    if row.pill then row.pill:Hide() end
    row.text:SetText(r.text or "")
    row.text:SetTextColor(TONES.rank[1], TONES.rank[2], TONES.rank[3])
    row.right:SetText("")
    local key = r.key
    row:SetScript("OnClick", function() A.M.Safe(onFold, key) end)
  else
    row.date:SetText(r.when or "")
    if row.pill then
      local tone = TONES[r.tag] or TONES.level
      Kit.SetPill(row.pill, TAGS[r.tag] or "", "gold")
      row.pill.text:SetTextColor(tone[1], tone[2], tone[3])
      row.pill:SetWidth(PILL_W)
      row.pill:SetShown(TAGS[r.tag] ~= nil)
    end
    row.text:SetText(r.text or "")
    row.text:SetTextColor(1, 1, 1)
    row.right:SetText(r.right or "")
    row:SetScript("OnClick", nil)
  end
  row:Show()
end

-- Month i's section header, card and rows, made in order of use and kept.
local function month(i, inner)
  local m = ui.months[i]
  if not m then
    m = { rows = {} }
    m.head = Kit.SectionHeader(ui.content, inner, "")
    m.card = Kit.Card(ui.content, inner, ROW_H)
    ui.months[i] = m
  end
  return m
end

local draw

local function onFold(key)
  if key == nil then return end
  state.opened[key] = not state.opened[key] or nil
  draw()
end

local function hideAll()
  ui.back:Hide()
  if ui.header then ui.header.card:Hide() end
  ui.only:Hide()
  ui.note:Hide()
  if ui.endFs then ui.endFs:Hide() end
  for _, m in ipairs(ui.months) do
    if m.head then m.head:Hide() end
    if m.card then m.card:Hide() end
  end
end

local function note(content, text, y)
  ui.note:SetText(text)
  ui.note:ClearAllPoints()
  ui.note:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
  ui.note:Show()
  content:SetHeight(-y + BUTTON_H)
end

local function drawHeader(rows, inner, y)
  local h = ui.header
  if not h then return y end
  local title, days, join, who
  for _, r in ipairs(rows) do
    if r.kind == "title" then title = r
    elseif r.kind == "line" and r.part == "who" then who = r.text
    elseif r.kind == "line" and r.part == "days" then days = r
    elseif r.kind == "line" and r.part == "join" then join = r end
  end
  h.card:SetWidth(inner)
  local leftW = math.max(TEXT_MIN, inner - LEFT_X - 12 - SHIELD_W - 10 - TITLE_W - GAP)
  h.name:SetWidth(leftW)
  h.who:SetWidth(leftW)
  h.join:SetWidth(leftW)
  h.card:ClearAllPoints()
  h.card:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, y)
  A.Kit.ClassIcon(h.icon, title and title.class, "groupfinder-icon-class-")
  h.name:SetTextColor(A.ClassColour(title and title.class))
  local joinText = join and join.text or ""
  if days then joinText = days.text .. DOT .. joinText end
  h.join:SetText(joinText)
  local nameText, titleText = title and title.text or "", title and title.title or ""
  local lineText = tostring(title and title.points or 0) .. " points" .. DOT .. tostring(title and title.count or 0)
    .. " achievements"
  h.name:SetText(nameText)
  h.who:SetText(who or "")
  h.title:SetText(titleText)
  h.points:SetText(tostring(title and title.points or 0))
  h.line:SetText(lineText)
  -- The tooltip from View's escaped texts, never read back from the FontStrings (f3018).
  h.card.tipTitle = nameText
  h.card.tip = { who or "", joinText, titleText, lineText }
  h.card:Show()
  return y - HEADER_H - GAP
end

draw = function()
  if not ui then return end
  local content = ui.content
  local L = A.Layout()
  local inner = L.inner
  content:SetWidth(inner)
  hideAll()
  local y = -CARD_PAD
  local G = A.PageG()
  if A.NoGuild(G) then return note(content, View.T_NO_GUILD, y) end
  local me = A.JourneySelf()
  local function rowsOf(guid)
    return View.JourneyRows(G, guid, A.Now(), { date = A.Date, opened = state.opened, self = me })
  end
  local rows = state.guid and rowsOf(state.guid)
  -- A guid not in the page's G (demo toggled, pruned) falls back to your own.
  if not rows then
    home()
    rows = rowsOf(me)
  end
  if not rows then return note(content, View.T_EMPTY, y) end
  local other = state.guid ~= nil and state.guid ~= me
  if other then
    ui.back:ClearAllPoints()
    ui.back:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
    ui.back:Show()
    y = y - BUTTON_H - GAP
  end
  y = drawHeader(rows, inner, y)
  if other then
    ui.only:ClearAllPoints()
    ui.only:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
    ui.only:Show()
    y = y - ROW_H
  end
  -- months: a section header, then a card with that month's rows
  local i, m, n, last = 0, nil, 0, nil
  local function close()
    if not m then return end
    for k = n + 1, #m.rows do m.rows[k]:Hide() end
    m.card:SetSize(inner, n * ROW_H + CARD_PAD * 2)
    y = y - n * ROW_H - CARD_PAD * 2 - GAP
    m = nil
  end
  for _, r in ipairs(rows) do
    if r.kind == "month" then
      close()
      i = i + 1
      m, n = month(i, inner), 0
      m.head:SetWidth(inner)
      m.head.label:SetText(r.text)
      m.head:ClearAllPoints()
      m.head:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
      m.head:Show()
      y = y - SECTION_H - CARD_PAD
      m.card:ClearAllPoints()
      m.card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
      m.card:Show()
    elseif m and (r.kind == "event" or r.kind == "feat" or r.kind == "fold") then
      n = n + 1
      local row = m.rows[n] or newRow(m.card)
      m.rows[n] = row
      if row then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", m.card, "TOPLEFT", 0, -CARD_PAD - (n - 1) * ROW_H)
        setRow(row, r, inner, onFold)
      end
    elseif r.kind == "end" then
      last = r
    end
  end
  close()
  if last then
    ui.endFs = ui.endFs or A.Label(content, "", "GameFontHighlightSmall")
    grey(ui.endFs)
    ui.endFs:SetText(last.text)
    ui.endFs:ClearAllPoints()
    ui.endFs:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
    ui.endFs:Show()
    y = y - ROW_H
  end
  content:SetHeight(-y + CARD_PAD)
end

ns.AnnalsJourney = { key = "journey", text = "Journey", build = build, refresh = function() draw() end,
  -- home(): your own Journey, folds closed (/annals). open(guid): that guid's Journey, folds closed (A.OpenJourney).
  home = home, open = open }
