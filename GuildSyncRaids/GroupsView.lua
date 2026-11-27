local _, ns = ...
if not ns.M then return end

-- The Groups tab of the chosen raid and the lineup drawing the roster card shares (ticket 56 stages B and C).
-- ns.DrawLineup draws a lineup's groups of five on a pane on card.body (built on the
-- first draw and kept on the card, the ns.DrawPulls shape) and answers its height; ns.DrawGroups(card, ev, L, top, view) is
-- the tab's draw (view is passed by RaidView and not read) and
-- leaves the rest of the card under the lineup to ns.DrawInvites (#57) when that is a function. Every name from another
-- player goes through ns.Escape; colours are set with SetTextColor, never as an inline code. Nothing is saved or sent.

local M = ns.M
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only (made on the first read)
local COL_GAP, HEAD_H, SEAT_H, BAND_GAP, LINE_H, MARK_W = 6, 12, 12, 4, 12, 16
local GROUP_H = HEAD_H + 5 * SEAT_H
local TAIL_H = 4 + 3 * LINE_H                         -- count line, reserve line, saved-by line
local EDIT_TAIL_H = 4 + LINE_H + 2 + LINE_H + 5 * LINE_H -- count line, gap, reserve head, reserve grid (4 x 5)
local RES_COLS = 4
local MAX_GROUPS = 8 -- a 40-player lineup; a hand-edited one with more draws its first 8
local R = ns.RosterRules
local MARKS = R.ROLE_WORD -- the role letters a seat shows

local function esc(s) return ns.Escape(tostring(s or "")) end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", x, y)
end

function ns.GroupsLayout(groups, IW, edit)
  local n = math.max(1, tonumber(groups) or 1)
  local cols = math.min(n, 4)
  local bands = math.ceil(n / cols)
  local colW = math.floor((IW - (cols - 1) * COL_GAP) / cols)
  local gridH = bands * GROUP_H + (bands - 1) * BAND_GAP
  return { cols = cols, colW = colW, bands = bands, gridH = gridH, h = gridH + (edit and EDIT_TAIL_H or TAIL_H) }
end

local function line(parent, font)
  local fs = ns.Label(parent, font)
  fs:SetWordWrap(false)
  fs:SetHeight(LINE_H)
  return fs
end

local function build(card)
  local V = { seats = {}, heads = {} }
  card.groupsView = V
  V.pane = CreateFrame("Frame", nil, card.body)
  V.count = line(V.pane, T.highlightSmall)
  V.reserve = line(V.pane, T.highlightSmall)
  V.saved = line(V.pane, T.small)
  color(V.saved, ns.GREY)
  V.resHead = line(V.pane, T.small)
  return V
end

-- The i-th seat Button (made on first use): the chosen mark, the name, the main mark and the off-spec mark.
local function seatButton(V, i)
  local b = V.seats[i]
  if b then return b end
  b = CreateFrame("Button", nil, V.pane)
  b.sel = b:CreateTexture(nil, "ARTWORK")
  b.sel:SetAllPoints(b)
  K.Atlas(b.sel, "common-button-list-small-selected", C.active)
  b.sel:Hide()
  b.name = line(b, T.highlightSmall)
  b.main = line(b, T.highlightSmall)
  b.off = line(b, T.small)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, which)
    M.Safe(function() if self.onSeat then self.onSeat(self.place, self, which) end end)
  end)
  V.seats[i] = b
  return b
end

local function headLabel(V, i)
  local h = V.heads[i]
  if h then return h end
  h = line(V.pane, T.small)
  color(h, ns.GREY)
  V.heads[i] = h
  return h
end

-- The class colour of a seat (D10): its guild row's class first (by key, else by name for a draft seat), then
-- seat.class; white without a colour. RAID_CLASS_COLORS is FrameXML (not in the API dataset): read guarded.
local function classColour(fs, rows, seat)
  local key = seat.key or (type(seat.name) == "string" and ns.Key(seat.name)) or nil
  local row = key and rows[key]
  local token = R.Token(row and row.class) or R.Token(seat.class)
  local all = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS or nil
  local cc = all and token and all[token]
  if type(cc) == "table" and cc.r then
    fs:SetTextColor(cc.r, cc.g, cc.b)
  else
    color(fs, ns.WHITE)
  end
end

-- One seat at (x, -y) on the pane, colW wide; seat false or nil is an empty seat.
local function drawSeat(b, seat, place, x, y, colW, rows, opts)
  at(b, x, -y)
  b:SetSize(colW, SEAT_H)
  b.place = place
  b.onSeat = opts.onSeat
  b:EnableMouse(opts.onSeat ~= nil)
  local sel = opts.selected
  b.sel:SetShown(type(sel) == "table" and sel.g == place.g and sel.s == place.s)
  at(b.name, 0, 0)
  b.name:SetWidth(math.max(1, colW - MARK_W - 2))
  at(b.main, colW - MARK_W, 0)
  b.main:SetWidth(MARK_W / 2)
  at(b.off, colW - MARK_W / 2, 0)
  b.off:SetWidth(MARK_W / 2)
  if type(seat) ~= "table" then
    b.name:SetText("empty")
    color(b.name, ns.GREY)
    b.main:Hide()
    b.off:Hide()
  else
    b.name:SetText(esc(seat.name))
    classColour(b.name, rows, seat)
    if MARKS[seat.role] then
      b.main:SetText(seat.role)
      color(b.main, ns.WHITE)
    else
      b.main:SetText("-")
      color(b.main, ns.GREY)
    end
    b.main:Show()
    if MARKS[seat.off] then
      b.off:SetText(string.lower(seat.off))
      color(b.off, ns.GREY)
      b.off:Show()
    else
      b.off:Hide()
    end
  end
  b:Show()
end

-- The lineup's groups at (12, -top) on card.body, then the count line and the reserve (a line, or with opts.edit a head
-- and a grid of seats), then "Saved by" when the lineup has one. Answers the height drawn (ns.GroupsLayout's h).
function ns.DrawLineup(card, lineup, L, top, opts)
  local V = rawget(card, "groupsView") or build(card)
  if type(lineup) ~= "table" then
    V.pane:Hide()
    return 0
  end
  opts = opts or {}
  L = L or ns.Layout()
  local rows = opts.rows or {}
  local IW = L.viewW - 24
  local groups = type(lineup.groups) == "table" and lineup.groups or {}
  local nG = math.min(#groups, MAX_GROUPS)
  local G = ns.GroupsLayout(nG, IW, opts.edit)
  at(V.pane, 12, -(top or 0))
  V.pane:SetSize(IW, G.h)
  V.pane:Show()
  local nSeat = 0
  for g = 1, nG do
    local grp = type(groups[g]) == "table" and groups[g] or {}
    local col, band = (g - 1) % G.cols, math.floor((g - 1) / G.cols)
    local x, y = col * (G.colW + COL_GAP), band * (GROUP_H + BAND_GAP)
    local h = headLabel(V, g)
    at(h, x, -y)
    h:SetWidth(G.colW)
    h:SetText("Group " .. g)
    h:Show()
    for s = 1, 5 do
      nSeat = nSeat + 1
      drawSeat(seatButton(V, nSeat), grp[s], { g = g, s = s }, x, y + HEAD_H + (s - 1) * SEAT_H, G.colW, rows, opts)
    end
  end
  for i = nG + 1, #V.heads do V.heads[i]:Hide() end
  local y = G.gridH + 4
  at(V.count, 0, -y)
  V.count:SetWidth(IW)
  V.count:SetText(R.CountLine(groups))
  V.count:Show()
  y = y + LINE_H
  local reserve = type(lineup.reserve) == "table" and lineup.reserve or {}
  if opts.edit then
    V.reserve:Hide()
    V.saved:Hide()
    y = y + 2
    at(V.resHead, 0, -y)
    V.resHead:SetWidth(IW)
    V.resHead:SetText("Reserve (" .. #reserve .. "/" .. R.MAX_RESERVE .. ")")
    V.resHead:Show()
    y = y + LINE_H
    local resW = math.floor((IW - (RES_COLS - 1) * COL_GAP) / RES_COLS)
    for i = 1, math.min(#reserve, R.MAX_RESERVE) do
      local seat = reserve[i]
      local col, r = (i - 1) % RES_COLS, math.floor((i - 1) / RES_COLS)
      nSeat = nSeat + 1
      drawSeat(seatButton(V, nSeat), seat, { g = 0, s = i }, col * (resW + COL_GAP), y + r * LINE_H, resW, rows, opts)
    end
  else
    V.resHead:Hide()
    local names = {}
    for _, seat in ipairs(reserve) do names[#names + 1] = esc(seat.name) end
    at(V.reserve, 0, -y)
    V.reserve:SetWidth(IW)
    V.reserve:SetText("Reserve (" .. #reserve .. ")" .. (#names > 0 and (": " .. table.concat(names, ", ")) or ""))
    V.reserve:Show()
    y = y + LINE_H
    if lineup.by then
      at(V.saved, 0, -y)
      V.saved:SetWidth(IW)
      V.saved:SetText("Saved by " .. ns.Who(rows, lineup.by) .. ", " .. ns.When("%a %d %b %H:%M", lineup.at or 0))
      V.saved:Show()
    else
      V.saved:Hide()
    end
  end
  for i = nSeat + 1, #V.seats do V.seats[i]:Hide() end
  return G.h
end

-- The Groups tab (D13): view (the fifth parameter) is the page's view, passed by the caller and not read here. ev nil, or an ev with no lineup, hides the pane and the invites box and returns before L is
-- read. Else the lineup, then the invites box under it to the card's bottom limit, filled by ns.DrawInvites(box, ev)
-- when that is a function; without it the box hides and nothing else moves.
function ns.DrawGroups(card, ev, L, top, view)
  local V = rawget(card, "groupsView")
  if type(ev) ~= "table" or ev.lineup == nil then
    if V then
      V.pane:Hide()
      if V.box then V.box:Hide() end
    end
    return
  end
  L = L or ns.Layout()
  top = top or 0
  local rows = ns.Roster() or {}
  local h = ns.DrawLineup(card, ev.lineup, L, top, { rows = rows })
  V = rawget(card, "groupsView")
  V.box = V.box or CreateFrame("Frame", nil, card.body)
  local draw = ns.DrawInvites
  if type(draw) ~= "function" then
    V.box:Hide()
    return
  end
  local y = top + h + 4
  at(V.box, 12, -y)
  V.box:SetSize(L.viewW - 24, math.max(1, L.cardH - 6 - y))
  V.box:Show()
  M.Safe(draw, V.box, ev)
end

function ns.ShowGroups(ev)
  return type(ev) == "table" and ev.lineup ~= nil
end

-- "You tonight" (D16): raw text, RaidView escapes it.
function ns.YouGroup(ev)
  return R.YouLine(type(ev) == "table" and ev.lineup or nil, ns.MyKey())
end
