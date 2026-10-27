-- GuildSyncNoticeBoard: the page shell and the Events tab (brief AC18, AC19, AC31, AC32; spec noticeboard/two-column.md
-- AC1, AC2, AC5, AC6, AC13). The hub builds the page into its window: Page.Build(frame) makes the tab buttons, the
-- Events tab's two panels (the list on the left, the detail or the New event form on the right) and hosts PageBoard's
-- Notices and Polls tabs; Page.Refresh(frame) redraws the current tab from the page frame's own size (Page.Layout).
-- AC19: the page asks the game's calendar for fresh data only when the page is shown (the page frame's OnShow, and
-- windowOpened while the page frame is shown). Refresh, Show and the resize hook never call ns.Cal.Open: the hub runs
-- refresh on every Window.Refresh and M.RefreshPage, so an Open there would loop. The page never sizes its frame.
-- State: the chosen row lives only in Event's detail (marked by detail.row.eventID); the form's state is PageCreate's;
-- the list reads PageCreate.Preview and a sorted copy of Cal.Rows (the shared table is never sorted in place).

local _, ns = ...
if not ns.M then return end

local M, C, Rules = ns.M, ns.C, ns.Rules
local Page = {}
ns.Page = Page

-- layout only
local KIT_TAB_H, OWN_TAB_H, SCROLLBAR_W = 32, 30, 26 -- the kit's tab holder is 32 tall (f4909), 0.1's buttons 30
local HEADER_H, NEW_W, BUTTON_H = 30, 120, 22
local MIN_W, MIN_H, WIDE_W, WIDE_H = 586, 388, 726, 508
local LIST_MIN, LIST_MAX, GAP = 220, 280, 10
local SCROLL_IN, SCROLL_BAR = 4, 16                -- the list's scroll inside its panel, room for its bar
local ROW_H, ROW_GAP, DAY_H, ROW_PAD = 52, 2, 20, 8
local PILL_H, PILL_MIN = 21, 70 -- PILL_MIN: the kit pill when the client does not measure it
local CARD = { 0, 0, 0, 0.42 }                     -- the panels' fill
local GOLD = { 0.541, 0.427, 0.122, 1 }            -- #8a6d1f, the thumbnail's frame
local HOVER_FILE = "Interface\\QuestFrame\\UI-QuestTitleHighlight" -- M.Kit.ListHover's fallback (d694, f4912)
local CHOSEN_FALLBACK = { 1, 0.82, 0, 0.18 }
local PILL_COLORS = { coming = { 0.25, 0.75, 0.25 }, tentative = { 0.9, 0.75, 0.2 }, notcoming = { 0.8, 0.25, 0.25 } }
local GREY = { 0.6, 0.6, 0.6 }
local WHITE = { 1, 1, 1 }
local DOT = " \194\183 " -- " · "
local DAY, HOUR = 86400, 3600
local NOT_READABLE = "not readable now"
local PREVIEW = "preview"
local TABS = { { key = "events", label = "Events" }, { key = "notices", label = "Notices" },
  { key = "polls", label = "Polls" } }
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local st = nil -- the page's state; the hub builds the page once

local function now() return math.floor(ns.Now() or 0) end

local function ago(t)
  local d = math.max(0, now() - (t or 0))
  if d < HOUR then return math.floor(d / 60) .. " min ago" end
  if d < DAY then return math.floor(d / HOUR) .. " h ago" end
  local days = math.floor(d / DAY)
  return days .. (days == 1 and " day ago" or " days ago")
end

-- ---------- the layout (pure) ----------

local function positive(v) return type(v) == "number" and v > 0 end

-- The Events tab's layout for a page frame of w x h: the list grows from 220 (586 wide) to 280 (726 wide and more),
-- the detail takes the rest; rows are compact below 726. top: the panels' top inside the tab, under the header row.
function Page.Layout(w, h)
  w = positive(w) and w or WIDE_W
  h = positive(h) and h or WIDE_H
  w, h = math.max(MIN_W, w), math.max(MIN_H, h)
  local listW = math.min(LIST_MAX, math.max(LIST_MIN, LIST_MIN + math.floor((w - MIN_W) * 60 / 140)))
  local detailW = w - listW - GAP
  local compact = w < WIDE_W
  return { w = w, h = h, listW = listW, detailW = detailW, gap = GAP, compact = compact,
    thumbW = compact and 48 or 64, thumbH = compact and 24 or 32,
    bannerW = detailW - 6, bannerH = compact and 88 or 110, top = HEADER_H }
end

-- ---------- widgets ----------

local function text(parent, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  return fs
end

local function button(parent, label, width, onClick)
  local b = ns.Look.Button(parent, label, onClick)
  b:SetSize(width, BUTTON_H)
  return b
end

local function place(f, parent, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
end

local function hhmm(t) return string.format("%02d:%02d", t.hour or 0, t.minute or 0) end

local function dayLabel(minutes)
  local t = Rules.FromMinutes(minutes)
  return (WEEKDAYS[t.weekday] or "?") .. " " .. t.monthDay .. " " .. (MONTHS[t.month] or "?")
end

-- ---------- a list row ----------

-- A row: the thumbnail in its gold frame, the title (cut, not wrapped), the type and time, my answer's pill. Event rows
-- are Buttons with the hover and chosen textures; the preview row is a plain frame (not clickable).
local function newRow(e, clickable)
  local b
  if clickable then
    b = CreateFrame("Button", nil, e.child)
    b.hover = M.Kit.ListHover(b, HOVER_FILE)
    b.chosen = b:CreateTexture(nil, "BACKGROUND")
    b.chosen:SetAllPoints(b)
    ns.Look.Atlas(b.chosen, "common-button-list-small-selected", CHOSEN_FALLBACK)
    b.chosen:Hide()
    b:SetScript("OnClick", function(self)
      if not self.row then return end
      if e.form then e.form:Hide() end -- the form keeps its fields (PageCreate resets only the banner on show)
      ns.Event.Select(self.row)
    end)
  else
    b = CreateFrame("Frame", nil, e.child)
  end
  b.border = b:CreateTexture(nil, "BORDER")
  b.border:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], GOLD[4])
  b.thumb = b:CreateTexture(nil, "ARTWORK")
  b.emblem = b:CreateTexture(nil, "OVERLAY")
  b.title = text(b, "GameFontHighlight")
  b.title:SetWordWrap(false)
  b.second = text(b, "GameFontHighlightSmall")
  b.second:SetWordWrap(false)
  b.pill = ns.Look.Pill(b)
  return b
end

-- Fills a row. item: { row = <Cal row> } or { preview = <PageCreate.Preview> }. -> nothing; the row is ROW_H tall.
local function fillRow(b, item, L, rowW, chosenID)
  local row, prev = item.row, item.preview
  b.row = row
  b:SetSize(rowW, ROW_H)
  local kind = row and row.kind or prev.kind
  local readable = prev ~= nil or (row.readable and true or false)
  local tw, th = L.thumbW, L.thumbH
  local ty = math.floor((ROW_H - th) / 2)
  local textX = ROW_PAD + tw + 10
  b.border:SetShown(readable)
  b.thumb:SetShown(readable)
  if readable then
    b.border:SetSize(tw + 2, th + 2)
    place(b.border, b, ROW_PAD - 1, ty - 1)
    b.thumb:SetSize(tw, th)
    place(b.thumb, b, ROW_PAD, ty)
    ns.Banners.Draw(b.thumb, prev and prev.banner or ns.Event.Banner(row), tw, th, b.emblem)
  else
    b.emblem:Hide()
  end

  -- my answer: none for an announcement or a nil status (f1517); the preview's grey "preview"
  local pill, color, tone
  if prev then
    pill, color, tone = PREVIEW, GREY, "grey"
  elseif row.readable and kind ~= "announcement" then
    local status = ns.Event.MyStatus(row.eventID)
    if status == nil then status = row.status end
    if status ~= nil then
      local group, label = Rules.Status(status)
      pill, color, tone = label, PILL_COLORS[group] or GREY, group
    end
  end
  local showPill = pill ~= nil and not L.compact
  ns.Look.SetPill(b.pill, showPill and pill or nil, tone)
  local pillW = 0
  if showPill then
    pillW = b.pill:GetWidth() -- the kit sizes the pill to its text (f4907)
    if not positive(pillW) then pillW = PILL_MIN end
    place(b.pill, b, rowW - ROW_PAD - pillW, math.floor((ROW_H - PILL_H) / 2))
  end
  local textW = rowW - textX - ROW_PAD - (showPill and pillW + 4 or 0)

  -- no colour codes in the text (a raw | is never drawn, AC33): colours go through SetTextColor
  local title, second, secondColor = nil, nil, WHITE
  if prev then
    title = GuildSync.Escape(prev.title) -- the typed title, as the game would store it escaped
    second = Rules.TypeLabel(kind) .. DOT .. hhmm(prev.time)
    if not showPill then second, secondColor = hhmm(prev.time) .. DOT .. pill, color end -- f4935: as a real row's
  elseif readable then
    title = Rules.ShownTitle(kind, row.title)
    second = Rules.TypeLabel(kind) .. DOT .. hhmm(row.time)
    -- compact: the pill gives way to "<time> · <answer>" (no type, so the answer is not cut), in the answer's colour
    if pill and not showPill then second, secondColor = hhmm(row.time) .. DOT .. pill, color end
  else
    title, second = row.title or "?", NOT_READABLE
  end
  b.title:SetWidth(textW)
  b.title:SetText(title)
  place(b.title, b, textX, 10)
  b.second:SetWidth(textW)
  b.second:SetText(second)
  b.second:SetTextColor(secondColor[1], secondColor[2], secondColor[3])
  place(b.second, b, textX, 29)
  if row then b.chosen:SetShown(chosenID ~= nil and row.eventID == chosenID) end -- the preview row has none
end

-- ---------- the Events tab ----------

local function buildEvents(root)
  local e = { root = root, rows = {}, heads = {} }
  e.header = text(root, "GameFontNormal")
  e.header:SetWordWrap(false)
  e.newEvent = button(root, "New event", NEW_W, function()
    if ns.Event.Detail() then ns.Event.Close() end
    if not e.form then
      e.form = CreateFrame("Frame", nil, e.detailPanel)
      e.form:SetAllPoints(e.detailPanel)
      e.form:Hide()
      ns.PageCreate.Build(e.form) -- built on first use: Build reads the calendar's date range
    end
    e.form:Show()
    Page.Refresh(st.frame)
  end)

  -- the kit's inset (marble and border) under the board's own black fill (d695, f4908)
  for _, key in ipairs({ "listPanel", "detailPanel" }) do
    local p = M.Kit.Inset(root)
    local fill = p:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(p)
    fill:SetColorTexture(CARD[1], CARD[2], CARD[3], CARD[4])
    e[key] = p
  end
  -- the list scrolls on its own
  e.scroll = ns.Look.Frame("ScrollFrame", e.listPanel, "ScrollFrameTemplate", "UIPanelScrollFrameTemplate")
  e.scroll:SetPoint("TOPLEFT", e.listPanel, "TOPLEFT", SCROLL_IN, -SCROLL_IN)
  e.scroll:SetPoint("BOTTOMRIGHT", e.listPanel, "BOTTOMRIGHT", -SCROLL_BAR, SCROLL_IN)
  e.child = CreateFrame("Frame", nil, e.scroll)
  e.child:SetSize(1, 1)
  e.scroll:SetScrollChild(e.child)
  -- the detail panel holds the chosen event (PageDetail) or the form (built on first New event)
  e.detail = CreateFrame("Frame", nil, e.detailPanel)
  e.detail:SetAllPoints(e.detailPanel)
  ns.PageDetail.Build(e.detail)
  e.preview = newRow(e, false)
  e.preview:Hide()
  return e
end

local function dayHead(e, i)
  local fs = e.heads[i]
  if not fs then
    fs = text(e.child, "GameFontNormalSmall")
    e.heads[i] = fs
  end
  return fs
end

-- A strict order: by minutes, rows with no time last; ties by the game's index (the preview after the rows).
local function before(a, b)
  if a.minutes and b.minutes then
    if a.minutes ~= b.minutes then return a.minutes < b.minutes end
  elseif a.minutes or b.minutes then
    return a.minutes ~= nil
  end
  return a.index < b.index
end

local function drawList(e, L, closed)
  local items = {}
  if not closed then
    for _, row in ipairs(ns.Cal.Rows() or {}) do
      items[#items + 1] = { row = row, minutes = row.minutes, index = row.index or 0 }
    end
    local prev = e.form and ns.PageCreate.Preview(e.form)
    if prev then items[#items + 1] = { preview = prev, minutes = Rules.Minutes(prev.time), index = math.huge } end
  end
  table.sort(items, before)

  local detail = ns.Event.Detail()
  local chosenID = detail and detail.row and detail.row.eventID
  local rowW = L.listW - SCROLL_IN - SCROLL_BAR
  local y, day, nRows, nHeads, previewShown = 0, nil, 0, 0, false
  for _, item in ipairs(items) do
    local d = item.minutes and item.minutes - item.minutes % 1440
    if d and d ~= day then
      day = d
      nHeads = nHeads + 1
      local fs = dayHead(e, nHeads)
      fs:SetText(dayLabel(d))
      fs:SetWidth(rowW - ROW_PAD)
      fs:Show()
      place(fs, e.child, ROW_PAD, y + 6)
      y = y + DAY_H
    end
    local b
    if item.preview then
      b, previewShown = e.preview, true
    else
      nRows = nRows + 1
      b = e.rows[nRows] or newRow(e, true)
      e.rows[nRows] = b
    end
    fillRow(b, item, L, rowW, chosenID)
    b:Show()
    place(b, e.child, 0, y)
    y = y + ROW_H + ROW_GAP
  end
  for i = nRows + 1, #e.rows do
    e.rows[i].row = nil
    e.rows[i]:Hide()
  end
  for i = nHeads + 1, #e.heads do e.heads[i]:Hide() end
  e.preview:SetShown(previewShown)
  e.child:SetSize(rowW, math.max(1, y))
  e.scroll:UpdateScrollChildRect()
end

local function drawEvents(e, frame)
  local L = Page.Layout(frame:GetWidth(), frame:GetHeight())
  local colH = L.h - st.tabH - L.top
  local _, readAt = ns.Cal.Rows()
  local closed = ns.Cal.Closed()
  local header = "Guild events, next " .. C.EVENT_DAYS .. " days, realm time"
  if readAt then header = header .. ", read " .. ago(readAt) end
  e.header:SetText(header)
  e.header:SetWidth(L.w - NEW_W - 10)
  place(e.header, e.root, 0, 4)
  e.newEvent:ClearAllPoints()
  e.newEvent:SetPoint("TOPRIGHT", e.root, "TOPRIGHT", 0, 0)
  e.newEvent:SetShown(not closed)

  e.listPanel:ClearAllPoints()
  e.listPanel:SetPoint("TOPLEFT", e.root, "TOPLEFT", 0, -L.top)
  e.listPanel:SetPoint("BOTTOMLEFT", e.root, "BOTTOMLEFT", 0, 0)
  e.listPanel:SetWidth(L.listW)
  e.detailPanel:ClearAllPoints()
  e.detailPanel:SetPoint("TOPRIGHT", e.root, "TOPRIGHT", 0, -L.top)
  e.detailPanel:SetPoint("BOTTOMRIGHT", e.root, "BOTTOMRIGHT", 0, 0)
  e.detailPanel:SetWidth(L.detailW)

  if closed and e.form then e.form:Hide() end
  drawList(e, L, closed)
  if e.form and e.form:IsShown() then
    e.detail:Hide()
    ns.PageCreate.Refresh(e.form, L.detailW, colH, L.compact)
  else
    e.detail:Show()
    ns.PageDetail.Draw(e.detail, L.detailW, colH, L.compact)
  end
end

-- ---------- the shell (AC31) ----------

-- f4: the Notices tab shown tells me about its notices, so the login line's "since your last login" starts from now.
local function noticesShown()
  if st and st.tab == "notices" and ns.Store then ns.Store.MarkSeen() end
end

-- AC19: the one place the page asks the game's calendar for data.
local function pageShown()
  ns.Cal.Open("page")
  noticesShown()
end

-- The Notices and Polls width: the page's width clamped as Page.Layout clamps it, less the scroll bar (d710, f4903).
local function contentW(frame)
  local w = frame:GetWidth()
  return math.max(MIN_W, positive(w) and w or WIDE_W) - SCROLLBAR_W
end

function Page.Build(frame)
  st = { frame = frame, tab = "events", roots = {}, scrolls = {}, contents = {} }
  local entries = {}
  for i, t in ipairs(TABS) do entries[i] = { key = t.key, text = t.label } end
  -- the kit's top tabs (d697); nil on a client without them: 0.1's button row
  st.tabs = M.Kit.Tabs(frame, entries, function(key) Page.Show(key) end)
  st.tabH = st.tabs and KIT_TAB_H or OWN_TAB_H
  local x = 0
  for _, t in ipairs(TABS) do
    local key = t.key
    if not st.tabs then
      local b = button(frame, t.label, 90, function() Page.Show(key) end)
      place(b, frame, x, 0)
      x = x + 94
    end
    local root = CreateFrame("Frame", nil, frame)
    root:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -st.tabH)
    root:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    st.roots[key] = root
    -- Notices and Polls: the tab's content is a scroll child (GuildSync Window.lua buildCharPage); the Events tab's
    -- panels scroll on their own instead
    if key ~= "events" then
      local scroll = CreateFrame("ScrollFrame", nil, root, "UIPanelScrollFrameTemplate")
      scroll:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
      scroll:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -SCROLLBAR_W, 0)
      local content = CreateFrame("Frame", nil, scroll)
      content:SetSize(contentW(frame), 1)
      scroll:SetScrollChild(content)
      st.scrolls[key], st.contents[key] = scroll, content
    end
  end
  st.events = buildEvents(st.roots.events)
  if ns.PageBoard then
    ns.PageBoard.Build(st.contents.notices, "notices")
    ns.PageBoard.Build(st.contents.polls, "polls")
  end
  for _, t in ipairs(TABS) do st.roots[t.key]:SetShown(t.key == st.tab) end
  if st.tabs then st.tabs:Select(st.tab) end -- Kit.Tabs starts with every tab unselected (f4905)

  frame:SetScript("OnShow", pageShown)
  -- a resize lays the page out again; hooked, never set (the frame is the hub's), and never opens the calendar
  frame:HookScript("OnSizeChanged", function()
    if st then Page.Refresh(st.frame) end
  end)
  M.On("windowOpened", function()
    if frame:IsShown() then pageShown() end
  end)
end

function Page.Refresh(frame)
  if not st then return end
  if st.tab == "events" then
    drawEvents(st.events, st.frame)
  else
    local w = contentW(st.frame)
    st.contents[st.tab]:SetWidth(w)
    if ns.PageBoard then ns.PageBoard.Refresh(st.contents[st.tab], st.tab, w) end
    st.scrolls[st.tab]:UpdateScrollChildRect()
  end
end

-- tab "events" | "notices" | "polls"
function Page.Show(tab)
  if not st or not st.roots[tab] then return end
  st.tab = tab
  for _, t in ipairs(TABS) do st.roots[t.key]:SetShown(t.key == tab) end
  if st.tabs then st.tabs:Select(tab) end
  noticesShown()
  Page.Refresh(st.frame)
end

-- ---------- the search provider's reads (Search.lua, run r-20261020-s6) ----------

-- The Events tab's rows without the preview: a sorted copy of the readable Cal.Rows() rows (f6571), {} while the
-- calendar is closed (drawList draws none then). Reads only: no client call.
function Page.Events()
  local out = {}
  if ns.Cal.Closed() then return out end
  for _, row in ipairs(ns.Cal.Rows() or {}) do
    if row.readable then out[#out + 1] = row end
  end
  table.sort(out, before)
  return out
end

-- A readable row's day and time as the Events tab writes them: "Wed 21 Oct 19:00".
function Page.When(row) return dayLabel(row.minutes - row.minutes % 1440) .. " " .. hhmm(row.time) end

-- The Events tab's row click for a row the caller kept: the current row with that eventID (a later read may have
-- moved its index, f6570); an event no longer listed shows the Events tab only.
function Page.OpenEvent(row)
  Page.Show("events")
  if st and st.events.form then st.events.form:Hide() end
  local id = type(row) == "table" and row.eventID or nil
  for _, r in ipairs(Page.Events()) do
    if r.eventID == id then
      ns.Event.Select(r)
      return
    end
  end
end
