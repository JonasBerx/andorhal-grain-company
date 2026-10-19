-- GuildSyncBank page: the tab bar, the wait line and the first four tabs (bank/brief.md I19, D11, D12, E13, E14, G17,
-- I20, I21, J23, B4).
--   ns.Page.Build(frame)    M.Kit.Tabs over every ns.TABS entry (0.1's own buttons when the kit answers nil), the
--                           wait line, one holder per tab at y -40 (d667) and the page's OnSizeChanged (d537)
--   ns.Page.Refresh(frame)  redraws from ns.Data: the tab bar (an entry shows when its shown(data) is true), the wait
--                           line from data.wait (else, with no other officer online, the age of the newest
--                           officer-domain record, d781), and the chosen tab
-- Page.lua puts Requisitions, Contents, Requests and Mine first in ns.TABS; later entries (PageBanker.lua) follow and
-- are all loaded when the page builds. Every action goes through ns.Do; every text from another player goes through
-- GuildSync.Escape.

local _, ns = ...
if not ns.M then return end

local M = ns.M
ns.TABS = ns.TABS or {}

local Page = {}
ns.Page = Page

local ROW_H, LEFT, TAB_W, HOLDER_Y = 22, 8, 96, -40
local uis = setmetatable({}, { __mode = "k" }) -- page or tab frame -> its widgets

-- AC10: control bytes (newlines included) never reach a FontString; each run becomes one space, then the escape.
local function E(s) return GuildSync.Escape((tostring(s or ""):gsub("%c+", " "))) end
local function textOf(b) local t = b:GetText() return type(t) == "string" and t or "" end
local function serverNow() return GuildSync.Compat.Plain(M.Compat.call("GetServerTime")) end

local function nameOf(data, key)
  local r = data.ctx.roster and data.ctx.roster[key]
  return E(r and r.name or key)
end

local function act(verb, args)
  local good, msg = ns.Do(verb, args)
  if not good and msg then GuildSync.Say(msg) end
  M.RefreshPage()
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

-- An item entry box: the shift-click target while it has focus; it lets go on focus lost or hide. Hooks, because
-- SearchBoxTemplate owns those scripts.
local function itemEntry(b)
  local function release(self) if ns.Items.Target() == self then ns.Items.SetTarget(nil) end end
  b:HookScript("OnEditFocusGained", function(self) M.Safe(ns.Items.SetTarget, self) end)
  b:HookScript("OnEditFocusLost", function(self) M.Safe(release, self) end)
  b:HookScript("OnHide", function(self) M.Safe(release, self) end)
end

local function label(parent, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  if text then fs:SetText(text) end
  return fs
end

local function button(parent, width, text)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 80, ROW_H)
  if text then b:SetText(text) end
  return b
end

-- ---------- Requisitions ----------

local GOLD = ns.Cards.GOLD_CODE
local function iconOf(icon) return type(icon) == "number" and icon or nil end

local function buildReqs(frame) uis[frame] = { cards = ns.Cards.List(frame, 0) } end

local function refreshReqs(frame, data)
  local C, ui = ns.Cards, uis[frame].cards
  C.Begin(ui)
  local who, open, filled = data.who, 0, {}
  for _, req in ipairs(data.view.reqs) do
    if req.status == "open" then
      open = open + 1
      local text, icon, _, quality = ns.Items.Line(req.item)
      local d, p = req.delivered or 0, req.pledged or 0
      local btns = {
        { "Pledge", function(c) act("pledge", { id = req.id, amount = tonumber(textOf(c.box)) }) end, 70 },
        { "I sent it", function(c) act("sent", { id = req.id, amount = tonumber(textOf(c.box)) }) end, 76 },
      }
      if who.bank or who.officer then btns[3] = { "Cancel", function() act("cancel", { id = req.id }) end, 64 } end
      C.Card(ui, { kind = "req", key = req.id, item = req.item, icon = iconOf(icon), title = E(text), quality = quality,
        when = C.Ago(data.now, req.posted),
        sub = { "for " .. GOLD .. E(req.why) .. "|r · posted by " .. nameOf(data, req.poster) },
        bar = { value = d, extra = p, max = req.wanted,
          text = d .. " / " .. req.wanted .. " delivered · " .. p .. " pledged" },
        strip = { box = 94, hint = "Amount", buttons = btns } })
    elseif req.status == "filled" then
      filled[#filled + 1] = req
    end
  end
  if open == 0 then C.Line(ui, "No open requisitions.") end
  -- Filled: newest closedAt first, at most 6 (C3); Derive orders by posted
  table.sort(filled, function(a, b) if a.closedAt ~= b.closedAt then return a.closedAt > b.closedAt end return a.id < b.id end)
  if #filled > 0 then C.Section(ui, "Filled") end
  for i = 1, math.min(6, #filled) do
    local req = filled[i]
    local text, icon, _, quality = ns.Items.Line(req.item)
    C.Card(ui, { kind = "filled", key = req.id, quiet = true, item = req.item, icon = iconOf(icon),
      title = E(text), quality = quality,
      when = C.Ago(data.now, req.closedAt),
      sub = { "for " .. E(req.why) .. " · " .. req.wanted .. " / " .. req.wanted .. " delivered" },
      bar = { value = req.wanted, max = req.wanted, text = "filled" } })
  end
  C.End(ui)
end

-- ---------- Contents ----------

local function buildContents(frame)
  local ui = { cards = ns.Cards.List(frame, 30) }
  uis[frame] = ui
  local form = ui.cards.form
  ui.search = ns.Cards.ItemBox(form, 200, "Search")
  ui.search:SetPoint("LEFT", form, "LEFT", 6, 0)
  -- hooks only: the template clears focus on Enter and keeps its own scripts (f11); a typed change redraws, and so
  -- does a box emptied by the template (its clear button or Escape), so every tile comes back (f4801)
  ui.search:HookScript("OnEnterPressed", function() M.Safe(M.RefreshPage) end)
  ui.search:HookScript("OnTextChanged", function(self, user)
    if user or textOf(self) == "" then M.Safe(M.RefreshPage) end
  end)
  -- the scan line: right-aligned, bounded by the search box and the form's right edge (C4)
  ui.guild = label(form)
  ui.guild:SetJustifyH("RIGHT")
  ui.guild:SetWordWrap(false)
  ns.Cards.Grey(ui.guild)
  ui.guild:SetPoint("LEFT", ui.search, "RIGHT", 12, 0)
  ui.guild:SetPoint("RIGHT", form, "RIGHT", 0, 0)
end

local function refreshContents(frame, data)
  local C, ui = ns.Cards, uis[frame]
  local readable, why = ns.Scan.GuildBankReadable()
  local view = data.view
  local g = view.guild
  local parts = {}
  if g then parts[1] = "Guild bank scanned " .. C.Ago(data.now, g.scanned) .. " by " .. nameOf(data, g.by) end
  local hs = {}
  for h, rec in pairs(view.holders) do hs[#hs + 1] = { key = h, scanned = rec.scanned or 0 } end
  table.sort(hs, function(a, b) if a.scanned ~= b.scanned then return a.scanned > b.scanned end return a.key < b.key end)
  for _, h in ipairs(hs) do parts[#parts + 1] = nameOf(data, h.key) .. " " .. C.Ago(data.now, h.scanned) end
  if not readable then parts[#parts + 1] = why end
  ui.guild:SetText(table.concat(parts, " · "))
  local ids = {}
  for id in pairs(view.items) do ids[#ids + 1] = id end
  local query = textOf(ui.search)
  if query:match("%S") then
    local found = {}
    for _, id in ipairs(ns.Items.Search(query:match("^%s*(.-)%s*$"), ids)) do
      if view.items[id] then found[#found + 1] = id end
    end
    ids = found
  end
  local tiles = {}
  for _, id in ipairs(ids) do
    local text, icon, _, quality = ns.Items.Line(id)
    tiles[#tiles + 1] = { id = id, text = E(text), icon = iconOf(icon) or ns.Cards.QMARK, quality = quality }
  end
  table.sort(tiles, function(a, b) if a.text ~= b.text then return a.text < b.text end return a.id < b.id end)
  C.Begin(ui.cards)
  for _, t in ipairs(tiles) do
    local it = view.items[t.id]
    local hl = {}
    for h, n in pairs(it.by) do
      local name, scanned
      if h == ns.Derive.GUILD then name, scanned = "Guild bank", g and g.scanned
      else name, scanned = nameOf(data, h), view.holders[h] and view.holders[h].scanned end
      hl[#hl + 1] = { name = name, n = n, scanned = scanned }
    end
    table.sort(hl, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    local full, short, tip = {}, {}, { t.text }
    for _, x in ipairs(hl) do
      full[#full + 1] = x.name .. " " .. x.n
      short[#short + 1] = (x.name:match("^(%S+)") or x.name) .. " " .. x.n
      tip[#tip + 1] = x.name .. ": " .. x.n .. " (scanned " .. C.Ago(data.now, x.scanned) .. ")"
    end
    full, short = table.concat(full, " · "), table.concat(short, " · ")
    local card = C.Card(ui.cards, { kind = "tile", key = tostring(t.id), item = t.id, icon = t.icon, count = it.total,
      title = t.text, quality = t.quality, sub = { full }, tooltip = tip })
    C.Fit(card.sub[1], full, short) -- first names when the full line does not fit (C4)
  end
  if #tiles == 0 then C.Line(ui.cards, "Nothing to show.") end
  C.End(ui.cards)
end

-- ---------- Requests ----------

local function pillOf(q)
  if not q.answer then return { text = "open", tone = "gold" } end
  if q.answer.verdict == "fulfilled" then return { text = "fulfilled", tone = "green" } end
  return { text = "declined", tone = "red" }
end

local function requestCard(C, ui, data, q, quietCard)
  local text, icon, _, quality = ns.Items.Line(q.item)
  local note = (q.note and q.note ~= "") and (GOLD .. E(q.note) .. "|r") or "no note"
  local sub = { nameOf(data, q.member) .. " · " .. note }
  if q.answer and q.answer.reason and q.answer.reason ~= "" then sub[2] = "declined: " .. E(q.answer.reason) end
  C.Card(ui, { kind = "plain", quiet = quietCard, item = q.item, icon = iconOf(icon) or C.QMARK, count = q.count,
    title = E(text),
    quality = quality, when = C.Ago(data.now, q.at), pill = pillOf(q), sub = sub })
end

local function buildRequests(frame)
  local ui = { cards = ns.Cards.List(frame, 60) }
  uis[frame] = ui
  ui.panel = ns.Cards.FormCard(ui.cards.form, "Ask the bank")
  ui.item = ns.Cards.ItemBox(ui.panel, 160, "Item: shift-click or name")
  ui.item:SetPoint("TOPLEFT", ui.panel, "TOPLEFT", 12, -30)
  itemEntry(ui.item)
  ui.count = ns.Cards.Box(ui.panel, 50, "Count")
  ui.count:SetPoint("LEFT", ui.item, "RIGHT", 8, 0)
  ui.note = ns.Cards.Box(ui.panel, 200, "Note (optional)")
  ui.note:SetPoint("LEFT", ui.count, "RIGHT", 8, 0)
  ui.ask = button(ui.panel, 64, "Ask")
  ui.ask:SetPoint("LEFT", ui.note, "RIGHT", 8, 0) -- d668
  ui.item.nextEditBox, ui.count.previousEditBox = ui.count, ui.item -- Tab order: Item, Count, Note
  ui.count.nextEditBox, ui.note.previousEditBox = ui.note, ui.count
  ui.ask:SetScript("OnClick", function()
    M.Safe(function()
      local id, why = ns.Items.Parse(textOf(ui.item), candidates(ui.data and ui.data.view))
      if not id then GuildSync.Say(why) return end
      act("ask", { item = id, count = tonumber(textOf(ui.count)), note = textOf(ui.note) })
    end)
  end)
end

local function refreshRequests(frame, data)
  local C, ui = ns.Cards, uis[frame]
  ui.data = data
  C.Begin(ui.cards)
  local n = 0
  for _, q in ipairs(data.view.requests) do if not q.answer then requestCard(C, ui.cards, data, q, false) n = n + 1 end end
  for _, q in ipairs(data.view.requests) do if q.answer then requestCard(C, ui.cards, data, q, true) n = n + 1 end end
  if n == 0 then C.Line(ui.cards, "No requests.") end
  C.End(ui.cards)
end

-- ---------- Mine ----------

local SEND = { pending = "waiting for the bank", received = "received", cancelled = "cancelled" }

local function buildMine(frame) uis[frame] = { cards = ns.Cards.List(frame, 0) } end

local function refreshMine(frame, data)
  local C, ui = ns.Cards, uis[frame].cards
  C.Begin(ui)
  local me = data.who.key
  local pl, se, rq = {}, {}, {}
  for _, req in ipairs(data.view.reqs) do
    if req.pledges[me] then pl[#pl + 1] = req end
    if req.sends[me] then se[#se + 1] = req end
  end
  for _, q in ipairs(data.view.requests) do if q.member == me then rq[#rq + 1] = q end end
  if #pl > 0 then
    C.Section(ui, "Your pledges")
    for _, req in ipairs(pl) do
      local p = req.pledges[me]
      local text, icon, _, quality = ns.Items.Line(req.item)
      local spec = { key = req.id, item = req.item, icon = iconOf(icon), count = p.amount,
        title = E(text), quality = quality,
        when = C.Ago(data.now, p.at), sub = { "pledged " .. p.amount .. " for " .. GOLD .. E(req.why) .. "|r" } }
      if req.status == "open" then
        spec.kind = "strip"
        spec.strip = { label = "Mail it to a bank character, then:", buttons = {
          { "I sent it", function() act("sent", { id = req.id, amount = p.amount }) end, 76 },
          { "Withdraw", function() act("pledge", { id = req.id, amount = 0 }) end, 72 } } }
      else
        spec.kind, spec.quiet, spec.pill = "plain", true, { text = "closed", tone = "grey" }
      end
      C.Card(ui, spec)
    end
  end
  if #se > 0 then
    C.Section(ui, "Your sends")
    for _, req in ipairs(se) do
      local s = req.sends[me]
      local text, icon, _, quality = ns.Items.Line(req.item)
      C.Card(ui, { kind = "plain", key = req.id, item = req.item, quiet = s.status ~= "pending",
        icon = iconOf(icon), count = s.amount,
        title = E(text), quality = quality, when = C.Ago(data.now, s.at),
        pill = { text = SEND[s.status] or s.status, tone = s.status == "received" and "green" or s.status == "cancelled" and "red" or "gold" },
        sub = { "sent " .. s.amount .. " for " .. E(req.why) } })
    end
  end
  if #rq > 0 then
    C.Section(ui, "Your requests")
    for _, q in ipairs(rq) do requestCard(C, ui, data, q, q.answer ~= nil) end
  end
  if #pl + #se + #rq == 0 then C.Line(ui, "Nothing of yours yet.") end
  C.End(ui)
end

local always = function() return true end
table.insert(ns.TABS, 1, { id = "requisitions", label = "Requisitions", build = buildReqs, refresh = refreshReqs,
  shown = always })
table.insert(ns.TABS, 2, { id = "contents", label = "Contents", build = buildContents, refresh = refreshContents,
  shown = always })
table.insert(ns.TABS, 3, { id = "requests", label = "Requests", build = buildRequests, refresh = refreshRequests,
  shown = always })
table.insert(ns.TABS, 4, { id = "mine", label = "Mine", build = buildMine, refresh = refreshMine, shown = always })

-- ---------- the page: tab bar, wait line, tabs ----------

local function choose(page, id)
  uis[page].current = id
  M.RefreshPage()
end

-- d781 (V1): with the full roster read and no officer but me online, the age of the newest `at` among the held
-- officer-domain records; nil otherwise, in the demo and with no such record.
local OFFICER_DOMAINS = { "bank", "bank_q", "bank_a" }
local function staleLine(data)
  if data.isDemo then return nil end
  local rows, partial, _, known = GuildSync.Comm.Roster()
  if not known or partial then return nil end
  local me = GuildSync.Comm.MyKey()
  for key, row in pairs(rows) do
    if key ~= me and row.online and GuildSync.Comm.IsOfficer(key) then return nil end
  end
  local records, newest = ns.Store.All() or {}, nil
  for _, dom in ipairs(OFFICER_DOMAINS) do
    for _, rec in pairs(records[dom] or {}) do
      if type(rec) == "table" and type(rec.at) == "number" and (newest == nil or rec.at > newest) then newest = rec.at end
    end
  end
  if not newest then return nil end
  return "No officer online: saved data from " .. ns.Cards.Ago(data.now, newest)
end

-- M.Kit.Tabs over every ns.TABS entry (all loaded by now), else 0.1's buttons; one holder per tab under the 32-tall
-- tab row (d667); the page's width drives every list's (d537).
function Page.Build(page)
  local ui = { holders = {} }
  uis[page] = ui
  local entries = {}
  for i, entry in ipairs(ns.TABS) do entries[i] = { key = entry.id, text = entry.label } end
  ui.tabs = M.Kit.Tabs(page, entries, function(key) M.Safe(choose, page, key) end)
  if not ui.tabs then
    ui.buttons = {}
    for _, entry in ipairs(ns.TABS) do
      local id = entry.id
      local b = button(page, TAB_W, entry.label)
      b:SetScript("OnClick", function() M.Safe(choose, page, id) end)
      ui.buttons[id] = b
    end
  end
  ui.wait = label(page)
  ui.wait:SetJustifyH("RIGHT")
  ns.Cards.Grey(ui.wait)
  ui.wait:SetPoint("TOPRIGHT", page, "TOPRIGHT", -8, -10)
  for _, entry in ipairs(ns.TABS) do
    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", page, "TOPLEFT", 0, HOLDER_Y)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
    holder:Hide()
    ui.holders[entry.id] = holder
    M.Safe(entry.build, holder)
  end
  ns.Items.HookInsert()
  page:HookScript("OnSizeChanged", function(_, w) -- a hook: the hub's own OnSizeChanged on its frame still runs
    M.Safe(function() if ns.Cards.Resize(w) then M.RefreshPage() end end)
  end)
end

function Page.Refresh(page)
  local ui = uis[page]
  if not ui then return end
  local data = ns.Data(serverNow())
  local wait = data.wait or staleLine(data) -- the rank-names wait wins (d781)
  if wait then ui.wait:SetText(wait) ui.wait:Show() else ui.wait:SetText("") ui.wait:Hide() end
  local x, shown = 0, {}
  for _, entry in ipairs(ns.TABS) do
    local b = ui.tabs and ui.tabs[entry.id] or ui.buttons[entry.id]
    if entry.shown(data) then
      shown[entry.id] = true
      if ui.buttons then
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT + x, -4)
        x = x + TAB_W + 4
      end
      b:Show()
    else
      b:Hide()
    end
  end
  -- Contributions follows Banker when it shows, else Mine (c6)
  local tabs = ui.tabs
  if tabs and tabs.contributions and tabs.banker and tabs.mine then
    tabs.contributions:ClearAllPoints()
    tabs.contributions:SetPoint("LEFT", shown.banker and tabs.banker or tabs.mine, "RIGHT", 2, 0)
  end
  if not (ui.current and shown[ui.current]) then ui.current = ns.TABS[1].id end
  if tabs then tabs:Select(ui.current) end
  for _, entry in ipairs(ns.TABS) do
    local holder = ui.holders[entry.id]
    local b = ui.buttons and ui.buttons[entry.id]
    if entry.id == ui.current then
      holder:Show()
      if b then b:LockHighlight() end
      entry.refresh(holder, data)
    else
      holder:Hide()
      if b then b:UnlockHighlight() end
    end
  end
end
