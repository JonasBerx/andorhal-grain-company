-- GuildSync Toast.lua: the hub toast behind M.Toast (API 9, API.md "What API 9 adds"). One queue and one kit card; a
-- toast stays until right-click or its close button dismisses it, which is the only thing that advances the queue
-- (no OnHide, so hiding the UI loses nothing). Held while Compat.HoldForCombat() is true; a toast on screen when combat
-- starts is hidden, stays first and comes back after it. Its sound plays once, at its first show. Api.lua checks and
-- cuts the spec; the text is escaped here, at draw.

local _, ns = ...

local Compat, Kit = ns.Compat, ns.Kit

local MODULE = "Core" -- errors here are recorded as the hub's own, and no module can take that title
local W, H = 320, 76
local TOP_Y = -24 -- near the top edge, away from the character: the card spans -24 to -100, above Games' flight prompt
-- and race toast, which span -160 to -356 (GuildSyncGames/Toast.lua:33)
local ICON = 36
local PAD = 12
local MAX_QUEUE = 8

local Toast = {}
ns.Toast = Toast

local queue = {} -- queue[1] is the current toast, on screen or held
local frame -- GuildSyncToast, built at the first show
local build

local function hide()
  if frame then frame:Hide() end
end

local function show()
  local t = queue[1]
  if not t or Compat.HoldForCombat() then return end
  frame = frame or build()
  if not frame then return end
  if t.icon then
    frame.icon:SetTexture(t.icon)
    frame.icon:Show()
  else
    frame.icon:SetTexture(nil)
    frame.icon:Hide()
  end
  frame.title:SetPoint("TOPLEFT", frame.body, "TOPLEFT", t.icon and (PAD + ICON + 10) or PAD, -PAD)
  frame.title:SetText(ns.Escape(t.title))
  frame.line:SetText(ns.Escape(t.text))
  frame:Show()
  if t.sound and not t.played then
    t.played = true
    Compat.PlaySound(t.sound)
  end
end

local function dismiss()
  table.remove(queue, 1)
  hide()
  show()
end

function build()
  local f = Compat.CreateFrame("Frame", "GuildSyncToast")
  if not f then return nil end
  f:SetSize(W, H)
  f:SetPoint("TOP", Compat.UIParent(), "TOP", 0, TOP_Y)
  f:SetFrameStrata("DIALOG")
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then ns.Safe(MODULE, dismiss) end
  end)

  local body = Kit.Card(f, W, H) or f
  if body ~= f then body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) end
  f.body = body

  f.icon = body:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(ICON, ICON)
  f.icon:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, -PAD)

  local template = Kit.HasTemplate("UIPanelCloseButton") and "UIPanelCloseButton" or nil
  local close = Compat.CreateFrame("Button", nil, body, template)
  if not template then
    close:SetSize(20, 20)
    close:SetText("x")
    close:SetNormalFontObject("GameFontNormal")
  end
  close:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  close:SetScript("OnClick", function() ns.Safe(MODULE, dismiss) end)

  f.title = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("RIGHT", close, "LEFT", -4, 0)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)

  f.line = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.line:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.line:SetPoint("RIGHT", body, "RIGHT", -PAD, 0)
  f.line:SetJustifyH("LEFT")
  return f
end

-- entry = { title, text, icon, sound }, already checked and cut. true | nil, "full".
function Toast.Push(entry)
  if #queue >= MAX_QUEUE then return nil, "full" end
  queue[#queue + 1] = entry
  ns.Safe(MODULE, show)
  return true
end

-- ---------- events (own frame, as CommQueue.lua) ----------

local spec = { events = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" } }

local function onEvent(_, event)
  if event == "PLAYER_REGEN_DISABLED" then hide() else show() end
end

local events = Compat.CreateFrame("Frame")
if events then
  for _, event in ipairs(spec.events) do pcall(events.RegisterEvent, events, event) end -- unknown events throw
  events:SetScript("OnEvent", function(...) ns.Safe(MODULE, onEvent, ...) end)
end
