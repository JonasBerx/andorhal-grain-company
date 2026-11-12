-- GuildSyncExpeditions Gear.lua: the Company bag and what followers wear (0.19 plan, Seams 7, 8, 9).
--   ns.Bag() -> { [cell] = copy }                      ns.Gear(id) -> copy | nil
--   ns.StackCount(kind, key) -> n                      ns.KitScore(fid) -> n
--   ns.AddStack(kind, key, n), ns.TakeStack(kind, key, n), ns.GrantMaterial(tier, n), ns.AddGear(spec)
--   ns.Equip(fid, id), ns.Unequip(fid, slot), ns.UnequipAll(fid), ns.MovePiece(id, cell)
--   ns.Temper(id), ns.Repair(id, how), ns.Buy(code) (third value true when ns.Grain has already said the line), ns.OnSale(row), ns.SellPiece(id), ns.BreakDown(id)
--   ns.BreakGear(fid, slot), ns.LoseGear(fid, slot), ns.LeaveWorn(fid)
--   ns.ReplaceSlot(fid, code) -> slot | nil, worn copy | nil (the slot Equip fills: an empty one, else the weaker worn piece)
--   ns.PoorInStorage() -> { { id, n }, ... }, total     ns.SellPoor(ids) -> sold, grain, why (each by ns.SellPiece)
--   ns.RepairState() -> broken, fixable                 ns.RepairAll() -> repaired, stillBroken (each by ns.Repair, salvage)
-- Every write answers nil, "demo" through ns.Inert first. Grain moves only through ns.Grain.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local GC, GD, FC = ns.GearCore, ns.GearData, ns.FollowerCore

local CELLS = 64
local TEMPER_MAX = 5

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function amount(n)
  return whole(n, 1, math.huge) and n ~= math.huge
end

local function goodKey(kind, key)
  if not GC.STACK_MAX[kind] then return false end
  if kind == "salvage" then return GC.WearLevel(key) ~= nil end -- a salvage key is a tier
  return type(key) == "string" and #key <= FC.TEXT_MAX and string.match(key, "^[%w_]+$") ~= nil
end

local function fresh() return { next = 1, rows = {} } end

-- A new table of the known fields only, as FC.SoundRow.
local function soundBagRow(id, row)
  if type(row) ~= "table" or not whole(id, 1, FC.ID_MAX) then return nil end
  if row.cell ~= nil and not whole(row.cell, 1, CELLS) then return nil end
  if row.kind == nil then
    if not GD.WellFormed(row.row) then return nil end
    return { id = id, row = row.row, cell = row.cell, broken = row.broken == true,
      temper = whole(row.temper, 0, TEMPER_MAX) and row.temper or 0 }
  end
  if row.cell == nil or not goodKey(row.kind, row.key) or not amount(row.n) then return nil end
  return { id = id, kind = row.kind, key = row.key, n = math.min(row.n, GC.STACK_MAX[row.kind]), cell = row.cell }
end

local function sortedIds(rows)
  local ids = {}
  for id in pairs(rows) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function listFree(used)
  local free = {}
  for cell = 1, CELLS do
    if not used[cell] then free[#free + 1] = cell end
  end
  return free
end

local function freeCells(rows)
  local used = {}
  for _, r in pairs(rows) do
    if r.cell then used[r.cell] = true end
  end
  return listFree(used)
end

-- Every earlier id claims its cell first, so a clash cannot push a row out of a cell that was rightly its own.
local function settleClashes(rows)
  local used, late = {}, {}
  for _, id in ipairs(sortedIds(rows)) do
    local cell = rows[id].cell
    if cell and used[cell] then
      late[#late + 1] = id
    elseif cell then
      used[cell] = true
    end
  end
  local free = listFree(used)
  for i, id in ipairs(late) do
    rows[id].cell = free[i]
    if not free[i] then rows[id] = nil end
  end
end

local last

-- At use, never at file load: saved variables are not ready then. Store runs soundBagRow per row, so the clash pass
-- has to live here.
local function bag()
  local p = ns.Part("bag", fresh, soundBagRow)
  if not rawequal(last, p) then
    settleClashes(p.rows)
    last = p
  end
  return p
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function freed()
  if ns.TakeHeld then M.Safe(ns.TakeHeld) end
end

local function stacksOf(rows, kind, key)
  local out = {}
  for _, id in ipairs(sortedIds(rows)) do
    local r = rows[id]
    if r.kind == kind and r.key == key then out[#out + 1] = r end
  end
  return out
end

-- All or nothing. Never runs freed().
local function addStack(p, kind, key, n)
  local cap = GC.STACK_MAX[kind]
  local stacks = stacksOf(p.rows, kind, key)
  local room = 0
  for _, s in ipairs(stacks) do room = room + cap - s.n end
  local newRows = math.max(0, math.ceil((n - room) / cap))
  local free = freeCells(p.rows)
  local id = FC.NextId(p)
  if newRows > #free or (newRows > 0 and (not id or id + newRows - 1 > FC.ID_MAX)) then return nil, "full" end
  for _, s in ipairs(stacks) do
    local add = math.min(n, cap - s.n)
    s.n = s.n + add
    n = n - add
  end
  for i = 1, newRows do
    local add = math.min(n, cap)
    p.rows[id] = { id = id, kind = kind, key = key, n = add, cell = free[i] }
    p.next = id + 1
    id = id + 1
    n = n - add
  end
  return true
end

-- Smallest stack first. Answers true, whether a stack reached 0. Never runs freed().
local function takeStack(p, kind, key, n)
  if not amount(n) then return nil, "amount" end
  local stacks = stacksOf(p.rows, kind, key)
  local total = 0
  for _, s in ipairs(stacks) do total = total + s.n end
  if total < n then return nil, "short" end
  table.sort(stacks, function(a, b)
    if a.n ~= b.n then return a.n < b.n end
    return a.id < b.id
  end)
  local emptied = false
  for _, s in ipairs(stacks) do
    local take = math.min(n, s.n)
    s.n = s.n - take
    n = n - take
    if s.n == 0 then
      p.rows[s.id] = nil
      emptied = true
    end
  end
  return true, emptied
end

local function pieceOf(p, id)
  local r = p.rows[id]
  if r and not r.kind then return r end
  return nil
end

local function known(p, id)
  local piece = pieceOf(p, id)
  local row = piece and GD.Row(piece.row)
  if row then return piece, row end
  return nil
end

-- A gear id whose piece is gone counts as empty. A read never repairs it; the next Equip overwrites it.
local function wornPiece(p, f, slot)
  local piece = pieceOf(p, f.gear[slot])
  if piece and piece.cell == nil then return piece end
  return nil
end

local function wornPieces(p, f)
  local out = {}
  for _, s in ipairs(GD.SLOTS) do
    local piece = wornPiece(p, f, s.key)
    if piece then out[#out + 1] = piece end
  end
  return out
end

-- The first slot of the row's kind with no worn piece (or one whose row is unknown), else the worn piece with the lowest
-- Item Level read as intact, the first on a tie. Answers slot, the worn piece itself or nil.
local function replaceSlot(p, f, row)
  local best, bestPiece, bestValue
  for _, s in ipairs(GD.SLOTS) do
    if GC.KIND[s.key] == GC.KIND[row.slot] then
      local piece = wornPiece(p, f, s.key)
      if not piece or not GD.Row(piece.row) then return s.key, nil end
      local value = GC.Value({ row = piece.row, temper = piece.temper })
      if not bestValue or value < bestValue then best, bestPiece, bestValue = s.key, piece, value end
    end
  end
  return best, bestPiece
end

local function idle(fid)
  local f = ns.Follower(fid)
  if not f then return nil, "unknown" end
  if f.state == "out" then return nil, "busy" end
  return f
end

local function putPiece(p, id, code, cell, temper)
  p.rows[id] = { id = id, row = code, cell = cell, temper = temper, broken = false }
  p.next = id + 1
end

function ns.Bag()
  local out = {}
  for _, r in pairs(bag().rows) do
    if r.cell then out[r.cell] = copy(r) end
  end
  return out
end

function ns.Gear(id)
  local r = bag().rows[id]
  return r and copy(r)
end

function ns.ReplaceSlot(fid, code)
  local f = ns.Follower(fid)
  local row = GD.Row(code)
  if not f or not row then return nil, nil end
  local slot, piece = replaceSlot(bag(), f, row)
  return slot, piece and copy(piece)
end

function ns.StackCount(kind, key)
  if not goodKey(kind, key) then return 0 end
  local total = 0
  for _, s in ipairs(stacksOf(bag().rows, kind, key)) do total = total + s.n end
  return total
end

function ns.KitScore(fid)
  local f = ns.Follower(fid)
  if not f then return 0 end
  local p = bag()
  local pieces = {}
  for _, s in ipairs(GD.SLOTS) do pieces[s.key] = wornPiece(p, f, s.key) end
  return GC.KitScore(pieces)
end

function ns.AddStack(kind, key, n)
  if ns.Inert() then return nil, "demo" end
  if not goodKey(kind, key) then return nil, "kind" end
  if not amount(n) then return nil, "amount" end
  return addStack(bag(), kind, key, n)
end

function ns.TakeStack(kind, key, n)
  if ns.Inert() then return nil, "demo" end
  if not goodKey(kind, key) then return nil, "kind" end
  local done, emptied = takeStack(bag(), kind, key, n)
  if not done then return nil, emptied end
  if emptied then freed() end
  return true
end

function ns.GrantMaterial(tier, n)
  return ns.AddStack("salvage", tier, n)
end

function ns.AddGear(spec)
  if ns.Inert() then return nil, "demo" end
  local code = type(spec) == "table" and spec.row or nil
  if not GD.Row(code) then return nil, "unknown" end
  local p = bag()
  local cell = freeCells(p.rows)[1]
  local id = FC.NextId(p)
  if not cell or not id then return nil, "full" end
  putPiece(p, id, code, cell, whole(spec.temper, 0, TEMPER_MAX) and spec.temper or 0)
  return id
end

function ns.Equip(fid, itemId)
  if ns.Inert() then return nil, "demo" end
  local f, why = idle(fid)
  if not f then return nil, why end
  local p = bag()
  local piece, row = known(p, itemId)
  if not piece or not piece.cell then return nil, "unknown" end
  if f.level < GC.WearLevel(row.tier) then return nil, "level" end
  local slot = replaceSlot(p, f, row)
  local old = wornPiece(p, f, slot)
  local cell = piece.cell
  piece.cell = nil
  f.gear[slot] = itemId
  if old then
    old.cell = cell
  else
    freed()
  end
  return true
end

function ns.Unequip(fid, slot)
  if ns.Inert() then return nil, "demo" end
  local f, why = idle(fid)
  if not f then return nil, why end
  local p = bag()
  local piece = wornPiece(p, f, slot)
  if not piece then return nil, "empty" end
  local cell = freeCells(p.rows)[1]
  if not cell then return nil, "full" end
  piece.cell = cell
  f.gear[slot] = nil
  return true
end

function ns.UnequipAll(fid)
  if ns.Inert() then return nil, "demo" end
  local f, why = idle(fid)
  if not f then return nil, why end
  local p = bag()
  local pieces = wornPieces(p, f)
  local free = freeCells(p.rows)
  if #pieces > #free then return nil, "full" end
  for i, piece in ipairs(pieces) do piece.cell = free[i] end
  f.gear = {}
  return true
end

function ns.MovePiece(itemId, cell)
  if ns.Inert() then return nil, "demo" end
  local p = bag()
  local piece = pieceOf(p, itemId)
  if not piece or not piece.cell then return nil, "unknown" end
  if not whole(cell, 1, CELLS) then return nil, "cell" end
  for _, r in pairs(p.rows) do
    if r.cell == cell then return nil, "taken" end
  end
  piece.cell = cell
  return true
end

function ns.Temper(itemId)
  if ns.Inert() then return nil, "demo" end
  local p = bag()
  local piece, row = known(p, itemId)
  if not piece then return nil, "unknown" end
  if piece.temper >= TEMPER_MAX then return nil, "max" end
  local cost = GC.TemperCost(GC.WEIGHT[row.slot], piece.temper + 1, row.q)
  local done, emptied = takeStack(p, "salvage", row.tier, cost)
  if not done then return nil, emptied end
  piece.temper = piece.temper + 1
  if emptied then freed() end
  return true
end

function ns.Repair(itemId, how)
  if ns.Inert() then return nil, "demo" end
  local p = bag()
  local piece, row = known(p, itemId)
  if not piece then return nil, "unknown" end
  if not piece.broken then return nil, "intact" end
  local salvage, grain = GC.RepairCost(row)
  local emptied = false
  if how == "salvage" then
    local done, result = takeStack(p, "salvage", row.tier, salvage)
    if not done then return nil, result end
    emptied = result
  elseif how == "grain" then
    if not grain then return nil, "quality" end
    if grain > 0 then
      local paid, refused = ns.Grain("spend", grain)
      if not paid then return nil, refused end
    end
  else
    return nil, "how"
  end
  piece.broken = false
  if emptied then freed() end
  return true
end

-- With no Story.lua no chapter is done, so the shop is the short one.
function ns.OnSale(row)
  return GC.OnSale(row, ns.ChaptersDone and #ns.ChaptersDone() or 0)
end

-- Every check comes before the spend and only plain assignments after it, so grain is never taken for nothing.
function ns.Buy(code)
  if ns.Inert() then return nil, "demo" end
  local row = GD.Row(code)
  if not row then return nil, "unknown" end
  local price = GC.SlotPrice(row)
  if not price then return nil, "quality" end
  if not ns.OnSale(row) then return nil, "stock" end
  local p = bag()
  local cell = freeCells(p.rows)[1]
  local id = FC.NextId(p)
  if not cell or not id then return nil, "full" end
  local have, why = M.Purse()
  if not have then return nil, why end
  if have < price then return nil, "short" end
  local paid, refused = ns.Grain("spend", price)
  if not paid then return nil, refused, true end
  putPiece(p, id, code, cell, 0)
  return id
end

function ns.SellPiece(itemId)
  if ns.Inert() then return nil, "demo" end
  local p = bag()
  local piece, row = known(p, itemId)
  if not piece then return nil, "unknown" end
  if not piece.cell then return nil, "worn" end
  local n = GC.Sellable(row)
  if not n then return nil, "quality" end
  if n > 0 then
    local paid, refused = ns.Grain("credit", n)
    if not paid then return nil, refused end
  end
  p.rows[itemId] = nil
  freed()
  return true, n
end

-- Storage pieces (with a cell) in cell order whose row is known.
local function storagePieces(p)
  local byCell = {}
  for _, r in pairs(p.rows) do
    if not r.kind and r.cell and GD.Row(r.row) then byCell[r.cell] = r end
  end
  local out = {}
  for cell = 1, CELLS do
    if byCell[cell] then out[#out + 1] = byCell[cell] end
  end
  return out
end

-- A grey piece that sells for 0 still counts, as the single Sell removes it too.
function ns.PoorInStorage()
  local list, total = {}, 0
  for _, piece in ipairs(storagePieces(bag())) do
    local row = GD.Row(piece.row)
    local n = row.q == 0 and GC.Sellable(row)
    if n then
      list[#list + 1] = { id = piece.id, n = n }
      total = total + n
    end
  end
  return list, total
end

-- Only listed ids still in Storage and still grey; one ns.SellPiece (one credit) each, stopping at a refusal.
function ns.SellPoor(ids)
  if ns.Inert() then return nil, "demo" end
  local sold, grain = 0, 0
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    local piece, row = known(bag(), id)
    if piece and piece.cell and row.q == 0 then
      local done, n = ns.SellPiece(id)
      if not done then return sold, grain, n end
      sold, grain = sold + 1, grain + n
    end
  end
  return sold, grain
end

function ns.RepairState()
  local p = bag()
  local left, broken, fixable = {}, 0, 0
  for _, piece in ipairs(storagePieces(p)) do
    if piece.broken then
      local row = GD.Row(piece.row)
      broken = broken + 1
      local cost = GC.RepairCost(row)
      if left[row.tier] == nil then left[row.tier] = ns.StackCount("salvage", row.tier) end
      if type(cost) == "number" and cost <= left[row.tier] then
        left[row.tier] = left[row.tier] - cost
        fixable = fixable + 1
      end
    end
  end
  return broken, fixable
end

-- Never spends grain: each piece by ns.Repair(id, "salvage"), a refused one is skipped.
function ns.RepairAll()
  if ns.Inert() then return nil, "demo" end
  local ids = {}
  for _, piece in ipairs(storagePieces(bag())) do
    if piece.broken then ids[#ids + 1] = piece.id end
  end
  local repaired = 0
  for _, id in ipairs(ids) do
    if ns.Repair(id, "salvage") then repaired = repaired + 1 end
  end
  return repaired, (ns.RepairState())
end

function ns.BreakDown(itemId)
  if ns.Inert() then return nil, "demo" end
  local p = bag()
  local piece, row = known(p, itemId)
  if not piece then return nil, "unknown" end
  if not piece.cell then return nil, "worn" end
  if row.q < 2 then return nil, "quality" end
  local n = GC.SalvageOf(row.q)
  p.rows[itemId] = nil -- first, so a full bag has the cell for the salvage
  local added, why = addStack(p, "salvage", row.tier, n)
  if not added then
    p.rows[itemId] = piece
    return nil, why
  end
  freed()
  return true, n
end

function ns.BreakGear(fid, slot)
  if ns.Inert() then return nil, "demo" end
  local f = ns.Follower(fid)
  if not f then return nil, "unknown" end
  local piece = wornPiece(bag(), f, slot)
  if not piece then return nil, "empty" end
  piece.broken = true
  return true
end

function ns.LoseGear(fid, slot)
  if ns.Inert() then return nil, "demo" end
  local f = ns.Follower(fid)
  if not f then return nil, "unknown" end
  local p = bag()
  local piece = wornPiece(p, f, slot)
  if not piece then return nil, "empty" end
  p.rows[piece.id] = nil
  f.gear[slot] = nil
  return true
end

local function hold(piece)
  if not ns.HoldNamed then return false end
  local ran, held = M.Safe(ns.HoldNamed, copy(piece))
  return ran and held == true
end

function ns.LeaveWorn(fid)
  if ns.Inert() then return nil, "demo" end
  local f = ns.Follower(fid)
  if not f then return nil, "unknown" end
  local p = bag()
  for _, piece in ipairs(wornPieces(p, f)) do
    local cell = freeCells(p.rows)[1]
    if cell then
      piece.cell = cell
    else
      local row = GD.Row(piece.row)
      local kept = hold(piece) or (row and addStack(p, "salvage", row.tier, GC.SalvageOf(row.q)))
      p.rows[piece.id] = nil
      if not kept then
        ns.Say(ns.W.Name["Company bag"] .. " is full: " .. (row and row.name or "An unknown item") .. " is lost.")
      end
    end
  end
  f.gear = {}
  return true
end
