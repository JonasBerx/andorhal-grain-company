-- GuildSyncNoticeBoard: the New event form's day grid and time pick (spec noticeboard/two-column.md AC11, AC12, AC15,
-- AC16). PageWhen.Build(parent, pick, onChange) makes every frame once; PageWhen.Draw lays them out from the width it
-- is given and returns the height used. The grid shows six weeks (42 days, Monday first) from the week of today and
-- pages six weeks at a time up to maxDate. pick = { date = { year, month, monthDay } | nil, hour, minute } belongs to
-- the caller: PageWhen changes it only inside a click or a dropdown pick, then calls onChange().
-- No calendar call here: today, maxDate and the days with events (from Cal.Rows) come from the caller.

local _, ns = ...
if not ns.M then return end

local C, Rules = ns.C, ns.Rules
local PageWhen = {}
ns.PageWhen = PageWhen

local CELL_W, CELL_H, PITCH_X, PITCH_Y = 28, 19, 30, 21 -- layout only
local GRID_W, GRID_H = 6 * PITCH_X + CELL_W, 5 * PITCH_Y + CELL_H
local DAYS, DAY_MIN, LINE, GAP, COL_GAP = 42, 1440, 14, 4, 16
local PAGE_W, BUTTON_H, QUICK_W, DD_W, STEP_W, VALUE_W = 76, 22, 58, 72, 22, 24
local TIME_W = 2 * DD_W + 8
local SLOT = 14 -- the height kept for one problem line (PageCreate.lua's SLOT)
local GOLD = { 1, 0.82, 0 }
local GREEN = { 0.2, 0.8, 0.2, 1 }
local WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
  "November", "December" }
local EARLIER, LATER = "\226\128\185 Earlier", "Later \226\128\186"
local RAIDS_LINE = "Raids start at about 20:00." -- the guild's rule (RULES.md), not a code value

local states = setmetatable({}, { __mode = "k" }) -- parent frame -> state

local function dayMin(ct)
  return Rules.Minutes({ year = ct.year, month = ct.month, monthDay = ct.monthDay, hour = 0, minute = 0 })
end

local function place(f, parent, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
end

local function button(parent, label, w, onClick)
  local b = ns.Look.Button(parent, label, onClick)
  b:SetSize(w, BUTTON_H)
  return b
end

local function texture(cell, layer, col, a)
  local t = cell:CreateTexture(nil, layer)
  t:SetColorTexture(col[1], col[2], col[3], a or col[4] or 1)
  t:Hide()
  return t
end

-- A day cell: the day number, today's underline, the chosen day's fill and 1 px frame, the event dot.
local function cell(st, parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(CELL_W, CELL_H)
  b.num = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.num:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.fill = texture(b, "BACKGROUND", GOLD, 0.25)
  b.fill:SetAllPoints(b)
  b.edges = {}
  for i, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" },
    { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local e = texture(b, "BORDER", GOLD, 1)
    e:SetPoint(side[1], b, side[1], 0, 0)
    e:SetPoint(side[2], b, side[2], 0, 0)
    if i <= 2 then e:SetHeight(1) else e:SetWidth(1) end
    b.edges[i] = e
  end
  b.underline = texture(b, "ARTWORK", GOLD, 1)
  b.underline:SetSize(CELL_W - 10, 1)
  b.underline:SetPoint("BOTTOM", b, "BOTTOM", 0, 2)
  b.dot = texture(b, "OVERLAY", GREEN)
  b.dot:SetSize(3, 3)
  b.dot:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -2)
  b:SetScript("OnClick", function(self)
    local d = Rules.FromMinutes(self.day)
    st.pick.date = { year = d.year, month = d.month, monthDay = d.monthDay }
    st.onChange()
  end)
  return b
end

-- Look.Dropdown (d699); nil keeps the steppers. The text follows the pick through GenerateMenu (f4901).
local function dropdown(st, parent, field, values)
  return ns.Look.Dropdown(parent, DD_W, function(_, root)
    root:SetScrollMode(10 * 20)
    for _, v in ipairs(values) do
      root:CreateRadio(string.format("%02d", v), function(d) return st.pick[field] == d end, function(d)
        ns.M.Safe(function()
          st.pick[field] = d
          st.onChange()
        end)
      end, v)
    end
  end)
end

-- Today's - / + steppers (PageCreate.lua's pattern) with a readout, for a client without the dropdown template.
local function stepper(st, parent, field, step, modulo)
  local function by(d)
    st.pick[field] = ((st.pick[field] or 0) + d * step) % modulo
    st.onChange()
  end
  local s = {
    less = button(parent, "-", STEP_W, function() by(-1) end),
    value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight"),
    more = button(parent, "+", STEP_W, function() by(1) end),
  }
  s.value:SetWidth(VALUE_W)
  s.value:SetJustifyH("CENTER")
  return s
end

function PageWhen.Build(parent, pick, onChange)
  local st = { pick = pick, onChange = onChange, page = 0, cells = {}, weekdays = {}, quick = {} }
  states[parent] = st
  st.header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  st.header:SetWidth(GRID_W)
  st.header:SetJustifyH("LEFT")
  for i, name in ipairs(WEEKDAYS) do
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetWidth(CELL_W)
    fs:SetJustifyH("CENTER")
    fs:SetText(name)
    st.weekdays[i] = fs
  end
  for i = 1, DAYS do st.cells[i] = cell(st, parent) end
  local function turn(d)
    st.page = st.page + d
    if st.last then PageWhen.Draw(parent, unpack(st.last, 1, 6)) end
  end
  st.earlier = button(parent, EARLIER, PAGE_W, function() turn(-1) end)
  st.later = button(parent, LATER, PAGE_W, function() turn(1) end)

  local hours, minutes = {}, {}
  for h = 0, 23 do hours[#hours + 1] = h end
  for m = 0, 59, C.MINUTE_STEP do minutes[#minutes + 1] = m end
  st.hourDD = dropdown(st, parent, "hour", hours)
  st.minuteDD = st.hourDD and dropdown(st, parent, "minute", minutes)
  if not st.minuteDD then
    if st.hourDD then st.hourDD:Hide() end
    st.hourDD = nil
    st.hourStep = stepper(st, parent, "hour", 1, 24)
    st.minuteStep = stepper(st, parent, "minute", C.MINUTE_STEP, 60)
  end
  for i, q in ipairs(C.QUICK_TIMES or {}) do
    local h, m = q[1], q[2]
    st.quick[i] = button(parent, string.format("%d:%02d", h, m), QUICK_W, function()
      pick.hour, pick.minute = h, m
      onChange()
    end)
  end
  st.raids = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  st.raids:SetJustifyH("LEFT")
  st.raids:SetWordWrap(true)
  st.raids:SetText(RAIDS_LINE)
end

-- "December 2026 · January · February 2027": the months of the days in view, each year after its last month.
local function header(first)
  local seen = {}
  for i = 0, DAYS - 1 do
    local d = Rules.FromMinutes(first + i * DAY_MIN)
    local last = seen[#seen]
    if not last or last.month ~= d.month or last.year ~= d.year then seen[#seen + 1] = d end
  end
  local parts = {}
  for i, d in ipairs(seen) do
    local nextOne = seen[i + 1]
    parts[i] = MONTHS[d.month] .. ((not nextOne or nextOne.year ~= d.year) and (" " .. d.year) or "")
  end
  return table.concat(parts, " \194\183 ")
end

local function stringHeight(fs)
  local h = fs:GetStringHeight()
  return math.max(LINE, type(h) == "number" and math.ceil(h) or 0)
end

-- Lays the time pieces from (tx, ty) in a column colW wide; returns the column's bottom.
local function drawTime(st, parent, tx, ty, colW)
  local pick = st.pick
  if st.hourDD then
    place(st.hourDD, parent, tx, ty)
    place(st.minuteDD, parent, tx + DD_W + 8, ty)
    st.hourDD:GenerateMenu()
    st.minuteDD:GenerateMenu()
  else
    local x = tx
    for _, s in ipairs({ { st.hourStep, pick.hour }, { st.minuteStep, pick.minute } }) do
      place(s[1].less, parent, x, ty)
      place(s[1].value, parent, x + STEP_W, ty + 4)
      s[1].value:SetText(string.format("%02d", s[2] or 0))
      place(s[1].more, parent, x + STEP_W + VALUE_W, ty)
      x = x + 2 * STEP_W + VALUE_W + 8
    end
  end
  local y = ty + math.max(BUTTON_H, st.hourDD and tonumber(st.hourDD:GetHeight()) or 0) + GAP + 2 -- kit: 25 tall
  local x = 0
  for _, b in ipairs(st.quick) do
    if x > 0 and x + QUICK_W > colW then x, y = 0, y + BUTTON_H + GAP end
    place(b, parent, tx + x, y)
    x = x + QUICK_W + GAP
  end
  if #st.quick > 0 then y = y + BUTTON_H + GAP end
  st.raids:SetWidth(colW)
  place(st.raids, parent, tx, y)
  return y + stringHeight(st.raids)
end

-- The height used keeps room for a problem line under the grid and under the time pick (two lines beside the grid,
-- where the columns are narrow); PageWhen.Lines says where those lines go.
function PageWhen.Draw(parent, x, y, width, today, maxDate, eventDays)
  local st = states[parent]
  if not st or not today or not maxDate then return 0 end
  st.last = { x, y, width, today, maxDate, eventDays }
  eventDays = eventDays or {}
  local t0, m0 = dayMin(today), dayMin(maxDate)
  local first0 = t0 - ((Rules.FromMinutes(t0).weekday + 5) % 7) * DAY_MIN
  local lastPage = math.max(0, math.floor((m0 - first0) / (DAYS * DAY_MIN)))
  st.page = math.max(0, math.min(st.page, lastPage))
  local first = first0 + st.page * DAYS * DAY_MIN
  local chosen = st.pick.date and dayMin(st.pick.date)

  st.header:SetText(header(first))
  place(st.header, parent, x, y)
  local wy = y + stringHeight(st.header) + GAP
  for i, fs in ipairs(st.weekdays) do place(fs, parent, x + (i - 1) * PITCH_X, wy) end
  local gy = wy + LINE + 2
  for i, b in ipairs(st.cells) do
    local m = first + (i - 1) * DAY_MIN
    local open = m >= t0 and m <= m0
    b.day = m
    b.num:SetText(tostring(Rules.FromMinutes(m).monthDay))
    b.num:SetFontObject(open and "GameFontHighlightSmall" or "GameFontDisableSmall")
    b:SetEnabled(open)
    b.underline:SetShown(m == t0)
    b.fill:SetShown(m == chosen)
    for _, e in ipairs(b.edges) do e:SetShown(m == chosen) end
    b.dot:SetShown(eventDays[m] == true)
    place(b, parent, x + ((i - 1) % 7) * PITCH_X, gy + math.floor((i - 1) / 7) * PITCH_Y)
  end
  local bottom = gy + GRID_H
  local paged = lastPage > 0
  st.earlier:SetShown(paged)
  st.later:SetShown(paged)
  if paged then
    st.earlier:SetEnabled(st.page > 0)
    st.later:SetEnabled(st.page < lastPage)
    place(st.earlier, parent, x, bottom + GAP)
    place(st.later, parent, x + GRID_W - PAGE_W, bottom + GAP)
    bottom = bottom + GAP + BUTTON_H
  end

  local beside = width >= GRID_W + COL_GAP + TIME_W
  local lineH = SLOT * (beside and 2 or 1)
  local where = { date = { x = x, y = bottom, w = beside and GRID_W or width } }
  local timeBottom
  if beside then
    local tx, tw = x + GRID_W + COL_GAP, width - GRID_W - COL_GAP
    timeBottom = drawTime(st, parent, tx, y, tw)
    where.time = { x = tx, y = timeBottom, w = tw }
  else
    timeBottom = drawTime(st, parent, x, bottom + lineH + 2 * GAP, width)
    where.time = { x = x, y = timeBottom, w = width }
  end
  st.where = where
  return math.max(bottom, timeBottom) + lineH - y
end

-- Where the date and time problem lines go after the last Draw: { date = { x, y, w }, time = { x, y, w } } | nil
function PageWhen.Lines(parent)
  local st = states[parent]
  return st and st.where
end
