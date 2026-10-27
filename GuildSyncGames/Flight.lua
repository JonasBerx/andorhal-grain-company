-- GuildSyncGames Flight.lua: the flight prompt and the flight setting (plan Task 8, o1552, f7075, f7076).
-- S11 (Task 7): the prompt offers the game last chosen (ns.LastGame): Harvest, Kodo races, else WoWdle as before.
-- PLAYER_CONTROL_LOST arms one check 1 s later. The check re-reads everything through M.Compat.call: UnitOnTaxi plain
-- true, not in combat, not in an instance, demo off, the setting on, this flight not asked yet. A missing or secret
-- answer means no prompt. PLAYER_CONTROL_GAINED ends the flight and hides the prompt. The prompt never opens the
-- window by itself: only its Play button does, through M.OpenPage().

local _, ns = ...

if not ns.M then return end
local M = ns.M

local ICON = "Interface\\Icons\\INV_Misc_Dice_01"
local ICONS = { harvest = 134058, races = 132245, vendor = 133784 } -- wheat, kodo (f7224), coin (S12); dice: WoWdle
local W, H = 330, 112 -- fl-1

-- ---------- the setting (db.flight, default on) ----------

function ns.FlightOn()
  local d = GuildSyncGamesDB
  return not (type(d) == "table" and d.flight == false)
end

function ns.SetFlight(on)
  GuildSyncGamesDB = type(GuildSyncGamesDB) == "table" and GuildSyncGamesDB or {}
  GuildSyncGamesDB.flight = on and true or false
end

-- ---------- the prompt ----------

local prompt -- GuildSyncGamesPrompt, built at the first show

local function hide()
  if prompt then prompt:Hide() end
end

-- The game last chosen (ns.LastGame, Grain.lua), WoWdle without it.
local function game()
  return ns.LastGame and ns.LastGame() or "wowdle"
end

local function play()
  hide()
  local key = game()
  local today = ns.Today and ns.Today()
  M.OpenPage()
  if ns.SelectGame then ns.SelectGame(key) end
  -- Harvest and Kodo races open on their tab; WoWdle also picks the daily word or a practice one
  if key == "wowdle" and type(today) == "table" and today.done then
    if ns.NewPractice then ns.NewPractice() end
  elseif key == "wowdle" and ns.SetMode then
    ns.SetMode("daily")
  elseif key == "vendor" and ns.VendorMode then -- a finished daily run goes endless
    local v = ns.VendorToday and ns.VendorToday()
    ns.VendorMode((type(v) == "table" and v.done) and "endless" or "daily")
  end
  if M.RefreshPage then M.RefreshPage() end
end

local function button(parent, text, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(80, 22)
  b:SetText(text)
  b:SetScript("OnClick", function() M.Safe(onClick) end)
  return b
end

local function build()
  local f = CreateFrame("Frame", "GuildSyncGamesPrompt", UIParent)
  f:SetSize(W, H)
  f:SetPoint("TOP", UIParent, "TOP", 0, -160)
  f:SetFrameStrata("DIALOG")
  f:Hide()
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GuildSyncGamesPrompt") end

  local body = M.Kit.Card(f, W, H) or f
  if body ~= f then body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end

  f.icon = body:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(36, 36)
  f.icon:SetPoint("TOPLEFT", body, "TOPLEFT", 12, -12)
  f.icon:SetTexture(ICON)

  f.title = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, -2)
  f.line = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.line:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.line:SetTextColor(0.6, 0.6, 0.6) -- grey, as fl-1 and fl-2 (f7227)

  local close = CreateFrame("Button", nil, body, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  f.title:SetPoint("RIGHT", close, "LEFT", -4, 0) -- a long title stops at the close button (v11)
  f.title:SetJustifyH("LEFT")
  close:SetScript("OnClick", function() M.Safe(hide) end)

  f.ask = M.Kit.Checkbox(body, "Ask on flights")
  if f.ask then
    f.ask:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 8, 8)
    f.ask:SetScript("OnClick", function(self)
      M.Safe(function() ns.SetFlight(self:GetChecked() and true or false) end)
    end)
  end

  local notNow = button(body, "Not now", hide)
  notNow:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -10, 10)
  local go = button(body, "Play", play)
  go:SetPoint("RIGHT", notNow, "LEFT", -6, 0)
  return f
end

local function show()
  prompt = prompt or build()
  local key = game()
  local today = ns.Today and ns.Today()
  local now = ns.Now()
  prompt.icon:SetTexture(ICONS[key] or ICON)
  if key == "harvest" then
    local farm = ns.Farm() -- fl-2
    prompt.title:SetText("A long flight? Tend your field.")
    prompt.line:SetText(farm.standing .. " of " .. farm.cap .. " grain standing · " .. farm.rate .. " a minute")
  elseif key == "vendor" then
    local v = ns.VendorToday and ns.VendorToday() -- nil with no clock: the title only (f7189)
    prompt.title:SetText("A long flight? Price some loot.")
    if type(v) == "table" and v.done then -- q1575
      prompt.line:SetText("Vendor price " .. tostring(v.label) .. " done, " .. tostring(v.score) .. "/10. Try Endless.")
    elseif type(v) == "table" then
      prompt.line:SetText("Vendor price " .. tostring(v.label) .. ": " .. #tostring(v.picks or "") .. " of 10 picked")
    else
      prompt.line:SetText("")
    end
  elseif key == "races" and type(now) ~= "number" then
    prompt.title:SetText("A long flight? Back a kodo.") -- no clock, no race to name (f7189)
    prompt.line:SetText("")
  elseif key == "races" then
    local phase, h = ns.GrainCore.Phase(now) -- the race open for bets, else the next one
    if phase ~= "betting" then h = h + 1 end
    prompt.title:SetText("A long flight? Back a kodo.")
    if phase == "betting" then
      prompt.line:SetText("The " .. tostring(ns.RaceLabel(h)) .. " race takes bets")
    else -- bets open at :05 (f7190); the short form when the long one runs past about 250 px (as Races.lua:353)
      local fs, nextRace = prompt.line, tostring(ns.RaceLabel(h))
      local at = string.gsub(tostring(ns.RaceLabel(h - 1)), "^(%d%d):00", "%1:05")
      fs:SetText("Bets for the " .. nextRace .. " race open at " .. at .. ".")
      local w = tonumber(fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
      if not w or w <= 0 then w = fs:GetStringWidth() end -- 0 is no measurement (Company.lua textWidth)
      if (fs.IsTruncated and fs:IsTruncated()) or (tonumber(w) or 0) > 250 then
        fs:SetText("Bets for " .. nextRace .. " open at " .. at .. ".")
      end
    end
  elseif type(today) == "table" and today.done then
    prompt.title:SetText("A long flight? Play a practice WoWdle.")
    prompt.line:SetText("Today's WoWdle " .. tostring(today.label) .. " is done.")
  elseif type(today) == "table" then
    prompt.title:SetText("A long flight? Play today's WoWdle.")
    prompt.line:SetText("WoWdle " .. tostring(today.label) .. " · try " .. (#(today.rows or {}) + 1) .. " of 6 · "
      .. tostring(today.len) .. " letters")
  else
    prompt.title:SetText("WoWdle while you fly?")
    prompt.line:SetText("")
  end
  if prompt.ask then prompt.ask:SetChecked(ns.FlightOn()) end
  prompt:Show()
end

-- ---------- the flight ----------

local flight, asked = 0, false -- flight counts landings, so a check armed before one is dropped

local function check(n)
  if n ~= flight or asked then return end
  if M.Compat.call("UnitOnTaxi", "player") ~= true then return end
  if M.Compat.call("InCombatLockdown") ~= false then return end
  if M.Compat.call("IsInInstance") ~= false then return end
  if M.Demo() or not ns.FlightOn() then return end
  asked = true
  show()
end

function ns.OnEvent(event)
  if event == "PLAYER_CONTROL_LOST" then
    local n = flight
    M.After(1, function() check(n) end)
  elseif event == "PLAYER_CONTROL_GAINED" then
    flight, asked = flight + 1, false
    hide()
  end
end
