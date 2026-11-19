-- GuildSyncExpeditions Talents.lua: a follower's learned talent build, the preview, learn and reset (issue 13 spec,
-- build step 2). The tree comes from the follower's class (FollowerData.KIND), never from the save.
--   ns.Talents(fid) -> { tree, learned, preview, left } | nil   copies; preview is the learned build while no preview
--                                                      is held; left = points earned at its level minus the preview's
--   ns.PreviewAdd(fid, i) -> true | nil, why           ns.PreviewTake(fid, i) -> true | nil, why
--     why: "unknown", or TalentCore's "rank" / "tier" / "arrow" / "points"; Take also "learned" for a learned rank
--   ns.PreviewCancel(fid)                              drops the preview
--   ns.Learn(fid) -> true | nil, why                   "demo", "unknown", "busy" (out on a run), "none" (no preview)
--   ns.ResetTalents(fid) -> true | nil, why            "demo", "unknown", "busy", "none", or ns.Grain's refusal:
--                                                      spends 10 grain per learned point, and only then clears
--   ns.TalentResetPrice(fid) -> n | nil                what a reset costs now (0 with nothing learned); nil unknown
--   ns.TalentBonus(fid, row) -> n                      the learned Power talents that row meets
--   ns.TalentMods(fid, row) -> { mod, ... }            one RiskCore mod table per learned odds or rest talent
--   ns.TalentPercent(fid, lever) -> n                  lever "xp" | "grain" | "salvage" | "raise", from the learned build
--   ns.TalentFind(fid, reward) -> n                    percent more often for a LootData reward, from the learned build
--   ns.ClearTalents(fid)                               drops the build and the preview (dismiss, permanent death)
-- Saved part talents: rows[fid] = { v = TalentData.V, ranks = { n, ... } }, one whole number per talent in tree order.
-- The preview is held in memory only and never saved.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local FC, D, TD, TC = ns.FollowerCore, ns.FollowerData, ns.TalentData, ns.TalentCore

local RESET_GRAIN = 10 -- per learned point

local previews = {} -- fid -> ranks, never saved

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function treeOf(f)
  return type(f) == "table" and TD.TREES[D.KIND[f.class]] or nil
end

-- A full list of the tree's length; a missing entry is 0.
local function listOf(tree, ranks)
  local out = {}
  for i = 1, #tree.talents do
    local r = type(ranks) == "table" and ranks[i]
    out[i] = whole(r, 0, tree.talents[i].max) and r or 0
  end
  return out
end

local function fresh() return { rows = {} } end

-- A row whose follower is gone is dropped. A build saved under another tree version, or one that breaks any rule at
-- the follower's level, is dropped too: refunded whole, never trimmed.
local function soundRow(id, row)
  if not whole(id, 1, FC.ID_MAX) then return nil end
  local f = ns.Follower(id)
  local tree = treeOf(f)
  if not tree or row.v ~= TD.V or type(row.ranks) ~= "table" then return nil end
  if TC.Problem(tree, row.ranks, f.level) then return nil end
  return { v = TD.V, ranks = listOf(tree, row.ranks) }
end

-- At use, never at file load: saved variables are not ready then.
local function part() return ns.Part("talents", fresh, soundRow) end

-- The reads open the part only once it is saved, so a chance shown never adds it to the saved table.
local function readPart()
  if not M.Demo() then
    local d = GuildSyncExpeditionsDB
    if type(d) ~= "table" or d.talents == nil then return nil end
  end
  return part()
end

local function learnedOf(fid)
  local p = readPart()
  local row = p and p.rows[fid]
  return row and row.ranks or nil
end

-- The follower and its tree, or nil.
local function held(fid)
  local f = ns.Follower(fid)
  local tree = treeOf(f)
  if not tree then return nil end
  return f, tree
end

function ns.Talents(fid)
  local f, tree = held(fid)
  if not f then return nil end
  local learned = listOf(tree, learnedOf(fid))
  local preview = listOf(tree, previews[fid] or learned)
  return { tree = tree, learned = learned, preview = preview, left = TC.Points(f.level) - TC.Spent(tree, preview) }
end

function ns.PreviewAdd(fid, i)
  local f, tree = held(fid)
  if not f then return nil, "unknown" end
  local base = listOf(tree, previews[fid] or learnedOf(fid))
  local good, why = TC.CanAdd(tree, base, i, f.level)
  if not good then return nil, why end
  base[i] = base[i] + 1
  previews[fid] = base
  return true
end

-- Only a preview rank comes back: a learned one needs a reset.
function ns.PreviewTake(fid, i)
  local f, tree = held(fid)
  if not f then return nil, "unknown" end
  local base = listOf(tree, previews[fid] or learnedOf(fid))
  if whole(i, 1, #base) and base[i] > 0 and base[i] <= listOf(tree, learnedOf(fid))[i] then return nil, "learned" end
  local good, why = TC.CanTake(tree, base, i)
  if not good then return nil, why end
  base[i] = base[i] - 1
  previews[fid] = base
  return true
end

function ns.PreviewCancel(fid)
  previews[fid] = nil
end

-- Every refusal comes before the one write.
function ns.Learn(fid)
  if ns.Inert() then return nil, "demo" end
  local f, tree = held(fid)
  if not f then return nil, "unknown" end
  if f.state == "out" then return nil, "busy" end
  local preview = previews[fid]
  if not preview or TC.Spent(tree, preview) <= TC.Spent(tree, learnedOf(fid)) then return nil, "none" end
  local why = TC.Problem(tree, preview, f.level)
  if why then return nil, why end
  part().rows[fid] = { v = TD.V, ranks = listOf(tree, preview) }
  previews[fid] = nil
  return true
end

function ns.TalentResetPrice(fid)
  local f, tree = held(fid)
  if not f then return nil end
  return RESET_GRAIN * TC.Spent(tree, learnedOf(fid))
end

-- The grain goes first; the build is cleared only once it is paid.
function ns.ResetTalents(fid)
  if ns.Inert() then return nil, "demo" end
  local f, tree = held(fid)
  if not f then return nil, "unknown" end
  if f.state == "out" then return nil, "busy" end
  local price = ns.TalentResetPrice(fid)
  if price == 0 then return nil, "none" end
  local paid, why = ns.Grain("spend", price)
  if not paid then return nil, why end
  part().rows[fid] = nil
  previews[fid] = nil
  return true
end

-- TalentBonus and TalentMods run for every chance shown, so they never store the part.
function ns.TalentBonus(fid, row)
  local f, tree = held(fid)
  if not f then return 0 end
  return TC.Power(tree, learnedOf(fid), row)
end

function ns.TalentMods(fid, row)
  local f, tree = held(fid)
  if not f then return {} end
  return TC.Mods(tree, learnedOf(fid), row)
end

function ns.TalentPercent(fid, lever)
  local f, tree = held(fid)
  if not f then return 0 end
  return TC.Percent(tree, learnedOf(fid), lever)
end

function ns.TalentFind(fid, reward)
  local f, tree = held(fid)
  if not f then return 0 end
  return TC.Find(tree, learnedOf(fid), reward)
end

function ns.ClearTalents(fid)
  previews[fid] = nil
  local p = readPart()
  if p and p.rows[fid] then p.rows[fid] = nil end
end
