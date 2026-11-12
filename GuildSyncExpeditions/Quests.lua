-- GuildSyncExpeditions Quests.lua: the saved quests and flair parts, granting and finishing writs (slice H plan, Seams 2).
--   ns.GrantQuest(seed) -> id | nil, "demo" | "full" | "none"
--   ns.GrantTitle(id) -> true | nil, "demo" | "unknown"         story titles only, once
--   ns.LookTint(id) -> r, g, b | nil
--   ns.Flair() -> { title, badges, trophies, looks = { [fid] = id }, quests = n }
--   ns.EarnedTitles() -> { id, ... }                            worn first, then writs in data order, then story titles
--   ns.OpenWrits() -> at most 3 { id, progress, need }          in data order
--   ns.AddWritProgress(id, n) -> new progress | nil, "demo" | "unknown"
--   ns.FinishWrit(id) -> true | nil, "demo" | "unknown"
-- Saved: quests = { rows = { [id] = { id = id, progress = n } } }; flair = { title = id | nil, rows = { [id] = { id = id } } }

local _, ns = ...
if not ns.M then return end

local M = ns.M
local D = ns.QuestData

local SLOTS = 3
local BAND = 1 -- every writ in 0.19; scaling writs to follower tiers changes this one fit

local function fresh() return { rows = {} } end

local function isStory(id)
  for _, s in ipairs(D.STORY_TITLES) do
    if s.id == id then return true end
  end
  return false
end

local function wearable(id)
  local w = D.BY_ID[id]
  if w then return w.title ~= nil end
  return isStory(id)
end

local function soundFlair(id)
  if D.BY_ID[id] or isStory(id) then return { id = id } end
  return nil
end

-- At use, never at file load. The title check is here because Store checks nothing when fresh() has no title.
local function flairPart()
  local p = ns.Part("flair", fresh, soundFlair)
  if p.title ~= nil and not (p.rows[p.title] and wearable(p.title)) then p.title = nil end
  return p
end

local function clamp(progress, w)
  return math.max(0, math.min(math.floor(progress), w.need))
end

-- A row that is also done is what a client gone between the two writes of a finish leaves behind: it goes here.
local function soundQuest(id, row)
  local w = D.BY_ID[id]
  if not w or type(row.progress) ~= "number" or flairPart().rows[id] then return nil end
  return { id = id, progress = clamp(row.progress, w) }
end

local function questPart() return ns.Part("quests", fresh, soundQuest) end

local function whole(v)
  return type(v) == "number" and v == math.floor(v) and v ~= math.huge and v ~= -math.huge
end

function ns.OpenWrits()
  local rows = questPart().rows
  local out = {}
  for _, w in ipairs(D.WRITS) do
    local row = rows[w.id]
    if row then out[#out + 1] = { id = w.id, progress = row.progress, need = w.need } end
    if #out == SLOTS then break end
  end
  return out
end

function ns.GrantQuest(seed)
  if ns.Inert() then return nil, "demo" end
  if not whole(seed) then return nil, "none" end
  if seed < 0 or seed >= 2^31 then return nil, "none" end
  if #ns.OpenWrits() >= SLOTS then return nil, "full" end
  local q, f = questPart(), flairPart()
  local pool = {}
  for _, w in ipairs(D.WRITS) do
    if w.band == BAND and not q.rows[w.id] and not f.rows[w.id] then pool[#pool + 1] = w.id end
  end
  if #pool == 0 then return nil, "none" end
  local id = pool[seed % #pool + 1]
  q.rows[id] = { id = id, progress = 0 }
  return id
end

function ns.GrantTitle(id)
  if ns.Inert() then return nil, "demo" end
  if not isStory(id) then return nil, "unknown" end
  local f = flairPart()
  if not f.rows[id] then
    f.rows[id] = { id = id }
    f.title = id
  end
  return true
end

function ns.LookTint(id)
  local w = D.BY_ID[id]
  if not w then return nil end
  return w.tint.r, w.tint.g, w.tint.b
end

function ns.Flair()
  local f = flairPart()
  local out = { title = f.title, badges = {}, trophies = {}, looks = {}, quests = 0 }
  for _, w in ipairs(D.WRITS) do
    if f.rows[w.id] then
      out.quests = out.quests + 1
      out.trophies[#out.trophies + 1] = w.trophy
      if w.badge then out.badges[#out.badges + 1] = w.badge end
    end
  end
  for _, row in ipairs(ns.Followers()) do
    if D.BY_ID[row.look] then out.looks[row.id] = row.look end
  end
  return out
end

function ns.EarnedTitles()
  local f = flairPart()
  local out = {}
  if f.title then out[1] = f.title end
  local function add(id)
    if f.rows[id] and id ~= f.title then out[#out + 1] = id end
  end
  for _, w in ipairs(D.WRITS) do
    if w.title then add(w.title) end
  end
  for _, s in ipairs(D.STORY_TITLES) do add(s.id) end
  return out
end

local function inReserve(row)
  if ns.IsReserve then return ns.IsReserve(row.id) end
  return row.reserve == true
end

local function better(row, best)
  if not best then return true end
  if (row.look == nil) ~= (best.look == nil) then return row.look == nil end
  return row.stats.runs > best.stats.runs
end

local function setLook(w)
  local best
  for _, row in ipairs(ns.Followers()) do -- ordered by id, so a tie stays with the lowest
    if row.state ~= "dead" and not inReserve(row) and better(row, best) then best = row end
  end
  if best then ns.Follower(best.id).look = w.look end
end

local function refreshPage()
  local tab = ns.QuestTab
  if tab and tab.frame and tab.frame:IsVisible() then tab.Refresh(tab.frame) end
end

function ns.FinishWrit(id)
  if ns.Inert() then return nil, "demo" end
  local q, f = questPart(), flairPart()
  local w = D.BY_ID[id]
  if not w or not q.rows[id] then return nil, "unknown" end
  if f.rows[id] then
    q.rows[id] = nil
    return nil, "unknown"
  end
  f.rows[id] = { id = id }
  if w.title then f.title = w.title end
  q.rows[id] = nil
  M.Safe(setLook, w)
  if ns.HistoryWrit then M.Safe(ns.HistoryWrit, w) end
  ns.Say("Writ complete: " .. w.name .. ".")
  M.Safe(refreshPage)
  return true
end

function ns.AddWritProgress(id, n)
  if ns.Inert() then return nil, "demo" end
  local w, row = D.BY_ID[id], questPart().rows[id]
  if not w or not row or not whole(n) then return nil, "unknown" end
  local progress = clamp(row.progress + n, w)
  row.progress = progress
  if progress >= w.need then ns.FinishWrit(id) end
  return progress
end
