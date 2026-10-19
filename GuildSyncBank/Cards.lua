-- GuildSyncBank cards: the one card builder every Bank tab draws with (bank/cards.md C1, C2), on the hub's M.Kit (t54).
--   ns.Cards.List(holder, formH) -> ui  a scroll frame (ScrollFrameTemplate with its bar in the mock's column when the
--                                      client has ScrollUtil.InitScrollFrameWithScrollBar, else UIPanelScrollFrameTemplate)
--                                      and its scroll child (ui.scroll, ui.list); ui.form is a formH-tall frame at the top
--                                      of the scroll child, and the cards start 8 below it (at 0 when formH is 0)
--   ns.Cards.Resize(pageW) -> changed  every list's width = pageW - 18 (only when pageW > 18); the page redraws on true
--   ns.Cards.Width(ui)                 the list's width (LIST_W from Cards.List until a Resize)
--   ns.Cards.Begin(ui) / End(ui)       start a redraw (hides every pooled card, header and line) / finish it (the
--                                      scroll child's height is the sum of the rows drawn)
--   ns.Cards.Section(ui, text), Line(ui, text), Card(ui, spec)   draw an M.Kit.SectionHeader, a grey line, a card
--   ns.Cards.FormCard(parent, title), ItemBox(parent, width, hint), Box(parent, width, hint)   a tab's form pieces
--   ns.Cards.StripNeed(strip), Ago(now, t), Fit(fs, full, short)
--   ns.Cards.Hint(box, text)           a grey hint inside an edit box (a strip box takes strip.hint)
--   ns.Cards.Grey(fs), GOLD_CODE, QMARK   the grey text colour, gold as an inline code, the no-icon icon
-- A card is an M.Kit.Card with an M.Kit.ItemButton (nothing written onto it: the item id and tooltip lines live on the
-- card), an M.Kit.Pill, an M.Kit.StatBar holding two StatusBars of its own (amber value+extra under green value, the
-- text above both) and an M.Kit.Divider over the strip. A kit piece that answers nil is skipped (a card falls back to
-- a plain frame). Every script handed to the game runs through M.Safe.
-- Layout: req/strip/plain/filled cards are queued and placed when their group closes (a Section, a Line, a tile or
-- contrib card, End). A group takes two columns from a list width of TWO_COL_MIN unless one of its strips needs more
-- than a column (StripNeed), so no strip control ever leaves its card. Tiles go four to a row, contrib rows one.
-- Every text line has two horizontal anchors inside its card and does not wrap. Cards never escape text: every string
-- in a spec arrives escaped. Restyling the Bank page means changing this file only.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local K = M.Kit
local Cards = {}
ns.Cards = Cards

Cards.H = { req = 116, strip = 92, plain = 56, filled = 80, tile = 52, contrib = 34, header = 26, line = 22 }
Cards.LIST_W = 708 -- the Bank list at the default 900 window (900 - 158 - 8 - 26); Width() before any size
Cards.TWO_COL_MIN = 560
Cards.PAD_L, Cards.PAD_R, Cards.GAP, Cards.LABEL_MIN = 12, 10, 6, 40

local H, PAD_L, PAD_R, GAP = Cards.H, Cards.PAD_L, Cards.PAD_R, Cards.GAP
local COL_GAP, TILE_GAP, CONTRIB_GAP, TILES = 10, 8, 4, 4
local ITEM, LINE_H, BUTTON_H, STRIP_H = 37, 14, 22, 32
local BAR_TOP = 7 -- the StatBar's fill sits 7 below its top: the bar is anchored that much above the line it fills
local TITLE_Y, SUB_Y, ROW_Y = 7, { 24, 38 }, 10
local WHEN_W = 60
local RANK_W, NAME_W, RIGHT_W = 24, 176, 80
local NAME_X = PAD_L + RANK_W + 14 -- a contribution row's name starts at 50 (bk-6)
local HEADER_GAP = 6 -- under a section header when a card group follows it (the mock's header + 32); none before a line
local BUTTON_W = 80 -- a strip button's width when its spec names none
local SCROLL_R = 18 -- the list's right margin, where the scroll bar sits

-- the hub's colours (GuildSync/Window.lua)
local GOLD = { 1, 0.82, 0 }
local PANEL_BG = { 0, 0, 0, 0.3 }
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GREY = { 0.72, 0.72, 0.72 }
local QUIET_TITLE = { 0.6, 0.6, 0.6 }
local WHITE = { 1, 1, 1 }
local GREEN = { 0.2, 0.75, 0.25 }
local AMBER = { 0.9, 0.6, 0.1 }
-- item quality colours (the game's own values), so no new API is needed
local QUALITY = { [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 },
  [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }

Cards.GOLD_CODE = "|cffffd100" -- GOLD as an inline colour code, for a gold word inside a grey line
Cards.QMARK = "Interface\\Icons\\INV_Misc_QuestionMark" -- the icon under a count when the item has no icon file id

local function colour(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end
function Cards.Grey(fs) colour(fs, GREY) end
local function tex(parent, layer, c)
  local t = parent:CreateTexture(nil, layer)
  t:SetColorTexture(c[1], c[2], c[3], c[4])
  return t
end
local function text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end
-- a text line from x1 to x2 at y (both x measured from the card's left when fromLeft, else from its right edge)
local function span(fs, card, y, x1, left1, x2, left2)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", card, left1 and "TOPLEFT" or "TOPRIGHT", x1, -y)
  fs:SetPoint("TOPRIGHT", card, left2 and "TOPLEFT" or "TOPRIGHT", x2, -y)
end

function Cards.Ago(now, t)
  if type(t) ~= "number" then return "never" end
  local s = math.max(0, now - t)
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  if s < 86400 then return math.floor(s / 3600) .. "h ago" end
  return math.floor(s / 86400) .. "d ago"
end

-- a FontString's text width: GetUnboundedStringWidth when it answers a number above 0 (GetStringWidth can answer the
-- cut-off width of a line anchored on both sides), else GetStringWidth; nil when neither answers a number
function Cards.TextWidth(fs)
  local u = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()
  if type(u) == "number" and u > 0 then return u end
  local sw = fs:GetStringWidth()
  if type(sw) == "number" then return sw end
  return nil
end

function Cards.Fit(fs, full, short)
  fs:SetText(full)
  local sw, w = Cards.TextWidth(fs), fs:GetWidth()
  if type(sw) == "number" and type(w) == "number" and w > 0 and sw > w then fs:SetText(short) end
end

-- a strip label's width in the strip label font, measured once per text on a scratch FontString (Cards.scratch, made
-- on first use, outside every card); LABEL_MIN when the client cannot measure yet (GetStringWidth missing or 0)
local labelW = {}
local function labelWidth(label)
  if labelW[label] then return labelW[label] end
  if not Cards.scratch then
    local holder = CreateFrame("Frame")
    holder:Hide()
    Cards.scratch = text(holder, "GameFontHighlightSmall")
  end
  Cards.scratch:SetText(label)
  local sw = Cards.scratch:GetStringWidth()
  if type(sw) ~= "number" or sw <= 0 then return Cards.LABEL_MIN end
  labelW[label] = math.max(Cards.LABEL_MIN, math.ceil(sw))
  return labelW[label]
end

function Cards.StripNeed(strip)
  local need = PAD_L + (strip.label and labelWidth(strip.label) + GAP or 0) + (strip.box and strip.box + GAP or 0) + PAD_R
  local buttons = strip.buttons or {}
  for _, b in ipairs(buttons) do need = need + (b[3] or BUTTON_W) end
  if #buttons > 1 then need = need + GAP * (#buttons - 1) end
  return need
end

-- A grey hint inside an InputBoxTemplate box, hidden while the box has text or focus. Hooks (never replaces) the box's
-- OnTextChanged, focus and OnHide scripts; box.hint is the FontString and box.hintUpdate() redraws it after a SetText.
-- Call it after the box's own SetScript calls: a later SetScript replaces the hook.
function Cards.Hint(box, hint)
  local fs = text(box, "GameFontHighlightSmall")
  fs:SetPoint("LEFT", box, "LEFT", 2, 0)
  fs:SetPoint("RIGHT", box, "RIGHT", -2, 0)
  colour(fs, GREY)
  fs:SetText(hint or "")
  local focused = false
  local function update()
    local t = box:GetText()
    fs:SetShown(not focused and (type(t) ~= "string" or t == ""))
  end
  local function set(on) focused = on update() end
  box:HookScript("OnTextChanged", function() M.Safe(update) end)
  box:HookScript("OnEditFocusGained", function() M.Safe(set, true) end)
  box:HookScript("OnEditFocusLost", function() M.Safe(set, false) end)
  box:HookScript("OnHide", function() M.Safe(set, false) end)
  box.hint, box.hintUpdate = fs, update
  update()
  return fs
end

-- ---------- a tab's form pieces ----------

-- A 60-tall M.Kit.Card (a plain frame when the kit answers nil) on both top corners of parent (the list's form), so it
-- is as wide as the list, with a gold GameFontNormal title at (12,-8).
function Cards.FormCard(parent, title)
  local card = K.Card(parent, Cards.LIST_W, 60) or CreateFrame("Frame", nil, parent)
  card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  card:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
  card:SetHeight(60)
  local fs = text(card, "GameFontNormal")
  fs:SetPoint("TOPLEFT", card, "TOPLEFT", PAD_L, -8)
  fs:SetPoint("TOPRIGHT", card, "TOPRIGHT", -PAD_R, -8)
  fs:SetText(title or "")
  colour(fs, GOLD)
  card.title = fs
  return card
end

-- Enter lets go of the box and submits nothing (hooked: a template's own Enter still runs)
local function enterClears(box)
  box:HookScript("OnEnterPressed", function(self) M.Safe(function() self:ClearFocus() end) end)
end

-- an InputBoxTemplate box width x 20 with Cards.Hint, Enter clears focus: the fallback of both boxes below
local function plainBox(parent, width, hint)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  Cards.Hint(box, hint)
  enterClears(box)
  return box
end

-- An item entry box: an M.Kit.SearchBox (the magnifier) with the hint as its instructions, grey as Cards.Hint's;
-- without the template an InputBoxTemplate box with Cards.Hint.
function Cards.ItemBox(parent, width, hint)
  local box = K.SearchBox(parent, width, hint)
  if not box then return plainBox(parent, width, hint) end
  box:SetAutoFocus(false)
  local ins = box.Instructions
  if type(ins) == "table" and type(ins.SetTextColor) == "function" then colour(ins, GREY) end
  return box
end

-- An edit box: M.Kit.InputBox (InputBoxInstructionsTemplate, else InputBoxTemplate) with Cards.Hint;
-- Enter clears focus.
function Cards.Box(parent, width, hint)
  local box = K.InputBox(parent, width, width)
  if not box then return plainBox(parent, width, hint) end
  box:SetAutoFocus(false)
  Cards.Hint(box, hint)
  enterClears(box)
  return box
end

-- ---------- the list ----------

local lists = {} -- every ui List made, for Resize
local listW -- the width the last Resize set; nil before any

-- The scroll frame fills the holder but its right SCROLL_R px. With the modern scroll API Forever's ScrollFrameTemplate
-- builds and joins its MinimalScrollBar; the bar moves to the mock's column (10 px right of the list) and stays shown
-- on a tab that does not scroll. Otherwise 0.1's UIPanelScrollFrameTemplate. A formH below 1 means no form.
function Cards.List(holder, formH)
  formH = (type(formH) == "number" and formH > 0) and formH or 0
  local modern = GuildSync.Compat.Has("ScrollUtil.InitScrollFrameWithScrollBar")
  local scroll = CreateFrame("ScrollFrame", nil, holder, modern and "ScrollFrameTemplate" or "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -SCROLL_R, 0)
  local bar = modern and scroll.ScrollBar
  if type(bar) == "table" then
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 10, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 10, 0)
    if type(bar.SetHideIfUnscrollable) == "function" then bar:SetHideIfUnscrollable(false) end
  end
  local list = CreateFrame("Frame", nil, scroll)
  list:SetHeight(1)
  list:SetWidth(listW or Cards.LIST_W) -- LIST_W until the first Resize
  scroll:SetScrollChild(list)
  local form = CreateFrame("Frame", nil, list)
  form:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
  form:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
  form:SetHeight(formH)
  local ui = { scroll = scroll, list = list, form = form, top = formH > 0 and formH + 8 or 0,
    cards = {}, heads = {}, lines = {}, q = {} }
  lists[#lists + 1] = ui
  return ui
end

-- Every list's width to pageW - SCROLL_R (only when pageW > SCROLL_R). True when the width changed: the page then
-- redraws (Resize itself draws nothing).
function Cards.Resize(pageW)
  if type(pageW) ~= "number" or pageW <= SCROLL_R then return false end
  local w = pageW - SCROLL_R
  local changed = w ~= listW
  listW = w
  for _, ui in ipairs(lists) do
    if ui.list:GetWidth() ~= w then
      ui.list:SetWidth(w)
      changed = true
    end
  end
  return changed
end

function Cards.Width(ui)
  local w = ui.list:GetWidth()
  if type(w) == "number" and w > 0 then return w end
  return Cards.LIST_W
end

-- The pill right after the title (C5): the title is as wide as its text, at most what is left before "when" minus the
-- pill and 6 px; the pill's left edge is 6 px past the title. Without a measured string width (the sim, or text not laid
-- out yet) the pill stays where fill put it, right-aligned before "when".
local function placePill(card, cardW)
  local at = card.pillAt
  if type(at) ~= "table" then return end
  local sw = Cards.TextWidth(card.title)
  if type(sw) ~= "number" or sw <= 0 or type(cardW) ~= "number" or cardW <= 0 then return end
  local room = cardW + at.right - at.x0 - at.w - 6 -- at.right is measured from the card's right edge (negative)
  if room <= 0 then return end -- no room beside the title: keep fill's right-aligned pill
  local tw = math.min(math.ceil(sw), room)
  span(card.title, card, TITLE_Y, at.x0, true, at.x0 + tw, true)
  card.pill:ClearAllPoints()
  card.pill:SetPoint("LEFT", card.title, "RIGHT", 6, 0)
end

local function flushGroup(ui)
  local q = ui.q
  if #q == 0 then return end
  local W = ui.w
  local colW2 = math.floor((W - COL_GAP) / 2)
  local cols = W >= Cards.TWO_COL_MIN and 2 or 1
  for _, e in ipairs(q) do if e.need > colW2 then cols = 1 end end
  local colW = cols == 2 and colW2 or W
  local rowH = 0
  for i, e in ipairs(q) do
    local col = (i - 1) % cols
    if col == 0 and i > 1 then
      ui.y = ui.y + rowH + COL_GAP
      rowH = 0
    end
    local card = e.card
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", ui.list, "TOPLEFT", col * (colW + COL_GAP), -ui.y)
    card:SetSize(colW, H[card.cardKind])
    placePill(card, colW)
    rowH = math.max(rowH, H[card.cardKind])
  end
  ui.y = ui.y + rowH + COL_GAP
  ui.q = {}
end

-- close the open group and the open tile run
local function close(ui)
  flushGroup(ui)
  ui.tileN = 0
end

function Cards.Begin(ui)
  for _, f in ipairs(ui.cards) do f:Hide() end
  for _, f in ipairs(ui.heads) do f:Hide() end
  for _, f in ipairs(ui.lines) do f:Hide() end
  ui.w = Cards.Width(ui)
  ui.y, ui.used, ui.headsUsed, ui.linesUsed, ui.tileN, ui.q = ui.top or 0, 0, 0, 0, 0, {}
  ui.headGap = nil
end

function Cards.End(ui)
  close(ui)
  ui.list:SetHeight(math.max(1, ui.y))
end

function Cards.Section(ui, label)
  close(ui)
  ui.headsUsed = ui.headsUsed + 1
  local h = ui.heads[ui.headsUsed]
  if not h then
    h = K.SectionHeader(ui.list, ui.w, label)
    ui.heads[ui.headsUsed] = h
  end
  if h then
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", ui.list, "TOPLEFT", 0, -ui.y)
    h:SetWidth(ui.w)
    h.label:SetText(label)
    h:Show()
  end
  ui.y = ui.y + H.header
  ui.headGap = HEADER_GAP
  return h
end

function Cards.Line(ui, label)
  close(ui)
  ui.headGap = nil
  ui.linesUsed = ui.linesUsed + 1
  local l = ui.lines[ui.linesUsed]
  if not l then
    l = CreateFrame("Frame", nil, ui.list)
    l.label = text(l, "GameFontHighlightSmall")
    l.label:SetPoint("LEFT", l, "LEFT", 0, 0)
    l.label:SetPoint("RIGHT", l, "RIGHT", 0, 0)
    colour(l.label, GREY)
    ui.lines[ui.linesUsed] = l
  end
  l:ClearAllPoints()
  l:SetPoint("TOPLEFT", ui.list, "TOPLEFT", 0, -ui.y)
  l:SetSize(ui.w, H.line)
  l.label:SetText(label)
  l:Show()
  ui.y = ui.y + H.line
  return l
end

-- ---------- one pooled card: every part made once, shown or hidden per spec ----------

-- The item tooltip on owner (the item button or the card), read through the card at call time. A cached item (its
-- name from ns.Items.Line) on a tooltip with SetItemByID: the game's item tooltip, then the card's lines after the
-- first (the game shows the name). Otherwise 0.1's tooltip: the first line as the title, then the others.
local function showTip(card, owner)
  local tip = M.Compat.Tooltip()
  local lines = card.tipLines
  if not tip or type(lines) ~= "table" then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  local id = card.itemId
  local cached = false
  if id ~= nil and type(tip.SetItemByID) == "function" and type(ns.Items) == "table" then
    cached = select(3, ns.Items.Line(id)) == false
  end
  if cached then tip:SetItemByID(id) else tip:SetText(lines[1] or "") end
  for i = 2, #lines do tip:AddLine(lines[i]) end
  tip:Show()
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

-- a StatusBar on both corners of parent (the StatBar's fill), at level
local function statusBar(parent, c, level)
  local b = CreateFrame("StatusBar", nil, parent)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  b:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
  b:SetStatusBarTexture(BAR_TEXTURE)
  b:SetStatusBarColor(c[1], c[2], c[3])
  b:SetFrameLevel(level)
  return b
end

local function makeCard(ui)
  local card = K.Card(ui.list, Cards.LIST_W, H.plain)
  if not card then
    card = CreateFrame("Frame", nil, ui.list)
    local bg = tex(card, "BACKGROUND", PANEL_BG)
    bg:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
    bg:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)
  end
  card.item = K.ItemButton(card)
  if card.item then
    card.item:SetPoint("TOPLEFT", card, "TOPLEFT", PAD_L, -8)
    card.item:SetScript("OnEnter", function(self) M.Safe(showTip, card, self) end)
    card.item:SetScript("OnLeave", function() M.Safe(hideTip) end)
  end
  card.title = text(card, "GameFontNormal")
  card.when = text(card, "GameFontHighlightSmall", "RIGHT")
  colour(card.when, GREY)
  card.pill = K.Pill(card, "", "gold")
  card.sub = { text(card, "GameFontHighlightSmall"), text(card, "GameFontHighlightSmall") }
  colour(card.sub[1], GREY)
  colour(card.sub[2], GREY)
  card.rank = text(card, "GameFontNormal", "RIGHT")
  colour(card.rank, GOLD)
  card.right = text(card, "GameFontHighlightSmall", "RIGHT")
  -- the bar: an M.Kit.StatBar; in its fill amber (value + extra) under green (value), the text one level above both
  card.bar = K.StatBar(card)
  local fill = card.bar and (type(card.bar.fill) == "table" and card.bar.fill or card.bar)
  if fill then
    card.amber = statusBar(fill, AMBER, fill:GetFrameLevel() + 1)
    card.green = statusBar(fill, GREEN, card.amber:GetFrameLevel() + 1)
    local top = CreateFrame("Frame", nil, card.green)
    top:SetPoint("TOPLEFT", card.green, "TOPLEFT", 0, 0)
    top:SetPoint("BOTTOMRIGHT", card.green, "BOTTOMRIGHT", 0, 0)
    top:SetFrameLevel(card.green:GetFrameLevel() + 1)
    card.barText = text(top, "GameFontHighlightSmall", "CENTER")
    card.barText:SetPoint("LEFT", top, "LEFT", 4, 0)
    card.barText:SetPoint("RIGHT", top, "RIGHT", -4, 0)
  end
  -- the strip: an M.Kit.Divider on top, the label left, the box and up to three buttons right-aligned
  card.strip = CreateFrame("Frame", nil, card)
  card.strip:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
  card.strip:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)
  card.strip:SetHeight(STRIP_H)
  card.rule = K.Divider(card.strip)
  if card.rule then
    card.rule:SetPoint("BOTTOMLEFT", card.strip, "TOPLEFT", 2, 0)
    card.rule:SetPoint("BOTTOMRIGHT", card.strip, "TOPRIGHT", -2, 0)
  end
  card.label = text(card.strip, "GameFontHighlightSmall")
  colour(card.label, GREY)
  card.box = K.InputBox(card.strip, BUTTON_W, BUTTON_W)
  if card.box then
    card.box:SetAutoFocus(false)
    Cards.Hint(card.box, "")
    enterClears(card.box)
  end
  card.buttons = {}
  for i = 1, 3 do card.buttons[i] = CreateFrame("Button", nil, card.strip, "UIPanelButtonTemplate") end
  card:SetScript("OnLeave", function() M.Safe(hideTip) end)
  return card
end

-- the bar's fill line from x1 to x2 at y (the StatBar BAR_TOP above it, so its fill lands on y)
local function drawBar(card, spec, y, x1, left1, x2)
  local b = spec.bar
  local bar = card.bar
  if not bar then return end
  if not b then
    bar:Hide()
    return
  end
  local max = type(b.max) == "number" and b.max or 0
  local value, upto = b.value or 0, (b.value or 0) + (b.extra or 0)
  if max <= 0 then
    max, value, upto = 1, 0, 0
  end
  bar:ClearAllPoints()
  bar:SetPoint("TOPLEFT", card, left1 and "TOPLEFT" or "TOPRIGHT", x1, -(y - BAR_TOP))
  bar:SetPoint("TOPRIGHT", card, "TOPRIGHT", x2, -(y - BAR_TOP))
  bar:Show()
  card.green:SetMinMaxValues(0, max)
  card.amber:SetMinMaxValues(0, max)
  card.green:SetValue(math.min(value, max))
  card.amber:SetValue(math.min(upto, max))
  card.barText:SetText(b.text or "")
  if type(bar.bg) == "table" then bar.bg:SetShown(not spec.head) end
end

local function drawStrip(card, strip)
  local s = card.strip
  s:Show()
  local buttons = strip.buttons or {}
  local right = PAD_R
  for i = #buttons + 1, 3 do card.buttons[i]:Hide() end
  for i = #buttons, 1, -1 do
    local b, spec = card.buttons[i], buttons[i]
    local w = spec[3] or BUTTON_W
    b:ClearAllPoints()
    b:SetPoint("RIGHT", s, "RIGHT", -right, 0)
    b:SetSize(w, BUTTON_H)
    b:SetText(spec[1])
    local fn = spec[2]
    b:SetScript("OnClick", function() M.Safe(fn, card) end)
    b:Show()
    right = right + w + GAP
  end
  local box = card.box
  if strip.box and box then
    box:ClearAllPoints()
    box:SetPoint("RIGHT", s, "RIGHT", -right, 0)
    box:SetSize(strip.box, BUTTON_H)
    box.hint:SetText(strip.hint or "")
    box.hintUpdate()
    box:Show()
    right = right + strip.box + GAP
  elseif box then
    box:Hide()
  end
  if strip.label then
    card.label:ClearAllPoints()
    card.label:SetPoint("LEFT", s, "LEFT", PAD_L, 0)
    card.label:SetPoint("RIGHT", s, "RIGHT", -right, 0)
    card.label:SetText(strip.label)
    card.label:Show()
  else
    card.label:Hide()
  end
end

local function showPill(card, on)
  local pill = card.pill
  if not pill then return end
  pill:SetShown(on)
  pill.text:SetShown(on)
end

local function fill(card, spec)
  local kind = spec.kind
  card.cardKind = kind
  card.pillAt = nil
  if card.key ~= spec.key and card.box then card.box:SetText("") end
  card.key = spec.key
  card:SetHeight(H[kind])
  card.itemId = spec.item
  -- spec.itemName: the item's name on a card whose title is not the item (the uncached tooltip's title)
  card.tipLines = spec.tooltip or { spec.itemName or spec.title or "" }

  local tooltip = spec.tooltip
  card:EnableMouse(tooltip ~= nil)
  card:SetScript("OnEnter", tooltip and function(self) M.Safe(showTip, card, self) end or nil)

  local titleColour = spec.quiet and QUIET_TITLE or (spec.quality and QUALITY[spec.quality]) or WHITE

  if kind == "contrib" then
    if card.item then card.item:Hide() end
    card.when:Hide()
    showPill(card, false)
    card.sub[1]:Hide()
    card.sub[2]:Hide()
    card.strip:Hide()
    local grey = spec.head and GREY
    if spec.rank then
      span(card.rank, card, ROW_Y, PAD_L, true, PAD_L + RANK_W, true)
      card.rank:SetText(tostring(spec.rank))
      card.rank:Show()
    else
      card.rank:Hide()
    end
    local nameL = NAME_X
    span(card.title, card, ROW_Y, nameL, true, nameL + NAME_W, true)
    card.title:SetText(spec.title or "")
    colour(card.title, grey or titleColour)
    span(card.right, card, ROW_Y, -(PAD_R + RIGHT_W), false, -PAD_R, false)
    card.right:SetText(spec.right or "")
    colour(card.right, grey or WHITE)
    card.right:Show()
    drawBar(card, spec, ROW_Y, nameL + NAME_W + GAP, true, -(PAD_R + RIGHT_W + GAP))
    if card.green and spec.head then
      card.green:SetValue(0)
      card.amber:SetValue(0)
    end
    if card.barText then colour(card.barText, spec.head and GREY or WHITE) end
    return
  end

  card.rank:Hide()
  card.right:Hide()
  if card.barText then colour(card.barText, WHITE) end

  local x0 = PAD_L
  if spec.icon and card.item then
    -- spec.itemQuality: the button's quality on a card whose title is not the item (the title keeps white)
    K.SetItem(card.item, spec.icon, spec.itemQuality or spec.quality, spec.count)
    card.item:Show()
    x0 = PAD_L + ITEM + 8
  elseif card.item then
    card.item:Hide()
  end

  -- right to left along the title line: when, pill, then the title ends at what is left
  local right = -PAD_R
  if spec.when and kind ~= "tile" then
    span(card.when, card, TITLE_Y, right - WHEN_W, false, right, false)
    card.when:SetText(spec.when)
    card.when:Show()
    right = right - WHEN_W - GAP
  else
    card.when:Hide()
  end
  local pill, spill = card.pill, spec.pill
  if spill and pill then
    K.SetPill(pill, spill.text, spill.tone)
    local w = pill:GetWidth()
    pill:ClearAllPoints()
    pill:SetPoint("TOPRIGHT", card, "TOPRIGHT", right, -(TITLE_Y - 3)) -- 21 tall, centred on the 14-px title line
    showPill(card, true)
    card.pillAt = { x0 = x0, right = right, w = w } -- placePill moves it beside the title once the card has a width
    right = right - w - GAP
  else
    showPill(card, false)
  end
  span(card.title, card, TITLE_Y, x0, true, right, false)
  card.title:SetText(spec.title or "")
  colour(card.title, titleColour)

  local y = SUB_Y[1]
  for i = 1, 2 do
    local fs, s = card.sub[i], spec.sub and spec.sub[i]
    if s then
      span(fs, card, SUB_Y[i], x0, true, -PAD_R, false)
      fs:SetText(s)
      fs:Show()
      y = SUB_Y[i] + LINE_H + 4
    else
      fs:Hide()
    end
  end
  drawBar(card, spec, y, x0, true, -PAD_R)

  if spec.strip and (kind == "req" or kind == "strip") then
    drawStrip(card, spec.strip)
  else
    card.strip:Hide()
  end
end

function Cards.Card(ui, spec)
  ui.used = ui.used + 1
  local card = ui.cards[ui.used]
  if not card then
    card = makeCard(ui)
    ui.cards[ui.used] = card
  end
  fill(card, spec)
  card:Show()
  local kind = spec.kind
  local gap = ui.headGap
  ui.headGap = nil
  if kind == "tile" then
    flushGroup(ui)
    if ui.tileN == 0 then ui.tileTop = ui.y end
    ui.tileN = ui.tileN + 1
    local i = ui.tileN
    local tileW = math.floor((ui.w - (TILES - 1) * TILE_GAP) / TILES)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", ui.list, "TOPLEFT", ((i - 1) % TILES) * (tileW + TILE_GAP),
      -(ui.tileTop + math.floor((i - 1) / TILES) * (H.tile + TILE_GAP)))
    card:SetSize(tileW, H.tile)
    ui.y = ui.tileTop + math.ceil(i / TILES) * (H.tile + TILE_GAP)
  elseif kind == "contrib" then
    close(ui)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", ui.list, "TOPLEFT", 0, -ui.y)
    card:SetSize(ui.w, H.contrib)
    ui.y = ui.y + H.contrib + CONTRIB_GAP
  else
    ui.tileN = 0
    if gap and #ui.q == 0 then ui.y = ui.y + gap end -- the first group card under a header
    local need = (spec.strip and (kind == "req" or kind == "strip")) and Cards.StripNeed(spec.strip) or 0
    ui.q[#ui.q + 1] = { card = card, need = need }
  end
  return card
end
