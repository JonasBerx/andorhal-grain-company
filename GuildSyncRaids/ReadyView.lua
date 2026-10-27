local _, ns = ...
if not ns.M then return end

-- The Ready tab's body (S9 L2, Raids 0.5 Ready), drawn by ns.DrawReady(card, ev, layout, top, events) from
-- ns.ReadyState() (or the demo state): the raid leader's table of who is missing what (mock s4r2-1) and a raider's own
-- read with Check my buffs (mock s4r2-2). The leader view shows for the role recorded at the check or a live leader or
-- assistant (d1244); Ask again and Missing to raid chat follow the live answer only, checked again at click. This file
-- sends nothing and says nothing in chat: Missing to raid chat only fills the chat box (ns.OpenChat). Every name goes
-- through ns.Escape; colours are set with SetTextColor, never as an inline code. The pane is built on the first draw,
-- on card.body.

local M = ns.M
local call = M.Compat.call
local Plain = GuildSync.Compat.Plain
local ID = "raids_r"
local SB, ROW_H = 22, 14 -- the scrollbar's room on the right; one table row
local GREEN = { 0.1, 1, 0.1 }
local CATS = ns.ReadyRules.CATS
local LABEL = { flask = "Flask", elixir = "Elixirs", food = "Food", world = "World buffs" }
local HEADS = { "Name", "Flask", "Elixirs", "Food", "World", "Fire res" }
local COLW = { 44, 50, 40, 44, 50 } -- Flask, Elixirs, Food, World, Fire res; the name column takes the rest
local NO_ANSWER = "no answer (no Raids 0.5, or offline)"
local ROLE_WHY = "Only the raid leader or an assistant can do this."
local NOBODY_WHY = "Nobody is missing anything."
local HOLD_WHY = "You asked a moment ago: wait a few seconds."
local HOVER = "Hover a cell for the buff names."
local NOTE = "Sent only at your raid leader's ready check, out of combat, over the guild channel. Nothing shows in chat; it reads your own buffs, no one else's."
local CHECK_SIDE = "Reads your own buffs again; sends nothing."
local DEMO_LINE = "demo: nothing happens here (demo data)"
local HIDES = { combat = "combat", secret = "the game hides your buffs here" }

local lastAsk -- when Ask again last asked, this session only (f17)

local function esc(s) return ns.Escape(tostring(s or "")) end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end
local function now() return tonumber(Plain(call("GetServerTime"))) or 0 end
local function demo() return ns.DemoData and ns.DemoData() or nil end

local function at(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", x, y)
end

-- GameTooltip and RAID_CLASS_COLORS are FrameXML (not in the API dataset): read guarded, as RaidView and Signups do.
local function tooltip() return type(GameTooltip) == "table" and GameTooltip or nil end

local function hideTip()
  local tip = tooltip()
  if tip then tip:Hide() end
end

local function classColor(fs, name)
  local r = ns.Member(name)
  local all = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS or nil
  local cc = all and r and r.class and all[r.class]
  if type(cc) == "table" and cc.r then fs:SetTextColor(cc.r, cc.g, cc.b) else color(fs, ns.WHITE) end
end

-- In a raid and the raid leader or an assistant now (a plain true).
local function live()
  if call("UnitInRaid", "player") == nil then return false end
  return call("UnitIsGroupLeader", "player") == true or call("UnitIsGroupAssistant", "player") == true
end

-- The state the tab draws: the demo state while demo is on, else the module's.
local function current()
  local d = demo()
  if d then return type(d.ready) == "table" and d.ready or {}, true end
  return ns.ReadyState(), false
end

local function chatText()
  local st = current()
  return ns.ReadyRules.ChatLine(ns.ReadyRules.Missing(st.rows or {}, ns.ReadyOptions()))
end

local function askWhy()
  if demo() then return nil end
  if not live() then return ROLE_WHY end
  if lastAsk and now() - lastAsk < ns.ReadyRules.ASKHOLD then return HOLD_WHY end
  return nil
end

local function chatWhy()
  if demo() then return nil end
  if not live() then return ROLE_WHY end
  if not chatText() then return NOBODY_WHY end
  return nil
end

local function redraw()
  local ui = ns.UI()
  if ui then ns.RefreshPage(ui.page) end
end

local function label(parent, font, c)
  local fs = ns.Label(parent, font or "GameFontHighlightSmall")
  if c then color(fs, c) end
  return fs
end

-- Places fs at (x, -y) with width w and text; answers y under it.
local function place(fs, x, y, w, text, c)
  at(fs, x, -y)
  fs:SetWidth(w)
  fs:SetText(text)
  if c then color(fs, c) end
  fs:Show()
  return y + (tonumber(fs:GetStringHeight()) or ROW_H)
end

local function button(parent, text, w, why, click)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:SetScript("OnEnter", function(self)
    M.Safe(function()
      local reason = why and why()
      local tip = reason and tooltip()
      if not tip then return end
      tip:SetOwner(self, "ANCHOR_RIGHT")
      tip:SetText(reason)
      tip:Show()
    end)
  end)
  b:SetScript("OnLeave", hideTip)
  b:SetScript("OnClick", function() M.Safe(click) end)
  return b
end

-- The buff names of a list of ids, ", " between them; "" for none.
local function names(ids)
  local out = {}
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    local row = ns.ReadyData[id]
    out[#out + 1] = esc(row and row.name or id)
  end
  return table.concat(out, ", ")
end

local function rowEnter(self)
  M.Safe(function()
    local tip, row = tooltip(), self.row
    if not (tip and row) then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:SetText(esc(row.name))
    if row.report then
      for _, cat in ipairs(CATS) do
        local list = names(row.report[cat])
        tip:AddLine(LABEL[cat] .. ": " .. (list ~= "" and list or "none"))
      end
    end
    tip:Show()
  end)
end

local function build(card)
  local V = { rows = {}, own = {} }
  card.readyView = V
  V.pane = CreateFrame("Frame", nil, card.body)
  V.result = label(V.pane, nil, ns.GREY)
  -- the leader's table
  V.lead = CreateFrame("Frame", nil, V.pane)
  V.lead:SetAllPoints(V.pane)
  V.head = label(V.lead, nil, ns.GREY)
  V.leadGate = label(V.lead, nil, ns.ORANGE)
  V.hidden = label(V.lead, nil, ns.GREY)
  V.heads = {}
  for i, h in ipairs(HEADS) do
    V.heads[i] = label(V.lead, "GameFontNormalSmall")
    V.heads[i]:SetText(h)
    V.heads[i]:SetWordWrap(false)
  end
  V.rule = V.lead:CreateTexture(nil, "ARTWORK")
  V.rule:SetColorTexture(1, 0.82, 0, 0.3)
  V.scroll, V.child = ns.ScrollArea(V.lead)
  V.hover = label(V.lead, nil, ns.GREY)
  V.summary = label(V.lead, nil, ns.WHITE)
  V.chat = button(V.lead, "Missing to raid chat", 160, chatWhy, function()
    if demo() then V.barText = DEMO_LINE return redraw() end
    if chatWhy() then return end
    local text = chatText()
    if ns.OpenChat(text) then V.barText = nil
    else V.barText = "copy this into raid chat: " .. (string.gsub(text, "^/raid ", "")) end
    redraw()
  end)
  V.ask = button(V.lead, "Ask again", 90, askWhy, function()
    if demo() then V.barText = DEMO_LINE return redraw() end
    if askWhy() then return end
    local why = ns.ReadyAsk()
    if why == nil then lastAsk = now() end
    V.barText = why and ("Not asked: " .. tostring(why) .. ".") or nil
    redraw()
  end)
  -- the raider's own read
  V.mine = CreateFrame("Frame", nil, V.pane)
  V.mine:SetAllPoints(V.pane)
  V.ownHead = label(V.mine, nil, ns.GREY)
  V.ownGate = label(V.mine, nil, ns.ORANGE)
  V.cannot = label(V.mine, nil, ns.ORANGE)
  for i = 1, 5 do V.own[i] = { lab = label(V.mine, "GameFontNormalSmall"), val = label(V.mine) } end
  V.note = label(V.mine, nil, ns.GREY)
  V.check = button(V.mine, "Check my buffs", 130, nil, function()
    if demo() then V.barText = DEMO_LINE return redraw() end
    ns.ReadyCheckMine()
    redraw()
  end)
  V.side = label(V.mine, nil, ns.GREY)
  return V
end

-- The i-th table row (made on first use): a frame in the scroll child, its hover, and six cells.
local function tableRow(V, i)
  local r = V.rows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, V.child)
  r:EnableMouse(true)
  r:SetScript("OnEnter", rowEnter)
  r:SetScript("OnLeave", hideTip)
  r.cells = {}
  for k = 1, 6 do
    r.cells[k] = label(r)
    r.cells[k]:SetWordWrap(false)
  end
  V.rows[i] = r
  return r
end

-- The header's "Your", "<Leader>'s", or "The" with no recorded leader (f6706).
local function whose(st)
  local me = ns.MyKey()
  local name = st.leaderName or (type(st.leader) == "table" and st.leader.name) or nil
  if me and (st.checkLeader == me or (name and ns.Key(name) == me)) then return "Your" end
  if not name then return "The" end
  return esc(name) .. "'s"
end

local function gateLine()
  if call("UnitInRaid", "player") == nil or type(M.Comm.Gate) ~= "function" then return nil end
  local open, why = M.Comm.Gate(ID)
  if open ~= false then return nil end
  return "The game holds addon messages here (" .. esc(why or "?") .. "): no report is sent."
end

local function cell(fs, x, w, text, c)
  at(fs, x, -1)
  fs:SetWidth(w)
  fs:SetText(text)
  color(fs, c)
  fs:Show()
end

local function drawRows(V, st, rows, opts, mark, cw)
  local xs, x = {}, cw
  for i = #COLW, 1, -1 do x = x - COLW[i]; xs[i + 1] = x end
  xs[1] = 4
  for i, row in ipairs(rows) do
    local r = tableRow(V, i)
    at(r, 0, -((i - 1) * ROW_H))
    r:SetSize(cw, ROW_H)
    r.row = row
    r:Show()
    for _, fs in ipairs(r.cells) do fs:Hide() end
    cell(r.cells[1], xs[1], xs[2] - xs[1] - 4, esc(row.name), ns.WHITE)
    classColor(r.cells[1], row.name)
    local rep = row.report
    if row.cannot then
      cell(r.cells[2], xs[2], cw - xs[2], "cannot read" .. (st.why and (" (" .. esc(st.why) .. ")") or ""), ns.GREY)
    elseif not rep then
      cell(r.cells[2], xs[2], cw - xs[2], NO_ANSWER, ns.GREY)
    else
      local function n(cat) return #(type(rep[cat]) == "table" and rep[cat] or {}) end
      -- white when the row has it, orange when it lacks a counted category
      local function tint(cat) return (n(cat) == 0 and opts[cat]) and ns.ORANGE or ns.WHITE end
      cell(r.cells[2], xs[2], COLW[1], n("flask") > 0 and "yes" or "no", tint("flask"))
      cell(r.cells[3], xs[3], COLW[2], n("elixir") > 0 and tostring(n("elixir")) or "no", tint("elixir"))
      cell(r.cells[4], xs[4], COLW[3], n("food") > 0 and "yes" or "no", tint("food"))
      cell(r.cells[5], xs[5], COLW[4], tostring(n("world")), tint("world"))
      local fire = tonumber(rep.fire) or 0
      cell(r.cells[6], xs[6], COLW[5], tostring(fire), (mark > 0 and fire >= mark) and GREEN or ns.GREY)
    end
  end
  for i = #rows + 1, #V.rows do V.rows[i]:Hide() end
  return xs
end

local function drawLeader(V, st, isDemo, IW, barRel)
  local rows = st.rows or {}
  local opts = ns.ReadyOptions()
  local mark = (isDemo and tonumber(st.mark)) or opts.fire
  local y = 2
  local heard = tonumber(st.heard) or 0
  local hidden = not isDemo and type(st.roster) ~= "table"
  local text
  if not st.checkAt then
    text = "No ready check yet. Start one from the raid frame; the answers show here."
  else
    text = whose(st) .. " ready check at " .. ns.When("%H:%M", st.checkAt) .. " ("
      .. math.max(0, math.floor((now() - st.checkAt) / 60)) .. " min ago)"
    if hidden then
      text = text .. "."
    else
      local n, m = ns.ReadyRules.Answered(rows)
      -- names Ready.lua dropped for not being on the roster (24.name-key)
      local drop = st.dropped and tonumber(st.dropped.roster) or 0
      text = text .. ": " .. n .. " of " .. m .. " answered (" .. heard .. " heard"
        .. (drop > 0 and (", " .. drop .. " not on the roster") or "") .. ")."
    end
  end
  y = place(V.head, 4, y, IW - 8, text) + 4
  V.leadGate:Hide()
  local gate = not isDemo and gateLine()
  if gate then y = place(V.leadGate, 4, y, IW - 8, gate) + 4 end
  V.hidden:Hide()
  -- the bar: the buttons at barRel + 2, the summary over them, the result or the hover note over that
  at(V.chat, 0, -(barRel + 2), "TOPRIGHT")
  V.ask:ClearAllPoints()
  V.ask:SetPoint("TOPRIGHT", V.chat, "TOPLEFT", -6, 0)
  V.ask:SetEnabled(askWhy() == nil)
  V.chat:SetEnabled(chatWhy() == nil)
  local table_ = st.checkAt and not hidden
  for _, h in ipairs(V.heads) do h:SetShown(table_) end
  V.rule:SetShown(table_)
  V.scroll:SetShown(table_)
  V.summary:Hide()
  V.hover:Hide()
  if not table_ then
    if st.checkAt then
      place(V.hidden, 4, y, IW - 8, "The game hid the raid's names here: " .. heard
        .. (heard == 1 and " report heard from guild members." or " reports heard from guild members."))
    end
    if V.barText then place(V.hover, 4, y + 20, IW - 8, V.barText, ns.GREY) end
    return
  end
  local cw = IW - SB
  local missing = ns.ReadyRules.Missing(rows, opts)
  local summary = ns.ReadyRules.Summary(missing) or NOBODY_WHY
  local sumH = place(V.summary, 4, 0, IW - 8, summary)
  local sumY = barRel - 6 - sumH
  V.summary:ClearAllPoints()
  V.summary:SetPoint("TOPLEFT", 4, -sumY)
  local xs = drawRows(V, st, rows, opts, mark, cw)
  for i, h in ipairs(V.heads) do
    at(h, xs[i], -y)
    h:SetWidth(i == 1 and (xs[2] - xs[1] - 4) or COLW[i - 1])
  end
  y = y + ROW_H + 2
  at(V.rule, 2, -y)
  V.rule:SetSize(IW - 4, 1)
  y = y + 3
  -- the note line: the result of the last click, else how many rows are below the fold and the hover hint
  local noteH = place(V.hover, 4, 0, IW - 8, V.barText or HOVER, ns.GREY)
  local noteY = sumY - 2 - noteH
  local h = math.max(ROW_H, noteY - 2 - y)
  local more = #rows - math.floor(h / ROW_H)
  if not V.barText and more > 0 then
    noteH = place(V.hover, 4, 0, IW - 8, "+" .. more .. " more (scroll). " .. HOVER)
    noteY = sumY - 2 - noteH
    h = math.max(ROW_H, noteY - 2 - y)
  end
  V.hover:ClearAllPoints()
  V.hover:SetPoint("TOPLEFT", 4, -noteY)
  V.scroll:ClearAllPoints()
  V.scroll:SetPoint("TOPLEFT", V.lead, "TOPLEFT", 0, -y)
  V.scroll:SetSize(cw, h)
  V.child:SetWidth(cw)
  V.child:SetHeight(math.max(10, #rows * ROW_H))
end

local function drawRaider(V, st, isDemo, IW)
  local own, y = st.own, 2
  local text
  local when = ns.When("%H:%M", st.ownAt or st.checkAt or 0)
  if st.ownBy == "check" then
    text = own and ("Check my buffs at " .. when .. " read this (not sent):") or ("Check my buffs at " .. when .. ":")
  elseif st.checkAt then
    text = whose(st) .. " ready check at " .. ns.When("%H:%M", st.checkAt) .. ". "
      .. (not own and "Your client could not read your buffs:"
        or (st.sentWhy and ("Your client read this (not sent: " .. esc(st.sentWhy) .. "):"))
        or "Your client answered with this:")
  else
    text = "No ready check yet. Check my buffs shows what your client would answer."
  end
  y = place(V.ownHead, 4, y, IW - 8, text) + 6
  V.ownGate:Hide()
  local gate = not isDemo and gateLine()
  if gate then y = place(V.ownGate, 4, y, IW - 8, gate) + 6 end
  V.cannot:Hide()
  for _, l in ipairs(V.own) do l.lab:Hide() l.val:Hide() end
  if own then
    local opts = ns.ReadyOptions()
    for i, cat in ipairs(CATS) do
      local l, list = V.own[i], names(own[cat])
      place(l.lab, 4, y, 100, LABEL[cat])
      y = math.max(y + ROW_H, place(l.val, 110, y, IW - 114, list ~= "" and list or "none",
        (list == "" and opts[cat]) and ns.ORANGE or ns.WHITE)) + 4
    end
    place(V.own[5].lab, 4, y, 100, "Fire resistance")
    y = place(V.own[5].val, 110, y, IW - 114, tostring(tonumber(own.fire) or 0), ns.WHITE) + 6
  elseif st.why then
    y = place(V.cannot, 4, y, IW - 8, "Cannot read now (" .. esc(HIDES[st.why] or st.why) .. ").") + 6
  end
  y = place(V.note, 4, y, IW - 8, NOTE) + 6
  at(V.check, 4, -y)
  V.side:ClearAllPoints()
  V.side:SetPoint("LEFT", V.check, "RIGHT", 8, 0)
  V.side:SetWidth(IW - 146)
  V.side:SetText(CHECK_SIDE)
  V.result:Hide()
  if V.barText then place(V.result, 4, y + 28, IW - 8, V.barText, ns.GREY) end
end

-- ev nil hides the pane, its rows and its buttons (the Sign-ups and Pulls tabs, the empty state).
function ns.DrawReady(card, ev, layout, top, events)
  local V = rawget(card, "readyView") or build(card)
  if not ev then
    V.pane:Hide()
    return
  end
  local L = layout or ns.Layout()
  local IW = L.viewW - 24
  top = top or 0
  local barRel = L.cardH - 24 - 34 - top
  at(V.pane, 12, -top)
  V.pane:SetSize(IW, math.max(1, L.cardH - 4 - top))
  V.pane:Show()
  if V.key ~= ev.key then
    V.key, V.barText = ev.key, nil
    V.scroll:SetVerticalScroll(0)
  end
  local st, isDemo = current()
  local leader
  if isDemo then
    local me = ns.MyKey()
    leader = (me and ns.IsOfficer(me)) and true or false
  else
    leader = st.role == "leader" or live()
  end
  V.lead:SetShown(leader)
  V.mine:SetShown(not leader)
  V.result:Hide()
  if leader then drawLeader(V, st, isDemo, IW, barRel) else drawRaider(V, st, isDemo, IW) end
end
