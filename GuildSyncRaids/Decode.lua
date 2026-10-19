local _, ns = ...
if not ns.M then return end

-- The GSR1 raid calendar decoder (discord-setup/RAIDCAL-FORMAT.md). Pure: string and table only, no client calls.
-- ns.Decode(text) -> cal | nil, why   (why: "size" | "prefix" | "version" | "cut" | "checksum" | "format")
-- Decoded cells keep a raw "|": doubling it is display work (GuildSync.Escape), not the decoder's.

local BOM = "\239\187\191"
local MIN = { E = 5, P = 6, L = 3 } -- fields after the tag
local LAST = { E = 7, P = 7, L = 5 } -- the last field a v1 decoder knows (E url, L colour); later ones are ignored
local MAX_BYTES = 131072 -- the largest paste the decoder takes (f1494)
local CEIL = 4102444800 -- 2100-01-01: a later time is refused (date() answers nil past year 3000; f1490)

local function adler(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end
ns.Adler = adler -- Store.lua's round hash

-- Outer whitespace, CR, LF and a BOM, at either end, in any mix.
local function trim(s)
  local prev
  repeat
    prev = s
    s = s:gsub("^%s+", "")
    if s:sub(1, 3) == BOM then s = s:sub(4) end
  until s == prev
  return (s:gsub("%s+$", ""))
end

local function split(s, sep)
  local out = {}
  for x in (s .. sep):gmatch("([^%" .. sep .. "]*)%" .. sep) do out[#out + 1] = x end
  return out
end

local function isInt(s) return s:find("^%d+$") ~= nil end

-- One escaped cell -> its raw bytes, or nil on a "%" not followed by two hex digits.
local function unesc(s)
  if (s:gsub("%%%x%x", "")):find("%", 1, true) then return nil end
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- One escaped cell -> clean text (C0 and DEL stripped), or nil on a bad escape.
local function cell(s)
  s = unesc(s)
  if not s then return nil end
  return (s:gsub("[%z\1-\31\127]", ""))
end

-- A soft-reserve url, or nil: https://, no whitespace, no control byte, no "|", at most 200 bytes.
-- The only gate for sr (Codec.lua uses it too); it checks the raw bytes, never a stripped copy.
function ns.SrUrl(s)
  if type(s) ~= "string" or #s > 200 or s:sub(1, 8) ~= "https://" then return nil end
  if s:find("[%s%z\1-\31\127|]") then return nil end
  -- softres.it is the only soft reserve site (host compared case-insensitively; a bare host has no raid).
  if string.lower(s:sub(1, 19)) ~= "https://softres.it/" then return nil end
  -- Printable ASCII only (33-126): no bidi controls, no-break spaces or other look-alike bytes.
  if s:find("[^\33-\126]") then return nil end
  -- No userinfo: an @ before the first /, ? or # after "https://" would hide the real host.
  if s:sub(9):match("^[^/?#]*"):find("@", 1, true) then return nil end
  -- Every % starts a two-hex-digit escape.
  for i in s:gmatch("()%%") do
    if not s:sub(i + 1, i + 2):match("^%x%x$") then return nil end
  end
  return s
end

local function list(s)
  local out = {}
  if s == "" then return out end
  for _, item in ipairs(split(s, "+")) do
    local v = cell(item)
    if not v then return nil end
    out[#out + 1] = v
  end
  return out
end

local function int(s) return isInt(s) and tonumber(s) or nil end
local function late(s) local n = int(s); return n ~= nil and n > CEIL end

local function colour(s)
  local n = int(s)
  if n and n >= 1 and n <= 4 then return n end
  return nil
end

function ns.Decode(text)
  if type(text) ~= "string" then return nil, "prefix" end
  if #text > MAX_BYTES then return nil, "size" end
  text = trim(text)
  local version = text:match("^GSR(%d+):")
  if not version then return nil, "prefix" end
  if version ~= "1" then return nil, "version" end
  local gen, at, count, check, body = text:match("^GSR1:([^:]*):([^:]*):([^:]*):([^:]*):(.*)$")
  if not gen then return nil, "cut" end
  if check:lower() ~= adler(body) then return nil, "checksum" end
  if not isInt(gen) or not isInt(count) or (at ~= "" and not isInt(at)) then return nil, "format" end
  if late(gen) or late(at) then return nil, "format" end

  local records = body == "" and {} or split(body, ";")
  if tonumber(count) ~= #records then return nil, "format" end

  local cal = { generatedAt = tonumber(gen), dataAt = int(at), count = #records, events = {}, teams = {} }
  local byId = {}
  for _, rec in ipairs(records) do
    local raw = split(rec, ",")
    local kind = raw[1]
    if MIN[kind] then
      if #raw - 1 < MIN[kind] then return nil, "format" end
      local f = {}
      for i = 2, math.min(#raw, LAST[kind]) do
        if kind == "L" and (i == 3 or i == 4) then
          f[i] = list(raw[i])
        else
          f[i] = cell(raw[i])
        end
        if f[i] == nil then return nil, "format" end
      end
      if kind == "E" then
        if late(f[5]) or late(f[6]) then return nil, "format" end
        local ev = { id = f[2], team = f[3], title = f[4], start = int(f[5]), finish = int(f[6]),
          url = f[7] or "", signups = {} }
        cal.events[#cal.events + 1] = ev
        byId[ev.id] = ev
      elseif kind == "P" then
        local ev = byId[f[2]]
        if ev then
          ev.signups[#ev.signups + 1] = { character = f[3], discord = f[4], role = f[5], class = f[6], kind = f[7] }
        end
      else
        cal.teams[#cal.teams + 1] = { name = f[2], active = f[3], bench = f[4] or {}, colour = colour(f[5] or "") }
      end
    elseif kind == "S" and #raw >= 3 then
      -- S,<event>,<url>: never fatal, a bad one is skipped; fields after the url are ignored.
      local ev = byId[cell(raw[2]) or ""]
      local url = ns.SrUrl(unesc(raw[3]))
      if ev and url then ev.sr = url end
    end
  end
  return cal
end
