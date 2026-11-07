-- GuildSyncGames StablesCore.lua (run r-20261107-games-more-to-buy-with-grain-escort-bone, Task 2): the pure Kodo
-- stables core, ns.StablesCore (prices from the races, fees, trades, dividends). Loads after CompanyCore.lua.
-- Pure: string, table and math only, no globals, no clock: hours come in as arguments. Integer math; every division
-- is by a literal or an UPPER_CASE local.
--
-- Price model B: per kodo v starts 1000 at hour h - WINDOW; for each hour x in [h - WINDOW, h - 1] a kodo that ran in
-- GC.Race(x) takes v = floor(v * MOVE[place] / 1000), then every kodo is pulled 2% back toward 1000, then v is clamped
-- to [400, 2500]. The price for all of hour h is floor((v + 5) / 10), so 40..250 and the same for everyone.
--
-- API:
--   SC.SHARES_MAX, SC.FEE_PCT, SC.DIV, SC.WINDOW, SC.LOCK, SC.CATCHUP, SC.PRICE_MIN, SC.PRICE_MAX
--   SC.Prices(h) -> { [k] = price }   (k = GC.ROSTER index; a fresh copy each call)
--   SC.Fee(value) -> n                (ceil(value * FEE_PCT / 100))
--   SC.BuyCost(shares, price) -> cost, fee;  SC.SaleValue(shares, price) -> got, fee
--   SC.Exchange(shares, priceFrom, priceTo) -> newShares, rest, fee   (one fee, on the value sold)
--   SC.Winner(h) -> k;  SC.Dividend(k, shares, fromHour, toHour) -> pay
-- Races are read only as GC.Race(x) through the table at call time; the memo is emptied when GC.Race is another
-- function.

local _, ns = ...

local GC = ns.GrainCore
local SC = {}
ns.StablesCore = SC

local SHARES_MAX = 20
local FEE_PCT = 10
local WINDOW = 168
local MOVE = { 1080, 1030, 1005, 990, 975, 960 }
local V_START, V_MIN, V_MAX = 1000, 400, 2500

SC.SHARES_MAX = SHARES_MAX
SC.FEE_PCT = FEE_PCT
SC.DIV = 1
SC.WINDOW = WINDOW
SC.LOCK = 86400
SC.CATCHUP = 168
SC.PRICE_MIN = 40
SC.PRICE_MAX = 250

local index = {}
for k, r in ipairs(GC.ROSTER) do index[r.name] = k end
local KODOS = #GC.ROSTER

-- memo[x] = { places = { [k] = place }, winner = k }, filled from memoFn; last = { hour, prices } of the last answer
local memo, count, memoFn, last = {}, 0, nil, nil

local function fresh()
  if GC.Race ~= memoFn then
    memo, count, memoFn, last = {}, 0, GC.Race, nil
  end
end

local function trim(h)
  if count <= 3 * WINDOW then return end
  for x in pairs(memo) do
    if x < h - 2 * WINDOW or x > h then
      memo[x] = nil
      count = count - 1
    end
  end
end

local function raceOf(x)
  local m = memo[x]
  if m then return m end
  local race = GC.Race(x)
  local places = {}
  for i, lane in ipairs(race.order) do places[index[race.field[lane].name]] = i end
  m = { places = places, winner = index[race.field[race.winner].name] }
  memo[x] = m
  count = count + 1
  return m
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function SC.Prices(h)
  fresh()
  if last and last.hour == h then return copy(last.prices) end
  local v = {}
  for k = 1, KODOS do v[k] = V_START end
  for x = h - WINDOW, h - 1 do
    local places = raceOf(x).places
    for k = 1, KODOS do
      local p = places[k]
      if p then v[k] = math.floor(v[k] * MOVE[p] / 1000) end
      v[k] = v[k] + math.floor((V_START - v[k]) * 2 / 100)
      if v[k] < V_MIN then v[k] = V_MIN elseif v[k] > V_MAX then v[k] = V_MAX end
    end
  end
  local prices = {}
  for k = 1, KODOS do prices[k] = math.floor((v[k] + 5) / 10) end
  trim(h)
  last = { hour = h, prices = prices }
  return copy(prices)
end

function SC.Fee(value)
  return math.floor((value * FEE_PCT + 99) / 100)
end

function SC.BuyCost(shares, price)
  local value = shares * price
  local fee = SC.Fee(value)
  return value + fee, fee
end

function SC.SaleValue(shares, price)
  local value = shares * price
  local fee = SC.Fee(value)
  return value - fee, fee
end

-- Shares counted up, no division by a price.
function SC.Exchange(shares, priceFrom, priceTo)
  local net, fee = SC.SaleValue(shares, priceFrom)
  local m = 0
  while m < SHARES_MAX and (m + 1) * priceTo <= net do m = m + 1 end
  return m, net - m * priceTo, fee
end

function SC.Winner(h)
  fresh()
  local w = raceOf(h).winner
  trim(h)
  return w
end

function SC.Dividend(k, shares, fromHour, toHour)
  fresh()
  local wins = 0
  for x = fromHour, toHour do
    if raceOf(x).winner == k then wins = wins + 1 end
  end
  trim(toHour)
  return wins * shares * SC.DIV
end
