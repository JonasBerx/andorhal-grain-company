-- GuildSyncExpeditions BoardCore.lua: ns.BoardCore, the pure board rules (0.19 plan, Seams 5). Loads after Regions.lua
-- and RiskCore.lua. Pure: string, table and math only, no globals, no game calls, no random.
--   BC.Day(t, untilReset) -> day | nil                 the server day, from the reset moment rounded to the minute
--   BC.Rows(day, regions, maps, personal) -> { { id, region, kind, hours, level, danger, capstone, gate, story }, ... }
--   BC.CanSend(level, kit, row) -> true | nil, "level" | "kit"
-- Per open region: shared -1..-3, easy -6 and -7 (own stream), the capstone; a held map adds -4 and -5.
-- So per open region at most 8 rows a day (5 shared, the capstone, 2 map rows), plus one personal row.

local _, ns = ...
if not ns.M then return end

local BC = {}
ns.BoardCore = BC

local RC = ns.RiskCore
local floor = math.floor

local DAY = 86400
local MAX_LEVEL = 10
local CAPSTONE_HOURS = 24
local GUARANTEED_LEVEL = 3
local KINDS = { "Raid", "Scout", "Rite" }

-- economy.md "The board". Weights are Safe/Risky/Dangerous/Deadly; a slot with no hours draws 1 or 2.
local SHARED = {
  tirisfal = {
    { lo = 1, hi = 5, weights = { 60, 40, 0, 0 } },
    { hours = 4, lo = 1, hi = 5, weights = { 30, 60, 10, 0 } },
    { hours = 8, lo = 5, hi = 7, weights = { 0, 30, 70, 0 } },
  },
  silverpine = {
    { lo = 6, hi = 9, weights = { 50, 40, 10, 0 } },
    { hours = 4, lo = 6, hi = 9, weights = { 20, 40, 30, 10 } },
    { hours = 8, lo = 6, hi = 9, weights = { 20, 40, 30, 10 } },
  },
}
-- Rows -6 and -7: fixed hours, levels a zone's newest follower may always go on.
local EASY = {
  tirisfal = { lo = 1, hi = 3, weights = { 60, 40, 0, 0 } },
  silverpine = { lo = 6, hi = 8, weights = { 50, 40, 10, 0 } },
}
local EASY_HOURS = { 1, 2 }
local SILVERPINE_GUARANTEE = 8
local MAP_HOURS = { 4, 8 }
local MAP_WEIGHTS = { 0, 30, 45, 25 }
local CAPSTONE_GATE = { tirisfal = { level = 8, kit = 24 }, silverpine = { level = 10, kit = 30 } }

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == floor(v)
end

local function draw(stream, n)
  return floor(stream() * n) + 1
end

local function dangerFrom(stream, weights)
  local d, sum = draw(stream, 100), 0
  for danger, weight in ipairs(weights) do
    sum = sum + weight
    if d <= sum then return danger end
  end
end

-- Draws level, danger and kind, in that order.
local function newRow(stream, id, region, hours, lo, hi, weights)
  local level = lo + draw(stream, hi - lo + 1) - 1
  local danger = dangerFrom(stream, weights)
  local kind = KINDS[draw(stream, #KINDS)]
  return { id = id, region = region, kind = kind, hours = hours, level = level, danger = danger }
end

-- The guarantee draws come after all three slots, so they never shift another row.
local function addShared(out, region, day)
  local stream = RC.Stream(RC.Seed(region, day, 0))
  local rows = {}
  for n, slot in ipairs(SHARED[region]) do
    local hours = slot.hours or draw(stream, 2)
    rows[n] = newRow(stream, region .. "-" .. day .. "-" .. n, region, hours, slot.lo, slot.hi, slot.weights)
    out[#out + 1] = rows[n]
  end
  if region == "tirisfal" and rows[1].level > GUARANTEED_LEVEL and rows[2].level > GUARANTEED_LEVEL then
    rows[1].level = draw(stream, GUARANTEED_LEVEL)
  end
  if region == "silverpine" and rows[1].level > SILVERPINE_GUARANTEE and rows[2].level > SILVERPINE_GUARANTEE
    and rows[3].level > SILVERPINE_GUARANTEE then
    local lo = SHARED.silverpine[1].lo
    rows[1].level = lo - 1 + draw(stream, SILVERPINE_GUARANTEE - lo + 1) -- slot 1's lowest up to the guarantee, the stream's last draw
  end
end

-- Their own stream, so the easy rows never shift the shared ones.
local function addEasy(out, region, day)
  local stream = RC.Stream(RC.Seed(region .. ":easy", day, 0))
  local band = EASY[region]
  if not band then return end
  for i, hours in ipairs(EASY_HOURS) do
    out[#out + 1] = newRow(stream, region .. "-" .. day .. "-" .. (5 + i), region, hours, band.lo, band.hi, band.weights)
  end
end

-- A new table each call: a row is the caller's to mark.
local function addCapstone(out, region)
  local gate = CAPSTONE_GATE[region]
  out[#out + 1] = {
    id = region .. "-capstone", region = region, kind = "Raid", hours = CAPSTONE_HOURS, level = gate.level, danger = 4,
    capstone = true, gate = { level = gate.level, kit = gate.kit },
  }
end

-- Their own stream, so holding a map never changes the shared or easy rows.
local function addMapRows(out, info, day)
  local stream = RC.Stream(RC.Seed(info.id .. ":map", day, 0))
  for i, hours in ipairs(MAP_HOURS) do
    out[#out + 1] = newRow(stream, info.id .. "-" .. day .. "-" .. (3 + i), info.id, hours, info.lo, info.hi, MAP_WEIGHTS)
  end
end

local function setOf(list)
  local set = {}
  for _, v in ipairs(list or {}) do set[v] = true end
  return set
end

local function personalFits(row)
  return type(row) == "table" and whole(row.level, 1, MAX_LEVEL) and whole(row.danger, 1, 4)
    and ns.Regions.IsOpen(row.region)
end

function BC.Day(t, untilReset)
  if type(t) ~= "number" or type(untilReset) ~= "number" then return nil end
  if untilReset < 0 or untilReset > DAY then return nil end
  return floor(floor((t + untilReset) / 60 + 0.5) * 60 / DAY)
end

-- Per region in map order, whatever order the lists come in: shared 1-3, easy 6-7, the capstone; then map rows (4-5); personal last.
function BC.Rows(day, regions, maps, personal)
  local wanted, held = setOf(regions), setOf(maps)
  local out = {}
  for _, info in ipairs(ns.Regions.LIST) do
    if info.open and wanted[info.id] then
      addShared(out, info.id, day)
      addEasy(out, info.id, day)
      addCapstone(out, info.id)
    end
  end
  for _, info in ipairs(ns.Regions.LIST) do
    if info.open and wanted[info.id] and held[info.id] then addMapRows(out, info, day) end
  end
  for _, row in ipairs(personal or {}) do
    if personalFits(row) then
      local copy = {} -- the caller marks its rows; S's table stays unmarked
      for k, v in pairs(row) do copy[k] = v end
      out[#out + 1] = copy
      break
    end
  end
  return out
end

function BC.CanSend(level, kit, row)
  if level < row.level - 2 then return nil, "level" end
  local gate = row.gate
  if gate and level < gate.level then return nil, "level" end
  if gate and kit < gate.kit then return nil, "kit" end
  return true
end
