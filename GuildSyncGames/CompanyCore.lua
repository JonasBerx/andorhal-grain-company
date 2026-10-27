-- GuildSyncGames CompanyCore.lua (S13 Task 1): the pure Company core, ns.CompanyCore (the store catalogue, the six
-- projects, the realm offset, the lottery week, ticket numbers, the target and the draw, the caravan outcome, the
-- games_c record body).
-- Pure: string, table and math only, no globals, no date or time, no math.random. Its own constants and its own
-- Park-Miller, never ns.Core (f7262). Every division is by a literal or an UPPER_CASE constant.
-- Frozen: item ids, CC.Number, CC.Target and CC.Draw (any change moves every later draw), the body format.
-- S14 changed the draw on purpose: CC.Target takes the officer's salt, tickets are numbered by the row's record key
-- (CC.Number's formula is the S13 one), and CC.Draw runs over { key, b } rows (d1600, d1606). The row adds an officer
-- part after the body (CC.PackRow, CC.ParseRow); the body format is unchanged.
--
-- API:
--   CC.ITEMS (array in id order), CC.COLOURS[n] = { hex }, CC.PROJECTS[k] = { name, goal, badge = icon, badgeName }
--   CC.TRIPS, CC.STAKES, CC.GIVES, CC.TICKET_PRICE, CC.TICKETS_MAX, CC.SETTLE_AFTER, CC.FIRST_WEEK
--   CC.WIRE_BASE = { title, colour, badge }: wire place n of a kind = local id - base; CC.PROJECT_BADGE_BASE (22):
--     earned project badge k has local id 22 + k and wire badge 4 + k
--   CC.Item(id) -> { id, kind, name, price, icon?, hex?, slot? } | nil
--   CC.Offset(gh, gm, t) -> -12..11;  CC.Week(t, off) -> week, closeAt, drawAt, settleAt, open
--   CC.Number(week, key, i) -> 0..99999;  CC.Target(week, total, salt) -> 0..99999
--   CC.Totals(rows) -> { x6 };  CC.Projects(totals) -> { current = k | nil, done = { x6 }, goals = { x6 } }
--   CC.Draw(week, rows, salt) -> { key, i, number, target, total, pot, salt } | nil   (rows = { { key, b }, ... })
--   CC.TicketsFor(b, week) -> the body's ticket count for week (its current or its previous week), 0 for none
--   CC.CaravanSeed(key, start, salt) -> 1..PM-1;  CC.Outcome(hours, stake, seed) -> back, kind | nil
--   CC.PackBody(b) -> string;  CC.ParseBody(body, weekNow) -> b | nil, why
--   CC.PackRow(b, off) -> string;  CC.ParseRow(row, weekNow) -> b, off | nil, why
--     row = body *( "!" item ); item = "d" week "." salt "." target "." total "." i "." key | "d" week ".0"
--       | "h" at "." key | "u" at "." key; off = { draw = d | nil, hides = { [key] = { on, at } } }
--   CC.ResolveHides(list, now) -> { [key] = { on, at, by } };  CC.ResolveDraw(list) -> d | nil
--   CC.HIDE_MAX, CC.TOTAL_CAP, CC.RICH_PCT[hours]

local _, ns = ...

local CC = {}
ns.CompanyCore = CC

local PM = 2147483647 -- Park-Miller modulus
local SEED_MOD = 2147483646
local PM_MULT = 16807
local NUM_MOD = 100000
local HALF_NUM = 50000
local TARGET_STEPS = 97
local SLOTS = 20
local MINUTE = 60
local HOUR = 3600
local DAY = 86400
local WEEK = 604800
local SUN0 = 1793491200 -- Sun 1 Nov 2026 00:00 UTC
local DRAW_HOUR = 20
local MAX_BODY = 80
local FIRST_WEEK = -8
local KEY_MAX = 64
local AT_DIGITS = 10
local FUTURE = 300 -- a hide entry stamped more than this past now is ignored

CC.TICKET_PRICE = 10
CC.TICKETS_MAX = 10
CC.SETTLE_AFTER = 7200
CC.FIRST_WEEK = FIRST_WEEK
CC.GIVES = { 10, 100, 1000 }
CC.TRIPS = { 1, 2, 4, 8 }
CC.STAKES = { 50, 100, 250, 500 }
CC.WIRE_BASE = { title = 0, colour = 6, badge = 12 }
CC.PROJECT_BADGE_BASE = 22
CC.HIDE_MAX = 20                                  -- o1769; the worst-case row splits into 13 chunks
CC.TOTAL_CAP = CC.TICKETS_MAX * (1000 + 50)       -- 10500, the fixed draw-total cap (d1608)

-- ---------- the catalogue (economy.md; ids frozen) ----------

CC.ITEMS = {
  { id = 1, kind = "title", name = "Farmhand", price = 250 },
  { id = 2, kind = "title", name = "Grain Runner", price = 600 },
  { id = 3, kind = "title", name = "Kodo Wrangler", price = 1000 },
  { id = 4, kind = "title", name = "Mill Warden", price = 1800 },
  { id = 5, kind = "title", name = "Andorhal Factor", price = 3000 },
  { id = 6, kind = "title", name = "Grain Baron", price = 5000 },
  { id = 7, kind = "colour", name = "Wheat", price = 300, hex = "f5deb3" },
  { id = 8, kind = "colour", name = "Plague green", price = 500, hex = "8fd14f" },
  { id = 9, kind = "colour", name = "Brass", price = 800, hex = "d4a24c" },
  { id = 10, kind = "colour", name = "Ember", price = 800, hex = "ff8040" },
  { id = 11, kind = "colour", name = "Forsaken violet", price = 1200, hex = "a07ae0" },
  { id = 12, kind = "colour", name = "Bone white", price = 1200, hex = "ece6d6" },
  { id = 13, kind = "badge", name = "Sickle", price = 400, icon = "interface\\icons\\inv_misc_herb_01" },
  { id = 14, kind = "badge", name = "Kodo", price = 600, icon = "interface\\icons\\ability_mount_kodo_01" },
  { id = 15, kind = "badge", name = "Copper coin", price = 900, icon = "interface\\icons\\inv_misc_coin_05" },
  { id = 16, kind = "badge", name = "Lantern", price = 1500, icon = "interface\\icons\\inv_misc_lantern_01" },
  { id = 17, kind = "decor", name = "Scarecrow", price = 200, slot = 1,
    icon = "interface\\icons\\inv_fabric_moonrag_01" },
  { id = 18, kind = "decor", name = "Hay bales", price = 250, slot = 2, icon = "interface\\icons\\inv_misc_bag_10" },
  { id = 19, kind = "decor", name = "Grain cart", price = 500, slot = 3, icon = "interface\\icons\\inv_misc_gear_01" },
  { id = 20, kind = "decor", name = "Windmill", price = 900, slot = 4,
    icon = "interface\\icons\\trade_blacksmithing" },
  { id = 21, kind = "decor", name = "Plague cauldron", price = 1200, slot = 5, icon = "interface\\icons\\inv_potion_51" },
  { id = 22, kind = "decor", name = "Company banner", price = 1800, slot = 6,
    icon = "interface\\icons\\inv_bannerpvp_02" },
}

CC.COLOURS = {}
for n = 1, 6 do CC.COLOURS[n] = { hex = CC.ITEMS[CC.WIRE_BASE.colour + n].hex } end

function CC.Item(id)
  if type(id) ~= "number" then return nil end
  return CC.ITEMS[id]
end

-- ---------- the projects ----------

CC.PROJECTS = {
  { name = "Rebuild Andorhal's mill", goal = 10000, badge = "interface\\icons\\inv_misc_food_wheat_01", badgeName = "Mill" },
  { name = "Mend the granary roof", goal = 25000, badge = "interface\\icons\\inv_misc_stonetablet_05", badgeName = "Roof" },
  { name = "Restock the seed store", goal = 50000, badge = "interface\\icons\\inv_misc_bag_07", badgeName = "Seed sack" },
  { name = "Raise the watchtower", goal = 75000, badge = "interface\\icons\\inv_misc_spyglass_03", badgeName = "Watchtower" },
  { name = "Dig the irrigation ditch", goal = 100000, badge = "interface\\icons\\inv_misc_shovel_01", badgeName = "Spade" },
  { name = "Raise the Company hall", goal = 150000, badge = "interface\\icons\\inv_bannerpvp_01", badgeName = "Company hall" },
}

function CC.Totals(rows)
  local t = { 0, 0, 0, 0, 0, 0 }
  for _, r in ipairs(rows or {}) do
    local g = r.b and r.b.gifts
    if g then
      for k = 1, 6 do t[k] = t[k] + (g[k] or 0) end
    end
  end
  return t
end

function CC.Projects(totals)
  local out = { done = {}, goals = {} }
  for k = 1, 6 do
    local goal = CC.PROJECTS[k].goal
    out.goals[k] = goal
    out.done[k] = (totals[k] or 0) >= goal
    if not out.done[k] and not out.current then out.current = k end
  end
  return out
end

-- ---------- the clock ----------

-- Realm minus UTC in whole hours, folded into -12..11 (d1583).
function CC.Offset(gh, gm, t)
  local utcMin = math.floor((t % DAY) / MINUTE)
  local raw = math.floor((gh * MINUTE + gm - utcMin) / MINUTE + 0.5)
  return ((raw + 12) % 24) - 12
end

-- Week W runs (drawAt(W - 1), drawAt(W)]; drawAt(W) = SUN0 + W x WEEK + 20 h - off h.
function CC.Week(t, off)
  local base = SUN0 + DRAW_HOUR * HOUR - off * HOUR
  local w = math.ceil((t - base) / WEEK)
  local drawAt = base + w * WEEK
  local closeAt = drawAt - HOUR
  return w, closeAt, drawAt, drawAt + CC.SETTLE_AFTER, t < closeAt
end

-- ---------- numbers and the draw ----------

local function hash(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % PM end
  return h
end

local function stream(s, steps)
  local x = hash(s) % SEED_MOD + 1
  for _ = 1, steps do x = x * PM_MULT % PM end
  return x
end

function CC.Number(week, key, i)
  return stream(week .. "^N^" .. key, i) % NUM_MOD
end

function CC.Target(week, total, salt)
  return stream(week .. "^T^" .. total .. "^" .. salt, 3 + total % TARGET_STEPS) % NUM_MOD
end

local function countFor(b, week)
  if not b then return 0 end
  if (b.count or 0) > 0 and b.week == week then return b.count end
  if (b.prevCount or 0) > 0 and b.prevWeek == week then return b.prevCount end
  return 0
end
CC.TicketsFor = countFor

function CC.Draw(week, rows, salt)
  local total = 0
  for _, r in ipairs(rows or {}) do total = total + countFor(r.b, week) end
  if total == 0 then return nil end
  local target = CC.Target(week, total, salt)
  local best
  for _, r in ipairs(rows) do
    for i = 1, countFor(r.b, week) do
      local n = CC.Number(week, r.key, i)
      local d = math.abs(n - target)
      if d > HALF_NUM then d = NUM_MOD - d end
      if not best or d < best.d or (d == best.d and (r.key < best.key or (r.key == best.key and i < best.i))) then
        best = { d = d, key = r.key, i = i, number = n }
      end
    end
  end
  return { key = best.key, i = best.i, number = best.number, target = target, total = total,
    pot = total * CC.TICKET_PRICE, salt = salt }
end

-- ---------- the caravan ----------

local PCT = {
  [1] = { bandits = 80, fair = 105, rich = 120 }, [2] = { bandits = 70, fair = 110, rich = 140 },
  [4] = { bandits = 50, fair = 115, rich = 170 }, [8] = { bandits = 25, fair = 130, rich = 230 },
}
CC.RICH_PCT = {}
for h, p in pairs(PCT) do CC.RICH_PCT[h] = p.rich end
local STAKE_OK = {}
for _, s in ipairs(CC.STAKES) do STAKE_OK[s] = true end

function CC.CaravanSeed(key, start, salt)
  return hash(tostring(key) .. "^" .. tostring(start) .. "^" .. tostring(salt)) % SEED_MOD + 1
end

-- Slots 1-5 bandits, 6-13 fair road, 14-20 rich road (5 / 8 / 7 of 20).
function CC.Outcome(hours, stake, seed)
  local pct = type(hours) == "number" and PCT[hours]
  if not pct or not STAKE_OK[stake] then return nil end
  if type(seed) ~= "number" or seed ~= math.floor(seed) or seed < 1 or seed > SEED_MOD then return nil end
  local slot = seed * PM_MULT % PM % SLOTS + 1
  local kind = slot <= 5 and "bandits" or slot <= 13 and "fair" or "rich"
  return math.floor(stake * pct[kind] / 100), kind
end

-- ---------- the body ----------
-- a^week^count^prevWeek^prevCount^g1.g2.g3.g4.g5.g6^title^colour^badge

function CC.PackBody(b)
  local g = b.gifts
  return string.format("%s^%d^%d^%d^%d^%d.%d.%d.%d.%d.%d^%d^%d^%d", b.a, b.week, b.count, b.prevWeek, b.prevCount,
    g[1], g[2], g[3], g[4], g[5], g[6], b.title, b.colour, b.badge)
end

local BODY = "^([0-9a-z]+)%^([%-%d]+)%^(%d+)%^([%-%d]+)%^(%d+)%^(%d+)%.(%d+)%.(%d+)%.(%d+)%.(%d+)%.(%d+)"
  .. "%^(%d+)%^(%d+)%^(%d+)$"

-- A canonical integer of at most `width` digits, between lo and hi; nil otherwise. Checked before tonumber, so "-0",
-- "03" and "+3" never pass (tostring(tonumber("-0")) is "-0" in LuaJIT).
local function int(s, width, lo, hi)
  if not (s == "0" or s:match("^%-?[1-9]%d*$")) then return nil end
  if #s:gsub("^%-", "") > width then return nil end
  local n = tonumber(s)
  if not n or n < lo or n > hi then return nil end
  return n
end

function CC.ParseBody(body, weekNow)
  if type(body) ~= "string" then return nil, "type" end
  if #body > MAX_BODY then return nil, "long" end
  if type(weekNow) ~= "number" then return nil, "weekNow" end
  local f = { body:match(BODY) }
  if #f ~= 14 then return nil, "shape" end
  if #f[1] ~= 6 then return nil, "token" end
  local b = { a = f[1], gifts = {} }
  b.week = int(f[2], 4, -9999, 9999)
  b.count = int(f[3], 2, 0, CC.TICKETS_MAX)
  b.prevWeek = int(f[4], 4, -9999, 9999)
  b.prevCount = int(f[5], 2, 0, CC.TICKETS_MAX)
  if not (b.week and b.count and b.prevWeek and b.prevCount) then return nil, "tickets" end
  for k = 1, 6 do
    b.gifts[k] = int(f[5 + k], 6, 0, CC.PROJECTS[k].goal)
    if not b.gifts[k] then return nil, "gift" end
  end
  b.title = int(f[12], 2, 0, 6)
  b.colour = int(f[13], 2, 0, 6)
  b.badge = int(f[14], 2, 0, 10)
  if not (b.title and b.colour and b.badge) then return nil, "look" end
  -- The current and the previous ticket weeks are checked on their own (S14): count 0 with a previous week is the
  -- row of a key whose week's tickets moved to another character.
  if b.count == 0 then
    if b.week ~= 0 then return nil, "noticket" end
  elseif b.week < FIRST_WEEK or b.week > weekNow + 1 then
    return nil, "week"
  end
  if b.prevCount == 0 then
    if b.prevWeek ~= 0 then return nil, "prevWeek" end
  elseif b.prevWeek < FIRST_WEEK or (b.count > 0 and b.prevWeek >= b.week)
    or (b.count == 0 and b.prevWeek > weekNow) then
    return nil, "prevWeek"
  end
  if CC.PackBody(b) ~= body then return nil, "canonical" end
  return b
end

-- ---------- the row (S14): the body, then an officer part ----------
-- row = body *( "!" item ); at most one d item, first; hide entries after it, sorted by key, each key once, at most
-- HIDE_MAX. Keys are 1..64 bytes without ! . ~ ^. Canonical: CC.PackRow(CC.ParseRow(row)) == row.

local D_MAX = 98  -- "!d" 4 . 10 . 5 . 5 . 2 . 64
local ENTRY_MAX = 2 + AT_DIGITS + 1 + KEY_MAX
local MAX_ROW = MAX_BODY + D_MAX + CC.HIDE_MAX * ENTRY_MAX

local function goodKey(k)
  return type(k) == "string" and #k >= 1 and #k <= KEY_MAX and not k:find("[!%.~%^]")
end

local function packDraw(d)
  if (d.total or 0) == 0 then return "d" .. d.week .. ".0" end
  return "d" .. d.week .. "." .. d.salt .. "." .. d.target .. "." .. d.total .. "." .. d.i .. "." .. d.key
end

function CC.PackRow(b, off)
  local parts = { CC.PackBody(b) }
  if off then
    if off.draw then parts[#parts + 1] = packDraw(off.draw) end
    local keys = {}
    for k in pairs(off.hides or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local h = off.hides[k]
      parts[#parts + 1] = (h.on and "h" or "u") .. h.at .. "." .. k
    end
  end
  return table.concat(parts, "!")
end

local function parseDraw(s, weekNow)
  local w = s:match("^d([%-%d]+)%.0$")
  if w then
    local week = int(w, 4, FIRST_WEEK, weekNow)
    if not week then return nil, "drawWeek" end
    return { week = week, total = 0 }
  end
  local f = { s:match("^d([%-%d]+)%.(%d+)%.(%d+)%.(%d+)%.(%d+)%.([^.]+)$") }
  if #f ~= 6 then return nil, "draw" end
  local d = { week = int(f[1], 4, FIRST_WEEK, weekNow), salt = int(f[2], AT_DIGITS, 1, SEED_MOD),
    target = int(f[3], 5, 0, NUM_MOD - 1), total = int(f[4], 6, 1, CC.TOTAL_CAP), i = int(f[5], 2, 1, CC.TICKETS_MAX),
    key = f[6] }
  if not (d.week and d.salt and d.target and d.total and d.i) then return nil, "draw" end
  if not goodKey(d.key) then return nil, "key" end
  if d.target ~= CC.Target(d.week, d.total, d.salt) then return nil, "target" end
  d.number = CC.Number(d.week, d.key, d.i)
  d.pot = d.total * CC.TICKET_PRICE
  return d
end

function CC.ParseRow(row, weekNow)
  if type(row) ~= "string" then return nil, "type" end
  if #row > MAX_ROW then return nil, "long" end
  local cut = row:find("!", 1, true)
  if not cut then return CC.ParseBody(row, weekNow) end
  local b, why = CC.ParseBody(row:sub(1, cut - 1), weekNow)
  if not b then return nil, why end
  local off, n, last = { hides = {} }, 0, nil
  local first = true
  for item in (row:sub(cut + 1) .. "!"):gmatch("([^!]*)!") do
    local kind = item:sub(1, 1)
    if kind == "d" then
      if not first then return nil, "drawPlace" end
      local d, dwhy = parseDraw(item, weekNow)
      if not d then return nil, dwhy end
      off.draw = d
    elseif kind == "h" or kind == "u" then
      local at, key = item:match("^[hu](%d+)%.(.*)$")
      at = at and int(at, AT_DIGITS, 0, 9999999999)
      if not at then return nil, "at" end
      if not goodKey(key) then return nil, "key" end
      if last and key <= last then return nil, "order" end
      n = n + 1
      if n > CC.HIDE_MAX then return nil, "hides" end
      off.hides[key] = { on = kind == "h", at = at }
      last = key
    else
      return nil, "item"
    end
    first = false
  end
  if CC.PackRow(b, off) ~= row then return nil, "canonical" end
  return b, off
end

-- The standing entry per hidden key over officer sections ({ by = record key, hides }): the newer at wins (entries
-- stamped past now + 300 are ignored), then a hide over an unhide, then the lower record key (q1606).
function CC.ResolveHides(list, now)
  local out = {}
  for _, e in ipairs(list or {}) do
    for key, h in pairs(e.hides or {}) do
      if type(h.at) == "number" and h.at <= now + FUTURE then
        local c = out[key]
        if not c or h.at > c.at or (h.at == c.at and ((h.on and not c.on) or (h.on == c.on and e.by < c.by))) then
          out[key] = { on = h.on and true or false, at = h.at, by = e.by }
        end
      end
    end
  end
  return out
end

-- Officers' draws ({ by = record key, draw }): more tickets counted wins, then the lower officer key (o1750).
function CC.ResolveDraw(list)
  local best, by
  for _, e in ipairs(list or {}) do
    local d = e.draw
    if d and (not best or (d.total or 0) > (best.total or 0) or ((d.total or 0) == (best.total or 0) and e.by < by)) then
      best, by = d, e.by
    end
  end
  return best
end
