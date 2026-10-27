-- GuildSyncGames Company.lua (S13 Task 5): the Company tab, ns.CompanyTab (plan V2-V4, mock co-1 to co-4). Left: the
-- store (Titles, Colours, Badges, Field), the preview "How guildmates see you:" and the purse at the foot. Right: the
-- granary goal (project, bar, own gift, donors, Give buttons) and the weekly lottery (schedule, close countdown, pot,
-- own numbers, Buy a ticket, the waiting line or the officer's last draw). Below 420 tall (the 760x480 window) the
-- Owned / Worn word and the schedule line go and the last draw takes two short lines (d1594). All UI state lives in C.
-- ns.Purse, ns.CompanyState, ns.CompanyProjects, ns.CompanyDonors, ns.Lottery, ns.BuyItem, ns.Wear, ns.Donate,
-- ns.BuyTicket, ns.Now and ns.ShownGame are looked up at call time (f7165: Demo.lua wraps them, tests replace them).
-- Every player name goes through ns.Escape; item titles, colours and icons come from CompanyCore by id (d1589).

local _, ns = ...

if not ns.M then return end
local M = ns.M

local LEFT, GAP = 8, 12
local SMALL_BELOW = 420 -- below this height the small layout (co-4)
local BIG = { rw = 348, rh = 26, top = 40, small = false }
local SMALL = { rw = 268, rh = 23, top = 0, small = true }
local ROWS = 10 -- 4 store badges + 6 earned project badges at most
local BTN_W, WORD_W = 64, 35
local WHEAT = 134058 -- INV_Misc_Food_Wheat_01
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GOLD = { 1, 0.769, 0.251 }
local RED = "|cffff4040"
local GREEN = "|cff1eff00"
local GROUPS = { { key = "title", text = "Titles" }, { key = "colour", text = "Colours" },
  { key = "badge", text = "Badges" }, { key = "decor", text = "Field" }, { key = "officers", text = "Officers" } }
local PER_BIG, PER_SMALL = 10, 6 -- Officers rows a page at full size and at the minimum (of-1, of-4)
local PITCH = 30 -- one Officers row, hidden (two lines) or not (f7541)
local REFUSAL = {
  short = "Not enough grain in the purse.", owned = "You own this already.", demo = "Demo: nothing is saved.",
  cap = "You gave the most this project takes from one player.", closed = "Sales are closed until the draw.",
  rolled = "The week has moved on; try again.", max = "Ten tickets a week is the most.",
  clock = "No server clock yet.", unknown = "That player is not in the guild.",
  officer = "Only officers can do this.", self = "You cannot hide yourself.",
  full = "The hide list is full. Unhide someone first.",
}

local C = { group = "title", rows = {}, groups = {}, give = {}, page = 1 }

local grey, label, button, fmt = ns.UI.grey, ns.UI.label, ns.UI.button, ns.UI.fmt -- Page.lua's helpers

local function header(parent, text)
  local h = M.Kit.SectionHeader(parent, 240, text)
  if h then return h end
  h = CreateFrame("Frame", nil, parent)
  h:SetSize(240, 26)
  h.label = label(h, "GameFontNormal")
  h.label:SetPoint("TOPLEFT", h, "TOPLEFT", 21, -8)
  h.label:SetText(text)
  return h
end

local function headerExtra(h)
  local fs = label(h)
  fs:SetPoint("TOPRIGHT", h, "TOPRIGHT", -21, -8)
  return fs
end

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", C.body, "TOPLEFT", x, -y)
end

local function size()
  local w, h = C.body:GetWidth(), C.body:GetHeight()
  if type(w) ~= "number" or w <= 0 then w = 726 end
  if type(h) ~= "number" or h <= 0 then h = 486 end
  return w, h
end

-- Each shown item { f, x, gap } under the one before it (wrapped lines push the rest down); the first at x0 + x, y0.
local function chain(items, x0, y0)
  local prev, px
  for _, it in ipairs(items) do
    local f, x, gap = it[1], it[2] or 0, it[3] or 4
    if f:IsShown() then
      f:ClearAllPoints()
      if prev then f:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", x - px, -gap) else at(f, x0 + x, y0) end
      prev, px = f, x
    end
  end
end

-- The refusal line f shows while C.msg belongs to where (green for a success, C.msg.ok: f7542).
local function showMsg(f, where)
  local m = C.msg and C.msg.where == where
  f:SetShown(m)
  f:SetText(m and ((C.msg.ok and GREEN or RED) .. C.msg.text .. "|r") or "")
end

-- A FontString's text width in the GuildSyncBank/Cards.lua:94-102 order; nil when nothing answers a number.
local function textWidth(fs)
  if type(fs) ~= "table" then return nil end
  local u = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()
  if type(u) == "number" and u > 0 then return u end
  local sw = fs.GetStringWidth and fs:GetStringWidth()
  if type(sw) == "number" then return sw end
  return nil
end

-- Whether fs's text is cut: IsTruncated when the client has it, else the measured width over the set width.
local function cut(fs)
  if fs.IsTruncated then return fs:IsTruncated() and true or false end
  local w, set = textWidth(fs), fs:GetWidth()
  return type(w) == "number" and type(set) == "number" and w > set
end

local function showTip(owner, text, more)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(text, 1, 1, 1, 1, true)
  if more then tip:AddLine(more, 1, 1, 1, true) end
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

-- ---------- the store (V2) ----------

-- The rows of the chosen group: CompanyCore's items of that kind in id order, then (Badges) the earned project badges.
local function storeRows(CC, st)
  local out = {}
  for _, it in ipairs(CC.ITEMS) do
    if type(it) == "table" and it.kind == C.group then out[#out + 1] = { id = it.id, item = it } end
  end
  if C.group == "badge" then
    for k, p in ipairs(CC.PROJECTS) do
      local id = CC.PROJECT_BADGE_BASE + k
      if st.owned[id] then out[#out + 1] = { id = id, earned = p } end
    end
  end
  return out
end

local function drawRow(r, e, st, B, LW, y)
  local kind = C.group
  local owned = st.owned[e.id] and true or false
  local worn = kind ~= "decor" and owned and st[kind] == e.id
  local btnX = LW - BTN_W
  local wordR = btnX - 6
  local priceR = (B.small and btnX or wordR - WORD_W) - 8
  at(r.btn, LEFT + btnX, y)
  r.icon:Show()
  if e.earned then
    r.icon:SetTexture(e.earned.badge)
  elseif e.item.hex then
    r.icon:SetColorTexture(rgb(e.item.hex))
  elseif e.item.icon then
    r.icon:SetTexture(e.item.icon)
  else
    r.icon:Hide()
  end
  at(r.icon, LEFT, y + 3)
  at(r.name, LEFT + 22, y + 4)
  r.name:SetText(e.earned and ("Earned: " .. e.earned.name) or e.item.name)
  r.name:SetTextColor(1, 1, 1)
  r.name:Show()
  r.by:Hide()
  r.key = nil
  r.price:ClearAllPoints()
  r.price:SetPoint("TOPRIGHT", C.body, "TOPLEFT", LEFT + priceR, -(y + 4))
  r.price:SetText(e.item and (fmt(e.item.price) .. " grain") or "")
  r.price:SetShown(e.item ~= nil and not (kind == "decor" and owned))
  r.word:ClearAllPoints()
  r.word:SetPoint("TOPRIGHT", C.body, "TOPLEFT", LEFT + (kind == "decor" and LW or wordR), -(y + 4))
  -- the name is cut where the price ("5,000 grain", about 77 px), the word or the button starts
  local right = (kind == "decor" and owned and LW - 147) or (e.item and priceR - 77)
    or (B.small and btnX or wordR - WORD_W)
  r.name:SetWidth(math.max(10, right - 6 - 22))
  at(r.hit, LEFT + 22, y + 4) -- the name's line, clear of the button (f7544)
  r.hit:SetSize(btnX - 26, 14)
  r.hit:Show()
  r.id = e.id
  if kind == "decor" and owned then
    r.word:SetText("Owned (in your field)")
    r.word:SetTextColor(0.6, 0.6, 0.6)
    r.word:Show()
    r.btn:Hide()
    return
  end
  r.word:SetText(worn and "Worn" or "Owned")
  if worn then r.word:SetTextColor(0.12, 1, 0) else r.word:SetTextColor(0.6, 0.6, 0.6) end
  r.word:SetShown(owned and not B.small)
  r.btn:SetText(worn and "Remove" or owned and "Wear" or "Buy")
  r.btn.act = worn and "remove" or owned and "wear" or "buy"
  r.btn:Show()
end

local function drawPreview(CC, st, LW, y)
  at(C.seeHead, LEFT, y)
  C.seeHead:Show()
  local badge = CC.Item(st.badge or 0)
  local k = (st.badge or 0) - CC.PROJECT_BADGE_BASE
  local icon = badge and badge.icon or (CC.PROJECTS[k] and CC.PROJECTS[k].badge)
  C.seeBadge:SetShown(icon ~= nil)
  if icon then C.seeBadge:SetTexture(icon) end
  at(C.seeBadge, LEFT, y + 18)
  local _, class = M.Compat.call("UnitClass", "player")
  M.Kit.ClassIcon(C.seeClass, class)
  at(C.seeClass, LEFT + 18, y + 18)
  local title, colour = CC.Item(st.title or 0), CC.Item(st.colour or 0)
  local text = ns.Escape(M.Compat.call("UnitName", "player") or "") .. (title and title.kind == "title" and (", " .. title.name) or "")
  if colour and colour.hex then text = "|cff" .. colour.hex .. text .. "|r" else ns.UI.classColour(C.see, class) end
  at(C.see, LEFT + 38, y + 19)
  C.see:SetWidth(LW - 38)
  C.see:SetText(text .. " |cff999999(you)|r")
  C.see:Show()
  showMsg(C.storeMsg, "store")
  at(C.storeMsg, LEFT, y + 40)
  C.storeMsg:SetWidth(LW)
end

-- ---------- the Officers group (mock of-1, of-4) ----------

-- GamesPlayers sorted: hidden first, then by name.
local function players()
  local list = {}
  for _, p in ipairs(ns.GamesPlayers and ns.GamesPlayers() or {}) do
    if type(p) == "table" and p.key then list[#list + 1] = p end
  end
  table.sort(list, function(a, b)
    if (a.hidden and true or false) ~= (b.hidden and true or false) then return a.hidden and true or false end
    return tostring(a.name or a.key) < tostring(b.name or b.key)
  end)
  return list
end

local function hideRow(r)
  r.icon:Hide(); r.name:Hide(); r.price:Hide(); r.word:Hide(); r.btn:Hide(); r.by:Hide(); r.hit:Hide()
  r.id, r.key = nil, nil
end

-- One page of players under rows0; returns the y under the last row.
local function drawOfficers(B, LW, rows0)
  local list, per = players(), B.small and PER_SMALL or PER_BIG
  local pages = math.max(1, B.small and math.ceil(#list / PER_SMALL) or math.ceil(#list / PER_BIG))
  C.page = math.min(math.max(1, C.page), pages)
  local me, btnX, y = ns.MyKey(), LW - BTN_W, rows0
  for i, r in ipairs(C.rows) do
    local p = i <= per and list[(C.page - 1) * per + i]
    if p then
      at(r.btn, LEFT + btnX, y + 4)
      M.Kit.ClassIcon(r.icon, p.class)
      r.icon:Show()
      at(r.icon, LEFT, y + 3)
      at(r.name, LEFT + 22, y + 1)
      r.name:SetWidth(btnX - 28)
      r.name0 = ns.Escape(p.name or "?")
      r.name:SetText(r.name0)
      ns.UI.classColour(r.name, p.class)
      r.name:Show()
      r.price:Hide(); r.word:Hide()
      r.by:SetShown(p.hidden and true or false)
      if p.hidden then
        at(r.by, LEFT + 22, y + 15)
        r.by:SetWidth(btnX - 28)
        r.by:SetText(RED .. "Hidden by " .. (p.byKey ~= nil and p.byKey == me and "you" or ns.Escape(p.byName or "an officer"))
          .. "|r")
      end
      at(r.hit, LEFT + 22, y + 1) -- the name and the Hidden by line, clear of the button (f7544)
      r.hit:SetSize(btnX - 26, p.hidden and 26 or 14)
      r.hit:Show()
      r.btn:SetText(p.hidden and "Unhide" or "Hide")
      r.btn.act = p.hidden and "unhide" or "hide"
      r.btn:Show()
      r.id, r.key = nil, p.key
      y = y + PITCH
    else
      hideRow(r)
    end
  end
  return y, pages
end

local function drawOfficersFoot(B, LW, y, pages)
  local PW = 150
  local helpW = B.small and (LW - PW - 6) or LW
  local msg = C.msg and C.msg.where == "officers" -- a refusal takes the help line's place
  at(C.help, LEFT, y + 4)
  C.help:SetWidth(helpW)
  C.help:SetShown(not msg)
  local py = B.small and (y + 2) or (y + 34)
  at(C.prev, LEFT + LW - PW, py)
  at(C.next, LEFT + LW - 24, py)
  at(C.pageText, LEFT + LW - PW + 30, py + 4)
  C.pageText:SetText((B.small and "" or "Page ") .. C.page .. " of " .. pages)
  C.prev:SetEnabled(C.page > 1)
  C.next:SetEnabled(C.page < pages)
  C.prev:Show(); C.next:Show(); C.pageText:Show()
  showMsg(C.storeMsg, "officers")
  at(C.storeMsg, LEFT, y + 4)
  C.storeMsg:SetWidth(helpW)
end

local function drawStore(B, LW, H, off)
  local CC, st = ns.CompanyCore, ns.CompanyState()
  local top = B.top
  local officers = C.group == "officers"
  at(C.storeHead, LEFT, top)
  C.storeHead:SetWidth(LW)
  C.storeHead.label:SetText(officers and "Officers" or "Store")
  C.storeExtra:SetText(officers and "hide and unhide" or "cosmetic only")
  local n = off and 5 or 4
  local bw = off and math.floor((LW - 24) / 5) or math.floor((LW - 18) / 4)
  -- at the small size each button fits its small label + 14 (f7548); a label with no measure keeps them all even
  local ws, fit = {}, B.small
  for i, g in ipairs(C.groups) do
    g:SetNormalFontObject(B.small and "GameFontNormalSmall" or "GameFontNormal")
    g:SetHighlightFontObject(B.small and "GameFontHighlightSmall" or "GameFontHighlight")
    if fit and i <= n then
      local w = textWidth(g.GetFontString and g:GetFontString() or g.Text)
      if w then ws[i] = math.ceil(w) + 14 else fit = false end
    end
  end
  local x = LEFT
  for i, g in ipairs(C.groups) do
    local w = fit and ws[i] or bw
    g:SetShown(i <= n)
    g:SetWidth(w)
    at(g, x, top + 32)
    if GROUPS[i].key == C.group then
      at(C.mark, x, top + 55)
      C.mark:SetWidth(w)
    end
    x = x + w + 6
  end
  local rows0 = top + 60
  for _, f in ipairs({ C.help, C.prev, C.next, C.pageText }) do f:Hide() end
  if officers then
    for _, f in ipairs({ C.seeHead, C.seeBadge, C.seeClass, C.see }) do f:Hide() end
    drawOfficersFoot(B, LW, drawOfficers(B, LW, rows0))
  else
    local list = storeRows(CC, st)
    for i, r in ipairs(C.rows) do
      local e = list[i]
      if e then drawRow(r, e, st, B, LW, rows0 + (i - 1) * B.rh) else hideRow(r) end
    end
    drawPreview(CC, st, LW, rows0 + #list * B.rh + 6)
  end
  local p = ns.Purse and ns.Purse()
  local purse = p ~= nil and not (officers and B.small)
  C.purseIcon:SetShown(purse)
  C.purse:SetShown(purse)
  at(C.purseIcon, LEFT, H - 26)
  at(C.purse, LEFT + 22, H - 24)
  C.purse:SetText(fmt(p or 0) .. " grain")
end

-- ---------- the granary (V3) ----------

local function drawGranary(B)
  local CC, st = ns.CompanyCore, ns.CompanyState()
  local pr = ns.CompanyProjects()
  local k = pr.current
  local all = k == nil
  if all then k = #CC.PROJECTS end
  local p = CC.PROJECTS[k]
  local goal, total = (pr.goals and pr.goals[k]) or p.goal, (pr.totals and pr.totals[k]) or 0
  C.projIcon:SetTexture(p.badge)
  C.projText:SetWidth(B.rw - 22)
  -- with the project before built, the two lines read as mock co-2: "Rebuilt! ..." and "Next: <name>."
  local prev = not all and k > 1 and pr.done and pr.done[k - 1] == true and CC.PROJECTS[k - 1]
  C.projText:SetText(prev and ("Rebuilt! Donors get the " .. prev.badgeName .. " badge.")
    or (p.name .. " (" .. k .. " of " .. #CC.PROJECTS .. ")"))
  C.bar:SetWidth(B.rw)
  C.grow:SetMinMaxValues(0, goal)
  C.grow:SetValue(math.min(total, goal))
  C.barText:SetText(fmt(total) .. " / " .. fmt(goal) .. " grain")
  C.gave:SetWidth(B.rw - 80)
  C.gave:SetText("You gave " .. fmt(st.gifts and st.gifts[k] or 0) .. " to this project.")
  local donors = ns.CompanyDonors and ns.CompanyDonors(k) or {}
  C.donors:SetText(#donors .. (#donors == 1 and " donor" or " donors"))
  C.reward:SetWidth(B.rw)
  C.reward:SetText(prev and ("Next: " .. p.name .. ".") or ("Donors get the " .. p.badgeName .. " badge."))
  local built = {}
  for j = 1, #CC.PROJECTS do
    if pr.done and pr.done[j] == true then built[#built + 1] = CC.PROJECTS[j].name end
  end
  C.built:SetWidth(B.rw)
  C.built:SetText("Built: " .. (#built > 0 and table.concat(built, ", ") or "none yet"))
  C.reward:SetShown(not all)
  C.built:SetShown(not all and not B.small) -- of-4: no Built line at the minimum
  C.gave:SetShown(not all)
  C.donors:SetShown(not all)
  C.done:SetShown(all)
  C.done:SetWidth(B.rw)
  local bw = math.floor((B.rw - 12) / 3)
  for _, b in ipairs(C.give) do b:SetWidth(bw); b:SetShown(not all) end
  showMsg(C.granaryMsg, "granary")
  C.granaryMsg:SetWidth(B.rw)
end

-- ---------- the lottery (V4) ----------

local function num(n) return string.format("#%05d", n or 0) end

-- The own win: the draw's key is this week's or last week's own tickets key (never MyKey).
local function ownWin(d, st)
  local t = st.tickets
  return d.key ~= nil and type(t) == "table" and (d.key == t.key or d.key == t.prevKey)
end

local function who(d, st)
  if ownWin(d, st) then return "you" end
  return d.name and ns.Escape(d.name) or "a guildmate"
end

local function untilText(s)
  local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
  return h > 0 and (h .. " h " .. m .. " min") or (m .. " min")
end

local function drawLottery(B)
  local st, L = ns.CompanyState(), ns.Lottery()
  local now = ns.Now()
  local block = { C.sched, C.status, C.pot, C.tickets, C.lotMsg, C.wait, C.lastHead, C.last1, C.last2, C.won, C.cost }
  for _, f in ipairs(block) do f:SetWidth(B.rw) end
  if not L then -- no server clock yet (review f4)
    C.lotHead.label:SetText("Lottery")
    C.lotExtra:SetText("")
    for _, f in ipairs(block) do f:Hide() end
    C.buy:Hide()
    C.status:SetText("No server clock yet.")
    C.status:Show()
    return
  end
  C.pot:Show()
  C.tickets:Show()
  C.buy:Show()
  local utc = L.utc and " UTC" or ""
  C.lotHead.label:SetText((type(L.week) == "number" and L.week >= 1) and ("Lottery, week " .. L.week) or "Lottery")
  C.lotExtra:SetText("draw Sun 20:00" .. utc)
  C.sched:SetText(L.utc and "Draw Sunday 20:00 UTC, sales close 19:00 UTC."
    or "Draw Sunday 20:00 realm time, sales close 19:00.")
  C.sched:SetShown(not B.small)
  local open = L.open and type(L.closeAt) == "number" and now < L.closeAt
  if open then
    C.status:SetText("Sales close in " .. untilText(L.closeAt - now))
  else
    C.status:SetText("Sales closed. The draw is at 20:00.")
  end
  C.status:SetShown(open or not (type(L.drawAt) == "number" and now >= L.drawAt))
  C.pot:SetText("Pot: " .. fmt(L.pot) .. " grain from " .. fmt(L.total) .. (L.total == 1 and " ticket" or " tickets"))
  local mine = {}
  for i, n in ipairs(L.mine or {}) do mine[i] = num(n) end
  C.tickets:SetText("Your tickets (" .. #mine .. " of " .. ns.CompanyCore.TICKETS_MAX .. ")"
    .. (#mine > 0 and (": " .. table.concat(mine, " ")) or ""))
  C.buy:SetEnabled(open and true or false)
  showMsg(C.lotMsg, "lottery")
  -- the waiting line and the officer's last draw (of-1 to of-4; the S13 provisional and latched lines are gone)
  local waiting = L.waiting and type(L.waitWeek) == "number"
  C.wait:SetShown(waiting and true or false)
  if waiting then
    C.wait:SetText((L.waitWeek >= 1 and ("The week " .. L.waitWeek .. " draw") or "The last draw")
      .. " waits for an officer: " .. fmt(L.waitTotal) .. " tickets here.")
  end
  local d = type(L.draw) == "table" and L.draw or nil
  local sold = d ~= nil and (d.total or 0) > 0
  local paid = L.paid
  local paidWin = sold and ownWin(d, st) and type(paid) == "table" and paid.week == d.week
  local won = paidWin and not B.small
  local by = ns.Escape(d and d.byName or "an officer")
  C.lastHead:SetShown(sold and not B.small)
  C.last1:SetShown(d ~= nil and not won)
  C.last2:SetShown(sold)
  C.won:SetShown(won)
  C.cost:Show()
  if d and not sold then
    C.last1:SetText("No tickets were sold last week.")
  elseif sold and B.small then
    -- an own paid win says so and is in the won line's green (d1641, d1642); the code goes with the text, so no
    -- colour lingers
    C.last1:SetText(paidWin and (GREEN .. "You won " .. fmt(d.pot) .. " grain, paid out.|r")
      or ("Last draw: " .. who(d, st) .. " won " .. fmt(d.pot) .. " grain."))
    C.last2:SetText(num(d.number) .. " · drawn by " .. by .. ".")
  elseif sold then
    C.lastHead:SetText((type(d.week) == "number" and d.week >= 1) and ("Last draw, week " .. d.week) or "Last draw")
    C.last1:SetText(who(d, st) .. " won " .. fmt(d.pot) .. " grain with " .. num(d.number) .. ".")
    C.won:SetText("You won " .. fmt(d.pot) .. " grain with " .. num(d.number) .. ". It is in your purse.")
    C.last2:SetText("Target " .. num(d.target) .. " · drawn by " .. by .. " from " .. fmt(d.total) .. " tickets.")
  end
end

function C.Draw()
  local W, H = size()
  local B = H < SMALL_BELOW and SMALL or BIG
  local LW = W - LEFT - GAP - B.rw - LEFT
  local x0 = W - LEFT - B.rw
  -- officers (and everyone in demo) see the Officers group; read on each draw, never cached
  local off = M.Demo() or (ns.IsOfficer and ns.IsOfficer(ns.MyKey())) or false
  if C.group == "officers" and not off then C.group, C.msg = "title", nil end
  C.title:SetShown(not B.small)
  C.sub:SetShown(not B.small)
  C.sub:SetWidth(W - 110)
  drawStore(B, LW, H, off)
  C.granaryHead:SetWidth(B.rw)
  C.lotHead:SetWidth(B.rw)
  drawGranary(B)
  drawLottery(B)
  local g = B.small and 4 or 6
  chain({ { C.granaryHead, 0, 0 }, { C.projText, 22, g }, { C.reward, 0, 2 }, { C.bar, 0, g },
    { C.gave, 0, g }, { C.built, 0, 4 }, { C.done, 0, g },
    { C.give[1], 0, g }, { C.granaryMsg, 0, g }, { C.lotHead, 0, B.small and 4 or 10 }, { C.sched, 0, 6 },
    { C.status, 0, 4 }, { C.pot, 0, 4 }, { C.tickets, 0, 4 }, { C.buy, 0, g }, { C.lotMsg, 0, g }, { C.wait, 0, g },
    { C.lastHead, 0, g }, { C.last1, 0, 4 }, { C.won, 0, 4 }, { C.last2, 0, 4 }, { C.cost, 0, g } }, x0, B.top)
end

-- ---------- actions ----------

local function act(where, fn, ...)
  C.msg = nil
  local good, why, name = fn(...)
  if not good and why == "other" then
    C.msg = { where = where, text = "This week's tickets are on " .. ns.Escape(name or "another character") .. "." }
  elseif not good and REFUSAL[why] then
    C.msg = { where = where, text = REFUSAL[why] }
  end
  C.Draw()
end

local function rowClick(r)
  if r.key then
    local key, hide, name = r.key, r.btn.act == "hide", r.name0
    return act("officers", function() -- a success names the character in green (f7542)
      local good, why, other = ns.SetHidden(key, hide)
      if good then C.msg = { where = "officers", text = name .. (hide and " hidden." or " shown again."), ok = true } end
      return good, why, other
    end)
  end
  if not r.id then return end
  local kind = C.group
  if r.btn.act == "buy" then act("store", ns.BuyItem, r.id)
  elseif r.btn.act == "wear" then act("store", ns.Wear, kind, r.id)
  else act("store", ns.Wear, kind, 0) end
end

-- ---------- build ----------

local function build(body)
  C.body = body
  C.title = label(body, "GameFontHighlightLarge")
  C.title:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -4)
  C.title:SetText("Company")
  C.sub = label(body)
  grey(C.sub)
  C.sub:SetWordWrap(false)
  C.sub:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT + 100, -8)
  C.sub:SetText("Spend grain on looks, the guild granary and the weekly lottery.")
  -- the store
  C.storeHead = header(body, "Store")
  C.storeExtra = headerExtra(C.storeHead)
  C.storeExtra:SetText("cosmetic only")
  for i, g in ipairs(GROUPS) do
    local b = button(body, g.text, 70)
    b:SetScript("OnClick", function() M.Safe(function() C.group, C.msg, C.page = g.key, nil, 1; C.Draw() end) end)
    C.groups[i] = b
  end
  C.mark = body:CreateTexture(nil, "ARTWORK") -- the chosen group's gold rule (co-1)
  C.mark:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)
  C.mark:SetHeight(2)
  for i = 1, ROWS do
    local r = { icon = body:CreateTexture(nil, "ARTWORK"), name = label(body, "GameFontHighlight"),
      price = label(body, "GameFontHighlight"), word = label(body), by = label(body) }
    r.by:SetWordWrap(false)
    r.icon:SetSize(16, 16)
    r.name:SetWordWrap(false)
    r.price:SetJustifyH("RIGHT")
    r.word:SetJustifyH("RIGHT")
    r.btn = button(body, "Buy", BTN_W)
    r.btn:SetScript("OnClick", function() M.Safe(rowClick, r) end)
    r.hit = CreateFrame("Frame", nil, body) -- a cut name or Hidden by line in full on hover (f7544)
    r.hit:EnableMouse(true)
    r.hit:SetScript("OnEnter", function(self)
      M.Safe(function()
        local by = r.by:IsShown()
        if cut(r.name) or (by and cut(r.by)) then showTip(self, r.name:GetText(), by and r.by:GetText() or nil) end
      end)
    end)
    r.hit:SetScript("OnLeave", function() M.Safe(hideTip) end)
    C.rows[i] = r
  end
  C.seeHead = label(body)
  grey(C.seeHead)
  C.seeHead:SetText("How guildmates see you:")
  C.seeBadge = body:CreateTexture(nil, "ARTWORK")
  C.seeBadge:SetSize(16, 16)
  C.seeClass = body:CreateTexture(nil, "ARTWORK")
  C.seeClass:SetSize(16, 16)
  C.see = label(body, "GameFontHighlight")
  C.see:SetWordWrap(false)
  C.storeMsg = label(body)
  C.help = label(body)
  grey(C.help)
  C.help:SetText("A hidden player counts on no board, granary or draw.")
  C.pageText = label(body, "GameFontHighlight")
  C.pageText:SetWidth(90)
  C.pageText:SetJustifyH("CENTER")
  C.prev = button(body, "<", 24)
  C.prev:SetScript("OnClick", function() M.Safe(function() C.page = C.page - 1; C.Draw() end) end)
  C.next = button(body, ">", 24)
  C.next:SetScript("OnClick", function() M.Safe(function() C.page = C.page + 1; C.Draw() end) end)
  for b, text in pairs({ [C.prev] = "Previous page", [C.next] = "Next page" }) do -- they disable on the first / last page
    if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
    b:SetScript("OnEnter", function(self) M.Safe(showTip, self, text) end)
    b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  end
  C.purseIcon = body:CreateTexture(nil, "ARTWORK")
  C.purseIcon:SetSize(16, 16)
  C.purseIcon:SetTexture(WHEAT)
  C.purse = label(body, "GameFontHighlight")
  -- the granary
  C.granaryHead = header(body, "Granary goal")
  C.projText = label(body, "GameFontNormal")
  C.projIcon = body:CreateTexture(nil, "ARTWORK")
  C.projIcon:SetSize(16, 16)
  C.projIcon:SetPoint("TOPRIGHT", C.projText, "TOPLEFT", -6, 1)
  C.bar = M.Kit.StatBar(body) or CreateFrame("Frame", nil, body) -- Harvest.lua's bar shape
  C.bar:SetSize(BIG.rw, 20)
  local fill = type(C.bar.fill) == "table" and C.bar.fill or C.bar
  C.grow = CreateFrame("StatusBar", nil, fill)
  C.grow:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
  C.grow:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
  C.grow:SetStatusBarTexture(BAR_TEXTURE)
  C.grow:SetStatusBarColor(GOLD[1], GOLD[2], GOLD[3])
  C.grow:SetFrameLevel(fill:GetFrameLevel() + 1)
  local top = CreateFrame("Frame", nil, C.grow)
  top:SetAllPoints(C.bar)
  top:SetFrameLevel(C.grow:GetFrameLevel() + 1)
  C.barText = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  C.barText:SetPoint("CENTER", C.bar, "CENTER", 0, 0)
  C.gave = label(body)
  C.gave:SetWordWrap(false)
  C.donors = label(body)
  C.donors:SetJustifyH("RIGHT")
  C.donors:SetPoint("TOPRIGHT", C.bar, "BOTTOMRIGHT", 0, -6)
  C.reward = label(body)
  grey(C.reward)
  C.built = label(body)
  C.done = label(body, "GameFontHighlight")
  C.done:SetText("All six projects are built. Thank you, Company.")
  for i, n in ipairs(ns.CompanyCore.GIVES) do
    local b = button(body, "Give " .. fmt(n), 100)
    b:SetScript("OnClick", function() M.Safe(act, "granary", ns.Donate, n) end)
    if i > 1 then b:SetPoint("TOPLEFT", C.give[i - 1], "TOPRIGHT", 6, 0) end
    C.give[i] = b
  end
  C.granaryMsg = label(body)
  -- the lottery
  C.lotHead = header(body, "Lottery")
  C.lotExtra = headerExtra(C.lotHead)
  C.sched = label(body)
  grey(C.sched)
  C.status = label(body, "GameFontHighlight")
  C.pot = label(body, "GameFontHighlight")
  C.tickets = label(body, "GameFontHighlight")
  C.buy = button(body, "Buy a ticket (" .. ns.CompanyCore.TICKET_PRICE .. " grain)", 170)
  C.buy:SetScript("OnClick", function() M.Safe(act, "lottery", ns.BuyTicket) end)
  C.lotMsg = label(body)
  C.wait = label(body, "GameFontHighlight")
  C.wait:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  C.lastHead = label(body, "GameFontNormal")
  C.last1 = label(body, "GameFontHighlight")
  C.last2 = label(body)
  C.won = label(body, "GameFontHighlight")
  C.won:SetTextColor(0.12, 1, 0)
  grey(C.last2)
  C.cost = label(body)
  grey(C.cost)
  C.cost:SetText("A hide or a draw reaches you once you have been online with an officer who carries it.")
  body:HookScript("OnSizeChanged", function() if ns.ShownGame and ns.ShownGame() == "company" then M.Safe(C.Draw) end end)
end

ns.CompanyTab = {
  Build = build,
  -- Nothing is drawn unless the Company tab is on screen (RefreshPage calls this while hidden too).
  Refresh = function()
    if C.body and ns.ShownGame and ns.ShownGame() == "company" then C.Draw() end
  end,
}
