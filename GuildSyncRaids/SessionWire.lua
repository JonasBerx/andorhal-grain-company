local _, ns = ...
if not ns.M then return end
-- SessionWire.lua: the raids_r wire text of a loot roll's open (O) and of an award (W). Pure: no client calls; only
-- string, table. The fields, caps and rules are in LOOT-SESSION-FORMAT.md.
-- Exports:
--   ns.SessionWire (SW), with the caps MAXTEXT, KEYMAX, WHOMAX, WHYMAX, ITEMMAX, MAXRESERVERS, MAXCOUNCIL, OFIELDS,
--   WFIELDS and:
--     SW.Unpack(text, key) -> msg | nil       key is the wire key rule (ns.Key in game)
--     SW.Pack(msg) -> text | nil
--     SW.Subject(msg) -> subject, version | nil
--   ns.RaidsR.O, ns.RaidsR.W = { unpack(text) -> msg | nil, subject = SW.Subject, handle, v = 1 }
-- The wire is hostile: Unpack checks the field count, every length and every number, and answers nil for anything
-- else. A reader needs at least the fields it knows and ignores any after them (unlike ReadyRules' exact count).
-- Nothing is sent yet, so the entries have no pack.

local SW = { MAXTEXT = 1000, KEYMAX = 48, WHOMAX = 60, WHYMAX = 200, ITEMMAX = 2147483647, MAXRESERVERS = 8,
  MAXCOUNCIL = 3, OFIELDS = 12, WFIELDS = 13 }
ns.SessionWire = SW

local RANGES = { [100] = true, [99] = true, [98] = true }
local KINDS = { R = true, S = true, C = true, N = true }
local HOWS = { ms = true, os = true, de = true, bank = true, sr = true, council = true }
local PLACES = "abcdefghi"

-- FSEP and LSEP, read from ReadyRules at call time; nil when it is missing.
local function seps()
  local R = ns.ReadyRules
  if type(R) ~= "table" or type(R.FSEP) ~= "string" or type(R.LSEP) ~= "string" then return nil end
  return R.FSEP, R.LSEP
end

-- The hub's wire key rule (CommWire.lua Wire.Key), a copy as in ReadyRules, so Pack needs no key function.
local function wireKey(name)
  if type(name) ~= "string" then return nil end
  local k = (string.match(name, "^([^-]*)") or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

local function split(s, sep)
  local out, from = {}, 1
  while true do
    local a = string.find(s, sep, from, true)
    if not a then out[#out + 1] = string.sub(s, from) return out end
    out[#out + 1] = string.sub(s, from, a - 1)
    from = a + 1
  end
end

-- A decimal integer of at most `digits` digits, no sign, no leading zero (but "0"), within lo..hi; or nil.
local function int(s, lo, hi, digits)
  if type(s) ~= "string" or #s < 1 or #s > (digits or 10) then return nil end
  if not (string.match(s, "^[1-9]%d*$") or s == "0") then return nil end
  local v = tonumber(s)
  if v < lo or (hi and v > hi) then return nil end
  return v
end

-- A server time: 1-10 digits.
local function time(s) return int(s, 0, nil, 10) end

-- The item's suffix: "" -> false (no suffix), or an optional "-" and 1-10 digits, not 0; nil when bad.
local function suffix(s)
  if s == "" then return false end
  if type(s) ~= "string" then return nil end
  local neg, digits = string.match(s, "^(%-?)([1-9]%d*)$")
  if not digits or #digits > 10 then return nil end
  local v = tonumber(digits)
  return neg == "-" and -v or v
end

-- An optional field: "" -> false, else check(s) (nil when bad).
local function opt(s, check)
  if s == "" then return false end
  return check(s)
end

local function orNil(v) if v == false then return nil end return v end

-- wire text -> msg, or nil. key is the wire key rule (ns.Key in game).
function SW.Unpack(text, key)
  if type(text) ~= "string" or type(key) ~= "function" or #text > SW.MAXTEXT then return nil end
  local FSEP, LSEP = seps()
  if not FSEP then return nil end
  local f = split(text, FSEP)
  local function keyField(s)
    if #s > SW.KEYMAX or string.find(s, LSEP, 1, true) or key(s) ~= s then return nil end
    return s
  end
  local function keys(s, max)
    local out = {}
    if s == "" then return out end
    for _, k in ipairs(split(s, LSEP)) do
      if not keyField(k) then return nil end
      out[#out + 1] = k
    end
    if #out > max then return nil end
    return out
  end
  if f[1] == "O" and #f >= SW.OFIELDS then
    local sfx = suffix(f[6])
    if sfx == nil then return nil end
    local ranges, seen = {}, {}
    for _, s in ipairs(split(f[8], LSEP)) do
      local r = int(s, 98, 100, 3)
      if not r or not RANGES[r] or seen[r] then return nil end
      seen[r] = true
      ranges[#ranges + 1] = r
    end
    if #ranges < 1 or #ranges > 3 then return nil end
    local msg = { t = "O", by = keyField(f[2]), session = time(f[3]), n = int(f[4], 1, 999, 3),
      item = int(f[5], 1, SW.ITEMMAX, 10), suffix = orNil(sfx), count = int(f[7], 1, 9, 1), ranges = ranges,
      closes = time(f[9]), kind = KINDS[f[10]] and f[10] or nil, reservers = keys(f[11], SW.MAXRESERVERS),
      council = keys(f[12], SW.MAXCOUNCIL) }
    if not (msg.by and msg.session and msg.n and msg.item and msg.count and msg.closes and msg.kind and msg.reservers
      and msg.council) then return nil end
    return msg
  elseif f[1] == "W" and #f >= SW.WFIELDS then
    local sfx = suffix(f[7])
    local roll = opt(f[10], function(s) return int(s, 1, 100, 3) end)
    local edited = opt(f[13], time)
    local how = HOWS[f[9]] and f[9] or nil
    if sfx == nil or roll == nil or edited == nil or not how then return nil end
    local who = f[8]
    -- s4: a name never holds "|" (escape codes, links, textures) or a control byte; why may hold "|", not a control byte
    if #who > SW.WHOMAX or (who == "" and how ~= "bank") or string.find(who, "[%z\1-\31|]") or #f[11] > SW.WHYMAX
      or string.find(f[11], "[%z\1-\31]") then return nil end
    local msg = { t = "W", by = keyField(f[2]), session = time(f[3]), n = int(f[4], 1, 999, 3), at = time(f[5]),
      item = int(f[6], 1, SW.ITEMMAX, 10), suffix = orNil(sfx), who = who ~= "" and who or nil, how = how,
      roll = orNil(roll), why = f[11], place = int(f[12], 1, 9, 1), edited = orNil(edited) }
    if not (msg.by and msg.session and msg.n and msg.at and msg.item and msg.place) then return nil end
    return msg
  end
  return nil
end

-- msg -> wire text, or nil. A field holding FSEP, a list entry holding LSEP, or anything Unpack would refuse is never
-- packed: the text is checked by Unpack with the wire key rule before it is answered.
function SW.Pack(msg)
  if type(msg) ~= "table" then return nil end
  local FSEP, LSEP = seps()
  if not FSEP then return nil end
  local bad = false
  local function field(v)
    if v == nil then return "" end
    local s = tostring(v)
    if string.find(s, FSEP, 1, true) then bad = true end
    return s
  end
  local function list(t)
    if t == nil then return "" end
    if type(t) ~= "table" then bad = true return "" end
    local out = {}
    for i, v in ipairs(t) do
      local s = field(v)
      if string.find(s, LSEP, 1, true) then bad = true end
      out[i] = s
    end
    return table.concat(out, LSEP)
  end
  local fields
  if msg.t == "O" then
    fields = { "O", field(msg.by), field(msg.session), field(msg.n), field(msg.item), field(msg.suffix),
      field(msg.count), list(msg.ranges), field(msg.closes), field(msg.kind), list(msg.reservers), list(msg.council) }
  elseif msg.t == "W" then
    fields = { "W", field(msg.by), field(msg.session), field(msg.n), field(msg.at), field(msg.item), field(msg.suffix),
      field(msg.who), field(msg.how), field(msg.roll), field(msg.why), field(msg.place), field(msg.edited) }
  else
    return nil
  end
  if bad then return nil end
  local text = table.concat(fields, FSEP)
  if not SW.Unpack(text, wireKey) then return nil end
  return text
end

-- msg -> subject (at most 64 bytes), version; nil for anything but an O or a W. O: "<session>.<n> <by>", version
-- closes. W: "<session>.<n><p> <by>", p the place as a letter (1 = a ... 9 = i), version edited when set, else at.
-- Subjects are kept per kind by the hub (the header type is raids_r.O or raids_r.W), so no kind letter is needed.
function SW.Subject(msg)
  if type(msg) ~= "table" then return nil end
  local head = tostring(msg.session) .. "." .. tostring(msg.n)
  if msg.t == "O" then
    return head .. " " .. tostring(msg.by), msg.closes
  elseif msg.t == "W" then
    local p = type(msg.place) == "number" and msg.place >= 1 and msg.place <= 9 and math.floor(msg.place) == msg.place
      and string.sub(PLACES, msg.place, msg.place)
    if not p then return nil end
    return head .. p .. " " .. tostring(msg.by), msg.edited or msg.at
  end
  return nil
end

-- An entry for one kind: unpack answers only that kind; no pack, and handle does nothing.
local function entry(kind)
  return {
    unpack = function(text)
      local msg = SW.Unpack(text, ns.Key)
      if type(msg) == "table" and msg.t == kind then return msg end
      return nil
    end,
    subject = SW.Subject,
    handle = function() end,
    v = 1,
  }
end

if type(ns.RaidsR) == "table" then
  ns.RaidsR.O = entry("O")
  ns.RaidsR.W = entry("W")
end
