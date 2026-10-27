-- GuildSyncGames Facts.lua: the streak and wins facts (plan Task 9, AC11; API.md M.Fact, M.FactsChanged).
-- streak(key): the streak of key's record when it is for today or yesterday, else 0 (also 0 for a hidden key or a
-- streak over L2, ns.Limits.WoWdle). wins(key): the own key's wins,
-- nil for any other key. Both read memory only; in demo both answer from the demo state (M.Demo()), where the row
-- marked you is the own key. ns.FactsChanged is called by Store.lua after the own finish and by Sync.lua after a merge.

local _, ns = ...

if not ns.M then return end
local M, Core = ns.M, ns.Core

function ns.FactStreak(key)
  local s = ns.DemoOn()
  if s then
    for _, row in ipairs(s.guild) do
      if row.key == key then return row.streak end
    end
    return 0
  end
  local d = ns.Today()
  local r = ns.Records()[key]
  if not d or type(r) ~= "table" or (r.n ~= d.n and r.n ~= d.n - 1) then return 0 end
  if ns.IsHidden and ns.IsHidden(key) then return 0 end
  local res = Core.ParseBody(r.body, d.n)
  if not res or not ns.Limits.WoWdle(res, ns.Now()) then return 0 end
  return res.streak
end

function ns.FactWins(key)
  local s = ns.DemoOn()
  if s then
    for _, row in ipairs(s.guild) do
      if row.you and row.key == key then return s.stats.won end
    end
    return nil
  end
  if key == nil or key ~= ns.MyKey() then return nil end
  return ns.Stats().won
end

function ns.FactsChanged()
  if M.FactsChanged then M.FactsChanged() end
end
