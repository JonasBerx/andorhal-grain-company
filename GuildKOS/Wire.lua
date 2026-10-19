-- GuildKOS Wire: addon messages, list chunks, the assembler and send results.
-- Message formats are defined in addon/KOS-FORMAT.md. Pure Lua 5.1, no client calls; time is passed in.
local _, ns = ...
local Wire = {}
ns.Wire = Wire

local Codec = ns.Codec

Wire.PREFIX = "GuildKOS"
Wire.MAX = 250                 -- bytes per message text; the client limit is 255
Wire.MAX_CHUNKS = 64           -- the largest n a receiver buffers; Codec.MAX_TEXT always fits
Wire.PARTIAL_TIMEOUT = 30      -- seconds after a partial's last chunk
Wire.CHUNK_GAP = 1             -- seconds between pushed chunks
Wire.RETRY_GAP = 1             -- seconds before a throttled chunk is sent again
Wire.MAX_TRIES = 3             -- retries of one throttled chunk
Wire.SWEEP_EVERY = 10          -- seconds between asm:Expired sweeps

-- s cut to at most maxBytes without splitting a UTF-8 character.
function Wire.TruncUtf8(s, maxBytes)
  if maxBytes < 0 then maxBytes = 0 end
  if #s <= maxBytes then return s end
  -- back off while the next byte is a continuation byte (10xxxxxx), at most 3 bytes: in valid UTF-8 a lead byte
  -- is never further back. No lead byte found (not UTF-8): cut at maxBytes, so a caller always moves forward.
  for back = 0, 3 do
    local cut = maxBytes - back
    if cut == 0 then return "" end
    local c = s:byte(cut + 1)
    if c < 0x80 or c >= 0xC0 then return s:sub(1, cut) end
  end
  return s:sub(1, maxBytes)
end

local function field(s)
  return ((s or ""):gsub(":", " "))
end

function Wire.PackSighting(spotter, target, zone, subzone)
  local head = "S:" .. field(spotter) .. ":" .. field(target) .. ":"
  local room = Wire.MAX - #head - 1
  local z = Wire.TruncUtf8(field(zone), math.floor(room / 2))
  local sz = Wire.TruncUtf8(field(subzone), room - #z)
  return head .. z .. ":" .. sz
end

function Wire.PackOffer(version)
  return "O:" .. (version or 0)
end

-- { "L:<version>:<i>:<n>:<piece>", ... } | nil when the text is too big.
function Wire.SplitList(version, text)
  if #text > Codec.MAX_TEXT then return nil end
  local prefix = "L:" .. version .. ":"
  local digits = 1
  while true do
    local room = Wire.MAX - #prefix - 2 * digits - 2
    local pieces, pos = {}, 1
    while pos <= #text do
      local piece = Wire.TruncUtf8(text:sub(pos, pos + room), room)
      pieces[#pieces + 1] = piece
      pos = pos + #piece
    end
    local n = #pieces
    if #tostring(n) <= digits then
      local out = {}
      for i, piece in ipairs(pieces) do out[i] = prefix .. i .. ":" .. n .. ":" .. piece end
      return out
    end
    digits = digits + 1
  end
end

function Wire.Unpack(text)
  if type(text) ~= "string" then return nil end
  local kind = text:sub(1, 2)
  if kind == "S:" then
    local spotter, target, zone, subzone = text:match("^S:([^:]*):([^:]*):([^:]*):([^:]*)$")
    if not spotter or spotter == "" or target == "" then return nil end
    return { kind = "S", spotter = spotter, target = target, zone = zone, subzone = subzone }
  elseif kind == "O:" then
    local v = text:match("^O:(%d+)$")
    if not v then return nil end
    return { kind = "O", version = tonumber(v) }
  elseif kind == "L:" then
    local v, i, n, piece = text:match("^L:(%d+):(%d+):(%d+):(.*)$")
    if not v then return nil end
    return { kind = "L", version = tonumber(v), i = tonumber(i), n = tonumber(n), piece = piece }
  end
  return nil
end

-- Assembler: one partial per sender.
local Assembler = {}
Assembler.__index = Assembler

function Wire.NewAssembler()
  return setmetatable({ partials = {}, expired = {} }, Assembler)
end

local function isInt(x) return type(x) == "number" and x == math.floor(x) end

function Assembler:Add(senderKey, chunk, now)
  if type(chunk) ~= "table" or chunk.kind ~= "L" or type(chunk.piece) ~= "string" then return nil end
  local v, i, n = chunk.version, chunk.i, chunk.n
  if not isInt(v) or not isInt(i) or not isInt(n) then return nil end
  if n < 1 or n > Wire.MAX_CHUNKS or i < 1 or i > n then return nil end

  local p = self.partials[senderKey]
  if p and now - p.last >= Wire.PARTIAL_TIMEOUT then
    self.expired[#self.expired + 1] = { sender = senderKey, version = p.version }
    p = nil
    self.partials[senderKey] = nil
  end
  if p then
    if v < p.version then return nil end
    if v > p.version then p = nil end
  end
  if not p then
    p = { version = v, n = n, pieces = {}, count = 0, last = now }
    self.partials[senderKey] = p
  end
  if n ~= p.n then return nil end

  p.last = now
  if not p.pieces[i] then
    p.pieces[i] = chunk.piece
    p.count = p.count + 1
  end
  if p.count < p.n then return nil end
  self.partials[senderKey] = nil
  return table.concat(p.pieces, "", 1, p.n)
end

function Assembler:Expired(now)
  local out = self.expired
  self.expired = {}
  for sender, p in pairs(self.partials) do
    if now - p.last >= Wire.PARTIAL_TIMEOUT then
      out[#out + 1] = { sender = sender, version = p.version }
      self.partials[sender] = nil
    end
  end
  return out
end

-- "ok" | "retry" | "lockdown" | "abort"; tries is 1 for the first send.
function Wire.SendOutcome(result, tries)
  if result == 0 then return "ok" end
  if result == 11 then return "lockdown" end
  if (result == 3 or result == 8) and tries <= Wire.MAX_TRIES then return "retry" end
  return "abort"
end

return Wire
