local _, ns = ...
if not ns.M then return end

-- Load raid data (right card, plan Task 6): the title with a grey "officers", the three steps, the paste box (a
-- M.Kit.Inset one frame level above the card, black .6 fill, its ScrollFrame from ns.ScrollArea), under it either the
-- read-back (a M.Kit.Card one level up, grown to its lines) or the refusal (orange, 0.2's readPaste words), a divider,
-- then Share with the guild and Cancel. place() stacks them (f4763): the box starts under the steps and gives up
-- height (150 down to 40) so the read-back or refusal ends above the divider. Everything is drawn on card.body. ns.Decode, ns.Rules.Plan and ns.Share are looked up at call
-- time. Every pasted or data text goes through ns.Escape.

local M = ns.M
local K = M.Kit
local STEPS = "1. On the website's /officers/ page press \"Copy for the game\".\n2. Paste it below (Ctrl+V).\n"
  .. "3. Check what was read, then press Share with the guild."
local SHARING = "Sharing sends it to every guildmate with the addon. Stay online until it has gone out."

local P = { cal = nil } -- the decoded calendar a good read holds until Share or Cancel
local LINE_H = 14 -- one text line's height in the stack

-- A FontString's wrapped line count (1 when the client cannot tell) and its height.
local function lines(fs)
  local n = fs:GetNumLines()
  return (type(n) == "number" and n > 1) and n or 1
end
local function textH(fs) return lines(fs) * LINE_H end

local function now() return M.Compat.call("GetServerTime") or 0 end
local function esc(s) return ns.Escape(tostring(s or "")) end
local function ago(s) return ns.Rules.Duration(s) end

local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

-- Stacks the card at the last layout: the read-back lines each under the one above (the card at least 70 tall), the
-- box under the steps (y 98 at the default size) and as tall as leaves room for the shown read-back or refusal above
-- the divider, the read-back and the refusal 12 under the box (y 260 at the default size).
local function place()
  local L = P.layout
  if not (L and P.box) then return end
  local IW = L.viewW - 24
  local more = (lines(P.read) - 1) * LINE_H
  P.held:ClearAllPoints()
  P.held:SetPoint("TOPLEFT", 12, -(32 + more))
  if P.held:IsShown() then more = more + (lines(P.held) - 1) * LINE_H end
  P.sharing:ClearAllPoints()
  P.sharing:SetPoint("TOPLEFT", 12, -(48 + more))
  local rbH = math.max(70, 48 + more + textH(P.sharing) + 10)
  P.readback:SetSize(IW, rbH)
  local mid = (P.readback:IsShown() and rbH) or (P.result:IsShown() and textH(P.result)) or 0
  local boxTop = math.max(98, 48 + textH(P.steps) + 8)
  local boxH = math.max(40, math.min(150, (L.cardH - 58) - 6 - mid - 12 - boxTop))
  P.inset:ClearAllPoints()
  P.inset:SetPoint("TOPLEFT", 12, -boxTop)
  P.inset:SetSize(IW, boxH)
  local y = boxTop + boxH + 12
  P.readback:ClearAllPoints()
  P.readback:SetPoint("TOPLEFT", 12, -y)
  P.result:ClearAllPoints()
  P.result:SetPoint("TOPLEFT", 12, -y)
end

-- The orange refusal in place of the read-back; Share stays shown, disabled.
local function refuse(text)
  P.readback:Hide()
  P.result:SetText(text)
  color(P.result, ns.ORANGE)
  P.result:Show()
  P.share:SetEnabled(false)
  place()
end

-- 0.2's readPaste (Page.lua a6a1332c:246-302), the read-back now in its own card.
local function readPaste(text)
  P.cal = nil
  P.share:SetEnabled(false)
  P.readback:Hide()
  P.result:Hide()
  color(P.result, ns.WHITE)
  if not text or string.match(text, "^%s*$") then P.result:SetText(""); return end
  local t = now()
  local rows = ns.Roster()
  local cal, why = ns.Decode(text)
  if not cal then
    local words = {
      prefix = "This is not a raid calendar: the prefix is not GSR1. Copy it with \"Copy for the game\" on /officers/.",
      version = "This raid calendar is from a newer version. Update GuildSyncRaids.",
      cut = "The paste is cut short. Copy it again and paste all of it.",
      checksum = "The paste does not match its checksum. Copy it again.",
      size = "This paste is too long (over 128 KB). Copy it again on /officers/.",
    }
    refuse(words[why] or "The paste could not be read. Copy it again.")
    return
  end
  local Rules = ns.Rules
  local plan, whyPlan, info = Rules.Plan(cal, ns.DB().records, t, ns.MyKey())
  local held = Rules.Held(ns.DB().records, t)
  if plan then
    local rb = plan.readback
    P.read:SetText("Read: " .. rb.raids .. " raids, " .. rb.signups .. " sign-ups, " .. rb.teams .. " teams, data "
      .. ago(t - (rb.at or rb.gen)) .. " old")
    if held then
      P.held:SetText("Held now: data from " .. ns.When("%H:%M", held.at or held.gen) .. " by "
        .. ns.Who(rows, held.by) .. ": this paste is newer")
    end
    P.held:SetShown(held and true or false)
    P.readback:Show()
    P.cal = cal
    P.share:SetEnabled(true)
    return
  end
  info = info or {}
  local text2
  if whyPlan == "stale" then
    text2 = "This copy is " .. ago(info.age or 0) .. " old. Copy it again on /officers/ and paste it within the hour."
  elseif whyPlan == "future" then
    text2 = "This copy's time is in the future. Copy it again on /officers/."
  elseif whyPlan == "older" then
    local h = info.held or {}
    text2 = "Held now: data from " .. ns.When("%H:%M", h.at or h.gen or 0) .. " by " .. ns.Who(rows, h.by)
      .. ". This paste is not newer, so nothing is shared."
  elseif whyPlan == "records" then
    text2 = "Too many records to share (" .. tostring(info.xCount or 0) .. " cancelled raids still held"
      .. (info.oldestExpiry and (", the oldest goes " .. ns.When("%a %d %b %H:%M", info.oldestExpiry)) or "") .. ")."
  elseif whyPlan == "parts" then
    text2 = esc(info.name) .. " is too big to share."
  elseif whyPlan == "teams" then
    text2 = "More teams than the game can hold."
  else
    text2 = "Nothing to share in this paste."
  end
  refuse(text2)
end

-- Cancel, and a good Share: empty the card and go back to the chosen raid.
local function cancel()
  P.cal = nil
  P.box:SetText("")
  P.result:SetText("")
  P.result:Hide()
  P.readback:Hide()
  P.share:SetEnabled(false)
  ns.EndPaste()
end

local function share()
  if not P.cal then return end
  local okShare, why = ns.Share(P.cal) -- looked up at click time
  if okShare then
    cancel()
  else
    P.cal = nil
    refuse(why == "officer" and "Only an officer can share, once the guild roster is read."
      or ("Not shared (" .. tostring(why) .. "). Paste it again."))
  end
end

local function button(parent, text, w, fn)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetScript("OnClick", function() M.Safe(fn) end)
  return b
end

function ns.BuildPaste(card)
  local body = card.body
  local level = card:GetFrameLevel() + 1
  P.title = ns.Label(body, "GameFontNormal")
  P.title:SetPoint("TOPLEFT", 12, -26)
  P.title:SetText("Load raid data")
  P.officers = ns.Label(body, "GameFontHighlightSmall")
  P.officers:SetJustifyH("RIGHT")
  P.officers:SetPoint("TOPRIGHT", -12, -27)
  P.officers:SetText("officers")
  color(P.officers, ns.GREY)
  P.steps = ns.Label(body)
  P.steps:SetJustifyV("TOP")
  P.steps:SetWordWrap(true)
  P.steps:SetPoint("TOPLEFT", 12, -48)
  P.steps:SetText(STEPS)
  -- The paste box (d636): the Inset one level up with a black .6 fill, 0.2's multi-line EditBox as the scroll child.
  P.inset = K.Inset(body) or CreateFrame("Frame", nil, body)
  P.inset:SetFrameLevel(level)
  local fill = P.inset:CreateTexture(nil, "ARTWORK")
  fill:SetAllPoints(P.inset)
  fill:SetColorTexture(0, 0, 0, 0.6)
  local scroll, spare = ns.ScrollArea(P.inset)
  scroll:SetPoint("TOPLEFT", 8, -7)
  scroll:SetPoint("BOTTOMRIGHT", -22, 7)
  spare:Hide()
  P.box = CreateFrame("EditBox", nil, scroll)
  P.box:SetMultiLine(true)
  P.box:SetMaxLetters(0)
  P.box:SetAutoFocus(false)
  P.box:SetFontObject("ChatFontNormal")
  P.box:SetWidth(400)
  scroll:SetScrollChild(P.box)
  scroll:SetScript("OnSizeChanged", function(_, w) if w then P.box:SetWidth(w) end end)
  P.box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  P.box:SetScript("OnTextChanged", function(self) M.Safe(function() readPaste(self:GetText()); place() end) end)
  -- Under the box (place): the read-back card (one level up) or the refusal.
  P.readback = K.Card(body, 412, 70) or CreateFrame("Frame", nil, body)
  P.readback:SetFrameLevel(level)
  P.read = ns.Label(P.readback)
  P.read:SetPoint("TOPLEFT", 12, -12)
  P.held = ns.Label(P.readback)
  P.sharing = ns.Label(P.readback, "GameFontHighlightSmall")
  P.sharing:SetText(SHARING)
  P.readback:Hide()
  P.result = ns.Label(body)
  P.result:SetJustifyV("TOP")
  P.result:SetWordWrap(true)
  P.result:Hide()
  P.div = K.Divider(body)
  P.share = button(body, "Share with the guild", 160, share)
  P.share:SetEnabled(false)
  P.cancel = button(body, "Cancel", 80, cancel)
end

function ns.DrawPaste(card, view, rows, t, layout)
  if not P.box then return end
  local IW = layout.viewW - 24
  local y = -(layout.cardH - 54)
  P.steps:SetWidth(IW)
  for _, fs in ipairs({ P.read, P.held, P.sharing }) do fs:SetWidth(IW - 24) end
  P.result:SetWidth(IW)
  P.layout = layout
  place()
  if P.div then
    P.div:ClearAllPoints()
    P.div:SetPoint("TOPLEFT", 12, -(layout.cardH - 58))
    P.div:SetWidth(IW)
  end
  P.share:ClearAllPoints()
  P.share:SetPoint("TOPRIGHT", -98, y)
  P.cancel:ClearAllPoints()
  P.cancel:SetPoint("TOPRIGHT", -12, y)
  P.share:SetEnabled(P.cal ~= nil)
end
