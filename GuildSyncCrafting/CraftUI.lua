-- GuildSync crafting, CraftUI: the Crafting page (tabs Work board, Crafters, Recipes, Cooldowns), the Work board with
-- its three lists and row actions, the post form, the alert popup and the Crafting part of the Settings page.
-- Frames come only from CraftCompat.CreateFrame and the frames CraftHost hands over; words and rows from CraftView;
-- board rules from CraftBoard. Posting, claiming, changing and clearing go through CraftSync, read at call time, so
-- the page still opens (and says so) while CraftSync is not there.
--
-- The logged-in character comes from CraftHost.Me().
-- Without it no row offers an action.
-- Redraw: the page draws when CraftHost asks (spec.dirty), at once after a tab, list, chip or row action click, and
-- when the crafter search text changes.
-- Item data is asked for drawn rows only, at most 20 items per draw (Gate A 1c).
-- Crafters and Recipes search and list from CraftView's id index, rebuilt only when CraftSync.Version() or the
-- roster's rows change (CraftHost.RosterVersion); names come from CraftSync.Names() at draw time, so a late name
-- redraws without a rebuild. The recipe book is rebuilt on a new index or a new spell name, never on an item name.

local _, ns = ...

local CraftUI = {}
ns.CraftUI = CraftUI

local CraftCompat, CraftHost, CraftView, CraftBoard =
  ns.CraftCompat, ns.CraftHost, ns.CraftView, ns.CraftBoard

local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local PAGE_ICON = "Interface\\Icons\\Trade_BlackSmithing"
local FLAT_BG = { 1, 1, 1, 0.06 }
local TAB_H, TAB_W = 24, 110
local LIST_W = 90
local BUTTON_H = 22
local CARD_L = CraftView.BoardLayout(0, 0, false) -- request cards: the card numbers do not depend on the page box
local CARD_W, CARD_H, CARD_GAP = CARD_L.cardW, CARD_L.cardH, CARD_L.colStep - CARD_L.cardW
local CARD_BUTTON_W, CARD_BUTTON_GAP = 96, 6
local GREY = 0.6
local DOT = " \194\183 " -- U+00B7, as CraftView's by-line
local PICK_MAX = 8
local PICK_H = 18
local ITEM_REQUESTS = 20 -- item data asked per draw, at most
-- The Keep question when the request or its item name is not known (keepAsk names it).
local KEEP_ASK = "Make this request yours, with its quantity, tip and note?"
local HOURS = { 1, 4, 12, 24, 48 }
local DEFAULT_HOURS = 12
local QTY_MAX, TIP_MAX = 200, 9999

local TABS = { { key = "board", text = "Work board" }, { key = "crafters", text = "Crafters" }, { key = "recipes", text = "Recipes" },
  { key = "cooldowns", text = "Cooldowns" } }
local LISTS = { { key = "forYou", text = "For you" }, { key = "all", text = "All open" }, { key = "mine", text = "Mine" } }
-- the game's top tabs (CraftHost.Tabs): the three board lists, then Crafters, Recipes and Cooldowns; nil -> TABS + LISTS
-- above
local TOP_TABS = { LISTS[1], LISTS[2], LISTS[3], TABS[2], TABS[3], TABS[4] }
local IS_LIST = {}
for _, l in ipairs(LISTS) do IS_LIST[l.key] = true end
local ACTION_TEXT = { claim = "I'll make it", drop = "Drop", release = "Release", done = "Done", cancel = "Cancel", keep = "Keep" }
local EMPTY_LIST = {
  forYou = "No open request you can make.",
  all = "No open requests.",
  mine = "Nothing posted or claimed by your characters.",
}
local EMPTY_NAMES = { items = {}, spells = {}, version = 0, spellVersion = 0 }
local PICK_CHIPS = {}

local u = {} -- the handles, CraftUI.UI()
local state = { tab = "board", list = "forYou", formOpen = false, dirty = true }
local form = { what = nil, hours = DEFAULT_HOURS }
local hooked = false -- shift-click into the item field (CraftCompat.HookShiftClick, at the end of this file)

function CraftUI.UI() return u end

-- ---------- small helpers ----------

-- Backstop for /gsync demo: no crafting write or send while it is on (the clicks say the inert line first).
local DEMO_HELD = { Claim = true, Keep = true, Change = true, Post = true, ClearRecipes = true, ClearBoard = true }

local function syncFn(name)
  if DEMO_HELD[name] and CraftHost.DemoOn() then return nil end
  local s = ns.CraftSync
  if type(s) == "table" and type(s[name]) == "function" then return s[name] end
  return nil
end

local function names()
  local fn = syncFn("Names")
  local t = fn and fn()
  if type(t) == "table" then return t end
  return EMPTY_NAMES
end

local function label(parent, text, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetText(text or "")
  return fs
end

local function panelButton(parent, text, width)
  local b = CraftCompat.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, BUTTON_H)
  b:SetText(text)
  return b
end

local function flatButton(parent, text, width, height)
  local b = CraftCompat.CreateFrame("Button", nil, parent)
  b:SetSize(width, height)
  b:SetNormalFontObject("GameFontHighlightSmall")
  b:SetHighlightTexture(HIGHLIGHT, "ADD")
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetColorTexture(FLAT_BG[1], FLAT_BG[2], FLAT_BG[3], FLAT_BG[4])
  b:SetText(text)
  return b
end

local function editBox(parent, width, letters)
  local e = CraftCompat.CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  if letters then e:SetMaxLetters(letters) end
  e:SetText("")
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return e
end

local function checkButton(parent, text)
  local c = CraftCompat.CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  c:SetSize(24, 24)
  c:SetChecked(false)
  c.label = label(parent, text)
  c.label:SetPoint("LEFT", c, "RIGHT", 4, 0)
  return c
end

local function textOf(box)
  local t = box and box:GetText()
  if type(t) ~= "string" then return "" end
  return (string.gsub(string.gsub(t, "^%s+", ""), "%s+$", ""))
end

local function isChecked(c) return c:GetChecked() == true end

-- shown, and every parent shown (IsVisible, without trusting it)
local function onScreen(f)
  while type(f) == "table" do
    if not f:IsShown() then return false end
    f = f:GetParent()
  end
  return true
end

local function markSelected(b, on)
  if on then b:LockHighlight() else b:UnlockHighlight() end
end

-- the character logged in now
local function myKey() return (CraftHost.Me()) end

local function clearGlow()
  local db = CraftCompat.DB()
  db.glow = false
  CraftHost.SetGlow(false)
end

-- ---------- board rows ----------

-- A names table for the drawn rows: the shared names first, then the item cache; an unknown item is asked for.
local function rowNames(list)
  local base = names()
  local out = { items = {}, spells = {}, version = base.version }
  local icons, asked = {}, 0
  for i = 1, #list do
    local req = list[i]
    local kind, id = string.match(tostring(req.what or ""), "^([is])(%d+)$")
    id = tonumber(id)
    if kind == "i" and id and not out.items[id] then
      local name, _, icon = CraftCompat.ItemInfo(id)
      name = base.items[id] or name
      if name then
        out.items[id] = name
        icons[id] = icon
      elseif asked < ITEM_REQUESTS then
        asked = asked + 1
        CraftCompat.RequestItem(id)
      end
    elseif kind == "s" and id and not out.spells[id] then
      out.spells[id] = base.spells[id] or CraftCompat.SpellName(id)
    end
  end
  return out, icons
end

-- ---------- request cards ----------
-- A card 349x76 (CraftHost.Card): item icon 36x36 at (12,8) with the quantity at its bottom right, the item at (56,8),
-- time left or the end state at the top right, "Requester · brings mats · tip 5 g" at (56,25), and at (56,40) either
-- today's tail (claim, mark, note) or the info line from CraftView.Actions (d376: the claim then joins the by-line).
-- Up to three action buttons 96x22 at the bottom right, right-aligned. The board places cards from u.layout
-- (CraftView.BoardLayout): in Kit.List rows of u.layout.cols cards, else in today's scroll frame's child.

local function makeCard(parent)
  local card = CraftHost.Card(parent, CARD_W, CARD_H)
  card.icon = card:CreateTexture(nil, "ARTWORK")
  card.icon:SetSize(36, 36)
  card.icon:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -8)
  card.qty = card:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  card.qty:SetPoint("BOTTOMRIGHT", card.icon, "BOTTOMRIGHT", -1, 2)
  card.qty:SetJustifyH("RIGHT")
  card.right = label(card, "", "GameFontHighlightSmall")
  card.right:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -8)
  card.right:SetJustifyH("RIGHT")
  card.right:SetTextColor(GREY, GREY, GREY)
  card.right:SetWordWrap(false)
  card.item = label(card, "", "GameFontHighlight")
  card.item:SetPoint("TOPLEFT", card, "TOPLEFT", 56, -8)
  card.item:SetPoint("RIGHT", card.right, "LEFT", -6, 0)
  card.item:SetWordWrap(false)
  card.by = label(card, "", "GameFontHighlightSmall")
  card.by:SetPoint("TOPLEFT", card, "TOPLEFT", 56, -25)
  card.by:SetPoint("RIGHT", card, "RIGHT", -12, 0)
  card.by:SetWordWrap(false)
  card.line = label(card, "", "GameFontHighlightSmall")
  card.line:SetWordWrap(false)
  -- hovering the slot shows its full text (it is cut at the card's width), plus the tail the info line displaced
  card.hit = CraftCompat.CreateFrame("Frame", nil, card)
  card.hit:SetAllPoints(card.line)
  card.hit:EnableMouse(true)
  card.hit:SetScript("OnEnter", function(self)
    CraftHost.Safe(function()
      local text = card.line:GetText()
      local tip = CraftHost.Tooltip()
      if not tip or type(text) ~= "string" or text == "" then return end
      tip:SetOwner(self, "ANCHOR_TOP")
      tip:SetText(text, 1, 1, 1, 1, true)
      if card.extra and card.extra ~= "" then tip:AddLine(card.extra, 1, 0.82, 0, true) end
      tip:Show()
    end)
  end)
  card.hit:SetScript("OnLeave", function()
    CraftHost.Safe(function()
      local tip = CraftHost.Tooltip()
      if tip then tip:Hide() end
    end)
  end)
  card.buttons = {}
  for b = 1, 3 do
    local btn = panelButton(card, "", CARD_BUTTON_W)
    btn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12 - (3 - b) * (CARD_BUTTON_W + CARD_BUTTON_GAP), 8)
    btn:SetScript("OnClick", function(self) CraftHost.Safe(CraftUI.Act, self.id, self.action) end)
    btn:Hide()
    card.buttons[b] = btn
  end
  return card
end

-- the slot at (56,40) runs to the leftmost shown button (8 px before it), else to the card's right edge minus 12
local function placeLine(card, first)
  card.line:ClearAllPoints()
  card.line:SetPoint("TOPLEFT", card, "TOPLEFT", 56, -40)
  if first then card.line:SetPoint("RIGHT", first, "LEFT", -8, 0)
  else card.line:SetPoint("RIGHT", card, "RIGHT", -12, 0) end
end

local function clearButton(btn)
  btn.id, btn.action = nil, nil
  btn:SetText("")
  btn:Hide()
end

-- an unused card: hidden, and no button keeps a request id
local function clearCard(card)
  for b = 1, 3 do clearButton(card.buttons[b]) end
  card:Hide()
end

-- "|cffrrggbb" for the requester's class from the roster row, or nil when unknown
local function classCode(roster, key)
  local m = type(roster) == "table" and key ~= nil and roster[key] or nil
  local r, g, b = CraftCompat.ClassColor(type(m) == "table" and m.class or nil)
  if not r then return nil end
  local function hex(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
  return string.format("|cff%02x%02x%02x", hex(r), hex(g), hex(b))
end

local function fillCard(card, req, now, ctx)
  local claim = CraftBoard.Effective(req)
  local st = CraftBoard.State(req, now)
  local r = CraftView.BoardRow(req, now, { names = ctx.names, claim = claim, roster = ctx.roster })
  local lines = CraftView.CardLines(r, st)
  local live = st == "open" or st == "claimed"
  local itemID = tonumber(string.match(tostring(req.what or ""), "^i(%d+)$"))
  local cell = CraftView.ItemCell(itemID, itemID and ctx.names.items[itemID], nil, itemID and ctx.icons[itemID])
  card.icon:SetTexture(itemID and cell.icon or CraftView.UNKNOWN_ICON)
  local qty = tonumber(req.qty) or 1
  card.qty:SetText(r.qty)
  if qty == 1 then card.qty:Hide() else card.qty:Show() end
  card.item:SetText(r.item)
  card.right:SetText(lines.right)

  local actions, line = {}, nil
  -- d215: my own expired request (not final, not provisional) keeps Done and Cancel
  if ctx.me and (st == "open" or st == "claimed" or (st == "expired" and req.by == ctx.me and not req.provisional)) then
    actions, line = CraftView.Actions(req, now, { me = ctx.me, myKeys = ctx.myKeys, claim = claim,
                                                 canMake = CraftHost.CanMake(req.what), roster = ctx.roster })
  end
  local by = lines.by
  -- d376: the info line takes the claim line's slot; the claim joins the by-line
  if line and live and r.claim ~= "" then by = by .. DOT .. r.claim end
  local code = classCode(ctx.roster, req.by)
  if code then by = code .. r.who .. "|r" .. string.sub(by, #r.who + 1) end
  card.by:SetText(by)
  card.line:SetText(line or lines.tail)
  -- the mark and note the info line displaces go into the slot's tooltip
  card.extra = nil
  if line then
    local rest = {}
    if live and r.mark ~= "" then rest[#rest + 1] = r.mark end
    if r.note ~= "" then rest[#rest + 1] = "\"" .. r.note .. "\"" end
    card.extra = table.concat(rest, ", ")
  end

  local first
  for b = 1, 3 do
    local btn = card.buttons[b]
    local action = actions[#actions - 3 + b] -- right-aligned
    if action then
      btn.id, btn.action = req.id, action
      btn:SetText(ACTION_TEXT[action])
      btn:Show()
      first = first or btn
    else
      clearButton(btn)
    end
  end
  placeLine(card, first)
  card:Show()
end

-- What the tabs draw: the Crafting module's demo state while /gsync demo is on, else the real board, directory and
-- roster. The one switch; row builders never ask. In demo every request counts as one this character can make.
local function demoCanMake() return true end
local function view()
  local s = CraftHost.DemoState()
  if s then return { board = s.board, crafters = s.crafters, roster = s.roster, canMake = demoCanMake } end
  return { board = CraftCompat.DB().board, crafters = CraftCompat.Dir().crafters, roster = (CraftHost.Roster()),
           canMake = CraftHost.CanMake }
end

local function boardCols() return (u.layout and u.layout.cols) or 2 end

-- Kit.List: one element per card row ({ req, req? }), each row frame holding two cards built once.
local function buildCardRow(frame)
  frame.cards = { makeCard(frame), makeCard(frame) }
  frame.cards[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  frame.cards[2]:SetPoint("TOPLEFT", frame, "TOPLEFT", CARD_W + CARD_GAP, 0)
end

local function initCardRow(frame, row)
  for k = 1, 2 do
    local req = type(row) == "table" and row[k] or nil
    if req and u.cardCtx then fillCard(frame.cards[k], req, u.cardNow, u.cardCtx) else clearCard(frame.cards[k]) end
  end
end

local function cardRows(list, cols)
  local rows = {}
  for i, req in ipairs(list) do
    local k = math.floor((i - 1) / cols) + 1
    rows[k] = rows[k] or {}
    rows[k][#rows[k] + 1] = req
  end
  return rows
end

-- the fallback pool in today's scroll child: card i at its column and row from the board layout
local function placePool(n)
  local cols = boardCols()
  for i = 1, #u.cards do
    local card = u.cards[i]
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", u.content, "TOPLEFT", ((i - 1) % cols) * (CARD_W + CARD_GAP),
                  -math.floor((i - 1) / cols) * (CARD_H + CARD_GAP))
  end
  u.content:SetHeight(math.max(1, math.ceil(n / cols) * (CARD_H + CARD_GAP)))
end

local function showCards(list, now, ctx)
  u.cardList, u.cardNow, u.cardCtx = list, now, ctx
  if u.list then
    -- a redraw of the same list keeps the scroll position; another list starts at the top
    local same = u.cardKey == state.list
    u.cardKey = state.list
    u.list:SetRows(cardRows(list, boardCols()), same)
    return
  end
  for i, req in ipairs(list) do
    local card = u.cards[i]
    if not card then
      card = makeCard(u.content)
      u.cards[i] = card
    end
    fillCard(card, req, now, ctx)
  end
  for i = #list + 1, #u.cards do clearCard(u.cards[i]) end
  placePool(#list)
end

-- The form's columns and rows (y of the fields in the card); placeBoard and buildForm read them.
local FORM_COL = { item = 17, cancel = 176, qty = 280, tip = 346, hours = 436 }
local FORM_ROW1, FORM_ROW2 = 26, 76
local PICKS_TOP = FORM_ROW1 + 36 -- the flat pick buttons (fallback without the menu) start under the item's hint

-- How much lower row 2 sits and how much taller the form card is while flat pick buttons show: row 2 goes under the
-- last shown pick, so the picks overlap neither row 2 nor the cards (0 on the menu path or with no picks shown).
local function picksExtra()
  local n = 0
  for _, b in ipairs(u.form.picks) do if b:IsShown() then n = n + 1 end end
  if n == 0 then return 0 end
  return math.max(0, PICKS_TOP + n * PICK_H + 4 - FORM_ROW2)
end

-- The form card at the cards' top and the cards under it (formShift lower while the form is open), from u.layout.
local function placeBoard()
  local B = u.layout
  if not (B and u.form) then return end
  local f = u.form
  local extra = picksExtra()
  local row2 = FORM_ROW2 + extra
  f.panel:ClearAllPoints()
  f.panel:SetPoint("TOPLEFT", u.board, "TOPLEFT", 0, -B.cardsTop)
  f.panel:SetSize(B.formW, B.formH + extra)
  f.mats:ClearAllPoints()
  f.mats:SetPoint("LEFT", f.panel, "TOPLEFT", FORM_COL.item, -(row2 + 11))
  f.cancel:ClearAllPoints()
  f.cancel:SetPoint("TOPLEFT", FORM_COL.cancel, -row2)
  f.note:ClearAllPoints()
  f.note:SetPoint("TOPLEFT", FORM_COL.qty + 4, -row2)
  f.note:SetWidth(f.noteGrows and B.noteW or math.min(230, B.noteW))
  f.post:ClearAllPoints()
  f.post:SetPoint("TOPLEFT", f.panel, "TOPLEFT", B.postX, -row2)
  local top = B.cardsTop + (state.formOpen and (B.formShift + extra) or 0)
  u.scroll:ClearAllPoints()
  if u.list then
    -- Kit.List's box is its holder minus 16 px for the bar, so a holder areaW + 16 wide gives a box exactly areaW
    u.scroll:SetPoint("TOPLEFT", u.board, "TOPLEFT", 2, -top)
    u.scroll:SetPoint("BOTTOMRIGHT", u.board, "BOTTOMRIGHT", 18, 0)
  else
    u.scroll:SetPoint("TOPLEFT", u.board, "TOPLEFT", 0, -top)
    u.scroll:SetPoint("BOTTOMRIGHT", u.board, "BOTTOMRIGHT", -24, 0)
  end
end

local function drawBoard()
  if not u.board then return end
  if u.lists then
    for _, l in ipairs(LISTS) do markSelected(u.lists[l.key], not state.formOpen and state.list == l.key) end
  end
  -- the form opens on top of the list: the cards stay drawn under it
  placeBoard()
  if state.formOpen then u.form.panel:Show() else u.form.panel:Hide() end
  u.status:Show()
  u.scroll:Show()
  local now = CraftCompat.Now()
  local list = {}
  local ctx
  if now then
    local v = view()
    local roster = v.roster
    local myKeys = CraftHost.MyKeys()
    local forYou, all, mine = CraftBoard.Lists(v.board, now, myKeys, v.canMake, roster)
    -- an unconfirmed request in my own name shows in Mine only while open, with Keep and Cancel (d211); a forgery
    -- cancelled by self-defence does not
    local posted = {}
    for _, r in ipairs(mine) do if not (r.provisional and r.final) then posted[#posted + 1] = r end end
    list = (state.list == "all" and all) or (state.list == "mine" and posted) or forYou
    local nm, icons = rowNames(list)
    ctx = { names = nm, icons = icons, roster = roster, myKeys = myKeys, me = myKey() }
  end
  showCards(list, now, ctx)
  if not now then
    u.status:SetText("The server time is not known yet. The board shows once it is.")
  elseif #list == 0 then
    u.status:SetText(EMPTY_LIST[state.list] or "")
  else
    u.status:SetText(state.result or "")
  end
end

-- ---------- the id index ----------

-- The directory version (CraftSync.Version) and the roster's version: the id index is rebuilt only when one
-- changes, never on a keystroke, a late name or a re-read of the same roster.
local function dirVersion()
  if CraftHost.DemoState() then return "demo:" .. tostring(CraftHost.DemoSerial()) end
  local fn = syncFn("Version")
  return tostring(fn and fn() or 0) .. ":" .. tostring(CraftHost.RosterVersion())
end

local function crafterIndex()
  local v = view()
  return CraftView.Index(v.crafters, CraftHost.MyKeys(), v.roster, dirVersion())
end

-- ---------- crafters tab ----------

local CRAFTER_ROW_H = 40
local CRAFTER_ROWS = 50 -- rows drawn at most; the status line says how many more match
local CHIP_W, CHIP_H, CHIPS_PER_LINE = 120, 20, 5
local STAR_W, WHISPER_W = 22, 80
local STAR_ON, STAR_OFF = "|cffffd100*|r", "|cff606060*|r"
local SEARCH_W = 220
local SEARCH_HINT = "Item, recipe, profession or name"

local cstate = { query = "", prof = nil, online = false, chips = nil, chipIndex = nil, chipIds = {} }

-- The chips table handed to CraftView.Search. Search caches per chips table, so a change makes a new one.
local function crafterChips()
  if not cstate.chips then
    cstate.chips = { prof = cstate.prof, online = cstate.online or nil, favourites = CraftCompat.DB().favourites }
  end
  return cstate.chips
end

local function chipsChanged() cstate.chips = nil end

-- Opens a tell to name with link in the box (never sent); without the chat helpers, prints the /w line instead.
function CraftUI.Whisper(name, link)
  if CraftHost.DemoInert() then return end
  if type(name) ~= "string" or name == "" then return end
  if CraftHost.OpenWhisper(name, link) == "tell" then return end
  CraftHost.Say("Whisper " .. name .. ": /w " .. name .. (link and (" " .. link) or ""))
end

local drawCrafters

local function crafterRow(i)
  local cu = u.crafters
  local h = cu.rows[i]
  if h then return h end
  local row = CraftCompat.CreateFrame("Frame", nil, cu.content)
  local y = -(i - 1) * CRAFTER_ROW_H
  row:SetHeight(CRAFTER_ROW_H)
  row:SetPoint("TOPLEFT", 0, y)
  row:SetPoint("TOPRIGHT", 0, y)
  row.name = label(row, "", "GameFontHighlight") -- the first text under the row: the crafter's name
  row.name:SetPoint("TOPLEFT", STAR_W + 8, -3)
  row.detail = label(row, "", "GameFontHighlightSmall")
  row.detail:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
  row.detail:SetPoint("RIGHT", row, "RIGHT", -(WHISPER_W + 8), 0)
  row.detail:SetWordWrap(false)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("TOPLEFT", STAR_W + 8, -21)
  row.item = label(row, "", "GameFontHighlightSmall")
  row.item:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
  row.item:SetPoint("RIGHT", row, "RIGHT", -(WHISPER_W + 8), 0)
  row.item:SetWordWrap(false)
  local star = flatButton(row, STAR_OFF, STAR_W, STAR_W)
  star:SetPoint("TOPLEFT", 2, -3)
  star:SetScript("OnClick", function(self)
    CraftHost.Safe(function()
      if not self.key then return end
      if CraftHost.DemoInert() then return end -- no favourite write for a made-up crafter
      local favs = CraftCompat.DB().favourites
      favs[self.key] = (not favs[self.key]) and true or nil
      chipsChanged()
      drawCrafters()
    end)
  end)
  local whisper = panelButton(row, "Whisper", WHISPER_W)
  whisper:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  whisper:SetScript("OnClick", function(self) CraftHost.Safe(CraftUI.Whisper, self.name, self.link) end)
  h = { frame = row, star = star, whisper = whisper }
  cu.rows[i] = h
  return h
end

-- The first matched recipe of a row: its item (icon, quality colour, link) or its recipe name. An uncached item
-- reads "item <id>" with the unknown icon and is asked for while asked < ITEM_REQUESTS.
local function drawHit(row, r, nm, asked)
  local hit = r.hits and r.hits[1]
  local link
  if not hit then
    row.icon:Hide()
    row.item:SetText("")
    return nil, asked
  end
  local text
  if hit.item then
    local name, quality, icon
    name, quality, icon, link = CraftCompat.ItemInfo(hit.item)
    if not name and asked < ITEM_REQUESTS then
      asked = asked + 1
      CraftCompat.RequestItem(hit.item)
    end
    local cell = CraftView.ItemCell(hit.item, name, quality, icon)
    row.icon:SetTexture(cell.icon)
    row.icon:Show()
    text = "|c" .. cell.color .. cell.text .. "|r"
  else
    row.icon:Hide()
    text = CraftView.RecipeLabel(hit.spell, nm)
  end
  if #r.hits > 1 then text = text .. "  (+" .. (#r.hits - 1) .. " more)" end
  row.item:SetText(text)
  return link, asked
end

local function drawCrafterRow(i, r, ctx)
  local h = crafterRow(i)
  local row = h.frame
  h.key, h.prof = r.key, r.prof
  local m, rec = ctx.roster[r.key], ctx.dir[r.key]
  local cr, cg, cb = CraftCompat.ClassColor(m and m.class)
  if not cr then cr, cg, cb = CraftCompat.ClassColor(rec and rec.class) end
  row.name:SetText(CraftView.SafeText(r.name)) -- names come from other players' messages (d377)
  row.name:SetTextColor(cr or 1, cg or 1, cb or 1)
  local rank = tostring(r.rank) .. (r.max and ("/" .. tostring(r.max)) or "")
  local parts = { CraftView.ProfessionName(r.prof) .. " " .. rank, CraftView.LastSeen(r.seen, ctx.now, r.online) }
  if not r.shared then parts[#parts + 1] = "recipes not shared" end
  if r.own then parts[#parts + 1] = "your character" end
  row.detail:SetText(table.concat(parts, ", "))
  local link
  link, ctx.asked = drawHit(row, r, ctx.names, ctx.asked)
  h.star.key = r.key
  h.star:SetText(r.fav and STAR_ON or STAR_OFF)
  h.whisper.name, h.whisper.link = r.name, link
  if r.own then h.whisper:Hide() else h.whisper:Show() end
  row:Show()
end

-- ---------- crafter rows in the kit list (cu.list) ----------
-- The box owns its frames: buildRow runs once per frame, initRow every time the box shows a row (at a draw, on a scroll
-- and from Refresh after a resize), so it sets every field from the row and the columns from u.clayout. drawCrafters
-- never hides, re-texts or indexes these frames; it clears the handles' data before each SetRows.

-- "rank" or "rank/max"
local function rankText(rank, max)
  return tostring(rank) .. (max and ("/" .. tostring(max)) or "")
end

-- A crafter's class token and colour: the roster row's class, else the crafter directory's.
local function crafterClass(m, rec)
  local cr, cg, cb = CraftCompat.ClassColor(m and m.class)
  if not cr then cr, cg, cb = CraftCompat.ClassColor(rec and rec.class) end
  return (m and m.class) or (rec and rec.class), cr, cg, cb
end

local function starClick(self)
  if not self.key then return end
  if CraftHost.DemoInert() then return end -- no favourite write for a made-up crafter
  local favs = CraftCompat.DB().favourites
  favs[self.key] = (not favs[self.key]) and true or nil
  chipsChanged()
  drawCrafters()
end

local function buildRow(frame)
  local h = { frame = frame }
  h.star = CraftHost.FavouriteStar(frame) or flatButton(frame, STAR_OFF, STAR_W, STAR_W)
  h.star:SetScript("OnClick", function(self) CraftHost.Safe(starClick, self) end)
  h.class = frame:CreateTexture(nil, "ARTWORK")
  h.class:SetSize(16, 16)
  h.name = label(frame, "", "GameFontHighlight")
  h.name:SetWordWrap(false)
  h.profIcon = frame:CreateTexture(nil, "ARTWORK")
  h.profIcon:SetSize(16, 16)
  h.profText = label(frame, "", "GameFontHighlightSmall")
  h.profText:SetPoint("LEFT", h.profIcon, "RIGHT", 4, 0)
  h.seen = label(frame, "", "GameFontHighlightSmall")
  h.icon = frame:CreateTexture(nil, "ARTWORK") -- drawHit's icon and item, as today's row
  h.icon:SetSize(16, 16)
  h.item = label(frame, "", "GameFontHighlightSmall")
  h.item:SetWordWrap(false)
  h.tags = label(frame, "", "GameFontHighlightSmall")
  h.whisper = panelButton(frame, "Whisper", WHISPER_W)
  h.whisper:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
  h.whisper:SetScript("OnClick", function(self) CraftHost.Safe(CraftUI.Whisper, self.name, self.link) end)
  CraftHost.ListHover(frame, HIGHLIGHT)
  frame.h = h
  local cu = u.crafters
  cu.rows[#cu.rows + 1] = h
end

local function initRow(frame, r)
  local h, L, ctx = frame.h, u.clayout, cstate.draw
  if not (h and L and ctx and type(r) == "table") then return end
  h.key, h.prof = r.key, r.prof
  -- columns from the layout (a resize re-runs this through Refresh)
  h.star:ClearAllPoints()
  h.star:SetPoint("TOPLEFT", L.starX, -L.starY)
  h.class:ClearAllPoints()
  h.class:SetPoint("TOPLEFT", L.classX, -L.classY)
  h.name:ClearAllPoints()
  h.name:SetPoint("TOPLEFT", L.nameX, -L.nameY)
  h.name:SetPoint("RIGHT", frame, "LEFT", L.profX - 6, 0)
  h.profIcon:ClearAllPoints()
  h.profIcon:SetPoint("TOPLEFT", L.profX, -L.nameY)
  h.seen:ClearAllPoints()
  h.seen:SetPoint("TOPLEFT", L.seenX, -L.nameY)
  h.icon:ClearAllPoints()
  h.icon:SetPoint("TOPLEFT", L.nameX, -L.line2Y)
  h.tags:ClearAllPoints()
  h.tags:SetPoint("TOPLEFT", L.profX, -L.line2Y)
  -- texts and colours, every field fresh (a recycled frame keeps nothing of its last row)
  local token, cr, cg, cb = crafterClass(ctx.roster[r.key], ctx.dir[r.key])
  h.class:Show()
  CraftHost.ClassIcon(h.class, token)
  h.name:SetText(CraftView.SafeText(r.name)) -- names come from other players' messages (d377)
  h.name:SetTextColor(cr or 1, cg or 1, cb or 1)
  h.profIcon:SetTexture(CraftHost.ProfessionIcon(r.prof))
  h.profText:SetText(CraftView.ProfessionName(r.prof) .. " " .. rankText(r.rank, r.max))
  h.seen:SetText(CraftView.LastSeen(r.seen, ctx.now, r.online))
  if r.online then h.seen:SetTextColor(CraftHost.Green()) else h.seen:SetTextColor(1, 1, 1) end
  local tags = {}
  if not r.shared then tags[#tags + 1] = "recipes not shared" end
  if r.own then tags[#tags + 1] = "your character" end
  h.tags:SetText(table.concat(tags, ", "))
  local link
  link, ctx.asked = drawHit(h, r, ctx.names, ctx.asked) -- shares the draw's 20 item asks with scroll-time inits
  h.item:ClearAllPoints()
  h.item:SetPoint("LEFT", h.icon, "RIGHT", 4, 0)
  if #tags > 0 then
    h.item:SetPoint("RIGHT", frame, "LEFT", L.profX - 6, 0)
  else
    h.item:SetPoint("RIGHT", h.whisper, "LEFT", -8, 0)
  end
  h.star.key = r.key
  if rawget(h.star, "isStar") then CraftHost.SetFavourite(h.star, r.fav) else h.star:SetText(r.fav and STAR_ON or STAR_OFF) end
  h.whisper.name, h.whisper.link = r.name, link
  if r.own then h.whisper:Hide() else h.whisper:Show() end
end

-- The first CRAFTER_ROWS rows to the box. Every handle's data is cleared first (data only): a frame the box no longer
-- shows keeps no crafter to act for.
local function listRows(rows, n)
  local cu = u.crafters
  for _, h in ipairs(cu.rows) do
    h.key, h.prof = nil, nil
    h.star.key = nil
    h.whisper.name, h.whisper.link = nil, nil
  end
  local shown = {}
  for i = 1, n do shown[i] = rows[i] end
  cu.list:SetRows(shown, true)
end

-- The status line and the list container: under the chip lines when the chips are shown (cstate.chipTop, set by
-- drawProfChips), else where u.clayout says. Moves frames only.
local function placeCrafterList()
  local cu, L = u.crafters, u.clayout
  local statusY, listY
  if cstate.chipTop then
    statusY, listY = cstate.chipTop - 2, cstate.chipTop - 20
  elseif L then
    statusY, listY = -L.statusY, -L.listTop
  else
    return
  end
  cu.status:ClearAllPoints()
  cu.status:SetPoint("TOPLEFT", 4, statusY)
  cu.status:SetPoint("RIGHT", cu.panel, "RIGHT", -4, 0)
  if cu.holder then
    cu.holder:ClearAllPoints()
    cu.holder:SetPoint("TOPLEFT", 0, listY)
    cu.holder:SetPoint("BOTTOMLEFT", 0, 0)
    if L then cu.holder:SetWidth(L.rowW + 16) end -- the area's width; Kit.List keeps 16 of it for the bar
  else
    cu.scroll:ClearAllPoints()
    cu.scroll:SetPoint("TOPLEFT", 0, listY)
    cu.scroll:SetPoint("BOTTOMRIGHT", -24, 0)
  end
end

-- The filter row from u.clayout (relayout): search box, profession dropdown (or the chips' place under it), Online now.
local function placeCrafters()
  local cu, L = u.crafters, u.clayout
  if not (cu and L) then return end
  cu.search:ClearAllPoints()
  if cu.searchBox then
    cu.search:SetPoint("TOPLEFT", L.searchX, -L.searchY)
    cu.search:SetWidth(L.searchW)
  else
    cu.search:SetPoint("TOPLEFT", L.searchX + 3, -L.searchY) -- InputBoxTemplate's left border sits outside the box
  end
  if cu.profMenu then
    cu.profMenu:ClearAllPoints()
    cu.profMenu:SetPoint("TOPLEFT", L.dropX, -L.searchY + 1) -- 25 tall, centred on the 22-tall search box
    cu.profMenu:SetWidth(L.dropW)
  end
  cu.online:ClearAllPoints()
  cu.online:SetPoint("TOPLEFT", L.checkX, cu.onlineCheck and (-L.searchY + 3) or -L.searchY) -- the checkbox is 29 tall
  placeCrafterList()
  if cu.list then cu.list:Refresh() end -- the shown rows' columns from the new layout, no frame made
end

-- The professions in the index in today's order (by name), worked out again only when the index changes; a chosen
-- profession that left the index is dropped (chips and dropdown alike). True when the index changed.
local function profIds(index)
  if cstate.chipIndex == index then return false end
  cstate.chipIndex = index
  local seen, ids = {}, {}
  for _, e in ipairs(index.entries or {}) do
    if not seen[e.prof] then seen[e.prof] = true ids[#ids + 1] = e.prof end
  end
  table.sort(ids, function(a, b) return CraftView.ProfessionName(a) < CraftView.ProfessionName(b) end)
  cstate.chipIds = ids
  if cstate.prof and not seen[cstate.prof] then
    cstate.prof = nil
    chipsChanged()
  end
  return true
end

local function profText(id, counts)
  if not id then return "All professions (" .. tostring(counts and counts.all or 0) .. ")" end
  return CraftView.ProfessionName(id) .. " (" .. tostring(counts and counts.profs and counts.profs[id] or 0) .. ")"
end

local function setProf(id)
  cstate.prof = id
  chipsChanged()
  drawCrafters()
end

local function setOnline(on)
  cstate.online = on
  chipsChanged()
  drawCrafters()
end

-- The dropdown's menu from the last draw's counts (cstate.counts, cstate.chipIds); nil-safe before the first draw.
local function profMenu(_, root)
  local counts = cstate.counts
  root:CreateRadio(profText(nil, counts), function() return cstate.prof == nil end,
    function() CraftHost.Safe(setProf, nil) end, 0)
  for _, id in ipairs(cstate.chipIds or {}) do
    root:CreateRadio(profText(id, counts), function() return cstate.prof == id end,
      function() CraftHost.Safe(setProf, id) end, id)
  end
end

-- One chip per profession in the index (the dropdown's fallback), laid out again only when the index changes.
local function drawProfChips(changed, counts)
  local cu = u.crafters
  if changed then
    local ids = cstate.chipIds
    for _, b in pairs(cu.profs) do b:Hide() end
    for i, id in ipairs(ids) do
      local b = cu.profs[id]
      if not b then
        b = flatButton(cu.panel, "", CHIP_W, CHIP_H)
        b:SetScript("OnClick", function()
          CraftHost.Safe(function()
            cstate.prof = (cstate.prof ~= id) and id or nil
            chipsChanged()
            drawCrafters()
          end)
        end)
        cu.profs[id] = b
      end
      local col, line = (i - 1) % CHIPS_PER_LINE, math.floor((i - 1) / CHIPS_PER_LINE)
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", col * (CHIP_W + 4), -(BUTTON_H + 6) - line * (CHIP_H + 4))
      b:Show()
    end
    local lines = math.ceil(#ids / CHIPS_PER_LINE)
    cstate.chipTop = -(BUTTON_H + 6) - lines * (CHIP_H + 4)
    placeCrafterList()
  end
  for _, id in ipairs(cstate.chipIds) do
    local b = cu.profs[id]
    b:SetText(profText(id, counts))
    markSelected(b, cstate.prof == id)
  end
end

-- The profession filter (dropdown text, else chips) and Online now with this draw's counts. An open menu stays open
-- and keeps the counts it opened with until it is opened again.
local function drawFilters(changed, counts)
  local cu = u.crafters
  cstate.counts = counts
  if cu.profMenu then
    CraftHost.DropdownText(cu.profMenu, profText(cstate.prof, counts))
  else
    drawProfChips(changed, counts)
  end
  local online = "Online now (" .. tostring(counts.online or 0) .. ")"
  if cu.onlineCheck then
    cu.online:SetChecked(cstate.online)
    cu.online.label:SetText(online)
  else
    markSelected(cu.online, cstate.online)
    cu.online:SetText(online)
  end
end

drawCrafters = function()
  local cu = u.crafters
  if not cu then return end
  local index = crafterIndex()
  local nm = names()
  local changed = profIds(index)
  local chips = crafterChips()
  local rows, counts = CraftView.Search(index, nm, cstate.query, chips)
  drawFilters(changed, counts)
  local v = view()
  local ctx = { now = CraftCompat.Now(), roster = v.roster, dir = v.crafters, names = nm,
                asked = 0 }
  cstate.draw = ctx -- read by initRow, also when the box scrolls between draws
  local n = math.min(#rows, CRAFTER_ROWS)
  if cu.list then
    listRows(rows, n)
  else
    for i = 1, n do drawCrafterRow(i, rows[i], ctx) end
    for i = n + 1, #cu.rows do -- a hidden row keeps no name from an earlier draw (a demo crafter after /gsync demo off)
      local row = cu.rows[i].frame
      row.name:SetText("")
      row.detail:SetText("")
      row.item:SetText("")
      row:Hide()
    end
    cu.content:SetHeight(math.max(1, n * CRAFTER_ROW_H))
  end
  if #rows == 0 then
    cu.status:SetText(cstate.query == "" and "No crafters known yet." or "No crafter matches that.")
  elseif #rows > n then
    cu.status:SetText("Showing " .. n .. " of " .. #rows .. ". Type more to narrow the list.")
  else
    cu.status:SetText(#rows == 1 and "1 crafter." or (#rows .. " crafters."))
  end
end

local function scrollList(p)
  local scroll = CraftCompat.CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
  local content = CraftCompat.CreateFrame("Frame", nil, scroll)
  content:SetSize(400, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(_, w) if type(w) == "number" and w > 0 then content:SetWidth(w) end end)
  return scroll, content
end

local function buildCrafters(p)
  local cu = { panel = p, profs = {}, rows = {} }
  u.crafters = cu
  local function searchChanged(self)
    local q = textOf(self)
    if q == cstate.query then return end -- the clear button's "" (userInput false) still filters
    cstate.query = q
    drawCrafters()
  end
  -- Search: the game's search box (its own scripts kept, so hooked), else today's box with the hint beside it
  cu.search = CraftHost.SearchBox(p, SEARCH_W, SEARCH_HINT)
  if cu.search then
    cu.searchBox = true
    cu.search:SetAutoFocus(false)
    cu.search:SetMaxLetters(60)
    cu.search:HookScript("OnTextChanged", function(self) CraftHost.Safe(searchChanged, self) end)
    -- Escape also closes an open profession menu
    cu.search:HookScript("OnEscapePressed", function(self)
      CraftHost.Safe(function() CraftHost.CloseDropdown(cu.profMenu) self:ClearFocus() end)
    end)
  else
    cu.search = editBox(p, SEARCH_W, 60)
    cu.search:SetScript("OnTextChanged", function(self) CraftHost.Safe(searchChanged, self) end)
    local hint = label(p, SEARCH_HINT, "GameFontDisableSmall")
    hint:SetPoint("LEFT", cu.search, "RIGHT", 8, 0)
  end
  if cstate.query ~= "" then cu.search:SetText(cstate.query) end -- a search row's name, set before the page was built
  -- Profession: the game's dropdown with a radio per profession and its count, else the chips (drawProfChips)
  cu.profMenu = CraftHost.Dropdown(p, 190, profMenu)
  -- Online now: the game's checkbox with the count in its label, else today's chip button
  cu.online = CraftHost.Checkbox(p, "Online now")
  if cu.online then
    cu.onlineCheck = true
    cu.online:SetChecked(cstate.online)
    cu.online:SetScript("OnClick", function(self)
      CraftHost.Safe(function() setOnline(self:GetChecked() == true) end)
    end)
  else
    cu.online = flatButton(p, "Online now", CHIP_W, CHIP_H)
    cu.online:SetScript("OnClick", function() CraftHost.Safe(setOnline, not cstate.online) end)
  end
  cu.status = label(p, "", "GameFontHighlightSmall")
  cu.status:SetWordWrap(false)
  -- Rows: the kit list (WowScrollBoxList + MinimalScrollBar) in a holder the area's width, else today's scroll frame
  cu.holder = CraftCompat.CreateFrame("Frame", nil, p)
  cu.list = CraftHost.List(cu.holder, CRAFTER_ROW_H, buildRow, initRow)
  if not cu.list then
    cu.holder:Hide()
    cu.holder = nil
    cu.scroll, cu.content = scrollList(p)
  end
end

-- ---------- recipes tab ----------

local BOOK_W, BOOK_ROW_H, INDENT = 230, 18, 14
local DETAIL_LINES = 24
local BOOK_CARD_W, BOOK_INSET, BOOK_LIST_ROW_H = 220, 8, 22 -- the modern book: a card, the kit list inset 8, rows 22
local BOOK_LIST_W = BOOK_CARD_W - 2 * BOOK_INSET - 16 -- a row: the list's box (Kit.List keeps 16 for the bar)

local rstate = { open = {}, prof = nil, spell = nil, index = nil, sv = nil, book = nil }

-- The book reads spell names only (CraftView.Book), so an item name arriving does not rebuild it (f1025).
local function recipeBook()
  local index, nm = crafterIndex(), names()
  if rstate.index ~= index or rstate.sv ~= nm.spellVersion or not rstate.book then
    rstate.index, rstate.sv, rstate.book = index, nm.spellVersion, CraftView.Book(index, nm)
  end
  return rstate.book
end

local drawRecipes

local function bookRow(i)
  local ru = u.recipes
  local b = ru.rows[i]
  if b then return b end
  b = flatButton(ru.content, "", BOOK_W - 28, BOOK_ROW_H - 1)
  b:SetPoint("TOPLEFT", 0, -(i - 1) * BOOK_ROW_H)
  b:SetScript("OnClick", function(self)
    CraftHost.Safe(function()
      if self.kind == "prof" then
        rstate.open[self.prof] = not rstate.open[self.prof] or nil
      elseif self.kind == "recipe" then
        rstate.prof, rstate.spell = self.prof, self.spell
      end
      drawRecipes()
    end)
  end)
  ru.rows[i] = b
  return b
end

-- ---------- the book in the kit list (ru.list) ----------
-- The box owns its frames: buildBookRow runs once per frame, initBookRow every time the box shows a row, so it sets
-- every field from the row. drawRecipes never hides, re-texts or indexes these frames; it clears the handles' data
-- (kind, prof, spell) before each SetRows.

local function bookClick(h)
  if h.kind == "prof" then
    rstate.open[h.prof] = not rstate.open[h.prof] or nil
  elseif h.kind == "recipe" then
    rstate.prof, rstate.spell = h.prof, h.spell
  end
  drawRecipes()
end

local function buildBookRow(frame)
  local h = { frame = frame }
  h.row = CraftHost.BookRow(frame, BOOK_LIST_W, BOOK_LIST_ROW_H)
  h.row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  h.row:SetScript("OnClick", function() CraftHost.Safe(bookClick, h) end)
  frame.h = h
  local ru = u.recipes
  ru.handles[#ru.handles + 1] = h
end

-- A profession row: toggle, profession icon, name. A recipe row: the item's icon (the unknown icon while uncached,
-- asked for under the draw's ITEM_REQUESTS, shared with scroll-time inits), or the profession icon when it makes no item.
local function initBookRow(frame, r)
  local h, ctx = frame.h, rstate.draw
  if not (h and type(r) == "table") then return end
  h.kind, h.prof, h.spell = r.kind, r.prof, r.spell
  local icon
  if r.kind == "recipe" and r.item then
    local name, quality, tex = CraftCompat.ItemInfo(r.item)
    if not name and ctx and ctx.asked < ITEM_REQUESTS then
      ctx.asked = ctx.asked + 1
      CraftCompat.RequestItem(r.item)
    end
    icon = CraftView.ItemCell(r.item, name, quality, tex).icon
  else
    icon = CraftHost.ProfessionIcon(r.prof)
  end
  CraftHost.SetBookRow(h.row, { kind = r.kind, text = r.text, icon = icon, open = rstate.open[r.prof] and true or false,
    chosen = r.kind == "recipe" and r.prof == rstate.prof and r.spell == rstate.spell })
end

-- The rows the book shows (every profession, the open ones' recipes) to the box. Every handle's data is cleared first
-- (data only): a frame the box no longer shows keeps no row to act for.
local function listBook(book)
  local ru = u.recipes
  local rows, prof = {}, nil
  for _, r in ipairs(book) do
    if r.kind == "prof" then
      prof = r.prof
      rows[#rows + 1] = { kind = "prof", prof = prof, text = r.text }
    elseif r.kind == "recipe" and rstate.open[prof] then
      rows[#rows + 1] = { kind = "recipe", prof = prof, spell = r.spell, item = r.item, text = r.text }
    end
  end
  for _, h in ipairs(ru.handles) do h.kind, h.prof, h.spell = nil, nil, nil end
  ru.list:SetRows(rows, true)
end

-- The book card from u.rlayout (relayout): bookW x bookH at the area's top left. Moves frames only.
local function placeBook()
  local ru, L = u.recipes, u.rlayout
  if not (ru and ru.card and L) then return end
  ru.card:ClearAllPoints()
  ru.card:SetPoint("TOPLEFT", L.bookX, -L.bookY)
  ru.card:SetSize(L.bookW, L.bookH)
end

local function placeText(b, x)
  local fs = b:GetFontString()
  if fs then
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", x, 0)
    fs:SetJustifyH("LEFT")
  end
end

-- ---------- the detail card (ru.detailCard) ----------
-- Built once in buildRecipes, every region the card's own (not pool frames); placed and sized by relayout from
-- u.rlayout; drawDetail fills, places and hides them (DetailFit), never creates.

-- The detail card from u.rlayout (relayout): detailW x detailH beside the book. Moves frames only.
local function placeDetail()
  local ru, L = u.recipes, u.rlayout
  if not (ru and ru.detailCard and L) then return end
  ru.detailCard:ClearAllPoints()
  ru.detailCard:SetPoint("TOPLEFT", L.detailX, 0)
  ru.detailCard:SetSize(L.detailW, L.detailH)
end

-- The index entry per (crafter, profession), built once per index: rank, max, online, seen for the Known by lines.
local function entryMap(index)
  if rstate.mapIndex ~= index or not rstate.map then
    local map = {}
    for _, e in ipairs(index and index.entries or {}) do map[e.key .. ":" .. tostring(e.prof)] = e end
    rstate.mapIndex, rstate.map = index, map
  end
  return rstate.map
end

local function hideDetail(d)
  local function off(r)
    if r.SetText then r:SetText("") end
    r:Hide()
  end
  for _, r in ipairs({ d.pick, d.icon, d.name, d.sub, d.makesLabel, d.makesIcon, d.makesText, d.knownLabel,
                       d.knownMore, d.reagentsLabel, d.reagentsMore }) do off(r) end
  if d.divider then d.divider:Hide() end
  for _, l in ipairs(d.known) do off(l.icon) off(l.name) off(l.rank) off(l.seen) end
  for _, l in ipairs(d.reagents) do off(l.icon) off(l.text) end
end

local D_X, D_LINE_X = 12, 36 -- the card's left pad; a Known by name after its class icon
local KNOWN_POOL, REAGENT_POOL = 39, 8 -- lines built once; DetailFit counts the "(+N more)" line in them

-- One point, the old ones cleared (a draw re-places the same regions).
local function at(r, ...)
  r:ClearAllPoints()
  r:SetPoint(...)
end

local function drawCard(prof, sel, known, nm)
  local ru = u.recipes
  local card, d, L = ru.detailCard, ru.d, u.rlayout
  hideDetail(d)
  if not sel then
    d.pick:SetText("Pick a profession, then a recipe, to see who knows it.")
    d.pick:Show()
    return
  end
  -- header: icon 36, name, "<Profession> · known by N", divider
  local cell
  if sel.item then
    local name, quality, tex = CraftCompat.ItemInfo(sel.item)
    if not name then CraftCompat.RequestItem(sel.item) end
    cell = CraftView.ItemCell(sel.item, name, quality, tex)
  end
  d.icon:SetTexture(cell and cell.icon or CraftHost.ProfessionIcon(prof))
  d.icon:Show()
  d.name:SetText(sel.text)
  d.name:Show()
  d.sub:SetText(CraftView.ProfessionName(prof) .. DOT .. "known by " .. #known)
  d.sub:Show()
  if d.divider then d.divider:Show() end
  -- reagents first (their count goes into the fit), asked at most ITEM_REQUESTS
  local reagents = CraftCompat.Reagents(sel.spell)
  local rn = { items = {}, spells = {}, version = 0 }
  local asked = 0
  for _, g in ipairs(reagents or {}) do
    local name = nm.items[g.itemID] or CraftCompat.ItemInfo(g.itemID)
    if name then
      rn.items[g.itemID] = name
    elseif asked < ITEM_REQUESTS then
      asked = asked + 1
      CraftCompat.RequestItem(g.itemID)
    end
  end
  local lines = CraftView.ReagentLines(reagents, rn)
  local fit = CraftView.DetailFit(L and L.detailH or card:GetHeight(), cell ~= nil, #known, #lines, #d.known, #d.reagents)
  if cell then
    d.makesLabel:SetText("Makes")
    at(d.makesLabel, "TOPLEFT", card, "TOPLEFT", D_X, -fit.makesY)
    d.makesLabel:Show()
    at(d.makesIcon, "TOPLEFT", card, "TOPLEFT", D_X, -(fit.makesY + 18))
    d.makesIcon:SetTexture(cell.icon)
    d.makesIcon:Show()
    d.makesText:SetText("|c" .. cell.color .. cell.text .. "|r")
    d.makesText:Show()
  end
  -- Known by: class icon, name (escaped, class colour), rank/max and last seen anchored from the card's right
  d.knownLabel:SetText("Known by")
  at(d.knownLabel, "TOPLEFT", card, "TOPLEFT", D_X, -fit.knownY)
  d.knownLabel:Show()
  local map, v, now = entryMap(rstate.index), view(), CraftCompat.Now()
  local rankRight, seenRight = L and L.rankRight or -130, L and L.seenRight or -12
  for i = 1, fit.knownLines do
    local k, l = known[i], d.known[i]
    local y = fit.knownY + 18 + (i - 1) * 18
    local e = map[k.key .. ":" .. tostring(prof)]
    local token, cr, cg, cb = crafterClass(v.roster and v.roster[k.key], v.crafters and v.crafters[k.key])
    at(l.icon, "TOPLEFT", card, "TOPLEFT", D_X, -(y + 1))
    l.icon:Show()
    if not CraftHost.ClassIcon(l.icon, token) then l.icon:Hide() end
    at(l.rank, "TOPRIGHT", card, "TOPRIGHT", rankRight, -(y + 2))
    l.rank:SetText(e and rankText(e.rank, e.max) or "")
    l.rank:Show()
    at(l.seen, "TOPRIGHT", card, "TOPRIGHT", seenRight, -(y + 2))
    l.seen:SetText(e and CraftView.LastSeen(e.seen, now, e.online) or "")
    if e and e.online then l.seen:SetTextColor(CraftHost.Green()) else l.seen:SetTextColor(1, 1, 1) end
    l.seen:Show()
    at(l.name, "TOPLEFT", card, "TOPLEFT", D_LINE_X, -(y + 2))
    l.name:SetPoint("RIGHT", l.rank, "LEFT", -8, 0)
    l.name:SetText(CraftView.SafeText(k.text)) -- names come from other players' messages (d377)
    l.name:SetTextColor(cr or 1, cg or 1, cb or 1)
    l.name:Show()
  end
  if fit.knownMore > 0 then
    at(d.knownMore, "TOPLEFT", card, "TOPLEFT", D_LINE_X, -(fit.knownY + 18 + fit.knownLines * 18 + 2))
    d.knownMore:SetText("(+" .. fit.knownMore .. " more)")
    d.knownMore:Show()
  end
  -- Reagents: icon 24 and today's line text, or the no-reagents line
  d.reagentsLabel:SetText("Reagents")
  at(d.reagentsLabel, "TOPLEFT", card, "TOPLEFT", D_X, -fit.reagentsY)
  d.reagentsLabel:Show()
  for i = 1, fit.reagentLines do
    local l, g = d.reagents[i], reagents and reagents[i]
    local y = fit.reagentsY + 18 + (i - 1) * 26
    at(l.icon, "TOPLEFT", card, "TOPLEFT", D_X, -y)
    if g then
      local name, quality, tex = CraftCompat.ItemInfo(g.itemID)
      l.icon:SetTexture(CraftView.ItemCell(g.itemID, name, quality, tex).icon)
      l.icon:Show()
      at(l.text, "TOPLEFT", card, "TOPLEFT", D_X + 30, -(y + 5))
    else
      at(l.text, "TOPLEFT", card, "TOPLEFT", D_X, -(y + 5))
    end
    l.text:SetPoint("RIGHT", card, "RIGHT", -D_X, 0)
    l.text:SetText(lines[i])
    l.text:Show()
  end
  if fit.reagentsMore > 0 then
    at(d.reagentsMore, "TOPLEFT", card, "TOPLEFT", D_X + 30, -(fit.reagentsY + 18 + fit.reagentLines * 26 + 5))
    d.reagentsMore:SetText("(+" .. fit.reagentsMore .. " more)")
    d.reagentsMore:Show()
  end
end

-- Builds the card's regions once, all hidden; the fixed ones anchored here, the rest by drawCard.
local function buildDetail(card)
  local d = { known = {}, reagents = {} }
  local function text(font, wrap)
    local fs = label(card, "", font)
    if wrap == false then fs:SetWordWrap(false) end
    return fs
  end
  local function tex(size)
    local t = card:CreateTexture(nil, "ARTWORK")
    t:SetSize(size, size)
    return t
  end
  d.pick = text("GameFontDisable")
  d.pick:SetPoint("TOPLEFT", card, "TOPLEFT", D_X, -12)
  d.pick:SetPoint("RIGHT", card, "RIGHT", -D_X, 0)
  d.icon = tex(36)
  d.icon:SetPoint("TOPLEFT", card, "TOPLEFT", D_X, -10)
  d.name = text("GameFontNormalLarge", false)
  d.name:SetPoint("TOPLEFT", card, "TOPLEFT", D_X + 44, -12)
  d.name:SetPoint("RIGHT", card, "RIGHT", -D_X, 0)
  d.sub = text("GameFontHighlightSmall", false)
  d.sub:SetPoint("TOPLEFT", card, "TOPLEFT", D_X + 44, -32)
  d.sub:SetPoint("RIGHT", card, "RIGHT", -D_X, 0)
  d.divider = CraftHost.Divider(card)
  if d.divider then
    d.divider:SetPoint("TOPLEFT", card, "TOPLEFT", D_X, -52)
    d.divider:SetPoint("TOPRIGHT", card, "TOPRIGHT", -D_X, -52)
  end
  d.makesLabel = text("GameFontNormalSmall")
  d.makesIcon = tex(24)
  d.makesText = text("GameFontHighlight", false)
  d.makesText:SetPoint("LEFT", d.makesIcon, "RIGHT", 6, 0)
  d.makesText:SetPoint("RIGHT", card, "RIGHT", -D_X, 0)
  d.knownLabel = text("GameFontNormalSmall")
  for i = 1, KNOWN_POOL do
    local l = { icon = tex(16), name = text("GameFontHighlightSmall", false) }
    l.rank = text("GameFontHighlightSmall", false)
    l.rank:SetWidth(70)
    l.rank:SetJustifyH("RIGHT")
    l.seen = text("GameFontHighlightSmall", false)
    l.seen:SetWidth(110)
    l.seen:SetJustifyH("RIGHT")
    d.known[i] = l
  end
  d.knownMore = text("GameFontDisableSmall")
  d.reagentsLabel = text("GameFontNormalSmall")
  for i = 1, REAGENT_POOL do
    local l = { icon = tex(24), text = text("GameFontHighlightSmall", false) }
    d.reagents[i] = l
  end
  d.reagentsMore = text("GameFontDisableSmall")
  hideDetail(d)
  return d
end

-- The selected recipe: what it makes, who knows it, and its reagents or the no-reagents line. On the card when there
-- is one; else today's lines on the panel.
local function drawDetail(book, nm)
  local ru = u.recipes
  local prof, sel, inSel, known = nil, nil, false, {}
  local selProf
  for _, r in ipairs(book) do
    if r.kind == "prof" then
      prof, inSel = r.prof, false
    elseif r.kind == "recipe" then
      inSel = prof == rstate.prof and r.spell == rstate.spell
      if inSel then sel, selProf = r, prof end
    elseif inSel then
      known[#known + 1] = r
    end
  end
  local L = u.rlayout -- the card size this draw is for; relayout redraws only when it changes
  ru.drawnW, ru.drawnH = L and L.detailW, L and L.detailH
  if ru.detailCard then return drawCard(selProf, sel, known, nm) end
  for i, k in ipairs(known) do known[i] = CraftView.SafeText(k.text) end
  local out = {}
  if not sel then
    out[1] = { text = "Pick a profession, then a recipe, to see who knows it.", font = "GameFontDisable" }
  else
    out[#out + 1] = { text = sel.text, font = "GameFontNormal" }
    if sel.item then
      local name, quality = CraftCompat.ItemInfo(sel.item)
      if not name then CraftCompat.RequestItem(sel.item) end
      local cell = CraftView.ItemCell(sel.item, name, quality, nil)
      out[#out + 1] = { text = "Makes |c" .. cell.color .. cell.text .. "|r" }
    end
    out[#out + 1] = { text = "Known by", font = "GameFontNormalSmall" }
    out[#out + 1] = { text = table.concat(known, ", ") }
    out[#out + 1] = { text = "Reagents", font = "GameFontNormalSmall" }
    local reagents = CraftCompat.Reagents(sel.spell)
    local rn = { items = {}, spells = {}, version = 0 }
    local asked = 0
    for _, g in ipairs(reagents or {}) do
      local name = nm.items[g.itemID] or CraftCompat.ItemInfo(g.itemID)
      if name then
        rn.items[g.itemID] = name
      elseif asked < ITEM_REQUESTS then
        asked = asked + 1
        CraftCompat.RequestItem(g.itemID)
      end
    end
    for _, line in ipairs(CraftView.ReagentLines(reagents, rn)) do out[#out + 1] = { text = line } end
  end
  for i = 1, DETAIL_LINES do
    local fs, o = ru.detail[i], out[i]
    if o then
      fs:SetFontObject(o.font or "GameFontHighlightSmall")
      fs:SetText(o.text)
      fs:Show()
    else
      fs:SetText("")
      fs:Hide()
    end
  end
end

drawRecipes = function()
  local ru = u.recipes
  if not ru then return end
  local nm = names()
  local book = recipeBook()
  rstate.draw = { asked = 0 } -- the item asks of this draw, read by initBookRow, also when the box scrolls
  if ru.list then
    listBook(book)
  else
    local n, prof = 0, nil
    for _, r in ipairs(book) do
      local show = r.kind == "prof" or (r.kind == "recipe" and rstate.open[prof])
      if r.kind == "prof" then prof = r.prof end
      if show then
        n = n + 1
        local b = bookRow(n)
        b.kind, b.prof, b.spell = r.kind, prof, r.spell
        b:SetText(r.text)
        placeText(b, r.kind == "prof" and 4 or 4 + INDENT)
        markSelected(b, r.kind == "recipe" and prof == rstate.prof and r.spell == rstate.spell)
        b:Show()
      end
    end
    for i = n + 1, #ru.rows do ru.rows[i]:Hide() end
    ru.content:SetHeight(math.max(1, n * BOOK_ROW_H))
  end
  ru.empty:SetShown(#book == 0)
  drawDetail(book, nm)
end

local function buildRecipes(p)
  local ru = { panel = p, rows = {}, detail = {}, handles = {} }
  u.recipes = ru
  -- The book: a card with the kit list (WowScrollBoxList + MinimalScrollBar) inside, placed by relayout (placeBook),
  -- else today's scroll frame and flat buttons
  ru.card = CraftHost.Card(p, BOOK_CARD_W, 1)
  if ru.card then
    ru.holder = CraftCompat.CreateFrame("Frame", nil, ru.card)
    ru.holder:SetPoint("TOPLEFT", BOOK_INSET, -BOOK_INSET)
    ru.holder:SetPoint("BOTTOMRIGHT", -BOOK_INSET, BOOK_INSET)
    ru.list = CraftHost.List(ru.holder, BOOK_LIST_ROW_H, buildBookRow, initBookRow)
    if not ru.list then
      ru.card:Hide()
      ru.card, ru.holder = nil, nil
    end
  end
  if ru.list then
    ru.empty = label(ru.card, "No shared recipes known yet.", "GameFontDisable")
    ru.empty:SetPoint("TOPLEFT", 8, -8)
  else
    ru.scroll, ru.content = scrollList(p)
    ru.scroll:SetPoint("TOPLEFT", 0, 0)
    ru.scroll:SetPoint("BOTTOMLEFT", 0, 0)
    ru.scroll:SetWidth(BOOK_W - 24)
    ru.empty = label(p, "No shared recipes known yet.", "GameFontDisable")
    ru.empty:SetPoint("TOPLEFT", 4, -4)
  end
  ru.empty:Hide()
  -- The detail card on both book paths, placed by relayout (placeDetail); without a card today's lines on the panel
  ru.detailCard = CraftHost.Card(p, 1, 1)
  if ru.detailCard then
    ru.d = buildDetail(ru.detailCard)
    return
  end
  for i = 1, DETAIL_LINES do
    local fs = label(p, "", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", BOOK_W + 8, -4 - (i - 1) * 18)
    fs:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    fs:Hide()
    ru.detail[i] = fs
  end
end

-- ---------- cooldowns tab ----------
-- One group per cooldown (CraftView.CooldownRows): a section header in the hub kit's look (Options_ListExpand, icon,
-- "<Group> · <Profession>", "n of m ready"), then 24 px rows: class icon, name, Ready, At, Last heard, and Whisper
-- only on a guildmate online on the roster. The summary and both checkbox counts come from the unfiltered groups;
-- Ready now / Online now filter the rows and drop a group left empty. Read only: no EditBox, no write, no send.
-- Everything lives in cd (CraftUI.lua is near LuaJIT's 200-local cap, f6626). The columns are offsets from the row's
-- right edge, so a resize moves nothing but the panel. Kit.List has one extent (24): a 26 px header sits 1 px over
-- each neighbour. Without Kit.List the panel shows the summary and the counts, no rows.
local cd = { ROW = 24, HDR = 26, READY = 130, AT = 96, LAST = 90, BTN = 76, HEAD_Y = 26, LIST_Y = 48, TICK = 60,
             state = { readyOnly = false, online = false }, boxes = {}, handles = {},
             COLUMN_TABS = "Interface\\FriendsFrame\\WhoFrame-ColumnTabs",
             NO_TIME = "The server time is not known yet. The cooldowns show once it is." }

-- A column header in Kit.ColumnHeader's look (not on M.Kit): the WhoFrame column tab in three parts, 19 tall.
function cd.column(p, text)
  local h = CraftCompat.CreateFrame("Frame", nil, p)
  h:SetHeight(19)
  local function part(l, r)
    local t = h:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(cd.COLUMN_TABS)
    t:SetTexCoord(l, r, 0, 0.59375)
    return t
  end
  local left, right, mid = part(0, 0.078125), part(0.90625, 0.96875), part(0.078125, 0.90625)
  left:SetSize(5, 19)
  left:SetPoint("TOPLEFT")
  right:SetSize(4, 19)
  right:SetPoint("TOPRIGHT")
  mid:SetPoint("TOPLEFT", left, "TOPRIGHT")
  mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
  label(h, text, "GameFontHighlightSmall"):SetPoint("LEFT", 8, 0)
  return h
end

-- Ready now / Online now: the game's checkbox (count in its label), else a chip button; key is cd.state's field.
function cd.check(p, x, key, text)
  local b = CraftHost.Checkbox(p, text)
  if b then
    b:SetPoint("TOPLEFT", p, "TOPRIGHT", x, 3)
    b:SetScript("OnClick", function(self)
      CraftHost.Safe(function() cd.state[key] = self:GetChecked() == true cd.draw() end)
    end)
  else
    b = flatButton(p, text, CHIP_W, CHIP_H)
    b:SetPoint("TOPLEFT", p, "TOPRIGHT", x, 0)
    b:SetScript("OnClick", function() CraftHost.Safe(function() cd.state[key] = not cd.state[key] cd.draw() end) end)
  end
  b.key, b.text0 = key, text
  cd.boxes[#cd.boxes + 1] = b
  return b
end

-- The hovered row: the name in its class colour, then CooldownTip's lines (when ready, Knows, Heard).
function cd.tip(frame)
  local r, tip = frame.cd and frame.cd.row, CraftHost.Tooltip()
  if not (r and tip) then return end
  local cr, cg, cb = CraftCompat.ClassColor(r.class)
  tip:SetOwner(frame, "ANCHOR_RIGHT")
  tip:SetText(CraftView.SafeText(r.name), cr or 1, cg or 1, cb or 1)
  for _, line in ipairs(CraftView.CooldownTip(r, date)) do tip:AddLine(line, 1, 1, 1, true) end
  tip:Show()
end

-- Kit.List's build: the header (26 tall, over the 24 slot) and the row's cells, all on the box's frame.
function cd.build(frame)
  local h = {}
  h.head = CraftCompat.CreateFrame("Frame", nil, frame)
  h.head:SetHeight(cd.HDR)
  h.head:SetPoint("TOPLEFT", 0, 1)
  h.head:SetPoint("TOPRIGHT", 0, 1)
  local l, m = h.head:CreateTexture(nil, "BACKGROUND"), h.head:CreateTexture(nil, "BACKGROUND")
  l:SetSize(12, cd.HDR)
  l:SetPoint("TOPLEFT")
  m:SetPoint("TOPLEFT", l, "TOPRIGHT")
  m:SetPoint("BOTTOMRIGHT")
  -- Kit.SectionHeader's bar, its mirrored right cap left out (the middle runs to the edge); else a rule under it
  if not (CraftHost.Atlas(l, "Options_ListExpand_Left") and CraftHost.Atlas(m, "_Options_ListExpand_Middle")) then
    l:Hide()
    m:Hide()
    local rule = CraftHost.Divider(h.head)
    if rule then
      rule:SetPoint("BOTTOMLEFT")
      rule:SetPoint("BOTTOMRIGHT")
    end
  end
  h.icon = h.head:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(16, 16)
  h.icon:SetPoint("TOPLEFT", 21, -5)
  h.label = label(h.head, "", "GameFontNormal")
  h.label:SetPoint("TOPLEFT", 43, -8)
  h.count = label(h.head, "", "GameFontHighlightSmall")
  h.count:SetPoint("TOPRIGHT", -21, -8)
  h.class = frame:CreateTexture(nil, "ARTWORK")
  h.class:SetSize(16, 16)
  h.class:SetPoint("TOPLEFT", 4, -4)
  local right = cd.BTN + cd.LAST + cd.AT
  h.name = label(frame, "", "GameFontHighlight")
  h.name:SetWordWrap(false)
  h.name:SetPoint("LEFT", 28, 0)
  h.name:SetPoint("RIGHT", frame, "RIGHT", -(right + cd.READY) - 2, 0)
  h.ready = label(frame, "", "GameFontHighlight")
  h.ready:SetPoint("LEFT", frame, "RIGHT", -(right + cd.READY) + 8, 0)
  h.at = label(frame, "", "GameFontHighlightSmall")
  h.at:SetPoint("LEFT", frame, "RIGHT", -right + 8, 0)
  h.last = label(frame, "", "GameFontHighlightSmall")
  h.last:SetPoint("LEFT", frame, "RIGHT", -(cd.BTN + cd.LAST) + 8, 0)
  h.whisper = panelButton(frame, "Whisper", 70)
  h.whisper:SetHeight(20) -- the mock's 20 in the 24 px row (f6605)
  h.whisper:SetPoint("LEFT", frame, "RIGHT", -cd.BTN + 2, 0)
  h.whisper:SetScript("OnClick", function(self) CraftHost.Safe(CraftUI.Whisper, self.name) end)
  h.hover = CraftHost.ListHover(frame, HIGHLIGHT)
  frame:SetScript("OnEnter", function(self) CraftHost.Safe(cd.tip, self) end)
  frame:SetScript("OnLeave", function()
    CraftHost.Safe(function()
      local tip = CraftHost.Tooltip()
      if tip then tip:Hide() end
    end)
  end)
  frame.cd = h
  cd.handles[#cd.handles + 1] = h
end

-- Kit.List's init: a { head = group } or { row = row } element; every field set both ways (frames are recycled).
function cd.init(frame, e)
  local h = frame.cd
  if not (h and type(e) == "table") then return end
  local g, r = e.head, e.row
  h.row, h.whisper.name = r, nil
  h.head:SetShown(g ~= nil)
  if h.hover then h.hover:SetShown(r ~= nil) end -- no hover on a section header (f6603)
  for _, k in ipairs({ "class", "name", "ready", "at", "last" }) do h[k]:SetShown(r ~= nil) end
  h.whisper:SetShown(r ~= nil and not r.own and r.online)
  if g then
    h.icon:SetTexture(g.icon)
    h.label:SetText(g.label)
    h.count:SetText(g.ready .. " of " .. g.total .. " ready")
    return
  end
  if not CraftHost.ClassIcon(h.class, r.class) then h.class:Hide() end
  local cr, cg, cb = CraftCompat.ClassColor(r.class)
  h.name:SetText(CraftView.SafeText(r.name) .. (r.tag and (" |cff999999" .. r.tag .. "|r") or "")) -- d377
  h.name:SetTextColor(cr or 1, cg or 1, cb or 1)
  h.ready:SetText(r.when)
  if r.state == "ready" then h.ready:SetTextColor(CraftHost.Green())
  elseif r.state == "unknown" then h.ready:SetTextColor(GREY, GREY, GREY)
  else h.ready:SetTextColor(1, 1, 1) end
  h.at:SetText(r.at)
  if r.state == "wait" then h.at:SetTextColor(1, 1, 1) else h.at:SetTextColor(GREY, GREY, GREY) end
  h.last:SetText(r.heard)
  if r.online then h.last:SetTextColor(CraftHost.Green())
  elseif r.heardGrey then h.last:SetTextColor(GREY, GREY, GREY)
  else h.last:SetTextColor(1, 1, 1) end
  if r.online and not r.own then h.whisper.name = r.name end
end

function cd.panelBuild(p)
  cd.panel = p
  cd.summary = label(p, "", "GameFontHighlightSmall")
  cd.summary:SetPoint("TOPLEFT", 6, -6)
  cd.summary:SetTextColor(GREY, GREY, GREY)
  cd.check(p, -300, "readyOnly", "Ready now")
  cd.check(p, -160, "online", "Online now")
  -- Name, Ready, At, Last heard over the list's box (the holder less Kit.List's 16 px bar)
  local edge = 16 + cd.BTN
  cd.columns = { cd.column(p, "Name"), cd.column(p, "Ready"), cd.column(p, "At"), cd.column(p, "Last heard") }
  cd.columns[1]:SetPoint("TOPLEFT", 0, -cd.HEAD_Y)
  cd.columns[1]:SetPoint("RIGHT", p, "RIGHT", -(edge + cd.LAST + cd.AT + cd.READY), 0)
  for i, w in ipairs({ cd.READY, cd.AT, cd.LAST }) do
    local c = cd.columns[i + 1]
    c:SetPoint("TOPLEFT", cd.columns[i], "TOPRIGHT")
    c:SetWidth(w)
  end
  cd.empty = label(p, "", "GameFontHighlight")
  cd.empty:SetPoint("TOPLEFT", 6, -6)
  cd.hint = label(p, CraftView.CD_EMPTY_HINT, "GameFontHighlightSmall")
  cd.hint:SetPoint("TOPLEFT", 6, -28)
  cd.hint:SetPoint("RIGHT", p, "RIGHT", -6, 0)
  cd.hint:SetTextColor(GREY, GREY, GREY)
  cd.holder = CraftCompat.CreateFrame("Frame", nil, p)
  cd.holder:SetPoint("TOPLEFT", 0, -cd.LIST_Y)
  cd.holder:SetPoint("BOTTOMRIGHT", 0, 0)
  cd.list = CraftHost.List(cd.holder, cd.ROW, cd.build, cd.init)
end

function cd.draw()
  if not cd.panel then return end
  local now, groups = CraftCompat.Now(), {}
  if now then
    local v, demo = view(), CraftHost.DemoState() ~= nil
    local fn = syncFn("Cooldowns")
    -- in demo no own character: the made-up guild has none of this account's
    groups = CraftView.CooldownRows({ mine = demo and {} or CraftHost.MyChars(), crafters = v.crafters,
      roster = v.roster, cooldowns = fn and fn() or {}, me = (not demo) and myKey() or nil, names = names(), fmt = date,
      own = (not demo) and CraftCompat.DB().cooldowns or nil }, now)
  end
  -- f6643: one pending redraw TICK s on keeps "in ..." and newly ready rows current; it dies while the tab is hidden
  if not cd.ticking then
    cd.ticking = true
    CraftHost.After(cd.TICK, function()
      cd.ticking = false
      if state.tab ~= "cooldowns" then return end
      -- rv1: with the window closed nothing draws; dirty makes the hub draw the tab when the window shows again
      if u.page and u.page:IsVisible() then cd.draw() else state.dirty = true end
    end)
  end
  local summary, ready, online = CraftView.CooldownSummary(groups)
  local empty = #groups == 0
  cd.empty:SetText(now and CraftView.CD_EMPTY or cd.NO_TIME)
  cd.empty:SetShown(empty)
  cd.hint:SetShown(empty and now ~= nil)
  cd.summary:SetText((string.gsub(summary, "%d+", "|cffffffff%0|r"))) -- the two counts white in the grey line (f6647)
  cd.summary:SetShown(not empty)
  for _, c in ipairs(cd.columns) do c:SetShown(not empty) end
  local counts = { readyOnly = "Ready now (" .. ready .. ")", online = "Online now (" .. online .. ")" }
  for _, b in ipairs(cd.boxes) do
    b:SetShown(not empty)
    if rawget(b, "label") then -- f6607: a chip fallback has no label (the sim's __index answers every name)
      b:SetChecked(cd.state[b.key])
      b.label:SetText(counts[b.key])
    else
      markSelected(b, cd.state[b.key])
      b:SetText(counts[b.key])
    end
  end
  local els = {}
  for _, g in ipairs(groups) do
    local head = #els + 1
    for _, r in ipairs(g.rows) do
      if (not cd.state.readyOnly or r.state == "ready") and (not cd.state.online or r.online) then
        if #els < head then els[head] = { head = g } end
        els[#els + 1] = { row = r }
      end
    end
  end
  cd.holder:SetShown(not empty)
  if not cd.list then return end
  for _, h in ipairs(cd.handles) do h.row, h.whisper.name = nil, nil end -- data only: a frame not shown acts for no one
  cd.list:SetRows(els, true)
end

local function draw()
  state.dirty = false
  if state.tab == "board" then drawBoard()
  elseif state.tab == "crafters" then drawCrafters()
  elseif state.tab == "recipes" then drawRecipes()
  elseif state.tab == "cooldowns" then cd.draw() end
end

local function redraw()
  state.dirty = true
  if u.page and u.page:IsShown() then draw() end
end

local function send(id, action)
  local fn = syncFn(action == "claim" and "Claim" or action == "keep" and "Keep" or "Change")
  local line
  if not fn then
    line = "Crafting sync is not running, so nothing was sent."
  elseif action == "claim" or action == "keep" then
    line = select(2, fn(id))
  else
    line = select(2, fn(id, action))
  end
  state.result = type(line) == "string" and line or nil
  redraw()
end

-- The Keep question naming the request ("Make Mooncloth x3 yours, ..."): the name made safe, " x<N>" only past one.
-- A request gone from the board or a name not known yet gives the fixed KEEP_ASK (never "item <id>").
local function keepAsk(req)
  if type(req) ~= "table" then return KEEP_ASK end
  local nm = rowNames({ req }) -- one request: at most one name, an item's or a recipe's
  local _, name = next(nm.items)
  if not name then _, name = next(nm.spells) end
  if not name then return KEEP_ASK end
  local q = tonumber(req.qty) or 1
  return "Make " .. CraftView.SafeText(name) .. (q > 1 and (" x" .. q) or "") .. " yours, with its quantity, tip and note?"
end

-- A row action: claim, drop, release, done, cancel or keep. Keep asks first through the confirm (d216); the
-- answer keeps the request that was clicked (this call's id, never a row's), also after a redraw before the answer.
function CraftUI.Act(id, action)
  if CraftHost.DemoInert() then return redraw() end
  if not id or not action then return end
  if action == "keep" then
    local board = view().board
    local text = keepAsk(type(board) == "table" and board[id] or nil)
    local function onOk()
      if CraftHost.DemoInert() then return redraw() end
      send(id, "keep")
    end
    -- Kit.Confirm tries StaticPopup again (it doubles % in its def, as Ask does) before its own window, which shows
    -- the text as passed (SetText, single % right).
    if not CraftHost.Ask("GUILDSYNC_CRAFT_KEEP", text, "Keep", "Cancel", onOk) then
      CraftHost.Confirm("GUILDSYNC_CRAFT_KEEP", text, "Keep", onOk)
    end
    return
  end
  send(id, action)
end

-- ---------- tabs and lists ----------

local function showTab(key)
  state.tab = key
  if not u.panels then return end -- before the page is built (ShowCraft opens it next; build shows state.tab)
  -- the top tab first, so a throw in the draw below still leaves the clicked tab chosen
  if u.topTabs then u.topTabs:Select(key == "board" and state.list or key) end
  for _, t in ipairs(TABS) do
    local on = t.key == key
    if u.tabs then markSelected(u.tabs[t.key], on) end
    if on then u.panels[t.key]:Show() else u.panels[t.key]:Hide() end
  end
  if key == "board" then clearGlow() end
  draw()
end

local function setList(key)
  state.list = key
  state.formOpen = false
  state.result = nil
end

local function showList(key)
  setList(key)
  draw()
end

-- A top tab: a board list (the board on that list) or Crafters / Recipes / Cooldowns.
local function onTop(key)
  if IS_LIST[key] then
    setList(key)
    showTab("board")
  else
    showTab(key)
  end
end

-- ---------- post form ----------

local function setLine(text) u.form.line:SetText(text or "") end

local NO_MATCH = "No one in the guild has a recipe for that."

local function hidePicks()
  local shown = false
  for _, b in ipairs(u.form.picks) do
    if b:IsShown() then shown = true end
    b.what = nil
    b:SetText("")
    b:Hide()
  end
  if shown then placeBoard() end -- the card shrinks back; the menu path leaves the scroll box alone
end

-- Closes the matches menu (CraftHost.MatchMenu), if one is open.
local function closeMatches()
  if u.form.menu then CraftHost.CloseMenu(u.form.menu) end
  u.form.menu = nil
end

-- Every recipe output and recipe name in the guild directory that matches, through the id index and names table.
local function pickResults(query)
  if string.len(query) < 2 then return {} end
  local nm = names()
  local rows = CraftView.Search(crafterIndex(), nm, query, PICK_CHIPS)
  local seen, out = {}, {}
  for _, r in ipairs(rows) do
    for _, h in ipairs(r.hits or {}) do
      local what = h.item and ("i" .. h.item) or ("s" .. h.spell)
      if not seen[what] then
        seen[what] = true
        local recipe = CraftView.RecipeLabel(h.spell, nm)
        local text = recipe
        if h.item then
          local item = nm.items[h.item] or ("item " .. h.item)
          text = (item == recipe) and item or (item .. " (" .. recipe .. ")")
          out[#out + 1] = { what = what, text = text, name = item, item = h.item }
        else
          out[#out + 1] = { what = what, text = text, name = recipe }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.text < b.text end)
  -- names come from the client's item and spell cache: every | doubled before they are drawn; name stays as is for
  -- the item box
  for _, r in ipairs(out) do r.text = CraftView.SafeText(r.text) end
  return out
end

local pick

-- The matches for query: the game's menu under the item box (CraftHost.MatchMenu, up to PICK_MAX entries with their
-- item icons, or the one no-match line), rebuilt per keystroke; without the menu system today's flat pick buttons.
-- Under 2 letters: no matches at all.
local function drawPicks(query)
  closeMatches()
  local results = pickResults(query)
  if string.len(query) >= 2 then
    local entries = {}
    for i = 1, math.min(#results, PICK_MAX) do
      local r = results[i]
      local icon = CraftView.UNKNOWN_ICON
      if r.item then icon = CraftView.ItemCell(r.item, CraftCompat.ItemInfo(r.item)).icon end
      entries[i] = { text = r.text, icon = icon, value = r }
    end
    local menu = CraftHost.MatchMenu(u.form.item, entries, function(e) pick(e.value.what, e.value.name) end, NO_MATCH)
    if menu then
      u.form.menu = menu
      hidePicks()
      setLine("")
      return
    end
  end
  hidePicks()
  for i = 1, math.min(#results, PICK_MAX) do
    local b = u.form.picks[i]
    b.what, b.name = results[i].what, results[i].name
    b:SetText(results[i].text)
    b:Show()
  end
  placeBoard() -- the card grows under the shown picks and the cards move down with it
  if string.len(query) >= 2 and #results == 0 then
    setLine(NO_MATCH)
  else
    setLine("")
  end
end

-- The item box's text changed: empty (typed away, the clear button, a reset) leaves no pick and no matches; typed
-- text drops the pick and shows the matches; a text set by pick or a shift-click keeps the pick.
local function onItemText(self, userInput)
  local text = textOf(self)
  if text == "" then
    form.what = nil
    closeMatches()
  end
  if not userInput then
    if text == "" then hidePicks() end
    return
  end
  form.what = nil
  drawPicks(text)
end

pick = function(what, name)
  form.what = what
  closeMatches()
  u.form.item:SetText(name or "")
  hidePicks()
  setLine("")
end

local function resetForm()
  form.what = nil
  closeMatches()
  hidePicks()
  u.form.item:SetText("")
  u.form.qty:SetText("1")
  u.form.tip:SetText("")
  u.form.note:SetText("")
  u.form.mats:SetChecked(false)
end

local function whole(text)
  local n = tonumber(text)
  if not n or n ~= math.floor(n) then return nil end
  return n
end

local function post()
  if CraftHost.DemoInert() then return setLine("") end
  if not form.what then return setLine("Pick an item from the list first.") end
  local qty = whole(textOf(u.form.qty))
  if not qty or qty < 1 or qty > QTY_MAX then return setLine("The quantity is 1 to 200.") end
  local tipText = textOf(u.form.tip)
  local tip = tipText == "" and 0 or whole(tipText)
  if not tip or tip < 0 or tip > TIP_MAX then return setLine("The tip is 0 to 9,999 gold.") end
  local fn = syncFn("Post")
  if not fn then return setLine("Crafting sync is not running, so nothing was posted.") end
  local ok, line = fn({ what = form.what, qty = qty, mats = isChecked(u.form.mats), tip = tip, hours = form.hours,
                        note = textOf(u.form.note) })
  if not ok then
    local text = type(line) == "string" and line ~= "" and line or "The request was not posted."
    return setLine((string.gsub(text, "[\r\n]+", " ")))
  end
  resetForm()
  -- posting closes the form; the Posted line shows under it and on the board's status line
  local done = "Posted. It stays on the Work board for " .. form.hours .. " h."
  setLine(done)
  state.result = done
  state.formOpen = false
  redraw()
end

local function openForm()
  state.formOpen = true
  setLine("")
  draw()
end

local function closeForm()
  state.formOpen = false
  draw()
end

-- shift-click on an item while the form is shown puts it in the item field
local function onLink(link)
  if not (u.form and state.formOpen and onScreen(u.form.item)) then return end
  local id = tonumber(string.match(link, "|Hitem:(%d+)"))
  if not id then return end
  pick("i" .. id, string.match(link, "|h%[(.-)%]|h") or ("item " .. id))
end

-- A form box through the kit (InputBoxInstructionsTemplate, else InputBoxTemplate), with today's caps and Escape /
-- Enter hooked (the template keeps its own scripts); today's editBox when the kit gives none.
local function formBox(parent, width, fallbackWidth, letters, numeric)
  local e = CraftHost.InputBox(parent, width, fallbackWidth)
  if e then
    e:SetAutoFocus(false)
    e:SetMaxLetters(letters)
    e:SetText("")
    e:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
  else
    e = editBox(parent, fallbackWidth, letters)
  end
  if numeric then e:SetNumeric(true) end
  return e
end

local function setHours(hours)
  form.hours = hours
  if u.form.hoursDropdown then CraftHost.DropdownText(u.form.hours, hours .. " h") else u.form.hours:SetText(hours .. " h") end
end

-- The form: a card areaW x 108 on top of the list (CraftView.BoardLayout's formW, formH), placed by placeBoard.
-- Row 1 (labels at y 10, fields at y 26): Item, Quantity, Tip in gold with the coin, Open for. Under the item its hint;
-- row 2 (y 76): I bring the mats, Cancel (x 176), Note (x 280, areaW - 412 wide) and Post request (areaW - 120). The result
-- line sits under the card.
local function buildForm(p)
  local f = CraftHost.Card(p, CARD_W * 2 + CARD_GAP, 108) or CraftCompat.CreateFrame("Frame", nil, p)
  local h = { panel = f, picks = {} }
  u.form = h

  local itemLabel = label(f, "Item", "GameFontNormalSmall")
  itemLabel:SetPoint("TOPLEFT", FORM_COL.item, -10)
  -- Item: the game's search box (its own scripts kept, so hooked), else today's box
  h.item = CraftHost.SearchBox(f, 240, "")
  if h.item then
    h.item:SetAutoFocus(false)
    h.item:SetMaxLetters(80)
    h.item:HookScript("OnTextChanged", function(self, userInput) CraftHost.Safe(onItemText, self, userInput) end)
    -- Escape and Enter close the matches; nothing on focus loss (form close, tab switch and demo close the menu by
    -- hiding its owner)
    h.item:HookScript("OnEscapePressed", function(self) CraftHost.Safe(closeMatches) self:ClearFocus() end)
    h.item:HookScript("OnEnterPressed", function(self) CraftHost.Safe(closeMatches) self:ClearFocus() end)
  else
    h.item = editBox(f, 240, 80)
    h.item:SetScript("OnTextChanged", function(self, userInput) CraftHost.Safe(onItemText, self, userInput) end)
  end
  h.item:SetPoint("TOPLEFT", FORM_COL.item + 4, -FORM_ROW1)
  local hint = label(f, hooked and "Type a recipe or item name, or shift-click an item."
    or "Type the item name.", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", FORM_COL.item, -(FORM_ROW1 + 24))
  for i = 1, PICK_MAX do
    local b = flatButton(f, "", 240, PICK_H - 1)
    b:SetPoint("TOPLEFT", FORM_COL.item, -PICKS_TOP - (i - 1) * PICK_H)
    placeText(b, 4)
    b:SetScript("OnClick", function(self) if self.what then CraftHost.Safe(pick, self.what, self.name) end end)
    b:Hide()
    h.picks[i] = b
  end

  local qtyLabel = label(f, "Quantity", "GameFontNormalSmall")
  qtyLabel:SetPoint("TOPLEFT", FORM_COL.qty, -10)
  h.qty = formBox(f, 50, 50, 3, true)
  h.qty:SetPoint("TOPLEFT", FORM_COL.qty + 4, -FORM_ROW1)
  h.qty:SetText("1")
  local tipLabel = label(f, "Tip in gold", "GameFontNormalSmall")
  tipLabel:SetPoint("TOPLEFT", FORM_COL.tip, -10)
  h.tip = formBox(f, 50, 60, 4, true)
  h.tip:SetPoint("TOPLEFT", FORM_COL.tip + 4, -FORM_ROW1)
  h.coin = f:CreateTexture(nil, "ARTWORK")
  h.coin:SetSize(13, 13)
  h.coin:SetPoint("LEFT", h.tip, "RIGHT", 4, 0)
  CraftHost.Atlas(h.coin, "coin-gold", "Interface\\MoneyFrame\\UI-GoldIcon")
  local hoursLabel = label(f, "Open for", "GameFontNormalSmall")
  hoursLabel:SetPoint("TOPLEFT", FORM_COL.hours, -10)
  -- Open for: the game's dropdown with a radio per HOURS entry, else today's button that cycles
  h.hours = CraftHost.Dropdown(f, 90, function(_, root)
    for _, v in ipairs(HOURS) do
      root:CreateRadio(v .. " h", function(hours) return form.hours == hours end,
        function(hours) CraftHost.Safe(setHours, hours) end, v)
    end
  end)
  if h.hours then
    h.hoursDropdown = true
    h.hours:SetPoint("TOPLEFT", FORM_COL.hours, -(FORM_ROW1 - 2))
    CraftHost.DropdownText(h.hours, form.hours .. " h")
  else
    h.hours = panelButton(f, form.hours .. " h", 60)
    h.hours:SetPoint("TOPLEFT", FORM_COL.hours, -(FORM_ROW1 - 1))
    h.hours:SetScript("OnClick", function()
      CraftHost.Safe(function()
        local nextH = HOURS[1]
        for i, v in ipairs(HOURS) do
          if v == form.hours then nextH = HOURS[i % #HOURS + 1] end
        end
        setHours(nextH)
      end)
    end)
  end
  h.mats = CraftHost.Checkbox(f, "I bring the mats") or checkButton(f, "I bring the mats")
  h.mats:SetChecked(false)
  h.mats:SetPoint("LEFT", f, "TOPLEFT", FORM_COL.item, -(FORM_ROW2 + 11))
  h.cancel = panelButton(f, "Cancel", 96)
  h.cancel:SetPoint("TOPLEFT", FORM_COL.cancel, -FORM_ROW2)
  h.cancel:SetScript("OnClick", function() CraftHost.Safe(closeForm) end)
  h.note = formBox(f, 296, 230, 80)
  h.note:SetPoint("TOPLEFT", FORM_COL.qty + 4, -FORM_ROW2)
  local hintText = rawget(h.note, "Instructions")
  if type(hintText) == "table" and type(hintText.SetText) == "function" then
    hintText:SetText("Note (optional)")
    h.noteGrows = true -- the template box follows the area's width; today's box keeps 230 at most
  else
    local noteLabel = label(f, "Note", "GameFontNormalSmall")
    noteLabel:SetPoint("BOTTOMLEFT", h.note, "TOPLEFT", -4, 2)
  end
  h.post = panelButton(f, "Post request", 108)
  h.post:SetScript("OnClick", function() CraftHost.Safe(post) end)
  h.line = label(f, "", "GameFontHighlightSmall")
  h.line:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 4, -4)
  h.line:SetPoint("RIGHT", f, "RIGHT", -8, 0)
  h.line:SetWordWrap(false)
  f:Hide()
end

-- ---------- the page ----------

-- flat: today's list buttons along the panel top (no top tabs); else the top tabs choose the list.
local function buildBoard(p, flat)
  if flat then
    local lists = {}
    u.lists = lists
    for i, l in ipairs(LISTS) do
      local b = flatButton(p, l.text, LIST_W, BUTTON_H)
      b:SetPoint("TOPLEFT", (i - 1) * (LIST_W + 4), 0)
      b:SetScript("OnClick", function() CraftHost.Safe(showList, l.key) end)
      lists[l.key] = b
    end
  end
  local new = panelButton(p, "New request", 120)
  new:SetPoint("TOPRIGHT", 0, 0)
  new:SetScript("OnClick", function() CraftHost.Safe(openForm) end)
  u.status = label(p, "", "GameFontHighlightSmall")
  u.status:SetPoint("TOPLEFT", 4, -BUTTON_H - 6)
  u.status:SetPoint("RIGHT", p, "RIGHT", -4, 0)
  u.status:SetWordWrap(false)

  -- the cards: Kit.List rows of two in a holder (u.scroll), else today's scroll frame with a card pool in its child
  local holder = CraftCompat.CreateFrame("Frame", nil, p)
  u.list = CraftHost.List(holder, CARD_H + CARD_GAP, buildCardRow, initCardRow)
  if u.list then
    u.scroll = holder
  else
    holder:Hide()
    u.scroll, u.content = scrollList(p)
    u.cards = {}
  end
  u.scroll:SetPoint("TOPLEFT", 0, -BUTTON_H - 26)
  u.scroll:SetPoint("BOTTOMRIGHT", -24, 0)

  buildForm(p)
  u.form.open = new
end

-- The page: the game's top tabs (For you, All open, Mine, Crafters, Recipes, Cooldowns) when CraftHost gives them, else
-- today's flat tabs (Work board, Crafters, Recipes, Cooldowns) with the list buttons on the board. The panels sit under
-- the tab row.
local function build(page)
  u.page = page
  u.panels = {}
  u.topTabs = CraftHost.Tabs(page, TOP_TABS, onTop)
  local flat = u.topTabs == nil
  if flat then u.tabs = {} end
  for i, t in ipairs(TABS) do
    if flat then
      local b = flatButton(page, t.text, TAB_W, TAB_H)
      b:SetNormalFontObject("GameFontNormal")
      b:SetText(t.text)
      b:SetPoint("TOPLEFT", (i - 1) * (TAB_W + 4), 0)
      b:SetScript("OnClick", function() CraftHost.Safe(showTab, t.key) end)
      u.tabs[t.key] = b
    end
    local p = CraftCompat.CreateFrame("Frame", nil, page)
    p:SetPoint("TOPLEFT", 0, -TAB_H - 8)
    p:SetPoint("BOTTOMRIGHT", 0, 0)
    u.panels[t.key] = p
  end
  u.board = u.panels.board
  buildBoard(u.board, flat)
  buildCrafters(u.panels.crafters)
  buildRecipes(u.panels.recipes)
  cd.panelBuild(u.panels.cooldowns)
  for _, t in ipairs(TABS) do
    if t.key == state.tab then u.panels[t.key]:Show() else u.panels[t.key]:Hide() end
  end
end

-- tab: "board" | "crafters" | "recipes" | "cooldowns", a board list "forYou" | "all" | "mine", or nil for the tab
-- shown last. focus (a search row's): { query } puts the name in the Crafters search box, { prof, spell } opens that
-- profession on Recipes with the recipe chosen; both are state, so a page built later shows them too.
local function onShow(tab, focus)
  if IS_LIST[tab] then
    setList(tab)
    tab = "board"
  end
  if type(focus) == "table" then
    if tab == "crafters" and type(focus.query) == "string" then
      cstate.prof, cstate.online = nil, false -- no filter hides the crafter asked for (f6641)
      chipsChanged()
      cstate.query = focus.query
      if u.crafters then u.crafters.search:SetText(focus.query) end
    elseif tab == "recipes" and focus.prof ~= nil and focus.spell ~= nil then
      rstate.prof, rstate.spell = focus.prof, focus.spell
      rstate.open[focus.prof] = true
    end
  end
  showTab(tab or state.tab)
end

-- A resize (and the first layout): the board area from CraftView.BoardLayout for the page box. Moves frames only.
local function relayout(L)
  if not (u.board and type(L) == "table") then return end
  local flat = u.topTabs == nil
  local B = CraftView.BoardLayout(L.contentW, L.contentH, flat)
  local regroup = u.layout ~= nil and u.layout.cols ~= B.cols
  u.layout = B
  u.board:ClearAllPoints()
  u.board:SetPoint("TOPLEFT", u.page, "TOPLEFT", B.areaX, -B.areaTop)
  u.board:SetSize(B.areaW, B.areaH)
  -- the Crafters, Recipes and Cooldowns panels on the same area box; their contents from CraftersLayout /
  -- RecipesLayout (Cooldowns' columns hang off its right edge)
  for _, key in ipairs({ "crafters", "recipes", "cooldowns" }) do
    local p = u.panels[key]
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", u.page, "TOPLEFT", B.areaX, -B.areaTop)
    p:SetSize(B.areaW, B.areaH)
  end
  u.clayout = CraftView.CraftersLayout(B.areaW)
  u.rlayout = CraftView.RecipesLayout(B.areaW, B.areaH)
  placeCrafters()
  placeBook()
  placeDetail()
  -- the detail's lines follow the card's new size (DetailFit); nothing is created; same size, no redraw
  local ru, RL = u.recipes, u.rlayout
  if ru and ru.detailCard and rstate.book and (ru.drawnW ~= RL.detailW or ru.drawnH ~= RL.detailH) then
    drawDetail(rstate.book, names())
  end
  u.status:ClearAllPoints()
  u.status:SetPoint("TOPLEFT", u.board, "TOPLEFT", 4, flat and -(BUTTON_H + 6) or -6)
  u.status:SetPoint("RIGHT", u.board, "RIGHT", flat and -4 or -(u.form.open:GetWidth() + 8), 0)
  placeBoard()
  -- one column <-> two: the drawn cards regrouped, no card frame built again
  if regroup and u.cardList then
    if u.list then u.list:SetRows(cardRows(u.cardList, B.cols), true) else placePool(#u.cardList) end
  end
end

local function isDirty()
  if state.dirty then return true end
  local fn = syncFn("Dirty")
  return fn and fn() and true or false
end

-- ---------- the hub's search (API 8) ----------
-- The registered find (CraftHost's thin wrapper) calls this. Read only and cheap: the tabs' id index and names, the
-- cooldown records through CraftSync; CraftView.SearchIndex runs again only on a new directory or roster, spell
-- name, cooldown state or demo state (dirVersion carries the demo serial). The item icon is asked only when cached.
function CraftHost.SearchFind(text)
  if type(text) ~= "string" then return nil end
  local nm = names()
  local cds, cv = syncFn("Cooldowns"), syncFn("CooldownVersion")
  local key = dirVersion() .. ":" .. tostring(nm.spellVersion) .. ":" .. tostring(cv and cv() or 0)
  if cstate.searchKey ~= key then
    cstate.search = CraftView.SearchIndex(crafterIndex(), nm, cds and cds() or {})
    cstate.searchKey = key
  end
  local rows = CraftView.SearchRows(cstate.search, text, CraftCompat.Now())
  for _, r in ipairs(rows) do
    if r.key then
      local focus = { query = r.name }
      r.open = function() CraftHost.ShowCraft("crafters", focus) end
    else
      local name, _, icon = CraftCompat.ItemInfo(r.item)
      r.icon = name and icon or CraftHost.ProfessionIcon(r.prof)
      local focus = { prof = r.prof, spell = r.spell }
      r.open = function() CraftHost.ShowCraft("recipes", focus) end
    end
  end
  return rows
end

-- /gsync demo on or off: the crafter chips (they cache the favourites) and every tab are drawn again.
CraftHost.OnDemo(function()
  chipsChanged()
  state.result = nil
  redraw()
end)

CraftHost.AddPage({ key = "craft", label = "Crafting", icon = PAGE_ICON, build = build, draw = draw,
                    onShow = onShow, dirty = isDirty, relayout = relayout,
                    seen = function() if state.tab == "board" then clearGlow() end end })

-- ---------- settings ----------

local SWITCHES = {
  { key = "share", text = "Share my recipes with the guild" },
  { key = "alertChat", text = "Chat line for a request I can make" },
  { key = "alertSound", text = "Sound for a request I can make" },
  { key = "alertGlow", text = "Glow on the minimap button" },
  { key = "alertPopup", text = "Popup for a request I can make" },
}

-- A switch's change: today's saved write and side effect, for the window's checkbox and the Options page alike.
local function applySwitch(key, on)
  local db = CraftCompat.DB()
  db.settings[key] = on
  if key == "alertGlow" then
    -- off hides a glow that is showing; on shows it again while an alert is unseen (f1028)
    CraftHost.SetGlow(on and db.glow == true)
  elseif key == "share" then
    local fn = syncFn("ShareChanged")
    if fn then fn() end
  end
end

for _, sw in ipairs(SWITCHES) do
  local key = sw.key
  sw.get = function() return CraftCompat.DB().settings[key] == true end
  sw.onSet = function(on) applySwitch(key, on) end
end

-- The retention values, NextRetention's walk; a stored value outside them reads as the store default.
local RETENTION_OK = { [14] = true, [30] = true, [60] = true, [90] = true, [0] = true }
local RETENTION = {
  get = function()
    local v = CraftCompat.DB().settings.retention
    if RETENTION_OK[v] then return v end
    return CraftCompat.SettingDefault("retention")
  end,
  set = function(v) if RETENTION_OK[v] then CraftCompat.DB().settings.retention = v end end,
}

local CLEARS = {
  recipes = { fn = "ClearRecipes", which = "GUILDSYNC_CLEAR_RECIPES",
              ask = "Clear the recipes recorded on this character?",
              done = "Recipes cleared on this character." },
  board = { fn = "ClearBoard", which = "GUILDSYNC_CLEAR_BOARD",
            ask = "Clear the work board and favourites for all your characters?",
            done = "Work board and favourites cleared for all your characters." },
}

local NOT_RUNNING = "Crafting sync is not running, so nothing was cleared."

-- Asks first; the clear runs only on the confirm's Clear button, and the outcome goes to chat.
local function clearClick(kind)
  if CraftHost.DemoInert() then return end
  local c = CLEARS[kind]
  CraftHost.Confirm(c.which, c.ask, "Clear", function()
    if CraftHost.DemoInert() then return end -- demo switched on while the popup was open
    local fn = syncFn(c.fn)
    if not fn then return CraftHost.Say(NOT_RUNNING) end
    fn()
    CraftHost.Say(c.done)
    redraw()
  end)
end

-- The Options page's rows (CraftHost): the switches (get, onSet), the retention (get, set) and the two clears.
local OPTION_CLEARS = {
  { name = "Recipes on this character", button = "Clear", click = function() clearClick("recipes") end },
  { name = "Work board and favourites", button = "Clear for all characters", click = function() clearClick("board") end },
}

CraftHost.AddSettings({ switches = SWITCHES, retention = RETENTION, clears = OPTION_CLEARS })

-- ---------- alert popup ----------

local function buildPopup()
  local f = CraftCompat.CreateFrame("Frame", "GuildSyncCraftAlert")
  f:SetSize(360, 96)
  f:SetPoint("TOP", 0, -140)
  f:SetFrameStrata("DIALOG")
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints(f)
  f.bg:SetColorTexture(0, 0, 0, 0.85)
  f.text = label(f, "", "GameFontHighlight")
  f.text:SetPoint("TOPLEFT", 12, -12)
  f.text:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.open = panelButton(f, "Open", 100)
  f.open:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 12)
  f.open:SetScript("OnClick", function()
    f:Hide()
    CraftHost.Safe(CraftHost.ShowCraft, "forYou")
  end)
  f.dismiss = panelButton(f, "Dismiss", 100)
  f.dismiss:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 12)
  f.dismiss:SetScript("OnClick", function() f:Hide() end)
  f:Hide()
  u.popup = f
  return f
end

-- The popup for a request this character can make: the game's StaticPopup through CraftHost.Ask, else today's
-- box. Open shows the Work board on For you; Dismiss only closes the popup. The item and recipe names are made safe
-- here (the requester's already is, CraftView's personName); Kit.Ask doubles every %. A second alert replaces the first: the
-- StaticPopup reuses the shown dialog of the same which, the box takes the new line.
function CraftUI.ShowAlert(req)
  if type(req) ~= "table" then return end
  local nm = rowNames({ req })
  for id, name in pairs(nm.items) do nm.items[id] = CraftView.SafeText(name) end
  for id, name in pairs(nm.spells) do nm.spells[id] = CraftView.SafeText(name) end
  local line = CraftView.AlertLine(req, nm, (CraftHost.Roster()))
  if CraftHost.Ask("GUILDSYNC_CRAFT_ALERT", line, "Open", "Dismiss", function() CraftHost.ShowCraft("forYou") end) then
    if u.popup then u.popup:Hide() end
    return
  end
  local f = u.popup or buildPopup()
  if not f then return end
  f.text:SetText(line)
  f:Show()
end

-- after Register: the hook goes through M (f4516)
CraftHost.Register()
hooked = CraftCompat.HookShiftClick(onLink) and true or false
