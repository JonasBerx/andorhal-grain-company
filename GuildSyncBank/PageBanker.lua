-- GuildSyncBank page, the Banker and Contributions tabs (bank/brief.md I19, E13, G17, H18, I21, J23; bank/cards.md
-- C7, C8; t58 V1, V3, V4). Appends three ns.TABS entries after Page.lua's four:
--   { id = "banker", label = "Banker", build, refresh, shown }      shown for a bank character (always under demo)
--   { id = "contributions", label = "Contributions", build, refresh, shown }   shown for everyone
--   { id = "gold", label = "Gold", build, refresh, shown }               shown for everyone (d1082: last)
-- ns.Banker.Prefill(item, wanted) fills New requisition at the next Banker refresh (d1096).
-- Both tabs draw with ns.Cards (Cards.lua) on the hub's M.Kit: New requisition is a Cards.FormCard in the list's form,
-- the mail line sits under the Pending sends header, and the Contributions header is four M.Kit.ColumnHeader buttons
-- with no click action. Every action goes through ns.Do. Mailbox matches come from ns.Mail.Match
-- and each needs a click: nothing is confirmed by a draw. Every text from another player goes through
-- GuildSync.Escape, and Banker cards carry no inline colour codes (I21). An item shows its icon as the card's icon
-- texture when the icon is a file id (D12); the amount is in a text line too, so an uncached item still shows it.
-- A pending send not heard from its owner (ns.Sync.Heard) offers no Received; its Cancel send only hides it on this
-- client (GuildSyncBankDB.hidden, d783).

local _, ns = ...
if not ns.M then return end

local M = ns.M
ns.TABS = ns.TABS or {}

local FORM_H = 22
local NAME_X, NAME_W, RIGHT_W = 50, 176, 80 -- the contribution columns, the same as Cards.lua draws the rows on
local uis = setmetatable({}, { __mode = "k" }) -- tab frame -> its widgets

-- AC10: control bytes (newlines included) never reach a FontString; each run becomes one space, then the escape.
local function E(s) return GuildSync.Escape((tostring(s or ""):gsub("%c+", " "))) end

-- the item's escaped name, its icon file id (or nil) and its quality
local function itemOf(id)
  local text, icon, _, quality = ns.Items.Line(id)
  return E(text), type(icon) == "number" and icon or nil, quality
end

local function nameOf(data, key)
  local r = data.ctx.roster and data.ctx.roster[key]
  return E(r and r.name or key)
end

local function act(verb, args)
  local good, msg = ns.Do(verb, args)
  if not good and msg then GuildSync.Say(msg) end
  M.RefreshPage()
  return good
end

-- Name candidates for item entry (I20): every item in the view's contents, requisitions and requests.
local function candidates(view)
  local ids, seen = {}, {}
  local function add(id) if id and not seen[id] then seen[id] = true ids[#ids + 1] = id end end
  for id in pairs(view and view.items or {}) do add(id) end
  for _, req in ipairs(view and view.reqs or {}) do add(req.item) end
  for _, q in ipairs(view and view.requests or {}) do add(q.item) end
  return ids
end

-- An item entry box: the shift-click target while it has focus; it lets go on focus lost or hide.
local function itemEntry(b)
  local function release(self) if ns.Items.Target() == self then ns.Items.SetTarget(nil) end end
  b:HookScript("OnEditFocusGained", function(self) M.Safe(ns.Items.SetTarget, self) end)
  b:HookScript("OnEditFocusLost", function(self) M.Safe(release, self) end)
  b:HookScript("OnHide", function(self) M.Safe(release, self) end)
end

-- a grey text line inside parent at y, with a right bound, no wrap
local function line(parent, y, x)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  ns.Cards.Grey(fs)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x or ns.Cards.PAD_L, -y)
  fs:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -ns.Cards.PAD_R, -y)
  return fs
end

-- ---------- Banker ----------

-- d783 (V5): a pending send not heard from its owner offers no Received, only this line; Cancel send hides it on this
-- client (GuildSyncBankDB.hidden: "<req>@<member>@<at>" -> when hidden, at most HIDDEN_MAX, the oldest dropped first)
-- and writes no unsend.
local UNCONFIRMED = "unconfirmed: open the mailbox to match it"
local HIDDEN_MAX = 200

local function hiddenList()
  local db = ns.DB()
  if type(db.hidden) ~= "table" then db.hidden = {} end
  return db.hidden
end

local function hideKey(req, member, at) return tostring(req) .. "@" .. tostring(member) .. "@" .. tostring(at) end

local function hide(key, now)
  local h = hiddenList()
  local n = 0
  for _ in pairs(h) do n = n + 1 end
  while n >= HIDDEN_MAX do
    local oldest, when
    for k, v in pairs(h) do
      local t = tonumber(v) or 0
      if oldest == nil or t < when or (t == when and k < oldest) then oldest, when = k, t end
    end
    h[oldest] = nil
    n = n - 1
  end
  h[key] = now or 0
  M.RefreshPage()
end

local function sorted(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function buildBanker(frame)
  local Cards = ns.Cards
  local ui = { list = Cards.List(frame, 124) }
  uis[frame] = ui

  -- the New requisition card in the list's form: item, wanted, why, Post requisition
  local panel = Cards.FormCard(ui.list.form, "New requisition")
  ui.panel = panel
  ui.item = Cards.ItemBox(panel, 180, "Item: shift-click, link or id")
  ui.item:SetPoint("TOPLEFT", panel, "TOPLEFT", Cards.PAD_L, -30)
  itemEntry(ui.item)
  ui.wanted = Cards.Box(panel, 50, "Wanted")
  ui.wanted:SetPoint("LEFT", ui.item, "RIGHT", 8, 0)
  ui.post = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  ui.post:SetSize(120, FORM_H)
  ui.post:SetText("Post requisition")
  ui.post:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -Cards.PAD_R, -30)
  ui.why = Cards.Box(panel, 160, "Why")
  ui.why:SetPoint("LEFT", ui.wanted, "RIGHT", 8, 0)
  ui.why:SetPoint("RIGHT", ui.post, "LEFT", -8, 0)
  ui.item.nextEditBox, ui.wanted.previousEditBox = ui.wanted, ui.item -- Tab order: Item, Wanted, Why
  ui.wanted.nextEditBox, ui.why.previousEditBox = ui.why, ui.wanted
  ui.post:SetScript("OnClick", function()
    M.Safe(function()
      local data = ui.data
      local id, why = ns.Items.Parse(ui.item:GetText(), candidates(data and data.view))
      if not id then GuildSync.Say(why) return end
      act("post", { item = id, wanted = tonumber(ui.wanted:GetText()), why = ui.why:GetText() or "" })
    end)
  end)

  -- the Minimum stock card under it (V3): item, Minimum, the Raid night toggle, Set, Clear
  local mins = Cards.FormCard(ui.list.form, "Minimum stock")
  mins:ClearAllPoints()
  mins:SetPoint("TOPLEFT", ui.list.form, "TOPLEFT", 0, -64)
  mins:SetPoint("TOPRIGHT", ui.list.form, "TOPRIGHT", 0, -64)
  ui.minItem = Cards.ItemBox(mins, 180, "Item: shift-click, link or id")
  ui.minItem:SetPoint("TOPLEFT", mins, "TOPLEFT", Cards.PAD_L, -30)
  itemEntry(ui.minItem)
  ui.min = Cards.Box(mins, 60, "Minimum")
  ui.min:SetPoint("LEFT", ui.minItem, "RIGHT", 8, 0)
  ui.minItem.nextEditBox, ui.min.previousEditBox = ui.min, ui.minItem
  ui.raidBtn = CreateFrame("Button", nil, mins, "UIPanelButtonTemplate")
  ui.raidBtn:SetSize(110, FORM_H)
  ui.raidBtn:SetPoint("LEFT", ui.min, "RIGHT", 8, 0)
  ui.clear = CreateFrame("Button", nil, mins, "UIPanelButtonTemplate")
  ui.clear:SetSize(64, FORM_H)
  ui.clear:SetText("Clear")
  ui.clear:SetPoint("TOPRIGHT", mins, "TOPRIGHT", -Cards.PAD_R, -30)
  ui.set = CreateFrame("Button", nil, mins, "UIPanelButtonTemplate")
  ui.set:SetSize(64, FORM_H)
  ui.set:SetText("Set")
  ui.set:SetPoint("RIGHT", ui.clear, "LEFT", -8, 0)
  local function minId()
    local data = ui.data
    return ns.Items.Parse(ui.minItem:GetText() or "", candidates(data and data.view))
  end
  local function showRaid() ui.raidBtn:SetText(ui.raidOn and "Raid night: on" or "Raid night: off") end
  -- d1083: a changed item text sets the default (class 0, subclass 1-3 on; else and without the api off); a click wins
  -- until the text changes again
  ui.minText, ui.raidOn = "", false
  ui.minItem:HookScript("OnTextChanged", function(self)
    M.Safe(function()
      local t = self:GetText() or ""
      if t == ui.minText then return end
      ui.minText = t
      local id = minId()
      local class, sub
      if id then class, sub = select(6, M.Compat.call("C_Item.GetItemInfoInstant", id)) end
      class, sub = GuildSync.Compat.Plain(class), GuildSync.Compat.Plain(sub)
      ui.raidOn = class == 0 and (sub == 1 or sub == 2 or sub == 3)
      showRaid()
    end)
  end)
  ui.raidBtn:SetScript("OnClick", function() M.Safe(function() ui.raidOn = not ui.raidOn showRaid() end) end)
  local function sendMinimum(clear)
    M.Safe(function()
      local id, why = minId()
      if not id then GuildSync.Say(why) return end
      if clear then act("minimum", { item = id, min = 0 })
      else act("minimum", { item = id, min = tonumber(ui.min:GetText()), raid = ui.raidOn }) end
    end)
  end
  ui.set:SetScript("OnClick", function() sendMinimum(false) end)
  ui.clear:SetScript("OnClick", function() sendMinimum(true) end)
  showRaid()
end

-- d1096 (V4): Prefill(item, wanted) fills the New requisition card at the next Banker refresh: the item's link when
-- the client has it cached, else its id; Wanted; Why "Restock".
local Banker = {}
ns.Banker = Banker
local prefill

function Banker.Prefill(item, wanted) prefill = { item = item, wanted = wanted } end

local function applyPrefill(ui)
  local p = prefill
  if not p then return end
  prefill = nil
  local text = tostring(p.item)
  local cached = true
  if GuildSync.Compat.Has("C_Item.IsItemDataCachedByID") then
    cached = GuildSync.Compat.Plain(M.Compat.call("C_Item.IsItemDataCachedByID", p.item))
  end
  if cached then
    local _, link = M.Compat.call("C_Item.GetItemInfo", p.item)
    link = GuildSync.Compat.Plain(link)
    if type(link) == "string" and link:find("|Hitem:", 1, true) then text = link end
  end
  ui.item:SetText(text)
  ui.wanted:SetText(tostring(p.wanted or ""))
  ui.why:SetText("Restock")
end

-- a section: its header with the count, then the grey line `first` when given, then its cards, or one grey "None."
local function section(ui, title, specs, first)
  local Cards = ns.Cards
  Cards.Section(ui.list, title .. " · " .. #specs)
  if first then Cards.Line(ui.list, first) end
  if #specs == 0 then Cards.Line(ui.list, "None.") end
  for _, spec in ipairs(specs) do Cards.Card(ui.list, spec) end
end

local function refreshBanker(frame, data)
  local ui = uis[frame]
  if not ui then buildBanker(frame) ui = uis[frame] end
  ui.data = data
  applyPrefill(ui)
  local Cards = ns.Cards
  local view, now = data.view, data.now
  Cards.Begin(ui.list)

  -- the minimums set (V3, mock ledger-4: first, right under the Minimum stock form), drawn only when one is set: a
  -- cleared one (min 0) is not listed; each row's Clear sends min 0
  local mins = {}
  for id, m in pairs(view.mins or {}) do
    if type(m) == "table" and (m.min or 0) > 0 then
      local name, icon, quality = itemOf(id)
      mins[#mins + 1] = { kind = "strip", key = "n:" .. tostring(id), item = id, icon = icon, title = name,
        quality = quality, sortKey = name,
        sub = { "min " .. m.min .. (m.raid and " · Raid night" or "") .. " · set by " .. nameOf(data, m.by) .. " "
          .. Cards.Ago(now, m.at) },
        strip = { buttons = { { "Clear", function() act("minimum", { item = id, min = 0 }) end, 64 } } } }
    end
  end
  table.sort(mins, function(a, b) if a.sortKey ~= b.sortKey then return a.sortKey < b.sortKey end return a.item < b.item end)
  if #mins > 0 then section(ui, "Minimums", mins) end

  -- the mail line under the Pending sends header: none while the mailbox reads
  local readable, why = ns.Mail.Readable()
  local mails = readable and ns.Mail.Current() or nil
  local mailLine
  if not readable then
    mailLine = why .. " (confirm deliveries by hand)"
  elseif not mails then
    mailLine = "Open the mailbox to match deliveries."
  end

  -- pending sends and pledges, per requisition
  local pending, sends = {}, {}
  local hidden = data.isDemo and {} or hiddenList()
  for _, req in ipairs(view.reqs) do
    for _, m in ipairs(sorted(req.sends)) do
      local s = req.sends[m]
      local hk = hideKey(req.id, m, s.at)
      if s.status == "pending" and hidden[hk] == nil then
        pending[#pending + 1] = { req = req.id, member = m, item = req.item, amount = s.amount, at = s.at }
        local name, icon, quality = itemOf(req.item)
        local strip
        if data.isDemo or ns.Sync.Heard(m) then
          strip = { buttons = {
            { "Received", function() act("receive", { id = req.id, member = m }) end, 80 },
            { "Cancel send", function() act("unsend", { id = req.id, member = m }) end, 92 },
          } }
        else
          strip = { label = UNCONFIRMED, buttons = {
            { "Cancel send", function() hide(hk, now) end, 92 },
          } }
        end
        sends[#sends + 1] = { kind = "strip", key = "s:" .. req.id .. "@" .. m, item = req.item, icon = icon, count = s.amount,
          title = name .. " from " .. nameOf(data, m), quality = quality, when = Cards.Ago(now, s.at),
          sub = { s.amount .. " sent for " .. E(req.why) }, strip = strip }
      end
    end
  end
  section(ui, "Pending sends", sends, mailLine)

  local pledges = {}
  for _, req in ipairs(view.reqs) do
    if req.status == "open" then
      for _, m in ipairs(sorted(req.pledges)) do
        local p = req.pledges[m]
        local name, icon, quality = itemOf(req.item)
        pledges[#pledges + 1] = { kind = "strip", key = "p:" .. req.id .. "@" .. m, item = req.item, icon = icon, count = p.amount,
          title = nameOf(data, m), itemName = name, itemQuality = quality, when = Cards.Ago(now, p.at),
          sub = { p.amount .. " " .. name .. " for " .. E(req.why) },
          strip = { buttons = { { "Remove", function() act("unpledge", { id = req.id, member = m }) end, 72 } } } }
      end
    end
  end
  section(ui, "Pledges", pledges)

  -- mailbox matches: a Received button each, partials listed without one
  if mails then
    local matches, partials = ns.Mail.Match(mails, pending, data.ctx.roster, GuildSync.Comm.Key)
    local inbox = {}
    for _, m in ipairs(matches) do
      local name, icon, quality = itemOf(m.item)
      inbox[#inbox + 1] = { kind = "strip", key = "m:" .. m.req .. "@" .. m.member, item = m.item, icon = icon, count = m.count,
        title = name .. " from " .. nameOf(data, m.member), quality = quality,
        sub = { m.count .. " in the mailbox, matches a pending send" },
        strip = { buttons = { { "Received", function() act("receive", { id = m.req, member = m.member }) end, 80 } } } }
    end
    for _, m in ipairs(partials) do
      local name, icon, quality = itemOf(m.item)
      inbox[#inbox + 1] = { kind = "plain", key = "x:" .. m.req .. "@" .. m.member, item = m.item, icon = icon, count = m.count,
        title = name .. " from " .. nameOf(data, m.member), quality = quality,
        sub = { m.count .. " of " .. m.amount .. " in the mailbox (partial, confirm by hand)" } }
    end
    section(ui, "In the mailbox", inbox)
  end

  -- requests to answer: each card's Decline sends that card's own reason
  local asks = {}
  for _, q in ipairs(view.requests) do
    if not q.answer then
      local name, icon, quality = itemOf(q.item)
      local note = (q.note ~= nil and q.note ~= "") and E(q.note) or "no note"
      asks[#asks + 1] = { kind = "strip", key = "r:" .. q.member .. "@" .. tostring(q.at), item = q.item, icon = icon, count = q.count,
        title = nameOf(data, q.member), itemName = name, itemQuality = quality, when = Cards.Ago(now, q.at),
        sub = { q.count .. " " .. name .. " · " .. note },
        strip = { box = 150, hint = "Decline reason", buttons = {
          { "Fulfilled", function() act("fulfil", { member = q.member, at = q.at }) end, 80 },
          { "Decline", function(card)
            if act("decline", { member = q.member, at = q.at, reason = card.box:GetText() or "" }) then card.box:SetText("") end
          end, 72 },
        } } }
    end
  end
  section(ui, "Requests", asks)

  Cards.End(ui.list)
end

-- ---------- Contributions ----------

-- The caption and the header in the list's form: four M.Kit.ColumnHeader buttons over the rows' columns, no click
-- action (R1); This month carries the "desc" sort arrow, All time's label is right-aligned (d666). The columns as bk-6:
-- rank 0..42, Character up to 4 before the bar, This month on to 8 past the bar's end, All time the rest.
local function buildContrib(frame)
  local Cards, K = ns.Cards, M.Kit
  local ui = { list = Cards.List(frame, 44) }
  uis[frame] = ui
  local form = ui.list.form
  line(form, 0, 0):SetText("Delivered to the bank, per character. Sorted by this month.")
  ui.head = CreateFrame("Frame", nil, form)
  ui.head:SetPoint("TOPLEFT", form, "TOPLEFT", 0, -25)
  ui.head:SetPoint("TOPRIGHT", form, "TOPRIGHT", 0, -25)
  ui.head:SetHeight(19)
  local nameL = NAME_X -- where the row's name starts; a header's label sits 8 in
  local rank = K.ColumnHeader(ui.head, "")
  local name = K.ColumnHeader(ui.head, "Character")
  local month = K.ColumnHeader(ui.head, "This month")
  local all = K.ColumnHeader(ui.head, "All time")
  if not (rank and name and month and all) then return end
  rank:SetPoint("TOPLEFT", ui.head, "TOPLEFT", 0, 0)
  rank:SetWidth(nameL - 8)
  name:SetPoint("TOPLEFT", rank, "TOPRIGHT", 0, 0)
  name:SetWidth(NAME_W + Cards.GAP + 4)
  all:SetPoint("TOPRIGHT", ui.head, "TOPRIGHT", 0, 0)
  all:SetWidth(RIGHT_W + Cards.PAD_R + Cards.GAP - 8)
  month:SetPoint("TOPLEFT", name, "TOPRIGHT", 0, 0)
  month:SetPoint("TOPRIGHT", all, "TOPLEFT", 0, 0)
  K.SortArrow(month, "desc")
  all.label:ClearAllPoints()
  all.label:SetPoint("RIGHT", all, "RIGHT", -Cards.PAD_R, 0)
  all.label:SetJustifyH("RIGHT")
end

local function refreshContrib(frame, data)
  local ui = uis[frame]
  if not ui then buildContrib(frame) ui = uis[frame] end
  local Cards = ns.Cards
  Cards.Begin(ui.list)
  -- sorted by this month, then all time, then key (the view sorts by all time)
  local rows, top = {}, 0
  for _, c in ipairs(data.view.contributions) do
    rows[#rows + 1] = c
    if c.month > top then top = c.month end
  end
  table.sort(rows, function(x, y)
    if x.month ~= y.month then return x.month > y.month end
    if x.all ~= y.all then return x.all > y.all end
    return x.member < y.member
  end)
  ui.head:SetShown(#rows > 0)
  if #rows == 0 then
    Cards.Line(ui.list, "Nothing received yet.")
  else
    for i, c in ipairs(rows) do
      Cards.Card(ui.list, { kind = "contrib", key = c.member, rank = i, title = nameOf(data, c.member),
        bar = { value = c.month, max = top, text = tostring(c.month) }, right = tostring(c.all) })
    end
  end
  Cards.End(ui.list)
end

-- ---------- Gold ----------

-- V1 (mock ledger-1): the total, the disclaimer (d1093), the holder cards three to a row (each bank character, then the
-- guild bank), then the newest ENTRIES_MAX entries under five M.Kit.ColumnHeader heads, one row of five cells each
-- (d1081, d1095). The tab lays itself out on the list's scroll child (as Contributions builds its header), not through
-- Cards.lua's two-column groups.
local ENTRIES_MAX = 50
local DISCLAIMER = "Entries are what each bank character's addon recorded; the game does not check them."
local KINDS = {
  m = { "Mail in", "Mail out" }, g = { "Guild bank withdrawal", "Guild bank deposit" },
  v = { "Vendor sale", "Vendor spend" }, o = { "Other gain", "Other spend" },
  s = { "Change while the addon was off", "Change while the addon was off" },
}
local HOLDER_H, HOLDER_GAP, ROW_H, HEAD_H, ENTRY_H, ENTRY_GAP, MONEY_W = 56, 10, 22, 19, 26, 4, 100
local GAIN, LOSS, GOLD_C = { 0.2, 0.75, 0.25 }, { 0.9, 0.25, 0.25 }, { 1, 0.82, 0 } -- the Amount, the holder money
local COLS = { { "When", 120 }, { "Holder", 140 }, { "Amount", 110 }, { "What" }, { "After", 110 } } -- What takes the rest

-- the five cells of an entry: date, holder, signed money, what, balance after
local function entryCells(data, e)
  local kind = KINDS[e.k] or KINDS.o
  local what = kind[e.d > 0 and 1 or 2]
  if e.k == "m" and e.w then what = what .. (e.d > 0 and " from " or " to ") .. E(e.w) end
  return { date("%Y-%m-%d %H:%M", e.t), nameOf(data, e.holder), (e.d > 0 and "+" or "") .. ns.Money(e.d), what,
    ns.Money(e.after) }
end

-- the x and width of each column at list width w
local function columns(w)
  local fixed = 0
  for _, col in ipairs(COLS) do fixed = fixed + (col[2] or 0) end
  local out, x = {}, 0
  for i, col in ipairs(COLS) do
    local cw = col[2] or math.max(40, w - fixed)
    out[i] = { x = x, w = cw }
    x = x + cw
  end
  return out
end

local function header(list)
  local h = M.Kit.SectionHeader(list, ns.Cards.LIST_W, "")
  if h then return h, h.label end
  local fs = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetJustifyH("LEFT")
  return fs, fs
end

local function buildGold(frame)
  local Cards, K = ns.Cards, M.Kit
  local ui = { list = Cards.List(frame, 0), holders = {}, rows = {} }
  uis[frame] = ui
  local list = ui.list.list
  ui.top, ui.topLabel = header(list)
  ui.disc = line(list, 0, 0)
  ui.disc:SetText(DISCLAIMER)
  ui.unread = line(list, 0, 0)
  ui.unread:SetText("Guild bank gold: not read yet.")
  ui.recent, ui.recentLabel = header(list)
  ui.empty = line(list, 0, 0)
  ui.empty:SetText("No gold entries yet.")
  ui.head = CreateFrame("Frame", nil, list)
  ui.head:SetHeight(HEAD_H)
  ui.heads = {}
  for i, col in ipairs(COLS) do ui.heads[i] = K.ColumnHeader(ui.head, col[1]) end
end

local function holderCard(ui, i)
  local card = ui.holders[i]
  if card then return card end
  local list = ui.list.list
  card = M.Kit.Card(list, 200, HOLDER_H) or CreateFrame("Frame", nil, list)
  card.cardKind = "holder"
  card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)
  card.title:SetPoint("TOPLEFT", card, "TOPLEFT", ns.Cards.PAD_L, -8)
  card.title:SetPoint("TOPRIGHT", card, "TOPRIGHT", -ns.Cards.PAD_R, -8)
  -- the money on its own line in gold, the age at that line's right (mock ledger-1)
  card.money = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.money:SetJustifyH("LEFT")
  card.money:SetWordWrap(false)
  card.money:SetTextColor(GOLD_C[1], GOLD_C[2], GOLD_C[3])
  card.money:SetPoint("TOPLEFT", card, "TOPLEFT", ns.Cards.PAD_L, -30)
  card.money:SetWidth(MONEY_W)
  card.age = line(card, 31, ns.Cards.PAD_L + MONEY_W + ns.Cards.GAP)
  card.age:SetJustifyH("RIGHT")
  ui.holders[i] = card
  return card
end

local function entryRow(ui, i)
  local row = ui.rows[i]
  if row then return row end
  -- a row card as the mock's: date grey, Amount green or red (set per entry), After right-aligned
  row = M.Kit.Card(ui.list.list, 200, ENTRY_H) or CreateFrame("Frame", nil, ui.list.list)
  row.cardKind = "entry"
  row:SetHeight(ENTRY_H)
  row.cells = {}
  for j = 1, #COLS do
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(j == #COLS and "RIGHT" or "LEFT")
    fs:SetWordWrap(false)
    row.cells[j] = fs
  end
  ns.Cards.Grey(row.cells[1])
  ui.rows[i] = row
  return row
end

-- put f at y in the list, w wide; answers the y under it
local function place(ui, f, y, h, w)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", ui.list.list, "TOPLEFT", 0, -y)
  f:SetWidth(w)
  if h then f:SetHeight(h) end
  f:Show()
  return y + (h or ROW_H)
end

local function refreshGold(frame, data)
  local ui = uis[frame]
  if not ui then buildGold(frame) ui = uis[frame] end
  local Cards = ns.Cards
  local gold, now = data.view.gold or { total = 0, holders = {}, entries = {} }, data.now
  local w = Cards.Width(ui.list)
  local list = ui.list.list
  for _, f in ipairs(ui.holders) do f:Hide() end
  for _, f in ipairs(ui.rows) do f:Hide() end
  ui.unread:Hide()
  ui.empty:Hide()
  ui.head:Hide()

  ui.topLabel:SetText("Bank gold · " .. ns.Money(gold.total))
  local y = place(ui, ui.top, 0, 26, w)
  y = place(ui, ui.disc, y, ROW_H, w) + 6

  -- the holder cards, three to a row: each bank character, then the guild bank
  local cards = {}
  for _, h in ipairs(gold.holders) do
    cards[#cards + 1] = { title = nameOf(data, h.key), money = ns.Money(h.money),
      age = "updated " .. Cards.Ago(now, h.at) }
  end
  local g = gold.guild
  if g then
    cards[#cards + 1] = { title = "Guild bank", money = ns.Money(g.money),
      age = "read " .. Cards.Ago(now, g.at) .. " by " .. nameOf(data, g.by) }
  end
  local cardW = math.floor((w - 2 * HOLDER_GAP) / 3)
  for i, spec in ipairs(cards) do
    local card = holderCard(ui, i)
    local col, rowN = (i - 1) % 3, math.floor((i - 1) / 3)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", list, "TOPLEFT", col * (cardW + HOLDER_GAP), -(y + rowN * (HOLDER_H + HOLDER_GAP)))
    card:SetSize(cardW, HOLDER_H)
    card.title:SetText(spec.title)
    card.money:SetText(spec.money)
    card.age:SetText(spec.age)
    card:Show()
  end
  if #cards > 0 then y = y + math.ceil(#cards / 3) * (HOLDER_H + HOLDER_GAP) end
  if not g then y = place(ui, ui.unread, y, ROW_H, w) end

  -- the newest entries, one row of five cells each under the column heads
  local entries = gold.entries
  local n = math.min(ENTRIES_MAX, #entries)
  ui.recentLabel:SetText("Recent entries · " .. n)
  y = place(ui, ui.recent, y + 6, 26, w)
  local cols = columns(w)
  if n == 0 then
    y = place(ui, ui.empty, y, ROW_H, w)
  else
    y = place(ui, ui.head, y, HEAD_H, w) + 4
    for i, hd in ipairs(ui.heads) do
      if hd then
        hd:ClearAllPoints()
        hd:SetPoint("TOPLEFT", ui.head, "TOPLEFT", cols[i].x, 0)
        hd:SetWidth(cols[i].w)
      end
    end
    for i = 1, n do
      local row = entryRow(ui, i)
      for j, text in ipairs(entryCells(data, entries[i])) do
        local fs = row.cells[j]
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", row, "TOPLEFT", cols[j].x + 8, -6)
        fs:SetWidth(cols[j].w - 16)
        fs:SetText(text)
      end
      local tone = entries[i].d > 0 and GAIN or LOSS
      row.cells[3]:SetTextColor(tone[1], tone[2], tone[3])
      y = place(ui, row, y, ENTRY_H, w) + ENTRY_GAP
    end
  end
  list:SetHeight(math.max(1, y))
end

ns.TABS[#ns.TABS + 1] = { id = "banker", label = "Banker", build = buildBanker, refresh = refreshBanker,
  shown = function(data) return data.who.bank == true end }
ns.TABS[#ns.TABS + 1] = { id = "contributions", label = "Contributions", build = buildContrib,
  refresh = refreshContrib, shown = function() return true end }
ns.TABS[#ns.TABS + 1] = { id = "gold", label = "Gold", build = buildGold, refresh = refreshGold,
  shown = function() return true end }
