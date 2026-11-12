-- GuildSyncExpeditions Record.lua: the shared record (0.19 plan, Seams 12; slice I plan, "The body").
--   ns.Rec.MAX_BODY                      read at call time by Pack
--   ns.Rec.Pack(view) -> body | nil, "field" | "too big"
--   ns.Rec.Unpack(body) -> view | nil    nil only for a malformed field; a follower also gets pieces = { [slot] = piece }
--   ns.OwnView() -> view                 reads only: no settle, no grain (R-quiet); ns.OwnOfficer is read when it exists;
--                                        acct is the token only for a Person of two or more characters, else "00000000"
--   ns.AccountToken() -> 8 hex           written once in the acct part; "00000000" in demo
-- A view: { v, acct, followers = { { name, race, class, sex, level, state, wins, deadly, look, traits, gear, pieces } },
--   flair = { title, badges, trophies, quests }, collection = { relics, sets, chains, badges } (numbers, bit sets as they
--   arrived), deadly, runs, finds = { { code, who, day, region } }, officer = { bank, at, hides = { { owner, name } } } }.
-- Everything a record claims is bounded here, so nothing else has to trust it. The body holds no escape byte: Pack and
-- Unpack both go through the positive set.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local D, FC, GD, QD, BD = ns.FollowerData, ns.FollowerCore, ns.GearData, ns.QuestData, ns.BookData

local Rec = { MAX_BODY = 1711 }
ns.Rec = Rec

local NOT_ALLOWED = "[^%w %^!%.%+%-\128-\255]"
local HEX8 = "^%x%x%x%x%x%x%x%x$"
local RECORD_TOP = 5000000
local DAY_TOP, AT_TOP = 999999, 9999999999
local BITS_TOP = 4294967295
local MAX_FOLLOWERS, MAX_FINDS, MAX_LIST, MAX_HIDES = 5, 5, 16, 10
local KEY_MAX = 50
local GEAR_LEN = 48
local BROKEN = "abcdef"
local LETTER = { idle = "i", out = "o", rest = "r", dead = "d" }
local STATE_OK = { i = true, b = true, o = true, r = true, d = true }

local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local at = string.find(s, sep, pos, true)
    if not at then
      out[#out + 1] = string.sub(s, pos)
      return out
    end
    out[#out + 1] = string.sub(s, pos, at - 1)
    pos = at + 1
  end
end

-- Digits only and a length cap before tonumber, so nan, inf, 1e309, 0x.. and signs never parse.
local function int(s, digits, lo, hi)
  if #s > digits or not string.match(s, "^%d+$") then return nil end
  local n = tonumber(s)
  if n < lo or n > hi then return nil end
  return n
end

local function bits(s)
  if #s > 8 or not string.match(s, "^%x+$") then return nil end
  return tonumber(s, 16)
end

-- Shortest lower-case hex. Not %x: the client's Lua casts to a 32-bit signed long, which cannot hold the top bit.
local function hex(n)
  if type(n) ~= "number" or n < 0 or n > BITS_TOP or n ~= math.floor(n) then return "?" end
  if n == 0 then return "0" end
  local out = ""
  while n > 0 do
    local d = n % 16
    out = string.sub("0123456789abcdef", d + 1, d + 1) .. out
    n = math.floor(n / 16)
  end
  return out
end

local function text(s, max, pattern)
  if #s > max or not string.match(s, pattern) then return nil end
  return s
end

local function isKey(s) return #s >= 1 and #s <= KEY_MAX end

local function idList(s)
  if s == "-" then return {} end
  local out = split(s, "+")
  if #out > MAX_LIST then return nil end
  for _, id in ipairs(out) do
    if not string.match(id, "^%l%d$") then return nil end
  end
  return out
end

-- One bad triple empties its slot and keeps the record (R-rows); an unknown code scores 0 and stays (R-codes).
local function parsePieces(gear)
  local pieces = {}
  for i, slot in ipairs(GD.SLOTS) do
    local code, third = string.match(string.sub(gear, i * 3 - 2, i * 3), "^([0-9A-Za-z][0-9A-Za-z])([0-9A-Za-z])$")
    if code then
      local temper, broken = tonumber(third), false
      if not temper or temper > 5 then
        local at = string.find(BROKEN, third, 1, true)
        temper = at and at - 1 or 0
        broken = at ~= nil
      end
      pieces[slot.key] = { row = code, temper = temper, broken = broken, unknown = GD.Row(code) == nil or nil }
    end
  end
  return pieces
end

local function parseFollower(line)
  local p = split(line, ".")
  if #p ~= 13 or not FC.ValidName(p[1]) then return nil end
  local race, class = text(p[2], 8, "^%u%l+$"), text(p[3], 7, "^%a+$")
  local level = int(p[5], 2, 1, D.MAX_LEVEL)
  local wins, deadly = int(p[7], 7, 0, FC.STAT_MAX), int(p[8], 7, 0, FC.STAT_MAX)
  if not (race and class and level and wins and deadly) then return nil end
  if (p[4] ~= "m" and p[4] ~= "f") or not STATE_OK[p[6]] or #p[13] ~= GEAR_LEN then return nil end
  local look
  if p[9] ~= "-" then
    look = text(p[9], 3, "^%w+$")
    if not look then return nil end
  end
  local traits = {}
  for i = 10, 12 do
    if p[i] ~= "-" then
      if not text(p[i], 7, "^%l+$") then return nil end
      traits[#traits + 1] = p[i]
    end
  end
  return { name = p[1], race = race, class = class, sex = p[4], level = level, state = p[6], wins = wins,
    deadly = deadly, look = look, traits = traits, gear = p[13], pieces = parsePieces(p[13]) }
end

local function parseFollowers(s)
  if s == "-" then return {} end
  local lines = split(s, "!")
  if #lines > MAX_FOLLOWERS then return nil end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = parseFollower(line)
    if not out[i] then return nil end
  end
  return out
end

local function parseFlair(s)
  local p = split(s, ".")
  if #p ~= 4 then return nil end
  local title
  if p[1] ~= "-" then
    title = text(p[1], 16, "^[%l%d%-]+$")
    if not title then return nil end
  end
  local badges, trophies = idList(p[2]), idList(p[3])
  local quests = int(p[4], 2, 0, #QD.WRITS)
  if not (badges and trophies and quests) then return nil end
  return { title = title, badges = badges, trophies = trophies, quests = quests }
end

local function parseCollection(s)
  local p = split(s, ".")
  if #p ~= 4 then return nil end
  local relics, sets, chains, badges = bits(p[1]), bits(p[2]), bits(p[3]), bits(p[4])
  if not (relics and sets and chains and badges) then return nil end
  return { relics = relics, sets = sets, chains = chains, badges = badges }
end

local function parseFind(line)
  local p = split(line, ".")
  if #p ~= 4 or not ns.WellFormed(p[1]) then return nil end
  if p[2] ~= "-" and not FC.ValidName(p[2]) then return nil end
  local day, region = int(p[3], 6, 0, DAY_TOP), text(p[4], 12, "^%l+$")
  if not (day and region) then return nil end
  return { code = p[1], who = p[2] ~= "-" and p[2] or nil, day = day, region = region }
end

local function parseFinds(s)
  if s == "-" then return {} end
  local lines = split(s, "!")
  if #lines > MAX_FINDS then return nil end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = parseFind(line)
    if not out[i] then return nil end
  end
  return out
end

-- Answers the section, or false for a malformed one (nil is a member with no section).
local function parseOfficer(s)
  if s == "-" then return nil end
  local rows = split(s, "!")
  if #rows > MAX_HIDES + 1 then return false end
  local head = split(rows[1], ".")
  if #head ~= 2 then return false end
  local at = int(head[2], 10, 0, AT_TOP)
  if not at then return false end
  local bank
  if head[1] == "-" then
    if at ~= 0 then return false end
  elseif isKey(head[1]) then
    bank = head[1]
  else
    return false
  end
  local hides = {}
  for i = 2, #rows do
    local p = split(rows[i], ".")
    if #p ~= 2 or not isKey(p[1]) or not FC.ValidName(p[2]) then return false end
    hides[i - 1] = { owner = p[1], name = p[2] }
  end
  return { bank = bank, at = at, hides = hides }
end

function Rec.Unpack(body)
  if type(body) ~= "string" or string.find(body, NOT_ALLOWED) then return nil end
  local f = split(body, "^")
  if #f ~= 9 or f[1] ~= "1" or not string.match(f[2], HEX8) then return nil end
  local followers, flair, collection = parseFollowers(f[3]), parseFlair(f[4]), parseCollection(f[5])
  local deadly, runs = int(f[6], 7, 0, RECORD_TOP), int(f[7], 7, 0, RECORD_TOP)
  local finds, officer = parseFinds(f[8]), parseOfficer(f[9])
  if not (followers and flair and collection and deadly and runs and finds) or officer == false then return nil end
  return { v = 1, acct = f[2], followers = followers, flair = flair, collection = collection, deadly = deadly,
    runs = runs, finds = finds, officer = officer }
end

local function packList(t) return #t > 0 and table.concat(t, "+") or "-" end

local function packFollowers(list)
  if #list == 0 then return "-" end
  local lines = {}
  for i, f in ipairs(list) do
    lines[i] = table.concat({ f.name, f.race, f.class, f.sex, f.level, f.state, f.wins, f.deadly, f.look or "-",
      f.traits[1] or "-", f.traits[2] or "-", f.traits[3] or "-", f.gear }, ".")
  end
  return table.concat(lines, "!")
end

local function packFinds(list)
  if #list == 0 then return "-" end
  local lines = {}
  for i, r in ipairs(list) do lines[i] = table.concat({ r.code, r.who or "-", r.day, r.region }, ".") end
  return table.concat(lines, "!")
end

local function packOfficer(o)
  if not o then return "-" end
  local rows = { (o.bank or "-") .. "." .. (o.bank and o.at or 0) }
  for _, h in ipairs(o.hides) do rows[#rows + 1] = h.owner .. "." .. h.name end
  return table.concat(rows, "!")
end

local function build(v)
  local fl, c = v.flair, v.collection
  return table.concat({ v.v, v.acct, packFollowers(v.followers),
    table.concat({ fl.title or "-", packList(fl.badges), packList(fl.trophies), fl.quests }, "."),
    table.concat({ hex(c.relics), hex(c.sets), hex(c.chains), hex(c.badges) }, "."),
    v.deadly, v.runs, packFinds(v.finds), packOfficer(v.officer) }, "^")
end

function Rec.Pack(view)
  local good, body = pcall(build, view)
  if not good or not Rec.Unpack(body) then return nil, "field" end
  if #body > Rec.MAX_BODY then return nil, "too big" end
  return body
end

local function stat(f, field) return f.stats and f.stats[field] or 0 end

-- A worn id whose piece is gone, or a stack's copy, is an empty slot.
local function gearStrip(f)
  local out = {}
  for i, slot in ipairs(GD.SLOTS) do
    local id = f.gear and f.gear[slot.key]
    local piece = id and ns.Gear(id)
    if piece and GD.WellFormed(piece.row) then
      local t = piece.temper or 0
      out[i] = piece.row .. (piece.broken and string.sub(BROKEN, t + 1, t + 1) or t)
    else
      out[i] = "---"
    end
  end
  return table.concat(out)
end

local function letterOf(f)
  if f.state == "idle" and f.reserve == true then return "b" end
  return LETTER[f.state] or "i"
end

local function sumBits(list, order, idOf)
  local want = {}
  for _, id in ipairs(list) do want[id] = true end
  local n = 0
  for i, row in ipairs(order) do
    if want[idOf(row)] then n = n + 2 ^ (i - 1) end
  end
  return n
end

local function ownCollection()
  local col = ns.Collection()
  local function region(s) return s.region end
  local chains = 0
  for _, c in ipairs(col.chains) do chains = chains + 2 ^ (c - 1) end
  return { relics = sumBits(col.relics, BD.relics, function(r) return r.id end),
    sets = sumBits(col.sets, BD.sets, region), chains = chains, badges = sumBits(col.badges, BD.sets, region) }
end

-- Two or more characters on this Person. Read at call time; the caller treats a throw as alone.
local function linked()
  local comm = GuildSync.Comm
  local p = comm.Person(comm.MyKey())
  return type(p) == "table" and type(p.chars) == "table" and #p.chars >= 2
end

-- The token says which characters share an account, and the fold only uses it inside one Person. So a lone or hidden
-- character (its Person lists only itself) sends zeros, and so does a failed read.
local function sharedAcct()
  local good, yes = pcall(linked)
  if good and yes then return ns.AccountToken() end
  return "00000000"
end

-- Reads only (R-quiet). The one write it can cause is the account token's first mint.
function ns.OwnView()
  local names, inUse, reserve = {}, {}, {}
  for _, f in ipairs(ns.Followers()) do
    names[f.id] = f.name
    local side = f.reserve == true and reserve or inUse
    side[#side + 1] = f
  end
  for _, f in ipairs(reserve) do inUse[#inUse + 1] = f end

  local lines, deadly, runs = {}, 0, 0
  for i = 1, math.min(#inUse, MAX_FOLLOWERS) do
    local f = inUse[i]
    lines[i] = { name = f.name, race = f.race, class = f.class, sex = f.sex, level = f.level, state = letterOf(f),
      wins = stat(f, "wins"), deadly = stat(f, "deadly"), look = f.look, traits = f.traits or {}, gear = gearStrip(f) }
    deadly = deadly + stat(f, "deadly")
    runs = runs + stat(f, "runs")
  end

  local finds = {}
  for i, r in ipairs(ns.Finds()) do
    finds[i] = { code = r.row, who = names[r.fid], day = r.day, region = r.region }
  end

  local fl = ns.Flair()
  return { v = 1, acct = sharedAcct(), followers = lines,
    flair = { title = fl.title, badges = fl.badges, trophies = fl.trophies, quests = fl.quests },
    collection = ownCollection(), deadly = deadly, runs = runs, finds = finds,
    officer = ns.OwnOfficer and ns.OwnOfficer() or nil }
end

local function freshAcct() return {} end

function ns.AccountToken()
  if M.Demo() then return "00000000" end
  local p = ns.Part("acct", freshAcct)
  if type(p.token) ~= "string" or not string.match(p.token, HEX8) then
    p.token = string.format("%04x%04x", math.random(0, 65535), math.random(0, 65535))
  end
  return p.token
end
