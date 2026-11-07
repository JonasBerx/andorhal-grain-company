-- GuildSyncGames Who.lua (S22 Task 7): the Who said it tab, ns.WhoTab (mock ws-1 to ws-6, #f1 and #f2), Vendor.lua's
-- twin. Left: the title, the sub line, the Play card (the icon, Play or Replay, "Hint: <group>"), four speaker names
-- 2x2, the line and marks row, the status line, Next line, and at the foot Daily / Endless / Share. A finished daily
-- run shows the score, the grain earned and the ten speakers instead. Right: Today in the guild, Best endless streak
-- and Daily streak. All UI state lives in V.
-- No dialogue text anywhere (d1632): a line is only "Line N of 10", Play / Replay and names; no kit or file id is drawn.
-- The names are locked until ns.WhoPlay played the line on screen; Build and Refresh only read, never play.
-- ns.WhoToday, ns.WhoPick, ns.WhoMode, ns.WhoEndless, ns.WhoHeard, ns.WhoStats, ns.WhoGuild, ns.WhoBoard, ns.WhoPlay,
-- ns.WhoCore, ns.VOICES, ns.Purse, ns.OpenChat and ns.ShownGame are looked up at call time (f7165: Demo.lua wraps
-- them, tests replace them). The seams answer reason codes; only this file turns them into sentences (seam-check f2).

local _, ns = ...

if not ns.M then return end
local M, GC = ns.M, ns.GrainCore

local LEFT, GAP = 8, 12
local SMALL_BELOW = 420 -- below this height (the 760x480 window) the card, names, rows and lists shrink (ws-6)
local BIG = { rw = 240, ch = 130, icon = 56, nh = 36, rh = 22, today = 8, board = 4 }
local SMALL = { rw = 200, ch = 100, icon = 40, nh = 30, rh = 19, today = 3, board = 3 }
local RUN = 10
local LIST_ROW = 20
local NAME_GAP = 12 -- between the two name columns and under the card
local WHEAT = 134058 -- INV_Misc_Food_Wheat_01
local PLAY_ICON = 132333 -- Interface\Icons\Ability_Warrior_BattleShout (NOTES-ws.md Art)
local RIGHT_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4"
local WRONG_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5"
local GREEN, RED = "|cff1eff00", "|cffff4040"
local UNKNOWN = "The guild list is not known yet."
local PICK = "Whose voice was that? Pick a name." -- the instruction sits in the status line (mock #f2)
local HINT = "5 grain a right pick, 25 more for all ten."
-- One name per Voices.lua group id, in the sorted order Task 1 assigns; pinned UI copy, never in Voices.lua (gate A 4).
local GROUP_NAMES = { "Ahn'Qiraj", "Dungeons", "Faction leaders", "Molten Core, Blackwing Lair and Zul'Gurub",
  "Naxxramas" }
-- The seams' reason codes as the page says them (mock ws-5); a code not here shows nothing.
local WHY = {
  ["in combat"] = "The line plays once you are out of combat.",
  ["sound off"] = "Sound or Dialog is off in your game settings: turn both on to play.",
  ["still playing"] = "The line is still playing.",
  ["no sound"] = "This game client cannot play the line.",
  heard = "Play the line first.",
  clock = "The day is not known yet.",
  done = "This run is over.",
  demo = "The demo plays no lines.",
  rolled = "A new day: today's lines are out.",
  started = "The day's run has started.", -- the Lucky charm's
  owned = "You have a charm on this game today.",
  short = "Not enough grain in the purse.",
}

local V = { names = {}, marks = {}, answers = {}, lists = {} }

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

-- A speaker's name by id, and the speaker of a line index (ns.VOICES.lines[i] = { kit, file, speaker, group }).
local function speaker(id)
  local s = ns.VOICES.speakers[id]
  return s and s.name or "?"
end
local function speakerOf(line) return ns.VOICES.lines[line][3] end

-- A text's drawn width: the client's measure, else about 7 px a character and 14 px an icon.
local function textWidth(fs, text)
  local w = fs.GetStringWidth and fs:GetStringWidth()
  if type(w) == "number" and w > 0 then return w end
  return 7 * #(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "  "))
end

-- ---------- placing ----------

local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", V.body, "TOPLEFT", x, -y)
end

local function size()
  local w, h = V.body:GetWidth(), V.body:GetHeight()
  if type(w) ~= "number" or w <= 0 then w = 726 end
  if type(h) ~= "number" or h <= 0 then h = 460 end
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

-- The Play card over the left column: Play, or Replay once the line was heard or answered, and the line's group.
local function drawCard(entry, heard, B, LW)
  local c = V.card
  c.f:SetSize(LW, B.ch)
  at(c.f, LEFT, 46)
  c.f:Show()
  c.icon:SetSize(B.icon, B.icon)
  c.text:ClearAllPoints()
  c.text:SetPoint("TOP", c.f, "TOP", 0, -(18 + B.icon))
  c.text:SetText(heard and "Replay" or "Play")
  local group = GROUP_NAMES[ns.VOICES.lines[entry.line][4]]
  c.hint:SetText(group and ("Hint: " .. group) or "")
  c.hint:SetShown(group ~= nil)
end

-- The four names 2x2 under the card. live: a pick is open (the line was played); last: the pick just made, then the
-- right name is green with its mark, a wrong pick red with its mark and the gold accent, the others grey.
local function drawNames(entry, live, last, B, LW)
  local bw = math.floor((LW - NAME_GAP) * 0.5)
  local y0 = 46 + B.ch + NAME_GAP
  local right = last and speakerOf(entry.line)
  for k, n in ipairs(V.names) do
    local id = entry.choices[k]
    n.id = id
    n.f:SetSize(bw, B.nh)
    at(n.f, LEFT + ((k - 1) % 2) * (bw + NAME_GAP), y0 + math.floor((k - 1) / 2) * (B.nh + 6))
    n.f:Show()
    n.f:SetEnabled(live)
    local mark = last and (id == right and RIGHT_ICON or (k == last.k and WRONG_ICON)) or nil
    -- A marked name leaves room for its mark on the left and may wrap inside the button (mock note 4), never cut.
    -- V-f3: a marked name's text sits right of the mark's room (centred 10 px right, bw - 30 wide, the mark at 6),
    -- in the small font when it does not fit there, so it keeps one line and never runs under the mark.
    local tw = mark and bw - 30 or bw - 12
    n.fs:SetFontObject("GameFontHighlight")
    n.fs:SetWidth(tw)
    n.fs:SetText(speaker(id))
    if mark and textWidth(n.fs, speaker(id)) > tw then n.fs:SetFontObject("GameFontHighlightSmall") end
    n.fs:ClearAllPoints()
    n.fs:SetPoint("CENTER", n.f, "CENTER", mark and 10 or 0, 0)
    if mark and id == right then
      n.fs:SetTextColor(0.12, 1, 0)
    elseif mark then
      n.fs:SetTextColor(1, 0.25, 0.25)
    elseif live then
      n.fs:SetTextColor(1, 1, 1)
    else
      grey(n.fs)
    end
    n.mark:SetShown(mark ~= nil)
    if mark then
      n.mark:SetTexture(mark)
      n.mark:ClearAllPoints()
      n.mark:SetPoint("LEFT", n.f, "LEFT", 6, 0)
    end
    n.accent:SetShown(last ~= nil and k == last.k)
  end
  return y0 + 2 * B.nh + 6
end

local function hideLine()
  V.card.f:Hide()
  for _, n in ipairs(V.names) do n.f:Hide(); n.id = nil end
end

-- The ten rows from top; a wrong row adds "your pick: <name>" (t.chose, mock ws-3) right of its speaker, cut at the
-- column's edge. The rows shrink so the tenth ends 4 px above the bottom buttons (V-f4).
local function drawAnswers(t, B, LW, top, H)
  at(V.answersHead, LEFT, top)
  local y0 = top + 28
  local rh = math.min(B.rh, math.floor((H - 30 - 4 - 14 - y0) / (RUN - 1)))
  V.answersHead:SetWidth(LW)
  V.answersHead:Show()
  for i, r in ipairs(V.answers) do
    local entry, mark = t.lines[i], t.picks:sub(i, i)
    local shown = entry ~= nil and mark ~= ""
    for _, f in ipairs({ r.num, r.icon, r.name }) do f:SetShown(shown) end
    local mine = shown and mark == "0" and t.chose and t.chose[i] or nil
    r.pick:SetShown(mine ~= nil)
    if shown then
      local y = y0 + (i - 1) * rh
      at(r.num, LEFT, y)
      r.num:SetText(tostring(i))
      at(r.icon, LEFT + 20, y - 1)
      r.icon:SetTexture(mark == "1" and RIGHT_ICON or WRONG_ICON)
      at(r.name, LEFT + 40, y)
      local sp = speaker(speakerOf(entry.line))
      r.name:SetText(sp)
      if mine then
        local x = math.max(LEFT + math.floor(LW * 0.5), LEFT + 40 + math.floor(textWidth(r.name, sp)) + 12)
        at(r.pick, x, y)
        r.pick:SetWidth(math.max(10, LEFT + LW - x))
        r.pick:SetText("your pick: " .. RED .. speaker(mine) .. "|r")
      end
    end
  end
end

local function hideAnswers()
  V.answersHead:Hide()
  for _, r in ipairs(V.answers) do r.num:Hide(); r.icon:Hide(); r.name:Hide(); r.pick:Hide() end
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
-- longer than max ends with "and N more" in the last slot (as Vendor.lua's Today in the guild).
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
  local guild = ns.WhoGuild and ns.WhoGuild()
  local board = ns.WhoBoard and ns.WhoBoard()
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

-- The status lines under the names: why a play or pick was refused, what the pick was, or what to do.
local function drawStatus(entry, live, sub, y, LW)
  at(V.status, LEFT, y + 24)
  -- A refusal with no pick on screen takes the column's full width in the small font, so the longest reason keeps
  -- one line (A-f2b); with a pick on screen Next line holds the right end.
  local reason = V.msg ~= nil and not V.last
  local sw = reason and LW or LW - 130
  V.status:SetFontObject(reason and "GameFontHighlightSmall" or "GameFontHighlight")
  V.status:SetWidth(sw)
  V.sub:SetWidth(LW - 130)
  if V.msg then -- a refusal in red; "still playing" is a wait, not a fault (A-f3)
    V.status:SetText(V.msg == WHY["still playing"] and V.msg or (RED .. V.msg .. "|r"))
  elseif V.last then
    V.status:SetText((V.last.right and (GREEN .. "Right.|r ") or (RED .. "Wrong.|r ")) .. "It was "
      .. speaker(speakerOf(entry.line)) .. ".")
  else
    V.status:SetText(ns.WhoPlaying and ns.WhoPlaying() and "Playing..." or live and PICK or "Play the line to answer.")
  end
  -- The sub line at a measured y, not on the status line's wrapped bottom (Vendor.lua's drawStatus).
  local text = V.status:GetText() or ""
  local w = V.status.GetUnboundedStringWidth and V.status:GetUnboundedStringWidth()
  if not (type(w) == "number" and w > 0) then w = textWidth(V.status, text) end
  local lines = w > 2 * sw and 3 or w > sw and 2 or 1
  at(V.sub, LEFT, y + 24 + lines * 14 + 4)
  V.sub:SetText(sub)
end

-- Next line (or Your results) at the right end of the lead row at y.
local function placeNext(text, shown, y, LW)
  V.next:SetText(text)
  V.next:SetShown(shown)
  V.next:ClearAllPoints()
  V.next:SetPoint("TOPRIGHT", V.body, "TOPLEFT", LEFT + LW, -(y + 22))
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
  V.charmLine:SetWidth(math.min(200, LEFT + LW - 222))
  V.charmLine:SetShown(on)
  V.charmIcon:SetShown(on)
end

function V.Draw()
  local W, H = size()
  local B = H < SMALL_BELOW and SMALL or BIG
  local LW = W - LEFT - B.rw - GAP - LEFT
  local e = ns.WhoEndless and ns.WhoEndless()
  local t = ns.WhoToday and ns.WhoToday()
  local last = V.last
  if last and (last.endless ~= (e ~= nil) or (not last.endless and not (t and t.n == last.n))) then
    V.last, last = nil, nil
  end
  V.shown = nil
  bottomButtons(e, t)
  drawCharm(e, t, LW)
  drawRight(B, W)
  V.next:Hide()
  V.best:Hide()
  V.earned:Hide()
  V.earnedIcon:Hide()
  V.note:Hide()
  hideAnswers()
  V.sub:Show()
  V.status:Show()
  V.lead:Show()
  if e then -- endless (ws-4)
    V.title2:SetText("Endless · name voices until you miss · no grain")
    local entry = last and last.entry or (e.line and e)
    local live = not last and entry ~= nil and V.heardLine == e.line
    local y = 46
    if entry then
      drawCard(entry, last ~= nil or live, B, LW)
      y = drawNames(entry, live, last, B, LW) + 12
    else
      hideLine()
    end
    hideMarks()
    at(V.lead, LEFT, y)
    V.lead:SetText("Streak " .. (e.streak or 0))
    at(V.best, LEFT + 110, y + 2)
    V.best:SetText("Your best: " .. ((ns.WhoStats and ns.WhoStats() or {}).ebest or 0))
    V.best:Show()
    if entry then
      drawStatus(entry, live, e.done and "The run is over: start a new one." or "A wrong pick ends the run.", y, LW)
    else
      V.status:Hide()
      V.sub:Hide()
    end
    placeNext("Next line", last ~= nil and not e.done, y, LW)
  elseif not t then -- no lines today (no clock)
    hideLine()
    hideMarks()
    V.title2:SetText("")
    V.lead:SetText("No lines today: the day is not known yet.")
    at(V.lead, LEFT, 46)
    V.status:Hide()
    V.sub:Hide()
  elseif t.done and not last then -- the finished run (ws-3)
    hideLine()
    V.title2:SetText("Daily " .. t.label .. " · finished · a new run at the daily reset")
    at(V.lead, LEFT, 48)
    V.lead:SetText((t.score or 0) .. "/10") -- the lead's gold (V-f2, mock ws-3)
    drawMarks(t.picks, LEFT + 60, 48)
    at(V.earnedIcon, LEFT, 70)
    V.earnedIcon:Show()
    at(V.earned, LEFT + 22, 72)
    V.earned:SetText((t.earned or 0) .. " grain earned")
    V.earned:Show()
    local r = t.score or 0
    local top = 92
    if V.msg then -- the Share note on its own full-width row under the earned line; the answers move down (A-f1)
      at(V.note, LEFT, 92)
      V.note:SetWidth(LW)
      V.note:SetText(V.msg)
      top = 92 + (textWidth(V.note, V.msg) > LW and 2 or 1) * 14 + 4
    else
      at(V.note, LEFT + 160, 72)
      V.note:SetWidth(LW - 160)
      V.note:SetText(r .. (r == 1 and " right pick" or " right picks") .. " at 5") -- mock ws-3
    end
    V.note:Show()
    V.status:Hide()
    V.sub:Hide()
    drawAnswers(t, B, LW, top, H)
  else -- a line to play and name, or the one just named (ws-1, ws-2)
    V.title2:SetText("Daily " .. t.label .. " · the same ten lines for the whole guild")
    local i = last and last.i or (#t.picks + 1)
    local entry = last and last.entry or t.lines[i]
    local live = not last and entry ~= nil and t.heard == i
    if not last then V.shown = { n = t.n, i = i, entry = entry } end -- what a click names (R-f9, Vendor's f7271)
    drawCard(entry, last ~= nil or t.heard == i, B, LW)
    local y = drawNames(entry, live, last, B, LW) + 12
    at(V.lead, LEFT, y)
    V.lead:SetText("Line " .. i .. " of " .. RUN)
    drawMarks(t.picks, LEFT + 110, y)
    drawStatus(entry, live, last and ((t.score or 0) .. " of " .. #t.picks .. " right · " .. (t.earned or 0)
      .. " grain so far") or HINT, y, LW)
    placeNext(t.done and "Your results" or "Next line", last ~= nil, y, LW)
  end
  V.title2:SetWidth(LW)
end

-- ---------- actions ----------

-- The line on screen: the one just named, else the endless line, else today's next one; nil when there is none.
local function onScreen()
  local e = ns.WhoEndless and ns.WhoEndless()
  if V.last then return V.last.entry, e end
  if e then return e.line and e or nil, e end
  local t = ns.WhoToday and ns.WhoToday()
  if not t or t.done then return nil end
  return t.lines[#t.picks + 1], nil, t
end

-- Play or Replay: the line on screen through ns.WhoPlay; on success it is heard. A replay of a line already named
-- calls no ns.WhoHeard: the pick is made, and the next line must still be played before it can be named.
local function play()
  local entry, e = onScreen()
  if not entry then return end
  local good, why = ns.WhoPlay(ns.VOICES.lines[entry.line][1])
  V.msg = nil
  if good then
    if not V.last then
      ns.WhoHeard()
      if e then V.heardLine = entry.line end
    end
  else
    V.msg = WHY[why]
  end
  V.Draw()
end

local function pick(k)
  if V.last then return end -- one pick a line; Next line moves on
  local e = ns.WhoEndless and ns.WhoEndless()
  -- The day and line drawn, not a fresh read: a click from before the reset is refused as rolled (R-f9).
  local s = not e and V.shown
  local entry = e and e.line and e or (s and s.entry)
  local id = entry and entry.choices[k]
  if not id then return end
  local i, n = s and s.i, s and s.n
  local good, right
  if s then
    good, right = ns.WhoPick(id, n, i) -- the run and line on screen (R-f1, as VendorPick)
  else
    good, right = ns.WhoPick(id)
  end
  V.msg = nil
  if good then
    V.last = { entry = entry, k = k, right = right, i = i, n = n, endless = e ~= nil }
    V.heardLine = nil
  else
    V.msg = WHY[right]
  end
  V.Draw()
end

local function mode(m)
  V.last, V.msg, V.heardLine = nil, nil, nil
  ns.WhoMode(m)
  V.Draw()
end

local function buyCharm()
  local good, why = ns.WhoBuyCharm()
  V.msg = not good and WHY[why] or nil
  V.Draw()
end

local function nextLine()
  V.last, V.msg = nil, nil
  V.Draw()
end

local function share()
  if ns.Inert and ns.Inert() then return end
  local t = ns.WhoToday and ns.WhoToday()
  if not (t and t.done) then return end
  local text = ns.WhoCore.ShareText(t.label, t.picks) -- the marks only, no speaker (AC5)
  if ns.OpenChat("/g " .. text) then
    V.msg = "In the guild chat box: press Enter to send."
  else
    V.msg = "Type this in guild chat: " .. (text:gsub("{rt4}", "G"):gsub("{rt5}", ".")) -- plain marks (A-f1)
  end
  V.Draw()
end

-- ---------- build ----------

local function buildCard(body)
  local f = CreateFrame("Button", nil, body)
  ns.UI.inset(f)
  local c = { f = f }
  c.icon = f:CreateTexture(nil, "ARTWORK")
  c.icon:SetPoint("TOP", f, "TOP", 0, -10)
  c.icon:SetTexture(PLAY_ICON)
  c.text = label(f, "GameFontNormalLarge") -- before the hint: the card's first text is its Play / Replay
  c.text:SetJustifyH("CENTER")
  c.hint = label(f)
  c.hint:SetJustifyH("CENTER")
  grey(c.hint)
  c.hint:SetPoint("TOP", c.text, "BOTTOM", 0, -2)
  f:SetScript("OnClick", function() M.Safe(play) end)
  V.card = c
end

local function buildName(body, k)
  local f = CreateFrame("Button", nil, body)
  ns.UI.inset(f)
  local n = { f = f }
  n.fs = label(f, "GameFontHighlight")
  n.fs:SetJustifyH("CENTER")
  n.fs:SetPoint("CENTER", f, "CENTER", 0, 0)
  n.mark = f:CreateTexture(nil, "OVERLAY")
  n.mark:SetSize(16, 16)
  n.mark:Hide()
  n.accent = f:CreateTexture(nil, "BORDER") -- as Vendor.lua's card accent: 2 px gold .55
  n.accent:SetColorTexture(1, 0.82, 0, 0.55)
  n.accent:SetWidth(2)
  n.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  n.accent:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  n.accent:Hide()
  f:SetScript("OnClick", function() M.Safe(pick, k) end)
  V.names[k] = n
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
  V.title = label(body, "GameFontNormalLarge") -- the holder's own title; the game menu repeats it (mock #f2)
  V.title:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -4)
  V.title:SetText("Who said it?")
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
  buildCard(body)
  for k = 1, 4 do buildName(body, k) end
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
  V.next = button(body, "Next line", 110)
  V.next:SetScript("OnClick", function() M.Safe(nextLine) end)
  V.earnedIcon = body:CreateTexture(nil, "ARTWORK")
  V.earnedIcon:SetSize(16, 16)
  V.earnedIcon:SetTexture(WHEAT)
  V.earned = label(body, "GameFontHighlight")
  V.note = label(body)
  grey(V.note)
  V.answersHead = header(body, "Your ten answers")
  V.pickHead = label(V.answersHead) -- mock ws-3
  V.pickHead:SetPoint("TOPRIGHT", V.answersHead, "TOPRIGHT", -21, -8)
  V.pickHead:SetText("your pick when wrong")
  grey(V.pickHead)
  for i = 1, RUN do
    local r = { num = label(body), icon = body:CreateTexture(nil, "ARTWORK"), name = label(body, "GameFontHighlight"),
      pick = label(body) }
    grey(r.pick)
    r.pick:SetWordWrap(false)
    grey(r.num)
    r.icon:SetSize(16, 16)
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
  body:HookScript("OnSizeChanged", function() if ns.ShownGame and ns.ShownGame() == "who" then M.Safe(V.Draw) end end)
end

ns.WhoTab = {
  Build = build,
  -- Nothing is drawn unless the Who said it game is on screen (RefreshPage calls this while hidden too).
  Refresh = function()
    if V.body and ns.ShownGame and ns.ShownGame() == "who" then V.Draw() end
  end,
}
