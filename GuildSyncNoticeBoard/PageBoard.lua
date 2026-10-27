-- GuildSyncNoticeBoard: the Notices and Polls tabs (brief AC6, AC7, AC10, AC11, AC13, AC14, AC17, AC31-AC34 as sliced
-- by ui-slice.md; every read and write goes through ns.Store, which syncs). Page.lua hosts a tab in a frame: PageBoard.Build(root, tab) makes the
-- fixed parts once, PageBoard.Refresh(root, tab, width) redraws them from ns.Store. Officers get the post form, Edit,
-- Remove and Close; everyone gets the list, its ages and the vote buttons. Refresh never writes an EditBox, so an edit
-- in progress survives every redraw. The one page subscription is the roster read below (AC34: a promoted member gets
-- the officer controls without a reload). Every notice and poll string is escaped at display.
-- t55 (plan d696-d704, d710): one M.Kit.Card per notice, per poll and per officer form, at Refresh's width (708 when
-- none is given); pills for pinned and open/closed; Look.Input boxes; Runs for and Open for through Look.Dropdown
-- (the 0.1 steppers when it answers nil); Pinned as M.Kit.Checkbox (the 0.1 toggle when nil); poll option rows with
-- the name and "Vote" as two click targets on the one Store.Vote path (d704); officer buttons on a M.Kit.Divider strip.

local _, ns = ...
if not ns.M then return end

local M, C, Rules = ns.M, ns.C, ns.Rules
local PageBoard = {}
ns.PageBoard = PageBoard

local DAY, HOUR = 86400, 3600
-- layout only. WIDE_W: the width when Refresh gets none; PAD: a card's inner margin; SIDE_W: Runs for / Open for and
-- Pinned beside the title or question.
local WIDE_W, PAD, LINE, GAP, CARD_GAP, BUTTON_H = 708, 12, 16, 6, 8, 22
local DD_W, STEP_W, VALUE_W, CB_W, SIDE_W = 104, 26, 44, 30, 202
local META_W, PILL_W, FIELD_W = 220, 70, 470 -- FIELD_W: the title or question box at its widest
local ROW_H, NAME_X, NAME_W, BAR_X, BAR_MAX, VOTE_W, VOTERS_MIN = 32, 5, 128, 138, 260, 70, 120 -- an option row (d704)
-- M.Kit.StatBar's .fill (the inner track) sits this far in from each end of the bar (API.md, M.Kit.StatBar)
local TRACK_INSET = 6

local NOTICE_LINE = "Every guildmate with the addon receives this. Keep officer matters out."
local POLL_LINE = "Every guildmate with the addon receives this poll. Keep officer matters out."
local OFFICERS_LINE = "Only officers with the addon receive this."

-- d1015: the notice form's yellow line follows the Officers only tick (an edit keeps its domain)
local function noticeLine(st, f)
  f.line:SetText((f.officers and not st.editing) and OFFICERS_LINE or NOTICE_LINE)
end
local VOTES_LINE = "Votes are not secret: every guildmate's addon receives them."

local states = setmetatable({}, { __mode = "k" }) -- root frame -> this tab's UI state

local function esc(s) return GuildSync.Escape(tostring(s or "")) end
local function now() return math.floor(ns.Now() or 0) end

local function ago(t)
  local d = math.max(0, now() - (t or 0))
  if d < HOUR then return math.floor(d / 60) .. " min ago" end
  if d < DAY then return math.floor(d / HOUR) .. " h ago" end
  local days = math.floor(d / DAY)
  return days .. (days == 1 and " day ago" or " days ago")
end

local function span(hours)
  if hours % 24 == 0 then
    local days = hours / 24
    return days .. (days == 1 and " day" or " days")
  end
  return hours .. (hours == 1 and " hour" or " hours")
end

local function nameOf(key)
  return esc(ns.MemberName(key))
end

-- From the last rosterRead (it hands partial; a read means known), so a redraw copies no roster (f6).
local rosterKnown, rosterPartial = false, false

-- known and not partial, and whether I am an officer then.
local function rosterState()
  local Comm = GuildSync.Comm
  local ready = rosterKnown and not rosterPartial
  local me = Comm.MyKey()
  -- R-demo: demo shows the officer's view (AC19); every write stays inert in Store
  return ready, ready and (ns.InDemo() or (me ~= nil and Comm.IsOfficer(me))), me
end

-- ---------- widgets ----------

local function text(parent, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  rawset(fs, "isText", true) -- stack measures it with GetStringHeight (f1)
  return fs
end

-- f1: a font string's wrapped height, any other frame's own height; never less than one line.
local function height(f)
  if rawget(f, "isText") then return math.max(LINE, math.ceil(f:GetStringHeight() or 0)) end
  local h = f:GetHeight()
  return math.max(LINE, type(h) == "number" and h or 0)
end

local function button(parent, label, width, onClick)
  local b = ns.Look.Button(parent, label, onClick)
  b:SetSize(width, BUTTON_H)
  return b
end

-- An EditBox's text; anything but a string (a box never typed in) reads as empty.
local function value(e)
  local t = e:GetText()
  return type(t) == "string" and t or ""
end

-- f at (x, y) from parent's top left; width when given.
local function place(f, parent, x, y, width)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  if width then f:SetWidth(width) end
end

-- Lays shown items top to bottom from (x, y) inside parent, each stepped by its real height (f1), texts width wide;
-- returns the y below the last.
local function stack(parent, items, x, y, width)
  for _, f in ipairs(items) do
    if f:IsShown() then
      place(f, parent, x + (rawget(f, "indent") or 0), y, rawget(f, "isText") and width or nil)
      y = y + height(f) + GAP
    end
  end
  return y
end

-- The shown buttons in one row ending PAD inside card's right edge at y, in list order; true when any is shown.
local function rightRow(card, y, list)
  local prev
  for i = #list, 1, -1 do
    local b = list[i]
    if b:IsShown() then
      b:ClearAllPoints()
      if prev then b:SetPoint("TOPRIGHT", prev, "TOPLEFT", -4, 0) else b:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PAD, -y) end
      prev = b
    end
  end
  return prev ~= nil
end

local function say(st, line)
  st.note:SetText(line and esc(line) or "")
  st.note:SetShown(line ~= nil)
end

-- After a Store write: the line on refusal, then the redraw.
local function done(st, ok, why)
  say(st, not ok and why or nil)
  M.RefreshPage()
  return ok
end

local function redraw(st) PageBoard.Refresh(st.root, st.tab, st.width) end

-- ---------- forms ----------

-- Runs for / Open for through Look.Dropdown (d699): one radio per value the 0.1 steppers reach (hours each); nil keeps
-- the steppers. The text follows the pick through GenerateMenu in placeSide (f4901).
local function hoursDropdown(f, form, field, values, per)
  return ns.Look.Dropdown(form, DD_W, function(_, root)
    root:SetScrollMode(15 * 20)
    for _, v in ipairs(values) do
      root:CreateRadio(span(v * per), function(d) return f[field] == d end,
        function(d) M.Safe(function() f[field] = d end) end, v)
    end
  end)
end

-- The 0.1 - / + steppers with their value between, for a client without the dropdown.
local function steppers(st, f, form, less, more)
  f.less = button(form, "-", STEP_W, function() less() redraw(st) end)
  f.value = form:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.value:SetWidth(VALUE_W)
  f.value:SetJustifyH("CENTER")
  f.more = button(form, "+", STEP_W, function() more() redraw(st) end)
end

local function placeSide(f, form, x, y, shown)
  if f.dd then
    place(f.dd, form, x, y)
    f.dd:GenerateMenu() -- the text follows the selection (d699)
    return
  end
  place(f.less, form, x, y)
  f.value:ClearAllPoints()
  f.value:SetPoint("LEFT", f.less, "RIGHT", 4, 0)
  f.value:SetText(shown)
  f.more:ClearAllPoints()
  f.more:SetPoint("LEFT", f.value, "RIGHT", 4, 0)
end

local function buildNoticeForm(st, form)
  local f = {}
  f.line = text(form, "GameFontNormal")
  f.line:SetText(NOTICE_LINE)
  f.titleLabel = text(form)
  f.titleLabel:SetText("Title")
  f.title = ns.Look.Input(form, FIELD_W, C.NOTICE_TITLE)
  f.sideLabel = text(form)
  f.sideLabel:SetText("Runs for")
  f.bodyLabel = text(form)
  f.bodyLabel:SetText("Text")
  f.body = ns.Look.Input(form, WIDE_W - 2 * PAD, C.NOTICE_BODY)
  f.days = C.NOTICE_DAYS
  f.pinned, f.officers = false, false
  local days = {}
  for d = 1, C.NOTICE_DAYS_MAX do days[d] = d end
  f.dd = hoursDropdown(f, form, "days", days, 24)
  if not f.dd then
    steppers(st, f, form, function() f.days = math.max(1, f.days - 1) end,
      function() f.days = math.min(C.NOTICE_DAYS_MAX, f.days + 1) end)
  end
  f.pinBox = M.Kit.Checkbox(form, "Pinned")
  if f.pinBox then
    f.pinBox:SetScript("OnClick", function(self)
      M.Safe(function() f.pinned = self:GetChecked() and true or false end)
    end)
  else
    f.pin = button(form, "Pinned: no", 120, function()
      f.pinned = not f.pinned
      redraw(st)
    end)
  end
  -- AC18: fixed at post, so hidden while editing; Store reads fields.officers
  f.offBox = M.Kit.Checkbox(form, "Officers only")
  if f.offBox then
    f.offBox:SetScript("OnClick", function(self)
      M.Safe(function()
        f.officers = self:GetChecked() and true or false
        noticeLine(st, f)
      end)
    end)
  else
    f.off = button(form, "Officers only: no", 140, function()
      f.officers = not f.officers
      redraw(st)
    end)
  end
  local function reset()
    st.editing = nil
    f.title:SetText("")
    f.body:SetText("")
    f.days, f.pinned, f.officers = C.NOTICE_DAYS, false, false
    noticeLine(st, f)
  end
  f.commit = button(form, "Post notice", 120, function()
    local fields = { title = value(f.title), body = value(f.body), days = f.days, pinned = f.pinned,
      officers = f.officers }
    local ok, why
    if st.editing then ok, why = ns.Store.Edit(st.editing, fields) else ok, why = ns.Store.Post(fields) end
    if ok then reset() end
    done(st, ok, why)
    redraw(st)
  end)
  f.cancel = button(form, "Cancel", 80, function()
    reset()
    redraw(st)
  end)
  st.form = f
end

local function buildPollForm(st, form)
  local f = {}
  f.line = text(form, "GameFontNormal")
  f.line:SetText(POLL_LINE)
  f.votesLine = text(form, "GameFontNormal")
  f.votesLine:SetText(VOTES_LINE)
  f.questionLabel = text(form)
  f.questionLabel:SetText("Question")
  f.question = ns.Look.Input(form, FIELD_W, C.POLL_Q)
  f.sideLabel = text(form)
  f.sideLabel:SetText("Open for")
  f.optionsLabel = text(form)
  f.optionsLabel:SetText("Options (" .. C.POLL_OPTS_MIN .. " to " .. C.POLL_OPTS_MAX .. "; leave the rest empty)")
  f.options = {}
  for i = 1, C.POLL_OPTS_MAX do f.options[i] = ns.Look.Input(form, 214, C.POLL_OPT) end
  f.hours = C.POLL_HOURS
  -- the steppers' values: hour by hour below a day, then day by day
  local hours = {}
  for h = C.POLL_HOURS_MIN, 23 do hours[#hours + 1] = h end
  for h = 24, C.POLL_HOURS_MAX, 24 do hours[#hours + 1] = h end
  f.dd = hoursDropdown(f, form, "hours", hours, 1)
  if not f.dd then
    steppers(st, f, form, function() f.hours = math.max(C.POLL_HOURS_MIN, f.hours - (f.hours > 24 and 24 or 1)) end,
      function() f.hours = math.min(C.POLL_HOURS_MAX, f.hours + (f.hours >= 24 and 24 or 1)) end)
  end
  f.commit = button(form, "Post poll", 120, function()
    local options = {}
    for _, e in ipairs(f.options) do
      local o = value(e)
      if o ~= "" then options[#options + 1] = o end
    end
    local ok, why = ns.Store.PostPoll({ question = value(f.question), options = options, hours = f.hours })
    if ok then
      f.question:SetText("")
      for _, e in ipairs(f.options) do e:SetText("") end
      f.hours = C.POLL_HOURS
    end
    done(st, ok, why)
    redraw(st)
  end)
  st.form = f
end

-- Lays the form card out at width w; returns its height.
local function layoutForm(st, w)
  local f, form = st.form, st.formFrame
  local inner = w - 2 * PAD
  local fieldW = math.min(FIELD_W, inner - 16 - SIDE_W)
  local sideX = PAD + fieldW + 16
  local notices = st.tab == "notices"
  if notices then noticeLine(st, f) end
  local y = stack(form, notices and { f.line } or { f.line, f.votesLine }, PAD, 9, inner)
  place(notices and f.titleLabel or f.questionLabel, form, PAD, y, fieldW)
  place(f.sideLabel, form, sideX, y, SIDE_W)
  y = y + LINE + 2
  place(notices and f.title or f.question, form, PAD, y, fieldW)
  if notices then
    placeSide(f, form, sideX, y, "Runs " .. span(f.days * 24))
    if f.pinBox then
      place(f.pinBox, form, sideX + DD_W + 16, y - 2)
      f.pinBox:SetChecked(f.pinned)
    end
    y = y + CB_W + GAP
    place(f.bodyLabel, form, PAD, y, fieldW)
    local offShown = f.offBox ~= nil and st.editing == nil
    if f.offBox then
      f.offBox:SetShown(offShown)
      place(f.offBox, form, sideX, y - 6) -- under Runs for: the label does not fit under Pinned
      f.offBox:SetChecked(f.officers)
    end
    y = y + (offShown and CB_W - 6 or LINE + 2)
    place(f.body, form, PAD, y, inner)
    y = y + 20 + 2 * GAP
    f.commit:SetText(st.editing and "Save" or "Post notice")
    f.cancel:SetShown(st.editing ~= nil)
    if f.pin then
      f.pin:SetText(f.pinned and "Pinned: yes" or "Pinned: no")
      place(f.pin, form, PAD, y)
    end
    if f.off then
      f.off:SetShown(st.editing == nil)
      f.off:SetText(f.officers and "Officers only: yes" or "Officers only: no")
      place(f.off, form, PAD + (f.pin and 124 or 0), y)
    end
    rightRow(form, y, { f.commit, f.cancel })
    return y + BUTTON_H + 10
  end
  placeSide(f, form, sideX, y, "Open for " .. span(f.hours))
  y = stack(form, { f.optionsLabel }, PAD, y + CB_W + GAP, inner)
  local optW = math.floor((inner - 2 * 8) / 3)
  for i, e in ipairs(f.options) do
    place(e, form, PAD + ((i - 1) % 3) * (optW + 8), y + math.floor((i - 1) / 3) * (20 + GAP), optW)
  end
  y = y + math.ceil(#f.options / 3) * (20 + GAP) + GAP
  rightRow(form, y, { f.commit })
  return y + BUTTON_H + 10
end

-- ---------- cards ----------

-- One poll option row, 32 tall (d704): the name (a templateless Button, the vote target while I may vote, else a
-- label), the StatBar with the board's fill and the count, the voters, "Vote" at the right while I may vote. Both
-- targets run the one Store.Vote path.
local function newRow(st, s, i)
  local r = { frame = CreateFrame("Frame", nil, s.frame) }
  r.frame:SetHeight(ROW_H)
  local function vote()
    if not (s.key and s.voteNow) then return end
    done(st, ns.Store.Vote(s.key, i))
    redraw(st)
  end
  r.name = CreateFrame("Button", nil, r.frame)
  r.name:SetSize(NAME_W, BUTTON_H)
  local fs = r.name:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", r.name, "LEFT", 0, 0)
  fs:SetWidth(NAME_W)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  r.name:SetFontString(fs)
  r.name:SetNormalFontObject("GameFontHighlight")
  r.name:SetDisabledFontObject("GameFontHighlight") -- a label reads as one, not dimmed
  r.name:SetScript("OnClick", vote)
  r.name:SetPoint("LEFT", r.frame, "LEFT", NAME_X, 0)
  r.bar = M.Kit.StatBar(r.frame)
  local host = r.bar and (r.bar.fill or r.bar) or r.frame
  if r.bar then
    r.bar:SetPoint("LEFT", r.frame, "LEFT", BAR_X, 0)
    -- the fill grows from the left of the bar's inner track (.fill), never over the bar's bevelled ends
    r.fill = host:CreateTexture(nil, "ARTWORK")
    if r.bar.fill then
      r.fill:SetPoint("LEFT", r.bar.fill, "LEFT", 0, 0)
    else
      r.fill:SetPoint("TOPLEFT", r.bar, "TOPLEFT", 0, -7)
    end
    r.fill:SetHeight(15)
    r.fill:SetColorTexture(0.1, 0.6, 0.1, 0.9)
  end
  -- on the bar's fill frame, so it draws above the fill
  r.count = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.count:SetPoint("CENTER", host, "CENTER", 0, 0)
  r.voters = r.frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  r.voters:SetJustifyH("LEFT")
  r.voters:SetWordWrap(false)
  r.vote = button(r.frame, "Vote", VOTE_W, vote)
  r.vote:SetPoint("RIGHT", r.frame, "RIGHT", 0, 0)
  return r
end

local function newSlot(st)
  local p = M.Kit.Card(st.root, WIDE_W, 1) or CreateFrame("Frame", nil, st.root)
  local s = { frame = p, rows = {} }
  s.title = text(p, "GameFontNormal")
  s.pill = ns.Look.Pill(p)
  s.tag = ns.Look.Pill(p) -- "Officers only", left of the pinned pill (AC18)
  s.meta = text(p, "GameFontDisableSmall")
  s.meta:SetJustifyH("RIGHT")
  s.body = text(p)
  s.state = text(p)
  s.voted = text(p)
  s.tally = text(p)
  s.waiting = text(p, "GameFontDisable")
  s.waiting:SetText("Looking for your earlier votes; voting opens within two minutes.")
  for i = 1, C.POLL_OPTS_MAX do s.rows[i] = newRow(st, s, i) end
  s.divider = M.Kit.Divider(p)
  s.edit = button(p, "Edit", 70, function()
    local rec = s.rec
    if not rec then return end
    local f = st.form
    st.editing = rec.key
    f.title:SetText(rec.title or "")
    f.body:SetText(rec.body or "")
    f.pinned = rec.pinned and true or false
    local left = math.ceil(((rec.expiresAt or now()) - now()) / DAY)
    f.days = math.min(C.NOTICE_DAYS_MAX, math.max(1, left))
    say(st, nil)
    redraw(st)
  end)
  s.remove = button(p, "Remove", 80, function()
    if s.key then done(st, ns.Store.Remove(s.key)) end
    redraw(st)
  end)
  s.close = button(p, "Close now", 90, function()
    if s.key then done(st, ns.Store.ClosePoll(s.key)) end
    redraw(st)
  end)
  st.slots[#st.slots + 1] = s
  return s
end

local function hideAll(s)
  for _, f in ipairs({ s.body, s.state, s.voted, s.tally, s.waiting, s.edit, s.remove, s.close }) do f:Hide() end
  ns.Look.SetPill(s.pill, nil)
  ns.Look.SetPill(s.tag, nil)
  if s.divider then s.divider:Hide() end
  for _, r in ipairs(s.rows) do r.frame:Hide() end
end

-- Lays out a slot's card at width w: the title with the pill and "posted by" at the right, its lines, its option
-- rows, then the officer strip; returns its height.
local function layoutSlot(s, w)
  local p, inner = s.frame, w - 2 * PAD
  p:SetWidth(w)
  s.meta:ClearAllPoints()
  s.meta:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -9)
  s.meta:SetWidth(META_W)
  s.pill:ClearAllPoints()
  s.pill:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(PAD + META_W + 8), -6)
  local tagged = type(s.tag) == "table" and s.tag:IsShown()
  if tagged then
    s.tag:ClearAllPoints()
    if s.pill:IsShown() then
      s.tag:SetPoint("TOPRIGHT", s.pill, "TOPLEFT", -4, 0)
    else
      s.tag:SetPoint("TOPRIGHT", p, "TOPRIGHT", -(PAD + META_W + 8), -6)
    end
  end
  place(s.title, p, PAD, 9, inner - META_W - PILL_W - 16 - (tagged and PILL_W + 4 or 0))
  -- the meta wraps in its META_W box (a long name stays whole), so the lines start below the taller of the two
  local top = 9 + math.max(height(s.title), height(s.meta)) + GAP
  local y = stack(p, { s.body, s.state, s.voted, s.tally, s.waiting }, PAD, top, inner)
  local rows = false
  for _, r in ipairs(s.rows) do
    if r.frame:IsShown() then
      place(r.frame, p, PAD, y, inner)
      y, rows = y + ROW_H, true
    end
  end
  if rows then y = y + GAP end
  local strip = rightRow(p, y + 8, { s.edit, s.close, s.remove })
  if s.divider then
    s.divider:ClearAllPoints()
    s.divider:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -y)
    s.divider:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -y)
    s.divider:SetShown(strip)
  end
  if strip then y = y + 8 + BUTTON_H + GAP end
  local h = y + 4
  p:SetHeight(h)
  return h
end

local function fillNotice(st, s, rec, officer)
  s.title:SetText(esc(rec.title))
  ns.Look.SetPill(s.pill, rec.pinned and "pinned" or nil, "gold")
  ns.Look.SetPill(s.tag, rec.officers and "Officers only" or nil, "red")
  s.meta:SetText("posted by " .. nameOf(rec.author) .. ", " .. ago(Rules.KeyTime(rec.key)))
  if rec.removed then
    s.state:SetText("Removed by an officer.")
    s.state:Show()
    return
  end
  if rec.body and rec.body ~= "" then
    s.body:SetText(esc(rec.body))
    s.body:Show()
  end
  s.edit:SetShown(officer)
  s.remove:SetShown(officer)
end

-- One option row's bar, count and voters at row width rw; the fill only when there are votes (no division by 0).
local function fillRow(s, r, o, count, total, names, rw)
  r.name:SetText(esc(o))
  r.name:SetEnabled(s.voteNow)
  r.vote:SetShown(s.voteNow)
  local voteW = s.voteNow and VOTE_W or 0 -- the hidden Vote's room goes to the voters
  local barW = math.max(60, math.min(BAR_MAX, rw - BAR_X - 8 - VOTERS_MIN - 8 - voteW))
  if r.bar then
    r.bar:SetWidth(barW)
    -- the inner track's width: the bar less the inset at each end (set here, not measured: .fill may not be laid out yet)
    local trackW = r.bar.fill and barW - 2 * TRACK_INSET or barW
    if total > 0 and count > 0 then
      r.fill:SetWidth(math.max(1, math.floor(trackW * count / total + 0.5)))
      r.fill:Show()
    else
      r.fill:Hide()
    end
  end
  r.count:SetText(tostring(count))
  if names and #names > 0 then
    local shown = {}
    for j, n in ipairs(names) do shown[j] = esc(n) end
    r.voters:SetText(table.concat(shown, ", "))
    r.voters:Show()
  else
    r.voters:Hide()
  end
  r.voters:ClearAllPoints()
  r.voters:SetPoint("LEFT", r.bar or r.frame, r.bar and "RIGHT" or "LEFT", 8, 0)
  r.voters:SetWidth(math.max(1, rw - BAR_X - barW - 8 - 8 - voteW))
  r.frame:Show()
end

local function fillPoll(st, s, rec, officer, canVote, inner)
  local t = now()
  s.title:SetText(esc(rec.question))
  s.meta:SetText("posted by " .. nameOf(rec.author) .. ", " .. ago(Rules.KeyTime(rec.key)))
  if rec.removed then
    s.state:SetText("Removed by an officer.")
    s.state:Show()
    return
  end
  local open = t < rec.closeAt
  ns.Look.SetPill(s.pill, open and "open" or "closed", open and "green" or "grey")
  s.state:SetText(open and ("Open, closes in " .. span(math.max(1, math.ceil((rec.closeAt - t) / HOUR)))) or "Closed.")
  s.state:Show()
  local mine = ns.Store.MyVote(rec.key)
  if mine and rec.options[mine] then
    s.voted:SetText("You voted: " .. esc(rec.options[mine]))
    s.voted:Show()
  end
  local counts, total, voters = ns.Store.Tally(rec.key)
  total = total or 0
  s.tally:SetText(total .. (total == 1 and " vote" or " votes") .. ", as heard by this client")
  s.tally:Show()
  -- AC13: until my earlier votes are heard, one waiting line and no Vote targets
  local waiting = (open and ns.Store.VoteWaiting and ns.Store.VoteWaiting()) and true or false
  s.waiting:SetShown(waiting)
  -- in demo the targets show and a click says the inert line (AC43); Store.CanVote is false there
  s.voteNow = (open and not waiting and canVote and not mine and (ns.InDemo() or ns.Store.CanVote(rec.key))) and true
    or false
  for i, o in ipairs(rec.options) do
    if i > C.POLL_OPTS_MAX then break end
    fillRow(s, s.rows[i], o, (counts and counts[i]) or 0, total, voters and voters[i], inner)
  end
  s.close:SetShown(officer and open)
  s.remove:SetShown(officer)
end

-- RC2 readers: the sorts skip a record without a number rev
local function sortedNotices()
  local t, out = now(), {}
  for _, rec in ipairs(ns.Store.Notices()) do
    if type(rec.rev) == "number" and (rec.removed or t < (rec.expiresAt or 0)) then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b)
    if (a.pinned and true or false) ~= (b.pinned and true or false) then return a.pinned and true or false end
    return (Rules.KeyTime(a.key) or 0) > (Rules.KeyTime(b.key) or 0)
  end)
  return out
end

local function sortedPolls()
  local t, out = now(), {}
  for _, rec in ipairs(ns.Store.Polls()) do
    if type(rec.rev) == "number" then out[#out + 1] = rec end -- RC2: skip a record with no rev
  end
  local function isOpen(rec) return not rec.removed and t < rec.closeAt end
  table.sort(out, function(a, b)
    if isOpen(a) ~= isOpen(b) then return isOpen(a) end
    return (Rules.KeyTime(a.key) or 0) > (Rules.KeyTime(b.key) or 0)
  end)
  return out
end

-- ---------- the tab ----------

function PageBoard.Build(root, tab)
  local st = { root = root, tab = tab, slots = {} }
  states[root] = st
  st.wait = text(root)
  st.wait:SetText("Waiting for the guild roster.")
  st.lastUpdate = text(root)
  st.note = text(root)
  st.note:Hide()
  st.formFrame = M.Kit.Card(root, WIDE_W, 1) or CreateFrame("Frame", nil, root)
  if tab == "polls" then buildPollForm(st, st.formFrame) else buildNoticeForm(st, st.formFrame) end
  st.empty = text(root)
  st.empty:SetText(tab == "polls" and "No polls." or "No notices.")
end

-- width: the tab's content width (Page.lua clamps it, d710); nil or not positive means WIDE_W.
function PageBoard.Refresh(root, tab, width)
  local st = states[root]
  if not st then return end
  st.width = width
  local w = (type(width) == "number" and width > 0) and width or WIDE_W
  local ready, officer = rosterState()
  st.wait:SetShown(not ready)
  st.formFrame:SetShown(officer and true or false)
  if not officer then st.editing = nil end
  -- AC43: demo on or off ends an edit in progress (its key may be a made-up record's); Event.lua's "demo" handler
  -- refreshes the page, so no second subscription here
  local demo = ns.InDemo()
  if st.demo ~= demo then st.editing, st.demo = nil, demo end

  local last = ns.Store.LastOfficerUpdate()
  if not ns.Store.OfficerHeardThisSession() and last then
    st.lastUpdate:SetText("No officer heard this session; last officer update " .. ago(last) .. ".")
    st.lastUpdate:Show()
  else
    st.lastUpdate:Hide()
  end

  local y = stack(root, { st.wait, st.lastUpdate, st.note }, 0, 0, w)
  if officer then
    st.formFrame:SetWidth(w)
    local h = layoutForm(st, w)
    st.formFrame:SetHeight(h)
    place(st.formFrame, root, 0, y)
    y = y + h + CARD_GAP
  end

  local list = st.tab == "polls" and sortedPolls() or sortedNotices()
  local _, _, me = rosterState()
  local canVote = ready and me ~= nil and GuildSync.Comm.Member(me) ~= nil -- as Store's voteCheck (AC13, f7)
  st.empty:SetShown(#list == 0)
  if #list == 0 then
    place(st.empty, root, 0, y, w)
    y = y + height(st.empty) + GAP
  end
  for i, rec in ipairs(list) do
    local s = st.slots[i] or newSlot(st)
    s.key, s.rec = rec.key, rec
    hideAll(s)
    if st.tab == "polls" then
      fillPoll(st, s, rec, officer, canVote, w - 2 * PAD)
    else
      fillNotice(st, s, rec, officer)
    end
    s.frame:Show()
    local h = layoutSlot(s, w)
    place(s.frame, root, 0, y)
    y = y + h + CARD_GAP
  end
  for i = #list + 1, #st.slots do
    st.slots[i].key, st.slots[i].rec = nil, nil
    st.slots[i].frame:Hide()
  end
  root:SetHeight(math.max(1, y)) -- f1: Page.lua's scroll child; the scroll range follows it
end

-- AC34: a promoted (or demoted) member's controls follow the next roster read, no reload.
M.On("rosterRead", function(partial)
  rosterKnown, rosterPartial = true, partial and true or false
  M.RefreshPage()
end)

-- ---------- the search provider's reads (Search.lua, run r-20261020-s6) ----------

-- The tabs' own lists (f6553): RC2 and expiry as drawn; removed records are still in them.
function PageBoard.Notices() return sortedNotices() end
function PageBoard.Polls() return sortedPolls() end

-- The poll card's "closes in <span>" at t, or nil once the poll is closed.
function PageBoard.ClosesIn(rec, t)
  if type(rec) ~= "table" or type(rec.closeAt) ~= "number" or type(t) ~= "number" then return nil end
  if t >= rec.closeAt then return nil end
  return "closes in " .. span(math.max(1, math.ceil((rec.closeAt - t) / HOUR)))
end
