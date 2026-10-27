-- GuildKOS Core: the saved list, /kos, import (paste window or chat line), spotting and alerts.
-- Every client value goes through ns.Compat; decisions and lines come from ns.Rules and ns.Codec.
-- ns.Sync loads after this file, so it is looked up when used, never at load.
local _, ns = ...
local Core = {}
ns.Core = Core

local C, Rules, Codec = ns.Compat, ns.Rules, ns.Codec

local SOUND_RAID_WARNING = 8959   -- SOUNDKIT.RAID_WARNING
local shownOwn = {}               -- throttle for own sightings (alert and send); not saved
-- The Kill on Sight page on the hub (Hub.lua); called when the list, a sighting or a setting changes.
local function refreshPage() if ns.Hub then ns.Hub.Refresh() end end

-- ---------- saved data ----------

-- Re-read on every call: GuildKOSDB is nil at load and replaced when the saved variables arrive.
function Core.DB()
  if type(GuildKOSDB) ~= "table" then GuildKOSDB = {} end
  local db = GuildKOSDB
  if type(db.list) ~= "table" or type(db.list.targets) ~= "table" then db.list = nil end
  if type(db.lastSeen) ~= "table" then db.lastSeen = {} end
  if type(db.sightings) ~= "table" then db.sightings = {} end
  db.muted = db.muted == true
  db.demo = db.demo == true
  if type(db.minimap) ~= "table" then db.minimap = {} end
  db.minimap.angle = Rules.MinimapAngle(db.minimap.angle)
  db.minimap.hidden = db.minimap.hidden == true
  return db
end

function Core.Now()
  local ok, t = C.call("GetServerTime")
  return (ok and C.num(t)) or 0
end

-- A date the client can't format reads "an unknown date" (D86).
function Core.DateText(version)
  local ok, text = pcall(date, "%Y-%m-%d %H:%M", version)
  if ok and type(text) == "string" then return text end
  return "an unknown date"
end

-- The real list and last-seen data (the hub's demo is drawn by Hub.lua, never stored here).
function Core.View()
  local db = Core.DB()
  return db.list, db.lastSeen
end

-- list: a Codec.Decode result. Keeps every decoded field for the next run.
function Core.Store(list, source)
  local db = Core.DB()
  db.list = { version = list.version, text = list.text, targets = list.targets }
  pcall(refreshPage) -- a page error never stops an import (f711)
  return db.list
end

-- ---------- import ----------

-- Returns ok and the line it printed. The verdict comes before the date is formatted (D86).
function Core.Import(text)
  local list, reason = Codec.Decode(text or "")
  if not list then
    local line = Rules.RefusalLine(reason)
    print(line)
    return false, line
  end
  local db = Core.DB()
  local mine = db.list and db.list.version
  local verdict = Rules.ImportVerdict(mine, list.version, Core.Now())
  if verdict ~= "take" then
    local line = Rules.RefusalLine(verdict, Core.DateText(list.version))
    print(line)
    return false, line
  end
  Core.Store(list, "import")
  if ns.Sync then ns.Sync.AfterImport() end
  local line = Rules.ImportLine(#list.targets, Core.DateText(list.version), ns.Sync and ns.Sync.IAmOfficer())
  print(line)
  return true, line
end

local paste
local function pasteWindow()
  if paste then return paste end
  local f = CreateFrame("Frame", "GuildKOSPasteFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(460, 300)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText("GuildKOS: paste the list, then Import")

  local scroll = CreateFrame("ScrollFrame", "GuildKOSPasteScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -32)
  scroll:SetPoint("BOTTOMRIGHT", -34, 44)

  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetMaxLetters(0)
  box:SetAutoFocus(false)
  box:SetFontObject("ChatFontNormal")
  box:SetWidth(400)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  scroll:SetScrollChild(box)
  f.box = box

  local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  button:SetSize(100, 24)
  button:SetPoint("BOTTOMRIGHT", -14, 12)
  button:SetText("Import")

  -- The refusal line from Core.Import (a Rules line, never the pasted text), two lines under the scroll (D94).
  local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  status:SetPoint("BOTTOMLEFT", 16, 10)
  status:SetPoint("BOTTOMRIGHT", button, "BOTTOMLEFT", -8, -2)
  status:SetHeight(30)
  status:SetWordWrap(true)
  status:SetJustifyH("LEFT")
  f.status = status

  local function import()
    local ok, line = Core.Import(box:GetText())
    if ok then
      status:SetText("")
      f:Hide()
    else
      status:SetText(line)
    end
  end
  button:SetScript("OnClick", import)
  box:SetScript("OnEnterPressed", import)
  box:SetScript("OnTabPressed", function() box:ClearFocus() end)

  -- Escape closes the window even when the box has no focus (after Tab); runs once, the frame is cached.
  local special = C.frame("UISpecialFrames")
  if special then table.insert(special, "GuildKOSPasteFrame") end

  f:Hide()
  paste = f
  return f
end

-- ---------- spotting ----------

-- entry, name | nil. No side effects; every value is checked for secrets before it is compared.
function Core.Identify(unit)
  unit = C.str(unit)
  if not unit then return nil end
  local db = Core.DB()
  if not db.list then return nil end
  local ok, secret = C.call("C_Secrets.ShouldUnitIdentityBeSecret", unit)
  if ok and C.plain(secret) ~= false then return nil end
  local okP, isPlayer = C.call("UnitIsPlayer", unit)
  if not okP or C.plain(isPlayer) ~= true then return nil end
  local okE, isEnemy = C.call("UnitIsEnemy", "player", unit)
  if not okE or C.plain(isEnemy) ~= true then return nil end
  local okN, name = C.call("UnitName", unit)
  name = okN and C.str(name) or nil
  if not name then return nil end
  local entry = Rules.Find(db.list.targets, name)
  if not entry then return nil end
  return entry, name
end

local banner
local function showBanner(text)
  if not banner then
    banner = CreateFrame("Frame", nil, UIParent)
    banner:SetSize(600, 40)
    banner:SetPoint("TOP", 0, -160)
    banner:SetFrameStrata("HIGH")
    banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    banner.text:SetAllPoints()
    banner.fade = banner:CreateAnimationGroup()
    local alpha = banner.fade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetDuration(1)
    alpha:SetStartDelay(Rules.BANNER)
    banner.fade:SetScript("OnFinished", function() banner:Hide() end)
  end
  banner.fade:Stop()
  banner:SetAlpha(1)
  banner.text:SetText(text)
  banner:Show()
  banner.fade:Play()
end

local function playSound()
  if not C.call("C_Sound.PlaySound", SOUND_RAID_WARNING) then C.call("PlaySound", SOUND_RAID_WARNING) end
end

-- Store first, then throttle what is shown and sent (own sightings only; heard ones were judged by Sync with
-- Rules.HeardAllowed, D89). source "self" | "heard"; by and senderKey are nil for "self".
function Core.Report(entry, zone, subzone, source, by, senderKey)
  local db = Core.DB()
  local now = Core.Now()
  local key = Rules.Key(entry.target)
  if not key then return end
  zone, subzone = zone or "", subzone or ""
  Rules.AddSighting(db.sightings, {
    key = key, target = entry.target, by = by, zone = zone, subzone = subzone, at = now, source = source,
    sender = senderKey,
  }, Rules.RING, Rules.RING_PER_SENDER)
  if source == "self" or not Rules.KeepOwn(db.lastSeen[key], now) then
    db.lastSeen[key] = { at = now, zone = zone, subzone = subzone, by = by }
  end
  pcall(refreshPage) -- a page error never stops the alert or the guild send (f711)

  -- Own sightings throttle here, heard ones in Sync: hearing a target never silences your own alert and send.
  if source == "self" then
    if not Rules.Throttle(shownOwn, key, now, Rules.WINDOW) then return end
    if not db.muted then
      local line = Rules.SpotLine(entry, zone, subzone)
      playSound()
      showBanner(line)
      print(line)
    end
    if ns.Sync then ns.Sync.SendSighting(entry.target, zone, subzone) end
  else
    if not db.muted then print(Rules.HeardLine(by or "", entry.target, zone, subzone)) end
  end
end

local function spot(unit)
  local entry = Core.Identify(unit)
  if not entry then return end
  local okZ, zone = C.call("GetZoneText")
  local okS, subzone = C.call("GetSubZoneText")
  Core.Report(entry, (okZ and C.str(zone)) or "", (okS and C.str(subzone)) or "", "self")
end

-- ---------- actions shared by /kos, the page and the settings ----------

function Core.SetMuted(muted)
  local db = Core.DB()
  db.muted = muted == true
  if db.muted then
    print("KOS: Alerts are off. You still tell the guild what you see.")
  else
    print("KOS: Alerts are on.")
  end
  refreshPage()
end

function Core.OpenImport()
  local f = pasteWindow()
  f.box:SetText("")
  f.status:SetText("")
  f:Show()
  f.box:SetFocus()
end

-- Officers only, local: clears the list, its last-seen lines and the sighting history, so the next list an officer
-- sends is taken (D81). Sends nothing; muted, demo and minimap stay.
function Core.Reset()
  if not (ns.Sync and ns.Sync.IAmOfficer()) then
    print(Rules.ResetRefusedLine())
    return
  end
  local db = Core.DB()
  local list = db.list
  db.list = nil
  db.lastSeen = {}
  db.sightings = {}
  if list then
    print(Rules.ResetLine(#list.targets, Core.DateText(list.version)))
  else
    print(Rules.ResetLine())
  end
  refreshPage()
end

-- ---------- /kos ----------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function slash(msg)
  msg = trim(C.str(msg) or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" or cmd == "ui" or cmd == "window" then
    if ns.Hub then ns.Hub.Open() else print("KOS: The Kill on Sight page needs GuildSync (API 4 or later).") end
  elseif cmd == "on" then
    Core.SetMuted(false)
  elseif cmd == "off" then
    Core.SetMuted(true)
  elseif cmd == "import" then
    if rest == "" then
      Core.OpenImport()
    else
      Core.Import(rest)
    end
  elseif cmd == "demo" then
    -- the hub's demo (d604): /kos demo is /gsync demo
    rest = rest:lower()
    if rest ~= "" and rest ~= "on" and rest ~= "off" then
      print("Usage: /kos demo [on | off]")
    else
      local fn = type(SlashCmdList) == "table" and SlashCmdList.GUILDSYNC or nil
      if type(fn) == "function" then fn(rest == "" and "demo" or ("demo " .. rest))
      else print("KOS: /gsync demo is not available.") end
    end
  elseif cmd == "reset" then
    if rest ~= "" then print("Usage: /kos reset") else Core.Reset() end
  else
    print("KOS: /kos opens the Kill on Sight page, /kos import adds a list, /kos on and /kos off turn alerts on and off, /kos demo shows a demo list (as /gsync demo), /kos reset (officers) clears your list so the next one is taken.")
  end
end

SLASH_KOS1 = "/kos"
SlashCmdList.KOS = slash

-- ---------- events ----------

local frame = CreateFrame("Frame")
local handlers = {
  NAME_PLATE_UNIT_ADDED = function(unit) spot(unit) end,
  PLAYER_TARGET_CHANGED = function() spot("target") end,
  UPDATE_MOUSEOVER_UNIT = function() spot("mouseover") end,
}
for event in pairs(handlers) do pcall(frame.RegisterEvent, frame, event) end
frame:SetScript("OnEvent", function(_, event, ...)
  local fn = handlers[event]
  if fn then fn(...) end
end)

return Core
