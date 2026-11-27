local _, ns = ...
if not ns.M then return end

-- The job card (ticket 61, N2). Exports ns.PinBoss, ns.NotesCallArrived, ns.JobCardDataChanged, ns.SetCardOption,
-- ns.OnFightEvent and ns.JobCardFrame. A plain movable frame on the screen parent that shows one boss and your
-- jobs on it with their hints: opened by Pin (the Notes tab) or by a boss call that names a job you hold in the
-- record's holders for the raid's team. Every change the module makes goes through one combat gate (apply): in a
-- fight it is held (the last one wins) and runs at PLAYER_REGEN_ENABLED. The player's own Close click and drag act at
-- once, outside the gate: the card is not a protected frame. The place is saved in GuildSyncRaidsDB.notes.card (x, y),
-- with the two settings onCall and hideInFight (unset reads on). Every text from another player is escaped at draw.
-- This file sends nothing.

local M, NR = ns.M, ns.NotesRules
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only (made on the first read)
local call = M.Compat.call
local WIDTH, PAD = 260, 10
local NO_JOB = "You hold no job on this boss."
local AFTER = "after the fight"

local f -- the card
local current -- { ev, boss } while the card is open (or hidden by the fight)
local pending -- the change held back in a fight
local hiddenByFight, placed = false, false

-- The one combat gate: only a plain false counts as out of combat (a compat call can answer no value at all).
local function fighting()
  local v = call("InCombatLockdown")
  return v ~= false
end

local function apply(change)
  if fighting() then
    pending = change
    return false
  end
  change()
  return true
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function card() return ns.NotesDB().card end

-- The boss on the event's notes raid, and your jobs on it (the record's holders for ev.team), or nil.
local function jobsOn(ev, bossId)
  if type(ev) ~= "table" then return nil end
  local raid = ns.NotesFor(ev)
  if type(raid) ~= "table" then return nil end
  local id, boss = tostring(bossId), nil
  for _, b in ipairs(type(raid.bosses) == "table" and raid.bosses or {}) do
    if b.id == id then boss = b end
  end
  if not boss then return nil end
  local mine = {}
  for _, m in ipairs(NR.YourJobs(raid, ev.team, ns.NotesMyKeys(), ns.Key)) do
    if m.boss and m.boss.id == id then mine[#mine + 1] = m.job end
  end
  return boss, mine
end

local function esc(s) return ns.Escape(tostring(s or "")) end

-- Draws current into the card; false when the boss is no longer held.
local function draw()
  local boss, mine = jobsOn(current.ev, current.boss)
  if not boss then return false end
  f.title:SetText(esc(boss.name))
  local out = {}
  for _, job in ipairs(mine) do
    local line = esc(job.name)
    if type(job.hint) == "string" and job.hint ~= "" then line = line .. ": " .. esc(job.hint) end
    out[#out + 1] = line
  end
  f.lines:SetText(#out > 0 and table.concat(out, "\n") or NO_JOB)
  local h = tonumber(f.lines:GetStringHeight()) or 0
  f:SetHeight(PAD * 4 + 30 + h)
  return true
end

-- The saved place, read on the first show (the SavedVariable is set only after the files ran); finite numbers only.
local function place()
  local c = card()
  local x, y = c.x, c.y
  f:ClearAllPoints()
  if finite(x) and finite(y) then
    f:SetPoint("TOPLEFT", nil, "BOTTOMLEFT", x, y)
  else
    f:SetPoint("CENTER", 0, 120)
  end
  placed = true
end

local function hide()
  current, hiddenByFight = nil, false
  f:Hide()
end

local function refresh()
  if not current then return end
  if not draw() then hide() end
end

local function open(ev, bossId)
  return function()
    current, hiddenByFight = { ev = ev, boss = bossId }, false
    if not draw() then return hide() end
    if not placed then place() end
    f:Show()
  end
end

local function build()
  f = CreateFrame("Frame", nil, UIParent)
  f:Hide()
  f:SetSize(WIDTH, 80)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  -- The player's own drag and Close: at once, also in combat (outside apply).
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x, y = self:GetLeft(), self:GetTop()
    if finite(x) and finite(y) then
      local c = card()
      c.x, c.y = x, y
    end
  end)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], C.panel[4])
  f.close = K.Button(f, "Close", 70)
  f.close:SetPoint("TOPRIGHT", -PAD, -PAD)
  f.close:SetScript("OnClick", function()
    pending = nil
    hide()
  end)
  f.title = ns.Label(f, T.normal)
  f.title:SetPoint("TOPLEFT", PAD, -PAD - 4)
  f.title:SetWidth(WIDTH - 2 * PAD - 76)
  f.lines = ns.Label(f, T.highlightSmall)
  f.lines:SetPoint("TOPLEFT", PAD, -PAD - 30)
  f.lines:SetWidth(WIDTH - 2 * PAD)
end

-- Pin on the Notes tab: true, or nil and why when held for the end of the fight.
function ns.PinBoss(ev, bossId)
  if apply(open(ev, bossId)) then return true end
  return nil, AFTER
end

-- A boss call (RaidsR B): opens the card only for a job you hold in the record's holders, while onCall is not false.
function ns.NotesCallArrived(ev, bossId)
  if card().onCall == false then return end
  local boss, mine = jobsOn(ev, bossId)
  if not boss or #mine == 0 then return end
  apply(open(ev, bossId))
end

-- New notes data: redraws the open card (or hides it when its boss is gone). A change already held in the fight is
-- kept: it draws from the data as it is when it runs.
function ns.JobCardDataChanged()
  if current and not pending then apply(refresh) end
end

function ns.SetCardOption(key, value)
  if key ~= "onCall" and key ~= "hideInFight" then return nil, "unknown option" end
  if type(value) ~= "boolean" then return nil, "not true or false" end
  card()[key] = value
  return true
end

-- Routed by Raids.lua for PLAYER_REGEN_DISABLED and PLAYER_REGEN_ENABLED. At ENABLED the held change runs last, so a
-- held hide still wins and a held refresh redraws a card that is shown again.
function ns.OnFightEvent(event)
  if fighting() then return end
  if event == "PLAYER_REGEN_DISABLED" then
    if f:IsShown() and card().hideInFight ~= false then
      f:Hide()
      hiddenByFight = true
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if type(ns.NotesAfterFight) == "function" then ns.NotesAfterFight() end
    if hiddenByFight then
      hiddenByFight = false
      f:Show()
    end
    local change = pending
    pending = nil
    if change then change() end
  end
end

function ns.JobCardFrame() return f end

build()
