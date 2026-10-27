-- GuildSyncBank model: the numbers, the record keys and the month, shared by every later file. Pure: no client call.
--   ns.LIMITS               caps and time bounds (seconds, counts, bytes)
--   ns.DOMAIN               key family -> the domain it syncs on (Store.lua registers the four domains)
--   ns.Key(family, n, author) -> key      "q07~anya dusk", "b1~anya dusk", "x~borin ash", "anya dusk" (family "m")
--   ns.ParseKey(key) -> family, n, author a key with no "~" is a member key: "m", nil, key
--   ns.CAPS                 records per author per key family (the n range)
--   ns.ValidKey(domain, key) -> bool      a canonical key of a family that syncs on that domain (plan section 2)
--   ns.Month(t) -> "YYYY-MM"              in UTC, whatever the client's time zone
--   ns.Money(copper) -> text              "-1g 23s 45c", "5s 20c", "0c"; "?" for what is not a whole number (d1095)

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
  ledgerMax = 40, ledgerDays = 30,               -- j entries the writer keeps, and for how long (d1072)
  otherWindow = 600, ledgerDebounce = 300,       -- an o entry amended this long; seconds between j writes (d1076, d1086)
  postage = 30,                                  -- copper per attached item (up to 12) a send may cost (d1084, f6395)
  minimum = 10000, minItems = 40, minClearDays = 14, -- n: the largest minimum, items per bank character, tombstone days
  maxBankChars = 6,                              -- smallest floor(200 / keys per bank character) over the domains (d1091)
}

ns.DOMAIN = { b = "bank", k = "bank", g = "bank", t = "bank", j = "bank", n = "bank", q = "bank_q", l = "bank_a",
  a = "bank_a", x = "bank_a", m = "bank_m" }

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
ns.CAPS = { b = 2, k = 6, g = 8, t = 8, j = 1, n = 1, q = 30, l = 6, a = 6, x = 1 }

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

-- Money(copper) -> text   the size with its sign, zero parts left out (d1095): -12345 -> "-1g 23s 45c", 0 -> "0c"
function ns.Money(c)
  if type(c) ~= "number" or c ~= c or c == math.huge or c == -math.huge or math.floor(c) ~= c then return "?" end
  local a = math.abs(c)
  local g, s, k = math.floor(a / 10000), math.floor(a % 10000 / 100), a % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = string.format("%.0fg", g) end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if k > 0 or #parts == 0 then parts[#parts + 1] = k .. "c" end
  return (c < 0 and "-" or "") .. table.concat(parts, " ")
end
