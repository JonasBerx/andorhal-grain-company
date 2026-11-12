-- GuildSyncExpeditions Maps.lua: the region maps the Company holds (0.19 plan, Seams 5, 6).
--   ns.GrantMap(region, tier) -> true | nil, "demo" | "locked" | "full"
--   ns.OpenRegions() -> a new list                     ns.HeldMaps() -> a new sorted list
-- A first copy opens two more board rows a day; a second copy turns into salvage.

local _, ns = ...
if not ns.M then return end

local DUPLICATE_SALVAGE = 6

local function soundMap(region)
  if ns.Regions.IsOpen(region) then return {} end
  return nil
end

local function fresh() return { rows = {} } end

-- At use, never at file load: saved variables are not ready then.
local function maps() return ns.Part("maps", fresh, soundMap) end

-- The asked tier when it is one, else the tier of the levels the region starts at.
local function tierOf(region, tier)
  if tier == 1 or tier == 2 then return tier end
  for _, r in ipairs(ns.Regions.LIST) do
    if r.id == region then return r.lo <= 5 and 1 or 2 end
  end
  return nil
end

function ns.GrantMap(region, tier)
  if ns.Inert() then return nil, "demo" end
  if not ns.Regions.IsOpen(region) then return nil, "locked" end
  local rows = maps().rows
  if not rows[region] then
    rows[region] = {}
    return true
  end
  local t = tierOf(region, tier)
  local added, why = ns.AddStack("salvage", t, DUPLICATE_SALVAGE)
  if why == "full" then
    local salvage = ns.W.Name[t == 1 and "Rusted salvage" or "Iron salvage"]
    ns.Say(ns.W.Name["Company bag"] .. " is full: " .. DUPLICATE_SALVAGE .. " " .. salvage .. " are lost.")
  end
  return added, why
end

function ns.OpenRegions()
  return ns.Regions.Open()
end

function ns.HeldMaps()
  local out = {}
  for region in pairs(maps().rows) do out[#out + 1] = region end
  table.sort(out)
  return out
end
