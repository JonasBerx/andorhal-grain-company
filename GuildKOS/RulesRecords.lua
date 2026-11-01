-- GuildKOS RulesRecords: the three record kinds (t = kos target, h = kos_h hunter, m = kos_m member), their keys,
-- body format, receive refusals, display-safe text, sizes and trim.
-- Pure Lua 5.1, no client calls. Time (now) is always passed in.
--
-- Body: fixed fields, then one section per list, sections joined by "=", entries by ",", fields by ";".
-- Every field is escaped with Escape below (Wire.Escape's byte costs plus "~", which the hub uses in P messages).
-- Numbers are decimal text. An empty field is an absent value.
local _, ns = ...
local Records = {}
ns.RulesRecords = Records

Records.BUDGET = { t = 2811, h = 2365, m = 2293 }  -- packed, escaped body bytes after the hub prefix (f5199)
Records.PLAYER_PREFIX = "Player-"                  -- the one "is a player GUID" test (d757 item 5); Task F may widen it
Records.FUTURE = 300                               -- seconds a time may lie ahead of now
Records.KEY_MAX = 25                               -- bytes in a target key
Records.ATOM_MAX = 64                              -- bytes in a key after Wire escape (Wire.ATOM_MAX)
Records.NAME_CHARS = 40                            -- the name cap counts characters (spec AC8)
Records.CAPS = { why = 80, zone = 40, subzone = 40, race = 12, class = 12 }   -- bytes
Records.DIGITS = 12                                -- longest number accepted; longer digit runs can reach inf
Records.GUID_MAX = 24                              -- bytes in any received GUID field (f5437)

local SPEC = {
  t = { fixed = { "status", "name", "race", "class", "level", "zone", "why", "markedBy", "markedAt", "decidedBy",
                  "decidedAt" },
        lists = { { name = "kills", fields = { "hunter", "time" }, max = 10 },
                  { name = "rejected", fields = { "hunter", "time" }, max = 10 } } },
  h = { fixed = { "total", "best", "since" },
        lists = { { name = "kills", fields = { "time", "victim", "officer" }, max = 25 } } },
  m = { fixed = { "guid" },
        lists = { { name = "marks", fields = { "guid", "name", "race", "class", "level", "zone", "subzone", "why", "time" },
                    max = 3, who = "marker" },
                  { name = "claims", fields = { "time", "victim", "zone" }, max = 6, who = "claimer" },
                  { name = "witness", fields = { "killer", "victim", "time" }, max = 6, who = "witness" },
                  { name = "sightings", fields = { "target", "time", "zone", "subzone", "shard" }, max = 3,
                    who = "spotter" } } },
}
local NUMBER = { level = true, markedAt = true, decidedAt = true, time = true, total = true, best = true, since = true }
local TIME = { markedAt = true, decidedAt = true, time = true }
local GUID = { victim = true, killer = true, target = true }   -- plus a mark's guid; all required in list entries
local MEMBER_KEY = { markedBy = true, decidedBy = true, hunter = true, officer = true }   -- capped at ATOM_MAX
local STATUS = { open = true, removed = true, rejected = true }

-- ---------- Safe ----------

local function dropped(cp)
  return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)
    or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069)
    or cp == 0x061C or cp == 0x2028 or cp == 0x2029 or cp == 0xFEFF
end

-- s with invalid UTF-8 and dropped code points removed.
local function clean(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len, cp, min
    if c < 0x80 then len, cp, min = 1, c, 0
    elseif c >= 0xC2 and c <= 0xDF then len, cp, min = 2, c - 0xC0, 0x80
    elseif c >= 0xE0 and c <= 0xEF then len, cp, min = 3, c - 0xE0, 0x800
    elseif c >= 0xF0 and c <= 0xF4 then len, cp, min = 4, c - 0xF0, 0x10000
    end
    local good = len ~= nil and i + len - 1 <= n
    if good then
      for j = 1, len - 1 do
        local d = s:byte(i + j)
        if d < 0x80 or d > 0xBF then good = false; break end
        cp = cp * 64 + (d - 0x80)
      end
      good = good and cp >= min and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF)
    end
    if good then
      if not dropped(cp) then out[#out + 1] = s:sub(i, i + len - 1) end
      i = i + len
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

-- s cut to at most maxBytes without splitting a UTF-8 character.
local function cut(s, maxBytes)
  if #s <= maxBytes then return s end
  local at = maxBytes
  while at > 0 do
    local c = s:byte(at + 1)
    if c < 0x80 or c >= 0xC0 then break end
    at = at - 1
  end
  return s:sub(1, at)
end

local function chars(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

-- Records.Safe(s, capBytes) -> s: controls, bidi, zero-width and bad UTF-8 dropped, then cut on a UTF-8 boundary.
-- | and % stay raw: escaping for display or the wire is the caller's job.
function Records.Safe(s, capBytes)
  s = clean(tostring(s or ""))
  if capBytes then s = cut(s, capBytes) end
  return s
end

-- ---------- escape ----------

local function escapeByte(c) return string.format("%%%02X", c:byte()) end
local function escape(v)
  if v == nil then return "" end
  return (tostring(v):gsub("[%z\1-\31%%:;,=/|~]", escapeByte))
end
local function unescape(s)
  if s:gsub("%%%x%x", ""):find("%", 1, true) then return nil end
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
-- Bytes of s after Wire.Escape (controls other than \r and \n are dropped there; counted as 3 here, the safe side).
local function wireBytes(s)
  local _, n = s:gsub("[%z\1-\31%%:;,=/|]", "")
  return #s + 2 * n
end

-- ---------- keys ----------

local function isPlayer(g)
  local p = Records.PLAYER_PREFIX
  return type(g) == "string" and #g > #p and g:sub(1, #p) == p
end

-- Records.TargetKey(guid) -> "t" .. guid | nil, why. Length only: Parse applies PLAYER_PREFIX to a received key.
function Records.TargetKey(guid)
  if type(guid) ~= "string" or guid == "" then return nil, "guid" end
  local key = "t" .. guid
  if #key > Records.KEY_MAX then return nil, "long" end
  if wireBytes(key) > Records.ATOM_MAX then return nil, "long" end
  return key
end

-- Records.HunterKey(memberKey) -> "h" .. memberKey | nil, why
function Records.HunterKey(memberKey)
  if type(memberKey) ~= "string" or memberKey == "" then return nil, "key" end
  local key = "h" .. memberKey
  if wireBytes(key) > Records.ATOM_MAX then return nil, "long" end
  return key
end

-- ---------- pack ----------

-- Records.Pack(kind, rec) -> body. A plain serialiser: no counts or caps (Trim and Parse own those).
function Records.Pack(kind, rec)
  local spec = SPEC[kind]
  if not spec or type(rec) ~= "table" then return nil end
  local fixed = {}
  for i, f in ipairs(spec.fixed) do fixed[i] = escape(rec[f]) end
  local sections = { table.concat(fixed, ";") }
  for _, list in ipairs(spec.lists) do
    local entries = {}
    for _, e in ipairs(rec[list.name] or {}) do
      local fields = {}
      for i, f in ipairs(list.fields) do fields[i] = escape(e[f]) end
      entries[#entries + 1] = table.concat(fields, ";")
    end
    sections[#sections + 1] = table.concat(entries, ",")
  end
  return table.concat(sections, "=")
end

-- Records.Size(kind, key, by, rec) -> the packed, escaped body bytes that BUDGET counts.
function Records.Size(kind, key, by, rec)
  return #(Records.Pack(kind, rec) or "")
end

-- ---------- parse ----------

local function splitOn(s, sep)
  local out, from = {}, 1
  while true do
    local at = s:find(sep, from, true)
    if not at then out[#out + 1] = s:sub(from); return out end
    out[#out + 1] = s:sub(from, at - 1)
    from = at + 1
  end
end

-- One field: value, or nil + false for absent, or nil + why for a refusal.
local function field(name, raw, now, isGuid, required)
  local v = unescape(raw)
  if not v then return nil, "escape" end
  v = Records.Safe(v)
  if v == "" then
    if required then return nil, "missing " .. name end
    return nil, false
  end
  if NUMBER[name] then
    if #v > Records.DIGITS or not v:match("^%d+$") then return nil, "number " .. name end
    local n = tonumber(v)
    if TIME[name] and n > now + Records.FUTURE then return nil, "future " .. name end
    return n
  end
  if isGuid and (#v > Records.GUID_MAX or not isPlayer(v)) then return nil, "guid " .. name end
  if name == "shard" and (#v > Records.DIGITS or not v:match("^%d+$")) then return nil, "shard" end
  if MEMBER_KEY[name] and #v > Records.ATOM_MAX then return nil, "cap " .. name end
  if name == "status" and not STATUS[v] then return nil, "status" end
  if name == "name" and chars(v) > Records.NAME_CHARS then return nil, "cap name" end
  local cap = Records.CAPS[name]
  if cap and #v > cap then return nil, "cap " .. name end
  return v
end

-- Records.Parse(kind, key, body, now) -> rec | nil, why
-- Refuses a list over its count, a field over its cap, a number that is not plain decimal digits (inf, nan,
-- negative), a time above now + FUTURE, a target/victim/killer GUID outside PLAYER_PREFIX or over GUID_MAX, a shard
-- that is not digits or over DIGITS, a member key over ATOM_MAX, a t status not open/removed/rejected, and a target
-- key that TargetKey would not make. A member record's marker, claimer, witness and spotter are the record key.
function Records.Parse(kind, key, body, now)
  local spec = SPEC[kind]
  if not spec then return nil, "kind" end
  if type(key) ~= "string" or key == "" or type(body) ~= "string" or type(now) ~= "number" then
    return nil, "args"
  end
  if kind == "t" and (not isPlayer(key:sub(2)) or Records.TargetKey(key:sub(2)) ~= key) then return nil, "key" end
  if kind == "h" and (key:sub(1, 1) ~= "h" or #key < 2) then return nil, "key" end
  local sections = splitOn(body, "=")
  if #sections ~= 1 + #spec.lists then return nil, "shape" end
  local rec = {}
  local fixed = splitOn(sections[1], ";")
  if #fixed ~= #spec.fixed then return nil, "shape" end
  for i, name in ipairs(spec.fixed) do
    local v, why = field(name, fixed[i], now, kind == "m" and name == "guid", kind == "t" and name == "status")
    if why then return nil, why end
    rec[name] = v
  end
  for li, list in ipairs(spec.lists) do
    local raw = sections[li + 1]
    local entries = raw == "" and {} or splitOn(raw, ",")
    if #entries > list.max then return nil, "count " .. list.name end
    local out = {}
    for ei, entry in ipairs(entries) do
      local fields = splitOn(entry, ";")
      if #fields ~= #list.fields then return nil, "shape" end
      local e = {}
      for i, name in ipairs(list.fields) do
        local isGuid = GUID[name] or (list.name == "marks" and name == "guid")
        local v, why = field(name, fields[i], now, isGuid, isGuid or name == "time")
        if why then return nil, why end
        e[name] = v
      end
      if list.who then e[list.who] = key end
      out[ei] = e
    end
    rec[list.name] = out
  end
  return rec
end

-- ---------- trim ----------

local function copy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = copy(x) end
  return o
end

-- A tie-break for equal times, so the cut never depends on list order.
local function tie(e)
  return tostring(e.victim or e.target or e.killer or e.hunter or "")
end

-- Removes the oldest entry of list that passes keep (all when keep is nil). true when one went.
local function dropOldest(list, keep)
  local at
  for i, e in ipairs(list or {}) do
    if not keep or keep(e) then
      local best = at and list[at]
      local t, bt = tonumber(e.time) or 0, best and (tonumber(best.time) or 0)
      if not best or t < bt or (t == bt and tie(e) < tie(best)) then at = i end
    end
  end
  if at then table.remove(list, at); return true end
  return false
end

-- Records.Trim(kind, rec, budget, settled) -> rec (a copy), cutCount
-- Drops entries until Size fits budget. m: oldest sighting, oldest settled claim, oldest witness line, oldest waiting
-- claim; the own GUID and the marks are never cut. t: oldest rejected id, then oldest kill. h: oldest kill.
-- settled(claim) -> bool is optional; without it no claim counts as settled.
function Records.Trim(kind, rec, budget, settled)
  rec = copy(rec)
  local n = 0
  local waiting = settled and function(c) return not settled(c) end
  while Records.Size(kind, nil, nil, rec) > budget do
    local done
    if kind == "m" then
      done = dropOldest(rec.sightings)
        or (settled ~= nil and dropOldest(rec.claims, settled))
        or dropOldest(rec.witness)
        or dropOldest(rec.claims, waiting)
    elseif kind == "t" then
      done = dropOldest(rec.rejected) or dropOldest(rec.kills)
    else
      done = dropOldest(rec.kills)
    end
    if not done then break end
    n = n + 1
  end
  return rec, n
end

return Records
