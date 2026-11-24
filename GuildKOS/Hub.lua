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
  "GetNormalizedRealmName", "C_Sound.PlaySound", "InCombatLockdown", "IsInInstance",
  optional = { "PlaySound", "C_Secrets.ShouldUnitIdentityBeSecret", "GetGuildInfo",
    "C_XMLUtil.GetTemplateInfo", "C_Texture.GetAtlasInfo", "UnitSex" } }
-- What each optional client function turns off when it is missing (status).
local OFF = {
  PlaySound = "the old sound fallback",
  ["C_Secrets.ShouldUnitIdentityBeSecret"] = "the secret-identity check",
  GetGuildInfo = "the guild name fallback",
  ["C_XMLUtil.GetTemplateInfo"] = "the page's template checks (plain frames and buttons)",
  ["C_Texture.GetAtlasInfo"] = "the painting crop",
  UnitSex = "the targets' sex on the cards",
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
  version = "0.7.0",
  -- API 9 brings the purse (M.Credit) and M.Toast for the kill grain (issue 8); an API 4-8 hub keeps 0.6's page and
  -- gives no grain (ns.Hub.Credit answers "no purse"). API 10 brings M.Kit.Button for the mark form (issue 44 s3); an
  -- API 9 hub keeps the page's own buttons
  needs = (hub.API >= 10 and 10) or (hub.API >= 9 and 9) or 4,
  apis = APIS,
  -- PLAYER_REGEN_DISABLED and _ENABLED re-check Mark my target on the page (issue 44 s3)
  events = { "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED",
    "ZONE_CHANGED_NEW_AREA", "PARTY_KILL", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" },
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
  onLogin = function()
    loggedIn = true
    ns.Mark.Login(ns.Core.Now()) -- issue 44 s6: marks from before this login never ping
  end,
  -- Esc > Options > AddOns > GuildSync > Kill on Sight. The hub makes the set inert under /gsync demo.
  settings = function(S)
    S.Checkbox("alerts", "Alerts on (banner and sound)", true,
      function() return not ns.Core.DB().muted end,
      function(v) ns.Core.SetMuted(not v) end)
    -- The kill grain (issue 8, d23-d25): officers set these for the whole guild; everyone sees the guild's numbers.
    local K = ns.RulesKills
    local LABEL = {
      reward = function(n) return n == 0 and "Off" or (n .. " grain") end,
      weekCap = function(n) return n == 0 and "Off" or (n .. " a week") end,
      perTarget = function(n) return n .. " a week" end,
    }
    -- the choices, plus the guild's current number when an officer set one the list does not offer
    local function values(name)
      return function()
        local cur, list, has = ns.Kill.Settings()[name], {}, false
        for _, n in ipairs(K.CHOICES[name]) do
          if n == cur then has = true end
          list[#list + 1] = { n, LABEL[name](n) }
        end
        if not has and type(cur) == "number" then
          list[#list + 1] = { cur, LABEL[name](cur) }
          table.sort(list, function(a, b) return a[1] < b[1] end)
        end
        return list
      end
    end
    local TIP = "Officers set this for the whole guild; for everyone else it only shows the guild's number."
    local DEFAULT = { reward = K.REWARD, weekCap = K.WEEK_CAP, perTarget = K.PER_TARGET }
    for _, row in ipairs({ { "killgrain", "reward", "Kill grain: grain a kill" },
        { "killweek", "weekCap", "Kill grain: paid kills a week per account" },
        { "killtarget", "perTarget", "Kill grain: paid kills of one target a week" } }) do
      local key, name, text = row[1], row[2], row[3]
      S.Dropdown(key, text, DEFAULT[name], values(name),
        function() return ns.Kill.Settings()[name] end,
        function(v) ns.Kill.SetSetting(name, v) end, TIP)
    end
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
  -- fn(...) through M.Safe (a throw is recorded under the module), else pcall, as the page's handlers (issue 44 s9)
  Safe = function(fn, ...)
    if type(M.Safe) == "function" then return M.Safe(fn, ...) end
    return pcall(fn, ...)
  end,
  After = function(seconds, fn) M.After(seconds, fn) end,
  -- API 9 and 7 (the kill grain, issue 8); missing on an older handle, these answer as if there were no purse
  Credit = function(n)
    if type(M.Credit) ~= "function" then return nil, "no purse" end
    return M.Credit(n)
  end,
  Toast = function(spec) if type(M.Toast) == "function" then return M.Toast(spec) end end,
  MyCharacters = function()
    if type(M.MyCharacters) ~= "function" then return {} end
    return (M.MyCharacters())
  end,
  MyKey = function() return hub.Comm.MyKey() end,
  Confirm = function(which, text, okText, onOk) return M.Kit.Confirm(which, text, okText, onOk) end,
  Person = function(key)
    if type(hub.Comm.Person) ~= "function" then return nil end
    return hub.Comm.Person(key)
  end,
}
