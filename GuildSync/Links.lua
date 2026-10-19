-- Links: the hub's R9 alt-link pure rules (plan r-20261018-o696-one-list-the-roster-api-7-member-pa, "R9", d835 as
-- amended, gate A d836): the record body (Parse, Pack), its caps, and PersonOf (the roster filter first, then
-- supersession, the confirmed closure, the head record, the main, the unconfirmed links, and the own account).
-- Pure Lua 5.1, no client calls and no ns.DB; time is passed in. Loads after CommWire.lua (Wire.FUTURE).
local _, ns = ...
local Links = ns.Links or {}
ns.Links = Links

Links.VERSION = 1
Links.MAX_LINKS = 16           -- keys in one record, self included
Links.MAX_KEY = 64             -- bytes in one key

local Wire = ns.Comm.Wire

-- Body "1^<linksAt>^<pick or empty>^<key>~<key>..." -> rec = { v, linksAt, pick = key|nil, list = sorted keys } or
-- nil, why: "newer" (a format version above VERSION, the record held before is kept) | "bad". A repeated key is held
-- once, before the MAX_LINKS cap.
function Links.Parse(body, now)
  if type(body) ~= "string" then return nil, "bad" end
  local v = tonumber(body:match("^([^%^]*)"))
  if not v or v ~= v or v < 1 or v ~= math.floor(v) then return nil, "bad" end
  if v > Links.VERSION then return nil, "newer" end
  local at, pick, keys = body:match("^[^%^]*%^([^%^]*)%^([^%^]*)%^([^%^]*)$")
  if not at then return nil, "bad" end
  local linksAt = tonumber(at)
  if not linksAt or linksAt ~= linksAt or linksAt < 0 or linksAt > (tonumber(now) or 0) + Wire.FUTURE then
    return nil, "bad"
  end
  if #pick > Links.MAX_KEY then return nil, "bad" end
  local list, seen = {}, {}
  if keys ~= "" then
    for k in (keys .. "~"):gmatch("([^~]*)~") do
      if k == "" or #k > Links.MAX_KEY then return nil, "bad" end
      if not seen[k] then
        seen[k] = true
        list[#list + 1] = k
      end
    end
  end
  if #list > Links.MAX_LINKS then return nil, "bad" end
  table.sort(list)
  return { v = v, linksAt = linksAt, pick = pick ~= "" and pick or nil, list = list }
end

-- (linksAt, pick, keys) -> body. Keys are sent sorted; a pick that is not in keys is sent empty. The caller chooses
-- the keys (self plus the first 15 others, hidden ones left out); a hidden character's own body is Pack(t, nil, { self }).
function Links.Pack(linksAt, pick, keys)
  local list, inList = {}, false
  for i, k in ipairs(keys or {}) do
    list[i] = k
    if k == pick then inList = true end
  end
  table.sort(list)
  return Links.VERSION .. "^" .. tostring(linksAt) .. "^" .. (inList and pick or "") .. "^" .. table.concat(list, "~")
end

local function levelOf(levels, k)
  local row = levels[k]
  return type(row) == "table" and tonumber(row.level) or 0
end

-- The main of a set of keys: pick when it is in the set, else the highest level, a tie to the lowest key.
local function mainOf(set, pick, levels)
  if pick and set[pick] then return pick end
  local best, bestLevel
  for k in pairs(set) do
    local lv = levelOf(levels, k)
    if not best or lv > bestLevel or (lv == bestLevel and k < best) then best, bestLevel = k, lv end
  end
  return best
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function alone(key)
  return { key = key, main = key, chars = { key }, unconfirmed = {} }
end

-- PersonOf(key, recs, levels, mine) -> nil | { key, main = key, chars = { sorted keys }, unconfirmed = { sorted keys } }
--   recs:   { [key] = rec } as Parse gives them (list order is not relied on).
--   levels: the viewer's roster, { [key] = { name, level, class } }; keys not in it are dropped first (gate A).
--   mine:   nil | { keys = { [key] = true }, hidden = { [key] = true }, pick = key|nil }, this account's characters.
-- nil when key is not on the roster. Comm.Person (Api.lua) turns the keys into rows and orders them.
function Links.PersonOf(key, recs, levels, mine)
  if type(key) ~= "string" or type(levels) ~= "table" or levels[key] == nil then return nil end

  -- Own account: the records are not consulted.
  if type(mine) == "table" then
    if type(mine.hidden) == "table" and mine.hidden[key] then return alone(key) end
    if type(mine.keys) == "table" and mine.keys[key] then
      local set = {}
      for k in pairs(mine.keys) do
        if levels[k] ~= nil and not (type(mine.hidden) == "table" and mine.hidden[k]) then set[k] = true end
      end
      return { key = key, main = mainOf(set, mine.pick, levels), chars = sortedKeys(set), unconfirmed = {} }
    end
  end

  -- Roster filter: records of off-roster keys are not consulted; off-roster keys leave every list and pick.
  local R = {}
  for k, r in pairs(type(recs) == "table" and recs or {}) do
    if levels[k] ~= nil and type(r) == "table" and type(r.linksAt) == "number" and type(r.list) == "table" then
      local lists = {}
      for _, y in ipairs(r.list) do
        if y ~= k and levels[y] ~= nil then lists[y] = true end
      end
      local pick = r.pick
      if pick == "" or levels[pick] == nil then pick = nil end
      R[k] = { at = r.linksAt, lists = lists, pick = pick }
    end
  end

  -- Supersession (d835 step 0): X lists Y, and Y's newer record does not list X back.
  local superseded = {}
  for x, rx in pairs(R) do
    for y in pairs(rx.lists) do
      local ry = R[y]
      if ry and ry.at > rx.at and not ry.lists[x] then
        superseded[x] = true
        break
      end
    end
  end

  local own = R[key]
  if not own or superseded[key] then return alone(key) end

  -- Closure over confirmed links between records that are not superseded (step 1).
  local closure, queue = { [key] = true }, { key }
  local i = 1
  while queue[i] do
    local x = queue[i]
    i = i + 1
    for y in pairs(R[x].lists) do
      local ry = R[y]
      if not closure[y] and ry and not superseded[y] and ry.lists[x] then
        closure[y] = true
        queue[#queue + 1] = y
      end
    end
  end

  -- Head: the newest record, a tie to the lowest key (step 2); the person is the head plus what it lists (steps 3-4).
  local head
  for _, k in ipairs(sortedKeys(closure)) do
    if not head or R[k].at > R[head].at then head = k end
  end
  local person = { [head] = true }
  for k in pairs(closure) do
    if R[head].lists[k] then person[k] = true end
  end
  if not person[key] then return alone(key) end

  -- The asked key's own unconfirmed links: no record, or a record not newer that does not list it back.
  local unconfirmed = {}
  for y in pairs(own.lists) do
    local ry = R[y]
    if not ry or (ry.at <= own.at and not ry.lists[key]) then unconfirmed[y] = true end
  end

  return {
    key = key, main = mainOf(person, R[head].pick, levels),
    chars = sortedKeys(person), unconfirmed = sortedKeys(unconfirmed),
  }
end

return Links
