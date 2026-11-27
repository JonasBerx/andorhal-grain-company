local _, ns = ...
if not ns.M then return end
-- WishRules.lua: 58 wave 1. The wish list rules: the paste reader, the own-list edits and the record codec
-- (WISH-FORMAT.md). Pure: no M call, no saved data, every time passed in. Every answer is a new table.
--   R.ReadPaste(text) -> { ids, unread, more }
--   R.Add(list, ids, spec, t) -> list, { added, dup, full }      R.Sentence(report) -> string | nil
--   R.Remove(list, i, t), R.Move(list, i, dir, t), R.SetSpec(list, i, spec, t) -> list | nil, why
--   R.PackBody(list) -> body | nil, why    R.UnpackBody(body, now) -> list | { newer = true } | nil, why
--   R.UnpackMsg(logical, proto, t) -> msg | nil    the raids_w unpack (a P keeps its body as sent); never reads the header
--   R.MarkHas(list, heldFn) -> list, changed | nil, why    heldFn(id) true marks, false unmarks, anything else keeps
--   R.WholeLink(text) -> text | nil    the text when it is exactly one game item link, else nil
--   R.SayLine(itemText, rows, max, pack) -> text | nil, why    "Wants <item>: A, B (os) (has it)" on one line

local R = {}
ns.WishRules = R

R.MAX = 40               -- items on one list
R.BODY_MAX = 2400        -- bytes in one body
R.ID_MAX = 2147483647    -- the bound of Items.lua
R.ENTRIES_MAX = 500      -- entries in one D or R
R.FUTURE = 300           -- seconds a changed time or rev may run ahead of now

local PASTE_MAX = 20000  -- bytes of a paste read
local UNREAD_MAX = 10    -- unread lines kept
local UNREAD_LEN = 60    -- bytes of an unread line kept
local NUM_LEN = 16       -- digits in a changed time or a rev
local NUM_MAX = 2 ^ 53   -- a rev or changed time is below this
local KEY_LEN = 64       -- bytes in a member key

function R.ValidId(v)
  return type(v) == "number" and v >= 1 and v <= R.ID_MAX and v % 1 == 0
end

function R.Empty() return { items = {} } end

-- "19019" -> 19019; a leading zero, more than 10 digits or a value out of range -> nil
local function idOf(s)
  if type(s) ~= "string" or #s > 10 or not s:match("^[1-9]%d*$") then return nil end
  local n = tonumber(s)
  if R.ValidId(n) then return n end
  return nil
end

-- digits only, at most 16, below 2^53 -> the number, else nil
local function numOf(s)
  if type(s) ~= "string" or #s < 1 or #s > NUM_LEN or not s:match("^%d+$") then return nil end
  local n = tonumber(s)
  if not n or n >= NUM_MAX then return nil end
  return n
end

local function validKey(s)
  return type(s) == "string" and #s >= 1 and #s <= KEY_LEN and not s:find("[%z\1-\31~,;]")
end

-- 8 hex digits, or n x 8 with n a power of two from 2 to 64 (CommSync.lua validParts)
local function validRoundHash(s)
  if type(s) ~= "string" or #s < 8 or #s > 512 or #s % 8 ~= 0 or not s:match("^[0-9a-f]+$") then return false end
  local n = #s / 8
  while n > 1 do
    if n % 2 ~= 0 then return false end
    n = n / 2
  end
  return true
end

local function validHash(s)
  return type(s) == "string" and #s == 8 and s:match("^[0-9a-f]+$") ~= nil
end

-- cut at n bytes, never in the middle of a UTF-8 character
local function cut(s, n)
  if #s <= n then return s end
  while n > 0 and s:byte(n + 1) >= 0x80 and s:byte(n + 1) < 0xC0 do n = n - 1 end
  return s:sub(1, n)
end

-- ---------- the paste reader ----------

-- spaces off both ends in linear time (a pattern trim backtracks over a long run of spaces)
local function trim(s)
  local a = s:find("%S")
  if not a then return "" end
  local b = #s
  while s:sub(b, b):match("%s") do b = b - 1 end
  return s:sub(a, b)
end

-- line:find(pattern, pos), kept in memo[k] while its start is not passed, so a line of many links is searched once
local function findFrom(line, pattern, pos, memo, k)
  local m = memo[k]
  if not m or (m[1] and m[1] < pos) then
    m = { line:find(pattern, pos) }
    memo[k] = m
  end
  return m[1], m[2], m[3]
end

-- the next link in line from pos: its start, its end and its id text, or nil
local function nextLink(line, pos, memo)
  local s1, e1, id1 = findFrom(line, "|Hitem:(%d+)[^|]*", pos, memo, 1)
  local s2, e2, id2 = findFrom(line, "item=(%d+)", pos, memo, 2)
  if s1 and (not s2 or s1 <= s2) then
    -- the whole link: |cffxxxxxx before it, |h[name]|h and |r after it
    if s1 - 10 >= pos and line:sub(s1 - 10, s1 - 1):match("^|c%x%x%x%x%x%x%x%x$") then s1 = s1 - 10 end
    local _, h = line:find("^|h.-|h", e1 + 1)
    if h then e1 = h end
    if line:sub(e1 + 1, e1 + 2) == "|r" then e1 = e1 + 2 end
    return s1, e1, id1
  end
  if s2 then
    -- a Wowhead link: the whole run of non-space text around item=<id>
    while s2 > pos and not line:sub(s2 - 1, s2 - 1):match("%s") do s2 = s2 - 1 end
    local _, run = line:find("^%S*", e2 + 1)
    return s2, run or e2, id2
  end
  return nil
end

function R.ReadPaste(text)
  local out = { ids = {}, unread = {}, more = 0 }
  if type(text) ~= "string" then return out end
  text = text:sub(1, PASTE_MAX)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local pos, found, rest, memo = 1, false, {}, {}
    while true do
      local s, e, id = nextLink(line, pos, memo)
      if not s then break end
      found = true
      rest[#rest + 1] = line:sub(pos, s - 1)
      out.ids[#out.ids + 1] = idOf(id)
      pos = e + 1
    end
    rest[#rest + 1] = line:sub(pos)
    local left = trim(table.concat(rest, " "))
    if left:match("^[%d%s,;]*$") then
      for d in left:gmatch("%d+") do out.ids[#out.ids + 1] = idOf(d) end
    elseif not found then
      if #out.unread < UNREAD_MAX then
        out.unread[#out.unread + 1] = cut(left, UNREAD_LEN)
      else
        out.more = out.more + 1
      end
    end
  end
  return out
end

-- ---------- the own list ----------

local function validList(list)
  return type(list) == "table" and type(list.items) == "table"
end

local function copyList(list)
  local items = {}
  for i, item in ipairs(list.items) do items[i] = { id = item.id, spec = item.spec, has = item.has } end
  return { changed = list.changed, items = items }
end

local function validIndex(list, i)
  return type(i) == "number" and i % 1 == 0 and i >= 1 and i <= #list.items
end

local function validSpec(spec) return spec == "m" or spec == "o" end

function R.Add(list, ids, spec, t)
  if not validList(list) then return nil, "not a list" end
  if type(ids) ~= "table" then return nil, "no ids" end
  if not validSpec(spec) then return nil, "bad spec" end
  local out = copyList(list)
  local report = { added = 0, dup = 0, full = 0 }
  local have = {}
  for _, item in ipairs(out.items) do have[item.id] = true end
  for _, id in ipairs(ids) do
    if R.ValidId(id) then
      if have[id] then
        report.dup = report.dup + 1
      elseif #out.items >= R.MAX then
        report.full = report.full + 1
      else
        have[id] = true
        out.items[#out.items + 1] = { id = id, spec = spec }
        report.added = report.added + 1
      end
    end
  end
  if report.added > 0 then out.changed = t end
  return out, report
end

function R.Remove(list, i, t)
  if not validList(list) then return nil, "not a list" end
  if not validIndex(list, i) then return nil, "no such item" end
  local out = copyList(list)
  table.remove(out.items, i)
  out.changed = t
  return out
end

function R.Move(list, i, dir, t)
  if not validList(list) then return nil, "not a list" end
  if not validIndex(list, i) then return nil, "no such item" end
  if dir ~= -1 and dir ~= 1 then return nil, "bad direction" end
  local j = i + dir
  if not validIndex(list, j) then return nil, "already at the edge" end
  local out = copyList(list)
  out.items[i], out.items[j] = out.items[j], out.items[i]
  out.changed = t
  return out
end

function R.SetSpec(list, i, spec, t)
  if not validList(list) then return nil, "not a list" end
  if not validIndex(list, i) then return nil, "no such item" end
  if not validSpec(spec) then return nil, "bad spec" end
  local out = copyList(list)
  out.items[i].spec = spec
  out.changed = t
  return out
end

-- marks are not edits: list.changed stays as it was
function R.MarkHas(list, heldFn)
  if not validList(list) then return nil, "not a list" end
  if type(heldFn) ~= "function" then return nil, "no reader" end
  local out, changed = copyList(list), false
  for _, item in ipairs(out.items) do
    local held
    if R.ValidId(item.id) then held = heldFn(item.id) end
    if held == true and item.has ~= true then
      item.has, changed = true, true
    elseif held == false and item.has == true then
      item.has, changed = nil, true
    end
  end
  return out, changed
end

local function items(n) return n == 1 and "1 item" or (n .. " items") end

function R.Sentence(report)
  if type(report) ~= "table" then return nil end
  local added, dup, full = tonumber(report.added) or 0, tonumber(report.dup) or 0, tonumber(report.full) or 0
  if full > 0 and added > 0 then return "Added " .. items(added) .. "; your list is full: " .. R.MAX .. " items." end
  if full > 0 then return "Your list is full: " .. R.MAX .. " items." end
  if added > 0 and dup > 0 then return "Added " .. items(added) .. "; " .. items(dup) .. " already on your list." end
  if added > 0 then return "Added " .. items(added) .. "." end
  if dup > 0 then return "Already on your list: " .. items(dup) .. "." end
  return nil
end

-- ---------- the record codec ----------

local function digits(n) return string.format("%.0f", n) end

function R.PackBody(list)
  if not validList(list) then return nil, "not a list" end
  if #list.items > R.MAX then return nil, "too many items" end
  local changed = list.changed or 0
  if type(changed) ~= "number" or changed < 0 or changed >= NUM_MAX or changed % 1 ~= 0 then
    return nil, "bad changed"
  end
  local cells, seen = { "W1," .. digits(changed) }, {}
  for _, item in ipairs(list.items) do
    if type(item) ~= "table" or not R.ValidId(item.id) then return nil, "bad id" end
    if not validSpec(item.spec) then return nil, "bad spec" end
    if seen[item.id] then return nil, "id twice" end
    seen[item.id] = true
    cells[#cells + 1] = digits(item.id) .. item.spec .. (item.has == true and "g" or "")
  end
  local body = table.concat(cells, ";")
  if #body > R.BODY_MAX then return nil, "too big" end
  return body
end

function R.UnpackBody(body, now)
  if type(body) ~= "string" or #body > R.BODY_MAX then return nil, "too big" end
  if type(now) ~= "number" then return nil, "no time" end
  local cells = {}
  for c in (body .. ";"):gmatch("([^;]*);") do
    cells[#cells + 1] = c
    if #cells > R.MAX + 1 then return nil, "too many items" end
  end
  local version, changedText = cells[1]:match("^W(%d+),?([^,]*)")
  if not version or #version > 3 then return nil, "bad head" end
  if version ~= "1" then return { newer = true } end
  local changed = numOf(changedText)
  if not changed then return nil, "bad changed" end
  if changed > now + R.FUTURE then return nil, "changed in the future" end
  local out, seen = { changed = changed, items = {} }, {}
  for i = 2, #cells do
    local idText, flags = cells[i]:match("^(%d+)(%l*)")
    local after = idText and cells[i]:sub(#idText + #flags + 1, #idText + #flags + 1)
    if not idText or (after ~= "" and after ~= ":") then return nil, "bad item" end
    local id = idOf(idText)
    if not id then return nil, "bad id" end
    if seen[id] then return nil, "id twice" end
    seen[id] = true
    local item = { id = id, spec = flags:find("o", 1, true) and "o" or "m" }
    if flags:find("g", 1, true) then item.has = true end
    out.items[#out.items + 1] = item
  end
  return out
end

-- "key,rev,hash;..." -> entries, or nil for more than 500 or one malformed entry
local function entriesOf(text)
  local entries = {}
  if text == "" then return entries end
  for e in (text .. ";"):gmatch("([^;]*);") do
    if #entries >= R.ENTRIES_MAX then return nil end
    local key, revText, hash = e:match("^([^,]*),([^,]*),([^,]*)$")
    local rev = numOf(revText)
    if not validKey(key) or not rev or not validHash(hash) then return nil end
    entries[#entries + 1] = { key = key, rev = rev, hash = hash }
  end
  return entries
end

function R.UnpackMsg(logical, proto, t)
  if type(logical) ~= "string" or logical:sub(2, 2) ~= "~" then return nil end
  local kind, rest = logical:sub(1, 1), logical:sub(3)
  if kind == "H" then
    if not validRoundHash(rest) then return nil end
    return { t = "H", hash = rest }
  elseif kind == "D" or kind == "R" then
    local entries = entriesOf(rest)
    if not entries then return nil end
    return { t = kind, entries = entries }
  elseif kind == "P" then
    local key, revText, hash, body = rest:match("^([^~]*)~([^~]*)~([^~]*)~(.*)$")
    local rev = numOf(revText)
    if not validKey(key) or not rev or not validHash(hash) then return nil end
    local list = R.UnpackBody(body, t)
    if not list then return nil end
    local msg = { t = "P", key = key, rev = rev, hash = hash, body = body }
    if list.newer then msg.newer = true else msg.list = list end
    return msg
  end
  return nil
end

-- ---------- the wants line ----------

-- anchored at both ends; the data is item-string characters only and the name holds no |, ] or control byte
-- (a newline would split the chat line, a NUL cut it short)
local LINK_FF = "^|cff%x%x%x%x%x%x|Hitem:%d[%d:%-]*|h%[[^|%]%c]+%]|h|r$"
local LINK_IQ = "^|cnIQ%d+:|Hitem:%d[%d:%-]*|h%[[^|%]%c]+%]|h|r$"
local LINK_MAX = 400     -- bytes; a game item link is well under this

function R.WholeLink(text)
  if type(text) ~= "string" or #text > LINK_MAX then return nil end
  if text:match(LINK_FF) or text:match(LINK_IQ) then return text end
  return nil
end

local function oneLine(lines)
  if type(lines) == "table" and #lines == 1 and type(lines[1]) == "string" then return lines[1] end
  return nil
end

function R.SayLine(itemText, rows, max, pack)
  if type(rows) ~= "table" then return nil, "no rows" end
  if type(max) ~= "number" or max ~= max or max <= 0 or max % 1 ~= 0 then return nil, "max" end
  if type(pack) ~= "function" then return nil, "no pack" end
  if type(itemText) ~= "string" then return nil, "head" end
  local head = "Wants " .. itemText .. ": "
  if #head >= max then return nil, "head" end
  -- a row with no name gives no entry
  local entries = {}
  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.name) == "string" and row.name ~= "" then
      entries[#entries + 1] = row.name .. (row.spec == "o" and " (os)" or "") .. (row.has == true and " (has it)" or "")
    end
  end
  local n = #entries
  if n == 0 then return nil, "no rows" end
  local lines = pack(head, entries, max)
  if type(lines) == "table" and #lines == 0 then return nil, "no rows" end
  local line = oneLine(lines)
  if line then return line end
  -- one line holds at most this many entries (each is 1 byte or more, with ", " between), so the retries stay short
  local k = math.min(n - 1, math.floor((max - #head + 2) / 3))
  while k >= 1 do
    local tail = " +" .. (n - k) .. " more"
    local first = {}
    for i = 1, k do first[i] = entries[i] end
    line = oneLine(pack(head, first, max - #tail))
    if line then return line .. tail end
    k = k - 1
  end
  return nil, "too long"
end
