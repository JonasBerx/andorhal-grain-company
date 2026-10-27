local _, ns = ...
if not ns.M then return end

-- The Pulls tab of the chosen raid (S9 L1, Raids 0.5 Pulls; mock s4r2-0): the raid's pulls as chips, then At every
-- pull, At some pulls, Signed up at no pull (the no-shows for /recap) and At pulls without a sign-up, over
-- PullRules.ForRaid and PullRules.Lists; the bar line under them. ns.DrawPulls(card, ev, layout, top, events) is
-- called by RaidView.lua. The pane is built on the first draw (RaidView has no build hook for it), on card.body. Every
-- name and boss goes through ns.Escape; colours are set with SetTextColor, never as an inline code.

local M = ns.M
local K = M.Kit
local SB = 22 -- the scrollbar's room on the right (ns.ScrollArea)
local CHIP_H, CHIP_GAP, CHIP_ROWS = 30, 4, 2
local GREEN = { 0.1, 1, 0.1 }
local KEPT = " Kept up to 300 pulls or 35 days on this character."
local NOTE = "Recorded by this client: the raid group as it was just before each pull."
local RECAP = "Mark no-shows in /recap on Discord: the bot's attendance counts them."

local function esc(s) return ns.Escape(tostring(s or "")) end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function at(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", x, y)
end

local function textWidth(fs)
  local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
  return type(w) == "number" and w or nil
end

local function build(card)
  local body = card.body
  local V = { chips = {}, heads = { n = 0 }, lines = { n = 0 } }
  card.pullsView = V
  V.pane = CreateFrame("Frame", nil, body)
  V.fill = V.pane:CreateTexture(nil, "ARTWORK")
  V.fill:SetAllPoints(V.pane)
  V.fill:SetColorTexture(0, 0, 0, 0.35)
  V.scroll, V.child = ns.ScrollArea(V.pane)
  V.barDiv = K.Divider and K.Divider(body)
  V.bar = ns.Label(body, "GameFontHighlightSmall")
  V.bar:SetWordWrap(false)
  color(V.bar, ns.GREY)
  return V
end

-- The i-th chip (made on first use): a dark tile, the boss on top, "HH:MM <result>" under it.
local function chip(V, i)
  local ch = V.chips[i]
  if ch then return ch end
  ch = CreateFrame("Frame", nil, V.pane)
  ch.bg = ch:CreateTexture(nil, "ARTWORK")
  ch.bg:SetAllPoints(ch)
  ch.bg:SetColorTexture(0, 0, 0, 0.5)
  ch.boss = ns.Label(ch, "GameFontHighlightSmall")
  ch.boss:SetWordWrap(false)
  at(ch.boss, 6, -2)
  ch.res = ns.Label(ch, "GameFontHighlightSmall")
  ch.res:SetWordWrap(false)
  at(ch.res, 6, -16)
  V.chips[i] = ch
  return ch
end

-- The next FontString of a pool in the lists' scroll child, placed at (x, -y) with width w; answers y below it.
local function line(V, pool, font, text, c, x, y, w)
  pool.n = pool.n + 1
  local fs = pool[pool.n]
  if not fs then
    fs = V.child:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    pool[pool.n] = fs
  end
  at(fs, x, -y)
  fs:SetWidth(w)
  fs:SetText(text)
  if c then color(fs, c) end
  fs:Show()
  local h = tonumber(fs:GetStringHeight()) or 14
  return y + h + 3
end

local function hideAll(V)
  for _, ch in ipairs(V.chips) do ch:Hide() end
  for _, pool in ipairs({ V.heads, V.lines }) do
    for i = 1, #pool do pool[i]:Hide() end
    pool.n = 0
  end
end

-- The chips in pull order, wrapping to the next row at the pane's width; rows past CHIP_ROWS are cut. Answers the
-- height the chips take.
local function drawChips(V, pulls, IW)
  local x, row, rows = 0, 0, 0
  for i, p in ipairs(pulls) do
    local ch = chip(V, i)
    ch.boss:SetText(esc(p.name or "?"))
    local res = (p.success == true and "kill") or (p.success == false and "wipe") or "no end"
    ch.res:SetText(ns.When("%H:%M", p.at) .. " " .. res)
    color(ch.res, (p.success == true and GREEN) or (p.success == false and ns.ORANGE) or ns.GREY)
    local w = math.max(textWidth(ch.boss) or 68, textWidth(ch.res) or 68)
    w = math.min(IW, w + 12)
    if x > 0 and x + w > IW then x, row = 0, row + 1 end
    if row >= CHIP_ROWS then
      ch:Hide()
      break
    end
    at(ch, x, -(row * (CHIP_H + CHIP_GAP)))
    ch:SetSize(w, CHIP_H)
    ch:Show()
    rows = row + 1
    x = x + w + CHIP_GAP
  end
  return rows * (CHIP_H + CHIP_GAP)
end

local function names(list, fmt)
  local out = {}
  for _, s in ipairs(list) do out[#out + 1] = fmt and fmt(s) or esc(s.name) end
  return table.concat(out, ", ")
end

-- The lists in the scroll child, top-down; answers the child's height.
local function drawLists(V, pulls, R, PW)
  local y = 6
  local function head(text) y = line(V, V.heads, "GameFontNormalSmall", text, nil, 4, y, PW - 8) end
  local function body(text, c) y = line(V, V.lines, "GameFontHighlightSmall", text, c, 12, y, PW - 16) + 4 end
  if #pulls == 0 then
    body("No pulls recorded for this raid on this character.", ns.GREY)
    return y
  end
  if R.hidden == 1 then
    body("No names for this pull: the game hid them, or the group was not read before it.", ns.GREY)
  elseif R.hidden > 1 then
    body("No names for " .. R.hidden .. " pulls: the game hid them, or the group was not read before them.", ns.GREY)
  end
  -- d1236: with no pull with names there are no lists, only the line above
  if R.m > 0 then
    head("At every pull (" .. #R.every .. ")")
    if #R.every > 0 then body(names(R.every), ns.WHITE) end
    head("At some pulls (" .. #R.some .. ")")
    if #R.some > 0 then
      -- d1239: "(from Boss)" only for a late joiner, someone not at the first pull with names
      local atFirst = {}
      for _, p in ipairs(pulls) do
        if p.snapAge ~= nil then
          for _, person in ipairs(p.people) do
            local k = type(person) == "table" and type(person.name) == "string" and ns.Key(person.name)
            if k then atFirst[k] = true end
          end
          break
        end
      end
      body(names(R.some, function(s)
        local text = esc(s.name) .. " " .. s.k .. " of " .. s.m
        if atFirst[ns.Key(s.name) or ""] then return text end
        return text .. " (from " .. esc(s.first or "?") .. ")"
      end), ns.WHITE)
    end
    head("Signed up, at no pull (" .. #R.noShow .. ")")
    if #R.noShow > 0 then
      body(names(R.noShow, function(s) return esc(s.name) .. " (" .. tostring(s.kind) .. ")" end), ns.ORANGE)
      body(RECAP, ns.GREY)
    end
    head("At pulls without a sign-up (" .. #R.unsigned .. ")")
    if #R.unsigned > 0 then body(names(R.unsigned), ns.WHITE) end
  end
  body(NOTE, ns.GREY)
  return y
end

-- ev nil hides the pane, the chips and the bar line (the Sign-ups tab and the empty state).
function ns.DrawPulls(card, ev, layout, top, events)
  local V = rawget(card, "pullsView") or build(card)
  hideAll(V)
  if not ev then
    V.pane:Hide()
    V.bar:Hide()
    if V.barDiv then V.barDiv:Hide() end
    return
  end
  local L = layout or ns.Layout()
  local IW = L.viewW - 24
  local barY = L.cardH - 24 - 34
  top = top or 0
  at(V.pane, 12, -top)
  V.pane:SetSize(IW, math.max(1, barY - 10 - top))
  V.pane:Show()
  if V.key ~= ev.key then
    V.key = ev.key
    V.scroll:SetVerticalScroll(0)
  end
  local pulls = ns.PullRules.ForRaid(ns.PullList(), ev, events)
  local R = ns.PullRules.Lists(pulls, ev.signups or {}, ns.Key,
    function(n) local P = GuildSync.Comm.Person; return P and P(n) end)
  local chipsH = drawChips(V, pulls, IW)
  V.scroll:ClearAllPoints()
  V.scroll:SetPoint("TOPLEFT", V.pane, "TOPLEFT", 0, -chipsH)
  V.scroll:SetPoint("BOTTOMRIGHT", V.pane, "BOTTOMRIGHT", -SB, 4)
  V.child:SetWidth(IW - SB)
  V.child:SetHeight(math.max(10, drawLists(V, pulls, R, IW - SB)))
  -- the bar line under the rule at barY - 6, as the sign-ups bar; the second sentence goes when the line would not fit
  -- (the kinds-line rule, RaidView.lua); a client that cannot measure keeps it
  if V.barDiv then
    V.barDiv:ClearAllPoints()
    V.barDiv:SetPoint("TOPLEFT", card.body, "TOPLEFT", 12, -(barY - 6))
    V.barDiv:SetPoint("TOPRIGHT", card.body, "TOPRIGHT", -12, -(barY - 6))
    V.barDiv:Show()
  end
  at(V.bar, 12, -(barY + 1))
  V.bar:SetWidth(IW)
  -- d1238: the singular for one
  local short = #pulls .. (#pulls == 1 and " pull, " or " pulls, ") .. R.kills .. (R.kills == 1 and " kill." or " kills.")
  V.bar:SetText(short .. KEPT)
  local w = textWidth(V.bar)
  if w and w > IW then V.bar:SetText(short) end
  V.bar:Show()
end
