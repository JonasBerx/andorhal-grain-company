-- GuildKOS Hub: Kill on Sight registers as a GuildSync module (API 4 or later) and draws its page (Page.lua) inside the
-- GuildSync window. With an older hub or on a refusal nothing here runs: ns.Hub stays nil and /kos says the page needs
-- API 4. Uses only the GuildSync global and the handle M. Client events go to Core.OnEvent (the Plain seam).
local _, ns = ...

if type(GuildSync) ~= "table" or type(GuildSync.API) ~= "number" or GuildSync.API < 4
  or type(GuildSync.RegisterModule) ~= "function" then
  return
end

local SKULL = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"
local TITLE = "Kill on Sight"

local hub = GuildSync
local M                 -- the handle, once the hub accepted the module
local loggedIn = false
local storeFault        -- "<domain>: <why>" when a store did not register or attach (selftest FAIL, AC35)

local function escape(s) return hub.Escape(s) end

-- The hub demo's store-shaped state (RulesDemo.lua) while /gsync demo is on (every tab draws it, d793 c), else nil.
local function demoState()
  if not M then return nil end
  local on, state = M.Demo()
  if on and type(state) == "table" then return state end
  return nil
end

-- What the List draws: the demo's open targets (in Core.View's shape) while /gsync demo is on, else the real list.
local function pageData()
  local state = demoState()
  if state and type(state.kos) == "table" then
    local targets = {}
    for key, rec in pairs(state.kos) do
      if type(rec) == "table" and rec.status == "open" then
        targets[#targets + 1] = { target = rec.name, race = rec.race, class = rec.class, guid = key:sub(2) }
      end
    end
    table.sort(targets, function(a, b) return a.target < b.target end)
    return #targets > 0 and { targets = targets } or nil, {}
  end
  return ns.Core.View()
end

local src = { escape = escape, data = pageData, demo = demoState }

-- Client functions reached through M.Compat (plan Decisions "Apis"); optional ones in this order for the selftest.
local APIS = { "GetServerTime", "UnitGUID", "UnitExists", "UnitNameUnmodified", "UnitIsPlayer", "UnitIsEnemy",
  "UnitRace", "UnitClass", "UnitLevel", "GetZoneText", "GetSubZoneText", "GetRealmName",
  "GetNormalizedRealmName", "C_Sound.PlaySound", "InCombatLockdown",
  optional = { "PlaySound", "C_Secrets.ShouldUnitIdentityBeSecret", "GetGuildInfo",
    "C_XMLUtil.GetTemplateInfo", "C_Texture.GetAtlasInfo" } }
-- What each optional client function turns off when it is missing (status).
local OFF = {
  PlaySound = "the old sound fallback",
  ["C_Secrets.ShouldUnitIdentityBeSecret"] = "the secret-identity check",
  GetGuildInfo = "the guild name fallback",
  ["C_XMLUtil.GetTemplateInfo"] = "the page's template checks (plain frames and buttons)",
  ["C_Texture.GetAtlasInfo"] = "the painting crop",
}

-- The argument each optional function is probed with in status (read-only calls).
local PROBE = {
  ["C_Secrets.ShouldUnitIdentityBeSecret"] = "player",
  GetGuildInfo = "player",
}

local function targetsLine()
  local db = ns.Core.DB()
  local list = ns.Core.View()
  local n = list and #list.targets or 0
  return ns.Page.Targets(n) .. ", alerts " .. (db.muted and "off" or "on")
end

local ok, answer = pcall(hub.RegisterModule, {
  id = "kos",
  title = TITLE,
  version = "0.6.0",
  needs = 4,
  apis = APIS,
  events = { "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED",
    "ZONE_CHANGED_NEW_AREA" },
  onEvent = function(event, ...) ns.Core.OnEvent(event, ...) end,
  slash = function(rest) ns.Core.Slash(rest) end,
  page = {
    title = TITLE,
    icon = SKULL,
    build = function(frame) ns.Page.Build(frame, src) end,
    refresh = function(frame) ns.Page.Refresh(frame, src) end,
  },
  -- /gsync demo: the made-up store state (RulesDemo.lua), held by the hub for the session; never saved, never sent.
  demo = function(g, now) return ns.RulesDemo.Build(g, now, ns.Probe and ns.Probe.kills == true) end,
  selftest = function()
    if storeFault then return "fail", "store " .. storeFault end
    if not loggedIn then return "wait", "not logged in yet" end
    -- the hub's roster read now (Comm.Roster known and whole) and the guild name, as the stores gate on (Store.Ready)
    local ready, why = ns.Store.Ready()
    if not ready then return "wait", ns.List.RefusalLine(why) end
    return "pass", targetsLine()
  end,
  status = function()
    local line = targetsLine()
    -- PlaySound is checked with GuildSync.Compat.Has (d764), since a call would play a sound; the others are probed
    -- through M.Compat.Try with a harmless argument
    for _, name in ipairs(APIS.optional) do
      local missing
      if PROBE[name] then missing = not M.Compat.Try(name, PROBE[name]) else missing = not GuildSync.Compat.Has(name) end
      if missing then line = line .. "; " .. name .. " missing: " .. OFF[name] .. " off" end
    end
    if ns.Spot and ns.Spot.Status then line = line .. "; " .. ns.Spot.Status() end
    return line
  end,
  onLogin = function() loggedIn = true end,
  -- Esc > Options > AddOns > GuildSync > Kill on Sight. The hub makes the set inert under /gsync demo.
  settings = function(S)
    S.Checkbox("alerts", "Alerts on (banner and sound)", true,
      function() return not ns.Core.DB().muted end,
      function(v) ns.Core.SetMuted(not v) end)
  end,
})
if not ok or type(answer) ~= "table" then return end
M = answer
do
  local good, why = ns.Store.Register(M)
  if not good then storeFault = tostring(why) end
end
src.kit = M.Kit
src.safe = M.Safe   -- the page's handlers run through it (f4688)
src.compat = M.Compat -- the page's template and atlas reads (d761, d793)

M.On("demo", function() M.RefreshPage() end)

ns.Hub = {
  Refresh = function() M.RefreshPage() end,
  Escape = escape,
  Open = function() M.OpenPage() end,
  InDemo = function() return (M.Demo()) == true end,
  Ready = function() return (ns.Store.Ready()) end, -- the one readiness gate (d792)
  Now = function() return M.Compat.call("GetServerTime") end,
  Call = function(...) return M.Compat.call(...) end,
  After = function(seconds, fn) M.After(seconds, fn) end,
}
