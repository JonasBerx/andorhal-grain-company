-- GuildSyncGames WoWdle.lua: the WoWdle tab body (plan Task 7; mock wd-1 to wd-4). Left: the title, the sub line, six
-- rows of tiles, the message line and the on-screen keys. Right: the stats card, Today in the guild (M.Kit.List, a
-- tooltip per row) with Share and Practice, or the practice card. All UI state lives in ns.U (f7080).
-- The typing box is a bare EditBox over the tile rows only, its text hidden; its text is the only owner of the guess
-- (f7072): the on-screen keys set it, OnTextChanged filters it to A-Z, cuts it at the word's length and mirrors it into
-- the open row. It never takes focus by itself (f7073); a click on the rows gives it focus.
-- ns.GuildToday and ns.OpenChat are looked up at call time (Sync.lua and Page.lua own them; tests replace them).

local _, ns = ...

if not ns.M then return end
local M, Core = ns.M, ns.Core

local TRIES = 6
local LEFT, COL_W, BOARD_Y, RX = 8, 330, 46, 352
local BIG = { s = 40, gap = 5, kw = 26, kh = 32, kgap = 4 }
local SMALL = { s = 28, gap = 4, kw = 22, kh = 24, kgap = 3 } -- below 420 tall (the 760x480 window, wd-4)
local SMALL_BELOW = 420
local KEY_ROWS = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
-- The score colours: correct, present, absent; an empty tile, and a typed tile or an unknown key.
local COL = { g = { 0.275, 0.549, 0.204, 1 }, y = { 0.729, 0.588, 0.157, 1 }, x = { 0.243, 0.243, 0.259, 1 },
  e = { 0, 0, 0, 0.42 }, t = { 0, 0, 0, 0.6 } }
local TIP = { g = "70:140:52", y = "186:150:40", x = "62:62:66" } -- the tooltip's squares, as vertex colours
local GREY = 0.6
local BAR_STEP, BAR_MAX = 12, 200

local U = { tiles = {}, keys = {}, len = 6 }
ns.U = U

local function grey(fs) fs:SetTextColor(GREY, GREY, GREY) end

-- The box's text; "" before it ever held one.
local function typed(box)
  local t = box:GetText()
  return type(t) == "string" and t or ""
end

local function label(parent, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  return fs
end

local function button(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

-- A tile or a key: the kit's inset (the mock's UI-Frame-Inner edges) one frame level below the cell, so its rim shows
-- around the fill; the fill and the centred letter stay on the cell (a frame draws over its children below it).
local function cell(kind, parent, font)
  local f = CreateFrame(kind, nil, parent)
  local inset = M.Kit.Inset(f)
  if inset then
    inset:SetAllPoints(f)
    inset:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
  end
  f.fill = f:CreateTexture(nil, "BACKGROUND")
  f.fill:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
  f.fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
  f.fs = f:CreateFontString(nil, "OVERLAY", font)
  f.fs:SetPoint("CENTER")
  return f
end

local function paint(f, state) f.fill:SetColorTexture(unpack(COL[state] or COL.e)) end -- "" past a 5-letter row

-- The game on show: today's, or the practice word. Rows are { word, codes } in both.
local function game()
  if ns.Mode() == "practice" and ns.Practice() then return ns.Practice(), true end
  return ns.Today(), false
end

-- ---------- layout (the tile and key sizes follow the body's height; the board is centred for n letters) ----------

function U.Layout()
  local h, w = U.body:GetHeight(), U.body:GetWidth()
  local small = type(h) == "number" and h > 0 and h < SMALL_BELOW
  local width = (type(w) == "number" and w > 0) and w or 726
  local B, n = small and SMALL or BIG, U.len
  local sig = tostring(small) .. n .. ":" .. width
  if U.laid == sig then return end
  U.laid = sig
  local bw = n * B.s + (n - 1) * B.gap
  U.board:ClearAllPoints()
  U.board:SetPoint("TOPLEFT", U.body, "TOPLEFT", LEFT + math.floor((COL_W - bw) * 0.5), -BOARD_Y)
  U.board:SetSize(bw, TRIES * B.s + (TRIES - 1) * B.gap)
  for r = 1, TRIES do
    for i = 1, 6 do
      local t = U.tiles[r][i]
      t:SetSize(B.s, B.s)
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", U.board, "TOPLEFT", (i - 1) * (B.s + B.gap), -(r - 1) * (B.s + B.gap))
      t:SetShown(i <= n)
    end
  end
  local msgY = BOARD_Y + TRIES * (B.s + B.gap) + 2
  U.msg:ClearAllPoints()
  U.msg:SetPoint("TOPLEFT", U.body, "TOPLEFT", LEFT, -msgY)
  local kbW = 10 * B.kw + 9 * B.kgap
  U.keyFrame:ClearAllPoints()
  U.keyFrame:SetPoint("TOPLEFT", U.body, "TOPLEFT", LEFT + math.floor((COL_W - kbW) * 0.5), -(msgY + 22))
  U.keyFrame:SetSize(kbW, 3 * B.kh + 2 * B.kgap)
  local wide = math.floor(B.kw * 1.6 + 0.5)
  for row, letters in ipairs(KEY_ROWS) do
    local x, y = 0, -(row - 1) * (B.kh + B.kgap)
    if row == 2 then x = math.floor((B.kw + B.kgap) * 0.5) end
    local function place(k, kw)
      k:SetSize(kw, B.kh)
      k:ClearAllPoints()
      k:SetPoint("TOPLEFT", U.keyFrame, "TOPLEFT", x, y)
      x = x + kw + B.kgap
    end
    if row == 3 then place(U.keys.Enter, wide) end
    for ch in letters:gmatch("%u") do place(U.keys[ch], B.kw) end
    if row == 3 then place(U.keys.Back, wide) end
  end
  local step = math.floor((width - RX - 14 - 16) * 0.25)
  for i, v in ipairs(U.statValues) do
    v:ClearAllPoints()
    v:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 8 + (i - 1) * step, -32)
    U.statLabels[i]:ClearAllPoints()
    U.statLabels[i]:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 8 + (i - 1) * step, -52)
  end
end

-- ---------- drawing ----------

-- The open row shows the box's text (typed letters on the typed fill).
function U.Mirror()
  local r = #U.rows + 1
  if U.done or r > TRIES then return end
  local text = typed(U.box)
  for i = 1, 6 do
    local ch = text:sub(i, i)
    U.tiles[r][i].fs:SetText(ch)
    paint(U.tiles[r][i], ch ~= "" and "t" or "e")
  end
end

local function wonPercent(s)
  if s.played == 0 then return "0%" end
  local pct = 0 -- the rounded share, found by counting up: the rule here is no division by a variable
  while pct < 100 and 2 * (pct + 1) * s.played <= 200 * s.won + s.played do pct = pct + 1 end
  return pct .. "%"
end

local function drawStats()
  local s = ns.Stats()
  local values = { tostring(s.played), wonPercent(s), tostring(s.cur), tostring(s.best) }
  for i, v in ipairs(U.statValues) do v:SetText(values[i]) end
  for i, bar in ipairs(U.bars) do
    local n = s.dist[i] or 0
    bar.fill:SetWidth(math.min(BAR_MAX, 14 + n * BAR_STEP))
    bar.count:SetText(tostring(n))
  end
end

function U.Draw()
  local g, practice = game()
  local today = g
  if practice then today = ns.Today() end
  U.label = today and today.label
  U.rows, U.done = g and g.rows or {}, g and g.done or false
  U.len = g and g.len or 6
  U.Layout()
  if g and not practice then
    if U.n and g.n ~= U.n then -- the day rolled while the page was open: the typed letters were for the old word
      U.box:SetText("")
      U.text, U.red = ns.ROLLED, false
    end
    U.n = g.n
  end
  local known = Core.Known(U.rows)
  for r = 1, TRIES do
    local row = U.rows[r]
    for i = 1, 6 do
      local t = U.tiles[r][i]
      t.fs:SetText(row and row.word:sub(i, i) or "")
      paint(t, row and row.codes:sub(i, i) or "e")
    end
  end
  U.Mirror()
  for ch in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch("%u") do paint(U.keys[ch], known[ch] or "t") end

  local tries, len = #U.rows, U.len .. " letters"
  local text, red = U.text, U.red
  if not g then
    U.title:SetText("WoWdle")
    U.sub:SetText("No word today.")
  elseif practice then
    U.title:SetText("WoWdle · Practice")
    U.sub:SetText(len .. (g.done and "" or (" · try " .. (tries + 1) .. " of " .. TRIES)))
  else
    U.title:SetText("WoWdle " .. g.label)
    local state = g.done and (g.won and ("solved in " .. tries) or "not solved") or ("try " .. (tries + 1) .. " of " .. TRIES)
    U.sub:SetText(len .. " · " .. state .. " · next word in " .. Core.Countdown(g.nextIn or g.secsLeft))
  end
  if g and g.done and not text then
    if g.won then
      text = g.word .. "! Solved in " .. tries .. "." .. (practice and "" or (" Streak " .. ns.Stats().cur .. "."))
    else
      text = "The word was " .. g.word .. "."
    end
  end
  U.msg:SetText(text or "")
  if red then U.msg:SetTextColor(1, 0.282, 0.282) else U.msg:SetTextColor(1, 1, 1) end

  U.daily:SetShown(not practice)
  U.prac:SetShown(practice)
  if practice then
    local wait = ""
    if today then
      wait = "Today's WoWdle " .. today.label .. (today.done and " is done." or (": try " .. (#today.rows + 1)
        .. " of " .. TRIES .. ", waiting for you."))
    end
    U.wait:SetText(wait)
    return
  end
  drawStats()
  U.share:SetShown(g and g.done or false)
  local list = ns.GuildToday and ns.GuildToday() or {}
  U.played:SetText(#list .. " played")
  if U.list then U.list:SetRows(list) end
end

-- ---------- typing ----------

local function submit()
  local text = typed(U.box)
  local ok, why, msg
  if ns.Mode() == "practice" then ok, why, msg = ns.PracticeGuess(text) else ok, why, msg = ns.Guess(text) end
  U.text, U.red = nil, false
  if ok or why == "rolled" then
    U.box:SetText("")
    U.text = msg
  elseif why == "word" then
    U.text, U.red = text .. " is not on the WoW word list.", true
  elseif why ~= "demo" then
    U.text, U.red = msg, msg ~= nil
  end
  U.Draw()
end

local function press(key)
  if key == "Enter" then return submit() end
  local text = typed(U.box)
  if key == "Back" then U.box:SetText(text:sub(1, -2))
  elseif #text < U.len then U.box:SetText(text .. key) end
end

-- daily or practice: focus dropped, the box and the message cleared (f7073)
local function switch(fn)
  U.box:ClearFocus()
  fn()
  U.text, U.red = nil, false
  U.box:SetText("")
  U.Draw()
end

local function share()
  if ns.Inert() then return end
  local t = ns.Today()
  if not (t and t.done) then return end
  local res = Core.Result(t.n, t.won, t.rows, ns.Stats().cur)
  if ns.OpenChat("/g " .. Core.ShareText(t.label, res, true, 3)) then
    U.text = "In the guild chat box: press Enter to send."
  else
    U.text = "Type this in guild chat: " .. Core.ShareText(t.label, res, false, 3)
  end
  U.red = false
  U.Draw()
end

-- ---------- the guild list's rows and tooltip ----------

local function buildRow(f)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(16, 16)
  f.icon:SetPoint("LEFT", f, "LEFT", 4, 0)
  f.name = label(f)
  f.name:SetPoint("LEFT", f, "LEFT", 26, 0)
  f.streak = label(f)
  grey(f.streak)
  f.streak:SetPoint("RIGHT", f, "RIGHT", -8, 0)
  f.streak:SetWidth(54)
  f.res = label(f, "GameFontHighlight")
  f.res:SetPoint("RIGHT", f.streak, "LEFT", -8, 0)
  M.Kit.ListHover(f)
  local function enter(self)
    local e, tip = self.entry, M.Compat.Tooltip()
    if not (e and tip) then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:SetText(ns.Escape(e.name))
    tip:AddLine("WoWdle " .. (U.label or "") .. " " .. Core.Tries(e.tries) .. "/6 · streak " .. e.streak,
      1, 1, 1)
    for _, codes in ipairs(e.rows or {}) do
      local line = ""
      for code in codes:gmatch(".") do
        line = line .. "|TInterface\\Buttons\\WHITE8X8:10:10:0:0:8:8:0:8:0:8:" .. (TIP[code] or TIP.x) .. "|t "
      end
      tip:AddLine(line)
    end
    tip:Show()
  end
  local function leave()
    local tip = M.Compat.Tooltip()
    if tip then tip:Hide() end
  end
  f:SetScript("OnEnter", function(self) M.Safe(enter, self) end)
  f:SetScript("OnLeave", function() M.Safe(leave) end)
end

local function initRow(f, e)
  f.entry = e
  M.Kit.ClassIcon(f.icon, e.class)
  local cc = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[e.class]
  f.name:SetText(ns.Escape(e.name) .. (e.you and " (you)" or ""))
  if cc then f.name:SetTextColor(cc.r, cc.g, cc.b) else f.name:SetTextColor(1, 1, 1) end
  f.res:SetText(Core.Tries(e.tries) .. "/6")
  f.streak:SetText((e.streak or 0) > 0 and ("streak " .. e.streak) or "-")
end

-- ---------- build ----------

local function buildRight(body)
  -- The kit's section header, or a plain one when it answers nil (API.md:1199).
  local function header(parent, text)
    local h = M.Kit.SectionHeader(parent, 360, text)
    if h then return h end
    h = CreateFrame("Frame", nil, parent)
    h:SetSize(360, 26)
    local fs = label(h, "GameFontNormal")
    fs:SetPoint("LEFT", h, "LEFT", 8, 0)
    fs:SetText(text)
    return h
  end
  U.daily = CreateFrame("Frame", nil, body)
  U.daily:SetPoint("TOPLEFT", body, "TOPLEFT", RX, 0)
  U.daily:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -14, 0)
  local head = header(U.daily, "Your WoWdle")
  head:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 0, 0)
  head:SetPoint("TOPRIGHT", U.daily, "TOPRIGHT", 0, 0)
  U.statValues, U.statLabels, U.bars = {}, {}, {}
  for i, name in ipairs({ "played", "won", "streak", "best" }) do
    U.statValues[i] = label(U.daily, "GameFontHighlightLarge")
    U.statLabels[i] = label(U.daily)
    U.statLabels[i]:SetText(name)
    grey(U.statLabels[i])
  end
  for i = 1, TRIES do
    local y = -(74 + (i - 1) * 15)
    local digit = label(U.daily)
    grey(digit)
    digit:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 8, y)
    digit:SetText(tostring(i))
    local bar = { fill = U.daily:CreateTexture(nil, "ARTWORK") }
    bar.fill:SetHeight(12)
    bar.fill:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 22, y)
    bar.fill:SetColorTexture(0.314, 0.314, 0.329, 1)
    bar.count = label(U.daily)
    bar.count:SetPoint("RIGHT", bar.fill, "RIGHT", -4, 0)
    U.bars[i] = bar
  end
  local guild = header(U.daily, "Today in the guild")
  guild:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 0, -170)
  guild:SetPoint("TOPRIGHT", U.daily, "TOPRIGHT", 0, -170)
  U.played = label(guild)
  grey(U.played)
  U.played:SetPoint("TOPRIGHT", guild, "TOPRIGHT", -21, -8)
  local box = CreateFrame("Frame", nil, U.daily)
  box:SetPoint("TOPLEFT", U.daily, "TOPLEFT", 0, -196)
  box:SetPoint("BOTTOMRIGHT", U.daily, "BOTTOMRIGHT", 0, 36)
  U.list = M.Kit.List(box, 22, buildRow, initRow)
  U.share = button(U.daily, "Share to guild chat", 156)
  U.share:SetPoint("BOTTOMLEFT", U.daily, "BOTTOMLEFT", 8, 8)
  U.share:SetScript("OnClick", function() M.Safe(share) end)
  local practice = button(U.daily, "Practice", 96)
  practice:SetPoint("BOTTOMLEFT", U.daily, "BOTTOMLEFT", 172, 8)
  practice:SetScript("OnClick", function() M.Safe(switch, ns.NewPractice) end)

  U.prac = CreateFrame("Frame", nil, body)
  U.prac:SetPoint("TOPLEFT", body, "TOPLEFT", RX, 0)
  U.prac:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -14, 0)
  local mark = header(U.prac, "Practice")
  mark:SetPoint("TOPLEFT", U.prac, "TOPLEFT", 0, 0)
  mark:SetPoint("TOPRIGHT", U.prac, "TOPRIGHT", 0, 0)
  local lines = { "Random WoW words, as many as you like.", "Not shared with the guild, not in your stats." }
  for i, text in ipairs(lines) do
    local fs = label(U.prac)
    grey(fs)
    fs:SetPoint("TOPLEFT", U.prac, "TOPLEFT", 8, -(34 + (i - 1) * 16))
    fs:SetText(text)
  end
  local new = button(U.prac, "New word", 110)
  new:SetPoint("TOPLEFT", U.prac, "TOPLEFT", 8, -76)
  new:SetScript("OnClick", function() M.Safe(switch, ns.NewPractice) end)
  local back = button(U.prac, "Back to today's word", 160)
  back:SetPoint("TOPLEFT", U.prac, "TOPLEFT", 126, -76)
  back:SetScript("OnClick", function() M.Safe(switch, function() ns.SetMode("daily") end) end)
  U.wait = label(U.prac)
  grey(U.wait)
  U.wait:SetPoint("TOPLEFT", U.prac, "TOPLEFT", 8, -110)
  U.prac:Hide()
end

local function buildBox(board)
  local box = CreateFrame("EditBox", nil, board)
  box:SetFontObject("ChatFontNormal")
  box:SetTextColor(1, 1, 1, 0)
  box:SetHighlightColor(0, 0, 0, 0) -- no selection highlight over the tiles (f7128)
  box:SetAutoFocus(false)
  box:SetAllPoints(board)
  box:SetScript("OnMouseDown", function(self) self:SetFocus() end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEnterPressed", function() M.Safe(submit) end)
  box:SetScript("OnTextChanged", function(self)
    local text = typed(self)
    local clean = string.sub((string.gsub(string.upper(text), "[^A-Z]", "")), 1, U.len)
    if clean ~= text then self:SetText(clean) end
    U.Mirror()
  end)
  return box
end

local function build(body)
  U.body = body
  U.title = label(body, "GameFontNormalLarge")
  U.title:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -4)
  U.sub = label(body)
  grey(U.sub)
  U.sub:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -26)
  U.board = CreateFrame("Frame", nil, body)
  for r = 1, TRIES do
    U.tiles[r] = {}
    for i = 1, 6 do U.tiles[r][i] = cell("Frame", U.board, "GameFontHighlightHuge") end
  end
  U.box = buildBox(U.board)
  U.msg = label(body, "GameFontHighlight")
  U.msg:SetWidth(COL_W)
  U.msg:SetJustifyH("CENTER")
  U.keyFrame = CreateFrame("Frame", nil, body)
  local function key(ch, font)
    local k = cell("Button", U.keyFrame, font)
    k.fs:SetText(ch)
    paint(k, "t")
    k:SetScript("OnClick", function() M.Safe(press, ch) end)
    U.keys[ch] = k
  end
  for _, letters in ipairs(KEY_ROWS) do
    for ch in letters:gmatch("%u") do key(ch, "GameFontHighlight") end
  end
  key("Enter", "GameFontHighlightSmall")
  key("Back", "GameFontHighlightSmall")
  buildRight(body)
  body:HookScript("OnHide", function() U.box:ClearFocus() end)
  body:HookScript("OnSizeChanged", function() M.Safe(U.Layout) end)
  U.rows = {}
end

ns.WoWdle = {
  Build = build,
  Refresh = function()
    if U.body then U.Draw() end
  end,
}
