-- GuildSyncExpeditions QuestWatch.lua: finishes open writs from what the client reports (slice H plan, Task 2).
--   ns.BringCount(writ) -> n | nil
-- One function in ns.EventHooks and one in ns.LoginHooks. It only reads: nothing is sent or clicked for the player.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Plain = GuildSync.Compat.Plain
local D = ns.QuestData

local TICK = 10 -- seconds between position re-reads while a place writ on this map waits

local ticking = false

local function eachOpen(kind, fn)
  -- A game event must not create a saved part.
  if not M.Demo() and (type(GuildSyncExpeditionsDB) ~= "table" or GuildSyncExpeditionsDB.quests == nil) then return end
  for _, open in ipairs(ns.OpenWrits()) do
    local w = D.BY_ID[open.id]
    if w.kind == kind then fn(w) end
  end
end

-- The npc id is the 6th dash field of a Creature GUID.
local function creatureId(guid)
  guid = Plain(guid)
  if type(guid) ~= "string" then return nil end
  return tonumber(string.match(guid, "^Creature%-[^-]*%-[^-]*%-[^-]*%-[^-]*%-([^-]*)"))
end

local function lists(w, npc)
  for _, id in ipairs(w.npcs) do
    if id == npc then return true end
  end
  return false
end

-- The o2878 mail capture replaces the MAIL branch and countOf.
local function countOf(writ)
  local n = M.Compat.call("C_Item.GetItemCount", writ.item)
  if type(n) == "number" then return n end
  return nil
end
ns.BringCount = countOf

local function atSpot(w, map)
  if not w.pos then return true end
  local p = M.Compat.call("C_Map.GetPlayerMapPosition", map, "player")
  if type(p) ~= "table" then return false end
  local x, y = Plain(p.x), Plain(p.y)
  if type(x) ~= "number" or type(y) ~= "number" then return false end
  local dx, dy = x - w.pos.x, y - w.pos.y
  return dx * dx + dy * dy <= w.radius * w.radius
end

-- Finishes what this map and spot complete; true when a place writ on this map stays open.
local function checkPlaces()
  local map = M.Compat.call("C_Map.GetBestMapForUnit", "player")
  if type(map) ~= "number" then return false end
  local waiting = false
  eachOpen("go", function(w)
    if w.map ~= map then return end
    if atSpot(w, map) then ns.FinishWrit(w.id) else waiting = true end
  end)
  return waiting
end

local function watchPlaces()
  if not checkPlaces() or ticking then return end
  ticking = true
  M.After(TICK, function()
    ticking = false -- first, so a throw below cannot end the loop for the session
    if M.Demo() then return end
    watchPlaces()
  end)
end

local function onKill(killer, victim)
  killer = Plain(killer)
  if type(killer) ~= "string" or killer ~= M.Compat.call("UnitGUID", "player") then return end
  local npc = creatureId(victim)
  if not npc then return end
  eachOpen("kill", function(w)
    if lists(w, npc) then ns.AddWritProgress(w.id, 1) end
  end)
end

local function onTalk()
  local npc = creatureId(M.Compat.call("UnitGUID", "npc"))
  if not npc then return end
  eachOpen("talk", function(w)
    if lists(w, npc) then ns.FinishWrit(w.id) end
  end)
end

local function onMail()
  eachOpen("bring", function(w)
    local n = countOf(w)
    if n and n >= w.need then ns.FinishWrit(w.id) end
  end)
end

ns.EventHooks[#ns.EventHooks + 1] = function(event, ...)
  if M.Demo() then return end
  if event == "ZONE_CHANGED_NEW_AREA" then
    watchPlaces()
  elseif event == "PARTY_KILL" then
    onKill(...)
  elseif event == "GOSSIP_SHOW" or event == "MERCHANT_SHOW" then
    onTalk()
  elseif event == "MAIL_SHOW" then
    onMail()
  end
end

ns.LoginHooks[#ns.LoginHooks + 1] = function()
  if M.Demo() then return end
  watchPlaces()
end
