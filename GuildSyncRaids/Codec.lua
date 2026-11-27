local _, ns = ...
if not ns.M then return end

-- Pure record body codec (plan "Record body"): caps, escapes, codes, parts, keys, expiry. No client calls.
--   body = head *( ";" item ); head = kind,gen,at,n,finish [,f1,f2,f3] (part 1 only)
--   E part 1: team, start, title. L part 1: team, colour. X: no items.
--   G (roster, ROSTER-FORMAT.md) part 1: size, name, raid id; item Name,<group><seat><main><off>[class]; a later
--   part's head is exactly 5 fields.

local Codec = {}
ns.Codec = Codec

local BODY_MAX, MAX_PARTS, RECV_MAX = 2000, 4, 3000
local DAY, TEAM_DAYS = 86400, 15
local CAP = { character = 40, discord = 40, team = 32, title = 64, sr = 200 }
local SUFFIX = { "", "b", "c", "d" }

local ROLE = { Tank = "T", Healer = "H", ["Melee DPS"] = "M", ["Ranged DPS"] = "R" }
local CLASS = { Warrior = "W", Paladin = "P", Hunter = "H", Rogue = "R", Priest = "I", Shaman = "S", Mage = "M",
  Warlock = "L", Druid = "D", ["Death Knight"] = "K", Monk = "O", ["Demon Hunter"] = "E", Evoker = "V" }
local KIND = { primary = "p", late = "l", tentative = "t", bench = "b", absence = "a" }

local function invert(t)
  local out = {}
  for word, code in pairs(t) do out[code] = word end
  return out
end
local ROLE_OF, CLASS_OF, KIND_OF = invert(ROLE), invert(CLASS), invert(KIND)
local SEAT_ROLE = { T = "T", H = "H", D = "D" }
local ROSTER_NAME = 40 -- code points; a person's name keeps CAP.character bytes

local ESC = { ["%"] = "%25", ["~"] = "%7E", [";"] = "%3B", [","] = "%2C", ["|"] = "%7C" }

-- Strip C0 and DEL, then cut to cap bytes on a UTF-8 boundary.
local function clean(s, cap)
  s = string.gsub(tostring(s or ""), "[%z\1-\31\127]", "")
  if #s <= cap then return s end
  local i = cap + 1
  while i > 1 do
    local b = string.byte(s, i)
    if b < 128 or b > 191 then break end
    i = i - 1
  end
  return string.sub(s, 1, i - 1)
end
Codec.Clean = clean

-- Strip C0 and DEL, then cut before the n+1-th UTF-8 lead byte (n code points).
local function chars(s, n)
  s = string.gsub(tostring(s or ""), "[%z\1-\31\127]", "")
  local count = 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b < 128 or b > 191 then
      count = count + 1
      if count > n then return string.sub(s, 1, i - 1) end
    end
  end
  return s
end

local function esc(s, cap) return (string.gsub(clean(s, cap), "[%%~;,|]", ESC)) end

-- %XX in either hex case; a bad or cut escape gives nil.
local function unesc(s)
  local bad = false
  local out = string.gsub(s, "%%(.?.?)", function(h)
    if not string.match(h, "^%x%x$") then bad = true; return "" end
    return string.char(tonumber(h, 16))
  end)
  if bad then return nil end
  return out
end

-- Split on a single-character separator, keeping empty cells.
local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local at = string.find(s, sep, pos, true)
    if not at then out[#out + 1] = string.sub(s, pos); return out end
    out[#out + 1] = string.sub(s, pos, at - 1)
    pos = at + 1
  end
end

local function cell(v) if v == nil then return "" end return tostring(v) end

function Codec.ValidKey(key)
  if type(key) ~= "string" then return false end
  local digits = string.match(key, "^[eg](%d+)[bcd]?$")
  if digits then return #digits <= 20 end
  return string.match(key, "^t[1-6][bcd]?$") ~= nil
end

-- Greedy packing: head1(n) and headN(n) give the part-1 head and the later-part head for a record of n parts.
-- n is one digit, so a placeholder "1" sizes every head exactly; the real n is written in at the end.
local function pack(key, head1, headN, items)
  local parts = {}
  local h1, hn = head1("1"), headN("1")
  local cur = { h1 }
  local size = #h1
  for _, item in ipairs(items) do
    if #cur > 1 and size + 1 + #item > BODY_MAX then
      parts[#parts + 1] = cur
      cur = { hn }
      size = #hn
    end
    cur[#cur + 1] = item
    size = size + 1 + #item
  end
  parts[#parts + 1] = cur
  if #parts > MAX_PARTS then return nil, "parts" end
  local n = tostring(#parts)
  local out = {}
  for i, p in ipairs(parts) do
    p[1] = (i == 1) and head1(n) or headN(n)
    out[key .. SUFFIX[i]] = table.concat(p, ";")
  end
  return out
end

function Codec.EncodeEvent(ev, gen, at)
  local items = {}
  for _, s in ipairs(ev.signups or {}) do
    local kind = KIND[s.kind]
    if kind then
      local character = esc(s.character, CAP.character)
      local item = character .. "," .. (ROLE[s.role] or "-") .. (CLASS[s.class] or "-") .. kind
      if character == "" then item = item .. "," .. esc(s.discord, CAP.discord) end
      items[#items + 1] = item
    end
  end
  local base = "E," .. cell(gen) .. "," .. cell(at) .. ","
  local tail = "," .. cell(ev.finish)
  -- sr: the optional 9th part-1 head field (older peers ignore it). ns.SrUrl (Decode.lua) is looked up at call time.
  local sr = ns.SrUrl and ns.SrUrl(ev.sr)
  local srCell = sr and ("," .. esc(sr, CAP.sr)) or ""
  return pack("e" .. tostring(ev.id), function(n)
    return base .. n .. tail .. "," .. esc(ev.team, CAP.team) .. "," .. cell(ev.start) .. "," .. esc(ev.title, CAP.title)
      .. srCell
  end, function(n) return base .. n .. tail end, items)
end

function Codec.EncodeTeam(team, n, gen, at)
  local items = {}
  for _, name in ipairs(team.active or {}) do items[#items + 1] = esc(name, CAP.character) .. ",a" end
  for _, name in ipairs(team.bench or {}) do items[#items + 1] = esc(name, CAP.character) .. ",b" end
  local base = "L," .. cell(gen) .. "," .. cell(at) .. ","
  return pack("t" .. tostring(n), function(parts)
    return base .. parts .. ",," .. esc(team.name, CAP.team) .. "," .. cell(team.colour)
  end, function(parts) return base .. parts .. "," end, items)
end

-- A roster's places and people (ROSTER-FORMAT.md "Caps"): size, then each item's place, seat taken and person twice,
-- then the reserve count.
function Codec.RosterCheck(size, items)
  if size ~= 10 and size ~= 20 and size ~= 40 then return nil, "size" end
  local seats, people, reserve = {}, {}, 0
  for _, it in ipairs(items or {}) do
    local g, s = tonumber(it.group) or -1, tonumber(it.seat) or -1
    if g == 0 and s == 0 then
      reserve = reserve + 1
    else
      if g < 1 or g > size / 5 or s < 1 or s > 5 then return nil, "seat" end
      if seats[g * 10 + s] then return nil, "taken" end
      seats[g * 10 + s] = true
    end
    if it.name ~= nil then
      if people[it.name] then return nil, "person" end
      people[it.name] = true
    end
  end
  if reserve > 20 then return nil, "reserve" end
  return true
end

-- Seats in group then seat order, then the reserve (group and seat 00). No checks beyond pack's part limit.
function Codec.EncodeRoster(r, gen, at)
  local items = {}
  local function add(x, place)
    items[#items + 1] = esc(x.name, CAP.character) .. "," .. place .. (SEAT_ROLE[x.role] or "-")
      .. (SEAT_ROLE[x.off] or "-") .. (CLASS[x.class] or "")
  end
  for g, grp in ipairs(r.groups or {}) do
    for s = 1, 5 do
      if grp[s] then add(grp[s], g .. s) end
    end
  end
  for _, x in ipairs(r.reserve or {}) do add(x, "00") end
  local base = "G," .. cell(gen) .. "," .. cell(at) .. ","
  local tail = "," .. cell(r.finish)
  local name = esc(chars(r.name, ROSTER_NAME), 4 * ROSTER_NAME)
  return pack("g" .. tostring(r.id), function(n)
    return base .. n .. tail .. "," .. cell(r.size) .. "," .. name .. "," .. cell(r.event)
  end, function(n) return base .. n .. tail end, items)
end

-- The head cells of a body, unparsed.
local function head(body)
  return split(string.match(body, "^[^;]*"), ",")
end

function Codec.Cancel(body, gen, at)
  return "X," .. cell(gen) .. "," .. cell(at) .. ",1," .. (head(body)[5] or "")
end

-- A cell above CEIL (2100-01-01) is refused: date() answers nil past year 3000, and 400 digits is inf (f1490).
local CEIL = 4102444800
local function num(s)
  if s == "" then return nil, true end
  if not string.match(s, "^%d+$") then return nil, false end
  local n = tonumber(s)
  if n > CEIL then return nil, false end
  return n, true
end

function Codec.Expired(body, now)
  local h = head(body)
  local finish = num(h[5] or "")
  if finish then return finish <= now - DAY end
  local gen = num(h[2] or "")
  if not gen then return true end
  if h[1] == "G" then return false end -- a roster with no end time is kept until cancelled
  return gen <= now - TEAM_DAYS * DAY
end

-- Unescape, then strip and cap again: a receiver never trusts the sender's encoder.
local function text(s, cap)
  local raw = unesc(s)
  if not raw then return nil end
  return clean(raw, cap)
end

function Codec.Decode(body)
  if type(body) ~= "string" or #body > RECV_MAX then return nil end
  local records = split(body, ";")
  local h = split(records[1], ",")
  local kind = h[1]
  if #h < 5 or (kind ~= "E" and kind ~= "L" and kind ~= "X" and kind ~= "G") then return nil end
  local gen = num(h[2])
  local at, okAt = num(h[3])
  local n = num(h[4])
  local finish, okFinish = num(h[5])
  if not gen or not okAt or not okFinish or not n or n < 1 or n > MAX_PARTS then return nil end
  local rec = { kind = kind, gen = gen, at = at, n = n, finish = finish, items = {} }
  if kind == "X" then
    if #records > 1 then return nil end
    return rec
  end
  if kind == "E" and #h >= 8 then
    local ok
    rec.team, rec.title = text(h[6], CAP.team), text(h[8], CAP.title)
    rec.start, ok = num(h[7])
    if not rec.team or not rec.title or not ok then return nil end
    -- h[9] is sr: unescaped with no cap, so ns.SrUrl is the only gate; a refused url is nil, the record kept.
    local sr = h[9] and unesc(h[9])
    rec.sr = sr and ns.SrUrl and ns.SrUrl(sr) or nil
  elseif kind == "L" and #h >= 7 then
    local ok
    rec.team = text(h[6], CAP.team)
    rec.colour, ok = num(h[7])
    if not rec.team or not ok then return nil end
  elseif kind == "G" and #h >= 8 then
    -- h[9] on are ignored (a later version's fields). The name is cut to 40 code points after the unescape.
    local raw = unesc(h[7])
    rec.size = num(h[6])
    if not rec.size or not raw then return nil end
    rec.name = clean(chars(raw, ROSTER_NAME), 4 * ROSTER_NAME)
    if h[8] ~= "" then
      if not string.match(h[8], "^%d+$") or #h[8] > 20 then return nil end
      rec.event = h[8]
    end
  elseif #h ~= 5 then
    return nil
  end
  for i = 2, #records do
    local f = split(records[i], ",")
    local character = text(f[1], CAP.character)
    if not character or #f < 2 then return nil end
    if kind == "E" then
      local code = f[2]
      local k = KIND_OF[string.sub(code, 3, 3)]
      if #code ~= 3 or not k then return nil end
      local discord = ""
      if f[3] then discord = text(f[3], CAP.discord) end
      if not discord then return nil end
      rec.items[#rec.items + 1] = { character = character, discord = discord,
        role = ROLE_OF[string.sub(code, 1, 1)] or "", class = CLASS_OF[string.sub(code, 2, 2)] or "", kind = k }
    elseif kind == "G" then
      -- an unknown role, off or class letter reads nil; cells after the code are ignored
      local code = f[2]
      local g, s = string.match(code, "^(%d)(%d)")
      if character == "" or not g or (#code ~= 4 and #code ~= 5) then return nil end
      rec.items[#rec.items + 1] = { name = character, group = tonumber(g), seat = tonumber(s),
        role = SEAT_ROLE[string.sub(code, 3, 3)], off = SEAT_ROLE[string.sub(code, 4, 4)],
        class = CLASS_OF[string.sub(code, 5, 5)] }
    else
      local k = (f[2] == "a" and "active") or (f[2] == "b" and "bench") or nil
      if not k then return nil end
      rec.items[#rec.items + 1] = { character = character, kind = k }
    end
  end
  -- a later part has no size: its places are checked against 40
  if kind == "G" and not Codec.RosterCheck(rec.size or 40, rec.items) then return nil end
  return rec
end
