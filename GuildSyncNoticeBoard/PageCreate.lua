-- GuildSyncNoticeBoard: the New event form in the detail panel (spec noticeboard/two-column.md AC6-AC10, AC13-AC15,
-- AC16). PageCreate.Build(panel) makes every frame once; PageCreate.Refresh(panel, w, h, compact) lays them out from
-- the size it is given (the rows wrap by width, so compact changes nothing; a call without a size keeps the last one)
-- and re-reads ns.Create (types, textures, the date range) every time. Fields scroll in their own ScrollFrame; Create
-- and Cancel sit fixed on the panel. Rows top to bottom: the realm-time line, type tiles, which dungeon, banner strip,
-- title, description, the day and time (PageWhen), each with a fixed slot for its Rules.CheckEvent line.
-- Every member gets the form; the server decides. The one write is ns.Create.Submit, called from Create's OnClick.
-- Refresh never writes an EditBox; the title is filled only inside a dungeon pick (a user action). The description's
-- hint is the board's own grey FontString: SetDefaultText is never called, so GetText() is the only read and the hint
-- can never reach Rules.CheckEvent, the counter or EventSetDescription. Change handlers are hooked (HookScript), never
-- set, so the templates' own OnTextChanged keeps running.

local _, ns = ...
if not ns.M then return end

local C, Rules, Banners = ns.C, ns.Rules, ns.Banners
local PageCreate = {}
ns.PageCreate = PageCreate

-- layout only
local PAD, LINE, SLOT, BUTTON_H = 12, 16, 14, 22
local TILE_W, TILE_H, TILE_GAP, TILE_ROW = 76, 32, 8, 56
local STRIP_W, STRIP_H, STRIP_GAP, STRIP_MAX = 48, 24, 4, 8
local DD_X, DD_W, TEX_W = 152, 180, 140
local DESC_H, COUNT_W, BAR = 34, 70, 36
local CREATE_W, CANCEL_W, BAR_GAP = 100, 80, 6
local BAR_ROOM = 14 -- f4931: Forever's ScrollFrameTemplate draws its bar from the frame's right + 6 to right + 14
local DEFAULT_W, DEFAULT_H = 436, 448
local GOLD = { 1, 0.82, 0, 1 }          -- #ffd100, the chosen tile's frame
local GREY = { 0.227, 0.227, 0.227, 1 } -- #3a3a3a, the other tiles' frame
local RED = { 1, 0.125, 0.125 }         -- RED_FONT_COLOR, the problem lines
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local CREATED_LINE = "Event created."
local DESC_HINT = "What, where, what to bring (optional)"
local STRIP_TAIL = " \194\183 saved as a short tag in the description"
local HINTS = { dungeon = "e.g. Deadmines run", pvp = "e.g. Warsong premade", social = "e.g. Fishing contest",
  rp = "e.g. Tavern night", other = "e.g. Guild meeting" }

local states = setmetatable({}, { __mode = "k" }) -- panel frame -> the form's state

local function esc(s) return GuildSync.Escape(tostring(s or "")) end

-- The game answers "" for an empty EditBox; anything else not a string reads as "".
local function value(e)
  local v = e:GetText()
  return type(v) == "string" and v or ""
end

local function dateText(ct) return ct.monthDay .. " " .. MONTHS[ct.month] .. " " .. ct.year end

local function dayMin(ct)
  return Rules.Minutes({ year = ct.year, month = ct.month, monthDay = ct.monthDay, hour = 0, minute = 0 })
end

local function place(f, parent, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
end

-- f4932, f4933: a wrapped line's real height, at least one LINE
local function lineH(fs)
  local fh = fs:GetStringHeight()
  return math.max(LINE, type(fh) == "number" and math.ceil(fh) or 0)
end

local function text(parent, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  return fs
end

local function problemSlot(parent)
  local fs = text(parent, "GameFontHighlightSmall")
  fs:SetTextColor(RED[1], RED[2], RED[3])
  fs:Hide()
  return fs
end

local function button(parent, label, width, onClick)
  local b = ns.Look.Button(parent, label, onClick)
  b:SetSize(width, BUTTON_H)
  return b
end

local function listed(kind)
  for _, t in ipairs(Rules.BOARD_TYPES) do if t == kind then return true end end
  return false
end

-- ---------- the checks (read only; nothing new is checked) ----------

local function fieldOf(line)
  if line:find("^Pick a type") then return "type" end
  if line:find("^An event needs a title") or line:find("^A title is") then return "title" end
  if line:find("^A description") then return "desc" end
  if line:find("^Pick a date") then return "date" end
  return "time"
end

-- The form as Submit would send it to Rules.CheckEvent (the description carries the banner tag, as Create.lua:109).
local function formOf(st)
  return { type = st.type, title = value(st.title),
    description = Banners.WithTag(value(st.desc), st.banner or Banners.Default(st.type)),
    date = st.pick.date, hour = st.pick.hour, minute = st.pick.minute }
end

-- -> { [field] = line }, valid. CheckEvent stops at its first refusal, so each failing field is re-checked once with a
-- fixed substitute (type: the current one if a board type, else "other"; title "x"; description ""; date maxDate;
-- hour and minute 0/0). The time-after-now line shows only when the real date is set and in range.
local function problems(st)
  local out = {}
  local today, maxDate = ns.Create.Range()
  if not today then return out, false end
  local g = formOf(st)
  local realDate = false
  if st.pick.date then
    local d = dayMin(st.pick.date)
    realDate = d >= dayMin(today) and d <= dayMin(maxDate)
  end
  local done, first, valid = {}, true, false
  for _ = 1, 8 do
    local good, why = Rules.CheckEvent(g, today, maxDate)
    if good then valid = first break end
    first = false
    local field = fieldOf(why)
    if done[field] then break end
    done[field] = true
    if not (why:find("^Pick a time after now") and not realDate) then out[field] = why end
    if field == "type" then g.type = listed(st.type) and st.type or "other"
    elseif field == "title" then g.title = "x"
    elseif field == "desc" then g.description = ""
    elseif field == "date" then g.date = { year = maxDate.year, month = maxDate.month, monthDay = maxDate.monthDay }
    else g.hour, g.minute = 0, 0 end
  end
  return out, valid
end

-- Counters, hints, problem lines and Create's state; no EditBox write, so safe from a text hook and from Refresh.
local function update(st)
  if not st.create then return end -- a text change while Build is still running
  local _, prefix = Rules.TypeToGame(st.type or "other")
  local title, desc = value(st.title), value(st.desc)
  st.titleCount:SetText(Rules.Chars(title) .. " / " .. (C.EVENT_TITLE - Rules.Chars(prefix or "")))
  st.descCount:SetText(Rules.Chars(desc) .. " / " .. Banners.DESC_LETTERS)
  st.descHint:SetShown(desc == "")
  if st.titleHint then st.titleHint:SetShown(title == "") end
  local lines, valid = problems(st)
  for field, fs in pairs(st.prob) do
    -- R-f3, f10: no line on a fresh, untouched form; once any field was edited (or Create clicked), every current
    -- line, so a start time the clock passed is explained too
    local line = (st.tried or st.edited) and lines[field] or nil
    fs:SetText(line and esc(line) or "")
    fs:SetShown(line ~= nil)
  end
  st.create:SetEnabled(valid and not ns.Create.Pending())
end

-- ---------- clicks ----------

-- After a click: the form, then the page (the list's preview row follows). Refresh itself never calls RefreshPage,
-- so this cannot loop.
local function redraw(st)
  PageCreate.Refresh(st.root)
  ns.M.RefreshPage()
end

local function say(st, line)
  st.note:SetText(line and esc(line) or "")
  st.note:SetShown(line ~= nil)
end

local function submit(st)
  st.tried = true
  local ok, why = ns.Create.Submit({ title = value(st.title), description = value(st.desc), type = st.type,
    date = st.pick.date, hour = st.pick.hour, minute = st.pick.minute,
    texture = st.type == "dungeon" and st.texture or nil, banner = st.banner })
  say(st, ok and CREATED_LINE or why)
  if ok then st.banner = Banners.Default(st.type) end -- B5: the next event starts on the default
  redraw(st)
end

local function pickType(st, kind)
  st.edited = true
  if kind == st.type then return redraw(st) end -- the chosen tile again: nothing changes
  st.type, st.texture, st.banner = kind, nil, Banners.Default(kind)
  if st.titleAuto then
    st.titleAuto = false
    st.title:SetText("")
  end
  redraw(st)
end

-- A dungeon pick (index nil = None): the texture, the banner of that name (else the type's default) and, while the
-- title is empty or was filled by an earlier pick, the title.
local function pickTexture(st, index, title)
  st.edited = true
  st.texture = index
  if index then
    st.banner = Banners.FromTextureTitle(title) or Banners.Default(st.type)
    if title and (value(st.title) == "" or st.titleAuto) then
      st.titleAuto = true
      st.title:SetText(title)
    end
  end
  redraw(st)
end

-- ---------- widgets ----------

-- A colour texture behind a tile's picture, centred on the tile: its size sets the frame's thickness.
local function backing(b)
  local t = b:CreateTexture(nil, "BACKGROUND")
  t:SetPoint("CENTER", b, "CENTER", 0, 0)
  return t
end

local function typeTile(st, ch, kind)
  local b = CreateFrame("Button", nil, ch)
  b:SetSize(TILE_W + 4, TILE_H + 4)
  b.frame = backing(b)
  b.pic = b:CreateTexture(nil, "ARTWORK")
  b.pic:SetSize(TILE_W, TILE_H)
  b.pic:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.label = text(b)
  b.label:SetText(Rules.TypeLabel(kind))
  b.label:SetPoint("TOP", b, "BOTTOM", 0, -2)
  b:SetScript("OnClick", function() pickType(st, kind) end)
  return b
end

local function stripTile(st, ch)
  local b = CreateFrame("Button", nil, ch)
  b:SetSize(STRIP_W, STRIP_H)
  b.frame = backing(b)
  b.frame:SetSize(STRIP_W + 4, STRIP_H + 4)
  b.frame:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], GOLD[4])
  b.pic = b:CreateTexture(nil, "ARTWORK")
  b.pic:SetSize(STRIP_W, STRIP_H)
  b.pic:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.emblem = b:CreateTexture(nil, "OVERLAY")
  b:SetScript("OnClick", function(self)
    st.banner, st.edited = self.id, true
    redraw(st)
  end)
  return b
end

-- Look.Dropdown (d699); nil keeps today's buttons. The text follows the pick through GenerateMenu (f4901).
local function dungeonDropdown(st, ch)
  return ns.Look.Dropdown(ch, DD_W, function(_, menu)
    menu:SetScrollMode(15 * 20)
    menu:CreateRadio("None", function() return st.texture == nil end,
      function() ns.M.Safe(pickTexture, st, nil) end, 0)
    for _, e in ipairs(st.textures or {}) do
      menu:CreateRadio(e.title or ("#" .. e.index), function(i) return st.texture == i end,
        function(i) ns.M.Safe(pickTexture, st, i, e.title) end, e.index)
    end
  end)
end

-- The changes every text hook makes: counters, hints, problems, Create; then the page (the preview row) redraws.
local function onText(st)
  update(st)
  ns.M.RefreshPage()
end

function PageCreate.Build(root)
  local st = { root = root, pick = {}, tiles = {}, strip = {}, texButtons = {}, prob = {}, edited = false, w = DEFAULT_W,
    h = DEFAULT_H }
  states[root] = st
  -- f3: start at the next MINUTE_STEP after the realm calendar's now (past midnight: 00:00 tomorrow); with no
  -- calendar time yet the day stays unset (Refresh never fills it)
  st.pick.hour, st.pick.minute = 20, 0
  local today = ns.Create.Range()
  if today then
    local start = (math.floor((today.hour * 60 + today.minute) / C.MINUTE_STEP) + 1) * C.MINUTE_STEP
    local day = dayMin(today)
    if start >= 1440 then start, day = start - 1440, day + 1440 end
    st.pick.hour, st.pick.minute = math.floor(start / 60), start % 60
    local d = Rules.FromMinutes(day)
    st.pick.date = { year = d.year, month = d.month, monthDay = d.monthDay }
  end

  st.scroll = ns.Look.Frame("ScrollFrame", root, "ScrollFrameTemplate", "UIPanelScrollFrameTemplate")
  st.child = CreateFrame("Frame", nil, st.scroll)
  st.scroll:SetScrollChild(st.child)
  local ch = st.child

  st.range = text(ch, "GameFontNormal")
  for _, kind in ipairs(Rules.BOARD_TYPES) do st.tiles[kind] = typeTile(st, ch, kind) end
  st.prob.type = problemSlot(ch)

  st.ddLabel = text(ch)
  st.ddLabel:SetText("Which dungeon (optional)")
  st.dd = dungeonDropdown(st, ch)

  st.stripLabel = text(ch)
  for i = 1, STRIP_MAX do st.strip[i] = stripTile(st, ch) end

  st.titleLabel = text(ch, "GameFontNormal")
  st.titleLabel:SetText("Title")
  st.titleCount = text(ch, "GameFontDisableSmall")
  st.title = ns.Look.Input(ch, DEFAULT_W - 29, C.EVENT_TITLE * 4) -- Refresh sizes it to the form's width
  if type(st.title.Instructions) ~= "table" then -- the fallback box has no hint of its own
    st.titleHint = text(st.title, "GameFontDisableSmall")
    st.titleHint:SetPoint("LEFT", st.title, "LEFT", 6, 0)
  end
  st.title:HookScript("OnTextChanged", function(_, userInput)
    if userInput then st.titleAuto, st.edited = false, true end -- only typing makes the title the member's own
    onText(st)
  end)
  st.prob.title = problemSlot(ch)

  st.descLabel = text(ch, "GameFontNormal")
  st.descLabel:SetText("Description")
  st.descCount = text(ch, "GameFontDisableSmall")
  local holder, used = ns.Look.Frame("Frame", ch, "ScrollingEditBoxTemplate")
  if used == "ScrollingEditBoxTemplate" then
    st.descHolder, st.desc = holder, holder:GetEditBox()
  else
    holder:Hide()
    st.desc = CreateFrame("EditBox", nil, ch)
    st.desc:SetMultiLine(true)
    st.desc:SetAutoFocus(false)
    st.desc:SetFontObject("ChatFontNormal")
    st.descHolder = st.desc
  end
  st.desc:SetMaxLetters(Banners.DESC_LETTERS)
  st.desc:HookScript("OnTextChanged", function(_, userInput)
    if userInput then st.edited = true end
    onText(st)
  end)
  st.descHint = text(st.descHolder, "GameFontDisableSmall")
  st.descHint:SetText(DESC_HINT)
  st.descHint:SetPoint("TOPLEFT", st.descHolder, "TOPLEFT", 4, -4)
  st.prob.desc = problemSlot(ch)

  ns.PageWhen.Build(ch, st.pick, function()
    st.edited = true
    redraw(st)
  end)
  st.prob.date = problemSlot(ch)
  st.prob.time = problemSlot(ch)
  st.note = text(ch)
  st.note:Hide()
  -- R-f1: the slot-held line and the server's refusal, on the panel above Create and Cancel
  st.slot = text(root)
  st.slot:SetWordWrap(true)
  st.error = text(root, "GameFontRedSmall")
  st.error:SetWordWrap(true)

  st.create = button(root, "Create", CREATE_W, function() submit(st) end)
  st.cancel = button(root, "Cancel", CANCEL_W, function()
    root:Hide()
    ns.M.RefreshPage() -- the preview row goes with the form
  end)
  -- B5: the default banner whenever the form opens; the fields themselves are kept
  root:HookScript("OnShow", function() st.banner = Banners.Default(st.type) end)
end

-- Days with a readable guild row in the list (the 14-day window), for the day grid's dots. Read only.
local function eventDays()
  local days = {}
  local rows = ns.Cal and ns.Cal.Rows()
  for _, r in ipairs(type(rows) == "table" and rows or {}) do
    if type(r) == "table" and type(r.minutes) == "number" and r.readable ~= false then
      days[r.minutes - r.minutes % 1440] = true
    end
  end
  return days
end

function PageCreate.Refresh(root, w, h, compact)
  local st = states[root]
  if not st then return end
  if type(w) == "number" and w > 0 then st.w = w end
  if type(h) == "number" and h > 0 then st.h = h end
  w, h = st.w, st.h
  local right = w - PAD
  local today, maxDate = ns.Create.Range()
  local ch = st.child

  -- R-f1: the slot line (unless the note already says it) and Cal.ErrorLine() (escaped there) stay in view with the
  -- form, stacked up from the bar; the fields' scroll ends above them
  local free, slotLine = true, nil
  if ns.Cal then free, slotLine = ns.Cal.SlotFree() end
  local slot = not free and slotLine or nil
  if slot and st.note:IsShown() and st.note:GetText() == esc(slot) then slot = nil end
  st.slot:SetText(slot or "")
  st.slot:SetShown(slot ~= nil)
  local err = ns.Cal and ns.Cal.ErrorLine() or nil
  st.error:SetText(err or "")
  st.error:SetShown(err ~= nil and err ~= "")
  local barTop = h - BAR - 4
  for _, fs in ipairs({ st.error, st.slot }) do
    if fs:IsShown() then
      fs:SetWidth(w - 2 * PAD)
      local fh = fs:GetStringHeight()
      barTop = barTop - math.max(LINE, type(fh) == "number" and math.ceil(fh) or 0)
      place(fs, root, PAD, barTop)
    end
  end

  st.scroll:ClearAllPoints()
  st.scroll:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
  st.scroll:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -BAR_ROOM, h - barTop)
  -- the fields lay out in the scroll's width (cw), from PAD to its right edge: the bar's own 6-px gap is their right
  -- margin, so the widths the panel had (eight strip tiles in one row at 436) still fit; Create and Cancel stay on
  -- the panel's right
  local cw = w - BAR_ROOM
  local cright = cw
  ch:SetWidth(cw)

  local y = 8
  if today and maxDate then
    st.range:SetText("Times are realm time. Dates from " .. dateText(today) .. " to " .. dateText(maxDate) .. ".")
  else
    st.range:SetText("Times are realm time. The calendar has no date yet.")
  end
  st.range:SetWidth(cright - PAD)
  place(st.range, ch, PAD, y)
  y = y + lineH(st.range) + 4

  -- type tiles: the board types the client lists now, in its order, wrapped inside w - 24
  local shown = {}
  for _, t in ipairs(ns.Create.Types()) do shown[t] = true end
  if st.type and not shown[st.type] then st.type, st.texture = nil, nil end
  local x = PAD
  for _, kind in ipairs(Rules.BOARD_TYPES) do
    local b = st.tiles[kind]
    b:SetShown(shown[kind] or false)
    if shown[kind] then
      if x > PAD and x + TILE_W > cright then x, y = PAD, y + TILE_ROW end
      place(b, ch, x - 2, y)
      Banners.Draw(b.pic, Banners.Default(kind), TILE_W, TILE_H)
      local chosen = st.type == kind
      local c = chosen and GOLD or GREY
      local edge = chosen and 2 or 1
      b.frame:SetSize(TILE_W + 2 * edge, TILE_H + 2 * edge)
      b.frame:SetColorTexture(c[1], c[2], c[3], c[4])
      b.label:SetFontObject(chosen and "GameFontHighlight" or "GameFontHighlightSmall")
      x = x + TILE_W + TILE_GAP
    end
  end
  y = y + TILE_ROW
  place(st.prob.type, ch, PAD, y)
  y = y + SLOT

  -- which dungeon: Dungeon only; the dropdown, else today's buttons
  st.textures = st.type == "dungeon" and ns.Create.Textures() or nil
  local tex = st.textures
  local known = false
  for _, e in ipairs(tex or {}) do if e.index == st.texture then known = true end end
  if not known then st.texture = nil end
  st.ddLabel:SetShown(tex ~= nil)
  if st.dd then
    st.dd:SetShown(tex ~= nil)
    if tex then
      place(st.ddLabel, ch, PAD, y + 4)
      place(st.dd, ch, DD_X, y)
      st.dd:GenerateMenu()
      y = y + math.max(BUTTON_H, tonumber(st.dd:GetHeight()) or 0) + 6 -- the kit's button is 25 tall
    end
  else
    if tex then
      place(st.ddLabel, ch, PAD, y)
      y = y + LINE
    end
    local bx = PAD
    for i, e in ipairs(tex or {}) do
      local b = st.texButtons[i]
      if not b then
        b = button(ch, "", TEX_W, function(self) pickTexture(st, self.index, self.title) end)
        st.texButtons[i] = b
      end
      b.index, b.title = e.index, e.title
      b:SetText(e.title or ("#" .. e.index))
      b:Show()
      if bx > PAD and bx + TEX_W > cright then bx, y = PAD, y + BUTTON_H + 4 end
      place(b, ch, bx, y)
      bx = bx + TEX_W + 4
    end
    for i = #(tex or {}) + 1, #st.texButtons do st.texButtons[i]:Hide() end
    if tex then y = y + BUTTON_H + 4 end
  end

  -- banner strip: the type's set, one row where it fits, else wrapped; hidden with no type
  local set = st.type and Banners.Set(st.type) or {}
  local banner = st.banner or (st.type and Banners.Default(st.type))
  st.stripLabel:SetShown(#set > 0)
  if #set > 0 then
    st.stripLabel:SetText("Banner " .. esc(Banners.LIST[banner].label) .. STRIP_TAIL)
    st.stripLabel:SetWidth(cright - PAD)
    place(st.stripLabel, ch, PAD, y)
    y = y + lineH(st.stripLabel)
  end
  -- f4931: the row starts 4 left of PAD so eight tiles and the chosen frame (2 past each side) fit in one row beside
  -- the bar at 436 (8 + 8 x 48 + 7 x 4 = 420, + 2 of frame = 422, the scroll's right edge)
  local sx0 = PAD - 4
  local sx = sx0
  for i, b in ipairs(st.strip) do
    local id = set[i]
    b:SetShown(id ~= nil)
    if id then
      b.id = id
      if sx > sx0 and sx + STRIP_W + 2 > cright then sx, y = sx0, y + STRIP_H + 4 end
      place(b, ch, sx, y)
      Banners.Draw(b.pic, id, STRIP_W, STRIP_H, b.emblem)
      b.frame:SetShown(id == banner)
      sx = sx + STRIP_W + STRIP_GAP
    end
  end
  if #set > 0 then y = y + STRIP_H + 6 end

  -- title
  place(st.titleLabel, ch, PAD, y)
  place(st.titleCount, ch, cright - COUNT_W, y)
  y = y + LINE
  st.title:SetSize(cright - PAD - 5, 20)
  place(st.title, ch, PAD + 5, y) -- the input box's border draws 5 to the left of its text
  local hint = HINTS[st.type or "other"]
  if type(st.title.Instructions) == "table" then st.title.Instructions:SetText(hint) end
  if st.titleHint then st.titleHint:SetText(hint) end
  y = y + 22
  place(st.prob.title, ch, PAD, y)
  y = y + SLOT

  -- description
  place(st.descLabel, ch, PAD, y)
  place(st.descCount, ch, cright - COUNT_W, y)
  y = y + LINE
  st.descHolder:SetSize(cright - PAD, DESC_H)
  place(st.descHolder, ch, PAD, y)
  y = y + DESC_H + 2
  place(st.prob.desc, ch, PAD, y)
  y = y + SLOT

  -- day and time (PageWhen); R-f8: the date line under the grid, the time line under the time pick
  local where
  if today and maxDate then
    y = y + ns.PageWhen.Draw(ch, PAD, y, cright - PAD, today, maxDate, eventDays()) + 4
    where = ns.PageWhen.Lines(ch)
  end
  if where then
    for _, f in ipairs({ "date", "time" }) do
      st.prob[f]:SetWidth(where[f].w)
      place(st.prob[f], ch, where[f].x, where[f].y)
    end
  else
    place(st.prob.date, ch, PAD, y)
    y = y + SLOT
    place(st.prob.time, ch, PAD, y)
    y = y + SLOT
  end
  st.note:SetWidth(cright - PAD)
  place(st.note, ch, PAD, y)
  y = y + LINE
  ch:SetHeight(y + 8)

  -- Create and Cancel fixed on the panel, right-aligned at y = h - 36
  place(st.cancel, root, right - CANCEL_W, h - BAR)
  place(st.create, root, right - CANCEL_W - BAR_GAP - CREATE_W, h - BAR)
  update(st)
end

-- The live preview's data for the list (Page.lua draws it): nil until a type, a title and a day are set, and while the
-- form is hidden. Read only.
function PageCreate.Preview(root)
  local st = states[root]
  if not st or not root:IsShown() or not st.type or not st.pick.date then return nil end
  local title = value(st.title)
  if title == "" then return nil end
  local d = st.pick.date
  return { kind = st.type, title = title, banner = st.banner or Banners.Default(st.type),
    time = Rules.FromMinutes(Rules.Minutes({ year = d.year, month = d.month, monthDay = d.monthDay,
      hour = st.pick.hour or 0, minute = st.pick.minute or 0 })) }
end

-- f2: redraw every built form when the game's calendar starts or ends an action, so the Create button follows it.
ns.Listen("CALENDAR_ACTION_PENDING", function()
  for root in pairs(states) do PageCreate.Refresh(root) end
end)
