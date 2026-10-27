-- GuildSyncBank items: names, icons and item entry (bank/brief.md D12, I20, I21).
-- Names and icons come from this client only, never from a record. An uncached id shows `item #<id>` with the icon
-- from C_Item.GetItemIconByID and asks the client to load it (RequestLoadItemDataByID, or C_Item.GetItemInfo where
-- that is missing, as on Forever build 70245); ITEM_DATA_LOAD_RESULT redraws the page. An invalid id starts no load,
-- and at most MAX_LOADS loads start per refresh window, the rest queued (t42 section 7).
-- There is no API that lists the client's cached names, so a name is looked up in ns.REAGENTS (Reagents.lua, read at
-- call time: it loads after this file) and then among the candidate ids the caller passes (the view's items).
--   ns.Items.Line(itemId) -> text, icon, loading, quality   (quality nil while the item is not cached)
--   ns.Items.Cached(itemId) -> name, icon | nil             read-only: only a cached id answers; never starts a load
--   ns.Items.Parse(text, candidateIds) -> itemId | nil, why
--   ns.Items.Search(query, itemIds) -> itemIds
--   ns.Items.HookInsert() -> "ChatFrameUtil.InsertLink" | "ChatEdit_InsertLink" | nil
--   ns.Items.SetTarget(editBox | nil)   the box a shift-clicked item fills
--   ns.Items.Target() -> editBox | nil   the box set now (a box clears it on focus lost or hide only when it is this)

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Items = {}
ns.Items = Items

local UNKNOWN = "Shift-click the item or pick it from the list."

local pending = {} -- itemId -> true while a load request is out
local failed = {}  -- itemId -> true once the client answered success == false: no new request this session
local target       -- the entry box a shift-click fills
local hooked       -- the hook's name once in place

-- t42 section 7 (f5301): an id outside 1..2^31-1, or one C_Item.DoesItemExistByID (when present) says does not exist,
-- starts no load. At most MAX_LOADS loads start per refresh window; ids past it wait in a queue and start at the next
-- coalesced refresh (0.5 s) and as ITEM_DATA_LOAD_RESULT frees a slot (R7-5).
local MAX_ID = 2147483647
local MAX_LOADS = 20
local started = 0              -- loads started in this window
local queue, queued = {}, {}   -- ids waiting for a slot, in order; id -> true
local draining                 -- the coalesced refresh is scheduled

local function plain(v) return GuildSync.Compat.Plain(v) end
local function has(path) return GuildSync.Compat.Has(path) end

-- name, icon of an id this client has cached, or nil. Never starts a load.
local function cachedName(id)
  if not plain(M.Compat.call("C_Item.IsItemDataCachedByID", id)) then return nil end
  local name = plain(M.Compat.call("C_Item.GetItemInfo", id))
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

local function reagents()
  return type(ns.REAGENTS) == "table" and ns.REAGENTS or {}
end

local function valid(id)
  if type(id) ~= "number" or id < 1 or id > MAX_ID or id % 1 ~= 0 then return false end
  if has("C_Item.DoesItemExistByID") and plain(M.Compat.call("C_Item.DoesItemExistByID", id)) == false then
    return false
  end
  return true
end

-- One load: RequestLoadItemDataByID, or an uncached C_Item.GetItemInfo where that is missing (it asks the server).
local function load(id)
  pending[id] = true
  started = started + 1
  if has("C_Item.RequestLoadItemDataByID") then
    M.Compat.call("C_Item.RequestLoadItemDataByID", id)
  else
    M.Compat.call("C_Item.GetItemInfo", id)
  end
end

local function startQueued()
  while started < MAX_LOADS and #queue > 0 do
    local id = table.remove(queue, 1)
    queued[id] = nil
    if not pending[id] and not failed[id] then load(id) end
  end
end

-- The coalesced refresh: a new window, the queued ids, a redraw. A window that started loads schedules the next one,
-- so the count always falls back to 0.
local drain
local function schedule()
  if draining then return end
  draining = true
  M.After(0.5, drain)
end
drain = function()
  draining = false
  started = 0
  startQueued()
  if started > 0 then schedule() end
  M.RefreshPage()
end

local function ask(id)
  if pending[id] or failed[id] or queued[id] then return end
  if started < MAX_LOADS then
    load(id)
  else
    queued[id] = true
    queue[#queue + 1] = id
  end
  schedule()
end

function Items.Line(id)
  local fallback = "item #" .. tostring(id)
  if not valid(id) then return fallback, nil, false end
  -- an uncached GetItemInfo asks the server, so it is called only for a cached id (or where the cache can't be asked)
  local cached = true
  if has("C_Item.IsItemDataCachedByID") then cached = plain(M.Compat.call("C_Item.IsItemDataCachedByID", id)) end
  if cached then
    local name, _, quality, _, _, _, _, _, _, icon = M.Compat.call("C_Item.GetItemInfo", id)
    name, icon = plain(name), plain(icon)
    if type(name) == "string" and name ~= "" then return name, icon, false, plain(quality) end
  end
  ask(id)
  return fallback, plain(M.Compat.call("C_Item.GetItemIconByID", id)), true
end

-- cachedName's check, with the icon from the same GetItemInfo call (a search row's icon, s6).
function Items.Cached(id)
  if not plain(M.Compat.call("C_Item.IsItemDataCachedByID", id)) then return nil end
  local name, _, _, _, _, _, _, _, _, icon = M.Compat.call("C_Item.GetItemInfo", id)
  name = plain(name)
  if type(name) ~= "string" or name == "" then return nil end
  return name, plain(icon)
end

ns.Listen("ITEM_DATA_LOAD_RESULT", function(_, id, success)
  id = plain(id)
  if id == nil or not pending[id] then return end
  pending[id] = nil
  if started > 0 then started = started - 1 end
  startQueued()
  if plain(success) == false then failed[id] = true return end
  M.RefreshPage()
end)

function Items.Parse(text, ids)
  text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
  local id = tonumber(text:match("|Hitem:(%d+)") or text:match("^(%d+)$"))
  if id and id > 0 then return id end
  if text == "" then return nil, UNKNOWN end
  local want = text:lower()
  for _, r in ipairs(reagents()) do
    if type(r.name) == "string" and r.name:lower() == want then return r.id end
  end
  for _, cand in ipairs(ids or {}) do
    local name = cachedName(cand)
    if name and name:lower() == want then return cand end
  end
  return nil, UNKNOWN
end

function Items.Search(query, ids)
  local want = type(query) == "string" and query:lower() or ""
  local out, seen = {}, {}
  local function add(id, name)
    if id and not seen[id] and name and name:lower():find(want, 1, true) then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  for _, id in ipairs(ids or {}) do add(id, cachedName(id)) end
  for _, r in ipairs(reagents()) do add(r.id, type(r.name) == "string" and r.name or nil) end
  return out
end

-- After every chat link insert: an item link fills the target box.
local function onInsert(text)
  local link = plain(text)
  if target and type(link) == "string" and link:find("|Hitem:", 1, true) then target:SetText(link) end
end
local function after(text) M.Safe(onInsert, text) end

function Items.HookInsert()
  if hooked then return hooked end
  if not has("hooksecurefunc") then return nil end
  if has("ChatFrameUtil.InsertLink") then
    hooksecurefunc(ChatFrameUtil, "InsertLink", after)
    hooked = "ChatFrameUtil.InsertLink"
  elseif has("ChatEdit_InsertLink") then
    hooksecurefunc("ChatEdit_InsertLink", after)
    hooked = "ChatEdit_InsertLink"
  end
  return hooked
end

function Items.SetTarget(box) target = box end
function Items.Target() return target end
