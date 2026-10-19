local _, ns = ...
if not ns.M then return end

-- The chosen raid (right card, plan Task 4): the raid banner with the title on a shade, the team square and line,
-- "You" plus the status pill, the read-only Raid-Helper link box, the soft-reserve row with Share (only with ev.sr),
-- the role counts strip and the kinds line; under them the people panel (ns.DrawSignups, Signups.lua). With nothing
-- chosen: the empty state (d634, f4743). Everything is drawn on card.body. Every cell from the string goes through
-- ns.Escape; colours are set with SetTextColor / SetVertexColor, never as an inline code.

local M = ns.M
local K = M.Kit
local LINK = "https://raid-helper.dev/event/%s" -- confirm in beta
local DISCORD_SENTENCE = "Sign-ups are on Discord (Raid-Helper)."
local SHADE_H = 56
local KINDS = { "primary", "late", "tentative", "bench", "absence" }
-- The counts strip's cells: the count key, the label, the role icon's atlas suffix.
local CELLS = { { "T", "Tanks", "tank" }, { "H", "Healers", "heal" }, { "M", "Melee", "dps" }, { "R", "Ranged", "dps" } }

local function esc(s) return ns.Escape(tostring(s or "")) end
local function grey(fs) fs:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3]) end

local function at(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", x, y)
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
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(70, 22)
  b:SetText("Share")
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
  K.Atlas(V.stripBg, "groupfinder-Stat-StoneBG", { 0, 0, 0, 0.35 })
  V.cells = {}
  for i, c in ipairs(CELLS) do
    local cell = {}
    cell.icon = V.strip:CreateTexture(nil, "ARTWORK", nil, 2)
    cell.icon:SetSize(27, 27)
    K.Atlas(cell.icon, "groupfinder-icon-role-large-" .. c[3])
    cell.num = ns.Label(V.strip, "GameFontHighlightLarge")
    cell.lab = ns.Label(V.strip, "GameFontHighlightSmall")
    grey(cell.lab)
    cell.lab:SetText(c[2])
    if i > 1 then
      cell.div = V.strip:CreateTexture(nil, "ARTWORK", nil, 2)
      cell.div:SetSize(11, 40)
      K.Atlas(cell.div, "common-framedivider", { 1, 1, 1, 0.12 })
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
    V.shade:SetColorTexture(1, 1, 1, 1)
    V.shade:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.8), CreateColor(0, 0, 0, 0))
  else
    V.shade:SetColorTexture(0, 0, 0, 0.5)
  end
  V.title = ns.Label(body, "GameFontNormalLarge")
  V.square = body:CreateTexture(nil, "ARTWORK")
  V.square:SetTexture("Interface\\Buttons\\WHITE8x8")
  V.square:SetSize(8, 8)
  V.team = ns.Label(body)
  V.team:SetWordWrap(false)
  V.you = ns.Label(body, "GameFontHighlightSmall")
  grey(V.you)
  V.you:SetText("You")
  V.pill = K.Pill(body, "", "grey")
  V.linkLabel = ns.Label(body, "GameFontNormalSmall")
  V.linkLabel:SetText("Raid-Helper")
  V.link = urlBox(body)
  V.srLabel = ns.Label(body, "GameFontNormalSmall")
  V.srLabel:SetText("Soft reserve")
  V.sr = urlBox(body)
  V.share = shareButton(body)
  buildStrip(V, body)
  V.kinds = ns.Label(body, "GameFontHighlightSmall")
  grey(V.kinds)
  V.kinds:SetWordWrap(false)
  -- the empty state
  V.pick = ns.Label(body, "GameFontNormal", "CENTER")
  V.pick:SetText("Pick a raid on the left")
  V.nextLine = ns.Label(body, "GameFontHighlightSmall", "CENTER")
  grey(V.nextLine)
  V.discord = ns.Label(body, "GameFontHighlightSmall", "CENTER")
  grey(V.discord)
  V.discord:SetText(DISCORD_SENTENCE)
  -- Everything the chosen raid shows (the art aside), hidden together for the empty state. Nil pieces are left out.
  V.top = {}
  for _, k in ipairs({ "shade", "title", "square", "team", "you", "pill", "linkLabel", "link", "srLabel", "sr", "share",
    "strip", "kinds" }) do
    if V[k] then V.top[#V.top + 1] = V[k] end
  end
  if ns.BuildSignups then ns.BuildSignups(card) end
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
    V.art:SetVertexColor(0.45, 0.45, 0.45)
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
  V.art:SetVertexColor(1, 1, 1)
  if not ev then
    -- nothing chosen, or the chosen raid dropped out of the data (f4756): the people panel and its bar hide
    if ns.DrawSignups then ns.DrawSignups(card, nil, view, rows, t, L) end
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
    V.square:SetVertexColor(slot[1], slot[2], slot[3], 1)
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
