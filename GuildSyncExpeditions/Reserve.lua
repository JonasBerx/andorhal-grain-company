-- GuildSyncExpeditions Reserve.lua: the reserve and the waiting recruit (0.19 plan, Seams 16; slice R).
--   ns.IsReserve(fid) -> bool                          always a boolean
--   ns.ToReserve(fid), ns.ToUse(fid) -> true | nil, "demo" | "unknown" | "busy" | "full"
--   ns.OfferRecruit(spec) -> "reserve" | "asked" | nil, why
--   ns.PendingRecruit() -> a copy of the spec | nil    a read, never speaks
--   ns.ReplaceWithRecruit(fid) -> true | nil, "demo" | "none" | "reserve" | "full" | "busy"
--   ns.TurnAwayRecruit() -> true | nil, "demo" | "none"
--   ns.TakeWaitingRecruit() -> true | nil              silent nil in demo
-- Reserve state is row.reserve on the live follower row. The "recruit" part holds only the waiting spec, at key 1.
-- ns.HideRecruitWindow (RecruitWindow.lua) is read at call time and skipped while it is missing.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local FC = ns.FollowerCore
local D = ns.FollowerData

local function fresh() return { rows = {} } end

-- A new table of the known fields only. A bad level or non-table traits drops the row.
local function soundRow(id, row)
  if id ~= 1 or type(row) ~= "table" or row.origin ~= "recruit" or type(row.traits) ~= "table" then return nil end
  if not FC.CheckSpec(row.name, row.race, row.class, row.sex) then return nil end
  local level = row.level
  if type(level) ~= "number" or level < 1 or level > D.MAX_LEVEL or level ~= math.floor(level) then return nil end
  return { name = row.name, race = row.race, class = row.class, sex = row.sex, level = level,
    traits = FC.NewRow(1, row).traits, origin = "recruit" }
end

-- At use, never at file load: saved variables are not ready then.
local function part() return ns.Part("recruit", fresh, soundRow) end

-- How many followers sit on that side; the dead count as in use.
local function count(reserve)
  local n = 0
  for _, x in ipairs(ns.Followers()) do
    if (x.reserve == true) == reserve then n = n + 1 end
  end
  return n
end

local function hasRoom()
  return count(true) < D.CAP_RESERVE and #ns.Followers() < D.CAP_ALL
end

local function hideWindow()
  if ns.HideRecruitWindow then ns.HideRecruitWindow() end
end

local function joined(name)
  ns.Say(name .. " joins the Company.")
  M.RefreshPage()
end

function ns.IsReserve(fid)
  local row = ns.Follower(fid)
  return row ~= nil and row.reserve == true
end

local function move(fid, reserve, cap)
  if ns.Inert() then return nil, "demo" end
  local row = ns.Follower(fid)
  if not row then return nil, "unknown" end
  if row.state ~= "idle" then return nil, "busy" end
  if (row.reserve == true) == reserve then return true end
  if count(reserve) >= D[cap] then return nil, "full" end
  row.reserve = reserve
  return true
end

function ns.ToReserve(fid) return move(fid, true, "CAP_RESERVE") end

function ns.ToUse(fid)
  local wasReserve = ns.IsReserve(fid)
  local done, why = move(fid, false, "CAP_USE")
  if done and wasReserve then ns.TakeWaitingRecruit() end
  return done, why
end

function ns.OfferRecruit(spec)
  if type(spec) ~= "table" then return nil, "spec" end
  if ns.Inert() then return nil, "demo" end
  local p = part()
  if p.rows[1] then return nil, "waiting" end
  local good, why = FC.CheckSpec(spec.name, spec.race, spec.class, spec.sex)
  if not good then return nil, why end
  local copy = { name = spec.name, race = spec.race, class = spec.class, sex = spec.sex, level = spec.level,
    traits = spec.traits, origin = "recruit" }
  if hasRoom() then
    local id, refused = ns.AddFollower(copy)
    if not id then return nil, refused end
    joined(spec.name)
    return "reserve"
  end
  local row = soundRow(1, copy)
  if not row then return nil, "spec" end
  p.rows[1] = row
  hideWindow() -- clears a stale `left`, so this recruit's window can open
  return "asked"
end

function ns.PendingRecruit()
  local row = part().rows[1]
  return row and soundRow(1, row) or nil
end

-- Dismiss and ToUse call this blind, so it checks for room itself.
function ns.TakeWaitingRecruit()
  if M.Demo() then return nil end
  local p = part()
  local row = p.rows[1]
  if not row or not hasRoom() or not ns.AddFollower(row) then return nil end
  p.rows[1] = nil
  hideWindow()
  joined(row.name)
  return true
end

function ns.ReplaceWithRecruit(fid)
  if ns.Inert() then return nil, "demo" end
  if not part().rows[1] then return nil, "none" end
  if not ns.IsReserve(fid) then return nil, "reserve" end
  -- A save over a cap: the freed slot could not take the recruit, so the follower stays.
  if count(true) - 1 >= D.CAP_RESERVE or #ns.Followers() - 1 >= D.CAP_ALL then return nil, "full" end
  local done, why = ns.Dismiss(fid)
  if done then return true end
  if why == "full" then ns.Say(ns.W.Name["Company bag"] .. " is full.") end
  return nil, why
end

function ns.TurnAwayRecruit()
  if ns.Inert() then return nil, "demo" end
  local p = part()
  local row = p.rows[1]
  if not row then return nil, "none" end
  p.rows[1] = nil
  ns.Say(row.name .. " moves on.")
  hideWindow()
  return true
end
