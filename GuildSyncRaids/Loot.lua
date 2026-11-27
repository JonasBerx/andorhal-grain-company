local _, ns = ...
if not ns.M then return end

-- The loot record store (ticket 59): GuildSyncRaidsDB.loot = { next, list } (LOOT-FORMAT.md), read only through
-- store(), which never creates it, repairs it and prunes it once per session on its first read (or at login through
-- ns.LootLogin, which Raids.lua does not call yet); the first Record creates it. Also
-- ns.Loot (Record, Add, Change, State, LastCouncil), ns.LootList, ns.LootLogin and /gsraids loot. Nothing is sent; in
-- /gsync demo nothing is written. The rules are LootRules.lua, looked up at call time.
-- The listener (CHAT_MSG_LOOT through ns.OnChat, ENCOUNTER_LOOT_RECEIVED through ns.OnEncounterLoot) makes
-- seen-only records in a party or raid instance while ns.LootListening() is true; every record goes through R.Merge.

local M = ns.M
local Plain = GuildSync.Compat.Plain
local call = M.Compat.call

local pruned                                       -- the session's prune has run
local session = { recorded = 0, kept = 0, refused = 0 } -- memory only
local heard = { made = 0, hidden = 0, skipped = 0 }     -- the listener's counts (memory only)

local function now() return Plain(call("GetServerTime")) end

local function demo()
  local on = M.Demo()
  return on == true
end

local function validId(v)
  return type(v) == "number" and v == v and v % 1 == 0 and v >= 1 and v <= ns.LootRules.MAXID
end

-- A non-table loot or list is replaced with the matching part of { next = 1, list = {} }; a next that is not a
-- valid id becomes the highest id in the list + 1 (so no held id is answered again, even with no clock to prune).
local function repair(db)
  if type(db.loot) ~= "table" then db.loot = {} end
  local loot = db.loot
  if type(loot.list) ~= "table" then loot.list = {} end
  if not validId(loot.next) then
    local top = 0
    for _, r in ipairs(loot.list) do
      if type(r) == "table" and validId(r.id) and r.id > top then top = r.id end
    end
    loot.next = top + 1
  end
  return loot
end

-- An item's quality from the item cache, else nil.
local function qualityOf(item)
  local Items = ns.Items
  if type(Items) ~= "table" or type(Items.Info) ~= "function" then return nil end
  local info = Items.Info(item)
  return type(info) == "table" and info.quality or nil
end

local function prune(db)
  local t = now()
  if type(t) == "number" then db.loot = ns.LootRules.Prune(db.loot, t, qualityOf) end
end

-- The only read path. An absent loot is never created here: it reads as an empty store. A present one is repaired,
-- and pruned under M.Safe on the session's first read of it (repaired again after a throw).
local function store()
  local db = ns.DB()
  if db.loot == nil then return { next = 1, list = {} } end
  repair(db)
  if not pruned then
    pruned = true
    M.Safe(prune, db)
    repair(db)
  end
  return db.loot
end

-- The write path (Record): the read path, then the key created when it is absent.
local function writable()
  local db = ns.DB()
  if db.loot == nil then db.loot = { next = 1, list = {} } end
  return store()
end

function ns.LootList() return store().list end

local registerListener -- defined with the listener below

-- Runs the session's prune now (meant for Raids.lua's onLogin); an absent loot stays absent. Prune always answers a
-- whole { next, list }, so no repair is needed after it.
function ns.LootLogin()
  registerListener()
  local db = ns.DB()
  pruned = true
  if db.loot == nil then return end
  repair(db)
  prune(db)
end

local function find(id)
  for _, r in ipairs(store().list) do
    if type(r) == "table" and r.id == id then return r end
  end
end

local function key(who)
  if type(who) ~= "string" then return nil end
  local k = ns.Key(who)
  return k
end

-- The player's cased name from the roster row, else the key.
local function myName()
  local k = ns.MyKey()
  local rows = ns.Roster()
  local row = type(rows) == "table" and rows[k] or nil
  local name = type(row) == "table" and row.name or nil
  if type(name) == "string" and name ~= "" then return name end
  return k
end

local function groupKind()
  if type(ns.GroupKind) ~= "function" then return nil end
  local kind = ns.GroupKind()
  return kind
end

local Loot = {}
ns.Loot = Loot

-- A made rec into the store through R.Merge. The answer is id, or id, "kept", or nil, why: Merge's other kinds
-- never leave this file.
local function merge(rec, why)
  local id, kind
  if rec then id, kind = ns.LootRules.Merge(writable(), rec, key) else kind = why end
  if not id then
    session.refused = session.refused + 1
    return nil, kind
  end
  if kind == "kept" then
    session.kept = session.kept + 1
    return id, "kept"
  end
  session.recorded = session.recorded + 1
  return id
end

-- An own award (no src and no from) stores the player's name as from.
function Loot.Record(t)
  if demo() then return nil, "demo" end
  if type(t) == "table" and t.src == nil and t.from == nil then
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    c.from = myName()
    t = c
  end
  local inRaid
  if type(ns.GroupKind) == "function" then inRaid = groupKind() == "raid" end
  return merge(ns.LootRules.Make(t, now(), ns.DB().pulls, inRaid))
end

-- A drop added by hand (src hand, by = the player's key, never party), answered as Record answers.
function Loot.Add(t)
  if demo() then return nil, "demo" end
  local me = ns.MyKey()
  return merge(ns.LootRules.Add(t, me, now(), ns.DB().pulls))
end

-- After a Change of who the record joins its partner (R.Rejoin); the removed row's id then answers nil, "id".
function Loot.Change(id, t)
  if demo() then return nil, "demo" end
  local rec = find(id)
  if not rec then return nil, "id" end
  local wasSeen = rec.src == "seen"
  local me = ns.MyKey()
  local R = ns.LootRules
  local good, why = R.Edit(rec, t, me, ns.DB().pulls)
  if good and type(t) == "table" and t.who ~= nil then R.Rejoin(store().list, rec, wasSeen, key) end
  return good, why
end

function Loot.State(id)
  if demo() then return nil end
  local rec = find(id)
  if not rec then return nil end
  return ns.LootRules.State(store().list, rec, key)
end

function Loot.LastCouncil(k)
  if demo() then return nil end
  return ns.LootRules.LastCouncil(store().list, k, key)
end

-- ---------- the listener ----------

-- loot.listen when it is a boolean, else LootRules.LISTEN. Never creates loot.
function ns.LootListening()
  local db = ns.DB()
  local loot = db.loot
  if type(loot) == "table" and type(loot.listen) == "boolean" then return loot.listen end
  return ns.LootRules.LISTEN == true
end

local FORMATS = {
  { "LOOT_ITEM", "%s receives loot: %s." }, { "LOOT_ITEM_MULTIPLE", "%s receives loot: %sx%d." },
  { "LOOT_ITEM_SELF", "You receive loot: %s." }, { "LOOT_ITEM_SELF_MULTIPLE", "You receive loot: %sx%d." },
}

-- The client's "receives loot" formats where they are strings, else the built-in English ones. The "You receive
-- item" lines (quests, vendors, crafts) are not loot and are not read.
function ns.LootFormats()
  local out = {}
  for i, f in ipairs(FORMATS) do
    local v = _G[f[1]]
    out[i] = type(v) == "string" and v or f[2]
  end
  return out
end

local pats, patsOf -- the patterns and the ns.LootFormats they were built from
local function patterns()
  if patsOf ~= ns.LootFormats then
    patsOf = ns.LootFormats
    pats = ns.LootRules.Patterns(patsOf())
  end
  return pats
end

local function inGroupInstance()
  local _, kind = call("IsInInstance")
  return kind == "party" or kind == "raid"
end

-- A raid only when GroupKind says raid and the group is not 5 or fewer.
local function listenerInRaid()
  if groupKind() ~= "raid" then return false end
  local n = Plain(call("GetNumGroupMembers"))
  return not (type(n) == "number" and n <= 5)
end

-- A sighting s through R.Sighting and R.Merge, counted made or skipped.
local function sight(s)
  local R = ns.LootRules
  local rec = R.Sighting(s, s.at, ns.DB().pulls, listenerInRaid())
  local id
  if rec then id = R.Merge(writable(), rec, key) end
  if id then heard.made = heard.made + 1 else heard.skipped = heard.skipped + 1 end
end

local function skip() heard.skipped = heard.skipped + 1 end

-- One plain CHAT_MSG_LOOT line. The event's name argument is never the winner: the line's text is.
local function onLine(text, _, guid)
  local R = ns.LootRules
  if not ns.LootListening() then return skip() end
  local link, who, count = R.ParseLine(text, patterns())
  if not link or not inGroupInstance() or demo() then return skip() end
  local Items = ns.Items
  local item, suffix
  if type(Items) == "table" and type(Items.Id) == "function" then item, suffix = Items.Id(link) end
  if not item then return skip() end
  local q = R.LinkQuality(link)
  if q == nil then q = qualityOf(item) end
  local t = now()
  if not R.Worth(store().list, item, suffix, q, t) then return skip() end
  local isSelf = who == nil -- a self line keeps the event's own guid (already plain or nil)
  local name, g = R.Receiver(ns.DB().pulls, guid, who, isSelf, myName())
  if not name then return skip() end
  sight({ item = item, suffix = suffix, count = count, q = q, who = name, guid = g, at = t, seen = "chat" })
end

local registered
function registerListener()
  if registered or type(ns.OnChat) ~= "function" then return end
  registered = true
  ns.OnChat("loot", onLine)
end
registerListener()

-- ENCOUNTER_LOOT_RECEIVED (encounterID, itemID, itemLink, quantity, playerName, className): the item from arg 2, the
-- link for the suffix and colour only, arg 5 the receiver. A secret or missing encounter id, item or name counts
-- hidden.
function ns.OnEncounterLoot(_, ...)
  if not ns.LootListening() or demo() or not inGroupInstance() then return end
  local enc, item, link, count, name = Plain((select(1, ...))), Plain((select(2, ...))), Plain((select(3, ...))),
    Plain((select(4, ...))), Plain((select(5, ...)))
  if type(enc) ~= "number" or not validId(item) or type(name) ~= "string" or name == "" then
    heard.hidden = heard.hidden + 1
    return
  end
  local R = ns.LootRules
  local Items = ns.Items
  local suffix
  if type(link) == "string" and type(Items) == "table" and type(Items.Id) == "function" then
    local id, sfx = Items.Id(link)
    if id == item then suffix = sfx end
  end
  local q = R.LinkQuality(link)
  if q == nil then q = qualityOf(item) end
  local who, g = R.Receiver(ns.DB().pulls, nil, name, false, myName())
  if not who then return skip() end
  sight({ item = item, suffix = suffix, count = type(count) == "number" and count or nil, q = q, who = who, guid = g,
    at = now(), seen = "enc", enc = enc })
end

local function say(text) ns.Say("Raids: " .. text) end
local USAGE = "/gsraids loot [last <1-50>] lists the saved loot; /gsraids loot test <item link or id> records a test award; /gsraids loot listen on|off turns the loot listener on or off"

-- /gsraids loot: "" or last [n] lists the saved records (never the demo's), names escaped, then the counters and the
-- listener's counts; test <link|id> records a test award to the player through ns.Loot.Record; listen on|off saves
-- loot.listen.
function ns.LootSlash(arg)
  local sub, rest = string.match(arg or "", "^%s*(%S*)%s*(.-)%s*$")
  sub = string.lower(sub or "")
  if sub == "" or sub == "last" then
    local n = 10
    if rest ~= "" then n = tonumber(rest) end
    if not n or n % 1 ~= 0 or n < 1 or n > 50 then return say(USAGE) end
    -- only the last n records are copied, named and escaped (oldest first, as ChatLines reads from the end)
    local saved, picked = store().list, {}
    for i = #saved, 1, -1 do
      if #picked >= n then break end
      if type(saved[i]) == "table" then picked[#picked + 1] = saved[i] end
    end
    local list = {}
    for i = #picked, 1, -1 do
      local q = {}
      for f, v in pairs(picked[i]) do q[f] = v end
      if type(q.who) == "string" then q.who = ns.Escape(q.who) end
      if type(q.boss) == "string" then q.boss = ns.Escape(q.boss) end
      local Items = ns.Items
      if type(Items) == "table" and type(Items.Info) == "function" then
        local info = Items.Info(q.item)
        local name = type(info) == "table" and info.name or nil
        if type(name) == "string" and name ~= "" then q.name = ns.Escape(name) end
      end
      list[#list + 1] = q
    end
    for _, line in ipairs(ns.LootRules.ChatLines(list, n, ns.When)) do say(line) end
    local counts = type(ns.ChatCounts) == "function" and ns.ChatCounts() or nil
    local row = type(counts) == "table" and type(counts.loot) == "table" and counts.loot or {}
    say(ns.LootRules.Counters(store(), session) .. "; " .. ns.LootRules.ListenLine(ns.LootListening(), {
      seen = row.seen, made = heard.made, hidden = (row.hidden or 0) + heard.hidden, skipped = heard.skipped }))
  elseif sub == "test" then
    local id, suffix
    if ns.Items and type(ns.Items.Id) == "function" then id, suffix = ns.Items.Id(rest) end
    if not id then id = tonumber(rest) end
    if not id then return say(USAGE) end
    local got, why = ns.Loot.Record({ item = id, suffix = suffix, who = myName(), how = "ms" })
    if not got then return say("not recorded: " .. tostring(why)) end
    say("test award recorded (id " .. tostring(got) .. ")")
  elseif sub == "listen" and (rest == "on" or rest == "off") then
    if demo() then return say("loot listener not changed in demo") end
    writable().listen = rest == "on"
    say("loot listener " .. rest)
  else
    say(USAGE)
  end
end
