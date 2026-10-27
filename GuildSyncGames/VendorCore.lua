-- GuildSyncGames VendorCore.lua (S12 Task 2): the pure Vendor price core, ns.VendorCore (the daily pairs, the seeded
-- draw, pay, coins, the share text, the record body).
-- Pure: string, table and math only, no globals, no date or time, no math.random. Its own constants, never ns.Core
-- (f7262). Every division is by a literal or an UPPER_CASE constant; price ratios are cross-multiplied.
-- Frozen after #1: the sorted index, VC.Seed, VC.Draw and VC.Daily (any change moves every later day).

local _, ns = ...

local VC = {}
ns.VendorCore = VC

local PM = 2147483647 -- Park-Miller modulus
local INV_M = 1 / 2147483647
local SEED_MOD = 2147483646
local OFFSET = 4194304 -- 2^22: keeps r non-negative for the preview days
local TRIES = 64
local RUN = 10
local MAX_SAY = 255 -- a chat line, the "/g " prefix included
local MAX_BODY = 80
local BEST_MAX = 999
local STREAK_MAX = 9999
local FIRST_DAY = -13
local PREVIEW_DAYS = 14

VC.SEED = 20261024

-- Item quality 0-4: colour (hex) and word. A local table, never ITEM_QUALITY_COLORS.
VC.QUALITY = {
  [0] = { colour = "9d9d9d", word = "Poor" },
  [1] = { colour = "ffffff", word = "Common" },
  [2] = { colour = "1eff00", word = "Uncommon" },
  [3] = { colour = "0070dd", word = "Rare" },
  [4] = { colour = "a335ee", word = "Epic" },
}

-- ---------- the items ----------

local items, index -- the parsed list, and its indexes sorted by (price, then id): a total order

function VC.Items()
  if items then return items end
  items, index = {}, {}
  for _, row in ipairs(ns.ITEMS or {}) do
    local id, price, quality, icon, name = row:match("^(%d+):(%d+):(%d+):(%d+):(.*)$")
    if id then
      items[#items + 1] = { id = tonumber(id), price = tonumber(price), quality = tonumber(quality),
        icon = tonumber(icon), name = name }
      index[#index + 1] = #items
    end
  end
  table.sort(index, function(x, y)
    local a, b = items[x], items[y]
    if a.price ~= b.price then return a.price < b.price end
    return a.id < b.id
  end)
  return items
end

-- ---------- the seed and the stream ----------

-- Day n's seed: quadratic in n (a product, never ^), so the days do not walk a straight line.
function VC.Seed(n)
  local r = n + OFFSET
  local q = r * 8 + 5
  return (q * q + VC.SEED) % SEED_MOD + 1
end

-- Park-Miller; a seed outside [1, PM - 1] is refused (0 sticks at 0).
function VC.Stream(seed)
  if type(seed) ~= "number" or seed ~= math.floor(seed) or seed < 1 or seed > PM - 1 then return nil end
  local x = seed
  return function()
    x = 16807 * x % PM
    return x * INV_M
  end
end

-- ---------- the bands ----------

-- Picks 1-3 at least 3x; 4-7 1.5x to under 3x; 8 and up 1.05x to under 1.5x (f7258). lo < hi, cross-multiplied.
local function band(k)
  if k <= 3 then return 1 elseif k <= 7 then return 2 end
  return 3
end

local function atLeast(b, lo, hi)
  if b == 1 then return hi >= 3 * lo elseif b == 2 then return 2 * hi >= 3 * lo end
  return 100 * hi >= 105 * lo
end

local function under(b, lo, hi)
  if b == 1 then return true elseif b == 2 then return hi < 3 * lo end
  return 2 * hi < 3 * lo
end

-- The first index position whose price makes pred true (pred goes false then true along the index); #index + 1 if none.
local function first(pred)
  local lo, hi = 1, #index + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if pred(items[index[mid]].price) then hi = mid else lo = mid + 1 end
  end
  return lo
end

-- A's partners in band b: the range below A, then the range above A, in index order.
local function partners(b, p)
  local l1 = first(function(q) return under(b, q, p) end)
  local r1 = first(function(q) return not atLeast(b, q, p) end) - 1
  local l2 = first(function(q) return atLeast(b, p, q) end)
  local r2 = first(function(q) return not under(b, p, q) end) - 1
  local c1 = r1 >= l1 and r1 - l1 + 1 or 0
  local c2 = r2 >= l2 and r2 - l2 + 1 or 0
  return l1, c1, l2, c2
end

-- ---------- the draw ----------

-- One exact rule (f7250): each try takes three next() calls; A from the index, B from A's partners, then the side.
-- Each step-up walk stops after one lap (n2). At most 64 tries, else nil. Answers item indexes, a on the left.
function VC.Draw(next, used, k)
  VC.Items()
  local N = #index
  local b = band(k)
  for _ = 1, TRIES do
    local v1, v2, v3 = next(), next(), next()
    local A
    local pos = math.floor(v1 * N) + 1
    for _ = 1, N do
      if not used[index[pos]] then A = index[pos] break end
      pos = pos < N and pos + 1 or 1
    end
    if A then
      local l1, c1, l2, c2 = partners(b, items[A].price)
      local C = c1 + c2
      local B
      if C > 0 then
        local m = math.floor(v2 * C) + 1
        for _ = 1, C do
          local at = m <= c1 and l1 + m - 1 or l2 + m - c1 - 1
          if not used[index[at]] then B = index[at] break end
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

-- Day n's ten pairs from one stream, no item twice; nil when any draw fails (never a short run, f7259).
function VC.Daily(n)
  if daily[n] ~= nil then return daily[n] or nil end
  local nxt, used, run = VC.Stream(VC.Seed(n)), {}, {}
  for k = 1, RUN do
    local a, b = VC.Draw(nxt, used, k)
    if not a then
      daily[n] = false
      return nil
    end
    used[a], used[b] = true, true
    run[k] = { a = a, b = b }
  end
  daily[n] = run
  return run
end

-- ---------- pay and coins ----------

-- The count of "1" marks (nil counts as none); VendorStore.lua, Vendor.lua and Demo.lua share it.
local function rights(marks)
  local _, c = (marks or ""):gsub("1", "")
  return c
end
VC.Rights = rights

-- 5 grain per right, 25 more at ten right.
function VC.Pay(marks)
  local c = rights(marks)
  return c * 5 + (c == RUN and 25 or 0)
end

function VC.Coins(copper)
  return math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
end

-- ---------- sharing ----------

local ICON = { ["1"] = "{rt4}", ["0"] = "{rt5}" }
local PLAIN = { ["1"] = "G", ["0"] = "." }

local function shareLine(label, marks, map)
  return "Vendor price " .. label .. " " .. rights(marks) .. "/10 " .. (marks:gsub(".", map))
end

-- The marks as one chat line; icons fall back to plain when the line with its prefix would pass 255 bytes.
function VC.ShareText(label, marks, icons, prefixLen)
  if icons then
    local text = shareLine(label, marks, ICON)
    if #text + (prefixLen or 0) <= MAX_SAY then return text end
  end
  return shareLine(label, marks, PLAIN)
end

-- ---------- the wire ----------

function VC.PackBody(r)
  local marks = r.marks or ""
  return r.n .. "^" .. rights(marks) .. "^" .. marks .. "^" .. r.best .. "^" .. r.streak
end

function VC.ParseBody(body, today)
  if type(body) ~= "string" or type(today) ~= "number" or #body > MAX_BODY then return nil, "not a body" end
  local n, score, marks, best, streak = body:match("^(%-?%d+)%^(%d+)%^([01]*)%^(%d+)%^(%d+)$")
  if not n or #n > 6 then return nil, "not a body" end
  n, score, best, streak = tonumber(n), tonumber(score), tonumber(best), tonumber(streak)
  if n < FIRST_DAY or n > today + 1 or (today >= 1 and n < 1) then return nil, "day" end
  if #marks ~= RUN and not (#marks == 0 and score == 0 and streak == 0) then return nil, "marks" end
  if score > RUN or score ~= rights(marks) then return nil, "score" end
  if best > BEST_MAX then return nil, "best" end
  if streak > STREAK_MAX or (n >= 1 and streak > n) or (n < 1 and streak > n + PREVIEW_DAYS) then
    return nil, "streak"
  end
  return { n = n, score = score, marks = marks, best = best, streak = streak }
end
