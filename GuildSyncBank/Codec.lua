-- GuildSyncBank wire codec (t42 plan section 3). Pure: no client call, no clock, no global beyond ns.
--   ns.Codec.Pack(msg) -> text | nil       P: "P~<key>~<rev>~<hash>~<by>~<body>", H: "H~<hash>", D and R: "k,rev,hash;..."
--   ns.Codec.Unpack(text) -> msg | nil     the P tail (the body) keeps every byte
--   ns.Codec.Encode(body) -> text          "{k=v,...}" sorted by tagged key text; "#" integers, "'" strings (%XX)
--   ns.Codec.Decode(text) -> body | nil, why   never throws; the why holds no input text
--   ns.Codec.Hash(text) -> "%08x"          Adler-32, as the hub's Wire.Hash
--   ns.Codec.Clean(family, body, now) -> view | nil, why   type, range, string and future checks; display caps
--   ns.Codec.Fits(domain, msg) -> bool ; ns.Codec.FIT[domain]   the packed P's byte budget per domain
--   ns.Codec.ByteLess(a, b) ; ns.Codec.Order(a, b)   bytewise string order; map-key order (numbers first, by value)

local _, ns = ...
if not ns.M then return end

local Codec = {}
ns.Codec = Codec

-- ---------- sizes (plan section 2) ----------

-- room = 250 - 7 - (4 + #T + 64 + 16) - 4 - 1 with T = "<domain>.P"; FIT = (maxChunks - 1) x (room - 3)
local MAX_CHUNKS = { bank = 16, bank_q = 16, bank_a = 16, bank_m = 64 }
Codec.FIT = {}
for domain, n in pairs(MAX_CHUNKS) do
  local room = 250 - 7 - (4 + #(domain .. ".P") + 64 + 16) - 4 - 1
  Codec.FIT[domain] = (n - 1) * (room - 3)
end

-- ---------- hash ----------

function Codec.Hash(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end

-- ---------- body encoding ----------

local SPECIAL = "[%z\1-\31{}=,%%'#~|]"
local MAX_INT = 9999999999999 -- 13 digits
local MAX_DEPTH, MAX_NODES = 4, 3000

local function escByte(c) return string.format("%%%02X", c:byte()) end

local function whole(v, lo, hi)
  return type(v) == "number" and v == v and v >= lo and v <= hi and math.floor(v) == v
end

-- A key or a scalar value as its tagged text; nil for what the grammar cannot hold (skipped by Encode).
local function tag(v)
  if type(v) == "string" then return "'" .. (v:gsub(SPECIAL, escByte)) end
  if whole(v, -MAX_INT, MAX_INT) then
    if v == 0 then v = 0 end -- -0 is written as 0
    return "#" .. string.format("%.0f", v)
  end
  return nil
end

-- Bytewise string order: the client's string `<` may follow the locale (strcoll), so two clients could sort apart.
local function byteLess(a, b)
  local n = #a < #b and #a or #b
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return #a < #b
end

local function byKey(x, y) return byteLess(x.k, y.k) end

-- Map keys: numbers before strings, numbers by value, strings bytewise.
local function byteOrder(a, b)
  local sa, sb = type(a) == "string", type(b) == "string"
  return (sa and sb and byteLess(a, b)) or (not sa and not sb and a < b) or (sb and not sa)
end

Codec.ByteLess, Codec.Order = byteLess, byteOrder

local function encodeTable(t)
  local list = {}
  for k, v in pairs(t) do
    local kt = tag(k)
    local vt
    if type(v) == "table" then vt = encodeTable(v) else vt = tag(v) end
    if kt and vt then list[#list + 1] = { k = kt, s = kt .. "=" .. vt } end
  end
  table.sort(list, byKey)
  local parts = {}
  for i, e in ipairs(list) do parts[i] = e.s end
  return "{" .. table.concat(parts, ",") .. "}"
end

function Codec.Encode(body)
  if type(body) ~= "table" then return nil end
  return encodeTable(body)
end

-- ---------- body decoding ----------

local text, pos, nodes

local function atom()
  local c = text:sub(pos, pos)
  if c == "#" then
    local _, e, digits = text:find("^(%-?%d+)", pos + 1)
    if not e then return nil, "bad number" end
    if #digits - (digits:sub(1, 1) == "-" and 1 or 0) > 13 then return nil, "number too long" end
    pos = e + 1
    return tonumber(digits)
  elseif c == "'" then
    local _, e = text:find("^[^,}=]*", pos + 1)
    local raw = text:sub(pos + 1, e)
    if raw:find("[%z\1-\31{'#~|]") or raw:gsub("%%%x%x", ""):find("%", 1, true) then return nil, "bad string" end
    pos = e + 1
    return (raw:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
  end
  return nil, "bad value"
end

local function tableAt(depth)
  if depth > MAX_DEPTH then return nil, "too deep" end
  pos = pos + 1
  local out = {}
  if text:sub(pos, pos) == "}" then
    pos = pos + 1
    return out
  end
  while true do
    nodes = nodes + 1
    if nodes > MAX_NODES then return nil, "too many entries" end
    local k, why = atom()
    if k == nil then return nil, why end
    if text:sub(pos, pos) ~= "=" then return nil, "expected =" end
    pos = pos + 1
    local v
    if text:sub(pos, pos) == "{" then v, why = tableAt(depth + 1) else v, why = atom() end
    if v == nil then return nil, why end
    if out[k] ~= nil then return nil, "duplicate key" end
    out[k] = v
    local c = text:sub(pos, pos)
    pos = pos + 1
    if c == "}" then return out end
    if c ~= "," then return nil, "expected , or }" end
  end
end

function Codec.Decode(s)
  if type(s) ~= "string" then return nil, "not text" end
  if s:sub(1, 1) ~= "{" then return nil, "not a table" end
  text, pos, nodes = s, 1, 0
  local good, v, why = pcall(tableAt, 1)
  local ended = pos == #s + 1
  text = nil
  if not good then return nil, "unreadable" end
  if v == nil then return nil, why or "unreadable" end
  if not ended then return nil, "trailing text" end
  return v
end

-- ---------- envelope ----------

local function revText(rev)
  if not whole(rev, 0, 9007199254740991) then return nil end
  return string.format("%.0f", rev)
end

local function field(s)
  if s == nil then return "" end
  if type(s) ~= "string" or s:find("~", 1, true) then return nil end
  return s
end

function Codec.Pack(msg)
  if type(msg) ~= "table" then return nil end
  if msg.t == "P" then
    local rev, hash, by = revText(msg.rev), field(msg.hash), field(msg.by)
    local body = msg.body == nil and "" or msg.body
    if type(msg.key) ~= "string" or msg.key == "" or not rev or not hash or not by or type(body) ~= "string" then
      return nil
    end
    return "P~" .. msg.key .. "~" .. rev .. "~" .. hash .. "~" .. by .. "~" .. body
  end
  if msg.t == "H" then
    local hash = field(msg.hash)
    return hash and ("H~" .. hash) or nil
  end
  if msg.t == "D" or msg.t == "R" then
    local list = {}
    for _, e in ipairs(type(msg.entries) == "table" and msg.entries or {}) do
      local rev = revText(e.rev or 0)
      if type(e.key) ~= "string" or not rev then return nil end
      list[#list + 1] = e.key .. "," .. rev .. "," .. (type(e.hash) == "string" and e.hash or "")
    end
    return msg.t .. "~" .. table.concat(list, ";")
  end
  return nil
end

-- A key holds one "~" after a one-letter family head ("q01~anya dusk") or none (a member key); character names are
-- never one letter and digits, so the two shapes do not overlap.
local P_FAMILY = "^P~(%a%d*~[^~]*)~(%d+)~([^~]*)~([^~]*)~(.*)$"
local P_MEMBER = "^P~([^~]*)~(%d+)~([^~]*)~([^~]*)~(.*)$"

function Codec.Unpack(s)
  if type(s) ~= "string" then return nil end
  local kind = s:sub(1, 2)
  if kind == "P~" then
    local key, rev, hash, by, body = s:match(P_FAMILY)
    if not key then key, rev, hash, by, body = s:match(P_MEMBER) end
    if not key or key == "" then return nil end
    return { t = "P", key = key, rev = tonumber(rev), hash = hash, by = by, body = body }
  end
  if kind == "H~" then
    local hash = s:match("^H~([^~]*)$")
    return hash and { t = "H", hash = hash } or nil
  end
  if kind == "D~" or kind == "R~" then
    local entries = {}
    for e in (s:sub(3) .. ";"):gmatch("([^;]*);") do
      local k, r, h = e:match("^([^,]+),(%d+),([^,]*)$")
      if k then entries[#entries + 1] = { key = k, rev = tonumber(r), hash = h } end
    end
    return { t = s:sub(1, 1), entries = entries }
  end
  return nil
end

function Codec.Fits(domain, msg)
  local fit, packed = Codec.FIT[domain], Codec.Pack(msg)
  return fit ~= nil and packed ~= nil and #packed <= fit
end

-- ---------- Clean (plan section 3, AC10) ----------

local ITEM_MAX = 2147483647
local DAY = 86400
local CAP = { requests = 10, pledges = 30, sends = 30, list = 200, answers = 200, x = 25, items = 400, totals = 500 }

-- A refusal carries a fixed why (a table, so a stray error is told apart and never shown).
local function fail(why) error({ why = why }) end

local now

local function int(v, lo, hi, what)
  if v == nil then return nil end
  if not whole(v, lo, hi) then fail(what) end
  return v
end

local function time(v) return int(v, 0, now + ns.LIMITS.future, "time") end

-- s cut to at most max bytes without splitting a UTF-8 character (as the hub's Wire.TruncUtf8)
local function cutUtf8(s, max)
  if #s <= max then return s end
  for back = 0, 3 do
    local at = max - back
    if at <= 0 then return "" end
    local c = s:byte(at + 1)
    if c < 0x80 or c >= 0xC0 then return s:sub(1, at) end
  end
  return s:sub(1, max)
end

local function str(v, max, what)
  if v == nil then return nil end
  if type(v) ~= "string" then fail(what) end
  return cutUtf8((v:gsub("[%z\1-\31|]", "")), max)
end

-- The longest whole-character prefix whose encoded text (an escaped byte counts 3) is at most max bytes (R7-2).
local function noteCap(s, max)
  local used, i, n = 0, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c >= 0xF0 and 4 or (c >= 0xE0 and 3 or (c >= 0xC0 and 2 or 1))
    local last = i + len - 1
    if last > n then last = n end
    local w = 0
    for j = i, last do w = w + (s:sub(j, j):find(SPECIAL) and 3 or 1) end
    if used + w > max then break end
    used = used + w
    i = last + 1
  end
  return s:sub(1, i - 1)
end

local function tbl(v, what)
  if v == nil then return nil end
  if type(v) ~= "table" then fail(what) end
  return v
end

-- The first cap entries of a map, by key (keys checked by keyOk first), each value through fn.
local function capMap(map, cap, keyOk, fn)
  local keys = {}
  for k in pairs(map) do
    keyOk(k)
    keys[#keys + 1] = k
  end
  table.sort(keys, byteOrder)
  local out = {}
  for i = 1, #keys do
    local v = fn(map[keys[i]])
    if i <= cap then out[keys[i]] = v end
  end
  return out
end

-- The first cap entries of a list, each through fn (every entry is checked, only cap are kept).
local function capList(list, cap, fn, keep)
  local out = {}
  for _, e in ipairs(list) do
    local v = fn(tbl(e, "entry") or fail("entry"))
    if #out < cap and (not keep or keep(v)) then out[#out + 1] = v end
  end
  return out
end

local function idKey(k)
  if type(k) ~= "string" or k == "" or #k > 80 then fail("id") end
end

local function scan(b)
  local items
  if tbl(b.items, "items") then
    items = capMap(b.items, CAP.items, function(id) int(id, 1, ITEM_MAX, "item") end,
      function(count) return int(count, 1, 1e6, "count") or fail("count") end)
  end
  return { scanned = time(b.scanned), money = int(b.money, 0, 1e12, "money"), tab = int(b.tab, 1, 16, "tab"),
    items = items }
end

local CLEAN = {}
CLEAN.b, CLEAN.k, CLEAN.g = scan, scan, scan

function CLEAN.q(b)
  local L = ns.LIMITS
  return { item = int(b.item, 1, ITEM_MAX, "item"), wanted = int(b.wanted, 1, L.wanted, "wanted"),
    why = str(b.why, L.why, "why"), posted = time(b.posted), cancelled = time(b.cancelled) }
end

function CLEAN.t(b)
  return capMap(b, CAP.totals,
    function(member) if type(member) ~= "string" or member == "" or #member > 48 then fail("member") end end,
    function(e)
      tbl(e, "total")
      if e == nil then fail("total") end
      return { all = int(e.all, 0, 1e9, "total"), month = str(e.month, 7, "month"),
        inMonth = int(e.inMonth, 0, 1e9, "total") }
    end)
end

function CLEAN.l(b)
  local L = ns.LIMITS
  local function entry(e)
    return { req = str(e.req, 80, "req"), member = str(e.member, 48, "member"),
      amount = int(e.amount, 1, L.sent, "amount"), sent = time(e.sent), at = time(e.at) }
  end
  local out = {}
  for _, name in ipairs({ "receipts", "unpledges", "unsends" }) do
    if tbl(b[name], "list") then out[name] = capList(b[name], CAP.list, entry) end
  end
  return out
end

function CLEAN.a(b)
  local L = ns.LIMITS
  return capList(b, CAP.answers, function(e)
    return { member = str(e.member, 48, "member"), at = time(e.at), verdict = str(e.verdict, 16, "verdict"),
      reason = str(e.reason, L.reason, "reason"), when = time(e.when) }
  end)
end

function CLEAN.x(b)
  return capMap(b, CAP.x, idKey, function(t) return time(t) or fail("time") end)
end

function CLEAN.m(b)
  local L = ns.LIMITS
  local out = {}
  if tbl(b.requests, "requests") then
    local oldest = now - L.requestDays * DAY
    out.requests = capList(b.requests, CAP.requests, function(e)
      local note = str(e.note, L.note, "note")
      return { item = int(e.item, 1, ITEM_MAX, "item"), count = int(e.count, 1, L.askCount, "count"),
        note = note and noteCap(note, L.note), at = time(e.at) }
    end, function(r) return r.at == nil or r.at >= oldest end)
  end
  local function amounts(name, max)
    if tbl(b[name], name) then
      out[name] = capMap(b[name], CAP[name], idKey, function(e)
        if type(e) ~= "table" then fail(name) end
        return { amount = int(e.amount, 1, max, "amount"), at = time(e.at) }
      end)
    end
  end
  amounts("pledges", L.wanted)
  amounts("sends", L.sent)
  return out
end

function Codec.Clean(family, body, at)
  local fn = CLEAN[family]
  if not fn then return nil, "family" end
  if type(body) ~= "table" then return nil, "body" end
  if type(at) ~= "number" or at ~= at then return nil, "time" end
  now = at
  local good, view = pcall(fn, body)
  now = nil
  if good then return view end
  if type(view) == "table" and type(view.why) == "string" then return nil, view.why end
  return nil, "unreadable"
end
