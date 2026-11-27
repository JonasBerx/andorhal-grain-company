local _, ns = ...
if not ns.M then return end

-- My wish list (ticket 58, wave 1): the "wish" owner card (Page.lua's ns.Cards contract), then the two slots other
-- views call, ns.YouWish (the "You tonight" cell) and ns.DrawWants (who on a raid wants an item). The card shows the
-- last-changed line, the entry box (Paste.lua's multi-line form, in entryBox only: the kit has no multi-line input),
-- Add, the sentence and the lines it could not read, then one row per item: icon, name, slot, the spec button, Up,
-- Down and Remove. Every edit goes through ns.WishRules, then ns.WishSave, then a redraw. ns.Items, ns.WishMine,
-- ns.WishSave and ns.Wants are looked up at call time. Nothing here is protected, so an edit works in combat.
-- Every pasted or other player's text goes through ns.Escape.

local M, R = ns.M, ns.WishRules
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only (made on the first read)
local HINT = "Click here, then shift-click an item; or paste item links, ids or Wowhead links (one or more a line) and press Add."
local NOBODY = "Nobody on this raid wants it."
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local ROW_H = 44 -- one row: the name line over the slot and the buttons
local LINE_H = 14

local P = { rows = {}, typed = "" } -- the card's frames, its pooled rows and the text the player last typed
local writing = false -- set while the card itself writes the entry box, so OnTextChanged skips it

local function now()
  local t = M.Compat.call("GetServerTime")
  return tonumber(t) or 0
end
local function esc(s) return ns.Escape(tostring(s or "")) end

local function mine()
  local fn = ns.WishMine
  local list = type(fn) == "function" and fn() or nil
  if type(list) ~= "table" or type(list.items) ~= "table" then return R.Empty() end
  return list
end

-- ns.Items[name] when it is a function, else nil; looked up at each call.
local function itemsFn(name)
  local Items = ns.Items
  local fn = type(Items) == "table" and Items[name] or nil
  return type(fn) == "function" and fn or nil
end

-- The item's name, icon and slot text: ns.Items.Info's answer, else "item #<id>" and the question mark.
local function itemOf(id)
  local Info = itemsFn("Info")
  local info = Info and Info(id) or nil
  if type(info) ~= "table" then return "item #" .. tostring(id), QMARK, "" end
  local slot = type(info.slot) == "string" and _G[info.slot] or nil
  return esc(info.name or ("item #" .. tostring(id))), info.icon or QMARK, type(slot) == "string" and slot or ""
end

-- Writes the entry box under the writing flag; the flag is cleared even when SetText throws.
local function setText(box, text)
  writing = true
  local good, err = pcall(box.SetText, box, text)
  writing = false
  if not good then error(err, 0) end
end

-- ---------- the card ----------

local function drawChanged(list)
  P.changed:SetText(list.changed and ("Changed " .. ns.When("%a %d %b %H:%M", list.changed)) or "Changed: never")
end

-- One pooled row on the list's scroll child: icon, name, slot and the four buttons. row.i is set at each draw.
local function edit(row, op)
  local list = mine()
  local out
  if op == "spec" then
    local item = list.items[row.i]
    out = item and R.SetSpec(list, row.i, item.spec == "m" and "o" or "m", now())
  elseif op == "remove" then
    out = R.Remove(list, row.i, now())
  else
    out = R.Move(list, row.i, op == "up" and -1 or 1, now())
  end
  if not out then return end -- an edge move or a stale index: nothing changes
  local saved, why = ns.WishSave(out)
  P.sentence:SetText(saved and "" or ("Not saved (" .. tostring(why) .. ")."))
  P.redraw()
end

local function button(parent, text, w, fn)
  local b = K.Button(parent, text, w)
  b:SetScript("OnClick", function() M.Safe(fn) end)
  return b
end

local function rowAt(i)
  local row = P.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, P.child)
  row:SetHeight(ROW_H)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(36, 36)
  row.icon:SetPoint("TOPLEFT", 0, -4)
  row.name = ns.Label(row)
  row.name:SetPoint("TOPLEFT", 42, -4)
  row.name:SetPoint("TOPRIGHT", 0, -4)
  row.name:SetWordWrap(false)
  row.remove = button(row, "Remove", 64, function() edit(row, "remove") end)
  row.remove:SetPoint("TOPRIGHT", 0, -20)
  row.down = button(row, "Down", 50, function() edit(row, "down") end)
  row.down:SetPoint("TOPRIGHT", row.remove, "TOPLEFT", -4, 0)
  row.up = button(row, "Up", 40, function() edit(row, "up") end)
  row.up:SetPoint("TOPRIGHT", row.down, "TOPLEFT", -4, 0)
  row.spec = button(row, "Main spec", 76, function() edit(row, "spec") end)
  row.spec:SetPoint("TOPRIGHT", row.up, "TOPLEFT", -4, 0)
  row.slot = ns.Label(row, T.highlightSmall)
  row.slot:SetPoint("TOPLEFT", 42, -24)
  row.slot:SetPoint("TOPRIGHT", row.spec, "TOPLEFT", -6, -4)
  row.slot:SetTextColor(C.grey[1], C.grey[2], C.grey[3])
  -- "have it": shown only for an item the last possession check found held (item.has == true)
  row.have = ns.Label(row, T.highlightSmall, "RIGHT")
  row.have:SetPoint("TOPRIGHT", row.spec, "TOPLEFT", -6, -4)
  row.have:SetTextColor(C.green[1], C.green[2], C.green[3])
  row.have:SetText("have it")
  P.rows[i] = row
  return row
end

local function drawRows()
  local list = mine()
  for i, item in ipairs(list.items) do
    local row = rowAt(i)
    row.i = i
    local name, icon, slot = itemOf(item.id)
    row.icon:SetTexture(icon)
    row.name:SetText(name)
    row.slot:SetText(slot)
    row.have:SetShown(item.has == true)
    -- the slot text ends left of "have it" when it shows, else left of the spec button
    row.slot:ClearAllPoints()
    row.slot:SetPoint("TOPLEFT", 42, -24)
    if item.has == true then
      row.slot:SetPoint("TOPRIGHT", row.have, "TOPLEFT", -4, 0)
    else
      row.slot:SetPoint("TOPRIGHT", row.spec, "TOPLEFT", -6, -4)
    end
    row.spec:SetText(item.spec == "o" and "Off spec" or "Main spec")
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", P.child, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", P.child, "TOPRIGHT", 0, -(i - 1) * ROW_H)
    row:Show()
  end
  for i = #list.items + 1, #P.rows do P.rows[i]:Hide() end
  P.child:SetHeight(math.max(10, #list.items * ROW_H))
  drawChanged(list)
end

-- Stacks the unread lines and the list under the Add line at the last layout.
local function place()
  local L = P.layout
  if not L then return end
  local IW = L.viewW - 24
  P.hint:SetWidth(IW)
  P.sentence:SetWidth(IW - 90)
  P.unread:SetWidth(IW)
  local top = 158
  if P.unread:IsShown() then top = top + P.unreadLines * LINE_H + 6 end
  P.scroll:ClearAllPoints()
  P.scroll:SetPoint("TOPLEFT", 12, -top)
  P.scroll:SetPoint("BOTTOMRIGHT", -34, 12)
end

function P.redraw()
  drawRows()
  place()
end

-- Reads text and adds what it found: the sentence, and the lines it could not read under it.
local function addText(text)
  local read = R.ReadPaste(text)
  local list, report = R.Add(mine(), read.ids, "m", now())
  local sentence = R.Sentence(report)
  if list and report.added > 0 then
    local saved, why = ns.WishSave(list)
    if not saved then sentence = "Not saved (" .. tostring(why) .. ")." end
  end
  P.sentence:SetText(sentence or "")
  local lines = {}
  for _, line in ipairs(read.unread) do lines[#lines + 1] = esc(line) end
  if read.more > 0 then lines[#lines + 1] = "and " .. read.more .. " more" end
  if #lines > 0 then
    P.unread:SetText("Not read (no item link or id):\n" .. table.concat(lines, "\n"))
    P.unreadLines = #lines + 1
  end
  P.unread:SetShown(#lines > 0)
  P.redraw()
end

-- Add and Enter: read the whole box, then empty it.
local function add()
  addText(P.box:GetText() or "")
  P.typed = ""
  setText(P.box, "")
end

-- Typed text is only remembered. A fill that is not the player's typing (a shift-click through ns.Items.Box) and
-- holds an item link is added, then the typed text goes back in the box.
local function onTextChanged(self, userInput)
  local text = self:GetText() or ""
  if userInput then P.typed = text return end
  if not text:find("|Hitem:", 1, true) then return end
  addText(text)
  setText(self, P.typed)
end

-- The entry box: the Inset with the kit's pillBg fill and Paste.lua's multi-line EditBox as the scroll child (the
-- kit has no multi-line input; this is the one place the card keeps the old form).
local function entryBox(body, level)
  local inset = K.Inset(body) or CreateFrame("Frame", nil, body)
  inset:SetFrameLevel(level)
  local fill = inset:CreateTexture(nil, "ARTWORK")
  fill:SetAllPoints(inset)
  fill:SetColorTexture(C.pillBg[1], C.pillBg[2], C.pillBg[3], C.pillBg[4])
  local scroll, spare = ns.ScrollArea(inset)
  scroll:SetPoint("TOPLEFT", 8, -7)
  scroll:SetPoint("BOTTOMRIGHT", -22, 7)
  spare:Hide()
  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetMaxLetters(0)
  box:SetAutoFocus(false)
  box:SetFontObject("ChatFontNormal")
  box:SetWidth(400)
  scroll:SetScrollChild(box)
  scroll:SetScript("OnSizeChanged", function(_, w) if w then box:SetWidth(w) end end)
  return inset, box
end

local function build(card)
  local body = card.body
  P.host = card
  P.title = ns.Label(body, T.normal)
  P.title:SetPoint("TOPLEFT", 12, -26)
  P.title:SetText("My wish list")
  P.changed = ns.Label(body, T.highlightSmall, "RIGHT")
  P.changed:SetPoint("TOPRIGHT", -12, -27)
  P.hint = ns.Label(body, T.highlightSmall)
  P.hint:SetPoint("TOPLEFT", 12, -46)
  P.hint:SetText(HINT)
  P.inset, P.box = entryBox(body, card:GetFrameLevel() + 1)
  P.inset:SetPoint("TOPLEFT", 12, -64)
  P.box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  P.box:SetScript("OnEnterPressed", function() M.Safe(add) end)
  P.box:SetScript("OnTextChanged", function(self, userInput)
    if writing then return end
    M.Safe(onTextChanged, self, userInput)
  end)
  P.add = button(body, "Add", 80, add)
  P.add:SetPoint("TOPRIGHT", -12, -132)
  P.sentence = ns.Label(body)
  P.sentence:SetPoint("TOPLEFT", 12, -136)
  P.unread = ns.Label(body, T.highlightSmall)
  P.unread:SetJustifyV("TOP")
  P.unread:SetPoint("TOPLEFT", 12, -158)
  P.unread:Hide()
  P.unreadLines = 0
  local spare
  P.scroll, spare = ns.ScrollArea(body)
  P.child = spare
  local Box, OnLoad = itemsFn("Box"), itemsFn("OnLoad")
  if Box then Box(P.box) end
  if OnLoad then OnLoad(function() if P.host:IsShown() then P.redraw() end end) end
end

local function draw(card, view, rows, t, layout)
  if not P.box then return end
  P.layout = layout
  P.inset:SetSize(layout.viewW - 24, 60)
  P.redraw()
end

ns.Cards.wish = { build = build, draw = draw }

-- ---------- the slots other views call ----------

-- A view event (RaidView's shape): a table with a signups list.
local function isEvent(ev) return type(ev) == "table" and type(ev.signups) == "table" end

-- The "You tonight" cell: nil for an empty list or a bad ev, else "wish list: <n> item(s)".
function ns.YouWish(ev)
  if not isEvent(ev) then return nil end
  local n = #mine().items
  if n == 0 then return nil end
  return "wish list: " .. n .. (n == 1 and " item" or " items")
end

local slots = setmetatable({}, { __mode = "k" }) -- box -> what DrawWants made in it and its last pick
local BOX_H = 28 -- the item box line: the box and "Say in raid"
local SHOWN = 3 -- wanter lines at most; the rest are counted on the title line (98 px in all)
local DOT = " \194\183 "
local SLOT_HINT = "Click a drop, or shift-click an item here, to see who wants it."
local SAY_MAX = 255 - #"/raid " -- the chat line, so the filled text with "/raid " fits 255 bytes
local ANSWER = { sent = "Sent to raid chat.", filled = "In your chat box: press Enter to send.",
  ["not in a raid"] = "Not in a raid.", demo = "Demo: nothing is said." }

local function hideSlot(s)
  s.input:Hide()
  s.say:Hide()
  s.title:Hide()
  s.hint:Hide()
  s.count:Hide()
  s.nobody:Hide()
  for _, fs in ipairs(s.rows) do fs:Hide() end
end

-- One non-wrapping 14 px line of the slot at y, across its width.
local function line(box, y)
  local fs = ns.Label(box)
  fs:SetWordWrap(false)
  fs:SetHeight(LINE_H)
  fs:SetPoint("TOPLEFT", 8, -y)
  fs:SetPoint("TOPRIGHT", -8, -y)
  return fs
end

-- Clears the item box under the writing flag (setText clears the flag even when SetText throws).
local function clearBox(s)
  if (s.input:GetText() or "") ~= "" then setText(s.input, "") end
end

-- "Say in raid": the item as text, every wanter shown or not, one line through ns.SayLine; the answer shows in
-- the count line's place (the title keeps the item). The item text is the link the last draw read from the box
-- only when R.WholeLink accepted it and its bracket text is the loaded item's own name; else the plain name
-- escaped, else "item <id>" before it loads.
local function say(s)
  local cur = s.cur
  if not cur then return end
  local Info = itemsFn("Info")
  local info = Info and Info(cur.id) or nil
  local name = type(info) == "table" and info.name or nil
  -- Items.Info names an item not loaded yet "item #<id>"; the chat line says "item <id>" then
  if type(name) ~= "string" or name == "" or info.loading == true or name == "item #" .. cur.id then name = nil end
  local text
  if name and cur.link and cur.link:match("|h%[(.-)%]|h") == name then text = cur.link end
  text = text or (name and esc(name)) or ("item " .. cur.id)
  local said, why = R.SayLine(text, cur.rows, SAY_MAX, ns.PackLines)
  if said and type(ns.SayLine) == "function" then
    why = select(2, ns.SayLine("RAID", said))
  elseif said then
    why = "no chat"
  end
  s.answer = { id = cur.id, text = ANSWER[why] or ("Not said (" .. tostring(why) .. ").") }
  s.count:SetText(s.answer.text)
  s.count:Show()
end

local function buildSlot(box)
  local s = { rows = {} }
  s.input = K.InputBox(box, 200, 200)
  s.input:SetPoint("TOPLEFT", 8, -4)
  s.input:SetAutoFocus(false)
  s.input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  s.input:SetScript("OnTextChanged", function()
    if writing or not s.ev then return end
    s.answer = nil -- a new item drops the answer and brings the count line back
    M.Safe(function()
      ns.DrawWants(box, s.ev, s.pick)
      M.RefreshPage()
    end)
  end)
  s.say = button(box, "Say in raid", 90, function() say(s) end)
  s.say:SetPoint("TOPRIGHT", -4, -3)
  s.title = line(box, BOX_H)
  s.hint = line(box, BOX_H)
  s.hint:SetText(SLOT_HINT)
  s.nobody = line(box, BOX_H + LINE_H)
  s.nobody:SetText(NOBODY)
  s.count = line(box, BOX_H + LINE_H)
  local Box = itemsFn("Box")
  if Box then Box(s.input) end
  return s
end

-- The pick rule: a new pick (another item or suffix) is stored first, then clears the box, so a text change fired
-- by the clear redraws the same pick and does not clear again; a draw with no pick, or for another raid, forgets the
-- last pick. (box, nil) keeps it: a tab switch is not a new pick.
local function takePick(s, ev, pick)
  if ev.key ~= s.key then s.key, s.lastPick = ev.key, nil end
  if type(pick) ~= "table" then s.lastPick = nil return end
  local last = s.lastPick
  if last and last.item == pick.item and last.suffix == pick.suffix then return end
  s.lastPick = { item = pick.item, suffix = pick.suffix }
  s.answer = nil
  clearBox(s)
end

-- "<name>  #<position> · main spec|off spec[ · has it][ · list <age> old]"
local function wanterText(w, t)
  local out = esc(w.name) .. "  #" .. tostring(tonumber(w.position) or "?") .. DOT
    .. (w.spec == "o" and "off spec" or "main spec")
  if w.has == true then out = out .. DOT .. "has it" end
  local Rules = ns.Rules
  local dur = type(Rules) == "table" and Rules.Duration or nil
  if type(w.changed) == "number" and type(dur) == "function" then out = out .. DOT .. "list " .. dur(t - w.changed) .. " old" end
  return out
end

-- Who wants the item among ev's sign-ups (everyone when ev has none), in ns.Wants's order: the item in the box when
-- it holds one, else the picked drop. A sign-up of kind "absence" (signed off) is left out; every other kind counts.
-- Names (unescaped from ns.Wants) are escaped here. A change of the item box redraws for the ev and pick last drawn,
-- then M.RefreshPage lets the host lay out the new height; the slot writes the box only under the writing flag, so
-- this cannot loop. Lines: the box line, the title (or the hint with no item), at most 3 wanter lines (or the nobody
-- line) and the count line, so at most 98 px. -> the height drawn; (box, nil) or a bad ev hides it all and answers 0.
function ns.DrawWants(box, ev, pick)
  if type(box) ~= "table" then return 0 end
  local s = slots[box]
  if not isEvent(ev) then
    if s then s.ev = nil hideSlot(s) end
    return 0
  end
  if not s then
    s = buildSlot(box)
    slots[box] = s
  end
  s.ev, s.pick = ev, pick
  takePick(s, ev, pick)
  s.input:SetWidth(math.max(40, (box:GetWidth() or 320) - 112))
  local Id = itemsFn("Id")
  local boxText = s.input:GetText() or ""
  local boxId = Id and Id(boxText) or nil
  local id = boxId or (type(pick) == "table" and R.ValidId(pick.item) and pick.item) or nil
  hideSlot(s)
  s.input:Show()
  s.say:Show()
  s.cur = nil
  if not id then
    s.say:SetEnabled(false)
    s.hint:Show()
    return BOX_H + LINE_H
  end
  local wants = type(ns.Wants) == "function" and ns.Wants(id) or nil
  local signed, m = {}, 0
  for _, su in ipairs(ev.signups) do
    if type(su) == "table" and su.key and su.kind ~= "absence" and not signed[su.key] then
      signed[su.key] = true
      m = m + 1
    end
  end
  local all = #ev.signups == 0
  local t = now()
  local rows, n = {}, 0
  for _, w in ipairs(type(wants) == "table" and wants or {}) do
    if type(w) == "table" and (all or signed[w.key]) then
      n = n + 1
      rows[n] = { name = esc(w.name), spec = w.spec, has = w.has }
      if n <= SHOWN then
        local fs = s.rows[n] or line(box, BOX_H + n * LINE_H)
        s.rows[n] = fs
        fs:SetText(wanterText(w, t))
        fs:Show()
      end
    end
  end
  local name = itemOf(id)
  s.cur = { id = id, name = name, rows = rows, link = boxId and R.WholeLink(boxText) or nil }
  if s.answer and s.answer.id ~= id then s.answer = nil end
  s.title:SetText("Who wants " .. name .. (n > SHOWN and (" (and " .. (n - SHOWN) .. " more want it)") or ""))
  s.title:Show()
  s.nobody:SetShown(n == 0)
  local lines = math.max(1, math.min(n, SHOWN))
  local h = BOX_H + LINE_H + lines * LINE_H
  -- The count line's place (always 14 px, so a click answer never changes the height): the answer until the next
  -- pick or item, else the count; empty when there is no ns.WishHolders.
  s.count:ClearAllPoints()
  s.count:SetPoint("TOPLEFT", 8, -h)
  s.count:SetPoint("TOPRIGHT", -8, -h)
  local holdersFn = ns.WishHolders
  local text = ""
  if s.answer then
    text = s.answer.text
  elseif type(holdersFn) == "function" then
    local holders = holdersFn()
    if type(holders) ~= "table" then holders = {} end
    local have = 0
    for key in pairs(signed) do if holders[key] then have = have + 1 end end
    text = m == 0 and "No sign-ups to count yet."
      or (have .. " of " .. m .. " signed up have a wish list; " .. (m - have) .. " have none.")
  end
  s.count:SetText(text)
  s.count:SetShown(text ~= "")
  h = h + LINE_H
  local mayEdit = ns.MayEdit
  s.say:SetEnabled(type(mayEdit) == "function" and mayEdit() == true and n > 0 and type(ns.SayLine) == "function")
  return h
end
