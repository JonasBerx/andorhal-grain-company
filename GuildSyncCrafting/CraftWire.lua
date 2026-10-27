-- GuildSync CraftWire: the crafting logical messages (protocol 1): escaping, pack/unpack, subjects,
-- send results and Hash. The hub's comm core carries them (chunks, assembler and prefix are the hub's).
-- Pure Lua 5.1, no client calls; time is passed in. Shapes copied from addon/GuildKOS/Wire.lua and Codec.lua.
local _, ns = ...
local CraftWire = {}
ns.CraftWire = CraftWire

CraftWire.PROTOCOL = 1
CraftWire.MAX = 250                 -- bytes per message text, header included; the client limit is 255
CraftWire.MAX_TRIES = 3             -- retries of one throttled chunk
CraftWire.FUTURE = 300              -- seconds a time may lie ahead of now
CraftWire.NAME_MAX = 48             -- bytes in a name atom (byName, claim/drop name, C/X name, P name and class)
CraftWire.MAX_PN = 8                -- parts per D or B digest
CraftWire.INT_DIGITS = 12           -- digits in an integer field
CraftWire.ATOM_MAX = 64             -- bytes in a header subject, a D entry key or a B entry id (f1070)

local LIMITS = { qtyMin = 1, qtyMax = 200, tipMax = 9999, note = 80 }
local HOURS = { [1] = true, [4] = true, [12] = true, [24] = true, [48] = true }
local X_KINDS = { drop = true, release = true, done = true, cancel = true }
local FINAL_KINDS = { done = true, cancel = true }

-- Adler-32 of the bytes, as "%04x%04x" of b, a (copied from GuildKOS Codec.Checksum).
function CraftWire.Hash(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

-- ---------- atoms ----------

local KEEP = { [13] = true, [10] = true }
local function escapeByte(c)
  local b = c:byte()
  if b < 32 and not KEEP[b] then return "" end
  return string.format("%%%02X", b)
end

function CraftWire.Escape(s)
  return (tostring(s or ""):gsub("[%z\1-\31%%:;,=/|]", escapeByte))
end

-- nil when a "%" is not followed by two hex digits. Bytes below 0x20, escaped or raw, are dropped (f1062).
function CraftWire.Unescape(s)
  if s:gsub("%%%x%x", ""):find("%", 1, true) then return nil end
  local out = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return (out:gsub("[%z\1-\31]", ""))
end

-- Split on a plain separator, keeping empty fields.
local function split(s, sep)
  local out, init = {}, 1
  while true do
    local at = s:find(sep, init, true)
    if not at then out[#out + 1] = s:sub(init); return out end
    out[#out + 1] = s:sub(init, at - 1)
    init = at + 1
  end
end

local function isInt(x) return type(x) == "number" and x == math.floor(x) and x >= 0 end
local function isStr(x) return type(x) == "string" and x ~= "" end
-- A character name or class atom: at most NAME_MAX bytes, no byte below 0x20, no DEL, no "|" (f1061).
local function isNameText(x)
  return type(x) == "string" and #x <= CraftWire.NAME_MAX and not x:find("[%z\1-\31\127|]")
end
local function isName(x) return isNameText(x) and x ~= "" end
local function isHash(x) return type(x) == "string" and x:find("^%x%x%x%x%x%x%x%x$") ~= nil end
-- Today's stored recipe list: "spell=item" joined by "/", decimal ids of at most INT_DIGITS digits, or "".
local function isPacked(x)
  if type(x) ~= "string" then return false end
  if x == "" then return true end
  for row in (x .. "/"):gmatch("([^/]*)/") do
    local s, i = row:match("^(%d+)=(%d+)$")
    if not s or #s > CraftWire.INT_DIGITS or #i > CraftWire.INT_DIGITS then return false end
  end
  return x:sub(-1) ~= "/"
end

-- The compact P recipe field (plan B, d422 q351): the rows sorted by spell, each "delta=item" in base 36
-- (lower case), the first delta from 0, "0" for no item, joined by "/". Decode rebuilds the decimal packed form.
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function base36(v)
  if v == 0 then return "0" end
  local out = ""
  while v > 0 do
    local d = v % 36
    out = B36:sub(d + 1, d + 1) .. out
    v = (v - d) / 36
  end
  return out
end
local function encodePacked(packed)
  if packed == "" then return "" end
  local rows = {}
  for row in (packed .. "/"):gmatch("([^/]*)/") do
    local s, i = row:match("^(%d+)=(%d+)$")
    rows[#rows + 1] = { tonumber(s), tonumber(i) }
  end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  local out, last = {}, 0
  for k, r in ipairs(rows) do
    out[k] = base36(r[1] - last) .. "=" .. base36(r[2])
    last = r[1]
  end
  return table.concat(out, "/")
end

-- A decode failure inside a field reader: caught by Unpack and turned into "format".
local FORMAT = {}
local function int(s)
  if not s or not s:find("^%d+$") or #s > CraftWire.INT_DIGITS then error(FORMAT) end
  return tonumber(s)
end
-- A base-36 id or delta of the compact P field: at most 8 digits, and the result within INT_DIGITS decimal digits.
local INT_MAX = 10 ^ CraftWire.INT_DIGITS - 1
local function b36(s)
  if not s or not s:find("^[0-9a-z]+$") or #s > 8 then error(FORMAT) end
  local v = 0 -- by hand: Lua 5.1's tonumber(s, 36) goes through a C long, 32 bits on Windows
  for k = 1, #s do v = v * 36 + (B36:find(s:sub(k, k), 1, true) - 1) end
  if v > INT_MAX then error(FORMAT) end
  return v
end
-- f4542: ids strictly increase after the first row (the encoder never writes a zero delta), and one profession holds
-- at most MAX_ROWS rows (a Classic profession has a few hundred recipes).
local MAX_ROWS = 1000
CraftWire.MAX_ROWS = MAX_ROWS -- the sender cuts its own professions to it (CraftSync ownProfs)
local function decodePacked(s)
  if s == "" then return "" end
  local out, last = {}, 0
  for row in (s .. "/"):gmatch("([^/]*)/") do
    local d, i = row:match("^([^=]*)=([^=]*)$")
    local delta = b36(d)
    if (#out > 0 and delta == 0) or #out >= MAX_ROWS then error(FORMAT) end
    last = last + delta
    if last > INT_MAX then error(FORMAT) end
    out[#out + 1] = string.format("%.0f=%.0f", last, b36(i))
  end
  return table.concat(out, "/")
end
local function optInt(s)
  if s == "" then return nil end
  return int(s)
end
local function atom(s)
  local v = s and CraftWire.Unescape(s)
  if not v then error(FORMAT) end
  return v
end
local function optAtom(s)
  if s == "" then return nil end
  return atom(s)
end
local function list(s, read)
  local out = {}
  if s == nil then error(FORMAT) end
  if s == "" then return out end
  for _, row in ipairs(split(s, ";")) do out[#out + 1] = read(split(row, ",")) end
  return out
end

local E = CraftWire.Escape
local function n(x) return x == nil and "" or tostring(x) end
local function o(x) return x == nil and "" or E(x) end

-- ---------- per type: encode, decode, check ----------
-- check(msg, now) -> nil | "format" | "limit" | "future"

local function future(now, ...)
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if t and t > now + CraftWire.FUTURE then return true end
  end
  return false
end

local function pairList(entries, a, b, encA, encB)
  local out = {}
  for i, e in ipairs(entries or {}) do out[i] = encA(e[a]) .. "," .. encB(e[b]) end
  return table.concat(out, ";")
end

local function checkRequest(m, now)
  if not (isStr(m.id) and isName(m.byName) and isStr(m.what) and isInt(m.qty) and type(m.mats) == "boolean"
          and isInt(m.tip) and isInt(m.postedAt) and isInt(m.expiresAt)) then return "format" end
  if m.note ~= nil and type(m.note) ~= "string" then return "format" end
  if #m.what > 1 + CraftWire.INT_DIGITS then return "format" end -- "i"/"s" and at most 12 digits (f1070)
  if m.qty < LIMITS.qtyMin or m.qty > LIMITS.qtyMax or m.tip > LIMITS.tipMax then return "limit" end
  local d = m.expiresAt - m.postedAt
  if d % 3600 ~= 0 or not HOURS[d / 3600] then return "limit" end
  if m.note and #m.note > LIMITS.note then return "limit" end
  if future(now, m.postedAt) then return "future" end
end

local function encodeRequest(m)
  return E(m.id) .. ":" .. E(m.byName) .. ":" .. E(m.what) .. ":" .. n(m.qty) .. ":" .. (m.mats and "1" or "0")
    .. ":" .. n(m.tip) .. ":" .. n(m.postedAt) .. ":" .. n(m.expiresAt) .. ":" .. o(m.note)
end

local function decodeRequest(m, f)
  m.id, m.byName, m.what, m.qty = atom(f[2]), atom(f[3]), atom(f[4]), int(f[5])
  if f[6] ~= "0" and f[6] ~= "1" then error(FORMAT) end
  m.mats = f[6] == "1"
  m.tip, m.postedAt, m.expiresAt, m.note = int(f[7]), int(f[8]), int(f[9]), optAtom(f[10] or error(FORMAT))
  return m
end

local function nameAt(e) return { name = atom(e[1]), at = int(e[2]) } end

local function checkNameAts(entries, now)
  if type(entries) ~= "table" then return "format" end
  for _, e in ipairs(entries) do
    if not isName(e.name) or not isInt(e.at) then return "format" end
    if future(now, e.at) then return "future" end
  end
end

local function checkRanged(m, keyField, valueOk)
  if not (isInt(m.did) and isInt(m.pi) and isInt(m.pn) and m.pi >= 1 and m.pi <= m.pn
          and m.pn <= CraftWire.MAX_PN) then return "format" end
  if (m.from ~= nil and type(m.from) ~= "string") or (m.to ~= nil and type(m.to) ~= "string") then return "format" end
  if type(m.entries) ~= "table" then return "format" end
  for _, e in ipairs(m.entries) do
    if not isStr(e[keyField]) or #e[keyField] > CraftWire.ATOM_MAX or not valueOk(e) then return "format" end
  end
end

local TYPES = {}

TYPES.H = {
  encode = function(m) return n(m.dirHash) .. ":" .. n(m.boardHash) end,
  decode = function(m, f)
    m.dirHash, m.boardHash = f[2], f[3]
    return m
  end,
  check = function(m)
    if not (isHash(m.dirHash) and isHash(m.boardHash)) then return "format" end
  end,
}

TYPES.D = {
  encode = function(m)
    local out = {}
    for i, e in ipairs(m.entries or {}) do out[i] = E(e.key) .. "," .. n(e.stamp) .. "," .. n(e.seen) end
    return n(m.did) .. ":" .. n(m.pi) .. ":" .. n(m.pn) .. ":" .. o(m.from) .. ":" .. o(m.to) .. ":" .. table.concat(out, ";")
  end,
  decode = function(m, f)
    m.did, m.pi, m.pn, m.from, m.to = int(f[2]), int(f[3]), int(f[4]), optAtom(f[5]), optAtom(f[6])
    m.entries = list(f[7], function(e) return { key = atom(e[1]), stamp = int(e[2]), seen = int(e[3]) } end)
    return m
  end,
  check = function(m, now)
    local why = checkRanged(m, "key", function(e) return isInt(e.stamp) and isInt(e.seen) end)
    if why then return why end
    for _, e in ipairs(m.entries) do if future(now, e.stamp, e.seen) then return "future" end end
  end,
}

TYPES.B = {
  encode = function(m)
    return n(m.did) .. ":" .. n(m.pi) .. ":" .. n(m.pn) .. ":" .. o(m.from) .. ":" .. o(m.to) .. ":"
      .. pairList(m.entries, "id", "hash", E, n)
  end,
  decode = function(m, f)
    m.did, m.pi, m.pn, m.from, m.to = int(f[2]), int(f[3]), int(f[4]), optAtom(f[5]), optAtom(f[6])
    m.entries = list(f[7], function(e) return { id = atom(e[1]), hash = e[2] } end)
    return m
  end,
  check = function(m)
    return checkRanged(m, "id", function(e) return isHash(e.hash) end)
  end,
}

TYPES.P = {
  encode = function(m)
    local out = {}
    for i, p in ipairs(m.profs or {}) do out[i] = n(p.skill) .. "," .. n(p.rank) .. "," .. n(p.max) .. "," .. encodePacked(p.packed) end
    return E(m.name) .. ":" .. E(m.class) .. ":" .. n(m.stamp) .. ":" .. n(m.seen) .. ":" .. table.concat(out, ";")
  end,
  decode = function(m, f)
    m.name, m.class, m.stamp, m.seen = atom(f[2]), atom(f[3]), int(f[4]), int(f[5])
    m.profs = list(f[6], function(e)
      if e[4] == nil then error(FORMAT) end
      return { skill = int(e[1]), rank = int(e[2]), max = int(e[3]), packed = decodePacked(e[4]) }
    end)
    return m
  end,
  check = function(m, now)
    if not (isName(m.name) and isNameText(m.class) and isInt(m.stamp) and isInt(m.seen)
            and type(m.profs) == "table") then return "format" end
    for _, p in ipairs(m.profs) do
      if not (isInt(p.skill) and isInt(p.rank) and isInt(p.max) and isPacked(p.packed)) then return "format" end
      if p.skill < 1 or p.skill > 100000 or p.rank > 1000 or p.max > 1000 then return "limit" end
    end
    if future(now, m.stamp, m.seen) then return "future" end
  end,
}

-- K: one character's cooldown states (crafting_c, q1170). cds = { { group, readyAt } }, readyAt a server time or 0
-- (ready when read); the groups are CraftStore.COOLDOWNS' (tr, mc, ss), each at most once.
local CD_GROUPS = { tr = true, mc = true, ss = true }
TYPES.K = {
  encode = function(m)
    return E(m.name) .. ":" .. E(m.class) .. ":" .. n(m.stamp) .. ":" .. n(m.seen) .. ":"
      .. pairList(m.cds, "group", "readyAt", n, n)
  end,
  decode = function(m, f)
    m.name, m.class, m.stamp, m.seen = atom(f[2]), atom(f[3]), int(f[4]), int(f[5])
    m.cds = list(f[6], function(e)
      if #e ~= 2 then error(FORMAT) end
      return { group = e[1], readyAt = int(e[2]) }
    end)
    return m
  end,
  check = function(m, now)
    if not (isName(m.name) and isNameText(m.class) and isInt(m.stamp) and isInt(m.seen)
            and type(m.cds) == "table") then return "format" end
    local seen = {}
    for _, c in ipairs(m.cds) do
      if type(c) ~= "table" or not CD_GROUPS[c.group] or seen[c.group] or not isInt(c.readyAt) then return "format" end
      seen[c.group] = true
    end
    if future(now, m.stamp, m.seen) then return "future" end
  end,
}

TYPES.R = {
  encode = function(m)
    if m.kind == "b" then return "b:" .. pairList(m.entries, "id", "hash", E, n) end
    return n(m.kind) .. ":" .. pairList(m.entries, "key", "stamp", E, n)
  end,
  decode = function(m, f)
    m.kind = f[2]
    if m.kind == "d" then
      m.entries = list(f[3], function(e) return { key = atom(e[1]), stamp = int(e[2]) } end)
    elseif m.kind == "b" then
      m.entries = list(f[3], function(e) return { id = atom(e[1]), hash = e[2] } end)
    else
      error(FORMAT)
    end
    return m
  end,
  check = function(m, now)
    if type(m.entries) ~= "table" then return "format" end
    for _, e in ipairs(m.entries) do
      if m.kind == "d" then
        if not (isStr(e.key) and isInt(e.stamp)) then return "format" end
        if future(now, e.stamp) then return "future" end
      elseif m.kind == "b" then
        if not (isStr(e.id) and isHash(e.hash)) then return "format" end
      else
        return "format"
      end
    end
    if m.kind ~= "d" and m.kind ~= "b" then return "format" end
  end,
}

TYPES.W = {
  encode = encodeRequest,
  decode = decodeRequest,
  check = checkRequest,
}

TYPES.C = {
  encode = function(m) return E(m.id) .. ":" .. E(m.name) .. ":" .. n(m.at) end,
  decode = function(m, f)
    m.id, m.name, m.at = atom(f[2]), atom(f[3]), int(f[4])
    return m
  end,
  check = function(m, now)
    if not (isStr(m.id) and isName(m.name) and isInt(m.at)) then return "format" end
    if future(now, m.at) then return "future" end
  end,
}

TYPES.X = {
  encode = function(m) return E(m.id) .. ":" .. n(m.kind) .. ":" .. E(m.name) .. ":" .. n(m.at) end,
  decode = function(m, f)
    m.id, m.kind, m.name, m.at = atom(f[2]), f[3], atom(f[4]), int(f[5])
    return m
  end,
  check = function(m, now)
    if not (isStr(m.id) and X_KINDS[m.kind] and isName(m.name) and isInt(m.at)) then return "format" end
    if future(now, m.at) then return "future" end
  end,
}

TYPES.F = {
  encode = function(m)
    return encodeRequest(m) .. ":" .. pairList(m.claims, "name", "at", E, n) .. ":" .. pairList(m.drops, "name", "at", E, n)
      .. ":" .. n(m.releasedAt) .. ":" .. n(m.finalKind) .. ":" .. n(m.finalAt)
  end,
  decode = function(m, f)
    decodeRequest(m, f)
    m.claims, m.drops = list(f[11], nameAt), list(f[12], nameAt)
    m.releasedAt = optInt(f[13] or error(FORMAT))
    m.finalKind = f[14] ~= "" and f[14] or nil
    m.finalAt = optInt(f[15] or error(FORMAT))
    return m
  end,
  check = function(m, now)
    local why = checkRequest(m, now) or checkNameAts(m.claims, now) or checkNameAts(m.drops, now)
    if why then return why end
    if (m.releasedAt ~= nil and not isInt(m.releasedAt)) or (m.finalAt ~= nil and not isInt(m.finalAt))
       or (m.finalKind ~= nil and not FINAL_KINDS[m.finalKind]) then return "format" end
    if future(now, m.releasedAt, m.finalAt) then return "future" end
  end,
}

-- ---------- logical messages ----------

-- Pack(msg, now) -> logical | nil, why
function CraftWire.Pack(msg, now)
  local def = type(msg) == "table" and TYPES[msg.t]
  if not def then return nil, "unknown" end
  local why = def.check(msg, now)
  if why then return nil, why end
  return msg.t .. ":" .. def.encode(msg)
end

-- Unpack(logical, now) -> msg | nil, why ("format" | "limit" | "future" | "unknown")
function CraftWire.Unpack(logical, now)
  if type(logical) ~= "string" then return nil, "format" end
  local f = split(logical, ":")
  local def = TYPES[f[1]]
  if not def then return nil, "unknown" end
  local good, msg = pcall(def.decode, { t = f[1] }, f)
  if not good then
    if msg == FORMAT then return nil, "format" end
    error(msg, 0)
  end
  local why = def.check(msg, now)
  if why then return nil, why end
  return msg
end

-- Subject(msg) -> subject, version: the key and stamp (P, K), the request id and content hash (F), the id and 0
-- (W, C, X), "-" and 0 (H, D, B, R). The subject is returned unescaped; Split escapes it on the wire.
-- An F that carries msg.hash (CraftSync sets CraftBoard.Hash of the request) uses it as its version, so the
-- chunk header carries the one hash of a request; without it, the Adler-32 of the F text.
function CraftWire.Subject(msg)
  local t = msg.t
  if t == "P" or t == "K" then return tostring(msg.name or ""):lower(), msg.stamp end
  if t == "F" then
    if type(msg.hash) == "string" then return msg.id, msg.hash end
    return msg.id, CraftWire.Hash(t .. ":" .. TYPES.F.encode(msg))
  end
  if t == "W" or t == "C" or t == "X" then return msg.id, 0 end
  return "-", 0
end

-- "ok" | "retry" | "lockdown" | "abort"; tries is 1 for the first send.
function CraftWire.SendOutcome(result, tries)
  if result == 0 then return "ok" end
  if result == 11 then return "lockdown" end
  if (result == 3 or result == 8) and tries <= CraftWire.MAX_TRIES then return "retry" end
  return "abort"
end

return CraftWire
