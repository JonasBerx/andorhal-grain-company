local _, ns = ...
if not ns.M then return end
-- InviteRules.lua: ticket 57 (stages 1, 4). The invite lists' rules, pure: who is wanted tonight (from the linked
-- roster or the sign-ups), how that compares with the group, the summary line, the plan's input and the missing
-- list. No client call, no state; Tools.lua feeds it the group reads and acts on the answer.

local INVITE_PENDING = 60
local INVITE_KINDS = { primary = true, late = true }
local STAND_KINDS = { bench = true, tentative = true }
local DOT = " \194\183 "

-- | and every control byte (a newline would split the chat box text) stripped.
local function noPipes(s) return (string.gsub(tostring(s or ""), "[|%c]", "")) end

local function row(name, key, signup)
  return { name = name, key = key, signup = signup, nosignup = signup == nil or nil,
    role = signup and signup.role or nil, class = signup and signup.class or nil }
end

-- ev, "roster" | "signups", keyOf(name) -> { source, list = { w }, standins = { w } }
local function Wanted(ev, source, keyOf)
  local signups = ev.signups or {}
  local lineup = ev.lineup
  local groups = type(lineup) == "table" and type(lineup.groups) == "table" and lineup.groups or nil
  local list, standins = {}, {}
  if source ~= "roster" or not groups then
    for _, s in ipairs(signups) do
      local name = s.character or ""
      if INVITE_KINDS[s.kind] then
        if name == "" then
          list[#list + 1] = { name = s.discord or "", nochar = true, signup = s, role = s.role, class = s.class }
        else
          list[#list + 1] = row(name, s.key or keyOf(name), s)
        end
      elseif STAND_KINDS[s.kind] and name ~= "" then
        standins[#standins + 1] = row(name, s.key or keyOf(name), s)
      end
    end
    return { source = "signups", list = list, standins = standins }
  end
  local byKey = {}
  for _, s in ipairs(signups) do
    local name = s.character or ""
    if name ~= "" then
      local k = s.key or keyOf(name)
      if byKey[k] == nil then byKey[k] = s end
    end
  end
  local seen = {}
  for gi, g in ipairs(groups) do
    for si = 1, 5 do -- an empty seat is false: ipairs would stop there
      local seat = type(g) == "table" and g[si] or nil
      if type(seat) == "table" and type(seat.name) == "string" and seat.name ~= "" then
        local k = seat.key or keyOf(seat.name)
        if not seen[k] then
          seen[k] = true
          local w = row(seat.name, k, byKey[k])
          w.group, w.role, w.class = gi, seat.role or w.role, seat.class or w.class
          list[#list + 1] = w
        end
      end
    end
  end
  local function stand(name, k, s)
    if seen[k] then return end
    seen[k] = true
    standins[#standins + 1] = row(name, k, s)
  end
  for _, r in ipairs(type(lineup.reserve) == "table" and lineup.reserve or {}) do
    local name = type(r) == "table" and r.name or r
    if type(name) == "string" and name ~= "" then
      local k = type(r) == "table" and r.key or keyOf(name)
      stand(name, k, byKey[k])
    end
  end
  for _, kinds in ipairs({ INVITE_KINDS, STAND_KINDS }) do
    for _, s in ipairs(signups) do
      local name = s.character or ""
      if name ~= "" and kinds[s.kind] then stand(name, s.key or keyOf(name), s) end
    end
  end
  return { source = "roster", list = list, standins = standins }
end

local function copy(w)
  local out = {}
  for k, v in pairs(w) do out[k] = v end
  return out
end

-- wanted, { raid, kind, me, now, pending, member(name), inGroupOf(name) } -> st
local function Compare(wanted, inp)
  local pending, t = inp.pending or {}, inp.now or 0
  local inRaid = {}
  for _, r in ipairs(inp.raid or {}) do if r.key then inRaid[r.key] = r end end
  local function state(w)
    if not w.key then return "unknown" end
    if w.key == inp.me or inRaid[w.key] then return "in" end
    if not inp.raid and inp.inGroupOf and inp.inGroupOf(w.name) then return "in" end
    if pending[w.key] and t - pending[w.key] < INVITE_PENDING then return "invited" end
    local m = inp.member and inp.member(w.name)
    if not m then return "unknown" end
    return m.online and "online" or "offline"
  end
  local counts = { total = 0, ["in"] = 0, wrong = 0, invited = 0, online = 0, offline = 0, unknown = 0, extras = 0 }
  local list, wantedKeys = {}, {}
  for _, w in ipairs(wanted.list or {}) do
    local r = copy(w)
    r.state = state(w)
    if w.key then wantedKeys[w.key] = true end
    local at = w.key and inRaid[w.key]
    if r.state == "in" and at and wanted.source == "roster" and inp.kind == "raid" and at.group ~= w.group then
      r.wrong, r.at = true, at.group
      counts.wrong = counts.wrong + 1
    end
    counts.total = counts.total + 1
    counts[r.state] = counts[r.state] + 1
    list[#list + 1] = r
  end
  local standins, standKeys = {}, {}
  for _, w in ipairs(wanted.standins or {}) do
    if w.key then standKeys[w.key] = true end
    local s = state(w)
    if s == "online" or s == "invited" then
      local r = copy(w)
      r.state = s
      standins[#standins + 1] = r
    end
  end
  local extras = {}
  for _, r in ipairs(inp.raid or {}) do
    if r.key and r.key ~= inp.me and not wantedKeys[r.key] then
      extras[#extras + 1] = { name = r.name, key = r.key, group = r.group, standin = standKeys[r.key] or nil }
    end
  end
  counts.extras = #extras
  return { source = wanted.source, list = list, standins = standins, extras = extras, counts = counts }
end

-- st -> "In the raid 14 of 20 · wrong group 2 · ..."; a part whose count is 0 is left out, the first always shows.
local function Line(st)
  local n = st.counts or {}
  local parts = { "In the raid " .. (n["in"] or 0) .. " of " .. (n.total or 0) }
  for _, p in ipairs({ { "wrong", "wrong group " }, { "invited", "invited " }, { "online", "online, not in " },
      { "offline", "offline " }, { "unknown", "not in the guild roster " }, { "extras", "not on the list " } }) do
    local v = n[p[1]] or 0
    if v > 0 then parts[#parts + 1] = p[2] .. v end
  end
  return table.concat(parts, DOT)
end

local TAKEN = { ["in"] = true, invited = true, online = true }

-- st -> the plan's sign-ups: the in, invited and online rows in wanted order, then the extras (never invited).
local function AsSignups(st)
  local out = {}
  for _, w in ipairs(st.list or {}) do
    if TAKEN[w.state] then out[#out + 1] = { character = w.name, key = w.key, kind = "primary" } end
  end
  for _, x in ipairs(st.extras or {}) do out[#out + 1] = { character = x.name, key = x.key, kind = "extra" } end
  -- an invited stand-in holds a party seat too; never invited from here
  for _, x in ipairs(st.standins or {}) do
    if x.state == "invited" then out[#out + 1] = { character = x.name, key = x.key, kind = "extra" } end
  end
  return out
end

local MISSING = { invited = true, online = true, offline = true, unknown = true }

-- st, max -> "Missing: A, B" and the number cut (0 when none), at most max bytes, cut between names; nil when nobody.
local function MissingText(st, max)
  local names = {}
  for _, w in ipairs(st.list or {}) do
    -- a Discord-only row (nochar) stays out: its Discord name is never put into game chat
    if MISSING[w.state] and not w.nochar then names[#names + 1] = noPipes(w.name) end
  end
  if #names == 0 then return nil end
  local full = "Missing: " .. table.concat(names, ", ")
  if #full <= max then return full, 0 end
  local kept = #names - 1
  while kept > 0 do
    local text = "Missing: " .. table.concat(names, ", ", 1, kept) .. " (+" .. (#names - kept) .. " more)"
    if #text <= max then return text, #names - kept end
    kept = kept - 1
  end
  return "Missing: (+" .. #names .. " more)", #names
end

ns.InviteRules = { Wanted = Wanted, Compare = Compare, Line = Line, AsSignups = AsSignups, MissingText = MissingText }
