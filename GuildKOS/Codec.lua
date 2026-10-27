-- GuildKOS Codec: decodes the kill-on-sight list string.
-- The format is defined in addon/KOS-FORMAT.md, and only there. website/src/lib/kos.js encodes it.
-- Pure Lua 5.1, no client calls.
local _, ns = ...
local Codec = {}
ns.Codec = Codec

Codec.MAX_TEXT = 12800

-- Adler-32 of the bytes, as "%04x%04x" of b, a.
function Codec.Checksum(body)
  local a, b = 1, 0
  for i = 1, #body do
    a = (a + body:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

-- Split on a plain separator, keeping empty fields (no gmatch empty-match quirk).
local function split(s, sep, limit)
  local out, init = {}, 1
  while true do
    if limit and #out == limit - 1 then out[#out + 1] = s:sub(init); return out end
    local at = s:find(sep, init, true)
    if not at then out[#out + 1] = s:sub(init); return out end
    out[#out + 1] = s:sub(init, at - 1)
    init = at + 1
  end
end

-- nil when a "%" is not followed by two hex digits.
local function unescape(s)
  if s:gsub("%%%x%x", ""):find("%", 1, true) then return nil end
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function integer(s)
  if not s:find("^%d+$") then return nil end
  return tonumber(s)
end

local MAX_VERSION_DIGITS = 10 -- a longer version can't be a real date (D86)

-- Decode(text) --> { version, text, targets } | nil, "format" | "cut"
function Codec.Decode(text)
  if type(text) ~= "string" then return nil, "format" end
  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "format" end

  local parts = split(text, ":", 5)
  if parts[1] ~= "KOS1" then return nil, "format" end
  if #parts < 5 then return nil, "cut" end
  local body = parts[5]
  if parts[4]:lower() ~= Codec.Checksum(body) then return nil, "cut" end

  if #parts[2] > MAX_VERSION_DIGITS then return nil, "format" end
  local version, count = integer(parts[2]), integer(parts[3])
  if not version or not count then return nil, "format" end

  local targets = {}
  if body ~= "" then
    for _, row in ipairs(split(body, ";")) do
      local f = split(row, "/")
      if #f < 6 then return nil, "format" end
      local id = integer(f[1])
      local race, class, zone, why = unescape(f[3]), unescape(f[4]), unescape(f[5]), unescape(f[6])
      if not id or not race or not class or not zone or not why then return nil, "format" end
      targets[#targets + 1] = { id = id, target = f[2], race = race, class = class, zone = zone, why = why }
    end
  end
  if #targets ~= count then return nil, "format" end

  return { version = version, text = text, targets = targets }
end

return Codec
