-- GuildSyncBank model: the numbers, the record keys and the month, shared by every later file. Pure: no client call.
--   ns.LIMITS               caps and time bounds (seconds, counts, bytes)
--   ns.DOMAIN               key family -> the domain it syncs on (Store.lua registers the four domains)
--   ns.Key(family, n, author) -> key      "q07~anya dusk", "b1~anya dusk", "x~borin ash", "anya dusk" (family "m")
--   ns.ParseKey(key) -> family, n, author a key with no "~" is a member key: "m", nil, key
--   ns.CAPS                 records per author per key family (the n range)
--   ns.ValidKey(domain, key) -> bool      a canonical key of a family that syncs on that domain (plan section 2)
--   ns.Month(t) -> "YYYY-MM"              in UTC, whatever the client's time zone

local _, ns = ...
if not ns.M then return end

ns.LIMITS = {
  why = 300, note = 120, reason = 120,           -- stored string caps, bytes
  wanted = 10000, sent = 10000, askCount = 1000, -- amount caps
  openReqs = 30, slots = 30, openRequests = 10,  -- requisition slots, open member requests per member
  pledgeDays = 7, keepClosedDays = 14, requestDays = 14,
  pledgesMax = 30, sendsMax = 30,                -- own pledges and sends Rules.prune keeps (d780)
  future = 300,                                  -- a time at most this far ahead of now is accepted (AC9)
  debounce = 60,                                 -- seconds between scans of the own record
}

ns.DOMAIN = { b = "bank", k = "bank", g = "bank", t = "bank", q = "bank_q", l = "bank_a", a = "bank_a", x = "bank_a",
  m = "bank_m" }

local SEP = "~"

function ns.Key(family, n, author)
  if family == "m" then return author end
  if family == "q" then return string.format("q%02d", n) .. SEP .. author end
  return family .. (n and tostring(n) or "") .. SEP .. author
end

function ns.ParseKey(key)
  local head, author = string.match(key, "^([^~]*)~(.*)$")
  if not head then return "m", nil, key end
  local family, digits = string.match(head, "^(%a)(%d*)$")
  if not family then return nil, nil, author end
  return family, tonumber(digits), author
end

-- Records per author per family (plan d772): the n range of each key family. x is one record with no n.
ns.CAPS = { b = 2, k = 6, g = 8, t = 8, q = 30, l = 6, a = 6, x = 1 }

-- ValidKey(domain, key) -> true | false   (plan section 2) the key is canonical (Key(ParseKey(key)) == key), at most
-- 64 bytes, its family belongs to the domain with n in range (x and m carry no n), and its author is 1-48 bytes with
-- no byte Wire.Escape escapes (% : ; , = / |), no ~ and no control byte, so its header subject keeps its raw size. A "1.2" key is never valid.
function ns.ValidKey(domain, key)
  if type(key) ~= "string" or #key < 1 or #key > 64 or key:find("^%d+%.%d+$") then return false end
  local family, n, author = ns.ParseKey(key)
  if not family or ns.DOMAIN[family] ~= domain or type(author) ~= "string" then return false end
  if #author < 1 or #author > 48 or author:find("[%z\1-\31%%:;,=/|~]") then return false end
  if family == "m" or family == "x" then
    if n ~= nil then return false end
  elseif not n or n < 1 or n > ns.CAPS[family] then
    return false
  end
  return ns.Key(family, n, author) == key
end

function ns.Month(t) return date("!%Y-%m", t) end
