-- GuildSyncExpeditions Traits.lua: what a follower gains and loses from runs, and what its traits do (0.19 plan, Seams 8).
--   ns.TraitEvents(fid, run, outcome, paid)            paid = { credited = bool, blue = bool }
--   ns.TraitBonus(fid, row) -> n                       ns.TraitMods(fid, row) -> a fresh table of RiskCore's mod fields
--   ns.OnRaised(fid)                                   ns.TraitFade(fid, id) -> wins left | nil
--   ns.TraitInfo(id) -> { name, text } | nil
-- A follower's traits are f.traits. The saved part traitc holds the three counters FC.SoundRow would not keep.

local _, ns = ...
if not ns.M then return end

local FC, D = ns.FollowerCore, ns.FollowerData

local MAX_HELD = 3
local COUNTERS = { "grave", "shaken", "streak" }
local FADE = { grave = 5, shaken = 2 } -- wins until the trait goes

local WIN = { succ = true, succw = true }
local WOUND = { succw = true, failw = true }
local FAIL = { fail = true, failw = true }

local MODS = {
  scarred = { woundPct = 75 }, grave = { deathPct = 80 }, sturdy = { broken = 3 },
  deadly = { success = 3 }, shaken = { success = -5 }, greedy = { success = -3 },
}
local DEADLY_DANGER = 4 -- the danger Deadly survivor is won at and works at

local INFO = {
  veteran = { "Veteran", "+5 Power" },
  scarred = { "Scarred", "-25% wound chance" },
  deadly = { "Deadly survivor", "+3 success on Deadly expeditions" },
  lucky = { "Lucky", "finds Rare gear 25% more often" },
  grave = { "Grave-touched", "-20% death chance" },
  shaken = { "Shaken", "-5 success" },
  greedy = { "Greedy", "+25% grain, -3 success; lost on a failure or a death" },
  keen = { "Keen-eyed", "finds relics 50% more often" },
  sturdy = { "Sturdy", "-3% gear break chance" },
}

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function fresh() return { rows = {} } end

-- A new table of the known fields only, as FC.SoundRow. A row whose follower is gone is dropped.
local function soundRow(id, row)
  if not whole(id, 1, FC.ID_MAX) or not ns.Follower(id) then return nil end
  local out = {}
  for _, k in ipairs(COUNTERS) do
    out[k] = whole(row[k], 0, FC.STAT_MAX) and row[k] or 0
  end
  return out
end

-- At use, never at file load: saved variables are not ready then.
local function part() return ns.Part("traitc", fresh, soundRow) end

local function count(fid, name)
  local row = part().rows[fid]
  return row and row[name] or 0
end

-- A row is made only when a counter changes.
local function setCount(fid, name, n)
  n = math.min(n, FC.STAT_MAX)
  if count(fid, name) == n then return end
  local rows = part().rows
  if not rows[fid] then rows[fid] = { grave = 0, shaken = 0, streak = 0 } end
  rows[fid][name] = n
end

local function indexOf(f, id)
  for i, v in ipairs(f.traits) do
    if v == id then return i end
  end
  return nil
end

local function gain(f, id)
  if not indexOf(f, id) and #f.traits < MAX_HELD then f.traits[#f.traits + 1] = id end
end

local function lose(f, id)
  local i = indexOf(f, id)
  if i then table.remove(f.traits, i) end
end

local function countWin(f, fid, id)
  if not indexOf(f, id) then return end
  local n = count(fid, id) + 1
  setCount(fid, id, n)
  if n >= FADE[id] then lose(f, id) end
end

-- Losses first, so a slot freed here can take a gain of the same run. The stats are C's, already bumped, and match
-- exactly, so a trait skipped at 3 held stays skipped.
function ns.TraitEvents(fid, run, outcome, paid)
  local f = ns.Follower(fid)
  if not f then return end
  local band = outcome.band
  if WIN[band] then
    countWin(f, fid, "grave")
    countWin(f, fid, "shaken")
  else
    lose(f, "greedy")
  end
  local streak = paid.credited == true and count(fid, "streak") + 1 or 0
  setCount(fid, "streak", streak)
  if band == "dead" then return end

  local s, deadliest = f.stats, run.danger == DEADLY_DANGER
  if WIN[band] and s.wins == 10 then gain(f, "veteran") end
  if WOUND[band] and s.wounds == 3 then gain(f, "scarred") end
  if WIN[band] and deadliest and s.deadly == 1 then gain(f, "deadly") end
  if paid.blue == true then gain(f, "lucky") end
  if FAIL[band] and deadliest then
    gain(f, "shaken")
    setCount(fid, "shaken", 0)
  end
  if streak == 5 then gain(f, "greedy") end
end

function ns.OnRaised(fid)
  local f = ns.Follower(fid)
  if not f then return end
  gain(f, "grave")
  setCount(fid, "grave", 0)
end

-- TraitBonus and TraitMods run for every chance shown, so they read f.traits only and never open traitc.
function ns.TraitBonus(fid, row)
  local f = ns.Follower(fid)
  local total = 0
  for _, id in ipairs(f and f.traits or {}) do
    local t = D.TRAIT_POWER[id]
    if t and (not t.rowKind or (type(row) == "table" and row.kind == t.rowKind)) then total = total + t.power end
  end
  return total
end

function ns.TraitMods(fid, row)
  local f = ns.Follower(fid)
  local out = {}
  for _, id in ipairs(f and f.traits or {}) do
    if id ~= "deadly" or (type(row) == "table" and row.danger == DEADLY_DANGER) then
      for field, n in pairs(MODS[id] or {}) do out[field] = (out[field] or 0) + n end
    end
  end
  return out
end

function ns.TraitInfo(id)
  if id == "quiet" then return { name = "Quiet", text = "+4 Power on " .. ns.W.Name.Scout .. " expeditions" } end
  local t = INFO[id]
  if not t then return nil end
  return { name = t[1], text = t[2] }
end

function ns.TraitFade(fid, id)
  local f = ns.Follower(fid)
  if not f or not FADE[id] or not indexOf(f, id) then return nil end
  return math.max(0, FADE[id] - count(fid, id))
end
