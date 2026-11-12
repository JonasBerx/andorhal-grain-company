-- GuildSyncExpeditions GuildTab.lua (slice I, plan Task 3): the Guild page, ns.GuildTab.
--   GuildTab.Build(f, bar) -> true   GuildTab.Refresh(f)     f is 726 x 476 or 586 x 356, never scaled
-- f.guild = { mode = "board" | "member", members = { [i] = { slots = { [1..16] = { icon, edges, code } } } } }
-- Every field of another member's record is a claim: every string goes through ns.Escape, nothing mechanical reads them.
-- Tooltips are the module's own (ns.BagGrid.Tip); a catalogue row's real item id never reaches the screen.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local TOP, GAP = 6, 4
local ROW_STEP, FEED_STEP = 16, 30
local MAX_BOARD, MAX_FEED = 10, 20
local MAX_HIDES = 10
local SET_SIZE = 6
local WHEEL_STEP = 40
local DOT = " \194\183 "
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local GREY, EMPTY_EDGE, WHITE = "9d9d9d", "3a3226", "ffffff"
local READY, AWAY, RESTING, DEAD, RESERVE = "19ff19", "ffd100", "ff801a", "ff2020", "9d9d9d"
local CLASS_HEX = { Warrior = "c79c6e", Paladin = "f58cba", Hunter = "abd473", Rogue = "fff569", Priest = "ffffff",
  Shaman = "0070de", Mage = "69ccf0", Warlock = "9482c9", Druid = "ff7d0a" }

local BIG = { big = true, w = 726, h = 476, left = 400, rightX = 408, officerH = 56, feedW = 302,
  top = { w = 384, nameX = 28, nameW = 84, midX = 114, midW = 114, statX = 230, statW = 52, ownerX = 284, ownerW = 100 },
  deadly = { w = 384, nameX = 28, nameW = 84, statX = 114, statW = 100, ownerX = 218, ownerW = 166 },
  off = { headX = 10, labelX = 74, boxX = 254, boxW = 140, saveX = 400, saveW = 54, countX = 464, lineW = 140, y1 = 8, y2 = 32,
    label = "Bring writs are mailed to", count = "Hidden followers: ",
    hint = "Right-click a follower on a board to hide it from the guild." },
  flair = { 8, 150, 164, 300, 470, 100, 580, 130 },
  rowStep = 62, nameY = 5, levelY = 22, followerW = 190, statusX = 204, statusW = 96, stripX = 306, stripY = 6, cell = 20,
  pitch = 22, groupGap = 8, underY = 30, underW = 366, scoreX = 678, scoreW = 40, headScoreX = 646 }

local SMALL = { big = false, w = 586, h = 356, left = 300, rightX = 308, officerH = 52, feedW = 262,
  top = { w = 284, nameX = 28, nameW = 72, midX = 104, midW = 28, statX = 136, statW = 68, ownerX = 208, ownerW = 76 },
  deadly = { w = 284, nameX = 28, nameW = 72, statX = 104, statW = 100, ownerX = 208, ownerW = 76 },
  off = { headX = 8, labelX = 70, boxX = 158, boxW = 120, saveX = 284, saveW = 50, countX = 344, lineW = 150, y1 = 6, y2 = 30,
    label = "Writ mail to", count = "Hidden: ", hint = "Right-click a follower to hide it." },
  flair = { 8, 128, 140, 246, 386, 90, 482, 96 },
  rowStep = 45, nameY = 1, levelY = 17, followerW = 152, statusX = 166, statusW = 108, stripX = 282, stripY = 2, cell = 13,
  pitch = 14, groupGap = 6, underY = 18, underW = 236, scoreX = 520, scoreW = 58, headScoreX = 506 }

local FLAIR_Y, FLAIR_H, TABLE_Y, ROWS_Y = 46, 44, 96, 24

local SAY = {
  officer = "Only officers can do that.",
  unknown = "That character is not in the guild.",
  self = "You cannot hide your own follower.",
  name = "That name cannot be hidden.",
  full = "You have hidden 10 followers. Show one again first.",
}

local GuildTab = {}
ns.GuildTab = GuildTab

local function sizeOf(f)
  return (f:GetWidth() >= 700 and f:GetHeight() >= 450) and BIG or SMALL
end

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function paint(hex, s) return "|cff" .. hex .. s .. "|r" end

local function refuse(why)
  if why ~= "demo" then ns.Say(SAY[why] or "You cannot do that now.") end
end

local function amOfficer()
  local C = GuildSync.Comm
  local me = C.MyKey()
  return me ~= nil and C.IsOfficer(me) == true
end

local function firstName(s) return s:match("^(%S+)") or s end

local function ownerText(s, row)
  if row.you then return "You" end
  return ns.Escape(s.big and row.owner or firstName(row.owner))
end

local function classed(name, class) return paint(CLASS_HEX[class] or WHITE, ns.Escape(name)) end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

-- ---------- pieces ----------

local function text(parent, x, y, w, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  if w then fs:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, -y) end
  fs:SetWordWrap(false)
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

local function button(parent, label, w, h)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  b:SetText(label)
  return b
end

local function place(frame, parent, x, y, w, h)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  frame:SetSize(w, h)
end

local function edge(frame, a, b, across)
  local t = frame:CreateTexture(nil, "BORDER")
  t:SetPoint(a, frame, a, 0, 0)
  t:SetPoint(b, frame, b, 0, 0)
  if across then t:SetHeight(1) else t:SetWidth(1) end
  return t
end

local function edges(frame)
  return { edge(frame, "TOPLEFT", "TOPRIGHT", true), edge(frame, "BOTTOMLEFT", "BOTTOMRIGHT", true),
    edge(frame, "TOPLEFT", "BOTTOMLEFT"), edge(frame, "TOPRIGHT", "BOTTOMRIGHT") }
end

local function paintEdges(list, hex)
  local r, g, b = rgb(hex)
  for _, t in ipairs(list) do t:SetColorTexture(r, g, b) end
end

local function wheel(scroll, child, delta)
  local range = math.max(0, (child:GetHeight() or 0) - (scroll:GetHeight() or 0))
  scroll:SetVerticalScroll(math.max(0, math.min(range, (scroll:GetVerticalScroll() or 0) - delta * WHEEL_STEP)))
end

local function newList(parent, title)
  local panel = M.Kit.Card(parent, 100, 100)
  text(panel, 10, 8, nil, "GameFontNormal"):SetText(title)
  local scroll = CreateFrame("ScrollFrame", nil, panel)
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -26)
  local child = CreateFrame("Frame", nil, scroll)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta) M.Safe(wheel, self, child, delta) end)
  return { panel = panel, scroll = scroll, child = child, rows = {}, empty = text(panel, 10, 30) }
end

local function fit(list, parent, x, y, w, h)
  place(list.panel, parent, x, y, w, h)
  list.scroll:SetSize(w - 16, h - 32)
end

-- The spare rows are hidden and the list's child takes the height of the n rows drawn.
local function finishList(list, n, step, width, emptyLine)
  for i = n + 1, #list.rows do list.rows[i].b:Hide() end
  list.child:SetSize(width, math.max(1, n * step))
  if n == 0 then
    list.empty:SetText(emptyLine)
    list.empty:Show()
  else
    list.empty:Hide()
  end
end

-- ---------- clicks ----------

local function openMember(ui, group)
  ui.mode, ui.group = "member", group
  GuildTab.Refresh(ui.f)
end

local function clickRow(ui, data, mouse)
  if not data then return end
  if mouse ~= "RightButton" then
    openMember(ui, data.group)
    return
  end
  if not data.name or not amOfficer() then return end
  local done, why = ns.SetHidden(data.key, data.name, true)
  if not done then refuse(why) end
  GuildTab.Refresh(ui.f)
end

local function rowButton(ui, list, i, step, width)
  local b = CreateFrame("Button", nil, list.child)
  b:SetSize(width, step)
  b:SetPoint("TOPLEFT", list.child, "TOPLEFT", 0, -(i - 1) * step)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local row = { b = b }
  b:SetScript("OnClick", function(_, mouse) M.Safe(clickRow, ui, row.data, mouse) end)
  return row
end

-- ---------- the boards ----------

local function followerRows(entries)
  local all = {}
  for _, e in ipairs(entries) do
    for _, x in ipairs(e.view.followers or {}) do
      if not ns.IsFollowerHidden(e.key, x.name) then
        all[#all + 1] = { name = x.name, class = x.class, race = x.race, level = x.level, wins = x.wins, deadly = x.deadly,
          key = e.key, group = e.group, owner = e.owner, you = e.you }
      end
    end
  end
  return all
end

local function byName(a, b)
  if a.name ~= b.name then return a.name < b.name end
  return a.key < b.key
end

local function byLevel(a, b)
  if a.level ~= b.level then return a.level > b.level end
  if a.wins ~= b.wins then return a.wins > b.wins end
  return byName(a, b)
end

local function byDeadly(a, b)
  if a.deadly ~= b.deadly then return a.deadly > b.deadly end
  return byName(a, b)
end

local function ranked(all, order, keep)
  local list = {}
  for _, row in ipairs(all) do
    if not keep or keep(row) then list[#list + 1] = row end
  end
  table.sort(list, order)
  return list
end

local function boardRow(ui, list, i, cols)
  local row = list.rows[i]
  if row then return row end
  row = rowButton(ui, list, i, ROW_STEP, cols.w)
  row.rank = text(row.b, 0, 1, 24)
  row.name = text(row.b, cols.nameX, 1, cols.nameW)
  if cols.midX then row.mid = text(row.b, cols.midX, 1, cols.midW) end
  row.stat = text(row.b, cols.statX, 1, cols.statW)
  row.owner = text(row.b, cols.ownerX, 1, cols.ownerW, nil, "RIGHT")
  list.rows[i] = row
  return row
end

local function drawBoard(ui, list, s, cols, rows, statOf)
  local n = math.min(#rows, MAX_BOARD)
  for i = 1, n do
    local data, row = rows[i], boardRow(ui, list, i, cols)
    row.data = data
    row.rank:SetText(i .. ".")
    row.name:SetText(classed(data.name, data.class))
    if row.mid then
      local line = "L" .. data.level
      if s.big then line = line .. " " .. ns.Escape(data.race) .. " " .. ns.Escape(data.class) end
      row.mid:SetText(line)
    end
    row.stat:SetText(statOf(data))
    row.owner:SetText(ownerText(s, data))
    row.b:Show()
  end
  finishList(list, n, ROW_STEP, cols.w, "Nothing to show yet.")
end

local function statWins(x) return plural(x.wins, "Win") end
local function statDeadly(x) return plural(x.deadly, "Deadly Win") end
local function hasDeadly(x) return x.deadly > 0 end

-- ---------- the feed ----------

local function feedRows(entries, today)
  local list = {}
  for _, e in ipairs(entries) do
    for i, find in ipairs(e.view.finds or {}) do
      local row = ns.GearData.Row(find.code)
      if (not row or row.q == 3) and not (today and find.day > today)
        and not (find.who and ns.IsFollowerHidden(e.key, find.who)) then
        list[#list + 1] = { row = row, who = find.who, day = find.day, rev = e.rev, index = i, key = e.key, group = e.group,
          owner = e.owner, you = e.you }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.day ~= b.day then return a.day > b.day end
    if a.rev ~= b.rev then return a.rev > b.rev end
    if a.key ~= b.key then return a.key < b.key end
    return a.index < b.index
  end)
  return list
end

local function dayWords(today, day)
  if not today then return "" end
  local n = today - day
  if n <= 0 then return "Today" end
  return plural(n, "Day")
end

local function feedRow(ui, list, i, width)
  local row = list.rows[i]
  if row then return row end
  row = rowButton(ui, list, i, FEED_STEP, width)
  row.what = text(row.b, 0, 1, width - 56)
  row.sub = text(row.b, 0, 15, width - 56)
  row.day = text(row.b, width - 52, 1, 52, nil, "RIGHT")
  list.rows[i] = row
  return row
end

local function drawFeed(ui, list, s, entries)
  local today = ns.BoardCore.Day(ns.Now(), M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset"))
  local rows = feedRows(entries, today)
  local n = math.min(#rows, MAX_FEED)
  for i = 1, n do
    local data, row = rows[i], feedRow(ui, list, i, s.feedW)
    row.data = data
    if data.row then
      row.what:SetText(paint(ns.GearCore.QUALITY_COLOUR[data.row.q], ns.Escape(data.row.name)))
    else
      row.what:SetText(paint(GREY, "Unknown item"))
    end
    local owner = ownerText(s, data)
    row.sub:SetText(data.who and (ns.Escape(data.who) .. DOT .. owner) or owner)
    row.day:SetText(dayWords(today, data.day))
    row.b:Show()
  end
  finishList(list, n, FEED_STEP, s.feedW, "No rare finds yet.")
end

-- ---------- the officer bar ----------

local function saveBank(ui, v)
  local value = (v.officer.box:GetText() or ""):match("^%s*(.-)%s*$")
  local done, why = ns.SetBankRecipient(value ~= "" and value or nil)
  if done then ns.Say("Saved.") else refuse(why) end
  GuildTab.Refresh(ui.f)
end

local function showAgain(ui)
  local first = ns.Hides()[1]
  if not first then return end
  local done, why = ns.SetHidden(first.owner, first.name, false)
  if not done then refuse(why) end
  GuildTab.Refresh(ui.f)
end

local function buildOfficer(ui, v)
  local s, o = v.s, v.s.off
  local card = M.Kit.Card(v.board, s.w, s.officerH)
  card:SetPoint("TOPLEFT", v.board, "TOPLEFT", 0, -(s.h - s.officerH))
  text(card, o.headX, o.y1, nil, "GameFontNormal"):SetText("Officers")
  text(card, o.labelX, o.y1):SetText(o.label)
  local box = M.Kit.InputBox(card, o.boxW, o.boxW)
  box:SetPoint("TOPLEFT", card, "TOPLEFT", o.boxX, -(o.y1 - 2))
  box:SetAutoFocus(false)
  local save = button(card, "Save", o.saveW, 20)
  save:SetPoint("TOPLEFT", card, "TOPLEFT", o.saveX, -(o.y1 - 2))
  save:SetScript("OnClick", function() M.Safe(saveBank, ui, v) end)
  text(card, o.headX, o.y2):SetText(o.hint)
  local again = button(card, "Show again", 80, 20)
  again:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 4)
  again:SetScript("OnClick", function() M.Safe(showAgain, ui) end)
  v.officer = { card = card, box = box, count = text(card, o.countX, o.y1), line = text(card, o.countX, o.y2, o.lineW), again = again }
end

local function drawOfficer(ui, v)
  if not v.officer then buildOfficer(ui, v) end
  local o, hides = v.officer, ns.Hides()
  o.card:Show()
  if not (o.box.HasFocus and o.box:HasFocus()) then o.box:SetText(ns.Escape(ns.BankRecipient() or "")) end
  o.count:SetText(v.s.off.count .. #hides .. " of " .. MAX_HIDES)
  local first = hides[1]
  if first then
    o.line:SetText(ns.Escape(first.name) .. " (" .. ns.Escape(first.ownerName) .. ")")
    o.again:Show()
  else
    o.line:SetText("")
    o.again:Hide()
  end
end

-- ---------- the member view ----------

local function newCell(rowFrame, x, y, size)
  local b = CreateFrame("Button", nil, rowFrame)
  b:SetSize(size, size)
  b:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", x, -y)
  local plate = b:CreateTexture(nil, "BACKGROUND")
  plate:SetAllPoints(b)
  plate:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  plate:SetTexCoord(0.1875, 0.8125, 0.1875, 0.8125)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
  icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
  return { b = b, icon = icon, edges = edges(b) }
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function cellTip(s, owner, cell)
  if cell.piece then ns.BagGrid.Tip(owner, cell.piece, cell.level or 0, s.big and "ANCHOR_RIGHT" or "ANCHOR_LEFT", true) end
end

local function newMemberRow(v, i)
  local s = v.s
  local frame = CreateFrame("Frame", nil, v.tableCard)
  frame:SetPoint("TOPLEFT", v.tableCard, "TOPLEFT", 0, -(ROWS_Y + (i - 1) * s.rowStep))
  frame:SetSize(s.w, s.rowStep)
  local row = { frame = frame, slots = {} }
  row.name = text(frame, 8, s.nameY, s.followerW, "GameFontNormal")
  row.level = text(frame, 8, s.levelY, s.followerW)
  row.status = text(frame, s.statusX, s.nameY, s.statusW)
  row.under = text(frame, s.stripX, s.underY, s.underW)
  row.score = text(frame, s.scoreX, s.nameY, s.scoreW, nil, "RIGHT")
  for n = 1, #ns.GearData.SLOTS do
    local x = s.stripX + (n - 1) * s.pitch + (n > 6 and s.groupGap or 0) + (n > 14 and s.groupGap or 0)
    local cell = newCell(frame, x, s.stripY, s.cell)
    cell.b:SetScript("OnEnter", function(self) M.Safe(cellTip, s, self, cell) end)
    cell.b:SetScript("OnLeave", function() M.Safe(hideTip) end)
    row.slots[n] = cell
  end
  return row
end

local function buildMember(v)
  local s = v.s
  local root = v.member
  v.ownerLine = text(root, 8, 6, s.w - 16, "GameFontNormalLarge")
  v.subLine = text(root, 8, 28, s.w - 16)
  local flair = M.Kit.Card(root, s.w, FLAIR_H)
  flair:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -FLAIR_Y)
  v.flair = {}
  for i, label in ipairs({ "Title", "Badges", "Trophies", "Relics" }) do
    local x, w = s.flair[i * 2 - 1], s.flair[i * 2]
    text(flair, x, 6, w, "GameFontNormal"):SetText(label)
    v.flair[i] = text(flair, x, 24, w)
  end
  v.tableCard = M.Kit.Card(root, s.w, s.h - TABLE_Y - GAP)
  v.tableCard:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -TABLE_Y)
  text(v.tableCard, 8, 6, s.followerW, "GameFontNormal"):SetText("Follower")
  text(v.tableCard, s.statusX, 6, s.statusW, "GameFontNormal"):SetText("Status")
  text(v.tableCard, s.stripX, 6, 60, "GameFontNormal"):SetText("Gear")
  text(v.tableCard, s.headScoreX, 6, 72, "GameFontNormal", "RIGHT"):SetText(ns.W.Name["kit score"])
  v.rows, v.members = {}, {}
  for i = 1, 5 do
    v.rows[i] = newMemberRow(v, i)
    v.members[i] = { slots = v.rows[i].slots }
  end
end

local function titleName(id)
  if not id then return nil end
  local QD = ns.QuestData
  local writ = QD.BY_ID[id]
  if writ then return writ.flairName end
  for _, row in ipairs(QD.STORY_TITLES or {}) do
    if row.id == id then return row.name end
  end
  return nil
end

local function badgeNames(ids)
  local names = {}
  for _, id in ipairs(ids or {}) do
    local writ = ns.QuestData.BY_ID[id]
    if writ and writ.flairName then names[#names + 1] = ns.Escape(writ.flairName) end
  end
  if #names == 0 then return "None" end
  return table.concat(names, ", ")
end

local function relicCount(bits)
  local n = 0
  for i = 1, #ns.BookData.relics do
    if math.floor((bits or 0) / 2 ^ (i - 1)) % 2 == 1 then n = n + 1 end
  end
  return n
end

local function stateOf(letter)
  local W = ns.W
  if letter == "b" then return W.Name["in reserve"], RESERVE end
  if letter == "o" then return W.Name.out, AWAY end
  if letter == "r" then return W.Name.rest, RESTING end
  if letter == "d" then return "Dead", DEAD end
  return W.Name.idle, READY
end

local function fillCell(cell, piece, level)
  cell.piece, cell.level, cell.code = piece, level, piece and piece.row or nil
  if not piece then
    cell.icon:Hide()
    paintEdges(cell.edges, EMPTY_EDGE)
    return
  end
  local row = not piece.unknown and ns.GearData.Row(piece.row)
  if row then
    cell.icon:SetTexture(row.icon)
    paintEdges(cell.edges, ns.GearCore.QUALITY_COLOUR[row.q])
  else
    cell.icon:SetTexture(QUESTION)
    paintEdges(cell.edges, GREY)
  end
  cell.icon:Show()
end

-- The set worn most, ties to the name that sorts first, and the piece count.
local function bestSet(pieces)
  local counts, best, n = {}, nil, 0
  for _, piece in pairs(pieces) do
    local row = not piece.unknown and ns.GearData.Row(piece.row)
    if row and row.set then counts[row.set] = (counts[row.set] or 0) + 1 end
  end
  for set, c in pairs(counts) do
    if c > n or (c == n and set < best) then best, n = set, c end
  end
  return best, n
end

local function underLine(x, pieces)
  local parts = {}
  local set, n = bestSet(pieces)
  if set then parts[#parts + 1] = ns.Escape(set) .. " " .. n .. " of " .. SET_SIZE end
  local writ = x.look and ns.QuestData.BY_ID[x.look]
  if writ and writ.lookName then parts[#parts + 1] = "Look: " .. ns.Escape(writ.lookName) end
  return table.concat(parts, DOT)
end

local function drawFollower(row, entry, x)
  local pieces = x.pieces or {}
  if ns.IsFollowerHidden(entry.key, x.name) then
    row.name:SetText("Hidden")
  else
    row.name:SetText(classed(x.name, x.class))
  end
  row.level:SetText("Level " .. x.level .. " " .. ns.Escape(x.race) .. " " .. ns.Escape(x.class))
  local word, hex = stateOf(x.state)
  row.status:SetText(paint(hex, word))
  row.score:SetText(tostring(ns.GearCore.KitScore(pieces)))
  row.under:SetText(underLine(x, pieces))
  for i, slot in ipairs(ns.GearData.SLOTS) do fillCell(row.slots[i], pieces[slot.key], x.level) end
  row.frame:Show()
end

local function drawMember(v, entry)
  if not v.rows then buildMember(v) end
  local view, W = entry.view, ns.W
  local followers = view.followers or {}
  local now = ns.Now()
  v.ownerLine:SetText(ns.Escape(entry.owner))
  local shared = now and (DOT .. "Shared " .. W.Time(now - entry.rev) .. " ago") or ""
  v.subLine:SetText(plural(#followers, "Follower") .. shared)
  local flair = view.flair or {}
  local title = titleName(flair.title)
  v.flair[1]:SetText(title and ns.Escape(title) or "None")
  v.flair[2]:SetText(badgeNames(flair.badges))
  v.flair[3]:SetText(#(flair.trophies or {}) .. " of " .. #ns.QuestData.WRITS)
  v.flair[4]:SetText(relicCount(view.collection and view.collection.relics) .. " of " .. #ns.BookData.relics)
  for i, row in ipairs(v.rows) do
    if followers[i] then drawFollower(row, entry, followers[i]) else row.frame:Hide() end
  end
end

-- ---------- the page ----------

local function newView(f, s)
  local v = { s = s }
  v.board = CreateFrame("Frame", nil, f)
  v.board:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  v.board:SetSize(s.w, s.h)
  v.member = CreateFrame("Frame", nil, f)
  v.member:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  v.member:SetSize(s.w, s.h)
  v.member:Hide()
  v.top = newList(v.board, "Top Followers")
  v.deadly = newList(v.board, "Deadly Survivors")
  v.feed = newList(v.board, ns.W.Quality(3) .. " Finds")
  return v
end

local function layoutBoard(v, officer)
  local s = v.s
  local body = s.h - TOP - GAP - (officer and (s.officerH + GAP) or 0)
  local half = math.floor((body - GAP) / 2)
  fit(v.top, v.board, 0, TOP, s.left, half)
  fit(v.deadly, v.board, 0, TOP + half + GAP, s.left, half)
  fit(v.feed, v.board, s.rightX, TOP, s.w - s.rightX, body)
end

local function drawBoardPage(ui, v, entries)
  local s, officer = v.s, amOfficer()
  layoutBoard(v, officer)
  local all = followerRows(entries)
  drawBoard(ui, v.top, s, s.top, ranked(all, byLevel), statWins)
  drawBoard(ui, v.deadly, s, s.deadly, ranked(all, byDeadly, hasDeadly), statDeadly)
  drawFeed(ui, v.feed, s, entries)
  if officer then
    drawOfficer(ui, v)
  elseif v.officer then
    v.officer.card:Hide()
  end
end

local function newestOf(entries, group)
  for _, e in ipairs(entries) do
    if e.group == group then return e end
  end
  return nil
end

local function back(ui)
  ui.mode, ui.group = "board", nil
  GuildTab.Refresh(ui.f)
end

function GuildTab.Build(f, bar)
  local ui = { f = f, mode = "board", views = {}, members = {} }
  ui.sharing = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ui.sharing:SetPoint("RIGHT", bar, "RIGHT", 0, 0) -- the band's title reaches past the bar's left edge
  ui.back = button(bar, "Back to the Guild Board", 176, 20)
  ui.back:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
  ui.back:SetScript("OnClick", function() M.Safe(back, ui) end)
  ui.back:Hide()
  f.guild = ui
  f:SetScript("OnSizeChanged", function(self) M.Safe(GuildTab.Refresh, self) end)
  return true
end

function GuildTab.Refresh(f)
  local ui = f.guild
  if type(ui) ~= "table" then return end
  local s = sizeOf(f)
  local v = ui.views[s]
  if not v then
    v = newView(f, s)
    ui.views[s] = v
  end
  for _, other in pairs(ui.views) do
    other.board:Hide()
    other.member:Hide()
  end
  local demo = ns.DemoGuildRows()
  local entries = demo or ns.GuildRecords()
  local entry = ui.mode == "member" and newestOf(entries, ui.group) or nil
  if entry then
    v.member:Show()
    drawMember(v, entry)
    ui.members = v.members
    ui.sharing:Hide()
    ui.back:Show()
  else
    ui.mode, ui.group = "board", nil
    v.board:Show()
    drawBoardPage(ui, v, entries)
    ui.back:Hide()
    local count = demo and tostring(#demo) or ns.GuildCount()
    ui.sharing:SetText(count and (count .. (count == "1" and " Guildmate" or " Guildmates") .. " Sharing") or "")
    ui.sharing:Show()
  end
end
