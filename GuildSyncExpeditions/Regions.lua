-- GuildSyncExpeditions Regions.lua: ns.Regions, the six regions in map order (0.19 plan, Seams 4).
-- Pure: string, table and math only, no globals, no game calls, but for one read of ns.Opened at call time (a region
-- with need asks it, guarded when missing).
--   Regions.LIST -> { { id, name, open, need, lo, hi }, ... }   lo and hi (row levels) on open and gated regions
--   Regions.Open() -> a new ordered list of open ids      Regions.IsOpen(id) -> bool

local _, ns = ...
if not ns.M then return end

local Regions = {}
ns.Regions = Regions

Regions.LIST = {
  { id = "tirisfal", name = "Tirisfal Glades", open = true, lo = 1, hi = 7 },
  { id = "silverpine", name = "Silverpine Forest", open = true, lo = 6, hi = 9 },
  { id = "hillsbrad", name = "Hillsbrad Foothills", open = false, need = "hillsbrad", lo = 11, hi = 15 },
  { id = "arathi", name = "Arathi Highlands", open = false },
  { id = "westpl", name = "Western Plaguelands", open = false },
  { id = "eastpl", name = "Eastern Plaguelands", open = false },
}

-- Always a boolean, never nil.
local function isOpen(region)
  return region.open == true
    or (region.need ~= nil and type(ns.Opened) == "function" and ns.Opened(region.need) == true)
end

function Regions.Open()
  local out = {}
  for _, region in ipairs(Regions.LIST) do
    if isOpen(region) then out[#out + 1] = region.id end
  end
  return out
end

function Regions.IsOpen(id)
  for _, region in ipairs(Regions.LIST) do
    if region.id == id then return isOpen(region) end
  end
  return false
end
