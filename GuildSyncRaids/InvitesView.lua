local _, ns = ...
if not ns.M then return end
-- InvitesView.lua: ticket 57 (stages 1, 4). The Tonight section at the top of the Sign-ups panel (ns.DrawInviteLists,
-- drawn only through the panel's P.draw helpers) and the summary in the Groups tab's slot (ns.DrawInvites). Nothing
-- acts without a click: Invite, Whisper, Copy missing and the source switch run only from OnClick, each through a
-- function looked up on ns at click time (Tools.lua holds the acting side, InviteRules.lua the rules).

local M = ns.M
local K = M.Kit
local T = K.Tokens.text -- a text role is read in a function only (made on the first read)
local STALE = "In combat, last read: "
local NONE = "In combat: the group is read after the fight."

local function noPipes(s) return (string.gsub(tostring(s or ""), "|", "")) end

-- The summary line of st: "In combat, last read: " before a stale read; the combat line when there is no read.
local function lineOf(st)
  if st.none then return NONE end
  local R = ns.InviteRules
  local text = (type(R) == "table" and type(R.Line) == "function") and R.Line(st) or ""
  return st.stale and (STALE .. text) or text
end

-- A row's role word: the sign-up's role when it has one, else the seat's letter as a word (never a bare letter).
local SEAT_ROLE = { T = "Tank", H = "Healer", D = "DPS" }
local function roleOf(w)
  local s = w.signup and w.signup.role
  if type(s) == "string" and s ~= "" then return s end
  return SEAT_ROLE[w.role] or w.role
end

local function hasLineup(ev) return type(ev.lineup) == "table" and type(ev.lineup.groups) == "table" end

-- ev, st (ns.InviteState), D = { PW, roleShown, nameW, ev, rows, me }, py, t -> py below the section.
function ns.DrawInviteLists(P, ev, st, D, py, t)
  local d = P.draw
  py = d.line(lineOf(st), py)
  if st.none then return py end -- no read in combat: nothing made up
  -- the button row: Copy missing and, with a lineup, the source switch
  d.button("Copy missing", 10, py, 110, function()
    local copy = ns.CopyMissing
    if type(copy) ~= "function" then return end
    local line = copy(ev)
    if line then d.say(line) end
  end)
  if hasLineup(ev) then
    local source = ns.InviteSource
    local cur = type(source) == "function" and source(ev) or "signups"
    d.button(cur == "roster" and "From roster" or "From sign-ups", 124, py, 110, function()
      local set = ns.SetInviteSource
      if type(set) ~= "function" then return end
      local done, why = set(cur == "roster" and "signups" or "roster")
      if not done then
        if why then d.say(why) end
        return
      end
      d.first()
      M.RefreshPage()
    end)
  end
  py = py + 26
  -- the sections
  local title = noPipes(ev.title)
  local SIGNED = "Raid tonight: " .. title .. ". You are signed up: an invite is on its way, or whisper me."
  local ROSTER = "Raid tonight: " .. title .. ". You are on the roster: an invite is on its way, or whisper me."
  local SIGNUP = "Raid tonight: " .. title .. ". Please sign up on Discord (Raid-Helper) or tell me if you can't come."
  local tl = ns.TonightLists
  local lists = type(tl) == "function" and tl(ev, D.me, t, date) or nil
  local may = lists and lists.mayInvite and true or false
  local nameW = (D.roleShown and 150 or D.PW - 156) - 34 - 6

  local function heading(text, n, always)
    if n == 0 and not always then return false end
    d.heading(n == 0 and (text .. ": nobody") or (text .. " (" .. n .. ")"), py)
    py = py + 18
    return true
  end
  -- One row: with words, a button row (Whisper, and Invite when invite) as today's Tonight rows; else a plain line.
  local function row(w, words, invite, marker)
    local f
    local role = roleOf(w)
    if words then
      if role then d.icon(role, py + 4) end
      f = d.name(w.name, py + 6, nameW)
      d.role(D, role, 150, py + 6)
      local member = d.rowOf(D.rows or {}, w.name) -- whisper the guild's spelling, the name Invite reaches
      local plain = noPipes(member and member.name or w.name)
      d.button("Whisper", D.PW - 156, py, 80, function()
        local whisper = ns.Whisper
        if type(whisper) == "function" then whisper(plain, words) end
      end)
      if invite then
        local s = { character = w.name, key = w.key, kind = "primary" }
        local b = d.button("Invite", D.PW - 70, py, 70, function()
          local click = ns.InviteClick
          if may and type(click) == "function" then d.say(click(ev, s)) end
        end)
        b:SetEnabled(may)
      end
      py = py + 26
    else
      if role then d.icon(role, py) end
      f = d.name(w.name, py + 2, nameW)
      py = py + 17
    end
    d.colour(f, d.rowOf(D.rows or {}, w.name), w.class)
    if marker then d.marker(f, marker) end
  end
  local function pick(list, test)
    local out = {}
    for _, w in ipairs(list or {}) do if test(w) then out[#out + 1] = w end end
    return out
  end
  local function noSignup(w) return w.nosignup and "(no sign-up)" or nil end

  local online = pick(st.list, function(w) return w.state == "online" end)
  local headY = py
  heading("Tonight: online, not in the raid", #online, true)
  d.note(st.source == "roster" and "roster seats" or "primary and late sign-ups", headY)
  for _, w in ipairs(online) do row(w, w.signup and SIGNED or ROSTER, true, noSignup(w)) end
  local wrong = pick(st.list, function(w) return w.wrong end)
  if heading("Tonight: in the wrong group", #wrong) then
    for _, w in ipairs(wrong) do row(w, nil, false, "group " .. tostring(w.at) .. ", planned " .. tostring(w.group)) end
  end
  for _, s in ipairs({ { "invited", "Tonight: invited" }, { "offline", "Tonight: offline" },
      { "unknown", "Tonight: not in the guild roster" } }) do
    local rows = pick(st.list, function(w) return w.state == s[1] end)
    if heading(s[2], #rows) then
      for _, w in ipairs(rows) do row(w, nil, false, noSignup(w)) end
    end
  end
  local standins = st.standins or {}
  if heading("Tonight: stand-ins online", #standins) then
    for _, w in ipairs(standins) do row(w, w.signup and SIGNED or ROSTER, true, noSignup(w)) end
  end
  local extras = st.extras or {}
  if heading("Tonight: in the raid, not on the list", #extras) then
    for _, x in ipairs(extras) do row(x, nil, false, x.standin and "(stand-in)" or nil) end
  end
  local listed = {} -- a seated player with no answer is listed once, on the wanted list or among the stand-ins
  for _, group in ipairs({ st.list or {}, standins }) do
    for _, w in ipairs(group) do if w.key then listed[w.key] = true end end
  end
  local notSigned = {}
  for _, r in ipairs(lists and lists.notSigned or {}) do
    local key = ns.Key
    local k = type(key) == "function" and key(r.name) or nil
    if not (k and listed[k]) then notSigned[#notSigned + 1] = r end
  end
  heading("Tonight: online, not signed up", #notSigned, true)
  for _, r in ipairs(notSigned) do row({ name = r.name }, SIGNUP, false) end
  return py
end

-- Ticket 56's slot on the Groups tab: the summary line and an Invites button that picks the Sign-ups tab, for a
-- viewer on a complete raid tonight with room for a button; otherwise everything it made is hidden. Never throws.
function ns.DrawInvites(box, ev)
  if type(box) ~= "table" then return end
  M.Safe(function() -- a fault is recorded by the hub, never thrown
    local w = box.gsInvites
    if type(w) ~= "table" then w = nil end -- a frame may answer a method for an unknown field
    local function hide()
      if w then w.line:Hide(); w.button:Hide() end
    end
    local t = M.Compat.call("GetServerTime")
    local sees, tonight, state = ns.SeesInvites, ns.Tonight, ns.InviteState
    local h = box:GetHeight()
    if not (type(ev) == "table" and ev.complete and type(t) == "number" and type(h) == "number" and h >= 22
        and type(sees) == "function" and sees() == true and type(tonight) == "function" and tonight(ev, t, date)
        and type(state) == "function") then
      return hide()
    end
    local st = state(ev, t)
    if type(st) ~= "table" then return hide() end
    if not w then
      w = { line = ns.Label(box, T.highlightSmall), button = K.Button(box, "Invites", 80) }
      w.line:SetWordWrap(true)
      w.line:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3])
      w.button:SetScript("OnClick", function()
        M.Safe(function()
          local ps = ns.PageState
          if type(ps) == "table" then ps.tab = "signups" end
          M.RefreshPage()
        end)
      end)
      box.gsInvites = w
    end
    w.button:ClearAllPoints()
    w.button:SetPoint("TOPRIGHT", 0, 0)
    w.button:Show()
    w.line:ClearAllPoints()
    w.line:SetPoint("TOPLEFT", 0, -4)
    w.line:SetWidth(math.max(1, (box:GetWidth() or 0) - 88))
    w.line:SetHeight(math.min(h, 28))
    w.line:SetText(lineOf(st))
    w.line:Show()
  end)
end
