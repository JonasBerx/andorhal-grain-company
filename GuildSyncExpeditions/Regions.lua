-- GuildSyncExpeditions Regions.lua: ns.Regions, the six regions in map order (0.19 plan, Seams 4).
-- Pure: string, table and math only, no globals, no game calls.
--   Regions.LIST -> { { id, name, open, lo, hi }, ... }   lo and hi (row levels) on open regions only
--   Regions.Open() -> a new ordered list of open ids      Regions.IsOpen(id) -> bool

local _, ns = ...
if not ns.M then return end

local Regions = {}
ns.Regions = Regions

Regions.LIST = {
  { id = "tirisfal", name = "Tirisfal Glades", open = true, lo = 1, hi = 7 },
  { id = "silverpine", name = "Silverpine Forest", open = true, lo = 6, hi = 9 },
  { id = "hillsbrad", name = "Hillsbrad Foothills", open = false },
  { id = "arathi", name = "Arathi Highlands", open = false },
  { id = "westpl", name = "Western Plaguelands", open = false },
  { id = "eastpl", name = "Eastern Plaguelands", open = false },
}

function Regions.Open()
  local out = {}
  for _, region in ipairs(Regions.LIST) do
    if region.open then out[#out + 1] = region.id end
  end
  return out
end

function Regions.IsOpen(id)
  for _, region in ipairs(Regions.LIST) do
    if region.id == id then return region.open end
  end
  return false
end
