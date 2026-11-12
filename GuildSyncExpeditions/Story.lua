-- GuildSyncExpeditions Story.lua: the storyline's progress, its one personal row and Anya's portrait (slice S, Seams 15).
--   ns.PersonalRows(day) -> { { id, region, kind, hours, level, danger, story } } | {}   at most the open step
--   ns.StoryRun(fid, run, outcome)                     Rewards calls it on a win; advances and pays a chapter end once
--   ns.StoryStep() -> { chapter, step, title, text, place } | nil                       nil once the story is finished
--   ns.StoryHeld() -> boolean                          true while the open step waits for the next server day
--   ns.CampStage() -> 1 | 2 | 3                        ns.ChaptersDone() -> { 1, 2, ... }
--   ns.ShowAnya(frame)                                 fills frame with the portrait; hides it if the art fails to set
-- Saved: story = { chapter = 1..7, step = 1..4, sentDay = 0..1e7 }; chapter 7 is finished. The advance is the guard
-- against a second payment, so it is written before anything is paid.
-- ns.Grain, AddGear, AddStack, GrantTitle, GrantChainEpic, Say, Now, StoryRunOut and ns.W are read at call time.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local D = ns.StoryData
local BC = ns.BoardCore

local DAY = 86400
local DAY_MAX = 1e7
local FINISHED = #D + 1
local STEPS = 4
local CAMP_2, CAMP_3 = 2, 4 -- chapters done
local SALVAGE_NAME = { [1] = "Rusted salvage", [2] = "Iron salvage" }
local ANYA = "Interface\\AddOns\\GuildSyncExpeditions\\Art\\anya"

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function fresh() return { chapter = 1, step = 1, sentDay = 0 } end

-- Every read repairs a bad field alone: ns.Part checks a part only once a session.
local function story()
  local p = ns.Part("story", fresh)
  if not whole(p.chapter, 1, FINISHED) then p.chapter = 1 end
  if not whole(p.step, 1, STEPS) then p.step = 1 end
  if not whole(p.sentDay, 0, DAY_MAX) then p.sentDay = 0 end
  return p
end

local function storyId(p) return p.chapter .. "." .. p.step end

-- The server day a run started, nil when it can't be known. R is rounded as BC.Day rounds it, so both terms see one R.
local function dayOf(start)
  local now = ns.Now()
  if not now or not whole(start, 0, now) then return nil end
  local untilReset = M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset")
  local today = BC.Day(now, untilReset)
  if not today then return nil end
  local R = math.floor((now + untilReset) / 60 + 0.5) * 60
  local day = today - math.floor((R - start - 1) / DAY)
  if whole(day, 0, DAY_MAX) then return day end
  return nil
end

-- M.Safe keeps only the first answer, so both are stored inside (as Rewards.lua).
local function safely(fn, ...)
  if not fn then return nil end
  local a, b
  M.Safe(function(...) a, b = fn(...) end, ...)
  return a, b
end

-- name is what the full-bag line says is lost: the salvage itself unless a piece was turned into it.
local function paySalvage(salvage, name)
  local added, why = safely(ns.AddStack, "salvage", salvage.tier, salvage.n)
  if not added and why == "full" then
    safely(ns.Say, ns.W.Name["Company bag"] .. " is full: " .. (name or ns.W.Name[SALVAGE_NAME[salvage.tier]]) .. " is lost.")
  end
end

-- A step's pieces land silently; with no cell free each turns to salvage, as a drop does, and nothing waits for later.
local function payGear(row)
  for _, code in ipairs(row.gear or {}) do
    local _, why = safely(ns.AddGear, { row = code })
    if why == "full" then
      local piece = ns.GearData.Row(code)
      paySalvage({ tier = piece.tier, n = ns.GearCore.SalvageOf(piece.q) }, piece.name)
    end
  end
end

local function sayHeld(region)
  for _, row in ipairs(ns.GearData.ROWS) do
    if row.named == region then
      ns.Say(row.name .. " is held until there is room in " .. ns.W.Name["Company bag"] .. ".")
      return
    end
  end
end

local function payChapter(ch)
  local reward = ch.reward
  safely(ns.Say, 'Anya: "' .. ch.ending .. '"')
  if reward.grain then safely(ns.Grain, "credit", reward.grain) end
  if reward.salvage then paySalvage(reward.salvage) end
  if reward.title then safely(ns.GrantTitle, reward.title) end
  if reward.chain and safely(ns.GrantChainEpic, reward.chain) == "held" then safely(sayHeld, reward.chain) end
end

function ns.ChaptersDone()
  local out = {}
  for c = 1, story().chapter - 1 do out[c] = c end
  return out
end

function ns.CampStage()
  local done = #ns.ChaptersDone()
  if done >= CAMP_3 then return 3 end
  if done >= CAMP_2 then return 2 end
  return 1
end

function ns.StoryStep()
  local p = story()
  local ch = D[p.chapter]
  if not ch then return nil end
  local row = ch.steps[p.step]
  return { chapter = ch.name, step = p.step, title = row.title, text = row.text, place = row.place }
end

function ns.PersonalRows(day)
  local p = story()
  local ch = D[p.chapter]
  if not ch or type(day) ~= "number" or not (day > p.sentDay) then return {} end
  local row = ch.steps[p.step]
  local id = storyId(p)
  if row.capstone then return {} end
  return { { id = "story-" .. id, region = ch.region, kind = row.kind, hours = row.hours, level = row.level,
    danger = row.danger, story = id, taken = ns.StoryRunOut(id) or nil } }
end

-- The clock ns.TodayRows hands PersonalRows, so this is true exactly when the open step's row is kept off the board.
function ns.StoryHeld()
  local p = story()
  local ch = D[p.chapter]
  if not ch or ch.steps[p.step].capstone then return false end
  local today = BC.Day(ns.Now(), M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset"))
  if not today or today > p.sentDay then return false end
  return not ns.StoryRunOut(storyId(p))
end

-- A step row counts even when its day can't be read (the next step is simply not held); a capstone does not.
function ns.StoryRun(_, run)
  if M.Demo() or type(run) ~= "table" then return end
  local p = story()
  local ch = D[p.chapter]
  if not ch then return end
  local row = ch.steps[p.step]
  local day
  if row.capstone then
    if run.capstone ~= true or run.story ~= nil or run.region ~= ch.region then return end
    day = dayOf(run.start)
    if not day or day <= p.sentDay then return end
  else
    if run.story ~= storyId(p) then return end
    day = dayOf(run.start)
  end
  if day then p.sentDay = day end
  if p.step < STEPS then
    p.step = p.step + 1
    payGear(row)
    return
  end
  p.chapter, p.step = p.chapter + 1, 1
  payChapter(ch)
end

local function tipOn(frame)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(frame, "ANCHOR_RIGHT")
  tip:SetText("Anya", 1, 0.82, 0)
  tip:AddLine("Dark Ranger of the Company", 1, 1, 1)
  tip:Show()
end

local function tipOff()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

function ns.ShowAnya(frame)
  local tex = frame.anyaTexture
  if not tex then
    tex = frame:CreateTexture(nil, "ARTWORK")
    frame.anyaTexture = tex
    if frame.CreateMaskTexture and tex.AddMaskTexture then
      pcall(function()
        local mask = frame:CreateMaskTexture()
        mask:SetAllPoints(tex)
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        tex:AddMaskTexture(mask)
      end)
    end
    local ring = frame:CreateTexture(nil, "OVERLAY")
    ring:SetPoint("TOPLEFT", frame, "TOPLEFT", -5, 5)
    ring:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 5, -5)
    M.Kit.Atlas(ring, "Adventures-Ring-Gold", nil)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", tipOn)
    frame:SetScript("OnLeave", tipOff)
  end
  tex:SetAllPoints(frame)
  if tex:SetTexture(ANYA) == false then frame:Hide() end
end
