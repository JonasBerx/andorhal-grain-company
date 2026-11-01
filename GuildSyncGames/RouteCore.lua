-- GuildSyncGames RouteCore.lua (S21 Task 2): the pure Flights core, ns.RouteCore (the routes and nodes, the daily
-- pairs, the seeded draw, the judge, the flight time display).
-- Pure: string, table and math only, no globals, no date or time, no math.random. The stream is ns.VendorCore.Stream,
-- read at call time (VendorCore.lua loads first). Every division is by a literal or an UPPER_CASE constant; the bands
-- are cross-multiplied.
-- Frozen after #1: the sorted indexes, RC.SEED, RC.Seed, RC.Question, RC.Draw, RC.Daily (any change moves every later
-- day).

local _, ns = ...

local RC = {}
ns.RouteCore = RC

local SEED_MOD = 2147483646
local OFFSET = 4194304 -- 2^22: keeps r non-negative for the preview days
local TRIES = 64
local RUN = 10
local SPEED = 30.38 -- yards a second

RC.SEED = 20261025
RC.SPEED = SPEED

local QUESTIONS = { "time", "cost", "stops" }
local FIELD = { time = "yards", cost = "copper", stops = "stops" }

-- ---------- the routes and nodes ----------

local routes, nodes, index -- the parsed rows (shipped order), the nodes by id, one sorted index per question

function RC.Routes()
  if routes then return routes end
  routes, index = {}, {}
  for _, row in ipairs(ns.ROUTES or {}) do
    local f, t, y, c, s = row:match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if f then
      routes[#routes + 1] = { from = tonumber(f), to = tonumber(t), yards = tonumber(y), copper = tonumber(c),
        stops = tonumber(s) }
    end
  end
  -- by (value, then from, then to): a total order
  for q, field in pairs(FIELD) do
    local list = {}
    for i = 1, #routes do list[i] = i end
    table.sort(list, function(x, y)
      local a, b = routes[x], routes[y]
      if a[field] ~= b[field] then return a[field] < b[field] end
      if a.from ~= b.from then return a.from < b.from end
      return a.to < b.to
    end)
    index[q] = list
  end
  return routes
end

function RC.Node(id)
  if not nodes then
    nodes = {}
    for _, row in ipairs(ns.ROUTE_NODES or {}) do
      local nid, name = row:match("^(%d+):(.*)$")
      if nid then
        local place, zone = name:match("^(.-), (.*)$")
        nodes[tonumber(nid)] = { place = place or name, zone = zone or "" }
      end
    end
  end
  return nodes[id]
end

-- ---------- the seed and the question ----------

-- Day n's seed: VendorCore's formula with its own constant (a product, never ^).
function RC.Seed(n)
  local r = n + OFFSET
  local q = r * 8 + 5
  return (q * q + RC.SEED) % SEED_MOD + 1
end

-- A fixed rotation: each day asks each question 3 or 4 times (o2164).
function RC.Question(n, k)
  return QUESTIONS[(n + k) % 3 + 1]
end

-- ---------- the bands (o2174) ----------

-- Picks 1-3, 4-7, 8 and up. lo < hi; time by yards 2x / 1.3x / 1.1x, cost by copper 3x / 1.75x / 1.25x, stops by
-- difference >= 2 / >= 1 / = 1.
local function band(k)
  if k <= 3 then return 1 elseif k <= 7 then return 2 end
  return 3
end

local function atLeast(q, b, lo, hi)
  if q == "time" then
    if b == 1 then return hi >= 2 * lo elseif b == 2 then return 10 * hi >= 13 * lo end
    return 10 * hi >= 11 * lo
  elseif q == "cost" then
    if b == 1 then return hi >= 3 * lo elseif b == 2 then return 4 * hi >= 7 * lo end
    return 4 * hi >= 5 * lo
  end
  if b == 1 then return hi - lo >= 2 end
  return hi - lo >= 1
end

local function under(q, b, lo, hi)
  if b == 1 then return true end
  if q == "time" then
    if b == 2 then return hi < 2 * lo end
    return 10 * hi < 13 * lo
  elseif q == "cost" then
    if b == 2 then return hi < 3 * lo end
    return 4 * hi < 7 * lo
  end
  if b == 2 then return true end
  return hi - lo < 2
end

-- The first position in q's index whose value makes pred true (false then true along the index); #list + 1 if none.
local function first(list, field, pred)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if pred(routes[list[mid]][field]) then hi = mid else lo = mid + 1 end
  end
  return lo
end

-- A's partners in band b for question q: the range below A, then the range above A, in index order.
local function partners(list, field, q, b, p)
  local l1 = first(list, field, function(v) return under(q, b, v, p) end)
  local r1 = first(list, field, function(v) return not atLeast(q, b, v, p) end) - 1
  local l2 = first(list, field, function(v) return atLeast(q, b, p, v) end)
  local r2 = first(list, field, function(v) return not under(q, b, p, v) end) - 1
  local c1 = r1 >= l1 and r1 - l1 + 1 or 0
  local c2 = r2 >= l2 and r2 - l2 + 1 or 0
  return l1, c1, l2, c2
end

-- ---------- the draw ----------

-- As VC.Draw: each try takes three next() calls; A from q's index, B from A's partners (never A's reverse), then the
-- side. Each step-up walk stops after one lap. At most 64 tries, else nil. Answers route indexes, a on the left.
function RC.Draw(next, used, k, q)
  RC.Routes()
  local list, field = index[q], FIELD[q]
  if not list then return nil end
  local N = #list
  if N == 0 then return nil end
  local b = band(k)
  for _ = 1, TRIES do
    local v1, v2, v3 = next(), next(), next()
    local A
    local pos = math.floor(v1 * N) + 1
    for _ = 1, N do
      if not used[list[pos]] then A = list[pos] break end
      pos = pos < N and pos + 1 or 1
    end
    if A then
      local ra = routes[A]
      local l1, c1, l2, c2 = partners(list, field, q, b, ra[field])
      local C = c1 + c2
      local B
      if C > 0 then
        local m = math.floor(v2 * C) + 1
        for _ = 1, C do
          local at = list[m <= c1 and l1 + m - 1 or l2 + m - c1 - 1]
          local rb = routes[at]
          if not used[at] and not (rb.from == ra.to and rb.to == ra.from) then B = at break end
          m = m < C and m + 1 or 1
        end
      end
      if B then
        if v3 < 0.5 then return A, B end
        return B, A
      end
    end
  end
  return nil
end

local daily = {}

-- Day n's ten pairs from one stream, no route twice; nil when any draw fails (never a short run).
function RC.Daily(n)
  if daily[n] ~= nil then return daily[n] or nil end
  local nxt, used, run = ns.VendorCore.Stream(RC.Seed(n)), {}, {}
  for k = 1, RUN do
    local q = RC.Question(n, k)
    local a, b = RC.Draw(nxt, used, k, q)
    if not a then
      daily[n] = false
      return nil
    end
    used[a], used[b] = true, true
    run[k] = { a = a, b = b, q = q }
  end
  daily[n] = run
  return run
end

-- ---------- the judge and the display ----------

-- Right when the picked route (k = 1 a, k = 2 b) has the larger value for the pair's question.
function RC.Right(pair, k)
  local field = FIELD[pair.q]
  local mine, other = pair.a, pair.b
  if k == 2 then mine, other = pair.b, pair.a end
  return mine[field] > other[field]
end

function RC.Seconds(yards)
  return math.floor(yards / SPEED + 0.5)
end

function RC.Clock(yards)
  local s = RC.Seconds(yards)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
