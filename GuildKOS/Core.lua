-- GuildKOS Core: saved data (GuildKOSDB schema 6, guild-scoped), the client-event dispatcher behind the Plain seam,
-- /kos (list, ui, mark, add by name, alerts on and off, demo) and the alerts setting. R6 Task A1 retired 0.5's
-- import, paste window, wire and spotting.
local ADDON, ns = ...
local Core = {}
ns.Core = Core

-- The Kill on Sight page on the hub (Hub.lua); called when the list, a sighting or a setting changes.
local function refreshPage() if ns.Hub then ns.Hub.Refresh() end end

-- ---------- the Plain seam (d757 item 1) ----------

-- GuildSync.Compat is read-only, so every event arg and unit read goes through ns.Core.Plain, looked up at call time
-- (a test swaps it). With an older hub that has no Compat nothing is registered, so no event ever arrives.
local hubCompat = type(GuildSync) == "table" and type(GuildSync.API) == "number" and GuildSync.API >= 4
  and GuildSync.Compat or nil
Core.Plain = hubCompat and hubCompat.Plain or function() return nil end

-- ---------- saved data ----------

-- GuildKOSDB = { schema = 6, guilds = { [guild name .. ".." .. realm] = { ... } }, muted = bool }. Any other shape
-- (0.5's list, lastSeen, sightings, demo, minimap) is discarded. Re-read on every call: GuildKOSDB is nil at load and
-- replaced when the saved variables arrive.
local SCHEMA = 6

function Core.DB()
  local db = GuildKOSDB
  if type(db) ~= "table" or db.schema ~= SCHEMA then
    db = { schema = SCHEMA, guilds = {}, muted = false }
    GuildKOSDB = db
  end
  if type(db.guilds) ~= "table" then db.guilds = {} end
  db.muted = db.muted == true
  return db
end

-- The guild's key as the hub keeps it (CommRegistry.lua:70, f5226), or nil while the guild name is unread. Read as
-- the hub reads it (Roster.lua:72): GetGuildInfo's name and realm, the realm falling back to the character's.
function Core.GuildKey()
  if not ns.Hub then return nil end
  local name, _, _, realm = ns.Hub.Call("GetGuildInfo", "player")
  if type(name) ~= "string" or name == "" then return nil end
  if type(realm) ~= "string" or realm == "" then realm = ns.Hub.Call("GetRealmName") end
  if type(realm) ~= "string" or realm == "" then return nil end
  return name .. ".." .. realm
end

-- This guild's saved table, made on first use; nil while the guild name is unread.
function Core.Guild()
  local key = Core.GuildKey()
  if not key then return nil end
  local guilds = Core.DB().guilds
  if type(guilds[key]) ~= "table" then
    guilds[key] = { kos = {}, kos_h = {}, kos_m = {}, gone = { kos = {}, kos_h = {}, kos_m = {} }, lastSeen = {} }
  end
  return guilds[key]
end

do
  local f = CreateFrame("Frame")
  f:RegisterEvent("ADDON_LOADED")
  f:SetScript("OnEvent", function(_, _, name) if name == ADDON then Core.DB() end end)
end

-- Server time through the hub (M.Compat.call, d761); 0 before the module is registered.
function Core.Now()
  local t = ns.Hub and ns.Hub.Now() or nil
  return type(t) == "number" and t or 0
end

-- The real list and last-seen data (the hub's demo is drawn by Hub.lua, never stored here): the open targets from the
-- store (List.Open) in the page's { targets = { { target, race, class } } } shape, and this guild's lastSeen.
function Core.View()
  local g = Core.Guild()
  local targets = {}
  for _, t in ipairs(ns.List and ns.List.Open() or {}) do
    targets[#targets + 1] = { target = t.rec.name, race = t.rec.race, class = t.rec.class, guid = t.guid }
  end
  if #targets == 0 then return nil, g and g.lastSeen or {} end -- no open target: the page's empty line
  return { targets = targets }, g and g.lastSeen or {}
end

-- ---------- client events (the module's events, Hub.lua) ----------

local UNIT_OF = { PLAYER_TARGET_CHANGED = "target", UPDATE_MOUSEOVER_UNIT = "mouseover" }

local function route(file, fn, ...)
  local t = ns[file]
  if type(t) == "table" and type(t[fn]) == "function" then t[fn](...) end
end

-- Every event arg goes through Core.Plain before anything else touches it, and the GUID is read through the handle's
-- M.Compat.call (d763), which plains every return: a secret becomes nil.
function Core.OnEvent(event, a1, a2)
  if event == "ZONE_CHANGED_NEW_AREA" then
    route("Spot", "OnZone")
  elseif event == "NAME_PLATE_UNIT_ADDED" or UNIT_OF[event] then
    local unit = Core.Plain(UNIT_OF[event] or a1)
    if type(unit) ~= "string" then return end
    local guid = ns.Hub and ns.Hub.Call("UnitGUID", unit) or nil
    route("Spot", "OnUnit", event, unit, guid)
  end
end

-- ---------- actions shared by /kos, the page and the settings ----------

function Core.SetMuted(muted)
  local db = Core.DB()
  db.muted = muted == true
  if db.muted then
    print("KOS: Alerts are off. You still tell the guild what you see.")
  else
    print("KOS: Alerts are on.")
  end
  refreshPage()
end

-- ---------- /kos ----------

-- 0.5's KOS1 paste is gone: the list is made in game (brief AC6).
local IMPORT_LINE = "KOS: There is no import any more. The list is made in game with Mark as bounty."

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- /kos alone: the open targets in chat, one line each, every other-player field escaped (AC23).
local function printList()
  if not ns.Hub then print("KOS: The Kill on Sight page needs GuildSync (API 4 or later).") return end
  local esc = ns.Hub.Escape
  local Marks = ns.RulesMarks
  local function row(r, guid)
    local line = "  " .. esc(r.name or "?")
    if Marks.IsNameKey(guid) then line = line .. " (" .. Marks.NAME_WHO .. ")" -- added by name, never seen
    else line = line .. " (" .. esc(r.race or "") .. " " .. esc(r.class or "") .. ")" end
    if type(r.zone) == "string" and r.zone ~= "" then line = line .. ", " .. esc(r.zone) end
    if type(r.why) == "string" and r.why ~= "" then line = line .. ": " .. esc(r.why) end
    print(line)
  end
  local open = ns.List and ns.List.Open() or {}
  if #open == 0 then print("KOS: No open targets. /kos ui opens the Kill on Sight page.")
  else
    print("KOS: " .. ns.Page.Targets(#open) .. " on the list:")
    for _, t in ipairs(open) do row(t.rec, t.guid) end
  end
  -- the waiting marks this client may see: an officer all, a member its own (AC20, ns.Mark.Waiting)
  local waiting = ns.Mark and ns.Mark.Waiting and ns.Mark.Waiting() or {}
  if #waiting > 0 then
    print("KOS: Waiting for an officer:")
    for _, w in ipairs(waiting) do row(w.mark, w.mark.guid) end
  end
end

local function slash(msg)
  msg = trim(type(msg) == "string" and msg or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    printList()
  elseif cmd == "ui" or cmd == "window" then
    if ns.Hub then ns.Hub.Open() else print("KOS: The Kill on Sight page needs GuildSync (API 4 or later).") end
  elseif cmd == "on" then
    Core.SetMuted(false)
  elseif cmd == "off" then
    Core.SetMuted(true)
  elseif cmd == "mark" then
    -- Mark as bounty on the current target (ns.Mark, Task D); inert under /gsync demo (AC36)
    if ns.Hub and ns.Hub.InDemo() then print("KOS: " .. ns.List.RefusalLine("demo"))
    elseif rest == "" then route("Mark", "FromTarget")
    else route("Mark", "FromTarget", rest) end
  elseif cmd == "add" then
    -- Mark a player by the typed First Surname (ns.Mark.FromName); inert under /gsync demo, as /kos mark
    if ns.Hub and ns.Hub.InDemo() then print("KOS: " .. ns.List.RefusalLine("demo"))
    else route("Mark", "FromName", ns.RulesMarks.SplitAdd(rest)) end
  elseif cmd == "import" then
    print(IMPORT_LINE)
  elseif cmd == "demo" then
    -- the hub's demo (d604): /kos demo is /gsync demo
    rest = rest:lower()
    if rest ~= "" and rest ~= "on" and rest ~= "off" then
      print("Usage: /kos demo [on | off]")
    else
      local fn = type(SlashCmdList) == "table" and SlashCmdList.GUILDSYNC or nil
      if type(fn) == "function" then fn(rest == "" and "demo" or ("demo " .. rest))
      else print("KOS: /gsync demo is not available.") end
    end
  else
    print("KOS: /kos prints the list, /kos ui opens the Kill on Sight page, /kos mark [why] marks your target as a bounty, /kos add First Surname [why] marks a player by name, /kos on and /kos off turn alerts on and off, /kos demo shows a demo (as /gsync demo).")
  end
end

SLASH_KOS1 = "/kos"
SlashCmdList.KOS = slash
Core.Slash = slash

return Core
