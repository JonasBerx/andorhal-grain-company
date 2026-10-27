-- GuildKOS Hub: Kill on Sight registers as a GuildSync module (API 4 or later) and draws its page (Page.lua) inside the
-- GuildSync window. With an older hub or on a refusal nothing here runs: ns.Hub stays nil, Core's alerts and Sync's
-- wire keep running and /kos says the page needs API 4. Uses only the GuildSync global and the handle M; GuildKOS's
-- own sends stay in Sync.lua, which reads GuildSync.Comm itself for the officer rule.
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
local hubReady = false  -- the hub's roster is known and full (f4696): seeded at registration, then each rosterRead

local function escape(s) return hub.Escape(s) end

-- What the page draws: the hub demo's state while /gsync demo is on, else the real list.
local function pageData()
  if M then
    local on, state = M.Demo()
    if on and type(state) == "table" then return state.list, state.lastSeen end
  end
  return ns.Core.View()
end

local src = { escape = escape, data = pageData, openImport = function() ns.Core.OpenImport() end }

local ok, answer = pcall(hub.RegisterModule, {
  id = "kos",
  title = TITLE,
  version = "0.5.1",
  needs = 4,
  page = {
    title = TITLE,
    icon = SKULL,
    build = function(frame) ns.Page.Build(frame, src) end,
    refresh = function(frame) ns.Page.Refresh(frame, src) end,
  },
  -- /gsync demo: the made-up targets (Rules.DemoList), held by the hub for the session; never saved, never sent.
  demo = function(_, now)
    local got, faction = ns.Compat.call("UnitFactionGroup", "player")
    local list, lastSeen = ns.Rules.DemoList(now, got and ns.Compat.str(faction) or nil)
    return { list = list, lastSeen = lastSeen }
  end,
  selftest = function()
    if not loggedIn then return "wait", "not logged in yet" end
    local db = ns.Core.DB()
    local n = db.list and #db.list.targets or 0
    return "pass", ns.Page.Targets(n) .. ", alerts " .. (db.muted and "off" or "on")
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
src.kit = M.Kit
src.safe = M.Safe   -- the page's handlers run through it (f4688)

-- One read at registration (API.md GuildSync.Comm.Roster), then follow the hub's reads.
do
  local okR, _, partial, _, known = pcall(hub.Comm and hub.Comm.Roster)
  hubReady = okR and known == true and not partial
end
M.On("rosterRead", function(partial)
  hubReady = not partial
  if ns.Sync then ns.Sync.ReadyChanged() end
end)

M.On("demo", function(on)
  M.RefreshPage()
  if on == false and ns.Sync then ns.Sync.AfterDemo() end
end)

ns.Hub = {
  Refresh = function() M.RefreshPage() end,
  Open = function() M.OpenPage() end,
  InDemo = function() return (M.Demo()) == true end,
  Ready = function() return hubReady end,
}
