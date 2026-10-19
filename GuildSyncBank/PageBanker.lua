-- GuildSyncBank page, the Banker and Contributions tabs (bank/brief.md I19, E13, G17, H18, I21, J23; bank/cards.md
-- C7, C8). Appends two ns.TABS entries after Page.lua's four:
--   { id = "banker", label = "Banker", build, refresh, shown }      shown for a bank character (always under demo)
--   { id = "contributions", label = "Contributions", build, refresh, shown }   shown for everyone
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
  local ui = { list = Cards.List(frame, 60) }
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
  local Cards = ns.Cards
  local view, now = data.view, data.now
  Cards.Begin(ui.list)

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

ns.TABS[#ns.TABS + 1] = { id = "banker", label = "Banker", build = buildBanker, refresh = refreshBanker,
  shown = function(data) return data.who.bank == true end }
ns.TABS[#ns.TABS + 1] = { id = "contributions", label = "Contributions", build = buildContrib,
  refresh = refreshContrib, shown = function() return true end }
