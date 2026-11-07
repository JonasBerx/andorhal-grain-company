-- GuildSyncGames Vendor.lua (S12 Task 6, S21 Task 6): the Higher or lower tab, ns.VendorTab (mock vp-1 to vp-6,
-- fm-1 to fm-9). Left: the pool switch (Vendor price | Flights, a gold rule under the chosen one, as Company's store
-- groups), the sub line, two cards (an item: icon, name in its quality colour, the quality word; a flight: the wyvern,
-- from and to place and zone; the prices or the time, cost and stops and right or wrong only after the pick), the marks
-- row, the status line, Next pair, and at the foot Daily / Endless / Share. A finished daily run shows the score, the
-- grain earned and the ten answers instead of the cards (a Flights row's hover shows both full routes). Right: Today in
-- the guild, Best endless streak and Daily streak. All UI state lives in V; V.pool is "items" or "flights".
-- The tooltip is our own (M.Compat.Tooltip(): the name and the quality word, or a route's places and zones); the
-- game's item tooltip is never asked, before or after the pick (o1652), so nothing here shows an item the player has
-- not seen in game, and nothing shows a flight's time, cost or stops before its pick.
-- ns.VendorToday, ns.VendorPick, ns.VendorMode, ns.VendorEndless, ns.VendorStats, ns.VendorGuild, ns.VendorBoard,
-- ns.VendorPool, ns.SetVendorPool, ns.RouteCore, ns.Purse, ns.OpenChat and ns.ShownGame are looked up at call time
-- (f7165: Demo.lua wraps them, tests replace them). Every store call passes "flights" on Flights and no pool on Vendor
-- price (seam-check f1). Endless picks go through ns.VendorPick(k) (Flights: (k, nil, nil, "flights")) on
-- ns.VendorEndless(pool).pair (G7); ns.VendorMode("endless", pool) starts a new run.

local _, ns = ...

if not ns.M then return end
local M, VC, GC = ns.M, ns.VendorCore, ns.GrainCore

local LEFT, GAP, OR_W = 8, 12, 30
local SMALL_BELOW = 420 -- below this height (the 760x480 window) the cards, rows and lists shrink (vp-6)
-- fch, ficon: a Flights card holds five route lines and three value lines, so it is taller (mock fm-2, fm-9a)
local BIG = { rw = 240, ch = 170, icon = 52, fch = 200, ficon = 52, rh = 22, today = 8, board = 4 }
local SMALL = { rw = 200, ch = 146, icon = 44, fch = 176, ficon = 40, rh = 19, today = 3, board = 3 } -- rh 19: the
-- ten answers end above the button row with the 16 px games footer under the holder (S14 T7, d1613)
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
local FLIGHT_HINT = "Click a flight. 5 grain a right pick, 25 more for all ten." -- mock fm-1a
local ANS_GAP = 14 -- between the two sides of an answer row (mock vp-3)
local WYVERN = 132268 -- Interface\Icons\Ability_Mount_Wyvern_01 (NOTES-fm.md Art)
local CARD_LINE = 14 -- a Flights card line: one FontString each at a fixed step, so nothing hangs on a wrapped height
local POOLS = { { key = "items", text = "Vendor price", w = 104 }, { key = "flights", text = "Flights", w = 80 } }
local QUESTION = { time = "Which flight takes longer?", cost = "Which flight costs more?",
  stops = "Which flight has more stops?" }
local WORD = { time = "Time", cost = "Cost", stops = "Stops" }
local FIELD = { time = "yards", cost = "copper", stops = "stops" }
local MORE = { time = "Takes longer", cost = "Costs more", stops = "More stops" }
local LESS = { time = "Shorter", cost = "Costs less", stops = "Fewer stops" }
local VERB = { time = " takes longer.", cost = " costs more.", stops = " has more stops." }
-- The Lucky charm's refusal codes as the page says them (the button is hidden without a day and in demo).
local CHARM_WHY = {
  started = "The day's run has started.",
  owned = "You have a charm on this game today.",
  short = "Not enough grain in the purse.",
}

local V = { cards = {}, marks = {}, answers = {}, lists = {}, pools = {}, pool = "items" }

-- The pool a store call carries: "flights", or nil for Vendor price (seam-check f1: the S12 calls stay as they were).
local function poolArg() return V.pool == "flights" and "flights" or nil end
local function flying() return V.pool == "flights" end

local grey, label, button = ns.UI.grey, ns.UI.label, ns.UI.button -- Page.lua's helpers

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

-- The side with the larger answer first: the dearer item, or the route with the larger value for the question.
local function dearer(pair)
  local f = pair.q and FIELD[pair.q] or "price"
  if pair.a[f] >= pair.b[f] then return pair.a, pair.b end
  return pair.b, pair.a
end

-- ---------- a flight ----------

local function node(id)
  return ns.RouteCore.Node(id) or { place = "?", zone = "" }
end

-- "Orgrimmar to Gadgetzan" (the places only).
local function routeName(r)
  return node(r.from).place .. " to " .. node(r.to).place
end

-- "Durotar to Tanaris" (a node with no zone gives its place, f10).
local function routeZones(r)
  local a, b = node(r.from), node(r.to)
  return (a.zone ~= "" and a.zone or a.place) .. " to " .. (b.zone ~= "" and b.zone or b.place)
end

-- "Direct", "1 stop", "N stops" (q1774).
local function stopsText(n)
  if n == 0 then return "Direct" end
  return n .. (n == 1 and " stop" or " stops")
end

-- A route's value for a question: m:ss, the cost in coins, or the stops; only ever drawn after the pick.
local function valueText(r, q)
  if q == "time" then return ns.RouteCore.Clock(r.yards) elseif q == "cost" then return money(r.copper) end
  return stopsText(r.stops)
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
  local fl = pair.q ~= nil -- a Flights pair (mock fm-1, fm-2)
  local ch, icon = fl and B.fch or B.ch, fl and B.ficon or B.icon
  for k, c in ipairs(V.cards) do
    local it = k == 1 and pair.a or pair.b
    c.item = it
    c.f:SetSize(cw, ch)
    at(c.f, LEFT + (k - 1) * (cw + OR_W), 46)
    c.f:Show()
    c.icon:SetSize(icon, icon)
    c.icon:SetTexture(fl and WYVERN or it.icon)
    c.name:SetWidth(cw - 12)
    c.name:ClearAllPoints()
    c.name:SetPoint("TOP", c.f, "TOP", 0, -(18 + icon))
    c.name:SetText(fl and "" or coloured(it))
    c.quality:SetText(fl and "" or (VC.QUALITY[it.quality] or VC.QUALITY[1]).word)
    c.verdict:SetWidth(cw - 12)
    c.accent:SetShown(picked ~= nil and picked.k == k) -- the picked card's gold accent (mock vp-2)
    local more = picked and it == dearer(pair)
    -- A Flights card, one line each (mock fm-1, fm-2): from place, from zone, "to", to place, to zone (no line for an
    -- empty zone, f10), then after the pick the time, the cost and stops, and the verdict.
    local y, texts = 16 + icon, {}
    if fl then
      local a, b = node(it.from), node(it.to)
      texts = { a.place, a.zone, "to", b.place, b.zone }
      if picked then
        texts[6] = ns.RouteCore.Clock(it.yards)
        texts[7] = money(it.copper) .. " · " .. stopsText(it.stops)
        texts[8] = (more and (GREEN .. MORE[pair.q] .. "|r") or LESS[pair.q])
          .. (picked.k == k and " · your pick" or "")
      end
    end
    for i, fs in ipairs(c.fl) do
      local text = texts[i] or ""
      if i == 6 then y = y + 6 end
      fs:SetShown(text ~= "")
      fs:SetText(text)
      fs:SetWidth(cw - 12)
      fs:ClearAllPoints()
      fs:SetPoint("TOP", c.f, "TOP", 0, -y)
      if text ~= "" then y = y + CARD_LINE end
    end
    if picked and not fl then
      c.price:SetText(money(it.price))
      c.verdict:SetText((more and (GREEN .. "Sells for more|r") or "Sells for less")
        .. (picked.k == k and " · your pick" or ""))
    else
      c.price:SetText("")
      c.verdict:SetText("")
    end
  end
  V.orText:ClearAllPoints()
  V.orText:SetPoint("CENTER", V.body, "TOPLEFT", LEFT + cw + OR_W * 0.5, -(46 + ch * 0.5))
  V.orText:Show()
end

local function hideCards()
  for _, c in ipairs(V.cards) do c.f:Hide(); c.item = nil end
  V.orText:Hide()
end

-- One side of an answer row: the name from x, cut with an ellipsis where the price or value (right-aligned at x +
-- half) starts. it is an item, or a route of a Flights pair asking q.
local function answerSide(name, price, it, q, x, y, half)
  local text = q and valueText(it, q) or money(it.price)
  price:ClearAllPoints()
  price:SetPoint("TOPRIGHT", V.body, "TOPLEFT", x + half, -y)
  price:SetText(text)
  at(name, x, y)
  name:SetWidth(math.max(10, math.floor(half - textWidth(price, text) - 6)))
  name:SetText(q and routeName(it) or coloured(it))
end

local function drawAnswers(t, B, LW)
  local fl = t.pairs[1] ~= nil and t.pairs[1].q ~= nil
  local x0 = fl and 84 or 40 -- a Flights row has its question word after the mark (mock fm-3)
  local half = math.floor((LW - x0 - ANS_GAP) * 0.5)
  at(V.answersHead, LEFT, 92)
  V.answersHead:SetWidth(LW)
  V.answersHead:Show()
  V.dear:SetText(fl and "the right answer first" or "the dearer item first")
  for i, r in ipairs(V.answers) do
    local pair, mark = t.pairs[i], t.picks:sub(i, i)
    local shown = pair ~= nil and mark ~= ""
    for _, f in ipairs({ r.num, r.icon, r.nameA, r.priceA, r.nameB, r.priceB }) do f:SetShown(shown) end
    r.word:SetShown(shown and fl)
    r.hover:SetShown(shown and fl)
    r.hover.pair, r.hover.i = shown and fl and pair or nil, i
    if shown then
      local y = 120 + (i - 1) * B.rh
      local hi, lo = dearer(pair)
      at(r.num, LEFT, y)
      r.num:SetText(tostring(i))
      at(r.icon, LEFT + 20, y - 1)
      r.icon:SetTexture(mark == "1" and RIGHT_ICON or WRONG_ICON)
      if fl then
        at(r.word, LEFT + 40, y)
        r.word:SetText(WORD[pair.q])
        at(r.hover, LEFT, y - 3)
        r.hover:SetSize(LW, B.rh)
      end
      answerSide(r.nameA, r.priceA, hi, pair.q, LEFT + x0, y, half)
      answerSide(r.nameB, r.priceB, lo, pair.q, LEFT + x0 + half + ANS_GAP, y, half)
    end
  end
end

local function hideAnswers()
  V.answersHead:Hide()
  for _, r in ipairs(V.answers) do
    for _, f in ipairs({ r.num, r.icon, r.nameA, r.priceA, r.nameB, r.priceB, r.word, r.hover }) do f:Hide() end
    r.hover.pair = nil
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
  local guild = ns.VendorGuild and ns.VendorGuild(poolArg())
  local board = ns.VendorBoard and ns.VendorBoard(poolArg())
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
  if V.msg then
    V.status:SetText(RED .. V.msg .. "|r")
  elseif picked then
    local hi = dearer(pair)
    V.status:SetText((picked.right and (GREEN .. "Right.|r ") or (RED .. "Wrong.|r "))
      .. (pair.q and (routeName(hi) .. VERB[pair.q]) or (hi.name .. " sells for more.")))
  else
    V.status:SetText(pair and pair.q and QUESTION[pair.q] or "Which sells for more to a vendor?")
  end
  -- The sub line at a measured y, not on the status line's wrapped bottom: one, two or three lines as the text is
  -- wider than one or two columns (the unbounded width when it is a number above 0, S15; else textWidth).
  local text = V.status:GetText() or ""
  local w = V.status.GetUnboundedStringWidth and V.status:GetUnboundedStringWidth()
  if not (type(w) == "number" and w > 0) then w = textWidth(V.status, text) end
  local lines = w > 2 * (LW - 130) and 3 or w > LW - 130 and 2 or 1 -- review f3: at most three
  at(V.sub, LEFT, y + 24 + lines * 14 + 4)
  V.sub:SetText(sub)
end

-- The Lucky charm on the title row at the left column's right edge: the button before the day's first pick, the icon
-- and its line once bought (o2766, o2769); nothing in endless.
local function drawCharm(e, t, LW)
  local on = not e and t ~= nil and t.charm == true
  V.charm:SetShown(not e and t ~= nil and not on and #(t.picks or "") == 0)
  V.charm:ClearAllPoints()
  V.charm:SetPoint("TOPRIGHT", V.body, "TOPLEFT", LEFT + LW, -2)
  V.charmLine:ClearAllPoints()
  V.charmLine:SetPoint("TOPRIGHT", V.body, "TOPLEFT", LEFT + LW, -6)
  V.charmLine:SetWidth(math.min(200, LEFT + LW - 222)) -- clear of the pool switch (x 8..198) with the icon
  V.charmLine:SetShown(on)
  V.charmIcon:SetShown(on)
end

function V.Draw()
  local W, H = size()
  local B = H < SMALL_BELOW and SMALL or BIG
  local LW = W - LEFT - B.rw - GAP - LEFT
  local e = ns.VendorEndless and ns.VendorEndless(poolArg())
  local t = ns.VendorToday and ns.VendorToday(poolArg())
  local last = V.last
  if last and (last.endless ~= (e ~= nil) or (not last.endless and not (t and t.n == last.n))) then
    V.last, last = nil, nil
  end
  for _, p in ipairs(V.pools) do -- the gold rule 1 px under the chosen pool's button (Company.lua:331-332)
    if p.key == V.pool then at(V.mark, p.x, 25); V.mark:SetWidth(p.w) end
  end
  bottomButtons(e, t)
  drawCharm(e, t, LW)
  drawRight(B, W)
  local y0 = 46 + (flying() and B.fch or B.ch) + GAP
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
    V.best:SetText("Your best: " .. ((ns.VendorStats and ns.VendorStats(poolArg()) or {}).best or 0))
    V.best:Show()
    drawStatus(last, pair, e.done and "The run is over: start a new one."
      or "The pairs get closer as the streak grows. A wrong pick ends the run.", y0, LW) -- mock vp-4
    V.next:SetText("Next pair") -- visual f1: never the daily's "Your results"
    V.next:SetShown(last ~= nil and not e.done)
  elseif not t then -- no pairs today (no clock, or no draw)
    hideCards()
    hideMarks()
    V.title2:SetText(flying() and "Flights" or "Vendor price") -- the pool on screen
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
      or (flying() and FLIGHT_HINT or HINT), y0, LW)
    if not last then V.shown = { n = t.n, i = i, pair = pair, pool = poolArg() } end -- what a click picks on (f7271)
    V.next:SetText(t.done and "Your results" or "Next pair")
    V.next:SetShown(last ~= nil)
  end
  V.title2:SetWidth(LW)
end

-- ---------- actions ----------

local function pick(k)
  if V.last then return end -- one pick a pair; Next pair moves on
  local e = ns.VendorEndless and ns.VendorEndless(poolArg())
  local t = not e and ns.VendorToday and ns.VendorToday(poolArg())
  local pair, i, n, pool
  if e then
    if e.done then return end
    pair, pool = e.pair, poolArg()
  elseif t and V.shown then -- the day and pair on screen, not a fresh read (f7271: the tab may be open over the reset)
    pair, i, n, pool = V.shown.pair, V.shown.i, V.shown.n, V.shown.pool
  end
  if not pair then return end
  local good, right, text
  if pool then -- Flights: the pool always goes along (f3)
    good, right, text = ns.VendorPick(k, n, i, pool)
  elseif e then
    good, right, text = ns.VendorPick(k)
  else
    good, right, text = ns.VendorPick(k, n, i)
  end
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
  ns.VendorMode(m, poolArg())
  V.Draw()
end

local function buyCharm()
  local good, why = ns.VendorBuyCharm(poolArg())
  V.msg = not good and CHARM_WHY[why] or nil
  V.Draw()
end

local function nextPair()
  V.last, V.msg = nil, nil
  V.Draw()
end

-- The switch: the other pool is remembered (q1776) and drawn with nothing of the last one's pick or message (f4).
local function setPool(p)
  if p == V.pool then return end
  V.pool, V.last, V.msg, V.shown = p, nil, nil, nil
  if ns.SetVendorPool then ns.SetVendorPool(p) end
  V.Draw()
end

local function share()
  if ns.Inert and ns.Inert() then return end
  local t = ns.VendorToday and ns.VendorToday(poolArg())
  if not (t and t.done) then return end
  local name = flying() and "Flights" or nil
  if ns.OpenChat("/g " .. VC.ShareText(t.label, t.picks, true, 3, name)) then
    V.msg = "In the guild chat box: press Enter to send."
  else
    V.msg = "Type this in guild chat: " .. VC.ShareText(t.label, t.picks, false, 3, name)
  end
  V.Draw()
end

-- ---------- build ----------

-- A card's tooltip: an item's name and quality word, or a route's places and zones (never its time, cost or stops).
local function enter(self)
  local it, tip = self.item, M.Compat.Tooltip()
  if not (it and tip) then return end
  tip:SetOwner(self, "ANCHOR_RIGHT")
  if it.from then
    tip:SetText(routeName(it), 1, 1, 1)
    tip:AddLine(routeZones(it), 0.8, 0.8, 0.8)
  else
    tip:SetText(coloured(it))
    tip:AddLine((VC.QUALITY[it.quality] or VC.QUALITY[1]).word, 0.8, 0.8, 0.8)
  end
  tip:Show()
end

-- A finished Flights answer row's tooltip (A2, mock fm-9c): the question, then both full routes and their values, the
-- larger first in green.
local function rowEnter(self)
  local pair, tip = self.pair, M.Compat.Tooltip()
  if not (pair and tip) then return end
  tip:SetOwner(self, "ANCHOR_BOTTOM")
  tip:SetText(self.i .. ". " .. QUESTION[pair.q])
  local hi, lo = dearer(pair)
  for k, r in ipairs({ hi, lo }) do
    tip:AddLine(routeName(r), 1, 1, 1)
    tip:AddLine(routeZones(r), 0.6, 0.6, 0.6)
    if k == 1 then
      tip:AddLine(valueText(r, pair.q) .. " · " .. MORE[pair.q]:lower(), 0.12, 1, 0)
    else
      tip:AddLine(valueText(r, pair.q), 0.8, 0.8, 0.8)
    end
  end
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
  -- the Flights lines: places white, zones grey, "to" gold, the time white, the cost and stops grey, the verdict grey
  c.fl = {}
  for i, font in ipairs({ "GameFontHighlight", false, "GameFontNormal", "GameFontHighlight", false,
    "GameFontHighlight", false, false }) do
    local fs = label(f, font or nil)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(false)
    if not font then grey(fs) end
    c.fl[i] = fs
  end
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
  V.pool = ns.VendorPool and ns.VendorPool() == "flights" and "flights" or "items" -- the remembered pool (q1776)
  local x = LEFT
  for i, p in ipairs(POOLS) do -- the pool switch, both enabled, in the title row (o2169, q1767)
    local b = button(body, p.text, p.w)
    b:SetPoint("TOPLEFT", body, "TOPLEFT", x, -2)
    b:SetScript("OnClick", function() M.Safe(setPool, p.key) end)
    V.pools[i] = { key = p.key, x = x, w = p.w }
    x = x + p.w + 6
  end
  V.mark = body:CreateTexture(nil, "ARTWORK") -- the chosen pool's gold rule, as Company.lua's C.mark
  V.mark:SetColorTexture(1, 0.769, 0.251, 0.9)
  V.mark:SetHeight(2)
  V.title2 = label(body)
  grey(V.title2)
  V.title2:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -28)
  V.charm = button(body, "Lucky charm · " .. GC.CHARM_PRICE, 130)
  local ci = V.charm:CreateTexture(nil, "ARTWORK")
  ci:SetSize(16, 16)
  ci:SetPoint("LEFT", V.charm, "LEFT", 6, 0)
  ci:SetTexture(GC.CHARM_ICON)
  V.charm:SetScript("OnClick", function() M.Safe(buyCharm) end)
  V.charmLine = label(body)
  V.charmLine:SetText("Lucky charm: double grain today")
  V.charmIcon = body:CreateTexture(nil, "ARTWORK")
  V.charmIcon:SetSize(16, 16)
  V.charmIcon:SetPoint("TOPRIGHT", V.charmLine, "TOPLEFT", -4, 2)
  V.charmIcon:SetTexture(GC.CHARM_ICON)
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
  V.dear = label(V.answersHead) -- mock vp-3
  V.dear:SetPoint("TOPRIGHT", V.answersHead, "TOPRIGHT", -21, -8)
  V.dear:SetText("the dearer item first")
  grey(V.dear)
  for i = 1, RUN do
    local r = { num = label(body), icon = body:CreateTexture(nil, "ARTWORK"), nameA = label(body), nameB = label(body),
      priceA = label(body, "GameFontHighlight"), priceB = label(body, "GameFontHighlight"), word = label(body),
      hover = CreateFrame("Frame", nil, body) }
    grey(r.word)
    r.hover:EnableMouse(true) -- a Flights row's own tooltip (A2)
    M.Kit.ListHover(r.hover) -- the row lights under the mouse (a11y f1)
    r.hover:SetScript("OnEnter", function(self) M.Safe(rowEnter, self) end)
    r.hover:SetScript("OnLeave", function() M.Safe(leave) end)
    r.hover:Hide()
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
  -- Outside demo the saved pool wins (review f4: a demo switch saves nothing, so after demo off the tab follows it).
  Refresh = function()
    if V.body and ns.VendorPool and not M.Demo() then
      local p = ns.VendorPool() == "flights" and "flights" or "items"
      if p ~= V.pool then V.pool, V.last, V.msg, V.shown = p, nil, nil, nil end
    end
    if V.body and ns.ShownGame and ns.ShownGame() == "vendor" then V.Draw() end
  end,
  -- o2650 R2: the tab's own pool switch ("items" | "flights"), for the home's Flights card.
  SetPool = setPool,
}
