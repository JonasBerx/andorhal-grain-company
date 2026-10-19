-- GuildSyncPeople: the week grid frame (plan Task 5, "The week grid"; not a kit piece, plain textures).
-- 7 rows (Monday first, ns.Rules.DAYS) x 24 hours. The grid keeps its own model: the mask string and
-- grid.cells[day][hour].on / .now (always true or false). The large grid takes clicks and drags: OnMouseDown on a cell
-- paints the opposite of that cell's value, OnEnter on another cell applies the paint while a drag is on, and the drag
-- ends on the origin cell's OnMouseUp (the client sends it there) or the grid's OnHide; the grid sets no OnLeave
-- (design review f7). Cells are the full pitch with the colour inset 1 px, so there are no gaps between them (f7a).
-- The grid never reads the clock: SetMask gets it from the caller.

local _, ns = ...
if not ns.M then return end

local Grid = {}
ns.Grid = Grid

local SIZES = {
  -- pitch, drawn cell, label fonts, the day labels ({ row, y } from the grid's top) and their x (NOTES-people.md)
  large = { w = 19, h = 18, cw = 18, ch = 17, dayFont = "GameFontNormalSmall", hourFont = "GameFontHighlightSmall",
    hourGrey = true, dayX = -34,
    days = { { 1, -4 }, { 2, -22 }, { 3, -40 }, { 4, -58 }, { 5, -76 }, { 6, -94 }, { 7, -112 } } },
}
local HOURS = { 0, 6, 12, 18 }

local function colour(cell)
  local tex = cell.tex
  if cell.on then tex:SetColorTexture(1, 0.82, 0, 0.72) else tex:SetColorTexture(1, 1, 1, 0.08) end
end

-- grid = ns.Grid.Build(parent, "large", interactive); the caller anchors it at its first cell's top-left.
function Grid.Build(parent, size, interactive)
  local S = SIZES.large
  local live = interactive == true
  local grid = CreateFrame("Frame", nil, parent)
  grid:SetSize(24 * S.w, 7 * S.h)
  local mask = ""
  local paint -- the drag: the value being painted, nil when no drag is on

  local function changed()
    local fn = rawget(grid, "onChange")
    if type(fn) == "function" then fn(mask) end
  end

  local function apply(cell, on)
    if cell.on == on then return end
    cell.on = on
    mask = ns.Rules.Set(mask, cell.weekday, cell.hour, on)
    colour(cell)
    changed()
  end

  grid.cells = {}
  for d = 1, 7 do
    local row = {}
    grid.cells[d] = row
    for h = 0, 23 do
      local cell = CreateFrame("Button", nil, grid)
      cell:SetSize(S.w, S.h)
      cell:SetPoint("TOPLEFT", grid, "TOPLEFT", h * S.w, -(d - 1) * S.h)
      local tex = cell:CreateTexture(nil, "ARTWORK")
      tex:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 0)
      tex:SetSize(S.cw, S.ch)
      cell.tex = tex
      cell.weekday, cell.hour = ns.Rules.DAYS[d], h
      cell.on, cell.now = false, false
      colour(cell)
      if live then
        cell:EnableMouse(true)
        cell:SetScript("OnMouseDown", function(self, button)
          ns.M.Safe(function()
            if button ~= "LeftButton" then return end
            paint = not self.on
            apply(self, paint)
          end)
        end)
        cell:SetScript("OnEnter", function(self)
          ns.M.Safe(function() if paint ~= nil then apply(self, paint) end end)
        end)
        cell:SetScript("OnMouseUp", function() paint = nil end)
      end
      row[h] = cell
    end
  end
  if live then grid:SetScript("OnHide", function() paint = nil end) end

  -- labels: days at the left, hours 0, 6, 12, 18 above their columns
  for _, at in ipairs(S.days) do
    local fs = grid:CreateFontString(nil, "OVERLAY", S.dayFont)
    fs:SetPoint("TOPLEFT", grid, "TOPLEFT", S.dayX, at[2])
    fs:SetText(ns.Rules.DAY_NAME[ns.Rules.DAYS[at[1]]])
  end
  for _, h in ipairs(HOURS) do
    local fs = grid:CreateFontString(nil, "OVERLAY", S.hourFont)
    fs:SetPoint("TOPLEFT", grid, "TOPLEFT", h * S.w, 12)
    if S.hourGrey then fs:SetTextColor(0.72, 0.72, 0.72) end
    fs:SetText(tostring(h))
  end

  -- the current server hour: four 1-px strips one pixel outside the drawn cell (they lie in the 1-px inset)
  local strips = {}
  for i = 1, 4 do
    local t = grid:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(1, 1, 1, 0.95)
    t:Hide()
    strips[i] = t
  end
  local function outline(cell)
    for _, t in ipairs(strips) do
      t:ClearAllPoints()
      t:SetShown(cell ~= nil)
    end
    if not cell then return end
    local tex = cell.tex
    local top, bottom, left, right = strips[1], strips[2], strips[3], strips[4]
    top:SetPoint("BOTTOMLEFT", tex, "TOPLEFT", -1, 0)
    top:SetPoint("BOTTOMRIGHT", tex, "TOPRIGHT", 1, 0)
    top:SetHeight(1)
    bottom:SetPoint("TOPLEFT", tex, "BOTTOMLEFT", -1, 0)
    bottom:SetPoint("TOPRIGHT", tex, "BOTTOMRIGHT", 1, 0)
    bottom:SetHeight(1)
    left:SetPoint("TOPRIGHT", tex, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMRIGHT", tex, "BOTTOMLEFT", 0, 0)
    left:SetWidth(1)
    right:SetPoint("TOPLEFT", tex, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMLEFT", tex, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(1)
  end

  -- grid:SetMask(mask, clock): the hours from the mask, the outline from the clock ({ weekday, hour }, or nil).
  grid.SetMask = function(self, m, clock)
    mask = ns.Rules.ValidMask(m) and m or ""
    local nowCell
    for d = 1, 7 do
      for h = 0, 23 do
        local cell = self.cells[d][h]
        cell.on = ns.Rules.Has(mask, cell.weekday, h)
        cell.now = type(clock) == "table" and clock.weekday == cell.weekday and clock.hour == h
        if cell.now then nowCell = cell end
        colour(cell)
      end
    end
    outline(nowCell)
  end

  grid.GetMask = function() return mask end

  return grid
end
