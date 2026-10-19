-- GuildSyncBank contents scans (brief D10, D11): what this bank character holds, into its own local records.
--   b1~self { scanned, money, items }        bags 0-4 and the reagent bag 5
--   k<n>~self { scanned, tab, items }        bank tab n (in FetchPurchasedBankTabIDs order), tab = its container id,
--                                            read only while the bank is open
--   g<n>~self { scanned, tab, items }        guild bank tab n, only when every reader is there (beta check), and only
--                                            once its tab is marked loaded since the guild bank opened: 0.8 s after
--                                            the open the viewable tabs are queried one at a time, each marked loaded
--                                            on the next GUILDBANKBAGSLOTS_CHANGED, or skipped after 2.5 s with no
--                                            answer. Every such event also marks the tab on screen
--                                            (the optional GetCurrentGuildBankTab, the UI's selection) loaded and
--                                            "sure": Blizzard's frame queried it (old recorder, Bags.lua). The event
--                                            may be another tab's, and a tab whose data has not arrived reads as all
--                                            empty, so an all-empty read never replaces a non-empty record unless the
--                                            tab is "sure"; any other read replaces it, smaller or not. A tab not
--                                            loaded keeps its last record, and nothing is written after
--                                            GUILDBANKFRAME_CLOSED (a held change is dropped)
--   ns.Scan.GuildBankReadable() -> bool, why
--   ns.Scan.GuildBankItems(tabs) -> items | nil   pure: tabs = { { viewable = bool, slots = { { id = n, count = n } } } }
-- Only a complete read changes a record: 0 slots seen, a closed bank, or any nil or secret read keeps the last one.
-- A record is written only when its items, money or tab changed, at most once per settings.debounce seconds
-- (LIMITS.debounce by default), plus once when the bank closes. The first scan waits for the first Ranks.OnChange where
-- this character is a bank character and its own key is settled (MyKey has a roster row). Store.Put publishes each
-- write as a P (t42). b is split into b1..b2 by Store.Fit (a former own tail piece becomes {}); k is clamped to k1..k6
-- and g to g1..g8; past a cap the scan cuts and ns.Scan.Cut() names this character. After a complete read of b, k or
-- g, every own key in ns.Sync.UnheldScan(family) beyond the new count becomes {} (d784, f5336); a key a scan writes
-- leaves that set. An incomplete read neither reads nor writes the set.
--   ns.Scan.Cut() -> holderKey | nil

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Scan = {}
ns.Scan = Scan

local BAGS = { 0, 1, 2, 3, 4, 5 }
local BANKER_FRAMES = { [8] = true, [67] = true } -- PLAYER_INTERACTION_MANAGER_FRAME_SHOW: Banker, CharacterBanker
local GUILD_READERS = { "GetNumGuildBankTabs", "GetGuildBankTabInfo", "QueryGuildBankTab", "GetGuildBankItemInfo",
  "GetGuildBankItemLink" }
local GUILD_SLOTS = 98
local OPEN_DELAY, QUERY_TIMEOUT = 0.8, 2.5 -- seconds: the old recorder's (GuildSync 0.11 Bags.lua)
local NOT_READABLE = "guild bank not readable on this client"

local started, bankOpen, guildOpen = false, false, false
local lastAt, held = {}, {} -- key -> time of this session's last write; key -> true while a write waits
-- Guild bank tabs since GUILDBANKFRAME_OPENED: still to query, queried with no answer yet, answered ({ [n] = true }).
local guildQueue, guildPending, guildLoaded = {}, nil, {}
local guildGen = 0 -- bumped by every reset and query; a timer acts only while its generation is current
local cut = nil   -- this character's key once a scan was cut at a family cap (b, k 6, g 8; d772)

local function plain(v) return GuildSync.Compat.Plain(v) end
local function call(...) return M.Compat.call(...) end
local function now() return plain(call("GetServerTime")) end
local function num(v)
  v = plain(v)
  if type(v) == "number" then return v end
  return nil
end

local function same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- The body without its scan time, to tell a real change from a rescan.
local function content(body)
  local out = {}
  for k, v in pairs(type(body) == "table" and body or {}) do
    if k ~= "scanned" then out[k] = v end
  end
  return out
end

local function me() return GuildSync.Comm.MyKey() end

local function ready()
  local key = me()
  return started and key ~= nil and ns.Ranks.IsBankChar(key)
end

-- Store.Put; a key it writes leaves the session's unheld set (d784, f5336).
local function put(key, body, t)
  if not ns.Store.Put(key, body, t) then return false end
  local set = ns.Sync.UnheldScan(ns.ParseKey(key))
  if set then set[key] = nil end
  return true
end

-- The pieces b1..bn of the whole b body (d772). Past the b cap the scan cuts: it keeps the lowest item ids that fit.
local function pieces(body)
  local mine = me()
  local list = ns.Store.Fit("b", mine, body)
  if list then return list end
  local ids = {}
  for id in pairs(body.items or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local function prefix(n) -- body with only the first n item ids
    local part = {}
    for k, v in pairs(body) do part[k] = v end
    part.items = {}
    for i = 1, n do part.items[ids[i]] = body.items[ids[i]] end
    return part
  end
  local lo, hi = 0, #ids -- Fit holds with the first lo ids
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if ns.Store.Fit("b", mine, prefix(mid)) then lo = mid else hi = mid - 1 end
  end
  cut = mine
  return ns.Store.Fit("b", mine, prefix(lo)) or {}
end

-- Writes the b family: b1..bn from Fit, and {} over a held own piece beyond n (d772).
local function writeB(body, t)
  local mine = me()
  local list = pieces(body)
  local good = #list > 0
  for i, p in ipairs(list) do
    if not put(ns.Key("b", i, mine), p, t) then good = false end
  end
  local records = ns.DB().records.bank or {}
  for i = #list + 1, ns.CAPS.b do
    local key = ns.Key("b", i, mine)
    local old = records[key]
    if old and type(old.body) == "table" and next(old.body) ~= nil then put(key, {}, t) end
  end
  return good
end

-- After a complete read of family: {} over every own key in the session's unheld set beyond the new count (f5336).
local function unheldTail(family, count, t)
  local set = ns.Sync.UnheldScan(family)
  for key in pairs(set or {}) do
    local _, n = ns.ParseKey(key)
    if n and n > count then put(key, {}, t) end
  end
end

-- The body held now: for b the pieces b1..bn joined (money and scanned from b1, items from all), else the record's.
local function heldBody(key)
  local records = ns.DB().records.bank or {}
  if ns.ParseKey(key) ~= "b" then return records[key] and records[key].body end
  local first = records[key] and records[key].body
  if type(first) ~= "table" then return nil end
  local joined = {}
  for k, v in pairs(first) do if k ~= "items" then joined[k] = v end end
  joined.items = {}
  for i = 1, ns.CAPS.b do
    local r = records[ns.Key("b", i, me())]
    for id, n in pairs(r and type(r.body) == "table" and type(r.body.items) == "table" and r.body.items or {}) do
      joined.items[id] = n
    end
  end
  return joined
end

-- Writes body under key when its content changed: now, or once the debounce allows (again() reads afresh then).
local function save(key, body, again, force)
  local old = heldBody(key)
  if old and same(content(old), content(body)) then return end
  local t = body.scanned
  local wait = tonumber(ns.DB().settings.debounce) or ns.LIMITS.debounce
  local last = lastAt[key]
  if not force and last and t - last < wait then
    if not held[key] then
      held[key] = true
      M.After(last + wait - t, function()
        held[key] = nil
        if ready() then again() end
      end)
    end
    return
  end
  local good
  if ns.ParseKey(key) == "b" then good = writeB(body, t) else good = put(key, body, t) end
  if good then lastAt[key] = t end
end

-- { [itemID] = count } over the containers, or nil when 0 slots were seen or any read was nil or secret.
local function readContainers(bags)
  local items, seen = {}, 0
  for _, bag in ipairs(bags) do
    local n = num(call("C_Container.GetContainerNumSlots", bag))
    if not n then return nil end
    seen = seen + n
    for slot = 1, n do
      local info = call("C_Container.GetContainerItemInfo", bag, slot)
      if info ~= nil then -- nil is an empty slot
        if type(info) ~= "table" then return nil end
        local id, count = num(info.itemID), num(info.stackCount)
        if not id or not count then return nil end
        items[id] = (items[id] or 0) + count
      end
    end
  end
  if seen == 0 then return nil end
  return items
end

local function scanBags()
  if not ready() then return end
  local t, money = now(), num(call("GetMoney"))
  local items = readContainers(BAGS)
  if not t or not money or not items then return end
  local body = { scanned = t, money = money, items = items }
  save(ns.Key("b", 1, me()), body, scanBags)
  if next(ns.Sync.UnheldScan("b") or {}) then unheldTail("b", #pieces(body), t) end
end

local scanTabs
local function readTabs(force)
  if not ready() or not bankOpen then return end
  if plain(call("C_Bank.CanViewBank")) ~= true then return end
  local bankType = Enum and Enum.BankType and Enum.BankType.Character
  if bankType == nil then return end
  local ids = call("C_Bank.FetchPurchasedBankTabIDs", bankType)
  local t = now()
  if type(ids) ~= "table" or not t then return end
  local count, complete = math.min(#ids, ns.CAPS.k), true
  if #ids > count then cut = me() end
  for n = 1, count do
    local id = num(ids[n])
    local items = id and readContainers({ id })
    if items then
      save(ns.Key("k", n, me()), { scanned = t, tab = id, items = items }, scanTabs, force)
    else
      complete = false
    end
  end
  if complete then unheldTail("k", count, t) end
end
scanTabs = function() readTabs(false) end

local function onBankOpened()
  bankOpen = true
  scanTabs()
end

-- The one write at bank close: the held change goes in now, while the client still answers CanViewBank.
local function onBankClosed()
  if not bankOpen then return end
  readTabs(true)
  bankOpen = false
end

-- ---------- guild bank (D11) ----------

-- This character's key once a scan was cut at a family cap, else nil (Health's `cut: <holder>`).
function Scan.Cut() return cut end

function Scan.GuildBankReadable()
  if plain(call("C_GuildBank.IsGuildBankEnabled")) ~= true then return false, NOT_READABLE end
  for _, name in ipairs(GUILD_READERS) do
    if not GuildSync.Compat.Has(name) then return false, NOT_READABLE end
  end
  return true
end

function Scan.GuildBankItems(tabs)
  if type(tabs) ~= "table" then return nil end
  local items = {}
  for _, tab in ipairs(tabs) do
    if type(tab) ~= "table" then return nil end
    local viewable = plain(tab.viewable)
    if type(viewable) ~= "boolean" then return nil end
    if viewable then
      for _, slot in ipairs(type(tab.slots) == "table" and tab.slots or {}) do
        if type(slot) ~= "table" then return nil end
        local id, count = num(slot.id), num(slot.count)
        if not id or not count then return nil end
        items[id] = (items[id] or 0) + count
      end
    end
  end
  return items
end

-- Tab n as GuildBankItems takes it; empty slots (no link) are left out.
local function readGuildTab(n)
  local _, _, viewable = call("GetGuildBankTabInfo", n)
  local tab = { viewable = viewable, slots = {} }
  if viewable ~= true then return tab end
  for slot = 1, GUILD_SLOTS do
    local link = call("GetGuildBankItemLink", n, slot)
    if type(link) == "string" then
      local _, count = call("GetGuildBankItemInfo", n, slot)
      tab.slots[#tab.slots + 1] = { id = tonumber(link:match("item:(%d+)")), count = count }
    end
  end
  return tab
end

local function guildTabs()
  return num(call("GetNumGuildBankTabs")) or 0
end

local function empty(items) return type(items) ~= "table" or next(items) == nil end

local function scanGuild()
  if not ready() or not guildOpen or not Scan.GuildBankReadable() then return end
  local t = now()
  if not t then return end
  local records = ns.DB().records.bank
  local count, complete = math.min(guildTabs(), ns.CAPS.g), true
  if guildTabs() > count then cut = me() end
  for n = 1, count do
    local tab = guildLoaded[n] and readGuildTab(n)
    if not tab then complete = false end
    if tab and tab.viewable == true then
      local items = Scan.GuildBankItems({ tab })
      local key = ns.Key("g", n, me())
      local old = records and records[key]
      -- No wipe from an uncertain read: the event may have answered another tab (Blizzard's frame, a tab click),
      -- and tab n read before its data arrived looks all empty. A tab whose items read as secret looks empty too.
      -- A read with any item is tab n's data and replaces the record, smaller or not (a real withdrawal).
      if items and guildLoaded[n] ~= "sure" and empty(items) and old and not empty(old.body and old.body.items) then
        items = nil
      end
      if items then save(key, { scanned = t, tab = n, items = items }, scanGuild) else complete = false end
    end
  end
  if complete then unheldTail("g", count, t) end
end

local function resetGuild()
  guildQueue, guildPending, guildLoaded = {}, nil, {}
  guildGen = guildGen + 1 -- a timer from an earlier visit or query finds a newer generation and does nothing
end

-- Sends the next query; with no answer in 2.5 s (the tab was already current, or the server throttled it) the queue
-- moves on without marking that tab loaded.
local function queryNextTab()
  guildPending = table.remove(guildQueue, 1)
  if not guildPending then return end
  guildGen = guildGen + 1
  local gen, tab = guildGen, guildPending
  call("QueryGuildBankTab", tab)
  M.After(QUERY_TIMEOUT, function()
    if guildOpen and guildGen == gen and guildPending == tab then queryNextTab() end
  end)
end

-- The queue starts OPEN_DELAY after the open, as the old recorder did (Bags.lua): the client settles its own queries first.
local function onGuildBankOpened()
  resetGuild()
  guildOpen = true
  local gen = guildGen
  M.After(OPEN_DELAY, function()
    if not guildOpen or guildGen ~= gen then return end
    if not ready() or not Scan.GuildBankReadable() then return end
    for n = 1, guildTabs() do
      local _, _, viewable = call("GetGuildBankTabInfo", n)
      if viewable == true then guildQueue[#guildQueue + 1] = n end
    end
    queryNextTab()
  end)
end

-- Any GUILDBANKBAGSLOTS_CHANGED marks the tab on screen loaded and "sure" (Blizzard's frame queried it, as the old
-- recorder assumed: Bags.lua), marks the pending tab loaded and sends the next; then the loaded tabs are read.
-- GetCurrentGuildBankTab returns the UI's selection, not the last QueryGuildBankTab; it is undocumented on Forever
-- (beta check), optional in Bank.lua's apis, and used only when the client has it.
local function onGuildSlotsChanged()
  if not guildOpen then return end
  local current = GuildSync.Compat.Has("GetCurrentGuildBankTab") and num(call("GetCurrentGuildBankTab")) or nil
  if current then guildLoaded[current] = "sure" end
  if guildPending then
    guildLoaded[guildPending] = guildLoaded[guildPending] or true
    queryNextTab()
  end
  scanGuild()
end

local function onGuildBankClosed()
  guildOpen = false
  resetGuild()
end

-- ---------- events ----------

ns.Ranks.OnChange(function()
  if started then return end
  local key = me()
  -- settled: MyKey has a roster row, so Store.Put writes (Store.IsOwn is not roster-gated, f5328)
  if not key or not GuildSync.Comm.Member(key) or not ns.Ranks.IsBankChar(key) then return end
  started = true
  scanBags()
end)

ns.Listen("BAG_UPDATE_DELAYED", function()
  scanBags()
  scanTabs()
end)
ns.Listen("PLAYER_MONEY", scanBags)
ns.Listen("BANKFRAME_OPENED", onBankOpened)
ns.Listen("BANKFRAME_CLOSED", onBankClosed)
ns.Listen("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
  if BANKER_FRAMES[plain(kind)] then onBankOpened() end
end)
ns.Listen("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
  if BANKER_FRAMES[plain(kind)] then onBankClosed() end
end)
ns.Listen("PLAYERBANKSLOTS_CHANGED", scanTabs)
ns.Listen("BANK_TABS_CHANGED", scanTabs)
ns.Listen("GUILDBANKFRAME_OPENED", onGuildBankOpened)
ns.Listen("GUILDBANKBAGSLOTS_CHANGED", onGuildSlotsChanged)
ns.Listen("GUILDBANKFRAME_CLOSED", onGuildBankClosed)
