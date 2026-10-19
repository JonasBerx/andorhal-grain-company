local _, ns = ...
if not ns.M then return end

-- The raid list (left card, plan Task 3): week headers over pooled raid rows in an own ScrollFrame (d631). A row has
-- the team bar, the raid thumbnail (ns.DrawArt, only when the layout has room, d633), the title, the date, the team
-- as its own FontString in its slot colour, the counts and the status pill (M.Kit.Pill). Every cell from the string
-- goes through ns.Escape; colours are set with SetTextColor / SetVertexColor, never as an inline code.

local M = ns.M
local K = M.Kit
local SB = 22 -- the scrollbar's room on the right (ns.ScrollArea)
local ROW_H, ROW_GAP, HEAD_H = 56, 2, 20
local THUMB_W, THUMB_H = 64, 32
local BORDER = { 0x8a / 255, 0x6d / 255, 0x1f / 255, 1 }

local function esc(s) return ns.Escape(tostring(s or "")) end

function ns.BuildList(card)
  local L = { rows = {}, heads = {} }
  L.scroll, L.content = ns.ScrollArea(card.body)
  L.scroll:SetPoint("TOPLEFT", 4, -24)
  L.scroll:SetPoint("BOTTOMRIGHT", -SB, 24)
  card.list = L
end

local function rowButton(L, i)
  local b = L.rows[i]
  if b then return b end
  b = CreateFrame("Button", nil, L.content)
  b:SetHeight(ROW_H)
  b.sel = b:CreateTexture(nil, "ARTWORK")
  b.sel:SetAllPoints(b)
  K.Atlas(b.sel, "common-button-list-small-selected", { 1, 0.82, 0, 0.15 })
  b.sel:Hide()
  K.ListHover(b, "Interface\\QuestFrame\\UI-QuestTitleHighlight")
  b.bar = b:CreateTexture(nil, "ARTWORK")
  b.bar:SetTexture("Interface\\Buttons\\WHITE8x8")
  b.bar:SetSize(3, 44)
  b.bar:SetPoint("TOPLEFT", 3, -6)
  b.border = b:CreateTexture(nil, "ARTWORK")
  b.border:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], BORDER[4])
  b.border:SetSize(THUMB_W + 2, THUMB_H + 2)
  b.border:SetPoint("TOPLEFT", 11, -11)
  b.art = b:CreateTexture(nil, "OVERLAY")
  b.art:SetPoint("TOPLEFT", 12, -12)
  b.art:Hide()
  b.title = ns.Label(b)
  b.date = ns.Label(b, "GameFontHighlightSmall")
  b.date:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3])
  b.team = ns.Label(b, "GameFontHighlightSmall")
  b.team:SetPoint("LEFT", b.date, "RIGHT", 0, 0)
  b.counts = ns.Label(b, "GameFontHighlightSmall")
  b.counts:SetWordWrap(false)
  b.pill = K.Pill(b, "", "grey")
  if b.pill then b.pill:SetPoint("TOPRIGHT", -8, -34) end
  b:SetScript("OnClick", function(self) M.Safe(function() ns.Select(self.key) end) end)
  L.rows[i] = b
  return b
end

local function headLabel(L, i)
  local h = L.heads[i]
  if h then return h end
  h = ns.Label(L.content, "GameFontNormalSmall")
  L.heads[i] = h
  return h
end

local function drawRow(b, ev, me, layout, rw)
  b:SetWidth(rw)
  b.sel:SetShown(ev.key == ns.PageState.chosen)
  local slot = ns.SLOT[tonumber(ev.colour) or 0]
  if slot then
    b.bar:SetVertexColor(slot[1], slot[2], slot[3], 1)
    b.bar:Show()
  else
    b.bar:Hide()
  end
  -- The text starts after the thumbnail, or at 14 when the list is narrow or the raid has no art (0.2's fallback).
  local art = false
  if layout.thumbs then
    art = ns.DrawArt(b.art, ns.ArtFor(ev.title), THUMB_W, THUMB_H)
  else
    b.art:Hide()
  end
  b.border:SetShown(art)
  local tx = art and 86 or 14
  b.title:ClearAllPoints()
  b.title:SetPoint("TOPLEFT", tx, -6)
  b.title:SetWidth(rw - tx - 8)
  b.title:SetText(esc(ev.title))
  b.date:ClearAllPoints()
  b.date:SetPoint("TOPLEFT", tx, -22)
  b.date:SetText(ns.When("%a %d %b %H:%M", ev.start or 0) .. " \194\183 ")
  b.team:SetText(esc(ev.team))
  local col = slot or ns.GREY
  b.team:SetTextColor(col[1], col[2], col[3])
  b.counts:ClearAllPoints()
  b.counts:SetPoint("TOPLEFT", tx, -38)
  local c = ev.counts or {}
  b.counts:SetText(string.format("T %d H %d M %d R %d", c.T or 0, c.H or 0, c.M or 0, c.R or 0))
  K.SetPill(b.pill, ns.StatusPill(ev, me, true))
  -- The counts end 6 px before the pill (f4765), which sits at the row's right edge - 8.
  local pillW = b.pill and tonumber(b.pill:GetWidth()) or 0
  b.counts:SetWidth(math.max(1, rw - 8 - pillW - 6 - tx))
  b:Show()
end

function ns.DrawList(card, view, rows, t, layout)
  local L = card.list
  if not L then return end
  local rw = layout.listW - 4 - SB
  local me = ns.MyKey()
  local y, nRow, nHead = 0, 0, 0
  for _, week in ipairs(ns.Rules.Weeks(view.events, t, date)) do
    nHead = nHead + 1
    local h = headLabel(L, nHead)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 8, -(y + 6))
    h:SetText(week.label)
    h:Show()
    y = y + HEAD_H
    for _, ev in ipairs(week.events) do
      nRow = nRow + 1
      local b = rowButton(L, nRow)
      b.key = ev.key
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 0, -y)
      drawRow(b, ev, me, layout, rw)
      y = y + ROW_H + ROW_GAP
    end
  end
  for i = nRow + 1, #L.rows do L.rows[i]:Hide() end
  for i = nHead + 1, #L.heads do L.heads[i]:Hide() end
  L.content:SetHeight(math.max(10, y))
end
