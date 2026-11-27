local _, ns = ...
if not ns.M then return end

-- The wish lists (ticket 58, wave 1): the own list saved in ns.DB().wish.mine, the raids_w domain's read side and
-- ns.Wants. This release sends nothing: the domain is registered with no store attached, so it has no queue
-- source. A P from its author is kept in wish.records[key] = { rev, hash, body, at }; H, D and R
-- are heard and ignored. A leaver's record is dropped on the hub's rosterRead, never when the store is read.
-- In demo the own list is a session copy (nothing saved) and ns.Wants answers from the made-up guild; a received
-- record still reaches the real store.
-- An item's has = true ("has it") is set and cleared only by ns.WishCheckHas, never stamps changed, and
-- is checked at login, on an equipment or bag change, and after a save that adds an item; a check asked in combat
-- runs after the fight. ns.WishHeld reads the game (equipped, or in the bags or bank); ns.WishHolders answers
-- who has a list. Still nothing is sent.

local M, R = ns.M, ns.WishRules
local ID = "raids_w"
-- The first six are confirmed Forever ids (issue 58, f44); the rest are Classic ids that may show as item #<id>.
local DEMO_ITEMS = { 19019, 288909, 288902, 873, 12640, 19323, 18814, 19347, 18832, 17076, 16901, 16922 }

-- the real roster, never the demo-overridden ns.Roster and ns.Member (Raids.lua:146)
local realRoster, realMember = GuildSync.Comm.Roster, GuildSync.Comm.Member

local rosterRead = false -- set at the session's first non-partial read of a known roster
local cache = {}         -- key -> { rev, hash, list }: held bodies unpacked once a session
local demoOnly = {}      -- the demo list when the hub keeps no demo state for this module

local function now()
  local t = M.Compat.call("GetServerTime")
  return tonumber(t) or 0
end

-- Read only: the saved list and records, or empty ones when missing or broken. Writes nothing.
local function saved()
  local d = ns.DB()
  local w = d.wish
  if type(w) ~= "table" then return R.Empty(), {} end
  local mine = (type(w.mine) == "table" and type(w.mine.items) == "table") and w.mine or R.Empty()
  return mine, type(w.records) == "table" and w.records or {}
end

-- For a write: sets d.wish and its two keys when missing or of the wrong type.
local function db()
  local d = ns.DB()
  if type(d.wish) ~= "table" then d.wish = {} end
  local w = d.wish
  if type(w.mine) ~= "table" or type(w.mine.items) ~= "table" then w.mine = R.Empty() end
  if type(w.records) ~= "table" then w.records = {} end
  return w
end

-- A member key: a string of 1 to 64 bytes (a hand-edited records table may hold anything).
local function validKey(key) return type(key) == "string" and #key >= 1 and #key <= 64 end

-- A copy with only good items, no id twice, at most R.MAX (the saved file may be edited by hand). A changed that
-- is not a whole number from 0 to below 2^53 reads as nil.
local function copy(list)
  local items, seen = {}, {}
  for _, item in ipairs(list.items) do
    if #items >= R.MAX then break end
    if type(item) == "table" and R.ValidId(item.id) and not seen[item.id] and (item.spec == "m" or item.spec == "o") then
      seen[item.id] = true
      items[#items + 1] = { id = item.id, spec = item.spec, has = item.has == true or nil }
    end
  end
  local c = list.changed
  if type(c) ~= "number" or not (c >= 0 and c < 2 ^ 53 and c % 1 == 0) then c = nil end
  return { changed = c, items = items }
end

-- The demo state holds the session list; nil when demo is off.
local function demoState()
  local on, st = M.Demo()
  if not on then return nil end
  if type(st) ~= "table" then return demoOnly end
  return st
end

-- ---------- the own list ----------

function ns.WishMine()
  local st = demoState()
  if not st then demoOnly.wishMine = nil return copy((saved())) end
  if not st.wishMine then st.wishMine = copy((saved())) end
  return copy(st.wishMine)
end

-- true, or nil and why: a list the wire would refuse is never saved. In demo nothing is written to ns.DB(). A
-- save that adds an id the saved list did not hold runs a "has it" check at once.
function ns.WishSave(list)
  local body, why = R.PackBody(list)
  if not body then return nil, why end
  local st = demoState()
  if st then
    st.wishMine = copy(list)
    return true
  end
  local old = {}
  for _, item in ipairs(copy((saved())).items) do old[item.id] = true end
  local saving = copy(list)
  db().mine = saving
  for _, item in ipairs(saving.items) do
    if not old[item.id] then ns.WishCheckHas() break end
  end
  return true
end

-- ---------- "has it": the check and its triggers ----------

local Plain = GuildSync.Compat.Plain
local owed, listening = false, false -- a check put off by a fight; the one ns.AfterCombat listener is added

-- Only an answer of true is a fight: a call that answers nothing runs the check.
local function inCombat()
  local v = M.Compat.call("InCombatLockdown")
  v = Plain(v)
  return v == true
end

-- true, changed | nil, why ("demo", "combat", "no reader"). ns.WishHeld is looked up at each call; a reader that
-- throws (recorded through M.Safe) or answers other than true or false keeps the mark. A flip saves the marks
-- without touching changed. markOnly (the login run) marks and never unmarks: the bags and bank may not be known yet.
local function checkHas(markOnly)
  if demoState() then return nil, "demo" end
  if inCombat() then
    owed = true
    if not listening and ns.AfterCombat then
      listening = true
      ns.AfterCombat(function() if owed then ns.WishCheckHas() end end)
    end
    return nil, "combat"
  end
  owed = false
  local reader = ns.WishHeld
  if type(reader) ~= "function" then return nil, "no reader" end
  local out, flipped = R.MarkHas(copy((saved())), function(id)
    local good, v = M.Safe(reader, id)
    if good ~= true or type(v) ~= "boolean" then return nil end
    if markOnly and v == false then return nil end
    return v
  end)
  if not out then return nil, flipped end
  if flipped then
    db().mine = copy(out)
    M.RefreshPage()
  end
  return true, flipped == true
end

function ns.WishCheckHas() return checkHas(false) end

-- The host calls this once at login: marks only (a check owed by a fight runs in full after it).
function ns.WishLogin() M.Safe(checkHas, true) end

-- PLAYER_EQUIPMENT_CHANGED and BAG_UPDATE_DELAYED: one check a second after the first, however many arrive.
local checking = false
function ns.OnWishEvent()
  if checking then return end
  checking = true
  M.After(1, function()
    checking = false
    ns.WishCheckHas()
  end)
end

-- true (equipped, or in the bags or bank), false, or nil when the game cannot tell (a call answered nothing). The
-- bank counts as the game knows it this session.
function ns.WishHeld(id)
  local worn = M.Compat.call("C_Item.IsEquippedItem", id)
  worn = Plain(worn)
  local count = M.Compat.call("C_Item.GetItemCount", id, true)
  count = Plain(count)
  if type(worn) ~= "boolean" or type(count) ~= "number" then return nil end
  return worn == true or count > 0
end

-- ---------- the domain: H, D and R heard, P kept ----------

local refreshing = false
local function refreshSoon()
  if refreshing then return end
  refreshing = true
  M.After(1, function()
    refreshing = false
    M.RefreshPage()
  end)
end

local function quiet() end

-- Merge: only the author's own list, rev not ahead of now, then higher rev, then higher hash. A newer format is
-- dropped and the held record stays.
local function onPut(msg, from, t)
  if type(msg) ~= "table" or msg.key ~= from or msg.newer or type(msg.body) ~= "string" then return end
  if type(msg.rev) ~= "number" or type(msg.hash) ~= "string" or type(t) ~= "number" then return end
  if msg.rev > t + R.FUTURE then return end
  local records = db().records
  local held = records[from]
  if type(held) == "table" then
    local rev, hash = tonumber(held.rev) or 0, tostring(held.hash or "")
    if msg.rev < rev or (msg.rev == rev and msg.hash <= hash) then return end
  end
  records[from] = { rev = msg.rev, hash = msg.hash, body = msg.body, at = t }
  cache[from] = nil
  refreshSoon()
end

-- A failed register raises nothing: the own list and ns.Wants work anyway. ns.WishDomain tells which.
local okDomain, whyDomain = M.Comm.Register({
  id = ID, prefix = "GSync", audience = "guild", owner = "self", maxChunks = 16,
  kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = "put" } },
  unpack = R.UnpackMsg, handle = { H = quiet, D = quiet, R = quiet, P = onPut },
})

-- true when raids_w registered, else nil and why.
function ns.WishDomain()
  if okDomain then return true end
  return nil, tostring(whyDomain or "not registered")
end

-- ---------- the leaver prune ----------

-- Only a full read of a known roster prunes, demo or not; it also opens the roster filter in ns.Wants. A bad key
-- is dropped.
M.On("rosterRead", function(partial)
  if partial then return end
  local rows, _, _, known = realRoster()
  if not known or type(rows) ~= "table" then return end
  rosterRead = true
  local _, records = saved()
  for key in pairs(records) do
    if not validKey(key) or not rows[key] then
      records[key] = nil
      cache[key] = nil
    end
  end
end)

-- ---------- ns.Wants (read only) ----------

-- A held record's list, unpacked once per rev and hash; nil when the body does not read (not kept: it is read
-- again next time, in case the time was missing).
local function heldList(key, r, t)
  if type(r) ~= "table" or type(r.body) ~= "string" then return nil end
  local c = cache[key]
  if c and c.rev == r.rev and c.hash == r.hash then return c.list end
  local list = R.UnpackBody(r.body, t)
  if type(list) ~= "table" or list.newer then return nil end
  cache[key] = { rev = r.rev, hash = r.hash, list = list }
  return list
end

local function nameOf(key)
  local row = ns.Member(key)
  return type(row) == "table" and type(row.name) == "string" and row.name or key
end

local function addRow(out, key, list, id)
  for i, item in ipairs(list.items) do
    if item.id == id then
      out[#out + 1] = { key = key, name = nameOf(key), position = i, spec = item.spec, has = item.has == true,
        changed = list.changed }
      return
    end
  end
end

-- The made-up guild's lists: member i (sorted by key) wants 3 of DEMO_ITEMS from offset 5 (i - 1).
local function demoLists(st)
  local d = ns.DemoData and ns.DemoData()
  local rows = type(d) == "table" and type(d.rows) == "table" and d.rows or {}
  local keys = {}
  for k in pairs(rows) do keys[#keys + 1] = k end
  table.sort(keys)
  local t = tonumber(st.now) or now()
  local lists = {}
  for i, key in ipairs(keys) do
    local items = {}
    for k = 0, 2 do
      items[k + 1] = { id = DEMO_ITEMS[(5 * (i - 1) + k) % #DEMO_ITEMS + 1], spec = k == 2 and "o" or "m" }
    end
    lists[key] = { changed = t - i * 3600, items = items }
  end
  return lists
end

local function before(a, b)
  if a.position ~= b.position then return a.position < b.position end
  if a.spec ~= b.spec then return a.spec == "m" end
  local ca, cb = a.changed or 0, b.changed or 0
  if ca ~= cb then return ca < cb end
  return a.key < b.key
end

-- { { key, name, position, spec, has, changed }, ... } for one item id; {} for a bad id. Writes nothing. A record
-- under a bad key is skipped. The roster filter asks Comm.Member for each key, never Comm.Roster (a fresh copy of
-- every row on each call, API.md), so a member who left since the last read is left out too.
-- name is not escaped (the roster name, or the key): pass it through ns.Escape before showing it.
function ns.Wants(itemId)
  local out = {}
  if not R.ValidId(itemId) then return out end
  local me = ns.MyKey()
  local st = demoState()
  local lists = {}
  if st then
    lists = demoLists(st)
  else
    local t = now()
    local _, records = saved()
    for key, r in pairs(records) do
      if validKey(key) and key ~= me and (not rosterRead or realMember(key) ~= nil) then lists[key] = heldList(key, r, t) end
    end
  end
  if type(me) == "string" then lists[me] = ns.WishMine() end
  for key, list in pairs(lists) do addRow(out, key, list, itemId) end
  table.sort(out, before)
  return out
end

-- { [key] = true } for each member with a list that holds an item, the own key too; the same records and roster
-- filter as ns.Wants (in demo the made-up guild). Writes nothing.
function ns.WishHolders()
  local out = {}
  local me = ns.MyKey()
  local st = demoState()
  if st then
    for key in pairs(demoLists(st)) do out[key] = true end
  else
    local t = now()
    local _, records = saved()
    for key, r in pairs(records) do
      if validKey(key) and key ~= me and (not rosterRead or realMember(key) ~= nil) then
        local list = heldList(key, r, t)
        if list and #list.items > 0 then out[key] = true end
      end
    end
  end
  if type(me) == "string" and #ns.WishMine().items > 0 then out[me] = true end
  return out
end
