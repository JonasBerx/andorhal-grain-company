local _, ns = ...
if not ns.M then return end
-- RosterRules.lua: ticket 56 stage C, the pure draft rules and the lineup lines. No client calls.
-- A draft: { id, name, size, event, finish, made, groups = { [g] = { seat|false x5 } }, reserve = { seat... } };
-- seat = { name, class, role, off, out }. place = { g = n, s = n }, g 0 = reserve position s. Every edit runs on a
-- copy, then R.Check; a refusal leaves the draft unchanged and answers nil, reason. Names are answered raw (the
-- caller escapes), except the texts R.Matches answers, which are escaped.

local R = {}
ns.RosterRules = R

R.MAX_DRAFTS, R.MAX_RESERVE, R.TITLE_MAX = 12, 20, 40

local NAME_RULE = "A character name is letters only, 2 to 25 of them, with at most one space."
local TOO_LONG = "That name is too long to share."
local TITLE_LONG = "A roster name is 40 characters at most."
local SIZE = "A roster is 10, 20 or 40 players."
local GONE = "That draft is gone."
local LINKED = "Another draft is linked to that raid."
local TAKEN = "That seat is taken."
local RESERVE = "The reserve list holds 20 at most."
local NO_SEAT = "That seat is not on this roster."
local NOBODY = "Nobody sits there."
local TOO_BIG = "This roster is too big to share."
local WIDEST_GEN = 4102444800 -- the widest gen cell Codec reads

-- The class words Codec writes (the class menu of a seat outside the guild) and the role letters with their words.
local WORDS = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid",
  "Death Knight", "Monk", "Demon Hunter", "Evoker" }
local ROLE_WORD = { T = "tank", H = "healer", D = "dps" }
R.CLASS_WORDS, R.ROLE_WORD = WORDS, ROLE_WORD
local SIGNUP_ROLE = { Tank = "T", Healer = "H", ["Melee DPS"] = "D", ["Ranged DPS"] = "D" }
local CLASS_ROLE = { Warrior = "T", Priest = "H", Paladin = "H", Druid = "H", Shaman = "H" }

local function lower(n) return type(n) == "string" and string.lower(n) or nil end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- A seat to read: a table with a string name (a hand-edited seat that is not is skipped).
local function seatOk(x) return type(x) == "table" and type(x.name) == "string" end

-- fn(seat) for every taken seat of a draft or lineup l: its groups, then its reserve.
local function eachSeat(l, fn)
  for _, grp in ipairs(type(l.groups) == "table" and l.groups or {}) do
    if type(grp) == "table" then
      for s = 1, 5 do if seatOk(grp[s]) then fn(grp[s]) end end
    end
  end
  for _, x in ipairs(type(l.reserve) == "table" and l.reserve or {}) do if seatOk(x) then fn(x) end end
end

local function validSize(size) return size == 10 or size == 20 or size == 40 end

local function emptyGroups(size)
  local groups = {}
  for g = 1, size / 5 do groups[g] = { false, false, false, false, false } end
  return groups
end

-- ---------- class words ----------

function R.Token(class)
  if type(class) ~= "string" then return nil end
  local t = string.upper((string.gsub(class, "%s", "")))
  if t == "" then return nil end
  return t
end

local WORD_OF = {}
for _, w in ipairs(WORDS) do WORD_OF[R.Token(w)] = w end
function R.Word(class)
  local t = R.Token(class)
  return t and WORD_OF[t] or nil
end

-- ---------- names ----------

-- One two-byte letter: U+00C0-U+00FF less U+00D7 and U+00F7, U+0100-U+024F, U+0400-U+047F.
local function letter2(a, b)
  if not b or b < 0x80 or b > 0xBF then return false end
  if a == 0xC3 then return b ~= 0x97 and b ~= 0xB7 end
  if a >= 0xC4 and a <= 0xC8 then return true end
  if a == 0xC9 then return b <= 0x8F end
  return a == 0xD0 or a == 0xD1
end

function R.Name(text)
  if type(text) ~= "string" then return nil, NAME_RULE end
  local s = string.match((string.gsub(text, "%s+", " ")), "^ ?(.-) ?$")
  local n, i, spaces = 0, 1, 0
  while i <= #s do
    local b = string.byte(s, i)
    if b == 32 then
      spaces = spaces + 1
      if spaces > 1 then return nil, NAME_RULE end
      i = i + 1
    elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
      i = i + 1
    elseif letter2(b, string.byte(s, i + 1)) then
      i = i + 2
    else
      return nil, NAME_RULE
    end
    n = n + 1
  end
  if n < 2 or n > 25 then return nil, NAME_RULE end
  if #s > 40 then return nil, TOO_LONG end
  return s
end

-- A roster name: controls stripped, spaces trimmed, at most R.TITLE_MAX characters (UTF-8 lead bytes, as Codec).
local function title(text)
  local s = string.gsub(tostring(text or ""), "[%z\1-\31\127]", "")
  s = string.match(s, "^%s*(.-)%s*$")
  local count = 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b < 128 or b > 191 then count = count + 1 end
  end
  if count == 0 then return nil, "Give the roster a name." end
  if count > R.TITLE_MAX then return nil, TITLE_LONG end
  return s
end

-- ---------- ids ----------

-- A time id plus one, on the string (carry, no tonumber); nil past 20 digits.
function R.NextId(id)
  if type(id) ~= "string" or not string.match(id, "^%d+$") then return nil end
  local digits = {}
  for k = 1, #id do digits[k] = string.sub(id, k, k) end
  local i = #id
  while i >= 1 do
    if digits[i] == "9" then
      digits[i] = "0"
      i = i - 1
    else
      digits[i] = string.char(string.byte(digits[i]) + 1)
      break
    end
  end
  local out = table.concat(digits)
  if i == 0 then out = "1" .. out end
  if #out > 20 then return nil end
  return out
end

local function raidId(id) return type(id) == "string" and string.match(id, "^%d+$") ~= nil and #id <= 20 end

-- Another draft in drafts (not d) linked to raid id.
local function linkedElsewhere(drafts, id, d)
  for _, x in pairs(drafts or {}) do
    if type(x) == "table" and x ~= d and x.event == id then return true end
  end
  return false
end

-- ---------- check ----------

function R.Check(d, keyFn)
  keyFn = keyFn or lower
  if type(d) ~= "table" or not validSize(d.size) then return nil, SIZE end
  local items, seen = {}, {}
  local function add(x, g, s)
    if type(x) ~= "table" or type(x.name) ~= "string" or x.name == "" then return NOBODY end
    if #x.name > 40 then return TOO_LONG end
    local key = keyFn(x.name)
    if key then
      if seen[key] then return x.name .. " is already on this roster." end
      seen[key] = true
    end
    items[#items + 1] = { group = g, seat = s, name = x.name }
  end
  for g, grp in pairs(d.groups or {}) do
    if type(g) ~= "number" or type(grp) ~= "table" then return nil, NO_SEAT end
    for s = 1, 5 do
      if grp[s] then
        local why = add(grp[s], g, s)
        if why then return nil, why end
      end
    end
  end
  for _, x in ipairs(d.reserve or {}) do
    local why = add(x, 0, 0)
    if why then return nil, why end
  end
  local good, why = ns.Codec.RosterCheck(d.size, items)
  if not good then
    if why == "reserve" then return nil, RESERVE end
    if why == "taken" then return nil, TAKEN end
    if why == "person" then return nil, "Someone is on this roster twice." end
    return nil, NO_SEAT
  end
  local bodies = ns.Codec.EncodeRoster({ id = d.id, name = d.name, size = d.size, event = d.event, finish = d.finish,
    groups = d.groups, reserve = d.reserve }, WIDEST_GEN, d.made)
  if type(bodies) ~= "table" then return nil, TOO_BIG end
  return true
end

-- Run change on a copy of d, check the copy, then put its fields back into d (the same table).
local function apply(d, change, keyFn)
  if type(d) ~= "table" then return nil, GONE end
  local c = copy(d)
  local res, why = change(c)
  if res == nil then return nil, why end
  local good, whyC = R.Check(c, keyFn)
  if not good then return nil, whyC end
  for k in pairs(d) do d[k] = nil end
  for k, v in pairs(c) do d[k] = v end
  return res
end

-- ---------- drafts ----------

function R.New(drafts, opts, t, heldKeys)
  drafts, opts, heldKeys = drafts or {}, opts or {}, heldKeys or {}
  local count = 0
  for _, x in pairs(drafts) do if type(x) == "table" then count = count + 1 end end
  if count >= R.MAX_DRAFTS then return nil, "12 drafts at most." end
  local name, whyT = title(opts.name)
  if not name then return nil, whyT end
  if not validSize(opts.size) then return nil, SIZE end
  local event = opts.event
  if event ~= nil then
    if not raidId(event) then return nil, "That raid cannot be linked." end
    if linkedElsewhere(drafts, event, nil) then return nil, LINKED end
  end
  local function used(id)
    if drafts[id] or heldKeys["g" .. id] then return true end
    for _, x in pairs(drafts) do if type(x) == "table" and x.id == id then return true end end
    return false
  end
  local id
  if event ~= nil and not used(event) then
    id = event
  else
    id = tostring(t)
    while id and used(id) do id = R.NextId(id) end
    if not id or not raidId(id) then return nil, "No free id for this draft." end
  end
  local d = { id = id, name = name, size = opts.size, event = event, finish = event and opts.finish or nil, made = t,
    groups = emptyGroups(opts.size), reserve = {} }
  local good, why = R.Check(d)
  if not good then return nil, why end
  return d
end

function R.Discard(drafts, id)
  if type(drafts) ~= "table" or id == nil or drafts[id] == nil then return nil, GONE end
  drafts[id] = nil
  return true
end

function R.Rename(d, text)
  local name, why = title(text)
  if not name then return nil, why end
  return apply(d, function(c) c.name = name; return true end)
end

function R.Link(d, event, drafts)
  if event ~= nil then
    if type(event) ~= "table" or not raidId(event.id) then return nil, "That raid cannot be linked." end
    if linkedElsewhere(drafts, event.id, d) then return nil, LINKED end
  end
  return apply(d, function(c)
    c.event = event and event.id or nil
    c.finish = event and event.finish or nil
    return true
  end)
end

function R.Resize(d, size)
  if not validSize(size) then return nil, SIZE end
  return apply(d, function(c)
    local from, to = #c.groups, size / 5
    for g = to + 1, from do
      for s = 1, 5 do
        if c.groups[g][s] then
          return nil, "Move the people out of groups " .. (to + 1) .. " to " .. from .. " first."
        end
      end
    end
    for g = to + 1, from do c.groups[g] = nil end
    for g = from + 1, to do c.groups[g] = { false, false, false, false, false } end
    c.size = size
    return true
  end)
end

-- ---------- seats ----------

-- The value at a place (false for an empty seat), or nil, reason for a place not on the roster.
local function at(c, p)
  if type(p) ~= "table" then return nil, NO_SEAT end
  if p.g == 0 then
    local x = c.reserve[p.s]
    if x == nil then return nil, NO_SEAT end
    return x
  end
  local grp = c.groups[p.g]
  if type(grp) ~= "table" or type(p.s) ~= "number" or p.s < 1 or p.s > 5 then return nil, NO_SEAT end
  return grp[p.s]
end

local function put(c, p, v)
  if p.g == 0 then c.reserve[p.s] = v else c.groups[p.g][p.s] = v end
end

-- The reserve with emptied places closed up.
local function close(c)
  local out = {}
  for i = 1, table.maxn(c.reserve) do if c.reserve[i] then out[#out + 1] = c.reserve[i] end end
  c.reserve = out
end

function R.FirstRole(name, key, ctx)
  ctx = ctx or {}
  local keyFn = ctx.keyFn or lower
  key = key or keyFn(name)
  if key == nil then return nil end
  for _, s in ipairs(ctx.signups or {}) do
    if (s.key or keyFn(s.character)) == key and SIGNUP_ROLE[s.role] then return SIGNUP_ROLE[s.role] end
  end
  local best, role
  for _, l in ipairs(ctx.lineups or {}) do
    local found, r = false, nil
    eachSeat(l, function(x)
      if type(x) == "table" and (x.key or keyFn(x.name)) == key then found, r = true, x.role end
    end)
    if found then
      local la, ba = tonumber(l.at) or 0, best and (tonumber(best.at) or 0)
      local lk, bk = tostring(l.key or ""), best and tostring(best.key or "")
      if not best or la > ba or (la == ba and (#lk > #bk or (#lk == #bk and lk > bk))) then best, role = l, r end
    end
  end
  return role
end

function R.Add(d, person, place, ctx)
  ctx = ctx or {}
  local keyFn = ctx.keyFn or lower
  if type(person) ~= "table" or type(person.name) ~= "string" then return nil, NAME_RULE end
  local name = person.name
  if person.out then
    local why
    name, why = R.Name(name)
    if not name then return nil, why end
  end
  local key = keyFn(name)
  return apply(d, function(c)
    local seated = false
    eachSeat(c, function(x)
      if x.name == name or (key and keyFn(x.name) == key) then seated = true end
    end)
    if seated then return nil, name .. " is already on this roster." end
    local p
    if place == nil then
      for g = 1, #c.groups do
        for s = 1, 5 do if not p and not c.groups[g][s] then p = { g = g, s = s } end end
      end
    end
    if p == nil and (place == nil or place == "reserve" or (type(place) == "table" and place.g == 0)) then
      if #c.reserve >= R.MAX_RESERVE then return nil, RESERVE end
      p = { g = 0, s = #c.reserve + 1 }
    elseif p == nil then
      local x, why = at(c, place)
      if x == nil then return nil, why end
      if x then return nil, TAKEN end
      p = { g = place.g, s = place.s }
    end
    put(c, p, { name = name, class = R.Word(person.class), role = R.FirstRole(name, key, ctx),
      out = person.out and true or nil })
    return p
  end, keyFn)
end

function R.Swap(d, a, b)
  return apply(d, function(c)
    local va, whyA = at(c, a)
    if va == nil then return nil, whyA end
    local vb, whyB = at(c, b)
    if vb == nil then return nil, whyB end
    put(c, a, vb)
    put(c, b, va)
    close(c)
    return true
  end)
end

function R.ToReserve(d, place)
  return apply(d, function(c)
    if type(place) ~= "table" or place.g == 0 then return nil, NO_SEAT end
    local x, why = at(c, place)
    if x == nil then return nil, why end
    if not x then return nil, NOBODY end
    if #c.reserve >= R.MAX_RESERVE then return nil, RESERVE end
    put(c, place, false)
    c.reserve[#c.reserve + 1] = x
    return true
  end)
end

function R.Remove(d, place)
  return apply(d, function(c)
    local x, why = at(c, place)
    if x == nil then return nil, why end
    if not x then return nil, NOBODY end
    put(c, place, false)
    close(c)
    return true
  end)
end

function R.Set(d, place, field, value)
  return apply(d, function(c)
    local x, why = at(c, place)
    if x == nil then return nil, why end
    if not x then return nil, NOBODY end
    if field == "role" or field == "off" then
      if value ~= nil and not ROLE_WORD[value] then return nil, "A role is tank, healer or dps." end
      x[field] = value
    elseif field == "class" then
      if not x.out then return nil, "Class is set only for someone outside the guild." end
      if value ~= nil and not R.Word(value) then return nil, "That is not a class." end
      x.class = R.Word(value)
    else
      return nil, "That cannot be set."
    end
    return true
  end)
end

-- ---------- the Add box ----------

function R.Matches(text, d, ctx)
  ctx = ctx or {}
  local keyFn = ctx.keyFn or lower
  local esc = ns.Escape
  local entries = {}
  local typed = string.match(tostring(text or ""), "^%s*(.-)%s*$")
  if typed == "" then return entries end
  local low = string.lower(typed)
  local seated, offered = {}, {}
  if type(d) == "table" then eachSeat(d, function(x) seated[keyFn(x.name) or x.name] = true end) end
  for _, s in ipairs(ctx.signups or {}) do
    local name = s.character
    local key = type(name) == "string" and name ~= "" and (s.key or keyFn(name)) or nil
    if key and not seated[key] and not offered[key] and string.find(string.lower(name), low, 1, true) then
      offered[key] = true
      entries[#entries + 1] = { text = esc(name) .. " (sign-up: " .. tostring(s.role ~= "" and s.role or "no role")
        .. ", " .. tostring(s.kind) .. ")", value = { name = name, class = s.class } }
    end
  end
  local guild = {}
  for key, row in pairs(ctx.rows or {}) do
    if type(row) == "table" and type(row.name) == "string" and not seated[key] and not offered[key]
      and string.find(string.lower(row.name), low, 1, true) then
      guild[#guild + 1] = row
    end
  end
  table.sort(guild, function(a, b) return a.name < b.name end)
  for i = 1, math.min(#guild, 10) do
    local row = guild[i]
    entries[#entries + 1] = { text = esc(row.name) .. " (guild)", value = { name = row.name, class = row.class } }
  end
  local name, why = R.Name(typed)
  if name then
    local key = keyFn(name)
    if key and seated[key] then
      why = name .. " is already on this roster."
    elseif not (key and ((ctx.rows or {})[key] or offered[key])) then
      entries[#entries + 1] = { text = esc(name) .. " (not in the guild)", value = { name = name, out = true } }
    end
  end
  if #entries > 0 then why = nil end
  return entries, why
end

-- ---------- lines ----------

function R.CountLine(groups)
  local n = { T = 0, H = 0, D = 0, none = 0 }
  for _, grp in ipairs(type(groups) == "table" and groups or {}) do
    for s = 1, 5 do
      local x = type(grp) == "table" and grp[s]
      if seatOk(x) then
        local r = ROLE_WORD[x.role] and x.role or "none"
        n[r] = n[r] + 1
      end
    end
  end
  return n.T .. (n.T == 1 and " tank, " or " tanks, ") .. n.H .. (n.H == 1 and " healer, " or " healers, ")
    .. n.D .. " dps, " .. n.none .. " not set"
end

function R.YouLine(lineup, meKey)
  if type(lineup) ~= "table" or meKey == nil then return nil end
  for g, grp in ipairs(lineup.groups or {}) do
    for s = 1, 5 do
      local x = grp[s]
      if type(x) == "table" and x.key == meKey then
        local line = "group " .. g
        if ROLE_WORD[x.role] then line = line .. " as " .. ROLE_WORD[x.role] end
        if ROLE_WORD[x.off] then line = line .. " (off-spec " .. ROLE_WORD[x.off] .. ")" end
        return line
      end
    end
  end
  for _, x in ipairs(lineup.reserve or {}) do
    if type(x) == "table" and x.key == meKey then return "on the reserve list" end
  end
  return nil
end

-- ---------- demo (D9) ----------

local OUTSIDERS = {
  { "Tarn Vale", "Warrior" }, { "Mira Holt", "Priest" }, { "Odo Fell", "Mage" }, { "Sela Brook", "Druid" },
  { "Kade Moor", "Rogue" }, { "Lune Ash", "Hunter" }, { "Bram Stone", "Paladin" }, { "Iris Wren", "Warlock" },
  { "Joss Reed", "Shaman" }, { "Nell Frost", "Priest" }, { "Rook Hale", "Warrior" }, { "Vey Thorn", "Mage" },
  { "Ada Marsh", "Rogue" }, { "Cort Lyle", "Hunter" }, { "Elm Gray", "Druid" }, { "Fay Dorn", "Warlock" },
  { "Gus Pike", "Paladin" }, { "Hale Burr", "Shaman" }, { "Isla Crane", "Mage" }, { "Jory Flint", "Warrior" },
  { "Kip Rowe", "Priest" }, { "Lark Shaw", "Rogue" }, { "Mace Holm", "Hunter" }, { "Nia Dale", "Warlock" },
  { "Orin Sedge", "Mage" }, { "Pell Brand", "Druid" }, { "Quin Ashby", "Warrior" }, { "Rue Banner", "Priest" },
  { "Sorn Gale", "Rogue" }, { "Tess Ivy", "Mage" }, { "Ulf Marrow", "Hunter" }, { "Vida Lorne", "Shaman" },
}

-- Made-up rosters over the demo guild: a 10 of the guild, a 20 and a linked 40 of the guild and outsiders; the
-- player sits in the 40's group 2 seat 1 (healer, off-spec dps) when me is given.
function R.DemoRecords(people, link, t, me)
  local meKey = lower(me)
  local list, taken = {}, {}
  for _, p in ipairs(people or {}) do
    local key = lower(p.name)
    if key and key ~= meKey and not taken[key] then
      taken[key] = true
      local word = R.Word(p.class)
      list[#list + 1] = { name = p.name, class = word, role = CLASS_ROLE[word] or "D" }
    end
  end
  for _, o in ipairs(OUTSIDERS) do
    local key = lower(o[1])
    if key ~= meKey and not taken[key] then
      list[#list + 1] = { name = o[1], class = o[2], role = CLASS_ROLE[o[2]] or "D", outsider = true }
    end
  end
  local function roster(size, guildOnly, seatMe)
    local groups, reserve, i = emptyGroups(size), {}, 0
    if seatMe then groups[2][1] = { name = me, role = "H", off = "D" } end
    for g = 1, size / 5 do
      for s = 1, 5 do
        if not groups[g][s] then
          repeat i = i + 1 until not list[i] or not (guildOnly and list[i].outsider)
          local p = list[i]
          if p then groups[g][s] = { name = p.name, class = p.class, role = p.role } end
        end
      end
    end
    if size == 40 then
      for _ = 1, 2 do
        i = i + 1
        local p = list[i]
        if p then reserve[#reserve + 1] = { name = p.name, class = p.class, role = p.role } end
      end
    end
    return groups, reserve
  end
  local base = tostring(t)
  local ids = { base, R.NextId(base), R.NextId(R.NextId(base)) }
  local linkId = link and raidId(link.id) and link.id or nil
  local records = {}
  local function add(id, name, size, guildOnly, linked)
    local groups, reserve = roster(size, guildOnly, linked and me ~= nil)
    local bodies = ns.Codec.EncodeRoster({ id = id, name = name, size = size, event = linked and linkId or nil,
      finish = linked and link.finish or nil, groups = groups, reserve = reserve }, t, t)
    for key, body in pairs(bodies or {}) do records[key] = { rev = t, hash = "", by = "demo", body = body } end
  end
  add(ids[1], "Alt run 10", 10, true, false)
  add(ids[2], "Weekend 20", 20, false, false)
  local fortyId = ids[3]
  if linkId and linkId ~= ids[1] and linkId ~= ids[2] then fortyId = linkId end
  add(fortyId, "Main raid 40", 40, false, linkId ~= nil)
  return records
end
