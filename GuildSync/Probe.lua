-- GuildSync Probe: records what this client really offers. Runs once per build a few seconds after login,
-- and on /gsync probe.

local ADDON, ns = ...
local Compat = ns.Compat

local Probe = {}
ns.Probe = Probe

function Probe.Run()
  local db = ns.DB()
  local version, build, _, interface = Compat.BuildInfo()
  if version and build then db.build = version .. "." .. build end
  if interface then db.interface = interface end

  local events = {}
  for event in pairs(ns.missingEvents) do events[event] = false end

  db.probe = {
    checked = time(),
    build = db.build,
    apis = Compat.ApiPresence(),
    flags = Compat.Flags(),
    restrictions = Compat.RestrictionStates(),
    missingEvents = events,
  }
  return db.probe
end

local function yesNo(v)
  if v == nil then return "unknown" end
  return v and "yes" or "no"
end

function Probe.Print()
  local db = ns.DB()
  local p = db.probe
  local W = ns.Window
  ns.Say(ns.View.SettingsPathLine(W and W.SettingsPath and W.SettingsPath() or "window")) -- also before the probe ran
  if type(p) ~= "table" then ns.Say("probe has not run yet.") return end
  local present, missing, missingNames = 0, 0, {}
  for _, name in ipairs(Compat.APIS) do
    if p.apis and p.apis[name] then
      present = present + 1
    else
      missing = missing + 1
      table.insert(missingNames, name)
    end
  end
  ns.Say("build " .. tostring(db.build or "?") .. ", interface " .. tostring(db.interface or "?") .. ".")
  local f = p.flags or {}
  ns.Say("guild bank: " .. yesNo(f.guildBank) .. ", guild trade skills: " .. yesNo(f.guildTradeSkills)
    .. ", damage meter: " .. yesNo(f.damageMeter) .. ", hardcore: " .. yesNo(f.hardcore) .. ".")
  ns.Say(present .. " of " .. (present + missing) .. " client functions present."
    .. (missing > 0 and (" Missing: " .. table.concat(missingNames, ", ") .. ".") or ""))
  local missingEvents = {}
  for event in pairs(p.missingEvents or {}) do table.insert(missingEvents, event) end
  if #missingEvents > 0 then
    table.sort(missingEvents)
    ns.Say("events this client does not know: " .. table.concat(missingEvents, ", ") .. ".")
  end
end

ns.RegisterModule({
  name = "Probe",
  events = { "PLAYER_LOGIN" },
  onEvent = function()
    ns.After(3, function()
      local db = ns.DB()
      local version, build = Compat.BuildInfo()
      local current = (version and build) and (version .. "." .. build) or nil
      if type(db.probe) ~= "table" or db.probe.build ~= current then
        Probe.Run()
        ns.Say("recorded what this client offers (build " .. tostring(current or "?") .. "). /gsync probe to see it.")
      end
    end, "Probe")
  end,
  status = function()
    local p = ns.DB().probe
    if type(p) ~= "table" then return "not run yet" end
    return "build " .. tostring(p.build or "?") .. ", interface " .. tostring(ns.DB().interface or "?")
      .. ", checked " .. date("%Y-%m-%d %H:%M", p.checked or 0)
  end,
  scan = function() Probe.Run() end,
})
