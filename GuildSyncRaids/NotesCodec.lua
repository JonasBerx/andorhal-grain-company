local _, ns = ...
if not ns.M then return end

-- The pure codec for the raids_n record bodies (ticket 61, N1 and N2; plan "Wire and saved shapes"): keys, escapes,
-- cleaning, caps and the two-part cut. Exports ns.NotesCodec: V, LIMITS, ValidKey, Clean, Utf8, Decode, Pack. No client
-- calls, no frame, no saved data.
--   r<id>: R,1,<gen>,1,1,<name>,<words>,<sketches>;<bossId>...
--   b<id>: B,1,<gen>,1,<n>,<raidId>,<name>,<text1>   b<id>b: B,1,<gen>,2,2,<text2>
--   j<id>: J,1,<gen>,1,<n>;j,<no>,<name>,<hint>;h,<no>,<team>,<holder>...   j<id>b: J,1,<gen>,2,2;...
--   any key, deleted: X,1,<gen>

local NC = { V = 1 }
ns.NotesCodec = NC

local L = { PART = 2000, RECV = 3000, NOTE = 3600, NAME = 40, HINT = 120, WORDS = 120, SKETCH = 120, JOBS = 20,
  HOLDERS = 5, BOSSES = 20, PARTS = 2 }
NC.LIMITS = L

local CEIL = 4102444800
local TAG = { r = "R", b = "B", j = "J" }
local ESC = { ["%"] = "%25", ["~"] = "%7E", [";"] = "%3B", [","] = "%2C", ["|"] = "%7C", ["\n"] = "%0A" }

local function digits(s) return type(s) == "string" and #s <= 20 and string.match(s, "^%d+$") ~= nil end

-- kind, id, part for a valid key; nil otherwise.
function NC.ValidKey(key)
  if type(key) ~= "string" then return nil end
  local kind, id, suffix = string.match(key, "^([rbj])(%d+)(b?)$")
  if not kind or #id > 20 or (kind == "r" and suffix ~= "") then return nil end
  return kind, id, suffix == "b" and 2 or 1
end

-- \r\n to \n, then drop C0 (but \n when keepBreaks), DEL and |. Over cap bytes gives nil; it never cuts.
function NC.Clean(s, cap, keepBreaks)
  if type(s) ~= "string" and type(s) ~= "number" then s = "" end
  s = string.gsub(string.gsub(tostring(s), "\r\n", "\n"), keepBreaks and "[%z\1-\9\11-\31\127|]" or "[%z\1-\31\127|]", "")
  if cap and #s > cap then return nil end
  return s
end

-- The byte ranges after each lead byte of a well-formed UTF-8 sequence (RFC 3629: no overlong form, no surrogate,
-- nothing above U+10FFFF); a lead byte not listed here is never valid.
local TAIL = {}
for b = 194, 223 do TAIL[b] = { { 128, 191 } } end
for b = 224, 239 do TAIL[b] = { { 128, 191 }, { 128, 191 } } end
TAIL[224] = { { 160, 191 }, { 128, 191 } }
TAIL[237] = { { 128, 159 }, { 128, 191 } }
for b = 240, 244 do TAIL[b] = { { 128, 191 }, { 128, 191 }, { 128, 191 } } end
TAIL[240] = { { 144, 191 }, { 128, 191 }, { 128, 191 } }
TAIL[244] = { { 128, 143 }, { 128, 191 }, { 128, 191 } }

-- s with every byte that is not part of a well-formed UTF-8 sequence removed.
function NC.Utf8(s)
  if type(s) ~= "string" or not string.find(s, "[\128-\255]") then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = string.byte(s, i)
    if b < 128 then
      out[#out + 1] = string.char(b)
      i = i + 1
    else
      local tail, good = TAIL[b], false
      if tail then
        good = true
        for k, r in ipairs(tail) do
          local c = string.byte(s, i + k)
          if not c or c < r[1] or c > r[2] then good = false; break end
        end
      end
      if good then
        out[#out + 1] = string.sub(s, i, i + #tail)
        i = i + #tail + 1
      else
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

local function esc(s) return (string.gsub(s, "[%%~;,|\n]", ESC)) end

-- %XX in either hex case; a bad or cut escape gives nil (Codec.lua:47-55).
local function unesc(s)
  local bad = false
  local out = string.gsub(s, "%%(.?.?)", function(h)
    if not string.match(h, "^%x%x$") then bad = true; return "" end
    return string.char(tonumber(h, 16))
  end)
  if bad then return nil end
  return out
end

local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local at = string.find(s, sep, pos, true)
    if not at then out[#out + 1] = string.sub(s, pos); return out end
    out[#out + 1] = string.sub(s, pos, at - 1)
    pos = at + 1
  end
end

-- A received cell: unescaped, then cleaned again; nil on a bad escape, over cap or under min bytes. Every cell but the
-- note's text (keepBreaks) loses its invalid UTF-8 here; the note loses it after the join (NotesRules.View).
local function cell(s, cap, min, keepBreaks)
  local u = unesc(s or "")
  if not u then return nil end
  local c = NC.Clean(u, cap, keepBreaks)
  if c and not keepBreaks then c = NC.Utf8(c) end
  if not c or #c < (min or 0) then return nil end
  return c
end

local function num(s, max)
  if not digits(s) then return nil end
  local v = tonumber(s)
  if v <= max then return v end
end

local function decodeJobs(rec, rows)
  local byNo, seenH, hs = {}, {}, {}
  rec.jobs, rec.loose = {}, {}
  for r = 2, #rows do
    local c = split(rows[r], ",")
    if c[1] == "j" or c[1] == "h" then
      local no = num(c[2], L.JOBS)
      if not no or no < 1 then return nil, "jobs" end
      if c[1] == "j" then
        local name, hint = cell(c[3], L.NAME, 1), cell(c[4], L.HINT)
        if byNo[no] or not name or not hint then return nil, "jobs" end
        byNo[no] = { no = no, name = name, hint = hint, holders = {} }
        rec.jobs[#rec.jobs + 1] = byNo[no]
      else
        local team = cell(c[3], L.NAME)
        seenH[no] = seenH[no] or {}
        if not team or seenH[no][team] or #c - 3 > L.HOLDERS then return nil, "holders" end
        seenH[no][team] = true
        local names = {}
        for k = 4, #c do
          local n = cell(c[k], L.NAME, 1)
          if not n then return nil, "holders" end
          names[#names + 1] = n
        end
        hs[#hs + 1] = { no, team, names }
      end
    end
  end
  -- h rows whose job is not in this part wait in rec.loose[no][team] for the other part (Rules joins them).
  for _, e in ipairs(hs) do
    local no, team, names = e[1], e[2], e[3]
    if byNo[no] then byNo[no].holders[team] = names
    else
      rec.loose[no] = rec.loose[no] or {}
      rec.loose[no][team] = names
    end
  end
  return rec
end

-- rec | nil, why. #body is checked before any parse; every cell is unescaped and cleaned.
function NC.Decode(key, body)
  local kind, id, part = NC.ValidKey(key)
  if not kind then return nil, "key" end
  if type(body) ~= "string" or #body > L.RECV then return nil, "size" end
  local rows = split(body, ";")
  local h = split(rows[1], ",")
  local v, gen = num(h[2], math.huge), num(h[3], CEIL)
  if not v or not gen then return nil, "head" end
  local rec = { kind = "x", v = v, gen = gen, id = id, part = part }
  if h[1] == "X" then return rec end
  if h[1] ~= TAG[kind] then return nil, "head" end
  local i, n = num(h[4], L.PARTS), num(h[5], L.PARTS)
  if not i or not n or i ~= part or i > n or (kind == "r" and n ~= 1) then return nil, "head" end
  rec.kind, rec.n = kind, n
  if kind == "r" then
    rec.name, rec.words, rec.sketches = cell(h[6], L.NAME, 1), cell(h[7], L.WORDS), cell(h[8], L.SKETCH)
    if not (rec.name and rec.words and rec.sketches) then return nil, "cell" end
    rec.bosses = {}
    local seen = {}
    for r = 2, #rows do
      local b = split(rows[r], ",")[1]
      if string.match(b, "^%d+$") then
        if #b > 20 or seen[b] or #rec.bosses >= L.BOSSES then return nil, "bosses" end
        seen[b] = true
        rec.bosses[#rec.bosses + 1] = b
      end
    end
  elseif kind == "b" then
    local t = (part == 1 and h[8] or h[6]) or ""
    if part == 1 then
      rec.raid, rec.name = h[6], cell(h[7], L.NAME, 1)
      if not digits(rec.raid) or not rec.name then return nil, "cell" end
    end
    rec.escLen = #t
    rec.text = rec.escLen <= L.NOTE and cell(t, nil, 0, true) or nil
    if not rec.text then return nil, "note" end
  else
    return decodeJobs(rec, rows)
  end
  return rec
end

local function packJobs(id, g, jobs)
  if #jobs > L.JOBS then return nil, "jobs" end
  local rows, seen = {}, {}
  for _, j in ipairs(jobs) do
    local no = type(j) == "table" and tonumber(j.no)
    if not no or no < 1 or no > L.JOBS or no % 1 ~= 0 or seen[no] then return nil, "jobs" end
    seen[no] = true
    local name, hint = NC.Clean(j.name, L.NAME), NC.Clean(j.hint, L.HINT)
    if not name or name == "" then return nil, "name" end
    if not hint then return nil, "hint" end
    rows[#rows + 1] = "j," .. no .. "," .. esc(name) .. "," .. esc(hint)
    local holders = type(j.holders) == "table" and j.holders or {}
    local teams = {}
    for team in pairs(holders) do if type(team) == "string" then teams[#teams + 1] = team end end
    table.sort(teams)
    for _, team in ipairs(teams) do
      local list, t = holders[team], NC.Clean(team, L.NAME)
      if not t or type(list) ~= "table" or #list > L.HOLDERS then return nil, "holders" end
      local cells = { "h", no, esc(t) }
      for _, name in ipairs(list) do
        local c = NC.Clean(name, L.NAME)
        if not c or c == "" then return nil, "holders" end
        cells[#cells + 1] = esc(c)
      end
      if #list > 0 then rows[#rows + 1] = table.concat(cells, ",") end
    end
  end
  -- Cut only between rows (Codec.lua:79-102).
  local function head(i, n) return "J,1," .. g .. "," .. i .. "," .. n end
  local parts, cur = {}, { head(1, 1) }
  local size = #cur[1]
  for _, row in ipairs(rows) do
    if #cur > 1 and size + 1 + #row > L.PART then
      parts[#parts + 1] = cur
      cur = { head(2, 2) }
      size = #cur[1]
    end
    cur[#cur + 1] = row
    size = size + 1 + #row
  end
  parts[#parts + 1] = cur
  if #parts > L.PARTS then return nil, "parts" end
  if #parts == 1 then return { ["j" .. id] = table.concat(cur, ";") } end
  parts[1][1] = head(1, 2)
  return { ["j" .. id] = table.concat(parts[1], ";"), ["j" .. id .. "b"] = table.concat(parts[2], ";") }
end

-- { [key] = body } | nil, why. Every input is cleaned; a cap refuses, it never cuts.
function NC.Pack(rec)
  if type(rec) ~= "table" or not digits(rec.id) then return nil, "id" end
  local gen = rec.gen
  if type(gen) ~= "number" or gen ~= gen or gen < 0 or gen > CEIL or gen % 1 ~= 0 then return nil, "gen" end
  local kind, id, g = rec.kind, rec.id, string.format("%d", gen)
  if kind == "r" then
    local name, words, sketches = NC.Clean(rec.name, L.NAME), NC.Clean(rec.words, L.WORDS), NC.Clean(rec.sketches, L.SKETCH)
    if not name or name == "" then return nil, "name" end
    if not words then return nil, "words" end
    if not sketches then return nil, "sketches" end
    local rows, seen = { "R,1," .. g .. ",1,1," .. esc(name) .. "," .. esc(words) .. "," .. esc(sketches) }, {}
    for _, b in ipairs(type(rec.bosses) == "table" and rec.bosses or {}) do
      if not digits(b) or seen[b] or #rows > L.BOSSES then return nil, "bosses" end
      seen[b] = true
      rows[#rows + 1] = b
    end
    local body = table.concat(rows, ";")
    if #body > L.PART then return nil, "parts" end
    return { ["r" .. id] = body }
  elseif kind == "b" then
    if not digits(rec.raid) then return nil, "id" end
    local name = NC.Clean(rec.name, L.NAME)
    if not name or name == "" then return nil, "name" end
    local e = esc(NC.Clean(rec.text, nil, true))
    if #e > L.NOTE then return nil, "note" end
    local function head(n) return "B,1," .. g .. ",1," .. n .. "," .. rec.raid .. "," .. esc(name) .. "," end
    if #head(1) + #e <= L.PART then return { ["b" .. id] = head(1) .. e } end
    -- The note cut: back off a UTF-8 continuation byte after the cut and an escape split by it.
    local c = L.PART - #head(2)
    while c > 0 do
      local after = string.byte(e, c + 1)
      if not ((after and after >= 128 and after <= 191) or string.sub(e, c, c) == "%"
        or string.sub(e, c - 1, c - 1) == "%") then break end
      c = c - 1
    end
    return { ["b" .. id] = head(2) .. string.sub(e, 1, c), ["b" .. id .. "b"] = "B,1," .. g .. ",2,2," .. string.sub(e, c + 1) }
  elseif kind == "j" then
    return packJobs(id, g, type(rec.jobs) == "table" and rec.jobs or {})
  end
  return nil, "id"
end
