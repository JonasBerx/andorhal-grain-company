-- GuildSyncGames Core.lua: the pure core, ns.Core (score, day, order, wire body, share text).
-- Pure: string, table and math only, no globals, no date or time (the day comes in as server seconds).
-- Every division is by a constant, except inside Core.Mod, which answers nil unless b is a positive number.

local _, ns = ...

local Core = {}
ns.Core = Core

local LAUNCH_UTC = 1793750400 -- 2026-11-04 00:00 UTC
local DAY = 86400
local PREVIEW_DAYS = 14
local PM = 2147483647 -- Park-Miller modulus
local INV_M = 1 / 2147483647
local MAX_SAY = 255 -- a chat line, the "/g " prefix included
local MAX_BODY = 80 -- a real body is at most 56 bytes (6 + 1 + 5 + 3 carets + 6 rows of 6 + 5 dots)

Core.SEED = 20261104
Core.PREVIEW_DAYS = PREVIEW_DAYS

-- ---------- the game ----------

-- Wordle's rule: exact matches first, then a yellow for each letter while the answer has some of it left.
function Core.Score(guess, answer)
  local codes, left = {}, {}
  for i = 1, #answer do
    local a = answer:sub(i, i)
    if guess:sub(i, i) == a then
      codes[i] = "g"
    else
      left[a] = (left[a] or 0) + 1
    end
  end
  for i = 1, #guess do
    if not codes[i] then
      local c = guess:sub(i, i)
      if (left[c] or 0) > 0 then
        codes[i] = "y"
        left[c] = left[c] - 1
      else
        codes[i] = "x"
      end
    end
  end
  return table.concat(codes)
end

function Core.Valid(guess, n, acceptedSet)
  if type(guess) ~= "string" then return nil, "length" end
  local word = guess:upper()
  if #word ~= n then return nil, "length" end
  if not acceptedSet[word] then return nil, "word" end
  return word
end

local RANK = { x = 1, y = 2, g = 3 }

function Core.Known(rows)
  local known = {}
  for _, row in ipairs(rows) do
    for i = 1, #row.word do
      local letter, code = row.word:sub(i, i), row.codes:sub(i, i)
      if RANK[code] and (not known[letter] or RANK[code] > RANK[known[letter]]) then known[letter] = code end
    end
  end
  return known
end

-- Each word with its codes against answer: { { word, codes }, ... }.
function Core.Scored(words, answer)
  local rows = {}
  for i, w in ipairs(words) do rows[i] = { word = w, codes = Core.Score(w, answer) } end
  return rows
end

-- A finished game as PackBody's input; rows are { word, codes }.
function Core.Result(n, won, rows, streak)
  local codes = {}
  for i, r in ipairs(rows) do codes[i] = r.codes end
  return { n = n, tries = won and #rows or 0, streak = streak, rows = codes }
end

-- The tries as shown: "X" for a loss (0).
function Core.Tries(tries) return tries == 0 and "X" or tries end

-- The guild list's order: solved first by tries, then the X rows, each by key.
function Core.ByResult(a, b)
  local x, y = a.tries == 0 and 7 or a.tries, b.tries == 0 and 7 or b.tries
  if x ~= y then return x < y end
  return a.key < b.key
end

-- ---------- the day ----------

function Core.Mod(a, b)
  if type(a) ~= "number" or type(b) ~= "number" or not (b > 0) then return nil end
  return a - math.floor(a / b) * b
end

-- The reset's seconds after UTC midnight, rounded to the nearest minute.
function Core.Phase(now, untilReset)
  if type(now) ~= "number" or type(untilReset) ~= "number" then return nil end
  if not (untilReset > 0 and untilReset <= DAY) then return nil end
  local secs = (now + untilReset) % DAY
  return (math.floor(secs / 60 + 0.5) * 60) % DAY
end

-- #1 is the first reset day that starts at or after LAUNCH_UTC; N <= 0 are the previews before it.
function Core.Puzzle(now, phase)
  local first = LAUNCH_UTC + ((type(phase) == "number" and phase % DAY) or 0)
  local n = math.floor((now - first) / DAY) + 1
  local secsLeft = first + n * DAY - now
  return n, Core.Label(n), secsLeft
end

-- Day n's label: "#n" from launch, "Preview 1" to "Preview 13" before it, nil earlier.
function Core.Label(n)
  if n >= 1 then return "#" .. n end
  if n > -PREVIEW_DAYS then return "Preview " .. (n + PREVIEW_DAYS) end
  return nil
end

function Core.Countdown(secsLeft)
  local s = math.max(0, math.floor(secsLeft or 0))
  local h, m = math.floor(s / 3600), math.floor((s % 3600) / 60)
  if h > 0 then return h .. " h " .. m .. " min" end
  return m .. " min"
end

-- ---------- the word ----------

-- Park-Miller, then Fisher-Yates.
function Core.Order(count, seed)
  local order = {}
  for i = 1, count do order[i] = i end
  local x = seed
  for i = count, 2, -1 do
    x = 16807 * x % PM
    local j = math.floor(x * INV_M * i) + 1
    order[i], order[j] = order[j], order[i]
  end
  return order
end

function Core.WordFor(n, answers, order)
  local at = Core.Mod(n - 1, #answers)
  if not at then return nil end
  return answers[order[at + 1]]
end

-- ---------- the wire ----------

function Core.PackBody(res)
  return res.n .. "^" .. res.tries .. "^" .. res.streak .. "^" .. table.concat(res.rows, ".")
end

local function allGreen(row) return not row:find("[^g]") end

function Core.ParseBody(body, today)
  if type(body) ~= "string" or type(today) ~= "number" or #body > MAX_BODY then return nil, "not a body" end
  local n, tries, streak, grid = body:match("^(%-?%d+)%^(%d)%^(%d+)%^([gyx%.]+)$")
  if not n or #n > 6 or #streak > 5 then return nil, "not a body" end -- N at most 6 characters, streak 5 digits
  n, tries, streak = tonumber(n), tonumber(tries), tonumber(streak)
  if n < today - 1 or n > today + 1 then return nil, "day" end
  local rows = {}
  for row in (grid .. "."):gmatch("([^.]*)%.") do rows[#rows + 1] = row end
  if #rows > 6 then return nil, "rows" end
  local len = #rows[1]
  for _, row in ipairs(rows) do
    if #row ~= len or len < 5 or len > 6 then return nil, "row length" end
  end
  for i = 1, #rows - 1 do
    if allGreen(rows[i]) then return nil, "solved early" end
  end
  if tries == 0 then
    if #rows ~= 6 or allGreen(rows[6]) then return nil, "tries" end
  elseif tries ~= #rows or not allGreen(rows[#rows]) then
    return nil, "tries"
  end
  return { n = n, tries = tries, streak = streak, rows = rows }
end

-- ---------- sharing ----------

local ICON = { g = "{rt4}", y = "{rt1}", x = "{rt5}" }
local PLAIN = { g = "G", y = "Y", x = "." }

local function shareLine(label, res, map)
  local parts = { "WoWdle " .. label .. " " .. Core.Tries(res.tries) .. "/6" }
  for _, row in ipairs(res.rows) do parts[#parts + 1] = (row:gsub(".", map)) end
  return table.concat(parts, " ")
end

-- The grid as one chat line; icons fall back to the plain grid when the line with its prefix would pass 255 bytes.
function Core.ShareText(label, res, icons, prefixLen)
  if icons then
    local text = shareLine(label, res, ICON)
    if #text + (prefixLen or 0) <= MAX_SAY then return text end
  end
  return shareLine(label, res, PLAIN)
end

-- The current streak: alive while the last win was today or yesterday.
function Core.Streak(stats, today)
  if type(stats.cur) == "number" and type(stats.last) == "number" and stats.last >= today - 1 then
    return stats.cur
  end
  return 0
end
