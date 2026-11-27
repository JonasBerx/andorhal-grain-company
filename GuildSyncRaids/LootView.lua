local _, ns = ...
if not ns.M then return end

-- The Loot tab of the chosen raid (ticket 59): the drops this client recorded that the raid owns, under
-- their bosses in pull order, then Trash. ns.ShowLoot(ev) says when the tab shows (an owned drop, or
-- ns.WantLootTab(ev) exactly true); ns.DrawLoot(card, ev, layout, top, view) is called by RaidView.lua, and builds on
-- the first draw with an ev. Two slots for later tickets: ns.DrawLootBar(bar, ev) above the list (60) and
-- ns.DrawWants(box, ev, pick) under it (58), each under M.Safe (LOOT-FORMAT.md, "The slots"). In demo the drops are
-- made up here from ns.DemoData()'s pulls and never saved. Every name and item name goes through ns.Escape.
-- Corrections: for ns.MayEdit() a right-click on a drop opens one flat kit menu (the kit has no submenu, so
-- Winner, How and Move to open a second menu), and the foot holds "Add a drop" and one input line with Save and
-- Cancel. Rights and demo are checked again at every click; each change goes through ns.Loot.Change or ns.Loot.Add.

local M = ns.M
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only (made on the first read)
local R = ns.LootRules
local SB = 22 -- the scrollbar's room on the right (ns.ScrollArea)
local ROW_H, ICON, WORD_W = 34, 28, 96
local DOT = " \194\183 "
local EMPTY = "No loot recorded for this raid on this character."
local NOTE = "Recorded by this client."
local HELD = "picked up by the loot master"
-- How it was won, as line 2 reads it; de and bank have none (the winner line already says it).
local HOW = { sr = "soft reserve", ms = "main spec", os = "off spec", council = "council", need = "need", greed = "greed" }
-- The How menu, in order; false clears how.
local HOWS = { { "none", false }, { "council", "council" }, { "soft reserve", "sr" }, { "main spec", "ms" },
  { "off spec", "os" }, { "need", "need" }, { "greed", "greed" }, { "disenchanted", "de" }, { "guild bank", "bank" } }
local HINT = "Right-click a drop to correct it."
local NEEDS = "needs a reason"
local WHO_MAY = "Only officers and the group's leader correct the loot log."
local DEMO = "demo: corrections and added drops are not saved."
local NOT_ITEM = "That is not an item: shift-click one, or type its id."
local ADD_W, BTN_W, BOX_W, NOTE_W = 90, 64, 260, 150
-- The input line's letter limit per field (Add a drop's steps by step name): the saved caps; an item link is longer.
local LIMIT = { who = R.WHOCAP, why = R.WHYCAP, others = R.OTHERSCAP, item = 255 }

local function esc(s) return ns.Escape(tostring(s or "")) end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function at(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", x, y)
end

-- The item name's colour by quality: 0 Poor grey, 1 Common white, 2 Uncommon green, 3 and up gold; anything else white.
local function qualityColour(q)
  if q == 0 then return C.grey end
  if q == 2 then return C.green end
  if type(q) == "number" and q >= 3 then return C.gold end
  return ns.WHITE
end

-- The name's colour: what C_Item.GetItemQualityColor answers when that is three numbers, else the token map.
local function nameColour(fs, q)
  if type(q) == "number" then
    local r, g, b = M.Compat.call("C_Item.GetItemQualityColor", q)
    if type(r) == "number" and type(g) == "number" and type(b) == "number" then
      fs:SetTextColor(r, g, b)
      return
    end
  end
  color(fs, qualityColour(q))
end

local function say(text) ns.Say("Raids: " .. text) end

local function key(name)
  if type(name) ~= "string" then return nil end
  local k = ns.Key(name)
  return k
end

-- ---------- sources (the same for ShowLoot and DrawLoot) ----------

-- Made-up drops for the demo: one or two per kill in d.pulls, won by the pull's people; kept per DemoData table.
local DEMO_ITEMS = { 16800, 16802, 16805, 16809, 17063, 18814, 16865, 18820, 16810, 17069 }
local demoFor, demoList
local function demoDrops(d)
  if demoFor == d then return demoList end
  local list = {}
  for i, p in ipairs(type(d.pulls) == "table" and d.pulls or {}) do
    if type(p) == "table" and p.success == true and type(p.at) == "number" then
      local people = type(p.people) == "table" and p.people or {}
      for j = 1, (i % 2 == 0) and 2 or 1 do
        local who = type(people[j]) == "table" and people[j].name
        if type(who) == "string" then
          list[#list + 1] = { id = #list + 1, at = p.at + (tonumber(p.duration) or 0) + 30 * j,
            item = DEMO_ITEMS[(#list % #DEMO_ITEMS) + 1], src = "award", who = who, how = j == 1 and "council" or "ms",
            enc = p.encounterID, boss = p.name, pull = p.at }
        end
      end
    end
  end
  demoFor, demoList = d, list
  return list
end

local function sources()
  local d = ns.DemoData()
  local list
  if type(d) == "table" then list = demoDrops(d) else list = ns.LootList() end
  local pulls = ns.PullList()
  return type(list) == "table" and list or {}, type(pulls) == "table" and pulls or {}
end

local function owns(groups)
  if #groups.trash.rows > 0 then return true end
  for _, g in ipairs(groups) do if #g.rows > 0 then return true end end
  return false
end

-- The tab shows for an owned drop or when ns.WantLootTab(ev) is exactly true. A cheap scan of the raid's window
-- (PullRules.WINDOW either side) comes first, so ns.View and ForRaid run only when a non-party record lies in it.
function ns.ShowLoot(ev)
  if type(ev) ~= "table" then return nil end
  local list, pulls = sources()
  local start = tonumber(ev.start)
  local inWindow = false
  if start then
    local win = ns.PullRules.WINDOW
    local lo, hi = start - win, (tonumber(ev.finish) or start) + win
    for _, r in ipairs(list) do
      if type(r) == "table" and r.party ~= true and type(r.at) == "number" and r.at >= lo and r.at <= hi then
        inWindow = true
        break
      end
    end
  end
  if inWindow then
    local events = {}
    if type(ns.View) == "function" then
      local good, view = M.Safe(ns.View)
      if good and type(view) == "table" and type(view.events) == "table" then events = view.events end
    end
    if owns(R.ForRaid(list, ev, events, pulls)) then return true end
  end
  if type(ns.WantLootTab) == "function" then
    local good, want = M.Safe(ns.WantLootTab, ev)
    if good and want == true then return true end
  end
  return nil
end

-- ---------- the redraw after an item load ----------

-- A row whose item info is still loading marks its id wanted; when ns.Items reports that id loaded, every view that
-- wanted it is marked dirty and one page refresh is queued for the next frame, run only out of combat.

local views, hooked, fightHooked, queued = {}, false, false, false

local function flush()
  queued = false
  local combat = M.Compat.call("InCombatLockdown")
  if combat == false then M.RefreshPage() end
end

-- One refresh for the next frame when any view is dirty.
local function queueDirty()
  local any = false
  for _, V in ipairs(views) do if V.dirty then any = true end end
  if any and not queued then
    queued = true
    M.After(0, flush)
  end
end

local function onLoad(id)
  for _, V in ipairs(views) do
    if V.wanted[id] then V.dirty = true end
  end
  -- a view left dirty by a load in combat redraws at the next load of any id, or when the fight ends
  queueDirty()
end

local function hook()
  if not fightHooked and type(ns.AfterCombat) == "function" then
    fightHooked = true
    ns.AfterCombat(queueDirty)
  end
  if hooked then return end
  local Items = ns.Items
  if type(Items) == "table" and type(Items.OnLoad) == "function" then
    hooked = true
    Items.OnLoad(onLoad)
  end
end

-- ---------- corrections ----------

-- The editor's right, asked again at every click: false says who may correct, or that demo saves nothing.
local function allowed()
  local may = ns.MayEdit()
  if may ~= true then
    say(WHO_MAY)
    return false
  end
  local d = ns.DemoData()
  if type(d) == "table" then
    say(DEMO)
    return false
  end
  return true
end

local function recOf(id)
  local list = sources()
  for _, r in ipairs(list) do if type(r) == "table" and r.id == id then return r end end
end

-- ns.Loot.Change(id, t), said when refused, then a redraw.
local function change(id, t)
  if not allowed() then return end
  local good, why = ns.Loot.Change(id, t)
  if not good then say("That correction was not saved (" .. tostring(why) .. ").") end
  M.RefreshPage()
end

-- The kills the shown raid owns, in pull order.
local function kills(V)
  local out = {}
  local _, pulls = sources()
  for _, p in ipairs(ns.PullRules.ForRaid(pulls, V.ev, V.events)) do
    if type(p) == "table" and p.success == true and type(p.at) == "number" then out[#out + 1] = p end
  end
  return out
end

local function openLine(V, t)
  V.edit = t
  V.edit.text = V.edit.text or ""
  V.edit.focus = true
  M.RefreshPage()
end

-- A second menu, opened on the next frame so the first menu's close does not take it with it.
local function second(owner, generate)
  M.After(0, function() M.Safe(K.Menu, owner, generate) end)
end

local function winnerMenu(V, owner, id)
  local rec = recOf(id)
  if not rec then return end
  local people = {}
  local _, pulls = sources()
  for _, p in ipairs(pulls) do
    if type(p) == "table" and rec.pull ~= nil and p.at == rec.pull and type(p.people) == "table" then people = p.people end
  end
  local mine = key(rec.who)
  second(owner, function(_, root)
    local n = 1
    for _, p in ipairs(people) do
      if type(p) == "table" and type(p.name) == "string" then
        n = n + 1
        root:CreateRadio(esc(p.name), function(name) return mine ~= nil and key(name) == mine end,
          function(name) M.Safe(change, id, { who = name }) end, p.name)
      end
    end
    root:CreateButton("Type a name", function()
      M.Safe(function() if allowed() then openLine(V, { id = id, field = "who" }) end end)
    end)
    if n > 20 then root:SetScrollMode(400) end
  end)
end

local function howMenu(owner, id)
  local rec = recOf(id)
  if not rec then return end
  second(owner, function(_, root)
    for _, h in ipairs(HOWS) do
      root:CreateRadio(h[1], function(v) return (rec.how or false) == v end,
        function(v) M.Safe(change, id, { how = v }) end, h[2])
    end
  end)
end

local function moveMenu(V, owner, id)
  local rec = recOf(id)
  if not rec then return end
  local list = kills(V)
  second(owner, function(_, root)
    for _, p in ipairs(list) do
      root:CreateRadio(esc(p.name or "?"), function(at) return rec.pull == at end,
        function(at) M.Safe(change, id, { pull = at }) end, p.at)
    end
    root:CreateRadio("Trash", function() return rec.pull == nil end,
      function() M.Safe(change, id, { pull = false }) end)
  end)
end

-- The row menu: id is the record the menu opened on, whatever the row frame draws later.
local function rowMenu(V, row)
  local id = row.recId
  local rec = recOf(id)
  if not rec then return end
  K.Menu(row, function(_, root)
    local function entry(text, fn)
      root:CreateButton(text, function() M.Safe(function() if allowed() then fn() end end) end)
    end
    entry("Winner", function() winnerMenu(V, row, id) end)
    entry("How", function() howMenu(row, id) end)
    entry("Reason", function() openLine(V, { id = id, field = "why" }) end)
    entry("Others considered", function() openLine(V, { id = id, field = "others" }) end)
    entry("Move to", function() moveMenu(V, row, id) end)
    if rec.gone == true then
      entry("Restore", function() change(id, { gone = false }) end)
    else
      entry("Strike out", function() change(id, { gone = true }) end)
    end
  end)
end

-- An added drop's time: now when the raid holds now, else the end of its last owned kill, else its start.
local function addAt(V)
  local now = M.Compat.call("GetServerTime")
  local start = tonumber(V.ev.start)
  local finish = tonumber(V.ev.finish) or start
  if type(now) == "number" and start and now >= start and now <= finish then return now end
  local last
  for _, p in ipairs(kills(V)) do
    local e = p.at + (tonumber(p.duration) or 0)
    if not last or e > last then last = e end
  end
  return last or start or now
end

-- The item typed or shift-clicked: a link, or an id alone.
local function itemOf(text)
  local Items = ns.Items
  local id, suffix
  if type(Items) == "table" and type(Items.Id) == "function" then id, suffix = Items.Id(text) end
  if id then return id, suffix end
  local n = tonumber(text:match("^%s*(%d+)%s*$"))
  if n and n >= 1 and n <= R.MAXID then return n end
end

-- The box the open line shows: the item box on Add a drop's item step, else the text box.
local function shownBox(V)
  local e = V.edit
  if e and e.field == "add" and e.step == "item" then return V.itemInput end
  return V.input
end

local function closeLine(V)
  V.edit = nil
  M.RefreshPage()
end

local function save(V)
  local e = V.edit
  if not e then return end
  local text = shownBox(V):GetText()
  if type(text) ~= "string" then text = "" end
  e.text = text
  if not allowed() then
    closeLine(V)
    return
  end
  if e.field == "add" then
    if e.step == "item" then
      local id, suffix = itemOf(text)
      if not id then
        say(NOT_ITEM)
        return
      end
      V.edit = { field = "add", step = "who", item = id, suffix = suffix, text = "", focus = true }
      M.RefreshPage()
      return
    end
    local got, why = ns.Loot.Add({ item = e.item, suffix = e.suffix, who = text, at = addAt(V) })
    if not got then
      say("That drop was not added (" .. tostring(why) .. ").")
      return
    end
    closeLine(V)
    return
  end
  V.edit = nil
  change(e.id, { [e.field] = text ~= "" and text or false })
end

-- ---------- the tab ----------

local function tipShow(row)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(row, "ANCHOR_RIGHT")
  if type(tip.SetItemByID) == "function" then tip:SetItemByID(row.tipItem) else tip:SetText(row.tipName) end
  tip:AddLine(row.tipLine)
  tip:Show()
end

local function tipHide()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function build(card)
  local body = card.body
  local V = { rows = {}, wanted = {}, dirty = false }
  card.lootView = V
  V.bar = CreateFrame("Frame", nil, body)
  V.box = CreateFrame("Frame", nil, body)
  V.pane = CreateFrame("Frame", nil, body)
  V.scroll, V.child = ns.ScrollArea(V.pane)
  at(V.child, 0, 0)
  V.empty = ns.Label(V.child, T.highlightSmall)
  V.empty:SetWordWrap(false)
  color(V.empty, ns.GREY)
  V.note = ns.Label(body, T.small)
  V.note:SetWordWrap(false)
  color(V.note, ns.GREY)
  V.count = ns.Label(body, T.small)
  V.count:SetWordWrap(false)
  color(V.count, ns.GREY)
  V.hint = ns.Label(body, T.small)
  V.hint:SetWordWrap(false)
  V.hint:SetText(HINT)
  color(V.hint, ns.GREY)
  V.add = K.Button(body, "Add a drop", ADD_W, function()
    M.Safe(function() if allowed() then openLine(V, { field = "add", step = "item" }) end end)
  end)
  -- the one input line (Reason, Others considered, Type a name, Add a drop), in place of the note while open
  -- the input line: one box for typed text, and one for Add a drop's item step, the only one ns.Items.Box fills
  -- with a shift-clicked link; one of the two shows at a time
  local function lineBox()
    local b = K.InputBox(body, BOX_W, BOX_W)
    if b then
      b:SetScript("OnTextChanged", function(self) if V.edit then V.edit.text = self:GetText() end end)
      b:SetScript("OnEnterPressed", function() M.Safe(save, V) end)
      b:SetScript("OnEscapePressed", function() M.Safe(closeLine, V) end)
    end
    return b
  end
  V.input, V.itemInput = lineBox(), lineBox()
  if V.input and V.itemInput then
    local Items = ns.Items
    if type(Items) == "table" and type(Items.Box) == "function" then Items.Box(V.itemInput) end
    V.save = K.Button(body, "Save", BTN_W, function() M.Safe(save, V) end)
    V.cancel = K.Button(body, "Cancel", BTN_W, function() M.Safe(closeLine, V) end)
  end
  views[#views + 1] = V
  hook()
  return V
end

-- The i-th row of the list (made on first use): a fixed two-line frame with the icon at its left.
local function row(V, i)
  local r = V.rows[i]
  if r then return r end
  r = CreateFrame("Frame", nil, V.child)
  r:EnableMouse(true)
  r.chosen = r:CreateTexture(nil, "BACKGROUND")
  r.chosen:SetAllPoints(r)
  local a = C.active
  r.chosen:SetColorTexture(a[1], a[2], a[3], a[4])
  r.chosen:Hide()
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(ICON, ICON)
  at(r.icon, 2, -3)
  r.name = ns.Label(r, T.highlightSmall)
  r.name:SetWordWrap(false)
  r.word = ns.Label(r, T.small, "RIGHT")
  r.word:SetWordWrap(false)
  color(r.word, ns.GREY)
  r.line = ns.Label(r, T.small)
  r.line:SetWordWrap(false)
  r:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
      local may = ns.MayEdit()
      if self.recId and may == true then M.Safe(rowMenu, V, self) end
    elseif self.recId then
      V.pick = self.recId
      M.RefreshPage()
    end
  end)
  r:SetScript("OnEnter", function(self) if self.recId then M.Safe(tipShow, self) end end)
  r:SetScript("OnLeave", function() M.Safe(tipHide) end)
  V.rows[i] = r
  return r
end

local function head(V, i, y, w, text)
  local r = row(V, i)
  r.recId = nil
  r.chosen:Hide()
  at(r, 0, -y)
  r:SetSize(w, ROW_H)
  r.icon:Hide()
  r.word:Hide()
  r.line:Hide()
  at(r.name, 4, -(ROW_H / 2 - 7))
  r.name:SetWidth(w - 8)
  r.name:SetText(text)
  color(r.name, ns.WHITE)
  r.name:Show()
  r:Show()
end

-- One drop's row; marks is R.Marks of the whole list, size the raid's size by pull. Answers the pick table when it
-- is the chosen row.
local function drop(V, i, y, w, rec, marks, size)
  local r = row(V, i)
  r.recId = rec.id
  at(r, 0, -y)
  r:SetSize(w, ROW_H)
  local id = rec.item
  local Items = ns.Items
  local info = type(Items) == "table" and type(Items.Info) == "function" and Items.Info(id) or nil
  if type(info) ~= "table" then info = nil end
  local name = info and type(info.name) == "string" and info.name or ("item #" .. tostring(id))
  if info and info.loading then V.wanted[id] = true end
  if info and info.icon ~= nil then
    r.icon:SetTexture(info.icon)
    r.icon:Show()
  else
    r.icon:SetTexture(nil)
    r.icon:Hide()
  end
  local q = info and type(info.quality) == "number" and info.quality or rec.q
  local x = ICON + 8
  at(r.name, x, -3)
  r.name:SetWidth(w - x - WORD_W - 8)
  r.name:SetText(esc(name))
  at(r.word, -4, -3, "TOPRIGHT")
  r.word:SetWidth(WORD_W)
  r.word:SetText(R.Word(rec))
  local parts = { esc(R.Winner(rec)) }
  if HOW[rec.how] then parts[#parts + 1] = HOW[rec.how] end
  local m = marks[rec.id] or {}
  if m.state == "held" then parts[#parts + 1] = HELD end
  if m.state == "other" then parts[#parts + 1] = "seen going to " .. esc(m.other) end
  if rec.src == "seen" and m.award then parts[#parts + 1] = "awarded to " .. esc(R.Winner(m.award)) end
  local gone = rec.gone == true
  if rec.src ~= "seen" and not gone and rec.why == nil then
    local council = type(Items) == "table" and type(Items.IsCouncil) == "function" and Items.IsCouncil(rec.item, size[rec.pull])
    if council == true then parts[#parts + 1] = NEEDS end
  end
  at(r.line, x, -18)
  r.line:SetWidth(w - x - 4)
  r.line:SetText(table.concat(parts, DOT))
  if gone then color(r.name, ns.GREY) else nameColour(r.name, q) end
  color(r.line, gone and ns.GREY or ns.WHITE)
  r.name:Show()
  r.word:Show()
  r.line:Show()
  r.tipName, r.tipLine, r.tipItem = esc(name), r.line:GetText(), id
  local chosen = V.pick ~= nil and V.pick == rec.id
  r.chosen:SetShown(chosen)
  r:Show()
  if chosen then return { item = rec.item, suffix = rec.suffix } end
end

-- A slot frame at width w: fn(f, ...) under M.Safe; a number over 0 sizes it, anything else hides it at 0 height.
local function slot(f, name, w, ...)
  f:SetWidth(w)
  local fn = ns[name]
  local h = 0
  if type(fn) == "function" then
    local good, got = M.Safe(fn, f, ...)
    if good and type(got) == "number" and got > 0 and got < math.huge then h = got end
  end
  f:SetHeight(h)
  f:SetShown(h > 0)
  return h
end

local function hideAll(V)
  for _, r in ipairs(V.rows) do r:Hide() end
  V.empty:Hide()
end

-- With ev nil (another tab is shown): before the first draw with an ev nothing is built; after it the tab is hidden
-- and both slots are called with nil so they can hide too.
function ns.DrawLoot(card, ev, layout, top, view)
  local V = rawget(card, "lootView")
  if not ev then
    if not V then return end
    hideAll(V)
    V.pane:Hide()
    V.note:Hide()
    V.count:Hide()
    V.bar:Hide()
    V.box:Hide()
    V.hint:Hide()
    V.add:Hide()
    if V.save then
      V.input:Hide()
      V.itemInput:Hide()
      V.save:Hide()
      V.cancel:Hide()
    end
    if type(ns.DrawLootBar) == "function" then M.Safe(ns.DrawLootBar, V.bar, nil) end
    if type(ns.DrawWants) == "function" then M.Safe(ns.DrawWants, V.box, nil) end
    V.wanted, V.dirty = {}, false
    V.edit = nil -- another tab or another raid cancels the input line
    return
  end
  V = V or build(card)
  hideAll(V)
  V.wanted, V.dirty = {}, false
  local L = layout or ns.Layout()
  local IW = L.viewW - 24
  local LW = IW - SB
  local footY = L.cardH - 24 - 34
  top = top or 0
  if V.key ~= ev.key then
    V.key = ev.key
    V.pick = nil
    V.edit = nil
    V.scroll:SetVerticalScroll(0)
  end
  local list, pulls = sources()
  local events = type(view) == "table" and type(view.events) == "table" and view.events or {}
  V.ev, V.events = ev, events
  local groups = R.ForRaid(list, ev, events, pulls)
  local marks = R.Marks(list, key)
  local size = {}
  for _, p in ipairs(pulls) do
    if type(p) == "table" and p.at ~= nil and type(p.people) == "table" then size[p.at] = #p.people end
  end
  local i, y, pick = 0, 0, nil
  local function rows(recs)
    for _, rec in ipairs(recs) do
      i = i + 1
      pick = drop(V, i, y, LW, rec, marks, size) or pick
      y = y + ROW_H
    end
  end
  for _, g in ipairs(groups) do
    i = i + 1
    head(V, i, y, LW, esc(g.boss or "?"))
    y = y + ROW_H
    rows(g.rows)
  end
  if #groups.trash.rows > 0 then
    i = i + 1
    head(V, i, y, LW, "Trash")
    y = y + ROW_H
    rows(groups.trash.rows)
  end
  if i == 0 then
    at(V.empty, 4, -6)
    V.empty:SetWidth(LW - 8)
    V.empty:SetText(EMPTY)
    V.empty:Show()
    y = 24
  end
  if pick == nil then V.pick = nil end
  V.child:SetWidth(LW)
  V.child:SetHeight(math.max(10, y))
  -- the bar above the list, the box under it, then the note and the count line at the foot
  at(V.bar, 12, -top)
  local barH = slot(V.bar, "DrawLootBar", LW, ev)
  local boxH = slot(V.box, "DrawWants", LW, ev, pick)
  at(V.box, 12, -(footY - 6 - boxH))
  local listTop = top + (barH > 0 and barH + 4 or 0)
  local listBottom = footY - 6 - (boxH > 0 and boxH + 4 or 0)
  local listH = math.max(1, listBottom - listTop)
  at(V.pane, 12, -listTop)
  V.pane:SetSize(IW, listH)
  V.pane:Show()
  at(V.scroll, 0, 0)
  V.scroll:SetSize(LW, listH)
  -- an editor's foot: the hint after the note and Add a drop at the right; the input line takes the note's place
  local may = ns.MayEdit()
  local editing = may == true and V.edit ~= nil and V.input ~= nil and V.itemInput ~= nil
  if not editing then V.edit = nil end
  at(V.note, 12, -footY)
  V.note:SetWidth(may == true and NOTE_W or IW)
  V.note:SetText(NOTE)
  V.note:SetShown(not editing)
  at(V.hint, 12 + NOTE_W, -footY)
  V.hint:SetWidth(IW - NOTE_W - ADD_W - 8)
  V.hint:SetShown(may == true and not editing)
  at(V.add, 12 + IW - ADD_W, -(footY - 4))
  V.add:SetShown(may == true and not editing)
  if V.save then
    at(V.input, 18, -(footY - 4))
    at(V.itemInput, 18, -(footY - 4))
    at(V.save, 18 + BOX_W + 8, -(footY - 4))
    at(V.cancel, 18 + BOX_W + 8 + BTN_W + 6, -(footY - 4))
    local box = editing and shownBox(V) or nil
    V.input:SetShown(box == V.input)
    V.itemInput:SetShown(box == V.itemInput)
    V.save:SetShown(editing)
    V.cancel:SetShown(editing)
    if editing then
      if box:GetText() ~= V.edit.text then box:SetText(V.edit.text) end
      if V.edit.focus then
        V.edit.focus = nil
        box:SetMaxLetters(LIMIT[V.edit.step or V.edit.field] or LIMIT.item)
        box:SetFocus()
      end
    end
  end
  at(V.count, 12, -(footY + 16))
  V.count:SetWidth(IW)
  V.count:SetText(string.format("%d drops on this character. At most %d are kept, for %d days.", #list, R.CAP, R.KEEP / 86400))
  V.count:Show()
end
