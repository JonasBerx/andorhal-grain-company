-- GuildSyncGames Vendor.lua (S12 Task 6): the Vendor price tab, ns.VendorTab (mock vp-1 to vp-6). Left: the title,
-- the sub line, two item cards (icon, name in its quality colour, the quality word; the prices and right or wrong only
-- after the pick), the marks row, the status line, Next pair, and at the foot Daily / Endless / Share. A finished daily
-- run shows the score, the grain earned and the ten answers instead of the cards. Right: Today in the guild, Best
-- endless streak and Daily streak. All UI state lives in V.
-- The tooltip is our own (M.Compat.Tooltip(): the name and the quality word); the game's item tooltip is never asked,
-- before or after the pick (o1652), so nothing here shows an item the player has not seen in game.
-- ns.VendorToday, ns.VendorPick, ns.VendorMode, ns.VendorEndless, ns.VendorStats, ns.VendorGuild, ns.VendorBoard,
-- ns.Purse, ns.OpenChat and ns.ShownGame are looked up at call time (f7165: Demo.lua wraps them, tests replace them).
-- Endless picks go through ns.VendorPick(k) on ns.VendorEndless().pair (G7); ns.VendorMode("endless") starts a new run.

local _, ns = ...

if not ns.M then return end
local M, VC = ns.M, ns.VendorCore

local LEFT, GAP, OR_W = 8, 12, 30
local SMALL_BELOW = 420 -- below this height (the 760x480 window) the cards, rows and lists shrink (vp-6)
local BIG = { rw = 240, ch = 170, icon = 52, rh = 22, today = 8, board = 4 }
local SMALL = { rw = 200, ch = 146, icon = 44, rh = 19, today = 3, board = 3 } -- rh 19: the ten answers end above the
-- button row with the 16 px games footer under the holder (S14 T7, d1613)
local RUN = 10
local LIST_ROW = 20
local WHEAT = 134058 -- INV_Misc_Food_Wheat_01
local RIGHT_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4"
local WRONG_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5"
local COIN = { "Interface\\MoneyFrame\\UI-GoldIcon", "Interface\\MoneyFrame\\UI-SilverIcon",
  "Interface\\MoneyFrame\\UI-CopperIcon" }
local GREEN, RED = "|cff1eff00", "|cffff4040"
local UNKNOWN = "The guild list is not known yet."
local HINT = "Click an item. 5 grain a right pick, 25 more for all ten." -- before a pick (mock vp-1)
local ANS_GAP = 14 -- between the two sides of an answer row (mock vp-3)

local V = { cards = {}, marks = {}, answers = {}, lists = {} }

local grey, label, button, fmt = ns.UI.grey, ns.UI.label, ns.UI.button, ns.UI.fmt -- Page.lua's helpers

local function header(parent, text)
  local h = M.Kit.SectionHeader(parent, 240, text)
  if h then return h end
  h = CreateFrame("Frame", nil, parent)
  h:SetSize(240, 26)
  local fs = label(h, "GameFontNormal")
  fs:SetPoint("LEFT", h, "LEFT", 8, 0)
  fs:SetText(text)
  return h
end

-- An item's name in its quality colour (VC.QUALITY, never ITEM_QUALITY_COLORS).
local function coloured(it)
  local q = VC.QUALITY[it.quality] or VC.QUALITY[1]
  return "|cff" .. q.colour .. it.name .. "|r"
end

-- 28920 -> "2 (gold) 89 (silver) 20 (copper)": the nonzero parts, each with its coin escape (the client's money string).
local function money(copper)
  local parts, out = { VC.Coins(copper) }, {}
  for i = 1, 3 do
    if parts[i] > 0 then out[#out + 1] = parts[i] .. "|T" .. COIN[i] .. ":0|t" end
  end
  if #out == 0 then return "0|T" .. COIN[3] .. ":0|t" end
  return table.concat(out, " ")
end

-- A text's drawn width: the client's measure, else about 7 px a character and 14 px a coin icon.
local function textWidth(fs, text)
  local w = fs.GetStringWidth and fs:GetStringWidth()
  if type(w) == "number" and w > 0 then return w end
  return 7 * #(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "  "))
end

local function dearer(pair)
  if pair.a.price >= pair.b.price then return pair.a, pair.b end
  return pair.b, pair.a
end

-- ---------- placing ----------

local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", V.body, "TOPLEFT", x, -y)
end

local function size()
  local w, h = V.body:GetWidth(), V.body:GetHeight()
  if type(w) ~= "number" or w <= 0 then w = 726 end
  if type(h) ~= "number" or h <= 0 then h = 486 end
  return w, h
end

-- The marks row at x, y: a box for each pick still open, the raid icon for a right or wrong one.
local function drawMarks(marks, x, y)
  for i, m in ipairs(V.marks) do
    local ch = marks and marks:sub(i, i) or ""
    at(m.box, x + (i - 1) * 18, y)
    m.icon:SetAllPoints(m.box)
    m.box:SetShown(ch == "")
    m.icon:SetShown(ch ~= "")
    if ch ~= "" then m.icon:SetTexture(ch == "1" and RIGHT_ICON or WRONG_ICON) end
  end
end

local function hideMarks()
  for _, m in ipairs(V.marks) do m.box:Hide(); m.icon:Hide() end
end

-- The two cards for pair; picked = { k, right } once a card was picked (then both prices show).
local function drawCards(pair, picked, B, LW)
  local cw = math.floor((LW - OR_W) * 0.5)
  for k, c in ipairs(V.cards) do
    local it = k == 1 and pair.a or pair.b
    c.item = it
    c.f:SetSize(cw, B.ch)
    at(c.f, LEFT + (k - 1) * (cw + OR_W), 46)
    c.f:Show()
    c.icon:SetSize(B.icon, B.icon)
    c.icon:SetTexture(it.icon)
    c.name:SetWidth(cw - 12)
    c.name:ClearAllPoints()
    c.name:SetPoint("TOP", c.f, "TOP", 0, -(18 + B.icon))
    c.name:SetText(coloured(it))
    c.quality:SetText((VC.QUALITY[it.quality] or VC.QUALITY[1]).word)
    c.verdict:SetWidth(cw - 12)
    c.accent:SetShown(picked ~= nil and picked.k == k) -- the picked card's gold accent (mock vp-2)
    if picked then
      local more = it == dearer(pair)
      c.price:SetText(money(it.price))
      c.verdict:SetText((more and (GREEN .. "Sells for more|r") or "Sells for less")
        .. (picked.k == k and " · your pick" or ""))
    else
      c.price:SetText("")
      c.verdict:SetText("")
    end
  end
  V.orText:ClearAllPoints()
  V.orText:SetPoint("CENTER", V.body, "TOPLEFT", LEFT + cw + OR_W * 0.5, -(46 + B.ch * 0.5))
  V.orText:Show()
end

local function hideCards()
  for _, c in ipairs(V.cards) do c.f:Hide(); c.item = nil end
  V.orText:Hide()
end

-- One side of an answer row: the name from x, cut with an ellipsis where the price (right-aligned at x + half) starts.
local function answerSide(name, price, it, x, y, half)
  local text = money(it.price)
  price:ClearAllPoints()
  price:SetPoint("TOPRIGHT", V.body, "TOPLEFT", x + half, -y)
  price:SetText(text)
  at(name, x, y)
  name:SetWidth(math.max(10, math.floor(half - textWidth(price, text) - 6)))
  name:SetText(coloured(it))
end

local function drawAnswers(t, B, LW)
  local half = math.floor((LW - 40 - ANS_GAP) * 0.5)
  at(V.answersHead, LEFT, 92)
  V.answersHead:SetWidth(LW)
  V.answersHead:Show()
  for i, r in ipairs(V.answers) do
    local pair, mark = t.pairs[i], t.picks:sub(i, i)
    local shown = pair ~= nil and mark ~= ""
    for _, f in ipairs({ r.num, r.icon, r.nameA, r.priceA, r.nameB, r.priceB }) do f:SetShown(shown) end
    if shown then
      local y = 120 + (i - 1) * B.rh
      local hi, lo = dearer(pair)
      at(r.num, LEFT, y)
      r.num:SetText(tostring(i))
      at(r.icon, LEFT + 20, y - 1)
      r.icon:SetTexture(mark == "1" and RIGHT_ICON or WRONG_ICON)
      answerSide(r.nameA, r.priceA, hi, LEFT + 40, y, half)
      answerSide(r.nameB, r.priceB, lo, LEFT + 40 + half + ANS_GAP, y, half)
    end
  end
end

local function hideAnswers()
  V.answersHead:Hide()
  for _, r in ipairs(V.answers) do
    for _, f in ipairs({ r.num, r.icon, r.nameA, r.priceA, r.nameB, r.priceB }) do f:Hide() end
  end
end

-- ---------- the right column ----------

local function byDesc(field)
  return function(x, y)
    if (x[field] or 0) ~= (y[field] or 0) then return (x[field] or 0) > (y[field] or 0) end
    return tostring(x.name) < tostring(y.name)
  end
end

-- One list under its header: rows (nil: not known yet), each a name and value(row); at most max rows. The empty or
-- not-known line takes the column's width and wraps (fault 2); a row's name is cut at rw - 80. With more set, a list
-- longer than max ends with "and N more" in the last slot (f7276; only Today in the guild, q1647).
local function drawList(L, rows, max, value, empty, rw, more)
  for i, r in ipairs(L.rows) do
    local e = rows and rows[i]
    local show = i <= max and (e ~= nil or i == 1)
    local note = more and show and e ~= nil and i == max and #rows > max
    r.icon:SetShown(show and e ~= nil and not note)
    r.name:SetShown(show)
    r.value:SetShown(show and e ~= nil and not note)
    r.name:SetWordWrap(e == nil)
    r.name:SetWidth(e and rw - 80 or rw - 32)
    if note then
      r.name:SetText("and " .. (#rows - max + 1) .. " more")
      grey(r.name)
      r.value:SetText("")
    elseif show and e then
      M.Kit.ClassIcon(r.icon, e.class)
      r.name:SetText(ns.Escape(e.name) .. (e.you and " |cff999999(you)|r" or ""))
      ns.UI.classColour(r.name, e.class)
      r.value:SetText(tostring(value(e)))
    elseif show then
      r.name:SetText(rows and empty or UNKNOWN)
      grey(r.name)
    end
  end
end

local function placeRight(B, W)
  local x, y = W - LEFT - B.rw, 0
  for _, L in ipairs(V.lists) do
    local n = L.today and B.today or B.board
    at(L.head, x, y)
    L.head:SetWidth(B.rw)
    for i, r in ipairs(L.rows) do
      local ry = y + 30 + (i - 1) * LIST_ROW
      at(r.icon, x + 4, ry)
      at(r.name, x + 24, ry + 1)
      r.value:ClearAllPoints()
      r.value:SetPoint("TOPRIGHT", V.body, "TOPLEFT", x + B.rw - 8, -(ry + 1))
    end
    y = y + 30 + n * LIST_ROW + 8
  end
end

local function drawRight(B, W)
  placeRight(B, W)
  local guild = ns.VendorGuild and ns.VendorGuild()
  local board = ns.VendorBoard and ns.VendorBoard()
  local today, best, streak = V.lists[1], V.lists[2], V.lists[3]
  today.extra:SetText(guild and (#guild .. " done") or "")
  drawList(today, guild, B.today, function(e) return (e.score or 0) .. "/10" end, "Nobody has finished today.",
    B.rw, true)
  local byBest, byStreak
  if board then
    byBest, byStreak = {}, {}
    for _, e in ipairs(board) do
      if (e.best or 0) > 0 then byBest[#byBest + 1] = e end
      if (e.streak or 0) > 0 then byStreak[#byStreak + 1] = e end
    end
    table.sort(byBest, byDesc("best"))
    table.sort(byStreak, byDesc("streak"))
  end
  drawList(best, byBest, B.board, function(e) return e.best end, "No endless runs yet.", B.rw)
  drawList(streak, byStreak, B.board, function(e) return e.streak .. (e.streak == 1 and " day" or " days") end,
    "No daily streaks yet.", B.rw)
end

-- ---------- drawing ----------

local function drawPurse(LW)
  local p = ns.Purse and ns.Purse()
  V.purseIcon:SetShown(p ~= nil)
  V.purse:SetShown(p ~= nil)
  if p == nil then return end
  at(V.purseIcon, LEFT + LW - 110, 4)
  at(V.purse, LEFT + LW - 90, 6)
  V.purse:SetText(fmt(p) .. " grain")
end

local function bottomButtons(e, t)
  local endless = e ~= nil
  V.daily:SetText(endless and "Back to daily" or ("Daily " .. (t and t.label or "")))
  V.endless:SetText(endless and "New endless run" or "Endless")
  V.endless:SetShown(not endless or e.done) -- f7280: no new run while one is going
  V.share:SetShown(not endless and t ~= nil and t.done and not V.last)
end

-- The status lines under the cards: what to do, or what the pick was.
local function drawStatus(picked, pair, sub, y, LW)
  at(V.status, LEFT, y + 24)
  V.status:SetWidth(LW - 130)
  V.sub:SetWidth(LW - 130)
  V.sub:ClearAllPoints()
  V.sub:SetPoint("TOPLEFT", V.status, "BOTTOMLEFT", 0, -4)
  if V.msg then
    V.status:SetText(RED .. V.msg .. "|r")
  elseif picked then
    local hi = dearer(pair)
    V.status:SetText((picked.right and (GREEN .. "Right.|r ") or (RED .. "Wrong.|r ")) .. hi.name .. " sells for more.")
  else
    V.status:SetText("Which sells for more to a vendor?")
  end
  V.sub:SetText(sub)
end

function V.Draw()
  local W, H = size()
  local B = H < SMALL_BELOW and SMALL or BIG
  local LW = W - LEFT - B.rw - GAP - LEFT
  local e = ns.VendorEndless and ns.VendorEndless()
  local t = ns.VendorToday and ns.VendorToday()
  local last = V.last
  if last and (last.endless ~= (e ~= nil) or (not last.endless and not (t and t.n == last.n))) then
    V.last, last = nil, nil
  end
  drawPurse(LW)
  bottomButtons(e, t)
  drawRight(B, W)
  local y0 = 46 + B.ch + GAP
  V.next:ClearAllPoints()
  V.next:SetPoint("TOPRIGHT", V.body, "TOPLEFT", LEFT + LW, -(y0 + 22))
  V.next:Hide()
  V.best:Hide()
  V.earned:Hide()
  V.earnedIcon:Hide()
  V.note:Hide()
  V.shown = nil
  hideAnswers()
  V.sub:Show()
  V.status:Show()
  V.lead:Show()
  if e then -- endless (vp-4)
    V.title2:SetText("Endless · pick until you miss · no grain")
    local pair = last and last.pair or e.pair
    if pair then drawCards(pair, last, B, LW) else hideCards() end
    hideMarks()
    at(V.lead, LEFT, y0)
    V.lead:SetText("Streak " .. (e.streak or 0))
    at(V.best, LEFT + 100, y0 + 2)
    V.best:SetText("Your best: " .. ((ns.VendorStats and ns.VendorStats() or {}).best or 0))
    V.best:Show()
    drawStatus(last, pair, e.done and "The run is over: start a new one."
      or "The pairs get closer as the streak grows. A wrong pick ends the run.", y0, LW) -- mock vp-4
    V.next:SetShown(last ~= nil and not e.done)
  elseif not t then -- no pairs today (no clock, or no draw)
    hideCards()
    hideMarks()
    V.title2:SetText("Vendor price")
    V.lead:SetText("No pairs today: the day is not known yet.")
    at(V.lead, LEFT, 46)
    V.status:Hide()
    V.sub:Hide()
  elseif t.done and not last then -- the finished run (vp-3)
    hideCards()
    V.title2:SetText("Daily " .. t.label .. " · finished · a new run at the daily reset")
    at(V.lead, LEFT, 48)
    V.lead:SetText(GREEN .. VC.Rights(t.picks) .. "/10|r")
    drawMarks(t.picks, LEFT + 60, 48)
    at(V.earnedIcon, LEFT, 70)
    V.earnedIcon:Show()
    at(V.earned, LEFT + 22, 72)
    V.earned:SetText((t.earned or 0) .. " grain earned")
    V.earned:Show()
    local r = VC.Rights(t.picks)
    at(V.note, LEFT + 160, 72)
    V.note:SetWidth(LW - 160)
    V.note:SetText(V.msg or (r .. (r == 1 and " right pick" or " right picks") .. " at 5")) -- mock vp-3
    V.note:Show()
    V.status:Hide()
    V.sub:Hide()
    drawAnswers(t, B, LW)
  else -- a pair to pick, or the one just picked (vp-1, vp-2)
    V.title2:SetText("Daily " .. t.label .. " · the same ten pairs for the whole guild")
    local i = last and last.i or (#t.picks + 1)
    local pair = last and last.pair or t.pairs[i]
    if pair then drawCards(pair, last, B, LW) else hideCards() end
    at(V.lead, LEFT, y0)
    V.lead:SetText("Pair " .. i .. " of " .. RUN)
    drawMarks(t.picks, LEFT + 100, y0)
    local right = VC.Rights(t.picks)
    drawStatus(last, pair, last and (right .. " of " .. #t.picks .. " right · " .. (t.earned or 0) .. " grain so far")
      or HINT, y0, LW)
    if not last then V.shown = { n = t.n, i = i, pair = pair } end -- what a click picks on (f7271)
    V.next:SetText(t.done and "Your results" or "Next pair")
    V.next:SetShown(last ~= nil)
  end
  V.title2:SetWidth(LW)
end

-- ---------- actions ----------

local function pick(k)
  if V.last then return end -- one pick a pair; Next pair moves on
  local e = ns.VendorEndless and ns.VendorEndless()
  local t = not e and ns.VendorToday and ns.VendorToday()
  local pair, i, n
  if e then
    if e.done then return end
    pair = e.pair
  elseif t and V.shown then -- the day and pair on screen, not a fresh read (f7271: the tab may be open over the reset)
    pair, i, n = V.shown.pair, V.shown.i, V.shown.n
  end
  if not pair then return end
  local good, right, text
  if e then good, right, text = ns.VendorPick(k) else good, right, text = ns.VendorPick(k, n, i) end
  V.msg = nil
  if good then
    V.last = { k = k, right = right, pair = pair, i = i, n = n, endless = e ~= nil }
  else
    V.msg = type(text) == "string" and text or nil
  end
  V.Draw()
end

local function mode(m)
  V.last, V.msg = nil, nil
  ns.VendorMode(m)
  V.Draw()
end

local function nextPair()
  V.last, V.msg = nil, nil
  V.Draw()
end

local function share()
  if ns.Inert and ns.Inert() then return end
  local t = ns.VendorToday and ns.VendorToday()
  if not (t and t.done) then return end
  if ns.OpenChat("/g " .. VC.ShareText(t.label, t.picks, true, 3)) then
    V.msg = "In the guild chat box: press Enter to send."
  else
    V.msg = "Type this in guild chat: " .. VC.ShareText(t.label, t.picks, false, 3)
  end
  V.Draw()
end

-- ---------- build ----------

local function enter(self)
  local it, tip = self.item, M.Compat.Tooltip()
  if not (it and tip) then return end
  local q = VC.QUALITY[it.quality] or VC.QUALITY[1]
  tip:SetOwner(self, "ANCHOR_RIGHT")
  tip:SetText(coloured(it))
  tip:AddLine(q.word, 0.8, 0.8, 0.8)
  tip:Show()
end

local function leave()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function buildCard(body, k)
  local f = CreateFrame("Button", nil, body)
  ns.UI.inset(f)
  local c = { f = f }
  c.icon = f:CreateTexture(nil, "ARTWORK")
  c.icon:SetPoint("TOP", f, "TOP", 0, -10)
  c.name = label(f, "GameFontNormal")
  c.name:SetJustifyH("CENTER")
  c.quality = label(f)
  c.quality:SetJustifyH("CENTER")
  grey(c.quality)
  c.quality:SetPoint("TOP", c.name, "BOTTOM", 0, -2)
  c.price = label(f, "GameFontHighlight")
  c.price:SetJustifyH("CENTER")
  c.price:SetPoint("TOP", c.quality, "BOTTOM", 0, -8)
  c.verdict = label(f)
  c.verdict:SetJustifyH("CENTER")
  grey(c.verdict)
  c.verdict:SetPoint("TOP", c.price, "BOTTOM", 0, -2)
  c.accent = f:CreateTexture(nil, "BORDER") -- as Kit.Card's accent: 2 px gold .55
  c.accent:SetColorTexture(1, 0.82, 0, 0.55)
  c.accent:SetWidth(2)
  c.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  c.accent:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  c.accent:Hide()
  f:SetScript("OnClick", function() M.Safe(pick, k) end)
  f:SetScript("OnEnter", function(self) f.item = c.item; M.Safe(enter, self) end)
  f:SetScript("OnLeave", function() M.Safe(leave) end)
  V.cards[k] = c
end

local function buildList(body, text, extra, max)
  local L = { head = header(body, text), rows = {}, today = text == "Today in the guild" }
  L.extra = label(L.head)
  L.extra:SetPoint("TOPRIGHT", L.head, "TOPRIGHT", -21, -8)
  L.extra:SetText(extra or "")
  for i = 1, max do
    local r = {}
    r.icon = body:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.name = label(body)
    r.name:SetWordWrap(false)
    r.value = label(body, "GameFontHighlight")
    r.value:SetJustifyH("RIGHT")
    L.rows[i] = r
  end
  V.lists[#V.lists + 1] = L
end

local function build(body)
  V.body = body
  local title = label(body, "GameFontHighlightLarge")
  title:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -4)
  title:SetText("Vendor price")
  V.title2 = label(body)
  grey(V.title2)
  V.title2:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -26)
  V.purseIcon = body:CreateTexture(nil, "ARTWORK")
  V.purseIcon:SetSize(16, 16)
  V.purseIcon:SetTexture(WHEAT)
  V.purse = label(body, "GameFontHighlight")
  for k = 1, 2 do buildCard(body, k) end
  V.orText = label(body, "GameFontNormal")
  V.orText:SetText("or")
  for i = 1, RUN do
    local m = { box = body:CreateTexture(nil, "ARTWORK"), icon = body:CreateTexture(nil, "OVERLAY") }
    m.box:SetSize(16, 16)
    M.Kit.Atlas(m.box, "checkbox-minimal")
    V.marks[i] = m
  end
  V.lead = label(body, "GameFontNormalLarge")
  V.best = label(body)
  grey(V.best)
  V.status = label(body, "GameFontHighlight")
  V.sub = label(body)
  grey(V.sub)
  V.next = button(body, "Next pair", 110)
  V.next:SetScript("OnClick", function() M.Safe(nextPair) end)
  V.earnedIcon = body:CreateTexture(nil, "ARTWORK")
  V.earnedIcon:SetSize(16, 16)
  V.earnedIcon:SetTexture(WHEAT)
  V.earned = label(body, "GameFontHighlight")
  V.note = label(body)
  grey(V.note)
  V.answersHead = header(body, "Your ten answers")
  local dear = label(V.answersHead) -- mock vp-3
  dear:SetPoint("TOPRIGHT", V.answersHead, "TOPRIGHT", -21, -8)
  dear:SetText("the dearer item first")
  grey(dear)
  for i = 1, RUN do
    local r = { num = label(body), icon = body:CreateTexture(nil, "ARTWORK"), nameA = label(body), nameB = label(body),
      priceA = label(body, "GameFontHighlight"), priceB = label(body, "GameFontHighlight") }
    grey(r.num)
    r.icon:SetSize(16, 16)
    r.priceA:SetJustifyH("RIGHT")
    r.priceB:SetJustifyH("RIGHT")
    r.nameA:SetWordWrap(false) -- cut with an ellipsis before the price (f7272)
    r.nameB:SetWordWrap(false)
    V.answers[i] = r
  end
  V.daily = button(body, "Daily", 110)
  V.daily:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", LEFT, 8)
  V.daily:SetScript("OnClick", function() M.Safe(mode, "daily") end)
  V.endless = button(body, "Endless", 120)
  V.endless:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", LEFT + 118, 8)
  V.endless:SetScript("OnClick", function() M.Safe(mode, "endless") end)
  V.share = button(body, "Share", 80)
  V.share:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", LEFT + 246, 8)
  V.share:SetScript("OnClick", function() M.Safe(share) end)
  buildList(body, "Today in the guild", "", BIG.today)
  buildList(body, "Best endless streak", nil, BIG.board)
  buildList(body, "Daily streak", "days in a row", BIG.board)
  body:HookScript("OnSizeChanged", function() if ns.ShownGame and ns.ShownGame() == "vendor" then M.Safe(V.Draw) end end)
end

ns.VendorTab = {
  Build = build,
  -- Nothing is drawn unless the Vendor price tab is on screen (RefreshPage calls this while hidden too).
  Refresh = function()
    if V.body and ns.ShownGame and ns.ShownGame() == "vendor" then V.Draw() end
  end,
}
