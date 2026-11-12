-- GuildSyncExpeditions Facts.lua: what People and Annals read (0.19 plan, Seams 12; slice I plan, "Facts").
--   ns.Fact.best(key)   -> "Grimbold, 9 Orc Warrior" | nil   highest level, then wins, then name; hidden followers skipped
--   ns.Fact.flair(key)  -> "<Title>, <n> trophies" | either part alone | nil
--   ns.Fact.quests(key) -> number | nil                      own with none: 0
--   ns.Fact.deadly(key) -> number | nil                      own with none: 0
--   ns.FlairOf(key)     -> the flair table | nil             in-module only (the hub's plainFact drops a table, C1)
-- key nil or the own key reads live; any other key reads ns.GuildRecord, which exists from Sync.lua on. A read never
-- writes, settles or moves grain (R-quiet).

local _, ns = ...
if not ns.M then return end

local QD = ns.QuestData

local function myKey() return GuildSync.Comm.MyKey() end
local function isOwn(key) return key == nil or key == myKey() end

local function recordOf(key)
  if not ns.GuildRecord then return nil end
  return (ns.GuildRecord(key))
end

local function stat(f, field) return f.stats and f.stats[field] or 0 end
local function winsOf(f) return f.wins or stat(f, "wins") end -- a record's line, or an own saved row

local function above(a, b)
  if a.level ~= b.level then return a.level > b.level end
  local wa, wb = winsOf(a), winsOf(b)
  if wa ~= wb then return wa > wb end
  return a.name < b.name
end

local function bestOf(list, owner)
  local top
  for _, f in ipairs(list) do
    local hidden = ns.IsFollowerHidden and ns.IsFollowerHidden(owner, f.name)
    if not hidden and (not top or above(f, top)) then top = f end
  end
  if not top then return nil end
  -- A record's race and class are only shape-checked: a word the data does not know is left out, the follower stays.
  local D, line = ns.FollowerData, string.format("%s, %d", top.name, top.level)
  if D.RACES[top.race] then line = line .. " " .. top.race end
  if D.KIND[top.class] then line = line .. " " .. top.class end
  return line
end

local function titleName(id)
  if not id then return nil end
  local writ = QD.BY_ID[id]
  if writ then return writ.flairName end
  for _, s in ipairs(QD.STORY_TITLES) do
    if s.id == id then return s.name end
  end
  return nil
end

local function flairLine(fl)
  local title = titleName(fl.title)
  local n = #fl.trophies
  local count = n == 1 and "1 trophy" or n > 1 and (n .. " trophies") or nil
  if title and count then return title .. ", " .. count end
  return title or count
end

function ns.FlairOf(key)
  if isOwn(key) then return ns.Flair() end
  local view = recordOf(key)
  return view and view.flair or nil
end

ns.Fact = {
  best = function(key)
    if isOwn(key) then return bestOf(ns.Followers(), myKey()) end
    local view = recordOf(key)
    return view and bestOf(view.followers, key) or nil
  end,
  flair = function(key)
    local fl = ns.FlairOf(key)
    return fl and flairLine(fl) or nil
  end,
  quests = function(key)
    local fl = ns.FlairOf(key)
    return fl and fl.quests or nil
  end,
  deadly = function(key)
    if isOwn(key) then
      local sum = 0
      for _, f in ipairs(ns.Followers()) do sum = sum + stat(f, "deadly") end
      return sum
    end
    local view = recordOf(key)
    return view and view.deadly or nil
  end,
}
