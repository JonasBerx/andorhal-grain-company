local _, ns = ...
if not ns.M then return end
-- Nights.lua: F (shared piece E), wave 1 (F, second PR). The per-raid saved state: GuildSyncRaidsDB.nights, keyed by the
-- Raid-Helper event id as a string. Each owner keeps its own fields in a night; made and ends are reserved here.
-- ns.Night(key) answers the night, made on first use with made = server time and ends = the held raid's finish (one
-- ns.View() read at creation). ns.NightsLogin() runs at login before the store prune (Raids.lua onLogin): it removes a
-- broken entry, stamps a missing made, copies the held raid's finish into ends (outside demo), and prunes a night at
-- ends + 1 day, or with no ends at made + 2 days. In /gsync demo ns.Night answers a session-only table, never saved.

local M = ns.M
local Plain = GuildSync.Compat.Plain
local call = M.Compat.call

local DAY = 86400

-- Session-only nights for /gsync demo.
local demoNights = {}

local function now()
  local t = Plain(call("GetServerTime"))
  if type(t) == "number" then return t end
  return nil
end

-- The held raids' finishes by event id (the digits, a string), from the view (Store.lua ns.View, Rules.View).
local function finishes()
  local out = {}
  local view = ns.View and ns.View()
  local events = type(view) == "table" and view.events
  if type(events) ~= "table" then return out end
  for _, ev in ipairs(events) do
    if type(ev) == "table" and type(ev.id) == "string" and type(ev.finish) == "number" then out[ev.id] = ev.finish end
  end
  return out
end

-- ns.Night(ev.id).holders: the night for a Raid-Helper event id (a string or a number); nil for any other key.
function ns.Night(key)
  key = Plain(key)
  if type(key) ~= "string" and type(key) ~= "number" then return nil end
  local k = tostring(key)
  if k == "" then return nil end
  local list
  if M.Demo() == true then list = demoNights else list = ns.DB().nights end
  local n = list[k]
  if type(n) ~= "table" then
    n = { made = now(), ends = finishes()[k] }
    list[k] = n
  end
  return n
end

-- At login, before the store prune (the store drops a raid only at login), so the last login that holds a raid copies
-- its finish.
function ns.NightsLogin()
  local t = now()
  if not t then return end
  local nights = ns.DB().nights
  local held
  if M.Demo() ~= true then held = finishes() end
  for k, n in pairs(nights) do
    if type(n) ~= "table" then
      nights[k] = nil
    else
      if type(n.made) ~= "number" then n.made = t end
      if held and held[k] then n.ends = held[k] end
      if type(n.ends) == "number" then
        if t >= n.ends + DAY then nights[k] = nil end
      elseif t >= n.made + 2 * DAY then
        nights[k] = nil
      end
    end
  end
end
