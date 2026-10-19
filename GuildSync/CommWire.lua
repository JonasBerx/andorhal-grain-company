-- CommWire: the GuildSync comm core's pure codec (plan r-20261005-guildsync-comm-core, section 1): escaping, Hash,
-- Key, the chunk header, chunking, the assembler, send results and the retry schedule.
-- Pure Lua 5.1, no client calls; time is passed in. Copied from CraftWire.lua and CraftStore.Key (those keep their
-- own code), with proto and T as parameters.
local _, ns = ...
ns.Comm = ns.Comm or {}
local Wire = ns.Comm.Wire or {}
ns.Comm.Wire = Wire

Wire.PROTOCOL = 1
Wire.MAX = 250                 -- bytes per message text, header included; the client limit is 255
Wire.MAX_CHUNKS = 64           -- the largest n a receiver buffers
Wire.PARTIAL_TIMEOUT = 30      -- seconds after a partial's last chunk
Wire.MAX_PARTIALS = 4          -- open partials per sender
Wire.MAX_TRIES = 3             -- retries of one throttled chunk
Wire.FUTURE = 300              -- seconds a time may lie ahead of now (f1078)
Wire.MAX_MID = 9999
Wire.ATOM_MAX = 64             -- bytes in a header subject

-- Adler-32 of the bytes, as "%04x%04x" of b, a (copy of CraftWire.Hash).
function Wire.Hash(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

-- Character name -> key: realm cut at the first "-", lowercased, trimmed, inner whitespace collapsed. nil if empty.
-- (copy of CraftStore.Key)
function Wire.Key(name)
  if type(name) ~= "string" then return nil end
  local k = (name:match("^([^-]*)") or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

-- s cut to at most maxBytes without splitting a UTF-8 character (copy of CraftWire's truncUtf8).
function Wire.TruncUtf8(s, maxBytes)
  if maxBytes < 0 then maxBytes = 0 end
  if #s <= maxBytes then return s end
  for back = 0, 3 do
    local cut = maxBytes - back
    if cut == 0 then return "" end
    local c = s:byte(cut + 1)
    if c < 0x80 or c >= 0xC0 then return s:sub(1, cut) end
  end
  return s:sub(1, maxBytes)
end

local KEEP = { [13] = true, [10] = true }
local function escapeByte(c)
  local b = c:byte()
  if b < 32 and not KEEP[b] then return "" end
  return string.format("%%%02X", b)
end

function Wire.Escape(s)
  return (tostring(s or ""):gsub("[%z\1-\31%%:;,=/|]", escapeByte))
end

-- nil when a "%" is not followed by two hex digits. Bytes below 0x20, escaped or raw, are dropped.
function Wire.Unescape(s)
  if s:gsub("%%%x%x", ""):find("%", 1, true) then return nil end
  local out = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return (out:gsub("[%z\1-\31]", ""))
end

-- ---------- chunks ----------

-- Split(proto, mid, t, subject, version, logical)
--   -> { "<proto>:<mid>:<i>:<n>:<t>:<E(subject)>:<version>:<piece>", ... } | nil when over MAX_CHUNKS.
function Wire.Split(proto, mid, t, subject, version, logical)
  local tail = ":" .. t .. ":" .. Wire.Escape(subject) .. ":" .. tostring(version) .. ":"
  local head = proto .. ":" .. mid .. ":"
  local digits = 1
  while true do
    local room = Wire.MAX - #head - #tail - 2 * digits - 1
    if room < 4 then return nil end
    local pieces, pos = {}, 1
    while pos <= #logical do
      local piece = Wire.TruncUtf8(logical:sub(pos, pos + room), room)
      if piece == "" then return nil end
      pieces[#pieces + 1] = piece
      pos = pos + #piece
      if #pieces > Wire.MAX_CHUNKS then return nil end
    end
    local count = #pieces
    if #tostring(count) <= digits then
      local out = {}
      for i, piece in ipairs(pieces) do out[i] = head .. i .. ":" .. count .. tail .. piece end
      return out
    end
    digits = digits + 1
  end
end

-- Header(text, ownProto) -> { proto, mid, i, n, t, subject, version, piece } | nil, why ("newer" | "format").
-- Accepts any proto from 1 up to ownProto (default PROTOCOL): an older sender is never dropped. No assembly.
function Wire.Header(text, ownProto)
  ownProto = ownProto or Wire.PROTOCOL
  if type(text) ~= "string" then return nil, "format" end
  local proto, mid, i, count, t, subject, version, piece =
    text:match("^(%d+):(%d+):(%d+):(%d+):([^:]*):([^:]*):([^:]*):(.*)$")
  if not proto then return nil, "format" end
  proto, mid, i, count = tonumber(proto), tonumber(mid), tonumber(i), tonumber(count)
  if proto > ownProto then return nil, "newer" end
  if proto < 1 then return nil, "format" end
  if mid < 1 or mid > Wire.MAX_MID or count < 1 or count > Wire.MAX_CHUNKS or i < 1 or i > count then
    return nil, "format"
  end
  subject = Wire.Unescape(subject)
  if not subject or #subject > Wire.ATOM_MAX or t == "" then return nil, "format" end
  if version == "0" then version = 0 end
  return { proto = proto, mid = mid, i = i, n = count, t = t, subject = subject, version = version, piece = piece }
end

-- ---------- assembler: partials keyed by (sender, mid), at most MAX_PARTIALS per sender ----------

local Assembler = {}
Assembler.__index = Assembler

function Wire.NewAssembler()
  return setmetatable({ senders = {}, seq = 0 }, Assembler)
end

-- asm:Has(senderKey, mid): a partial is held for it (timed out or not; Add drops those).
function Assembler:Has(senderKey, mid)
  local open = self.senders[senderKey]
  return open ~= nil and open[mid] ~= nil
end

-- asm:Drop(senderKey, mid): forgets its partial, if any.
function Assembler:Drop(senderKey, mid)
  local open = self.senders[senderKey]
  if not open then return end
  open[mid] = nil
  if next(open) == nil then self.senders[senderKey] = nil end
end

-- asm:Add(senderKey, text, now, ownProto) -> logical | nil, why
function Assembler:Add(senderKey, text, now, ownProto)
  local h, why = Wire.Header(text, ownProto)
  if not h then return nil, why end
  local open = self.senders[senderKey]
  if open then
    for mid, p in pairs(open) do
      if now - p.last >= Wire.PARTIAL_TIMEOUT then open[mid] = nil end
    end
  end
  if h.n == 1 then
    if open then open[h.mid] = nil end
    return h.piece
  end
  if not open then
    open = {}
    self.senders[senderKey] = open
  end
  local p = open[h.mid]
  if p and (p.n ~= h.n or p.t ~= h.t or p.subject ~= h.subject or p.version ~= h.version) then
    self:Drop(senderKey, h.mid) -- a chunk that disagrees with its mid's first chunk: drop the partial, seed none
    return nil, "mismatch"
  end
  if not p then
    local count, oldestMid, oldestSeq = 0, nil, nil
    for mid, q in pairs(open) do
      count = count + 1
      if not oldestSeq or q.seq < oldestSeq then oldestMid, oldestSeq = mid, q.seq end
    end
    if count >= Wire.MAX_PARTIALS then open[oldestMid] = nil end
    self.seq = self.seq + 1
    p = { n = h.n, t = h.t, subject = h.subject, version = h.version, pieces = {}, count = 0, seq = self.seq, last = now }
    open[h.mid] = p
  end
  p.last = now
  if not p.pieces[h.i] then
    p.pieces[h.i] = h.piece
    p.count = p.count + 1
  end
  if p.count < p.n then return nil end
  open[h.mid] = nil
  if next(open) == nil then self.senders[senderKey] = nil end
  return table.concat(p.pieces, "", 1, p.n)
end

-- ---------- send results ----------

-- "ok" | "retry" | "lockdown" | "abort"; tries is 1 for the first send.
function Wire.SendOutcome(result, tries)
  if result == 0 then return "ok" end
  if result == 11 then return "lockdown" end
  if (result == 3 or result == 8) and tries <= Wire.MAX_TRIES then return "retry" end
  return "abort"
end

-- Seconds before the next try after a 3 or 8: 1, 2, 4 for tries 1, 2, 3 (plan section 5).
function Wire.RetryDelay(tries)
  return 2 ^ (tries - 1)
end

return Wire
