local _, ns = ...
if not ns.M then return end
-- Items.lua: F (shared piece B), the item model. No UI, no frame, no event of its own: Raids.lua routes
-- GET_ITEM_INFO_RECEIVED and ITEM_DATA_LOAD_RESULT to ns.OnItemEvent. Every client call goes through M.Compat (names
-- in Raids.lua apis), every value through GuildSync.Compat.Plain. A link is parsed, never built.
--   ns.Items.Id(link) -> id, suffix | nil       suffix: link field 7, a non-zero integer (negative kept), else nil
--   ns.Items.Info(id) -> info | nil             { name, icon, quality, slot, class, subclass, bind, loading }
--   ns.Items.OnLoad(fn)                         fn(id) under M.Safe, once per asked id, at the first of the two events
--   ns.Items.Box(editBox) -> hookName | nil     a shift-clicked item link fills the registered box shown with focus
--   ns.Items.IsCouncil(id, size) -> bool, why   false, "no rule" until ns.Items.CouncilRule = fn(id, size, info)
--   ns.OnItemEvent(event, id, success)

local M = ns.M
local Items = {}
ns.Items = Items
Items.CouncilRule = nil

local MAX_ID = 2147483647
local MAX_LOADS = 20 -- loads started per 0.5 s window (Bank's cap)
local QMARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local pending = {}           -- id -> true while a load is out
local failed = {}            -- id -> true once the client answered success == false: never asked again
local started = 0            -- loads started in this window
local queue, queued = {}, {} -- ids waiting for a slot, in order; id -> true
local draining               -- the window's drain is scheduled
local onLoad = {}            -- the OnLoad fns, in order
local boxes = {}             -- the registered boxes, in order; box -> true in seen
local seen = {}
local hooked                 -- the hook's name once in place

local function plain(v) return GuildSync.Compat.Plain(v) end
local function has(path) return GuildSync.Compat.Has(path) end

local function valid(id)
  if type(id) ~= "number" or id < 1 or id > MAX_ID or id % 1 ~= 0 then return false end
  if has("C_Item.DoesItemExistByID") and plain(M.Compat.call("C_Item.DoesItemExistByID", id)) == false then
    return false
  end
  return true
end

function Items.Id(link)
  local text = plain(link)
  if type(text) ~= "string" then return nil end
  local digits, rest = text:match("|Hitem:(%d+)([^|]*)")
  local id = tonumber(digits)
  if not id or id < 1 or id > MAX_ID then return nil end
  -- rest is ":f2:f3:...": the 6th field after the id is field 7, the suffix
  local n, field = 0, nil
  for f in rest:gmatch(":([^:]*)") do
    n = n + 1
    if n == 6 then field = f break end
  end
  local suffix
  if field and field:match("^%-?%d+$") then suffix = tonumber(field) end
  if suffix == 0 then suffix = nil end
  return id, suffix
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

-- A new window every 0.5 s while loads start or wait, so the count always falls back to 0.
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
  if started > 0 or #queue > 0 then schedule() end
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

local function iconOf(id)
  local icon = plain(M.Compat.call("C_Item.GetItemIconByID", id))
  if icon ~= nil then return icon end
  return QMARK
end

local function num(v)
  v = plain(v)
  if type(v) == "number" then return v end
  return nil
end

function Items.Info(id)
  if not valid(id) then return nil end
  -- an uncached GetItemInfo asks the server, so it is called only for a cached id (or where the cache can't be asked)
  local cached = true
  if has("C_Item.IsItemDataCachedByID") then cached = plain(M.Compat.call("C_Item.IsItemDataCachedByID", id)) end
  if cached then
    local name, _, quality, _, _, _, _, _, slot, icon, _, class, subclass, bind = M.Compat.call("C_Item.GetItemInfo", id)
    name, slot, icon = plain(name), plain(slot), plain(icon)
    if type(name) == "string" and name ~= "" then
      if type(slot) ~= "string" or slot == "" then slot = nil end
      if icon == nil then icon = iconOf(id) end
      return { name = name, icon = icon, quality = num(quality), slot = slot, class = num(class),
        subclass = num(subclass), bind = num(bind), loading = false }
    end
  end
  local loading = not failed[id]
  if loading then ask(id) end
  return { name = "item #" .. tostring(id), icon = iconOf(id), loading = loading }
end

function Items.OnLoad(fn)
  if type(fn) == "function" then onLoad[#onLoad + 1] = fn end
end

-- Routed by Raids.lua: the first of the two events for an id Items asked for finishes its load.
function ns.OnItemEvent(event, id, success)
  if event ~= "ITEM_DATA_LOAD_RESULT" and event ~= "GET_ITEM_INFO_RECEIVED" then return end
  id = plain(id)
  if id == nil or not pending[id] then return end
  pending[id] = nil
  if plain(success) == false then failed[id] = true end
  for _, fn in ipairs(onLoad) do M.Safe(fn, id) end
end

-- After every chat link insert: an item link fills the registered box that is shown and has focus.
local function onInsert(text)
  local link = plain(text)
  if type(link) ~= "string" or not link:find("|Hitem:", 1, true) then return end
  for _, b in ipairs(boxes) do
    if plain(b:IsShown()) == true and plain(b:HasFocus()) == true then
      b:SetText(link)
      return
    end
  end
end
local function after(text) M.Safe(onInsert, text) end

local function hook()
  if hooked then return hooked end
  if has("ChatFrameUtil.InsertLink") then
    if M.Compat.Try("hooksecurefunc", ChatFrameUtil, "InsertLink", after) then hooked = "ChatFrameUtil.InsertLink" end
  elseif has("ChatEdit_InsertLink") then
    if M.Compat.Try("hooksecurefunc", "ChatEdit_InsertLink", after) then hooked = "ChatEdit_InsertLink" end
  end
  return hooked
end

function Items.Box(editBox)
  if type(editBox) == "table" and not seen[editBox] then
    seen[editBox] = true
    boxes[#boxes + 1] = editBox
  end
  return hook()
end

function Items.IsCouncil(id, size)
  local rule = Items.CouncilRule
  if type(rule) ~= "function" then return false, "no rule" end
  local a, why
  local good = M.Safe(function() a, why = rule(id, size, Items.Info(id)) end)
  if not good then return false, "rule failed" end
  if type(a) ~= "boolean" then return false, why end
  return a, why
end
