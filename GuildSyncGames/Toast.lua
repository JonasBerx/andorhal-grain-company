-- GuildSyncGames Toast.lua: the race toast (plan Task 7, AC5, f7158). ns.ArmToast() arms one M.After per race hour
-- for the race you bet on; Grain.lua calls it after a bet, a cancel, a settle and at login. The arm time comes from
-- ns.Now() (f7154). At the start the timer re-reads the bet (a cancelled one makes it a no-op) and the checks through
-- M.Compat.call: not in combat, not in an instance, demo off. A missing answer means no toast. The toast hides itself
-- at race end and when combat starts (PLAYER_REGEN_DISABLED, so f7122 is not repeated). It never opens the window by
-- itself: only its Watch button does, through M.OpenPage(). Seams are read through ns. when called (f7165).

local _, ns = ...

if not ns.M then return end
local M = ns.M

local W, H = 300, 76 -- to-1
local HOUR = 3600

local toast -- GuildSyncGamesToast, built at the first show

local function hide()
  if toast then toast:Hide() end
end

local function watch()
  hide()
  M.OpenPage()
  if ns.SelectGame then ns.SelectGame("races") end
  if M.RefreshPage then M.RefreshPage() end
end

local function build()
  local f = CreateFrame("Frame", "GuildSyncGamesToast", UIParent)
  f:SetSize(W, H)
  f:SetPoint("TOP", UIParent, "TOP", 0, -280) -- below the flight prompt (-160, 112 tall): the two never overlap (f7214)
  f:SetFrameStrata("DIALOG")
  f:Hide()
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GuildSyncGamesToast") end -- Escape closes it

  local body = M.Kit.Card(f, W, H) or f
  if body ~= f then body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end

  f.icon = body:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(36, 36)
  f.icon:SetPoint("TOPLEFT", body, "TOPLEFT", 12, -12)

  f.title = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
  f.line = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.line:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.line:SetPoint("RIGHT", body, "RIGHT", -12, 0) -- a long kodo name ends in an ellipsis inside the card (a1)
  f.line:SetJustifyH("LEFT")
  f.line:SetWordWrap(false)
  f.line:SetTextColor(0.6, 0.6, 0.6) -- grey, as to-1 (f7227)

  local close = CreateFrame("Button", nil, body, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  f.title:SetPoint("RIGHT", close, "LEFT", -4, 0) -- a long title stops at the close button, as the prompt's
  f.title:SetJustifyH("LEFT")
  close:SetScript("OnClick", function() M.Safe(hide) end)

  local go = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
  go:SetSize(76, 22)
  go:SetText("Watch")
  go:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -12, 12)
  go:SetScript("OnClick", function() M.Safe(watch) end)
  return f
end

-- The kodo you backed, its icon and the bet; the race end is timed by the real clock (f7154).
local function show(h, bet)
  local GC = ns.GrainCore
  local kodo = GC.Race(h).field[bet.lane]
  toast = toast or build()
  toast.icon:SetTexture(kodo.icon)
  toast.title:SetText("The kodos are off!")
  toast.line:SetText("The " .. tostring(ns.RaceLabel(h)) .. " race · your " .. bet.stake .. " grain on " .. kodo.name)
  toast:Show()
  local now, s = ns.Now(), 0 -- with no clock the hide waits the whole race (f7189)
  if type(now) == "number" then s = select(2, GC.RaceAt(now)) end
  M.After(math.max(GC.RUN - s, 0), hide)
end

-- At race h's start: the bet is re-read, so a cancel (or a bet moved to another race) shows nothing.
local function fire(h)
  local b = ns.MyBet()
  if not (b and b.hour == h) then return end
  if M.Compat.call("InCombatLockdown") ~= false then return end
  if M.Compat.call("IsInInstance") ~= false then return end
  if M.Demo() then return end
  show(h, b)
end

local armed = {} -- [race hour] = true once its timer is set; a re-bet on the same race reuses it

function ns.ArmToast()
  local b = ns.MyBet() -- may re-enter through ns.OnLogin, so the armed set is read after it
  local now = ns.Now()
  if not b or armed[b.hour] or type(now) ~= "number" then return end
  local start = b.hour * HOUR
  if start <= now then return end
  armed[b.hour] = true
  local h = b.hour
  M.After(start - now, function() fire(h) end)
end

function ns.OnToastEvent(event)
  if event == "PLAYER_REGEN_DISABLED" then hide() end
end
