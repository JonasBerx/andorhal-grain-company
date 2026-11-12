-- GuildSyncExpeditions BagGrid.lua: the Company bag's grid and the Storage page, ns.BagGrid (0.19 plan, Seams 9, 10; slice P).
--   BagGrid.New(parent, cols, rowsInView, cell, gap, host) -> grid   a pool of cells over ns.Bag(), wheel scrolled; the caller anchors grid.frame
--   BagGrid.Hook(button, host, read)                  read(button) -> a drag or nil; the shared drag, ending in host.drop
--   BagGrid.Tip(owner, entry, level, anchor, readOnly) a piece's or stack's tooltip, from our own data only
--   BagGrid.Menu(owner, entry, host, slotKey)         a piece's right click menu; slotKey set for a worn piece
--   BagGrid.Compare(tip, entry)                       the lines against the piece ns.PickedFollower would take off (ns.ReplaceSlot);
--                                                     nothing with no follower or when it wears entry.id; reads only
--   BagGrid.Build(f, bar), BagGrid.Refresh(f)         the Storage page, host f.bag, the count in bar (left of bar.barracks when the band made one);
--                                                     Sell All Poor and Repair All right of the grid (host.sellPoor, host.repairAll)
-- A host is f.bag here or f.char on the Barracks; see the plan's Seams for its fields.
-- ns.GearCore, ns.GearData, ns.BookData and ns.W are read at call time: they load after this file.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local CELLS = 64
local COLS = 8
local BIG = { cell = 37, gap = 3 }
local SMALL = { cell = 35, gap = 2 }
local BIG_W, BIG_H = 700, 450
local TOP = 8
local RAIL = 10 -- the scroll column's width

local SLOT_LABEL = { head = "Head", neck = "Neck", shoulder = "Shoulder", back = "Back", chest = "Chest",
  wrist = "Wrist", hands = "Hands", waist = "Waist", legs = "Legs", feet = "Feet", finger = "Finger",
  trinket = "Trinket", mainhand = "Main Hand", offhand = "Off Hand" }
local SCRAP = { [1] = "Rusted salvage", [2] = "Iron salvage" }
local SCRAP_ICON = { [1] = "Interface\\Icons\\INV_Misc_Gear_02", [2] = "Interface\\Icons\\INV_Ingot_Iron" }
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Every supply the game can hand out. The chart has no use here: its line names a word from ns.W, see useLine.
local SUPPLIES = {
  rations = { name = "Field Rations", icon = "Interface\\Icons\\INV_Misc_Food_59",
    use = "Use: +5% chance of success on one expedition." },
  bandage = { name = "Linen Bandage", icon = "Interface\\Icons\\INV_Misc_Bandage_12",
    use = "Use: Halves the chance of being wounded on one expedition." },
  whetstone = { name = "Whetstone Kit", icon = "Interface\\Icons\\INV_Stone_SharpeningStone_01",
    use = "Use: Halves the chance of broken or lost gear on one expedition." },
  candle = { name = "Spirit Candle", icon = "Interface\\Icons\\INV_Misc_Candle_01",
    use = "Use: Halves the chance of death on one expedition." },
  scoutchart = { name = "Scout's Chart", icon = "Interface\\Icons\\INV_Misc_Map_01" },
  gravemoss = { name = "Grave-moss Charm", icon = "Interface\\Icons\\INV_Misc_Herb_07",
    use = "Use: Keeps a follower from dying for good on one expedition." },
}

local WHITE = "ffffff"
local EMPTY_EDGE = { 0.35, 0.30, 0.20 }

local LINES = {
  taken = "That slot is taken.",
  max = "This piece is fully tempered.",
  short = "Not enough scrap.",
  level = "That follower is too low level for this piece.",
  busy = "That follower is away.",
}
-- What a call that pays through ns.Grain answers before it gets there. Any other why came from ns.Grain, which has spoken.
local BEFORE_GRAIN = { unknown = true, intact = true, quality = true, worn = true }

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function isBig(f)
  return f:GetWidth() >= BIG_W and f:GetHeight() >= BIG_H
end

local function refuse(why, viaGrain)
  if why == "demo" or (viaGrain and not BEFORE_GRAIN[why]) then return end
  if why == "full" then
    ns.Say(ns.W.Name["Company bag"] .. " is full.")
  else
    ns.Say(LINES[why] or "You cannot do that now.")
  end
end

local function useLine(supply)
  return supply.use or ("Use: +10% chance of success on one " .. ns.W.Name.Scout .. " expedition.")
end

-- ns.BookData loads after this file and may be absent.
local function relicOf(key)
  local book = ns.BookData
  for _, r in ipairs(book and book.relics or {}) do
    if r.id == key then return r end
  end
  return nil
end

local function stackIcon(kind, key)
  if kind == "salvage" then return SCRAP_ICON[key] or UNKNOWN_ICON end
  local s = (kind == "supply" and SUPPLIES[key]) or (kind == "relic" and relicOf(key))
  return s and s.icon or UNKNOWN_ICON
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

-- How many pieces of the set the follower on the owner's host has on; 0 with no follower shown.
local function setCount(owner, set)
  local host = rawget(owner, "bagHost")
  local follower = host and host.fid and ns.Follower(host.fid)
  if not follower then return 0 end
  local n = 0
  for _, id in pairs(follower.gear) do
    local worn = ns.Gear(id)
    local row = worn and ns.GearData.Row(worn.row)
    if row and row.set == set then n = n + 1 end
  end
  return n
end

-- A piece's base line and +stat lines. The Quartermaster adds the same lines through BagGrid.StatLines.
local function statLines(tip, piece)
  local s = ns.GearCore.PieceStats(piece)
  if s.armor then tip:AddLine(s.armor .. " Armor", 1, 1, 1) end
  if s.low then tip:AddLine(s.low .. " - " .. s.high .. " Damage", 1, 1, 1) end
  for _, stat in ipairs(s.stats) do
    tip:AddLine("+" .. stat.n .. " " .. stat.name, 0.12, 1, 0)
  end
end

local function signed(n) return (n > 0 and "+" or "") .. n end

-- Green for more, red for less.
local function tint(d)
  if d > 0 then return 0.12, 1, 0 end
  return 1, 0.13, 0.13
end

-- One line for a change that is not 0, with its sign.
local function change(tip, d, text)
  if d ~= 0 then tip:AddLine(signed(d) .. text, tint(d)) end
end

-- Both sides are read as { row, temper }, so a broken piece compares at the values its own tooltip shows.
local function compare(tip, entry)
  local GC, GD = ns.GearCore, ns.GearData
  local follower = ns.PickedFollower and ns.PickedFollower()
  local row = GD.Row(entry.row)
  if not (follower and row and ns.ReplaceSlot) then return end
  for _, id in pairs(follower.gear) do
    if entry.id and id == entry.id then return end
  end
  local slot, worn = ns.ReplaceSlot(follower.id, entry.row)
  if not slot then return end
  local wornRow = worn and GD.Row(worn.row)
  local name = ns.Escape(follower.name)
  if wornRow then
    tip:AddLine("If " .. name .. " wears this instead of " .. wornRow.name .. ":", 1, 0.82, 0)
  else
    tip:AddLine("If " .. name .. " wears this (" .. SLOT_LABEL[GC.KIND[row.slot]] .. " empty):", 1, 0.82, 0)
  end
  local new = { row = entry.row, temper = entry.temper }
  local old = wornRow and { row = worn.row, temper = worn.temper }
  local a, b = GC.PieceStats(new), old and GC.PieceStats(old) or { stats = {} }
  change(tip, GC.Value(new) - (old and GC.Value(old) or 0), " " .. ns.W.Name["piece value"])
  change(tip, (a.armor or 0) - (b.armor or 0), " Armor")
  local low, high = (a.low or 0) - (b.low or 0), (a.high or 0) - (b.high or 0)
  if low ~= 0 or high ~= 0 then tip:AddLine(signed(low) .. " - " .. signed(high) .. " Damage", tint(low ~= 0 and low or high)) end
  local have, had = {}, {}
  for _, s in ipairs(a.stats) do have[s.name] = s.n end
  for _, s in ipairs(b.stats) do had[s.name] = s.n end
  for _, stat in ipairs(GC.STATS) do change(tip, (have[stat] or 0) - (had[stat] or 0), " " .. stat) end
end

local function pieceTip(tip, owner, entry, level, readOnly)
  local GC, W = ns.GearCore, ns.W
  local row = ns.GearData.Row(entry.row)
  if not row then
    tip:SetText("Unknown item", 1, 1, 1)
    return
  end
  local need = GC.WearLevel(row.tier)
  local r, g, b = rgb(GC.QUALITY_COLOUR[row.q])
  tip:SetText(row.name, r, g, b)
  tip:AddLine(SLOT_LABEL[GC.KIND[row.slot]], 1, 1, 1)
  tip:AddLine(W.Name["piece value"] .. " " .. GC.Value({ row = entry.row, temper = entry.temper }), 1, 0.82, 0)
  statLines(tip, entry)
  if entry.temper and entry.temper > 0 then tip:AddLine("Tempered +" .. entry.temper, 0.12, 1, 0) end
  tip:AddLine(W.Requires(need, level >= need), 1, 1, 1)
  if entry.broken then tip:AddLine("Broken", 1, 0.13, 0.13) end
  if row.set then tip:AddLine(readOnly and row.set or (row.set .. " (" .. setCount(owner, row.set) .. "/6)"), 1, 0.82, 0) end
  if not readOnly then
    tip:AddLine("<Right Click for options>", 0, 1, 0)
    compare(tip, entry)
  end
end

local function salvageTip(tip, tier)
  local GC = ns.GearCore
  tip:SetText(ns.W.Name[SCRAP[tier]], 1, 1, 1)
  tip:AddLine("Crafting Reagent", 0.4, 0.73, 1)
  local from, nextTier = GC.WearLevel(tier), GC.WearLevel(tier + 1)
  if nextTier then
    tip:AddLine("Tempers gear of level " .. from .. " to " .. (nextTier - 1) .. ".", 1, 1, 1)
  else
    tip:AddLine("Tempers gear of level " .. from .. " and up.", 1, 1, 1)
  end
end

local function stackTip(tip, entry)
  if entry.kind == "salvage" and SCRAP[entry.key] then
    salvageTip(tip, entry.key)
    return
  end
  local supply = entry.kind == "supply" and SUPPLIES[entry.key]
  local relic = entry.kind == "relic" and relicOf(entry.key)
  if supply then
    tip:SetText(supply.name, 1, 1, 1)
    tip:AddLine(useLine(supply), 0, 1, 0)
  elseif relic then
    tip:SetText(relic.name, 1, 1, 1)
    tip:AddLine("Relic", 0.4, 0.73, 1)
  else
    tip:SetText("Unknown item", 1, 1, 1)
  end
end

local BagGrid = {}
ns.BagGrid = BagGrid
BagGrid.StatLines = statLines
BagGrid.Compare = compare

function BagGrid.Tip(owner, entry, level, anchor, readOnly)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, anchor)
  if entry.kind then stackTip(tip, entry) else pieceTip(tip, owner, entry, level, readOnly) end
  tip:Show()
end

-- Redraws the page the host belongs to; ns.CharacterTab is read at call time.
local function redraw(host)
  local f = host.root
  if f.char == host then ns.CharacterTab.Refresh(f) else BagGrid.Refresh(f) end
end

function BagGrid.Menu(owner, entry, host, slotKey)
  if entry.kind or not ns.GearData.Row(entry.row) then return end
  local id = entry.id
  M.Kit.ContextMenu(owner, function(_, root)
    local function item(text, act, viaGrain)
      root:CreateButton(text, function()
        M.Safe(function()
          local done, why = act()
          if not done then refuse(why, viaGrain) end
          redraw(host)
        end)
      end)
    end
    if slotKey then
      local function unlessAway(act)
        return function()
          local follower = ns.Follower(host.fid)
          if follower and follower.state == "out" then return nil, "busy" end
          return act()
        end
      end
      item("Take Off", function() return ns.Unequip(host.fid, slotKey) end)
      item("Temper", unlessAway(function() return ns.Temper(id) end))
      item("Repair", unlessAway(function() return ns.Repair(id, "salvage") end))
      return
    end
    if host.fid then
      item("Equip on " .. host.name, function() return ns.Equip(host.fid, id) end)
    end
    item("Temper", function() return ns.Temper(id) end)
    item("Repair (Scrap)", function() return ns.Repair(id, "salvage") end)
    item("Repair (Grain)", function() return ns.Repair(id, "grain") end, true)
    item("Sell", function() return ns.SellPiece(id) end, true)
    item("Break Down", function() return ns.BreakDown(id) end)
  end)
end

local function ghostIcon(drag)
  if drag.kind == "piece" then return drag.row and drag.row.icon or UNKNOWN_ICON end
  return stackIcon(drag.kind, drag.key)
end

local function ensureGhost(host)
  if host.ghost then return end
  local ghost = CreateFrame("Frame", nil, host.root)
  ghost:SetFrameStrata("DIALOG")
  ghost:SetMovable(true)
  ghost:EnableMouse(false)
  ghost.icon = ghost:CreateTexture(nil, "ARTWORK")
  ghost.icon:SetAllPoints(ghost)
  ghost:SetScript("OnHide", function(self)
    M.Safe(function()
      self:StopMovingOrSizing()
      host.drag = nil
      self:Hide() -- hidden with its page it keeps its shown flag, and would come back with the page
    end)
  end)
  ghost:Hide()
  host.ghost = ghost
end

local function startDrag(button, host, read)
  local drag = read(button)
  if not drag then return end
  drag.from = button
  host.drag = drag
  local ghost = host.ghost
  ghost.icon:SetTexture(ghostIcon(drag))
  ghost:SetSize(button:GetWidth(), button:GetHeight())
  ghost:ClearAllPoints()
  ghost:SetPoint("CENTER", button, "CENTER", 0, 0)
  ghost:Show()
  ghost:StartMoving()
end

local function stopDrag(host)
  local drag = host.drag
  if not drag then return end
  host.ghost:Hide() -- its OnHide clears host.drag
  for _, target in ipairs(host.targets) do
    local frame = target.frame
    if frame:IsVisible() and frame:IsMouseOver() then
      host.drop(drag, target)
      return
    end
  end
end

function BagGrid.Hook(button, host, read)
  ensureGhost(host)
  button.bagHost = host
  button:RegisterForDrag("LeftButton")
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:SetScript("OnDragStart", function(self) M.Safe(startDrag, self, host, read) end)
  button:SetScript("OnDragStop", function() M.Safe(stopDrag, host) end)
end

local function edge(frame, a, b, across)
  local t = frame:CreateTexture(nil, "BORDER")
  t:SetPoint(a, frame, a, 0, 0)
  t:SetPoint(b, frame, b, 0, 0)
  if across then t:SetHeight(1) else t:SetWidth(1) end
  return t
end

local function dragOf(entry)
  if not entry then return nil end
  if entry.kind then return { id = entry.id, kind = entry.kind, key = entry.key } end
  return { id = entry.id, kind = "piece", row = ns.GearData.Row(entry.row) }
end

local function tipLevel(host)
  local follower = host.fid and ns.Follower(host.fid)
  if follower then return follower.level end
  local top = 1
  for _, x in ipairs(ns.Followers()) do top = math.max(top, x.level) end
  return top
end

local function paint(view, entry)
  local icon, count, r, g, b = nil, "", EMPTY_EDGE[1], EMPTY_EDGE[2], EMPTY_EDGE[3]
  if entry and entry.kind then
    icon, count = stackIcon(entry.kind, entry.key), tostring(entry.n)
    r, g, b = rgb(WHITE)
  elseif entry then
    local row = ns.GearData.Row(entry.row)
    icon = row and row.icon or UNKNOWN_ICON
    r, g, b = rgb(row and ns.GearCore.QUALITY_COLOUR[row.q] or WHITE)
  end
  view.icon:SetTexture(icon)
  view.count:SetText(count)
  for _, t in ipairs(view.edges) do t:SetColorTexture(r, g, b) end
end

-- A cell past the bag's 64 (the last row of a 5-wide grid) stays hidden; so does every cell of a grid whose frame is hidden.
local function fill(grid)
  local bag = ns.Bag()
  local on = grid.frame:IsShown()
  for i, b in ipairs(grid.cells) do
    local index = (grid.first - 1) * grid.cols + i
    local entry = bag[index]
    grid.entries[i] = entry
    grid.targets[i].key = index
    paint(grid.views[i], entry)
    b:SetShown(on and index <= CELLS)
  end
end

local function scroll(grid, delta)
  local last = math.max(1, math.ceil(CELLS / grid.cols) - grid.rows + 1)
  grid.first = math.max(1, math.min(last, grid.first + (delta < 0 and 1 or -1)))
  grid.Fill(grid)
end

local function newCell(grid, i, cell, host)
  local b = CreateFrame("Button", nil, grid.frame)
  b:SetSize(cell, cell)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(b)
  bg:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  bg:SetTexCoord(0.1875, 0.8125, 0.1875, 0.8125)
  local view = { icon = b:CreateTexture(nil, "ARTWORK"), count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal"),
    edges = { edge(b, "TOPLEFT", "TOPRIGHT", true), edge(b, "BOTTOMLEFT", "BOTTOMRIGHT", true),
      edge(b, "TOPLEFT", "BOTTOMLEFT"), edge(b, "TOPRIGHT", "BOTTOMRIGHT") } }
  view.icon:SetAllPoints(b)
  view.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
  grid.views[i] = view
  BagGrid.Hook(b, host, function() return dragOf(grid.entries[i]) end)
  b:SetScript("OnClick", function(self, which)
    local entry = grid.entries[i]
    if which == "RightButton" and entry then M.Safe(BagGrid.Menu, self, entry, host) end
  end)
  b:SetScript("OnEnter", function(self)
    local entry = grid.entries[i]
    if entry then
      local anchor = isBig(host.root) and "ANCHOR_RIGHT" or "ANCHOR_LEFT"
      M.Safe(function() BagGrid.Tip(self, entry, tipLevel(host), anchor) end)
    end
  end)
  b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  return b
end

local function arrow(grid, texture, point, delta)
  local b = CreateFrame("Button", nil, grid.frame)
  b:SetSize(RAIL, RAIL)
  b:SetPoint(point, grid.frame, point, 0, 0)
  b:SetNormalTexture(texture)
  b:SetScript("OnClick", function() M.Safe(grid.Scroll, grid, delta) end)
end

function BagGrid.New(parent, cols, rowsInView, cell, gap, host)
  local grid = { frame = CreateFrame("Frame", nil, parent), cells = {}, entries = {}, views = {}, targets = {},
    first = 1, rows = rowsInView, cols = cols, Fill = fill, Scroll = scroll }
  local pitch = cell + gap
  local width = cols * cell + (cols - 1) * gap
  if cols * rowsInView < CELLS then
    -- The table's two embedded grids: BIG has exactly RAIL px left in f (515 + 201 + 10 = 726), SMALL one more.
    width = width + (gap > 1 and 0 or 1) + RAIL
    arrow(grid, "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up", "TOPRIGHT", 1)
    arrow(grid, "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up", "BOTTOMRIGHT", -1)
  end
  grid.frame:SetSize(width, rowsInView * cell + (rowsInView - 1) * gap)
  grid.frame:EnableMouseWheel(true)
  grid.frame:SetScript("OnMouseWheel", function(_, delta) M.Safe(grid.Scroll, grid, delta) end)
  for i = 1, cols * rowsInView do
    local b = newCell(grid, i, cell, host)
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    b:SetPoint("TOPLEFT", grid.frame, "TOPLEFT", col * pitch, -row * pitch)
    grid.cells[i] = b
    grid.targets[i] = { frame = b, kind = "cell", key = i }
    host.targets[#host.targets + 1] = grid.targets[i]
  end
  grid.Fill(grid)
  return grid
end

local function place(f)
  local host = f.bag
  local big = isBig(f)
  local grid, other = big and host.big or host.small, big and host.small or host.big
  other.frame:Hide()
  grid.frame:Show()
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor((f:GetWidth() - grid.frame:GetWidth()) / 2), -TOP)
  host.held:ClearAllPoints()
  host.held:SetPoint("TOP", grid.frame, "BOTTOM", 0, -4)
  host.sellPoor:ClearAllPoints()
  host.sellPoor:SetPoint("TOPLEFT", grid.frame, "TOPRIGHT", 12, 0)
  host.repairAll:ClearAllPoints()
  host.repairAll:SetPoint("TOPLEFT", host.sellPoor, "BOTTOMLEFT", 0, -6)
  host.grid = grid
end

function BagGrid.Refresh(f)
  local host = f.bag
  place(f)
  host.big.Fill(host.big)
  host.small.Fill(host.small)
  local n = 0
  for _ in pairs(ns.Bag()) do n = n + 1 end
  host.count:SetText(n .. "/" .. CELLS)
  local held = ns.HeldEpics and ns.HeldEpics()
  host.held:SetShown(held and #held > 0 or false)
  host.sellPoor:SetEnabled(#ns.PoorInStorage() > 0)
  local _, fixable = ns.RepairState()
  host.repairAll:SetEnabled(fixable > 0)
end

local function pieces(n) return n .. (n == 1 and " Poor piece" or " Poor pieces") end

-- Sells only the ids the dialog counted; ns.SellPoor skips any no longer grey in Storage. A grain refusal has spoken.
local function sellPoorClick(f)
  if ns.Inert() then return end
  local list, total = ns.PoorInStorage()
  if #list == 0 then return end
  local ids = {}
  for i, e in ipairs(list) do ids[i] = e.id end
  M.Kit.Confirm("expeditions_sellpoor", "Sell " .. pieces(#list) .. " for " .. total .. " grain?", "Sell All", function()
    local sold, grain, why = ns.SellPoor(ids)
    if sold and sold > 0 then
      ns.Say("Sold " .. pieces(sold) .. " for " .. grain .. " grain.")
    elseif not why then
      ns.Say("No Poor piece left to sell.") -- the dialog is not modal: the counted pieces went before yes
    end
    if why then refuse(why, true) end
    BagGrid.Refresh(f)
  end)
end

-- Scrap only, no confirm. The grid may be stale since its last redraw, so the line names what the click found.
local function repairAllClick(f)
  if ns.Inert() then return end
  local repaired, broken = ns.RepairAll()
  if repaired and repaired > 0 then
    ns.Say("Repaired " .. repaired .. (repaired == 1 and " piece; " or " pieces; ") .. broken .. " still broken.")
  elseif broken == 0 then
    ns.Say("Nothing is broken.")
  else
    ns.Say(LINES.short)
  end
  BagGrid.Refresh(f)
end

local function storageButton(f, text, onClick)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(110, 22)
  b:SetText(text)
  b:SetScript("OnClick", function() M.Safe(onClick, f) end)
  return b
end

function BagGrid.Build(f, bar)
  local host = { root = f, targets = {} }
  f.bag = host
  function host.drop(drag, target)
    if target.frame == drag.from or drag.kind ~= "piece" then return end
    local done, why = ns.MovePiece(drag.id, target.key)
    if not done then refuse(why) end
    BagGrid.Refresh(f)
  end
  host.big = BagGrid.New(f, COLS, COLS, BIG.cell, BIG.gap, host)
  host.small = BagGrid.New(f, COLS, COLS, SMALL.cell, SMALL.gap, host)
  host.count = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  if bar.barracks then
    host.count:SetPoint("RIGHT", bar.barracks, "LEFT", -8, 0)
  else
    host.count:SetPoint("RIGHT", bar, "RIGHT", -8, 0)
  end
  host.held = f:CreateFontString(nil, "OVERLAY", "GameFontRed")
  host.held:SetText(ns.W.Name["Company bag"] .. " is full. Free a slot.")
  host.held:Hide()
  host.sellPoor = storageButton(f, "Sell All Poor", sellPoorClick)
  host.repairAll = storageButton(f, "Repair All", repairAllClick)
  f:SetScript("OnSizeChanged", function(self) M.Safe(BagGrid.Refresh, self) end)
end
