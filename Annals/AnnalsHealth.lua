-- Annals AnnalsHealth: the Health tab on the Annals page in the GuildSync window (window plan Task 7, mock an-5/an-6),
-- officers only (A.HealthVisible, D6). A counts strip by band, the do-not-invite alert, the bands in Layout().cols
-- columns, New this week, Anniversaries, Former as cards with Use name, and Do not invite (the local-list note, the
-- form, one card per entry with Remove). Rows come from View.HealthRows (texts escaped there, D13).
-- Reaches only ns.AnnalsModule (the seam), ns.AnnalsView and ns.AnnalsRules.
local _, ns = ...
if not (ns.AnnalsModule and ns.AnnalsModule.M) then ns.AnnalsHealth = {} return end
local A, View, Rules = ns.AnnalsModule, ns.AnnalsView, ns.AnnalsRules

local GREY = { 0.7, 0.7, 0.7 }
local RED = { 1, 0.35, 0.35 }
local ROW_H, HEADER_H, GAP = 18, 26, 6
local STRIP_H, STRIP_CELLS, CELL_GAP = 56, 6, 4
local ALERT_H, CARD_H, DNI_H, FORM_H = 20, 72, 34, 64
local NAME_W, USE_W, REMOVE_W, ADD_W, NAME_BOX_W = 170, 80, 74, 136, 150
local T_NAME, T_REASON = "Name", "Reason"
local T_ADD, T_USE, T_REMOVE = "Add to do not invite", "Use name", "Remove"
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- s: the holder's frames. items: frames made once per key (a guid or a dni id), each keeping its own character;
-- pools: frames reused by position. demoSeen: A.DemoGen() at the last draw; the inputs clear when it changes.
local s = { items = {}, headers = {}, notes = {}, alerts = {}, cells = {} }

local function colour(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

-- Every row text is one line cut by the client at its width (A.Label); hovering f shows owner.tip whole (f3001).
local function hoverTip(f, owner)
  A.HoverTip(f, function()
    local t = owner.tip
    if t then return t.title or "", t.lines end
  end)
end

local function tipOf(row) return { title = row.text or "", lines = { row.right } } end

local function clearInputs()
  if s.name then s.name:SetText("") end
  if s.reason then s.reason:SetText("") end
  s.picked = nil
end

-- ---------- actions (moved from AnnalsUI.lua addDni / onHealthAction) ----------

local function addDni()
  local name = string.match(s.name:GetText() or "", "^%s*(.-)%s*$")
  local reason = s.reason:GetText() or ""
  local guid = (s.picked and s.picked.name == name) and s.picked.guid or nil
  -- Keep a picked guid only while the page's G still holds it (no demo guid into the real annals).
  local G = A.PageG()
  if guid and not (G and ((G.chars and G.chars[guid]) or (G.former and G.former[guid]))) then guid = nil end
  local id, err = A.DniAdd(name, guid, reason)
  if not id then
    A.Say(tostring(err or "could not add"))
    return
  end
  clearInputs()
end

local function useName(row)
  local G = A.PageG()
  local rec = G and G.former and row.guid and G.former[row.guid]
  local name = (rec and rec.n) or row.text
  s.name:SetText(name)
  s.picked = { name = name, guid = row.guid }
end

-- ---------- pieces ----------

local function item(key, make)
  local f = s.items[key]
  if not f then
    f = make()
    if not f then return nil end
    s.items[key] = f
  end
  f:ClearAllPoints()
  f:Show()
  return f
end

local function pooled(pool, i, make)
  local f = pool[i]
  if not f then
    f = make()
    if not f then return nil end
    pool[i] = f
  end
  f:ClearAllPoints()
  f:Show()
  return f
end

local function at(f, x, y) f:SetPoint("TOPLEFT", s.content, "TOPLEFT", x, -y) end

local function header(n, text, x, y, w)
  local h = pooled(s.headers, n, function()
    local sh = A.Kit and A.Kit.SectionHeader(s.content, w, text)
    if sh then return sh end
    local f = A.Kit and A.Kit.Inset(s.content)
    if f then f.label = A.Label(f, "", "GameFontNormal") f.label:SetPoint("LEFT", 8, 0) end
    return f
  end)
  if not h then return end
  h:SetSize(w, HEADER_H)
  h.label:SetText(text)
  at(h, x, y)
end

local function note(n, text, x, y, w)
  local fs = pooled(s.notes, n, function() return A.Label(s.content, "", "GameFontHighlightSmall") end)
  fs:SetWidth(w)
  fs:SetText(text)
  colour(fs, GREY)
  at(fs, x, y)
end

-- A character row: the row is the name button (A.NameButton), the name in class colour, the right text grey.
local function charRow(key, row, x, y, w)
  local b = item(key, function()
    local nb = A.NameButton(s.content, row)
    if not nb then return nil end
    nb.name = A.Label(nb, "")
    nb.name:SetPoint("LEFT", 4, 0)
    nb.right = A.Label(nb, "", "GameFontHighlightSmall")
    nb.right:SetJustifyH("RIGHT")
    nb.right:SetPoint("RIGHT", -4, 0)
    if A.Kit then A.Kit.ListHover(nb, HIGHLIGHT) end
    hoverTip(nb, nb)
    return nb
  end)
  if not b then return end
  local nameW = math.min(NAME_W, w - 8)
  b:SetSize(w, ROW_H)
  b.name:SetWidth(nameW)
  b.name:SetText(row.text or "")
  colour(b.name, { A.ClassColour(row.class) })
  b.right:SetWidth(math.max(1, w - nameW - 12))
  b.right:SetText(row.right or "")
  b.tip = tipOf(row)
  colour(b.right, GREY)
  at(b, x, y)
end

local function strip(heads, y, inner)
  local labels = {}
  for _, band in ipairs(Rules.BANDS) do labels[band.key] = band.label end
  labels[Rules.UNKNOWN_KEY] = Rules.UNKNOWN_LABEL
  local cellW = (inner - CELL_GAP * (STRIP_CELLS - 1)) / STRIP_CELLS
  for i, h in ipairs(heads) do
    local cell = pooled(s.cells, i, function()
      local f = A.Kit and A.Kit.Inset(s.content)
      if not f then return nil end
      local bg = f:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints(f)
      A.Kit.Atlas(bg, "groupfinder-Stat-StoneBG", nil)
      f.label = A.Label(f, "", "GameFontHighlightSmall")
      f.label:SetPoint("TOP", 0, -8)
      f.count = A.Label(f, "", "GameFontNormalLarge")
      f.count:SetPoint("BOTTOM", 0, 10)
      return f
    end)
    if cell then
      cell:SetSize(cellW, STRIP_H)
      cell.label:SetText(labels[h.band] or "")
      cell.count:SetText(tostring(h.count or 0))
      at(cell, (i - 1) * (cellW + CELL_GAP), y)
    end
  end
end

local function alert(n, text, y, inner)
  local a = pooled(s.alerts, n, function()
    local icon = s.content:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 16)
    A.Kit.Atlas(icon, "services-icon-warning", nil)
    return { icon = icon, fs = A.Label(s.content, ""),
      Show = function(self) self.icon:Show() self.fs:Show() end,
      Hide = function(self) self.icon:Hide() self.fs:Hide() end,
      ClearAllPoints = function(self) self.icon:ClearAllPoints() self.fs:ClearAllPoints() end }
  end)
  at(a.icon, 4, y)
  a.fs:SetWidth(inner - 28)
  a.fs:SetText(text)
  colour(a.fs, RED)
  at(a.fs, 26, y + 1)
end

-- A Former card: name (a name button over it), "level 15, Deathguard", then its note rows; Use name at the right.
local function formerCard(row, x, y, w)
  local card = item("former:" .. tostring(row.guid), function()
    local f = A.Kit and A.Kit.Card(s.content, w, CARD_H)
    if not f then return nil end
    f.name = A.Label(f, "")
    f.name:SetPoint("TOPLEFT", 10, -8)
    f.right = A.Label(f, "", "GameFontHighlightSmall")
    f.right:SetPoint("TOPLEFT", 10, -26)
    f.lines = {}
    f.use = A.Button(f, T_USE, USE_W, function() if f.row then useName(f.row) end end)
    if f.use then f.use:SetPoint("TOPRIGHT", -8, -6) end
    f.nameBtn = A.NameButton(f, row)
    f:EnableMouse(true)
    hoverTip(f, f)
    hoverTip(f.nameBtn, f)
    if f.nameBtn then f.nameBtn:SetPoint("TOPLEFT", 8, -6) end
    return f
  end)
  if not card then return nil end
  card.row = row
  card.tip = tipOf(row)
  local nameW = math.max(1, w - USE_W - 24)
  card:SetSize(w, CARD_H)
  card.name:SetWidth(nameW)
  card.name:SetText(row.text or "")
  colour(card.name, { A.ClassColour(row.class) })
  card.right:SetWidth(w - 20)
  card.right:SetText(row.right or "")
  colour(card.right, GREY)
  if card.nameBtn then card.nameBtn:SetSize(nameW, ROW_H) end
  for _, fs in ipairs(card.lines) do fs:Hide() end
  card.used = 0
  at(card, x, y)
  return card
end

local function cardLine(card, text, w)
  card.used = card.used + 1
  card.tip.lines[#card.tip.lines + 1] = text
  local fs = card.lines[card.used]
  if not fs then
    fs = A.Label(card, "", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 10, -26 - 15 * card.used)
    card.lines[card.used] = fs
  end
  fs:SetWidth(w - 20)
  fs:SetText(text)
  colour(fs, GREY)
  fs:Show()
end

-- A do-not-invite entry: name (a name button only while the annals know its guid), the reason, Remove.
local function dniCard(row, y, inner)
  local card = item("dni:" .. tostring(row.id), function()
    local f = A.Kit and A.Kit.Card(s.content, inner, DNI_H)
    if not f then return nil end
    f.name = A.Label(f, "")
    f.name:SetPoint("LEFT", 10, 0)
    f.why = A.Label(f, "", "GameFontHighlightSmall")
    f.why:SetPoint("LEFT", NAME_W + 20, 0)
    f.remove = A.Button(f, T_REMOVE, REMOVE_W, function()
      if f.row and f.row.id then A.DniRemove(f.row.id) end
    end)
    if f.remove then f.remove:SetPoint("RIGHT", -8, 0) end
    f:EnableMouse(true)
    hoverTip(f, f)
    return f
  end)
  if not card then return end
  card.row = row
  card.tip = tipOf(row)
  card:SetSize(inner, DNI_H)
  card.name:SetWidth(NAME_W)
  card.name:SetText(row.text or "")
  card.why:SetWidth(math.max(1, inner - NAME_W - REMOVE_W - 40))
  card.why:SetText(row.right or "")
  colour(card.why, GREY)
  if row.guid and not card.nameBtn then
    card.nameBtn = A.NameButton(card, row)
    if card.nameBtn then card.nameBtn:SetPoint("LEFT", 8, 0) end
    hoverTip(card.nameBtn, card)
  end
  if card.nameBtn then
    card.nameBtn.guid = row.guid -- the entry's guid now: an n:name entry can bind to another character (f3008)
    card.nameBtn:SetSize(NAME_W, ROW_H)
    if row.guid then card.nameBtn:Show() else card.nameBtn:Hide() end
  end
  at(card, 0, y)
end

-- The form card: the local-list note, Name, Reason, Add (built once, laid out on every draw).
local function buildForm()
  local f = A.Kit and A.Kit.Card(s.content, A.Layout().inner, FORM_H)
  if not f then return end
  s.form = f
  f.note = A.Label(f, "", "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", 10, -8)
  local nameLabel = A.Label(f, T_NAME, "GameFontNormalSmall")
  nameLabel:SetPoint("TOPLEFT", 10, -36)
  s.name = A.Kit.InputBox(f, NAME_BOX_W, NAME_BOX_W)
  if s.name then
    s.name:SetMaxLetters(40)
    s.name:SetPoint("TOPLEFT", 54, -32)
  end
  local reasonLabel = A.Label(f, T_REASON, "GameFontNormalSmall")
  reasonLabel:SetPoint("TOPLEFT", 214, -36)
  s.reason = A.Kit.InputBox(f, NAME_BOX_W, NAME_BOX_W)
  if s.reason then
    s.reason:SetMaxLetters(Rules.REASON_MAX)
    s.reason:SetPoint("TOPLEFT", 270, -32)
  end
  s.add = A.Button(f, T_ADD, ADD_W, function() if s.name and s.reason then addDni() end end)
  if s.add then s.add:SetPoint("TOPRIGHT", -8, -30) end
end

-- ---------- draw ----------

local function draw()
  if not s.content then return end
  if A.DemoGen() ~= s.demoSeen then
    clearInputs()
    s.demoSeen = A.DemoGen()
  end
  for _, f in pairs(s.items) do f:Hide() end
  for _, pool in ipairs({ s.headers, s.notes, s.alerts, s.cells }) do
    for _, f in ipairs(pool) do f:Hide() end
  end
  if s.form then s.form:Hide() end
  local L = A.Layout()
  local G = A.PageG()
  if A.NoGuild(G) then
    note(1, View.T_NO_GUILD, 4, 4, L.inner - 8)
    s.content:SetHeight(ROW_H + 8)
    return
  end
  -- Officer notes only where this character may read them now, and always on the made-up guild (security s2).
  local rows = View.HealthRows(G, A.Now(), { date = A.Date,
    officerNotes = A.DrawsDemo(G) or A.CanViewOfficerNote() == true })

  local heads = {}
  for _, r in ipairs(rows) do if r.kind == "header" and r.section == "band" then heads[#heads + 1] = r end end
  local y = 0
  if #heads > 0 then
    strip(heads, y, L.inner)
    y = STRIP_H + GAP
  end
  local nh, nn, na = 0, 0, 0
  local section, card, col
  local colY, inCols = { 0, 0 }, false
  local function flush()
    if inCols then y = math.max(colY[1], colY[2]) + GAP inCols = false end
  end
  -- The shorter column (the first while one column), its x.
  local function pick()
    if not inCols then colY[1], colY[2], inCols = y, y, true end
    local c = (L.cols == 2 and colY[2] < colY[1]) and 2 or 1
    return c, (c - 1) * (L.colW + Rules.COL_GAP)
  end

  for _, row in ipairs(rows) do
    if row.kind == "alert" then
      na = na + 1
      alert(na, row.text, y, L.inner)
      y = y + ALERT_H
    elseif row.kind == "header" then
      card = nil
      nh = nh + 1
      if row.section == "band" then
        local c, x = pick()
        header(nh, row.text, x, colY[c], L.colW)
        colY[c] = colY[c] + HEADER_H
        col = { c = c, x = x }
      else
        flush()
        header(nh, row.text, 0, y, L.inner)
        y = y + HEADER_H
      end
      section = row.section
    elseif section == "band" and row.kind == "char" then
      charRow("band:" .. tostring(row.guid), row, col.x, colY[col.c], L.colW)
      colY[col.c] = colY[col.c] + ROW_H
    elseif row.kind == "former" then
      local c, x = pick()
      card = formerCard(row, x, colY[c], L.colW)
      colY[c] = colY[c] + CARD_H + GAP
    elseif row.kind == "note" and card then
      cardLine(card, row.text, L.colW)
    elseif row.kind == "note" and section == "dni" and row.text == View.T_LOCAL and s.form then
      s.form:SetSize(L.inner, FORM_H)
      s.form.note:SetWidth(L.inner - 20)
      s.form.note:SetText(row.text)
      colour(s.form.note, GREY)
      if s.reason then s.reason:SetWidth(math.max(1, L.inner - 270 - ADD_W - 20)) end
      s.form:ClearAllPoints()
      at(s.form, 0, y + 2)
      s.form:Show()
      y = y + FORM_H + GAP
    elseif row.kind == "dni" then
      dniCard(row, y, L.inner)
      y = y + DNI_H + 2
    elseif row.kind == "char" then
      charRow(tostring(section) .. ":" .. tostring(row.guid), row, 0, y, L.inner)
      y = y + ROW_H
    else
      flush()
      nn = nn + 1
      note(nn, row.text or "", 4, y + 2, L.inner - 8)
      y = y + ROW_H
    end
  end
  flush()
  s.content:SetHeight(y + 8)
end

ns.AnnalsHealth = { key = "health", text = "Health",
  build = function(holder)
    local _, content = A.Scroll(holder)
    if not content then return end
    s.content = content
    buildForm()
  end,
  refresh = function() draw() end,
  visible = function() return A.HealthVisible() end }
