-- GuildSyncGames WhoCore.lua (S22 Task 2): the pure Who said it core, ns.WhoCore (the daily lines and their four
-- names, the endless draw, pay, the share text, the results block).
-- Pure: string, table and math only, no globals, no date or time, no math.random. Its own constants, never
-- ns.VendorCore; it reads nothing but ns.VOICES, at call time. Every division is by a literal or an UPPER_CASE constant.
-- Frozen after #1: WC.Seed, the question draw and WC.Daily (any change moves every later day).

local _, ns = ...

local WC = {}
ns.WhoCore = WC

local PM = 2147483647 -- Park-Miller modulus
local INV_M = 1 / 2147483647
local SEED_MOD = 2147483646
local OFFSET = 4194304 -- 2^22: keeps r non-negative for the preview days
local RUN = 10
local MAX_SAY = 255 -- a chat line, the "/g " prefix included
local SAY_PREFIX = 3
local BEST_MAX = 999
local STREAK_MAX = 9999
local DRAWS = 7 -- stream values per question: the line, three names, three shuffle steps

WC.SEED = 20261026
WC.ENABLED = true -- the shipped switch (AC7): false hides the game

-- ---------- the seed and the stream ----------

-- Day n's seed: quadratic in n (a product, never ^), so the days do not walk a straight line.
function WC.Seed(n)
  local r = n + OFFSET
  local q = r * 8 + 5
  return (q * q + WC.SEED) % SEED_MOD + 1
end

-- Park-Miller; a seed outside [1, PM - 1] is refused (0 sticks at 0).
local function stream(seed)
  if type(seed) ~= "number" or seed ~= math.floor(seed) or seed < 1 or seed > PM - 1 then return nil end
  local x = seed
  return function()
    x = 16807 * x % PM
    return x * INV_M
  end
end

-- ---------- the groups ----------

local lines, members, daily -- the list the caches were built from, group id -> its speaker ids, day -> run

-- Rebuilt when ns.VOICES.lines is another table (a data-only edit, a test's list).
local function groups()
  local L = ns.VOICES and ns.VOICES.lines or {}
  if lines == L then return members end
  lines, members, daily = L, {}, {}
  local seen = {}
  for _, l in ipairs(L) do
    local s, g = l[3], l[4]
    members[g] = members[g] or {}
    seen[g] = seen[g] or {}
    if not seen[g][s] then
      seen[g][s] = true
      members[g][#members[g] + 1] = s
    end
  end
  for _, m in pairs(members) do table.sort(m) end
  return members
end

-- ---------- the draw ----------

-- One question from DRAWS next() calls: a line not in used (the walk steps on from a used one), three other names of
-- its group (the same walk), then a shuffle of the four. Answers lineIndex, choices; nil when no line or names are left.
local function question(next, used)
  local M = groups()
  local N = #lines
  local v = next()
  local i = math.floor(v * N) + 1
  local line
  for _ = 1, N do
    if not used[i] then line = i break end
    i = i < N and i + 1 or 1
  end
  if not line then return nil end
  local speaker = lines[line][3]
  local others = {}
  for _, s in ipairs(M[lines[line][4]]) do
    if s ~= speaker then others[#others + 1] = s end
  end
  local C = #others
  if C < 3 then return nil end
  local choices, taken = { speaker }, {}
  for _ = 1, 3 do
    local m = math.floor(next() * C) + 1
    while taken[m] do m = m < C and m + 1 or 1 end
    taken[m] = true
    choices[#choices + 1] = others[m]
  end
  for k = 4, 2, -1 do
    local j = math.floor(next() * k) + 1
    choices[k], choices[j] = choices[j], choices[k]
  end
  return line, choices
end

-- Day n's ten lines from one stream, no line twice; nil when any draw fails (never a short run). Any whole n.
function WC.Daily(n)
  groups()
  if daily[n] ~= nil then return daily[n] or nil end
  local nxt, used, run = stream(WC.Seed(n)), {}, {}
  for k = 1, RUN do
    local line, choices = question(nxt, used)
    if not line then
      daily[n] = false
      return nil
    end
    used[line] = true
    run[k] = { line = line, choices = choices }
  end
  daily[n] = run
  return run
end

-- The next endless line: the stream from seed, past the DRAWS values of each line already used. used is keyed by line
-- index and kept by the caller; the same seed and used give the same line.
function WC.Endless(seed, used)
  local nxt = stream(seed)
  if not nxt then return nil end
  local n = 0
  for _ in pairs(used or {}) do n = n + 1 end
  for _ = 1, n * DRAWS do nxt() end
  return question(nxt, used or {})
end

-- ---------- pay ----------

-- The count of "1" marks (nil counts as none).
local function rights(marks)
  local _, c = (marks or ""):gsub("1", "")
  return c
end

-- 5 grain per right, 25 more at ten right; endless pays nothing.
function WC.Pay(right, endless)
  if endless then return 0 end
  return right * 5 + (right == RUN and 25 or 0)
end

-- ---------- sharing ----------

local ICON = { ["1"] = "{rt4}", ["0"] = "{rt5}" }
local PLAIN = { ["1"] = "G", ["0"] = "." }

local function shareLine(label, marks, map)
  return "Who said it? " .. label .. " " .. rights(marks) .. "/10 " .. (marks:gsub(".", map))
end

-- The marks as one chat line, no speaker and no id; icons fall back to plain when the line with "/g " would pass 255.
function WC.ShareText(label, marks) -- label = Core.Label(n): "#12", or "Preview 7" before launch
  local text = shareLine(label, marks, ICON)
  if #text + SAY_PREFIX <= MAX_SAY then return text end
  return shareLine(label, marks, PLAIN)
end

-- ---------- the block ----------
-- n^score^marks^best^streak, the score packed from the marks; VendorCore's "!w" block makes the same bytes. Caps as
-- VendorCore's (day 6 characters, best 999, streak 9999); no day rule here (ns.Limits.Who has them).

function WC.PackBlock(b)
  if type(b) ~= "table" or type(b.n) ~= "number" or type(b.best) ~= "number" or type(b.streak) ~= "number" then
    return nil
  end
  local marks = b.marks or ""
  return b.n .. "^" .. rights(marks) .. "^" .. marks .. "^" .. b.best .. "^" .. b.streak
end

function WC.ParseBlock(s)
  if type(s) ~= "string" then return nil end
  local n, score, marks, best, streak = s:match("^(%-?%d+)%^(%d+)%^([01]*)%^(%d+)%^(%d+)$")
  if not n or #n > 6 then return nil end
  n, score, best, streak = tonumber(n), tonumber(score), tonumber(best), tonumber(streak)
  if #marks ~= RUN and not (#marks == 0 and score == 0 and streak == 0) then return nil end
  if score > RUN or score ~= rights(marks) then return nil end
  if best > BEST_MAX or streak > STREAK_MAX then return nil end
  return { n = n, score = score, marks = marks, best = best, streak = streak }
end
