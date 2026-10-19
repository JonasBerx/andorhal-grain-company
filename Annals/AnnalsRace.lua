-- Annals AnnalsRace: the Race tab on the Annals page in the GuildSync window (window plan Task 4, an-3). A class
-- dropdown, one card per milestone with Forever's level circle ("First: <name>" or a tie with whole names, every name
-- in the tooltip, D12), then Leaders with level bars. Rows come from View.RaceRows and View.LeaderRows; the layout from
-- A.Layout() on every refresh (D17). Reaches only ns.AnnalsModule (the seam), ns.AnnalsView and ns.AnnalsRules.
local _, ns = ...
if not (ns.AnnalsModule and ns.AnnalsModule.M) then ns.AnnalsRace = {} return end

local A, View, Rules = ns.AnnalsModule, ns.AnnalsView, ns.AnnalsRules

local FILTER_H = 34        -- the dropdown row above the scroll
local DROPDOWN_W = 150
local CARD_H = 72
local CIRCLE_SIZE = 56
local TEXT_X = 72          -- circle (56) + its inset (8) + a gap (8)
local CARD_PAD = 12
local LEADER_H = 30
local LEADER_GAP = 4
local STAT_INSET = 6 -- M.Kit.StatBar's fill line starts 6 in from each end (API.md)
local GAP = 8
local HEADER_H = 26
local NAME_W = 200
local LEVEL_W = 60         -- "Level 60" on the bar
local TIE_LINES = 2        -- a tie's names may take two lines (d501, f3002)
local TIE_SLACK = 40       -- room for the wrap breaking at a space
local T_ALL = "All classes"

local race = { filter = "ALL", cards = {}, leaders = {} }

local function classText(token)
  if token == "ALL" then return T_ALL end
  return Rules.CLASS_NAMES[token] or token
end

-- The largest half pixel k * 0.5 with k * max <= 2 * W * level: multiplication only (f1454); full at max.
local function barWidth(W, level, max)
  if type(max) ~= "number" or max <= 0 or type(level) ~= "number" or level <= 0 then return 0 end
  if level >= max then return W end
  local k, top = 0, 2 * W * level
  while (k + 1) * max <= top do k = k + 1 end
  return k * 0.5
end

-- A name button over label; pointName sets the guid it opens (pooled cards change character).
local function nameButton(parent, label)
  local b = A.NameButton(parent, { guid = false })
  if not b then return nil end
  b:SetAllPoints(label)
  return b
end

local function pointName(b, row)
  if not b then return end
  b.guid = row and row.guid or nil
  if b.guid then b:Show() else b:Hide() end
end

-- ---------- cards ----------

local function newCard(parent)
  local f = A.Kit.Card(parent, A.Layout().colW, CARD_H)
  if not f then return nil end
  local c = { frame = f }
  c.circle = f:CreateTexture(nil, "ARTWORK")
  c.circle:SetSize(CIRCLE_SIZE, CIRCLE_SIZE)
  c.circle:SetPoint("LEFT", f, "LEFT", GAP, 0)
  A.Kit.Atlas(c.circle, "Legacy-Tree-Frame-level-circle")
  c.level = A.Label(f, "", "GameFontNormalLarge")
  c.level:SetPoint("CENTER", c.circle, "CENTER", 0, 0)
  c.line = A.Label(f, "", "GameFontHighlight")
  c.line:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -CARD_PAD - 4)
  c.time = A.Label(f, "", "GameFontHighlightSmall", A.Layout().colW - TEXT_X - CARD_PAD)
  c.time:SetPoint("TOPLEFT", c.line, "BOTTOMLEFT", 0, -6)
  c.time:SetTextColor(0.6, 0.6, 0.6)
  c.name = nameButton(f, c.line)
  f:EnableMouse(true)
  A.HoverTip(f, function() if c.tip then return c.tipTitle or "", c.tip end end)
  return c
end

-- A tie entry's name, with View.T_LEFT for a former member.
local function tieName(x) return x.name .. (x.former and View.T_LEFT or "") end

-- The tie text with as many whole names (1 to TIE_NAMES) as fit two lines of `width`, then "and N more" (D12, d501).
local function tieText(fs, row, width)
  local names, count = row.names, row.count or #row.names
  local k = math.min(#names, Rules.TIE_NAMES)
  while true do
    local shown = {}
    for i = 1, k do shown[i] = tieName(names[i]) end
    local text = string.format(View.T_TIE, table.concat(shown, ", "))
    if k < count then text = text .. string.format(View.T_MORE, count - k) end
    fs:SetWidth(0)
    fs:SetText(text)
    local w = type(fs.GetStringWidth) == "function" and fs:GetStringWidth() or nil
    if k <= 1 or type(w) ~= "number" or w <= TIE_LINES * width - TIE_SLACK then return end
    k = k - 1
  end
end

local function fillCard(c, M, row, L)
  local f = c.frame
  f:SetSize(L.colW, CARD_H)
  c.level:SetText(M and tostring(M) or "")
  local width = L.colW - TEXT_X - CARD_PAD
  -- The card's tooltip holds its whole text (a cut line or time reads there; a tie lists every name).
  c.tipTitle, c.tip = string.format(View.T_LEVEL, M or 0), {}
  local tie = row and type(row.names) == "table"
  c.line:SetWordWrap(tie and true or false)
  c.line:SetMaxLines(tie and TIE_LINES or 1)
  if tie then
    tieText(c.line, row, width)
    for i, x in ipairs(row.names) do c.tip[i] = tieName(x) end
  else
    c.line:SetText(row and row.text or "")
    if row then c.tip[1] = row.text end
  end
  if row and row.right then c.tip[#c.tip + 1] = row.right end
  c.line:SetWidth(width)
  c.time:SetWidth(width)
  if row and row.class then c.line:SetTextColor(A.ClassColour(row.class)) else c.line:SetTextColor(1, 1, 1) end
  c.time:SetText(row and row.right or "")
  pointName(c.name, row and row.kind == "char" and row or nil)
  f:Show()
end

-- ---------- leaders ----------

local function newLeader(parent)
  local f = A.Kit.Card(parent, A.Layout().inner, LEADER_H)
  if not f then return nil end
  local r = { frame = f }
  r.label = A.Label(f, "", "GameFontHighlight", NAME_W)
  r.label:SetPoint("LEFT", f, "LEFT", CARD_PAD, 0)
  r.name = nameButton(f, r.label)
  r.bar = A.Kit.StatBar(f)
  if r.bar then
    r.bar:SetPoint("LEFT", f, "LEFT", CARD_PAD + NAME_W + GAP, 0)
    if r.bar.fill then
      r.bar.fill:ClearAllPoints()
      r.bar.fill:SetPoint("TOPLEFT", r.bar, "TOPLEFT", STAT_INSET, -7)
      r.colour = r.bar.fill:CreateTexture(nil, "ARTWORK")
      r.colour:SetAllPoints(r.bar.fill)
    end
  end
  -- On the fill frame, so the text draws above the fill (a child frame draws over its parent's regions).
  r.level = A.Label(r.bar and r.bar.fill or f, "", "GameFontHighlightSmall", LEVEL_W)
  r.level:SetJustifyH("CENTER")
  if r.bar then r.level:SetPoint("CENTER", r.bar, "CENTER", 0, 0)
  else r.level:SetPoint("RIGHT", f, "RIGHT", -CARD_PAD, 0) end
  return r
end

local function fillLeader(r, row, L, max)
  r.frame:SetSize(L.inner, LEADER_H)
  r.label:SetText(row.text)
  local cr, cg, cb = A.ClassColour(row.class)
  r.label:SetTextColor(cr, cg, cb)
  pointName(r.name, row)
  local level = type(row.level) == "number" and row.level or nil
  if r.bar then
    r.bar:SetWidth(L.levelBarW)
    local w = barWidth(L.levelBarW - 2 * STAT_INSET, level, max)
    if r.bar.fill then
      if w > 0 then r.bar.fill:SetWidth(w) r.bar.fill:Show() else r.bar.fill:Hide() end
      if r.colour then r.colour:SetColorTexture(cr, cg, cb, 0.8) end
    end
  end
  r.level:SetText(string.format(View.T_LEVEL, level or 0))
  r.frame:Show()
end

-- ---------- the tab ----------

local function hideFrom(pool, n)
  for i = n, #pool do pool[i].frame:Hide() end
end

local function draw(holder)
  if not race.content then return end
  local G = A.PageG()
  local content = race.content
  -- No guild, or nothing read into it yet: the note, no cards.
  if A.NoGuild(G) then
    race.note:SetText(View.T_NO_GUILD)
    race.note:Show()
    if race.leadersHead then race.leadersHead:Hide() end
    hideFrom(race.cards, 1)
    hideFrom(race.leaders, 1)
    return
  end
  race.note:Hide()
  local known = false
  for _, t in ipairs(View.ClassFilters(G)) do if t == race.filter then known = true end end
  if not known then race.filter = "ALL" end
  if race.dd then A.Kit.DropdownText(race.dd, classText(race.filter)) end

  local L = A.Layout()
  local max = A.PageMaxLevel(G)
  local rows = View.RaceRows(G, A.Now(), max, race.filter ~= "ALL" and race.filter or nil, { date = A.Date })
  local milestones = Rules.Milestones(max)

  -- One card per milestone: its header, then the row under it (first, tie or nobody).
  local n, col, y = 0, 1, -4
  local i = 1
  while i <= #rows do
    if rows[i].kind == "header" then
      n = n + 1
      local row = rows[i + 1]
      if row and row.kind == "header" then row = nil end
      local c = race.cards[n]
      if not c then
        c = newCard(content)
        race.cards[n] = c
      end
      if c then
        fillCard(c, milestones[n], row, L)
        c.frame:ClearAllPoints()
        c.frame:SetPoint("TOPLEFT", content, "TOPLEFT", (col - 1) * (L.colW + Rules.COL_GAP), y)
      end
      col = col + 1
      if col > L.cols then col, y = 1, y - CARD_H - GAP end
    end
    i = i + 1
  end
  hideFrom(race.cards, n + 1)
  if col > 1 then y = y - CARD_H - GAP end

  -- Leaders
  local leaders = View.LeaderRows(G, Rules.LEADERS)
  if not race.leadersHead then
    race.leadersHead = A.Kit.SectionHeader(content, L.inner, leaders[1].text) or A.Label(content, leaders[1].text)
  end
  local head = race.leadersHead
  head:SetWidth(L.inner)
  head:ClearAllPoints()
  head:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  head:Show()
  y = y - HEADER_H - LEADER_GAP
  local m = 0
  for _, row in ipairs(leaders) do
    if row.kind == "char" then
      m = m + 1
      local r = race.leaders[m]
      if not r then
        r = newLeader(content)
        race.leaders[m] = r
      end
      if r then
        fillLeader(r, row, L, max)
        r.frame:ClearAllPoints()
        r.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
      end
      y = y - LEADER_H - LEADER_GAP
    end
  end
  hideFrom(race.leaders, m + 1)
  content:SetHeight(-y + GAP)
end

local function pick(token)
  race.filter = token
  draw(race.holder)
end

local function build(holder)
  race.holder = holder
  race.dd = A.Kit.Dropdown(holder, DROPDOWN_W, function(_, root)
    local G = A.PageG()
    for _, token in ipairs(G and View.ClassFilters(G) or { "ALL" }) do
      root:CreateRadio(classText(token), function(t) return race.filter == t end,
        function(t) A.M.Safe(pick, t) end, token)
    end
  end)
  if race.dd then race.dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 4, -4) end
  local scroll, content = A.Scroll(holder)
  if not scroll then return end
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -FILTER_H)
  scroll:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -Rules.SCROLL_W, 0)
  race.content = content
  if content then
    race.note = A.Label(content, "", "GameFontHighlight")
    race.note:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
    race.note:Hide()
  end
end

ns.AnnalsRace = { key = "race", text = "Race", build = build, refresh = draw }
