local _, ns = ...
if not ns.M then return end

-- The chosen raid's lower half (right card, plan Task 5): the people panel (a black .35 fill and its own ScrollFrame)
-- with the sign-ups by kind and No answer (bench included); for an officer on a raid today the two Tonight lists with
-- Whisper and Invite per row (d368); the officer's invite bar above the card's bottom rim. Everything is drawn on
-- card.body. A name is its own FontString, only ns.Escape'd, its class colour set with SetTextColor (d635); the grey
-- "(online)" / "(offline)" marker is a second FontString. Nothing runs without a click: Whisper, Invite and Invite
-- next sign-ups act only from OnClick, through ns.Whisper and ns.InviteClick (Tools.lua), looked up at call time.

local M = ns.M
local K = M.Kit
local SB = 22 -- the scrollbar's room on the right (plan section 2)
local KINDS = { "primary", "late", "tentative", "bench", "absence" }
local KIND_TITLE = { primary = "Primary", late = "Late", tentative = "Tentative", bench = "Bench", absence = "Absence" }
local ROLE_ICON = { Tank = "tank", Healer = "heal", ["Melee DPS"] = "dps", ["Ranged DPS"] = "dps" }
local NOT_IN = "Tonight: online, not in the raid"
local NOT_SIGNED = "Tonight: online, not signed up"

local function esc(s) return ns.Escape(tostring(s or "")) end
local function noPipes(s) return (string.gsub(tostring(s or ""), "|", "")) end
local function grey(fs) fs:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3]) end

-- A divider across its parent at y, x in from both edges (K.Divider may answer nil).
local function rule(d, x, y)
  if not d then return end
  d:ClearAllPoints()
  d:SetPoint("TOPLEFT", x, y)
  d:SetPoint("TOPRIGHT", -x, y)
  d:Show()
end

local function at(f, x, y, point)
  f:ClearAllPoints()
  f:SetPoint(point or "TOPLEFT", x, y)
end

-- The roster row of a character name, or nil.
local function rowOf(rows, name)
  local key = name and ns.Key(name)
  return key and rows[key] or nil
end

-- The class colour of a name: the roster row r's class, else the sign-up's class upper-cased; white without a colour.
-- RAID_CLASS_COLORS is FrameXML (not in the API dataset): read guarded, as 0.2 read GameTooltip.
local function colour(fs, r, signupClass)
  local token = (r and r.class) or string.upper(tostring(signupClass or ""))
  local all = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS or nil
  local cc = all and token ~= "" and all[token]
  if type(cc) == "table" and cc.r then
    fs:SetTextColor(cc.r, cc.g, cc.b)
  else
    fs:SetTextColor(1, 1, 1)
  end
end

-- ---------- pools (frames are reused on every draw) ----------

-- The next frame of P's kind pool, made on first use, shown.
local function take(P, kind)
  local pool = P.pools[kind]
  pool.n = pool.n + 1
  local f = pool[pool.n]
  if not f then
    f = P.make[kind]()
    pool[pool.n] = f
  end
  f:Show()
  return f
end

local function resetPools(P)
  for _, pool in pairs(P.pools) do
    for i = 1, #pool do pool[i]:Hide() end
    pool.n = 0
  end
end

local function rowButton(parent)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetScript("OnClick", function(self) if self.gsClick then M.Safe(self.gsClick) end end)
  return b
end

function ns.BuildSignups(card)
  local body = card.body
  local P = {}
  card.signups = P
  P.panel = CreateFrame("Frame", nil, body)
  P.fill = P.panel:CreateTexture(nil, "ARTWORK")
  P.fill:SetAllPoints(P.panel)
  P.fill:SetColorTexture(0, 0, 0, 0.35)
  P.tile = P.panel:CreateTexture(nil, "ARTWORK", nil, 1)
  P.tile:SetPoint("TOPLEFT", P.panel, "TOPLEFT", 0, 0)
  P.tile:SetPoint("TOPRIGHT", P.panel, "TOPRIGHT", 0, 0)
  P.tile:SetHeight(3)
  K.Atlas(P.tile, "_UI-Frame-InnerTopTile")
  P.scroll, P.child = ns.ScrollArea(P.panel)
  P.scroll:SetPoint("TOPLEFT", P.panel, "TOPLEFT", 0, -4)
  P.scroll:SetPoint("BOTTOMRIGHT", P.panel, "BOTTOMRIGHT", -SB, 4)
  local child = P.child
  P.tonightDiv = K.Divider(child)
  P.note = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  grey(P.note)
  P.note:SetText("primary and late sign-ups")
  local function fs(font, isGrey)
    return function()
      local f = child:CreateFontString(nil, "OVERLAY", font)
      f:SetJustifyH("LEFT")
      f:SetWordWrap(false)
      if isGrey then grey(f) end
      return f
    end
  end
  P.make = {
    heads = fs("GameFontNormalSmall"), names = fs("GameFontHighlightSmall"), markers = fs("GameFontHighlightSmall", true),
    roles = fs("GameFontHighlightSmall", true),
    icons = function()
      local t = child:CreateTexture(nil, "ARTWORK")
      t:SetSize(14, 14)
      return t
    end,
    buttons = function() return rowButton(child) end,
  }
  P.pools = { heads = { n = 0 }, names = { n = 0 }, markers = { n = 0 }, roles = { n = 0 }, icons = { n = 0 },
    buttons = { n = 0 } }
  -- the officer's bar
  P.barDiv = K.Divider(body)
  P.result = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  P.result:SetJustifyH("LEFT")
  P.result:SetWordWrap(true)
  grey(P.result)
  P.invite = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
  P.invite:SetSize(160, 22)
  P.invite:SetText("Invite next sign-ups")
  P.invite:SetScript("OnClick", function()
    M.Safe(function() if P.ev then P.first = false; P.result:SetText(ns.InviteClick(P.ev)) end end)
  end)
  P.all = {}
  for _, k in ipairs({ "panel", "tonightDiv", "note", "barDiv", "result", "invite" }) do
    if P[k] then P.all[#P.all + 1] = P[k] end
  end
  for _, f in ipairs(P.all) do f:Hide() end
end

-- A role icon at (14, -y) by the role's atlas; hidden for a role it has none for.
local function icon(P, role, y)
  local key = ROLE_ICON[role]
  if not key then return end
  local t = take(P, "icons")
  at(t, 14, -y)
  K.Atlas(t, "groupfinder-icon-role-large-" .. key)
end

-- A name FontString at (34, -y), escaped.
local function nameText(P, text, y, width)
  local f = take(P, "names")
  at(f, 34, -y)
  f:SetWidth(width)
  f:SetText(esc(text))
  return f
end

-- The role FontString at (x, -y), only for a role with text and a panel wide enough (D.roleShown).
local function roleText(P, D, role, x, y)
  if (role or "") == "" or not D.roleShown then return end
  local rf = take(P, "roles")
  at(rf, x, -y)
  rf:SetText(esc(role))
end

-- One sign-up line (or a No answer line with role nil): icon, name, marker when the name has a roster row, role.
local function signupLine(P, rows, py, D, text, class, role, character)
  if role then icon(P, role, py) end
  local f = nameText(P, text, py + 2, D.nameW)
  local r = rowOf(rows, character)
  colour(f, r, class)
  if r then
    local m = take(P, "markers")
    m:ClearAllPoints()
    m:SetPoint("LEFT", f, "RIGHT", 4, 0)
    m:SetText(r.online and "(online)" or "(offline)")
  end
  roleText(P, D, role, D.PW - 180, py + 2)
end

local function heading(P, text, py)
  local h = take(P, "heads")
  at(h, 10, -py)
  h:SetText(text)
end

local function button(P, text, x, y, w, onClick)
  local b = take(P, "buttons")
  at(b, x, -y)
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetEnabled(true) -- a reused button may have been disabled by an earlier draw
  b.gsClick = onClick
  return b
end

-- One Tonight list: its heading, then a row per entry (name in class colour, no marker; Whisper; Invite with s).
local function tonightList(P, rows, py, D, title, list, words, may)
  heading(P, title .. (#list == 0 and ": nobody" or ""), py)
  py = py + 18
  for _, r in ipairs(list) do
    local s = r.s
    if s then icon(P, s.role, py + 4) end
    local f = nameText(P, r.name, py + 6, (D.roleShown and 150 or D.PW - 156) - 34 - 6)
    colour(f, rowOf(rows, r.name), s and s.class)
    roleText(P, D, s and s.role, 150, py + 6)
    local plain = noPipes(r.name)
    button(P, "Whisper", D.PW - 156, py, 80, function() ns.Whisper(plain, words) end)
    if s then
      local b = button(P, "Invite", D.PW - 70, py, 70, function()
        if may then P.first = false; P.result:SetText(ns.InviteClick(D.ev, s)) end
      end)
      b:SetEnabled(may and true or false)
    end
    py = py + 26
  end
  return py
end

function ns.DrawSignups(card, ev, view, rows, t, layout, top)
  local P = card.signups
  if not P then return end
  resetPools(P)
  for _, f in ipairs(P.all) do f:Hide() end
  P.ev = ev
  if not ev then
    P.key = nil
    return
  end
  rows = rows or {}
  local L = layout or ns.Layout()
  local IW = L.viewW - 24
  local PW = IW - SB
  local barY = L.cardH - 24 - 34
  local me = ns.MyKey()
  local officer = (me and ns.IsOfficer(me)) and true or false
  if P.key ~= ev.key then
    P.key = ev.key
    P.scroll:SetVerticalScroll(0)
    P.first = true -- the result line holds its first words until an invite click answers in it
  end
  -- the panel
  local y = top or 0
  local bottom = officer and (barY - 10) or (L.cardH - 24)
  P.panel:ClearAllPoints()
  P.panel:SetPoint("TOPLEFT", card.body, "TOPLEFT", 12, -y)
  P.panel:SetSize(IW, math.max(1, bottom - y))
  P.panel:Show()
  P.child:SetWidth(PW)
  local D = { PW = PW, roleShown = PW >= 390, ev = ev }
  D.nameW = (D.roleShown and PW - 180 or PW) - 34 - 70
  local py = 6
  for _, k in ipairs(KINDS) do
    local list = {}
    for _, s in ipairs(ev.signups or {}) do if s.kind == k then list[#list + 1] = s end end
    if #list > 0 then
      heading(P, KIND_TITLE[k] .. " (" .. #list .. ")", py)
      py = py + 16
      for _, s in ipairs(list) do
        local char = (s.character or "") ~= "" and s.character or nil
        signupLine(P, rows, py, D, char or s.discord, s.class, s.role or "", char)
        py = py + 17
      end
      py = py + 4
    end
  end
  local noAnswer = ev.noAnswer or {}
  heading(P, "No answer (bench included) (" .. #noAnswer .. ")", py)
  py = py + 16
  for _, n in ipairs(noAnswer) do
    signupLine(P, rows, py, D, n, nil, nil, n)
    py = py + 17
  end
  py = py + 4
  -- the Tonight lists: an officer, a complete raid, today
  if officer and ev.complete and ns.Tonight(ev, t, date) then
    rule(P.tonightDiv, 4, -py)
    py = py + 8
    local lists = ns.TonightLists(ev, me, t, date)
    local title = noPipes(ev.title)
    at(P.note, 0, -(py + 1), "TOPRIGHT")
    P.note:Show()
    py = tonightList(P, rows, py, D, NOT_IN, lists.notIn,
      "Raid tonight: " .. title .. ". You are signed up: an invite is on its way, or whisper me.", lists.mayInvite)
    py = tonightList(P, rows, py, D, NOT_SIGNED, lists.notSigned,
      "Raid tonight: " .. title .. ". Please sign up on Discord (Raid-Helper) or tell me if you can't come.", false)
  end
  P.child:SetHeight(math.max(10, py))
  -- the officer's bar
  if not officer then return end
  rule(P.barDiv, 12, -(barY - 6))
  at(P.result, 12, -(barY + 1))
  P.result:SetWidth(IW - 172)
  P.result:Show()
  if not ev.complete then
    P.first = true -- back to the first words once the raid is complete; the scroll stays (f4769)
    P.result:SetText("sign-ups still arriving")
    return
  end
  -- The first words follow the current batch (/gsraids batch, the Options dropdown) at every draw (f4768).
  if P.first then
    P.result:SetText("One click invites the next " .. (ns.DB().batch or 5) .. " online primary and late sign-ups.")
  end
  at(P.invite, -12, -(barY + 2), "TOPRIGHT")
  P.invite:Show()
end
