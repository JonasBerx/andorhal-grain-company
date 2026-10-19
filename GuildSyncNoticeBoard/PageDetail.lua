-- GuildSyncNoticeBoard: the Events tab's detail panel (spec noticeboard/two-column.md AC3, AC4, AC5). Build makes the
-- pieces once; Draw lays them out from the panel's width and height for the chosen event (banner, title, sub line,
-- my answer, description, counts, who is coming in its own scroll, the respond bar at the bottom), the nothing-chosen
-- state, or a state line. Draw only reads (Event.Detail, Cal.Rows/Closed/SlotFree/ErrorLine); the respond buttons call
-- ns.Event.Respond from their OnClick only (AC24's rule is Event's: shown for an open event I may answer, disabled
-- while the game's calendar has an action pending).

local _, ns = ...
if not ns.M then return end

local Rules = ns.Rules
local PageDetail = {}
ns.PageDetail = PageDetail

local PAD, GAP, LINE, BTN_H, BAR_H, CLOSE_W, BTN_GAP, RIGHT = 8, 6, 16, 22, 36, 64, 6, 12 -- layout only
local YOU_W, PILL_MIN, COUNTS_H, PEOPLE_MIN = 34, 70, 34, 3 * LINE
local DOT = " \194\183 " -- " · "
local WAITING = "Waiting for the game's calendar."
local LOADING = "Opening the event."
local NOT_READABLE = "not readable now"
local EMPTY_PICK = "Pick an event on the left"
local EMPTY_NEW = "or New event to plan one"
local ONLINE = " (online)"
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local GROUP_LABELS = { { "coming", "Coming" }, { "standby", "Standby" }, { "tentative", "Tentative" },
  { "notcoming", "Not coming" }, { "unanswered", "Not answered" }, { "other", "Other" } }
-- the counts strip: the first four always, Standby and Other only when they have people
local COUNTS = { { "coming", "Coming" }, { "tentative", "Tentative" }, { "notcoming", "Not coming" },
  { "unanswered", "Not answered" }, { "standby", "Standby", true }, { "other", "Other", true } }
local RESPONSES = { { "signup", "Sign up" }, { "tentative", "Tentative" }, { "decline", "Decline" } }
local GREY = { 0.6, 0.6, 0.6 }

local states = setmetatable({}, { __mode = "k" }) -- panel -> its pieces

-- Weekday, day, month and 24-hour time, in the realm's calendar time.
local function when(t)
  if not t then return NOT_READABLE end
  return string.format("%s %d %s %02d:%02d", WEEKDAYS[t.weekday] or "?", t.monthDay, MONTHS[t.month] or "?",
    t.hour, t.minute)
end

local function text(parent, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  return fs
end

-- a font string's wrapped height, never less than one line
local function height(fs) return math.max(LINE, math.ceil(fs:GetStringHeight() or 0)) end

local function place(f, parent, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
end

-- sets the text and shows it, or hides it for nil or ""
local function setLine(fs, s)
  fs:SetText(s or "")
  fs:SetShown(s ~= nil and s ~= "")
  return fs:IsShown()
end

local function button(parent, label, onClick)
  return ns.Look.Button(parent, label, onClick)
end

function PageDetail.Build(panel)
  local d = { panel = panel, names = {}, headers = {}, cells = {} }
  states[panel] = d
  d.banner = panel:CreateTexture(nil, "BACKGROUND")
  d.emblem = panel:CreateTexture(nil, "ARTWORK")
  d.shade = panel:CreateTexture(nil, "BORDER")
  -- black .6 at the bottom, clear at the top; without a gradient the seam draws 0.1's flat black .6 (d703)
  ns.Look.Gradient(d.shade, 0.6, 0)
  d.title = text(panel, "GameFontNormalLarge")
  d.title:SetWordWrap(false)
  d.sub = text(panel, "GameFontHighlightSmall")
  d.by = text(panel, "GameFontHighlightSmall")
  d.you = text(panel, "GameFontHighlightSmall")
  d.you:SetText("You")
  d.pill = ns.Look.Pill(panel)
  d.line = text(panel)
  d.desc = text(panel, "GameFontHighlightSmall")
  -- the counts strip: one stone cell per group, number over label
  for i, cnt in ipairs(COUNTS) do
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    local num = text(panel, "GameFontNormal")
    local label = text(panel, "GameFontHighlightSmall")
    num:SetJustifyH("CENTER")
    label:SetJustifyH("CENTER")
    label:SetWordWrap(false) -- f4934: one line cut to the cell's width ("Not ans...") rather than a wrap out of the cell
    label:SetText(cnt[2])
    d.cells[i] = { bg = bg, num = num, label = label }
  end
  -- who is coming: its own scroll
  d.scroll = ns.Look.Frame("ScrollFrame", panel, "ScrollFrameTemplate", "UIPanelScrollFrameTemplate")
  d.child = CreateFrame("Frame", nil, d.scroll)
  d.child:SetSize(1, 1)
  d.scroll:SetScrollChild(d.child)
  -- the respond bar
  d.divider = ns.M.Kit.Divider(panel)
  d.buttons = {}
  for _, r in ipairs(RESPONSES) do
    local which = r[1]
    d.buttons[#d.buttons + 1] = button(panel, r[2], function() ns.Event.Respond(which) end)
  end
  d.close = button(panel, "Close", function() ns.Event.Close() end)
  -- nothing chosen
  d.pick = text(panel, "GameFontNormal")
  d.pick:SetJustifyH("CENTER")
  d.pick:SetText(EMPTY_PICK)
  d.next = text(panel, "GameFontHighlightSmall")
  d.next:SetJustifyH("CENTER")
  d.new = text(panel, "GameFontDisableSmall")
  d.new:SetJustifyH("CENTER")
  d.new:SetTextColor(GREY[1], GREY[2], GREY[3])
  d.new:SetText(EMPTY_NEW)
  -- the calendar's state (closed, slot held) and the error line
  d.state = text(panel)
  d.error = text(panel, "GameFontRedSmall")
end

local function hideAll(d)
  for _, f in ipairs({ d.banner, d.emblem, d.shade, d.title, d.sub, d.by, d.you, d.pill, d.line, d.desc,
    d.scroll, d.divider, d.close, d.pick, d.next, d.new, d.state, d.error }) do
    f:Hide()
  end
  for _, cell in ipairs(d.cells) do cell.bg:Hide() cell.num:Hide() cell.label:Hide() end
  for _, b in ipairs(d.buttons) do b:Hide() end
end

-- the banner across the top: (3, 3), (w - 6) x (110, or 88 compact)
local function drawBanner(d, id, w, compact)
  local bw, bh = w - 6, compact and 88 or 110
  d.banner:SetSize(bw, bh)
  place(d.banner, d.panel, 3, 3)
  ns.Banners.Draw(d.banner, id, bw, bh, d.emblem)
  d.banner:Show()
  return bw, bh
end

-- lines stacked from y, each by its wrapped height; -> the next y
local function stack(d, list, x, y, width)
  for _, fs in ipairs(list) do
    if fs:IsShown() then
      fs:SetWidth(width)
      place(fs, d.panel, x, y)
      y = y + height(fs) + GAP
    end
  end
  return y
end

-- The readable row with the soonest time (Cal.Rows is read, never sorted).
local function nextRow(rows)
  local best
  for _, row in ipairs(rows or {}) do
    if row.readable and row.minutes and (not best or row.minutes < best.minutes) then best = row end
  end
  return best
end

local function drawEmpty(d, w, compact, y)
  local row = nextRow(ns.Cal.Rows())
  if row then
    local _, bh = drawBanner(d, ns.Event.Banner(row), w, compact)
    d.banner:SetDesaturated(true)
    d.banner:SetVertexColor(0.45, 0.45, 0.45)
    y = 3 + bh + 2 * GAP
    d.pick:Show()
    setLine(d.next, "Next: " .. Rules.ShownTitle(row.kind, row.title or "?") .. ", " .. when(row.time) .. " ("
      .. Rules.TypeLabel(row.kind) .. ")")
  end
  d.new:Show()
  return stack(d, { d.pick, d.next, d.new }, PAD, y, w - 2 * PAD)
end

-- who is coming: a header per group with people, names in two columns; the child grows with them
local function drawPeople(d, groups, x, y, width, bottom)
  local child, n, m, cy = d.child, 0, 0, 0
  local colW = math.floor(width / 2)
  for _, g in ipairs(GROUP_LABELS) do
    local list = groups[g[1]]
    if list and #list > 0 then
      n = n + 1
      d.headers[n] = d.headers[n] or text(child, "GameFontNormalSmall")
      local hd = d.headers[n]
      hd:SetText(g[2] .. " (" .. #list .. ")")
      hd:SetWidth(width)
      hd:Show()
      place(hd, child, 0, cy)
      cy = cy + LINE
      for i, who in ipairs(list) do
        m = m + 1
        d.names[m] = d.names[m] or text(child, "GameFontHighlightSmall")
        local fs = d.names[m]
        fs:SetWordWrap(false)
        fs:SetWidth(colW - 4)
        fs:SetText(who.name .. (who.online and ONLINE or ""))
        fs:Show()
        place(fs, child, ((i - 1) % 2) * colW, cy)
        if i % 2 == 0 or i == #list then cy = cy + LINE end
      end
      cy = cy + 4
    end
  end
  for i = n + 1, #d.headers do d.headers[i]:Hide() end
  for i = m + 1, #d.names do d.names[i]:Hide() end
  if n == 0 then return end
  y = math.min(y, bottom - LINE) -- never over the respond bar
  place(d.scroll, d.panel, x, y)
  d.scroll:SetSize(width, math.max(LINE, bottom - y))
  child:SetSize(width, math.max(1, cy))
  d.scroll:Show()
  if d.scroll.UpdateScrollChildRect then d.scroll:UpdateScrollChildRect() end
end

local function drawCounts(d, groups, x, y, width)
  local shown = {}
  for i, cnt in ipairs(COUNTS) do
    local list = groups and groups[cnt[1]] or {}
    if not cnt[3] or #list > 0 then shown[#shown + 1] = { cell = d.cells[i], n = #list } end
  end
  local cw = math.floor((width - (#shown - 1) * 4) / #shown)
  for i, s in ipairs(shown) do
    local cx = x + (i - 1) * (cw + 4)
    ns.Look.Atlas(s.cell.bg, "groupfinder-Stat-StoneBG", { 0, 0, 0, 0.35 })
    s.cell.bg:SetSize(cw, COUNTS_H)
    place(s.cell.bg, d.panel, cx, y)
    s.cell.num:SetText(tostring(s.n))
    s.cell.num:SetWidth(cw)
    s.cell.num:Show()
    place(s.cell.num, d.panel, cx, y + 2)
    s.cell.label:SetWidth(cw)
    s.cell.label:Show()
    place(s.cell.label, d.panel, cx, y + 2 + LINE)
  end
  return y + COUNTS_H + GAP
end

local function drawChosen(d, detail, w, h, compact)
  local row = detail.row
  local bw, bh = drawBanner(d, detail.banner or ns.Event.Banner(row), w, compact)
  d.banner:SetDesaturated(false)
  d.banner:SetVertexColor(1, 1, 1)
  d.shade:SetSize(bw, math.floor(bh / 2))
  d.shade:ClearAllPoints()
  d.shade:SetPoint("BOTTOMLEFT", d.banner, "BOTTOMLEFT", 0, 0)
  d.shade:Show()

  -- my answer: no pill for an announcement, nor a nil status outside a sign-up (inviteType 1) (f1517)
  local status = detail.status
  local pill = row.kind ~= "announcement" and (status ~= nil or detail.inviteType == 1)
  local pillW = 0
  if pill then
    local group, label = "unanswered", "not answered"
    if status ~= nil then group, label = Rules.Status(status) end
    ns.Look.SetPill(d.pill, label, group)
    -- the kit sizes the pill to its text; PILL_MIN when the client does not measure
    local gw = d.pill:GetWidth()
    pillW = (type(gw) == "number" and gw > 0) and gw or PILL_MIN
  end
  local textW = bw - 2 * PAD - (pill and YOU_W + pillW or 0)
  local sub = Rules.TypeLabel(row.kind) .. DOT .. when(row.time)
  if detail.organiser and not compact then sub = sub .. DOT .. "by " .. detail.organiser end
  setLine(d.sub, sub)
  d.sub:SetWidth(textW)
  d.title:SetWidth(textW)
  -- the title follows the sub line's type label, so an rp title drops its "RP: " (f1516)
  setLine(d.title, Rules.ShownTitle(row.kind, row.title or "?"))
  local subY = 3 + bh - PAD - height(d.sub)
  place(d.sub, d.panel, 3 + PAD, subY)
  place(d.title, d.panel, 3 + PAD, subY - height(d.title))
  if pill then
    -- "You", then the pill ending PAD inside the banner's right edge
    local px = 3 + bw - PAD - pillW - YOU_W
    d.you:SetWidth(YOU_W - 4)
    d.you:Show()
    place(d.you, d.panel, px, subY)
    place(d.pill, d.panel, px + YOU_W, subY - 3) -- the 21-tall pill centred on the sub line
  end

  local y = 3 + bh + GAP
  if compact and detail.organiser then setLine(d.by, "by " .. detail.organiser) end
  local line = detail.line
  if detail.pending then line = WAITING
  elseif line == WAITING then line = nil end
  if not line and detail.state == "loading" then line = LOADING end
  setLine(d.line, line)
  setLine(d.desc, detail.description)
  local tw, barY = w - 2 * PAD, h - BAR_H
  y = stack(d, { d.by, d.line }, PAD, y, tw)
  -- R-f4: the description gives up lines so the state and error lines, the counts and a few people rows still fit
  -- above the respond bar
  local counts = detail.state == "open" and row.kind ~= "announcement"
  local below = (counts and COUNTS_H + GAP or 0) + (detail.state == "open" and detail.groups and PEOPLE_MIN or 0)
  for _, fs in ipairs({ d.state, d.error }) do
    if fs:IsShown() then
      fs:SetWidth(tw)
      below = below + height(fs) + GAP
    end
  end
  if d.desc:IsShown() then
    d.desc:SetWidth(tw)
    local room, dh = barY - GAP - below - y - GAP, height(d.desc)
    if d.desc.SetMaxLines then d.desc:SetMaxLines(0) end
    d.desc:SetHeight(0)
    if dh > room then
      local lines = math.floor(room / LINE)
      dh = lines * LINE
      if lines < 1 then d.desc:Hide()
      else
        if d.desc.SetMaxLines then d.desc:SetMaxLines(lines) end
        d.desc:SetHeight(dh)
      end
    end
    if d.desc:IsShown() then
      place(d.desc, d.panel, PAD, y)
      y = y + dh + GAP
    end
  end
  y = stack(d, { d.state, d.error }, PAD, y, tw)

  if counts then
    y = drawCounts(d, detail.groups, PAD, y, w - 2 * PAD)
  end
  if detail.state == "open" and detail.groups then
    drawPeople(d, detail.groups, PAD, y, w - PAD - 30, barY - GAP)
  end

  -- AC24: shown for an event I may answer, disabled (not hidden) while the game's calendar has an action pending
  d.divider:SetWidth(w - 2 * PAD)
  place(d.divider, d.panel, PAD, barY - 4)
  d.divider:Show()
  local respond = detail.state == "open" and detail.canRespond and true or false
  local btnW = compact and 76 or 96
  local x = w - RIGHT - CLOSE_W
  d.close:SetSize(CLOSE_W, BTN_H)
  place(d.close, d.panel, x, barY)
  d.close:Show()
  for i = #d.buttons, 1, -1 do
    local b = d.buttons[i]
    b:SetEnabled(not detail.pending)
    if respond then
      x = x - BTN_GAP - btnW
      b:SetSize(btnW, BTN_H)
      place(b, d.panel, x, barY)
      b:Show()
    end
  end
end

function PageDetail.Draw(panel, w, h, compact)
  local d = states[panel]
  if not d then return end
  hideAll(d)
  local closed, closedLine = ns.Cal.Closed()
  local free, slotLine = ns.Cal.SlotFree()
  local detail = not closed and ns.Event and ns.Event.Detail() or nil
  -- the slot line once: Event's own detail.line may already say it
  local stateLine = closed and closedLine or (not free and not (detail and detail.line == slotLine) and slotLine) or nil
  setLine(d.state, stateLine)
  setLine(d.error, not closed and ns.Cal.ErrorLine() or nil)
  if closed then
    stack(d, { d.state }, PAD, PAD, w - 2 * PAD)
  elseif detail then
    drawChosen(d, detail, w, h, compact)
  else
    local y = drawEmpty(d, w, compact, PAD)
    stack(d, { d.state, d.error }, PAD, y, w - 2 * PAD)
  end
end
