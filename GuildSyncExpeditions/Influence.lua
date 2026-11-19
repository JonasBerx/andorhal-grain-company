-- GuildSyncExpeditions Influence.lua: the latched influence ladder (issue 6). Games' fact granarybuilt (the furthest
-- granary project this client sees built, 0-6) opens the steps of ns.InfluenceCore; this file keeps the highest value
-- it has seen, so a hidden donor or a dropped row never closes a step again.
--   ns.Influence() -> 0..6                  reads the fact, raises the latch, says each newly reached step's line once
--   ns.Unlocked(key) -> bool                the stored latch >= the step's need; false for an unknown key
--   ns.Opened(key) -> bool                  ns.Unlocked(key) and the step is live: what the camp, the shop and the
--                                           writs open on, so a step reached before its content shipped stays shut
--   ns.Fact.nextopen() -> text | nil         the step after the latch, for Games' Company tab; nil once all are open
-- Saved (account-wide, as followers and maps): influence = { built = 0..6, said = { [sayKey] = true } }. said marks the
-- lines that were said, so a step reached before its content shipped is said once it goes live.
-- Demo: the fact as it is (6 when Games gives none), nothing saved, nothing said. Without Games the latch holds.
-- Raised on the hub's "facts" event for games (once after login, and on Games' M.FactsChanged, which CompanySync calls
-- when the furthest built project moves) and on Camp.Refresh. A raise calls M.FactsChanged, so Games redraws its
-- "Next in Expeditions" line. ns.Unlocked, ns.Opened and the nextopen fact read the stored latch only: they run per
-- drawn row, and a Games read folds every guild record. In demo they read Games' demo fact instead.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local IC = ns.InfluenceCore

local function fresh() return { built = 0, said = {} } end

local function part()
  local p = ns.Part("influence", fresh)
  if not IC.Valid(p.built) then p.built = 0 end
  if type(p.said) ~= "table" then p.said = {} end
  return p
end

local function games()
  if type(M.Fact) ~= "function" then return nil end
  return IC.Valid(M.Fact("games", "granarybuilt"))
end

function ns.Influence()
  if M.Demo() then return games() or IC.MAX end
  local p = part()
  local seen = games()
  local raised = seen ~= nil and seen > p.built
  if raised then p.built = seen end
  for _, s in ipairs(IC.Newly(0, p.built)) do
    local mark = s.sayKey or s.key
    if not p.said[mark] then
      p.said[mark] = true
      ns.Say(s.say)
    end
  end
  if raised and type(M.FactsChanged) == "function" then M.FactsChanged() end
  return p.built
end

-- The stored latch, or in demo Games' demo fact (6 without one). Never a live Games read outside demo.
local function latch()
  if M.Demo() then return games() or IC.MAX end
  return part().built
end

function ns.Unlocked(key)
  local need = IC.Need(key)
  if not need then return false end
  return latch() >= need
end

function ns.Opened(key)
  return IC.Live(key) and ns.Unlocked(key)
end

-- Games reads this fact while it draws: outside demo it reads the stored latch only, never M.Fact. In demo it reads
-- Games' demo fact, which never reads Expeditions, so that cannot loop.
local function nextOpen()
  local s = IC.Step(latch() + 1)
  return s and s.text or nil
end

if type(ns.Fact) == "table" then ns.Fact.nextopen = nextOpen end

M.On("facts", function(id)
  if id == "games" then M.Safe(ns.Influence) end
end)
