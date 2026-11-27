local _, ns = ...
if not ns.M then return end

-- The chosen raid (right card, plan Task 4): the raid banner with the title on a shade, the team square and line,
-- "You" plus the status pill, the read-only Raid-Helper link box, the soft-reserve row with Share (only with ev.sr),
-- the role counts strip and the kinds line; under them the people panel (ns.DrawSignups, Signups.lua). With nothing
-- chosen: the empty state (d634, f4743). Everything is drawn on card.body. Every cell from the string goes through
-- ns.Escape; colours are set with SetTextColor / SetVertexColor, never as an inline code.

local M = ns.M
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only (made on the first read)
local LINK = "https://raid-helper.dev/event/%s" -- confirm in beta
local DISCORD_SENTENCE = "Sign-ups are on Discord (Raid-Helper)."
local SHADE_H = 56
local KINDS = { "primary", "late", "tentative", "bench", "absence" }
-- The counts strip's cells: the count key, the label, the role icon's atlas suffix.
local CELLS = { { "T", "Tanks", "tank" }, { "H", "Healers", "heal" }, { "M", "Melee", "dps" }, { "R", "Ranged", "dps" } }
-- The tabs under the team line (S9 L1, plan Task 3): key and label (a string, or a function of the chosen raid). The
-- chosen key is ns.PageState.tab, kept across raids and redraws. Ready (S9 L2) is last and shows only on a raid that is
-- tonight (ns.Tonight); a chosen "ready" draws as Sign-ups on any other raid. Groups, Loot and Notes (F1, o50) come
-- after Ready, each shown only when ns[show](ev) answers exactly true and drawn by ns[draw] (the ns.DrawPulls shape,
-- the whole view fifth, o53); every owner delegate is looked up at call time and runs under M.Safe on its own. A chosen
-- tab that is not shown draws as Sign-ups.
local TABS = {
  { key = "signups", text = function(ev) return "Sign-ups (" .. #(ev and ev.signups or {}) .. ")" end },
  { key = "pulls", text = "Pulls" },
  { key = "ready", text = "Ready", tonight = true },
  { key = "groups", text = "Groups", show = "ShowGroups", draw = "DrawGroups" },
  { key = "loot", text = "Loot", show = "ShowLoot", draw = "DrawLoot" },
  { key = "notes", text = "Notes", show = "ShowNotes", draw = "DrawNotes" },
}
-- The "You tonight" line's cells, in this order; each owner answers a string, or nil when the raid is not relevant.
local YOU = { "YouGroup", "YouJobs", "YouReserves", "YouWish" }
local TAB_H = 32 -- Kit.Tabs' holder height; the plain-button row takes the same room
-- The Sign-ups tab's own parts on the card, hidden while the Pulls tab is chosen.
local SIGNUP_PARTS = { "linkLabel", "link", "srLabel", "sr", "share", "strip", "kinds" }

local function tabText(tab, ev)
  if type(tab.text) == "function" then return tab.text(ev) end
  return tab.text
end

local function esc(s) return ns.Escape(tostring(s or "")) end
local function grey(fs) fs:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3]) end

local function at(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", x, y)
end

-- One owner delegate call under M.Safe: fn's first result when it ran, nil when it threw (recorded under Raids) or is
-- not a function.
local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local good, v = M.Safe(fn, ...)
  if good then return v end
  return nil
end

-- Hides every delegate tab's body: ns[draw](card, nil).
local function hideDelegates(card)
  for _, tab in ipairs(TABS) do
    if tab.draw then safe(ns[tab.draw], card, nil) end
  end
end

-- GameTooltip is FrameXML (not in the API dataset, no M.Compat call): read guarded, as 0.2 did.
local function tooltip() return type(GameTooltip) == "table" and GameTooltip or nil end

-- A read-only url box (0.2's urlBox): focus selects all, Escape lets go, typing puts self.url back.
local function urlBox(parent)
  local box = K.InputBox(parent, 340, 340)
  if not box then return nil end
  box:SetAutoFocus(false)
  box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnTextChanged", function(self, user) if user and self.url then self:SetText(self.url) end end)
  return box
end

local function shareButton(parent)
  local b = K.Button(parent, "Share", 70)
  if not b then return nil end
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  b:SetScript("OnEnter", function(self)
    local tip = self.tip and tooltip()
    if not tip then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:SetText(self.tip)
    tip:Show()
  end)
  b:SetScript("OnLeave", function()
    local tip = tooltip()
    if tip then tip:Hide() end
  end)
  b:SetScript("OnClick", function(self)
    M.Safe(function()
      local msg = self.ev and ns.ShareClick(self.ev)
      if msg then ns.Say("Raids: " .. msg) end
    end)
  end)
  return b
end

local function buildStrip(V, body)
  V.strip = CreateFrame("Frame", nil, body)
  V.strip:SetHeight(46)
  V.stripBg = V.strip:CreateTexture(nil, "ARTWORK")
  V.stripBg:SetAllPoints(V.strip)
  K.Atlas(V.stripBg, "groupfinder-Stat-StoneBG", C.panel)
  V.cells = {}
  for i, c in ipairs(CELLS) do
    local cell = {}
    cell.icon = V.strip:CreateTexture(nil, "ARTWORK", nil, 2)
    cell.icon:SetSize(27, 27)
    K.Atlas(cell.icon, "groupfinder-icon-role-large-" .. c[3])
    cell.num = ns.Label(V.strip, T.large)
    cell.num:SetTextColor(ns.WHITE[1], ns.WHITE[2], ns.WHITE[3])
    cell.lab = ns.Label(V.strip, T.highlightSmall)
    grey(cell.lab)
    cell.lab:SetText(c[2])
    if i > 1 then
      cell.div = V.strip:CreateTexture(nil, "ARTWORK", nil, 2)
      cell.div:SetSize(11, 40)
      K.Atlas(cell.div, "common-framedivider", C.divider)
    end
    V.cells[i] = cell
  end
end

function ns.BuildView(card)
  local body = card.body
  local V = {}
  card.view = V
  V.art = body:CreateTexture(nil, "ARTWORK")
  V.art:Hide()
  -- The shade under the title: a gradient (dark at the bottom) when the client has CreateColor and SetGradient, else a
  -- flat black .5 band.
  V.shade = body:CreateTexture(nil, "ARTWORK", nil, 1)
  if type(CreateColor) == "function" and V.shade.SetGradient then
    V.shade:SetColorTexture(ns.WHITE[1], ns.WHITE[2], ns.WHITE[3])
    V.shade:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.8), CreateColor(0, 0, 0, 0))
  else
    V.shade:SetColorTexture(C.pillBg[1], C.pillBg[2], C.pillBg[3], C.pillBg[4])
  end
  V.title = ns.Label(body, T.large)
  V.square = body:CreateTexture(nil, "ARTWORK")
  V.square:SetTexture("Interface\\Buttons\\WHITE8x8")
  V.square:SetSize(8, 8)
  V.team = ns.Label(body)
  V.team:SetWordWrap(false)
  V.you = ns.Label(body, T.highlightSmall)
  grey(V.you)
  V.you:SetText("You")
  V.pill = K.Pill(body, "", "grey")
  V.linkLabel = ns.Label(body, T.small)
  V.linkLabel:SetText("Raid-Helper")
  V.link = urlBox(body)
  V.srLabel = ns.Label(body, T.small)
  V.srLabel:SetText("Soft reserve")
  V.sr = urlBox(body)
  V.share = shareButton(body)
  buildStrip(V, body)
  V.kinds = ns.Label(body, T.highlightSmall)
  grey(V.kinds)
  V.kinds:SetWordWrap(false)
  -- "You tonight: ..." under the team line (not in V.top: it shows only when a cell answers)
  V.tonight = ns.Label(body, T.highlightSmall)
  V.tonight:SetWordWrap(false)
  -- the empty state
  V.pick = ns.Label(body, T.normal, "CENTER")
  V.pick:SetText("Pick a raid on the left")
  V.nextLine = ns.Label(body, T.highlightSmall, "CENTER")
  grey(V.nextLine)
  V.discord = ns.Label(body, T.highlightSmall, "CENTER")
  grey(V.discord)
  V.discord:SetText(DISCORD_SENTENCE)
  -- Everything the chosen raid shows (the art aside), hidden together for the empty state. Nil pieces are left out.
  V.top = {}
  for _, k in ipairs({ "shade", "title", "square", "team", "you", "pill" }) do
    if V[k] then V.top[#V.top + 1] = V[k] end
  end
  for _, k in ipairs(SIGNUP_PARTS) do
    if V[k] then V.top[#V.top + 1] = V[k] end
  end
  -- The tab strip (Kit.Tabs), else plain buttons in a row (the chosen one disabled). A click sets the tab and redraws.
  local function choose(key)
    ns.PageState.tab = key
    local ui = ns.UI()
    if ui then ns.RefreshPage(ui.page) end
  end
  local entries = {}
  for i, tab in ipairs(TABS) do entries[i] = { key = tab.key, text = tabText(tab, nil) } end
  V.tabs = K.Tabs and K.Tabs(body, entries, function(key) M.Safe(choose, key) end)
  if V.tabs then
    V.top[#V.top + 1] = V.tabs.holder
  else
    V.tabButtons = {}
    for _, tab in ipairs(TABS) do
      local key = tab.key
      local b = K.Button(body, tabText(tab, nil), 100)
      b:SetScript("OnClick", function() M.Safe(choose, key) end)
      V.tabButtons[key] = b
      V.top[#V.top + 1] = b
    end
  end
  if ns.BuildSignups then ns.BuildSignups(card) end
end

-- Each tab shown or hidden (shown[key]), and the shown ones chained left to right with no gap. A kit gap: Kit.Tabs
-- anchors each tab on the previous one once, at build (GuildSync/Kit.lua:701-702, :723), and has no piece to hide a
-- middle tab, so the shown tabs are anchored again here on every draw with the kit's own points. The fallback row
-- puts the n-th shown button at 12 + (n - 1) * 104. With only Sign-ups, Pulls and Ready the points equal the build's.
-- A strip that would pass the inner width (inner = viewW - 24) shares it evenly (o72): each kit tab gets
-- floor((inner - 4 - 2 * (n - 1)) / n) and its label that width less the template's side padding, and each fallback
-- button floor((inner - 4 * (n - 1)) / n), stepping by w + 4. A strip that fits keeps the template's widths (the kit
-- re-sizes them on every draw, f9) and the fallback's 100.
local TAB_TEXT_PAD = 20 -- PanelTemplates_TabResize's side padding around the label
local function reanchorTabs(V, shown, y, inner)
  local list, sum = {}, 0
  for _, tab in ipairs(TABS) do
    local b = V.tabs and V.tabs[tab.key] or V.tabButtons[tab.key]
    local visible = shown[tab.key] == true
    b:SetShown(visible)
    if visible then
      list[#list + 1] = b
      sum = sum + (tonumber(b:GetWidth()) or 0)
    end
  end
  local n = #list
  local w
  if V.tabs then
    if n > 0 and 4 + sum + 2 * (n - 1) > inner then w = math.floor((inner - 4 - 2 * (n - 1)) / n) end
  elseif n > 0 and (n - 1) * 104 + 100 > inner then
    w = math.floor((inner - 4 * (n - 1)) / n)
  end
  for k, b in ipairs(list) do
    if V.tabs then
      b:ClearAllPoints()
      if k > 1 then b:SetPoint("LEFT", list[k - 1], "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", V.tabs.holder, "TOPLEFT", 4, 0) end
      if w then
        b:SetWidth(w)
        local fs = b.GetFontString and b:GetFontString()
        if fs then
          fs:SetWidth(w - TAB_TEXT_PAD)
          fs:SetWordWrap(false)
        end
      end
    elseif w then
      b:SetWidth(w)
      at(b, 12 + (k - 1) * (w + 4), -(y + 4))
    else
      b:SetWidth(100)
      at(b, 12 + (k - 1) * 104, -(y + 4))
    end
  end
end

-- The tabs at y (the team line's y + 22, or 18 more under "You tonight") on every draw: the holder re-anchored (a
-- resize moves the banner), each label set (the Sign-ups count changes), the holder hidden and shown so the template
-- re-sizes the tabs to their text (f9), the chosen tab selected, then the shown tabs re-anchored. Kit's Select runs no
-- onSelect, so this never redraws.
local function drawTabs(V, ev, y, chosen, shown, inner)
  if V.tabs then
    local h = V.tabs.holder
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 12, -y)
    h:SetPoint("TOPRIGHT", -12, -y)
    for _, tab in ipairs(TABS) do V.tabs[tab.key]:SetText(tabText(tab, ev)) end
    h:Hide()
    h:Show()
    V.tabs:Select(chosen)
    reanchorTabs(V, shown, y, inner)
    return tonumber(h:GetHeight()) or TAB_H
  end
  for _, tab in ipairs(TABS) do
    local b = V.tabButtons[tab.key]
    b:SetText(tabText(tab, ev))
    b:SetEnabled(tab.key ~= chosen)
  end
  reanchorTabs(V, shown, y, inner)
  return TAB_H
end

-- The empty state (d634): the next raid (the first whose finish, else start, is after now) as a dark, desaturated
-- banner, "Pick a raid on the left", its Tonight/Next line and the Discord sentence; with no raid only the sentence.
local function drawEmpty(V, view, t, L)
  for _, f in ipairs(V.top) do f:Hide() end
  local nx
  for _, e in ipairs(view.events) do
    if (tonumber(e.finish or e.start) or 0) > t then nx = e break end
  end
  local ys = { 40, 62, 78 }
  for i, f in ipairs({ V.pick, V.nextLine, V.discord }) do
    at(f, 0, -(L.banner + ys[i]))
    f:SetWidth(L.viewW)
  end
  V.discord:Show()
  if not nx then
    V.art:Hide()
    V.pick:Hide()
    V.nextLine:Hide()
    return
  end
  at(V.art, 3, -3)
  if ns.DrawArt(V.art, ns.ArtFor(nx.title), L.viewW - 6, L.banner) then
    if V.art.SetDesaturated then V.art:SetDesaturated(true) end
    V.art:SetVertexColor(ns.ART_DIM[1], ns.ART_DIM[2], ns.ART_DIM[3])
  end
  local team = " (" .. esc(nx.team) .. ")"
  if ns.Tonight and ns.Tonight(nx, t, date) then
    V.nextLine:SetText("Tonight: " .. esc(nx.title) .. ", " .. ns.When("%H:%M", nx.start or 0) .. team)
  else
    V.nextLine:SetText("Next: " .. esc(nx.title) .. ", " .. ns.When("%a %d %b %H:%M", nx.start or 0) .. team)
  end
  V.pick:Show()
  V.nextLine:Show()
end

local function drawSr(V, ev, IW, y)
  if not (ev.sr and V.sr and V.share) then
    if V.sr then V.sr.url = nil; V.sr:Hide() end
    if V.share then V.share.ev, V.share.tip = nil, nil; V.share:Hide() end
    V.srLabel:Hide()
    return y
  end
  at(V.srLabel, 12, -(y + 6))
  at(V.sr, 84, -y)
  V.sr:SetWidth(IW - 148)
  -- ev.sr has no | (ns.SrUrl); escaped anyway so the box never draws a code.
  V.sr.url = esc(ev.sr)
  V.sr:SetText(V.sr.url)
  at(V.share, -12, -y, "TOPRIGHT")
  local on, why = ns.ShareState(ev)
  V.share.ev, V.share.tip = ev, (not on) and why or nil
  V.share:SetEnabled(on and true or false)
  return y + 30
end

local function drawStrip(V, ev, IW, y)
  at(V.strip, 12, -y)
  V.strip:SetWidth(IW)
  local cw = IW / 4
  local counts = ev.counts or {}
  for i, cell in ipairs(V.cells) do
    local x = cw * (i - 1)
    at(cell.icon, x + 14, -9)
    at(cell.num, x + 46, -6)
    at(cell.lab, x + 46, -29)
    cell.num:SetText(tostring(tonumber(counts[CELLS[i][1]]) or 0))
    if cell.div then at(cell.div, x - 5.5, -3) end
  end
  return y + 52
end

function ns.DrawView(card, ev, view, rows, t, layout)
  local V = card.view
  if not V then return end
  local L = layout or ns.Layout()
  V.pick:Hide()
  V.nextLine:Hide()
  V.discord:Hide()
  if V.art.SetDesaturated then V.art:SetDesaturated(false) end
  V.art:SetVertexColor(ns.WHITE[1], ns.WHITE[2], ns.WHITE[3])
  if not ev then
    -- nothing chosen, or the chosen raid dropped out of the data (f4756): the people panel and its bar hide
    if ns.DrawSignups then ns.DrawSignups(card, nil, view, rows, t, L) end
    if ns.DrawPulls then ns.DrawPulls(card, nil) end
    if ns.DrawReady then ns.DrawReady(card, nil) end
    hideDelegates(card)
    V.tonight:Hide()
    return drawEmpty(V, view, t, L)
  end
  for _, f in ipairs(V.top) do f:Show() end
  local W, BH = L.viewW, L.banner
  local IW = W - 24
  at(V.art, 3, -3)
  local art = ns.DrawArt(V.art, ns.ArtFor(ev.title), W - 6, BH)
  at(V.shade, 3, -(3 + BH - SHADE_H))
  V.shade:SetSize(W - 6, SHADE_H)
  V.shade:SetShown(art)
  at(V.title, 12, -(BH - 20))
  V.title:SetText(esc(ev.title))
  local y = BH + 12
  local slot = ns.SLOT[tonumber(ev.colour) or 0]
  at(V.square, 12, -(y + 3))
  if slot then
    V.square:SetVertexColor(slot[1], slot[2], slot[3])
  else
    V.square:Hide()
  end
  at(V.team, 26, -y)
  V.team:SetWidth(W - 214)
  V.team:SetText(esc(ev.team) .. " \194\183 " .. ns.When("%a %d %b %H:%M", ev.start or 0) .. " to "
    .. ns.When("%H:%M", ev.finish or ev.start or 0))
  if V.pill then
    K.SetPill(V.pill, ns.StatusPill(ev, ns.MyKey(), false))
    at(V.pill, -12, -(y - 2), "TOPRIGHT")
    V.you:ClearAllPoints()
    V.you:SetPoint("RIGHT", V.pill, "LEFT", -6, 0)
  else
    at(V.you, -12, -y, "TOPRIGHT")
  end
  y = y + 22
  -- "You tonight": the cells that answer a string, each escaped; no cell, no line and no height
  local cells = {}
  for _, name in ipairs(YOU) do
    local s = safe(ns[name], ev)
    if type(s) == "string" and s ~= "" then cells[#cells + 1] = esc(s) end
  end
  if #cells > 0 then
    at(V.tonight, 12, -y)
    V.tonight:SetWidth(IW)
    V.tonight:SetText("You tonight: " .. table.concat(cells, " \194\183 "))
    V.tonight:Show()
    y = y + 18
  else
    V.tonight:Hide()
  end
  local on = ns.Tonight(ev, t, date) and true or false
  local shown = {}
  for _, tab in ipairs(TABS) do
    if tab.show then
      shown[tab.key] = safe(ns[tab.show], ev) == true
    else
      shown[tab.key] = (not tab.tonight) or on
    end
  end
  local chosen = ns.PageState.tab or "signups"
  if not shown[chosen] then chosen = "signups" end
  y = y + drawTabs(V, ev, y, chosen, shown, IW)
  if chosen ~= "signups" then
    -- the sign-up parts hide; the people panel and its bar hide through DrawSignups' own nil path
    for _, k in ipairs(SIGNUP_PARTS) do
      if V[k] then V[k]:Hide() end
    end
    if ns.DrawSignups then ns.DrawSignups(card, nil, view, rows, t, L) end
    local pulls = chosen == "pulls" and ev or nil
    local ready = chosen == "ready" and ev or nil
    if ns.DrawPulls then ns.DrawPulls(card, pulls, L, y, view.events) end
    if ns.DrawReady then ns.DrawReady(card, ready, L, y, view.events) end
    for _, tab in ipairs(TABS) do
      if tab.draw then safe(ns[tab.draw], card, tab.key == chosen and ev or nil, L, y, view) end
    end
    return
  end
  if ns.DrawReady then ns.DrawReady(card, nil) end
  if ns.DrawPulls then ns.DrawPulls(card, nil) end
  hideDelegates(card)
  at(V.linkLabel, 12, -(y + 6))
  if V.link then
    at(V.link, 84, -y)
    V.link:SetWidth(IW - 72)
    V.link.url = string.format(LINK, esc(ev.id))
    V.link:SetText(V.link.url)
  end
  y = drawSr(V, ev, IW, y + 28)
  y = drawStrip(V, ev, IW, y)
  local kc = {}
  for _, k in ipairs(KINDS) do kc[#kc + 1] = k .. " " .. (tonumber((ev.kinds or {})[k]) or 0) end
  at(V.kinds, 12, -y)
  V.kinds:SetWidth(IW)
  -- The suffix goes when the line would not fit (f4766); the counts always stay. A client that cannot measure keeps it.
  local counts = table.concat(kc, " \194\183 ")
  V.kinds:SetText(counts .. " (the counts above are primary and late)")
  local w = V.kinds.GetUnboundedStringWidth and V.kinds:GetUnboundedStringWidth() or V.kinds:GetStringWidth()
  if type(w) == "number" and w > IW then V.kinds:SetText(counts) end
  y = y + 18
  if ns.DrawSignups then ns.DrawSignups(card, ev, view, rows, t, L, y) end
end
