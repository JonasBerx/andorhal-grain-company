-- Annals AnnalsLevelLog: the Level log tab on the Annals page in the GuildSync window (window plan Task 5, D9, D17).
-- A filter row (Name search box, Class dropdown, From and To boxes, Milestones only), the "Showing a to b of n" line,
-- column headers (Time, Name, Level, How sure) and the rises from View.LevelLogRows in a Kit.List, else in pooled
-- rows in a scroll frame. Reaches only ns.AnnalsModule (the seam), ns.AnnalsView and ns.AnnalsRules.
local _, ns = ...
if not (ns.AnnalsModule and ns.AnnalsModule.M) then ns.AnnalsLevelLog = {} return end
local A, View, Rules = ns.AnnalsModule, ns.AnnalsView, ns.AnnalsRules

local ROW_H = 20
local TIME_W, NAME_W, LEVEL_W = 70, 200, 90
local FIXED_W = TIME_W + NAME_W + LEVEL_W
local CELL_PAD = 8          -- a cell's text sits where its header's label does (Kit.ColumnHeader, LEFT +8)
local CHAR_W = 5            -- GameFontHighlightSmall, about 5 px a character, when the client gives no measure
local NAV_W = 100
local FILTER_Y, SHOWING_Y, HEADER_Y, LIST_Y = -4, -36, -54, -74
local FOOTER_H = 20          -- the "<n> level-ups recorded since" line under the list
local ELLIPSIS = "\226\128\166"
local T_NAME, T_ALL, T_FROM, T_TO, T_MS = "Name", "All classes", "From", "To", "Milestones only"
local T_CLASS = "Class: %s"
local T_MS_OFF, T_MS_ON = "Milestones: off", "Milestones: on"
local T_OLDER, T_NEWER = "Show older", "Show newer"
local HOVER = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- The filters and the page offset live here, so they survive a trip to a Journey, another tab and a window reopen.
-- cache: every rise of the page's G, newest first, kept while G, G.last, G.rv and A.DemoGen() stay the same, so a
-- keystroke filters without rebuilding it; a read, an own ding or a demo change rebuilds it.
local st = { name = "", class = "ALL", from = "", to = "", ms = false, offset = 0 }
local ui = nil
local cache = nil

local function allRises(G)
  local k = cache
  if not (k and k.G == G and k.last == G.last and k.rv == G.rv and k.gen == A.DemoGen()) then
    k = { G = G, last = G.last, rv = G.rv, gen = A.DemoGen(), list = View.AllRises(G) }
    cache = k
  end
  return k.list
end

local function classes(G) return G and View.ClassFilters(G) or { "ALL" } end

local function classText(token)
  if token == "ALL" then return T_ALL end
  return Rules.CLASS_NAMES[token] or token
end

-- The class filter while G still has that class, else "ALL".
local function knownClass(G, value)
  for _, f in ipairs(classes(G)) do if f == value then return value end end
  return "ALL"
end

-- The text's width: the client's measure, else CHAR_W a character.
local function textWidth(fs, text)
  fs:SetText(text)
  local w = fs:GetStringWidth()
  if type(w) == "number" and w > 0 then return w end
  return #text * CHAR_W
end

-- Sets text on fs cut to fit width, ending in an ellipsis; true when it was cut.
local function fitText(fs, text, width)
  if textWidth(fs, text) <= width then return false end
  local kept = text
  while #kept > 0 do
    kept = string.sub(kept, 1, #kept - 1)
    while #kept > 0 and string.byte(kept, #kept) >= 128 and string.byte(kept, #kept) < 192 do
      kept = string.sub(kept, 1, #kept - 1)
    end
    if #kept > 0 and string.byte(kept, #kept) >= 192 then kept = string.sub(kept, 1, #kept - 1) end
    -- An odd run of | at the cut leaves a lone escape byte: drop one more.
    local odd, i = false, #kept
    while i > 0 and string.byte(kept, i) == 124 do odd, i = not odd, i - 1 end
    if odd then kept = string.sub(kept, 1, #kept - 1) end
    if textWidth(fs, kept .. ELLIPSIS) <= width then return true end
  end
  fs:SetText(ELLIPSIS)
  return true
end

local draw

local function turnPage(delta)
  st.offset = math.max(0, st.offset + delta * Rules.LOG_ROWS)
  draw(false)
end

-- Any filter change goes back to the newest rows.
local function setFilter(key, value)
  if st[key] == value then return end
  st[key] = value
  st.offset = 0
  draw(false)
end

-- ---------- rows: one shape for a Kit.List row frame and a pooled row on the scroll content ----------
-- o = { host, frame, top, cells... }: on a list row, host and frame are the row frame; on a pooled row, host is the
-- scroll content, frame is nil and top is the row's place on it.

local CELLS = { "day", "note", "time", "name", "levels", "how" }

local function at(o, obj, x)
  if o.frame then obj:SetPoint("LEFT", o.frame, "LEFT", x, 0)
  else obj:SetPoint("TOPLEFT", o.host, "TOPLEFT", x, -o.top) end
end

local function cell(o, font, x, width)
  local fs = A.Label(o.host, "", font, width)
  if not o.frame then fs:SetHeight(ROW_H) end
  at(o, fs, x)
  return fs
end

local function buildRow(o)
  o.day = cell(o, "GameFontNormal", CELL_PAD)
  o.note = cell(o, "GameFontDisableSmall", CELL_PAD)
  o.time = cell(o, "GameFontHighlightSmall", CELL_PAD, TIME_W - CELL_PAD)
  o.name = cell(o, "GameFontHighlight", TIME_W + CELL_PAD, NAME_W - CELL_PAD)
  o.levels = cell(o, "GameFontHighlightSmall", TIME_W + NAME_W + CELL_PAD, LEVEL_W - CELL_PAD)
  o.how = cell(o, "GameFontHighlightSmall", FIXED_W + CELL_PAD)
  if o.frame then
    A.Kit.ListHover(o.frame, HOVER)
    -- A How sure text cut to fit shows whole in the tooltip.
    A.HoverTip(o.frame, function()
      if o.cutHow then return o.cutTitle or "", { o.cutHow } end
      return o.cutText
    end)
  end
end

local function hide(obj) if obj then obj:Hide() end end

-- One name button per row; it opens the Journey of the character the row shows when clicked (rows are recycled).
local function nameButton(o, row)
  if not o.nameBtn then
    o.nameBtn = A.NameButton(o.host, row)
    if not o.nameBtn then return end
    o.nameBtn:SetSize(NAME_W, ROW_H)
    at(o, o.nameBtn, TIME_W)
  end
  o.nameBtn.guid = row.guid
  o.nameBtn:Show()
end

local function navButtons(o, row)
  if not o.older then
    o.newer = A.Button(o.host, T_NEWER, NAV_W, function() turnPage(-1) end)
    o.older = A.Button(o.host, T_OLDER, NAV_W, function() turnPage(1) end)
    if not (o.newer and o.older) then return end
    at(o, o.newer, CELL_PAD)
    at(o, o.older, CELL_PAD + NAV_W + CELL_PAD)
  end
  if row.newer then o.newer:Show() else o.newer:Hide() end
  if row.older then o.older:Show() else o.older:Hide() end
end

local function initRow(o, row)
  for _, k in ipairs(CELLS) do
    o[k]:SetText("")
    o[k]:Hide()
    if not o.frame then o[k].row = nil end
  end
  hide(o.nameBtn)
  hide(o.newer)
  hide(o.older)
  o.cutHow, o.cutTitle, o.cutText = nil, nil, nil
  -- A day line or note spans the row, inside the list's inner width.
  local lineW = A.Layout().inner - CELL_PAD
  if row.kind == "header" then
    o.day:SetWidth(lineW)
    if fitText(o.day, row.text or "", lineW) then o.cutText = row.text end
    o.day:Show()
    if not o.frame then o.day.row = row end
  elseif row.kind == "char" then
    o.time:SetText(row.time or "")
    o.name:SetText(row.text)
    o.name:SetTextColor(A.ClassColour(row.class))
    o.levels:SetText(row.levels or "")
    local howW = A.Layout().inner - FIXED_W
    o.how:SetWidth(howW)
    if fitText(o.how, row.how or "", howW) then o.cutHow, o.cutTitle = row.how, row.text end
    for _, k in ipairs({ "time", "name", "levels", "how" }) do o[k]:Show() end
    if not o.frame then o.name.row = row end
    if row.guid then nameButton(o, row) end
  elseif row.kind == "nav" then
    navButtons(o, row)
  else
    o.note:SetWidth(lineW)
    if fitText(o.note, row.text or "", lineW) then o.cutText = row.text end
    o.note:Show()
  end
end

-- ---------- the list ----------

local function listFrom(holder)
  local list = A.Kit.List(holder, ROW_H,
    function(f) f.annalsRow = { host = f, frame = f } buildRow(f.annalsRow) end,
    function(f, row) A.M.Safe(initRow, f.annalsRow, row) end)
  if list then
    list.box:ClearAllPoints()
    list.box:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, LIST_Y)
    list.box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -16, FOOTER_H)
    return list
  end
  -- Fallback: the same rows, pooled on a scroll frame's content.
  local area, content = A.Scroll(holder)
  if not (area and content) then return nil end
  area:ClearAllPoints()
  area:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, LIST_Y)
  area:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -Rules.SCROLL_W, FOOTER_H)
  local pool = {}
  local fb = {}
  function fb.SetRows(_, rows)
    for i, row in ipairs(rows) do
      local o = pool[i]
      if not o then
        o = { host = content, top = (i - 1) * ROW_H }
        buildRow(o)
        pool[i] = o
      end
      initRow(o, row)
    end
    for i = #rows + 1, #pool do initRow(pool[i], { kind = "note" }) end
    content:SetHeight(math.max(1, #rows * ROW_H))
  end
  return fb
end

draw = function(keepScroll)
  if not ui then return end
  local G = A.PageG()
  local rows = {}
  local showing, footer = "", ""
  -- No read yet (a G with no read, or none): the shared note. A demo G carries its own read time.
  if A.NoGuild(G) or not G.last then
    st.class = "ALL"
    rows[1] = { kind = "note", text = View.T_NO_GUILD }
  else
    st.class = knownClass(G, st.class)
    local filter = View.LevelFilter(st.name, st.class, st.from, st.to, st.ms, A.PageMaxLevel(G))
    local rises = allRises(G)
    local total = 0
    for _, x in ipairs(rises) do if View.MatchRise(x.rise, x.rec, filter) then total = total + 1 end end
    -- Data that shrank under the offset shows its last page.
    if st.offset >= total then
      local pages = 0
      while (pages + 1) * Rules.LOG_ROWS < total do pages = pages + 1 end
      st.offset = pages * Rules.LOG_ROWS
    end
    local older, newer = st.offset + Rules.LOG_ROWS < total, st.offset > 0
    local all = View.LevelLogRows(G, A.Now(), filter, { date = A.Date, offset = st.offset, rises = rises })
    showing = all[1] and all[1].text or ""
    footer = #all > 1 and all[#all].text or ""
    for i = 2, #all - 1 do rows[#rows + 1] = all[i] end
    if older or newer then rows[#rows + 1] = { kind = "nav", older = older, newer = newer } end
  end
  ui.showing:SetText(showing)
  ui.footer:SetText(footer)
  if ui.ddFallback then ui.ddFallback:SetText(string.format(T_CLASS, classText(st.class))) end
  if ui.msFallback then ui.msFallback:SetText(st.ms and T_MS_ON or T_MS_OFF) end
  ui.headers.how:SetWidth(A.Layout().inner - FIXED_W)
  if ui.list then ui.list:SetRows(rows, keepScroll) end
end

-- ---------- the filter row ----------

local function editBox(holder, box, key, x)
  box:SetPoint("TOPLEFT", holder, "TOPLEFT", x, FILTER_Y)
  box:SetAutoFocus(false)
  box:SetText(st[key])
  box:HookScript("OnTextChanged", function(self) A.M.Safe(setFilter, key, self:GetText() or "") end)
  box:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return box
end

local function classMenu(_, root)
  for _, token in ipairs(classes(A.PageG())) do
    root:CreateRadio(classText(token), function(t) return t == st.class end,
      function(t) A.M.Safe(setFilter, "class", t) end, token)
  end
end

local function nextClass()
  local list = classes(A.PageG())
  for i, f in ipairs(list) do
    if f == st.class then setFilter("class", list[i + 1] or list[1]) return end
  end
  setFilter("class", "ALL")
end

local function build(holder)
  local K = A.Kit
  ui = { headers = {} }
  local name = K.SearchBox(holder, 150, T_NAME) or K.InputBox(holder, 150, 150)
  if name then editBox(holder, name, "name", 4) end
  ui.dd = K.Dropdown(holder, 130, classMenu)
  if ui.dd then
    ui.dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 160, FILTER_Y + 2)
  else
    ui.ddFallback = A.Button(holder, string.format(T_CLASS, classText(st.class)), 130, nextClass)
    if ui.ddFallback then ui.ddFallback:SetPoint("TOPLEFT", holder, "TOPLEFT", 160, FILTER_Y) end
  end
  A.Label(holder, T_FROM, "GameFontNormalSmall"):SetPoint("TOPLEFT", holder, "TOPLEFT", 298, FILTER_Y - 4)
  local from = K.InputBox(holder, 44, 44)
  if from then editBox(holder, from, "from", 328) end
  A.Label(holder, T_TO, "GameFontNormalSmall"):SetPoint("TOPLEFT", holder, "TOPLEFT", 378, FILTER_Y - 4)
  local to = K.InputBox(holder, 44, 44)
  if to then editBox(holder, to, "to", 396) end
  local cb = K.Checkbox(holder, T_MS)
  if cb then
    cb:SetPoint("TOPLEFT", holder, "TOPLEFT", 444, FILTER_Y + 4)
    cb:SetChecked(st.ms)
    cb:SetScript("OnClick", function(self)
      A.M.Safe(function()
        self:SetChecked(not st.ms)
        setFilter("ms", not st.ms)
      end)
    end)
  else
    ui.msFallback = A.Button(holder, T_MS_OFF, 122, function() setFilter("ms", not st.ms) end)
    if ui.msFallback then ui.msFallback:SetPoint("TOPLEFT", holder, "TOPLEFT", 444, FILTER_Y) end
  end
  ui.showing = A.Label(holder, "", "GameFontHighlightSmall")
  ui.showing:SetPoint("TOPLEFT", holder, "TOPLEFT", 4, SHOWING_Y)
  ui.footer = A.Label(holder, "", "GameFontDisableSmall")
  ui.footer:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 4, 4)
  local x = 0
  for _, h in ipairs({ { "time", "Time", TIME_W }, { "name", "Name", NAME_W }, { "levels", "Level", LEVEL_W },
    { "how", "How sure", A.Layout().inner - FIXED_W } }) do
    local b = K.ColumnHeader(holder, h[2])
    if b then
      b:SetWidth(h[3])
      b:SetPoint("TOPLEFT", holder, "TOPLEFT", x, HEADER_Y)
      ui.headers[h[1]] = b
    end
    x = x + h[3]
  end
  ui.headers.how = ui.headers.how or { SetWidth = function() end }
  ui.list = listFrom(holder)
end

ns.AnnalsLevelLog = {
  key = "levellog",
  text = "Level log",
  build = function(holder) build(holder) end,
  refresh = function() draw(true) end,
}
