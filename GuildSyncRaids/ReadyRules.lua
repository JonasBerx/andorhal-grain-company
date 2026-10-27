local _, ns = ...
if not ns.M then return end

-- Pure ready-check rules (S9 L2, Raids 0.5 Ready): sorting the own auras into the four categories (Classify), the
-- raids_r wire text of a report and of an ask (Pack / Unpack), the leader's table (Table), who misses what (Missing,
-- Summary, Answered) and the raid chat line (ChatLine). No client calls; only string, table, math.
-- Wire text: fields joined by FSEP "~", the ids of one category joined by LSEP ",", numbers in decimal, keys verbatim.
--   report: Y ~ key ~ at ~ leader ~ flask ids ~ elixir ids ~ food ids ~ world ids ~ fire
--   ask:    A ~ by ~ at ~ leader
-- A key, by or leader holding either separator is never packed and never accepted.

local ReadyRules = { CATS = { "flask", "elixir", "food", "world" }, MAXIDS = 8, MAXCHUNKS = 4, FIREMAX = 1000,
  KEYMAX = 48, SINCE = 60, ASKHOLD = 10, CHATMAX = 255, FSEP = "~", LSEP = "," }
ns.ReadyRules = ReadyRules
local R = ReadyRules

-- The hub's wire key rule (CommWire.lua Wire.Key): the part before a realm dash, spaces folded, lower case. A copy,
-- so Table needs no key function and this file stays pure.
local function wireKey(name)
  if type(name) ~= "string" then return nil end
  local k = (string.match(name, "^([^-]*)") or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

local function isInt(v) return type(v) == "number" and v == math.floor(v) end

-- ids (any list) -> { flask = {id}, elixir = {id}, food = {id}, world = {id} }: integer ids found in data, each once,
-- sorted, at most MAXIDS per category. Anything else is ignored.
function R.Classify(ids, data)
  local out, seen = { flask = {}, elixir = {}, food = {}, world = {} }, {}
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    local row = isInt(id) and not seen[id] and data[id]
    if row and out[row.cat] then
      seen[id] = true
      local list = out[row.cat]
      list[#list + 1] = id
    end
  end
  for _, cat in ipairs(R.CATS) do
    table.sort(out[cat])
    while #out[cat] > R.MAXIDS do table.remove(out[cat]) end
  end
  return out
end

-- A key field that can be packed: a string without either separator.
local function packable(k)
  return type(k) == "string" and not string.find(k, R.FSEP, 1, true) and not string.find(k, R.LSEP, 1, true)
end

-- msg -> wire text, or nil when a key field cannot be packed or t is unknown.
function R.Pack(msg)
  if type(msg) ~= "table" then return nil end
  if msg.t == "Y" then
    if not (packable(msg.key) and packable(msg.leader)) then return nil end
    local fields = { "Y", msg.key, tostring(msg.at), msg.leader }
    for _, cat in ipairs(R.CATS) do
      local ids = {}
      for i, id in ipairs(type(msg[cat]) == "table" and msg[cat] or {}) do ids[i] = tostring(id) end
      fields[#fields + 1] = table.concat(ids, R.LSEP)
    end
    fields[#fields + 1] = tostring(msg.fire)
    return table.concat(fields, R.FSEP)
  elseif msg.t == "A" then
    if not (packable(msg.by) and packable(msg.leader)) then return nil end
    return table.concat({ "A", msg.by, tostring(msg.at), msg.leader }, R.FSEP)
  end
  return nil
end

local function split(s, sep)
  local out, from = {}, 1
  while true do
    local a = string.find(s, sep, from, true)
    if not a then out[#out + 1] = string.sub(s, from) return out end
    out[#out + 1] = string.sub(s, from, a - 1)
    from = a + 1
  end
end

-- A non-negative decimal integer, or nil.
local function int(s) if type(s) == "string" and string.match(s, "^%d+$") then return tonumber(s) end end

-- wire text -> msg, or nil. key is the wire key rule (ns.Key in game): every key field must be its own key form, at
-- most KEYMAX bytes, without a separator; ids, at and fire are integers, fire 0-FIREMAX, at most MAXIDS ids each.
function R.Unpack(logical, key)
  if type(logical) ~= "string" or type(key) ~= "function" then return nil end
  local f = split(logical, R.FSEP)
  local function keyField(s)
    if #s > R.KEYMAX or string.find(s, R.LSEP, 1, true) or key(s) ~= s then return nil end
    return s
  end
  if f[1] == "Y" and #f == 9 then
    local msg = { t = "Y", key = keyField(f[2]), at = int(f[3]), leader = keyField(f[4]), fire = int(f[9]) }
    if not (msg.key and msg.at and msg.leader and msg.fire) or msg.fire > R.FIREMAX then return nil end
    for i, cat in ipairs(R.CATS) do
      local ids = {}
      if f[4 + i] ~= "" then
        for _, s in ipairs(split(f[4 + i], R.LSEP)) do
          local id = int(s)
          if not id then return nil end
          ids[#ids + 1] = id
        end
      end
      if #ids > R.MAXIDS then return nil end
      msg[cat] = ids
    end
    return msg
  elseif f[1] == "A" and #f == 4 then
    local msg = { t = "A", by = keyField(f[2]), at = int(f[3]), leader = keyField(f[4]) }
    if not (msg.by and msg.at and msg.leader) then return nil end
    return msg
  end
  return nil
end

-- The leader's table: one row per roster entry ({ guid, name }, PullRules.Snapshot's people) in roster order. A
-- report counts when it is for checkLeader's check and no older than checkAt - SINCE. The row whose guid is myGuid
-- is the own row, filled from own.read (cannot when nil). Answers rows and the number of reports from keys not on
-- the roster.
function R.Table(roster, reports, checkAt, checkLeader, own, myGuid)
  local rows, onRoster = {}, {}
  reports = type(reports) == "table" and reports or {}
  for _, p in ipairs(type(roster) == "table" and roster or {}) do
    local k = wireKey(p.name)
    if k then onRoster[k] = true end
    local row = { name = p.name, key = k, guid = p.guid, mine = false, cannot = false }
    if myGuid ~= nil and p.guid == myGuid then
      row.mine = true
      if own and own.read then row.report = own.read else row.cannot = true end
    else
      local msg = k and reports[k]
      if type(msg) == "table" and msg.leader == checkLeader and isInt(msg.at) and isInt(checkAt)
        and msg.at >= checkAt - R.SINCE then
        row.report = msg
      end
    end
    rows[#rows + 1] = row
  end
  local lost = 0
  for k in pairs(reports) do if not onRoster[k] then lost = lost + 1 end end
  return rows, lost
end

-- Per counted category (opts[cat] true), the names of answered rows with none of it; noAnswer for rows without a
-- report. A cannot row is in no list. A category switched off is absent.
function R.Missing(rows, opts)
  local out = { noAnswer = {} }
  for _, cat in ipairs(R.CATS) do if opts and opts[cat] then out[cat] = {} end end
  for _, row in ipairs(rows or {}) do
    if not row.cannot then
      if not row.report then
        out.noAnswer[#out.noAnswer + 1] = row.name
      else
        for _, cat in ipairs(R.CATS) do
          if out[cat] and #(row.report[cat] or {}) == 0 then out[cat][#out[cat] + 1] = row.name end
        end
      end
    end
  end
  return out
end

local LABEL = { flask = "Flask", elixir = "Elixirs", food = "Food", world = "World buffs" }

-- "Missing: flask 3, elixirs 1, food 2. No answer: 2.", empty parts left out; nil when nothing is missing.
function R.Summary(missing)
  local parts, out = {}, {}
  for _, cat in ipairs(R.CATS) do
    if missing[cat] and #missing[cat] > 0 then parts[#parts + 1] = string.lower(LABEL[cat]) .. " " .. #missing[cat] end
  end
  if #parts > 0 then out[#out + 1] = "Missing: " .. table.concat(parts, ", ") .. "." end
  if missing.noAnswer and #missing.noAnswer > 0 then out[#out + 1] = "No answer: " .. #missing.noAnswer .. "." end
  if #out == 0 then return nil end
  return table.concat(out, " ")
end

-- n answered (a cannot row is not), m rows.
function R.Answered(rows)
  local n = 0
  for _, row in ipairs(rows or {}) do if row.report and not row.cannot then n = n + 1 end end
  return n, #(rows or {})
end

-- "/raid Missing flask: A, B. Food: C. No answer: D.": the first category says "Missing", names lose every "|", and
-- the whole text is at most CHATMAX bytes; a cut text ends in "+N more", N the names left out. nil when nothing is
-- missing.
function R.ChatLine(missing)
  local parts, total = {}, 0
  for _, cat in ipairs(R.CATS) do
    local names = missing[cat]
    if names and #names > 0 then
      parts[#parts + 1] = { label = #parts == 0 and ("Missing " .. string.lower(LABEL[cat])) or LABEL[cat], names = names }
      total = total + #names
    end
  end
  if missing.noAnswer and #missing.noAnswer > 0 then
    parts[#parts + 1] = { label = "No answer", names = missing.noAnswer }
    total = total + #missing.noAnswer
  end
  if total == 0 then return nil end
  -- the text with the first k names
  local function text(k)
    local out, left = {}, k
    for _, part in ipairs(parts) do
      if left <= 0 then break end
      local names = {}
      for i = 1, math.min(left, #part.names) do names[i] = (string.gsub(tostring(part.names[i]), "|", "")) end
      left = left - #names
      out[#out + 1] = part.label .. ": " .. table.concat(names, ", ") .. "."
    end
    local s = "/raid " .. table.concat(out, " ")
    if k < total then s = s .. " +" .. (total - k) .. " more" end
    return s
  end
  for k = total, 1, -1 do
    local s = text(k)
    if #s <= R.CHATMAX then return s end
  end
  return nil
end
