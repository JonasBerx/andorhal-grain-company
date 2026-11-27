local _, ns = ...
if not ns.M then return end

-- RollRules.lua: the pure rules of a loot roll. No client calls and no clock: times are passed in. A refusal is
-- nil, why. st is the roll state RR.Open makes.
-- Exports ns.RollRules (RR), with the constants RANGES, ENGLISH, ROLLTIME, MINTIME, MAXTIME, EXTRA, CHATMAX,
-- OTHERSMAX, WHYMAX (the longest council reason, in bytes), REFMAX (the longest ref Record makes), MAXENTRIES (the
-- most not-counted lines Add stores per round) and:
--   RR.ParseRoll(line, fmt) -> { name, roll, lo, hi } | nil    a /roll system line, fmt nil reads ENGLISH
--   RR.RollTime(v) -> seconds        RR.Open(t, opts) -> st    opts { item, suffix, count, rollTime, group, fill }
--   RR.Add(st, r, t) -> entry | nil, why                       RR.Typed(st, t, r) -> entry | nil, why
--     Add judges first and never refuses a roll that counts. It refuses "roll" (outside lo..hi or not whole); of the
--     lines that do not count it stores at most 3 per player per round ("repeat") and MAXENTRIES per round over all
--     players ("full"), and each line it drops this way raises st.dropped. Again starts the round's counts again.
--     Typed is never limited and also works after the time limit and after Close.
--   RR.Pick(st, i) / RR.Down(st, i) / RR.SetFill(st, key, on) -> true | nil, why   the leader's hand
--   RR.More(st, t) -> closesAt       RR.Close(st, t)           RR.IsOpen(st, t) -> bool    RR.Unread(st, n, t)
--   RR.Rank(st) -> entries           RR.Result(st) -> { kind, winners, tied, places, left, hi }  kind win, tie, de,
--     none; left = the copies nobody won (count less winners)
--   RR.Again(st, t, rollTime) -> true | nil, why               a roll-off of a tie
--   RR.Record(st, pick, at, session, n, place) -> award | nil, "ref" (ref over REFMAX, never cut)    RR.Correction(pick) -> fix    RR.DoneText(rec) -> text
--   RR.CouncilRecord(row, pick, at, session, place) -> award | nil, why ("who", "why", "others", "ref")    row { item,
--     suffix, n }, pick { who, why, others }
--   RR.CouncilWhy(case, why) -> why    case "time" | "nobody" (a council item rolled), any other case answers why
--   RR.OpenLine(itemText, seconds), RR.AgainLine(itemText, names), RR.WinLine(itemText, recs) -> chat line
--   RR.Channel(groupKind, leads) -> "RAID_WARNING" | "RAID" | "PARTY" | nil
-- Groups rank first to last: 1 team main spec, 2 fill-in main spec, 3 off spec, 4 disenchant.

local RR = { RANGES = { [100] = "ms", [99] = "os", [98] = "de" }, ENGLISH = "%s rolls %d (%d-%d)", ROLLTIME = 20,
  MINTIME = 10, MAXTIME = 60, EXTRA = 10, CHATMAX = 255, OTHERSMAX = 120, WHYMAX = 200, REFMAX = 64,
  MAXENTRIES = 80 }
ns.RollRules = RR

local PERPLAYER = 3 -- not-counted lines stored per player per round
local HOW = { "ms", "ms", "os", "de" }
local GROUPHI = { 100, 100, 99, 98 }
local LABEL = { ms = "main spec", os = "off spec", de = "disenchant", council = "council" }

local function isInt(v) return type(v) == "number" and v == math.floor(v) end
local function text(v) return type(v) == "string" and v or "" end
-- A name that may go into a chat line: a non-empty string with no "|" (no escape codes).
local function clean(n) return type(n) == "string" and n ~= "" and not n:find("|", 1, true) end

-- list of strings joined by sep, whole items only, at most max bytes.
local function join(list, sep, max)
  local out = ""
  for _, s in ipairs(list) do
    local nx = out == "" and s or out .. sep .. s
    if #nx > max then break end
    out = nx
  end
  return out
end

-- ---------- parse ----------

-- fmt (a RANDOM_ROLL_RESULT style format) -> { pat, map } where map[j] is the field slot (1 name, 2 roll, 3 lo, 4 hi)
-- of capture j; false when fmt is not a roll format with all four slots.
local function compile(fmt)
  local out, map, auto, i = { "^" }, {}, 0, 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == "%" and fmt:sub(i + 1, i + 1) == "%" then
      out[#out + 1] = "%%"
      i = i + 2
    elseif c == "%" then
      local pos, kind, nx = fmt:match("^(%d*)%$?([sd])()", i + 1)
      if not kind then return false end
      auto = auto + 1
      map[#map + 1] = tonumber(pos) or auto
      out[#out + 1] = kind == "s" and "(.+)" or "(%d+)"
      i = nx
    else
      out[#out + 1] = c:find("^[%^%$%(%)%.%[%]%*%+%-%?]") and "%" .. c or c
      i = i + 1
    end
  end
  local slots = {}
  for _, s in ipairs(map) do slots[s] = true end
  if #map ~= 4 or not (slots[1] and slots[2] and slots[3] and slots[4]) then return false end
  return { pat = table.concat(out) .. "$", map = map }
end

local patterns = {}

-- A system chat line -> { name, roll, lo, hi }, or nil when it is not a roll line. fmt nil reads RR.ENGLISH.
function RR.ParseRoll(line, fmt)
  if fmt == nil then fmt = RR.ENGLISH end
  if type(line) ~= "string" or type(fmt) ~= "string" then return nil end
  local p = patterns[fmt]
  if p == nil then
    p = compile(fmt)
    patterns[fmt] = p
  end
  if not p then return nil end
  local caps, v = { line:match(p.pat) }, {}
  for j, slot in ipairs(p.map) do v[slot] = caps[j] end
  local out = { name = v[1], roll = tonumber(v[2]), lo = tonumber(v[3]), hi = tonumber(v[4]) }
  if not (out.name and out.roll and out.lo and out.hi) then return nil end
  return out
end

-- ---------- open and judge ----------

-- A whole number of seconds from MINTIME to MAXTIME, else ROLLTIME.
function RR.RollTime(v)
  if isInt(v) and v >= RR.MINTIME and v <= RR.MAXTIME then return v end
  return RR.ROLLTIME
end

function RR.Open(t, opts)
  opts = type(opts) == "table" and opts or {}
  t = type(t) == "number" and t or 0
  local secs = RR.RollTime(opts.rollTime)
  return { item = opts.item, suffix = opts.suffix, count = isInt(opts.count) and opts.count >= 1 and opts.count or 1,
    rollTime = secs, group = type(opts.group) == "table" and opts.group or {},
    fill = type(opts.fill) == "table" and opts.fill or {}, openedAt = t, closesAt = t + secs, round = 1, entries = {},
    settled = {}, unread = 0, dropped = 0 }
end

local function groupOf(st, key, hi)
  if hi == 100 then return st.fill[key] and 2 or 1 end
  return hi == 99 and 3 or 4
end

-- The player's counted roll in the current round, if any.
local function countedOf(st, key)
  for _, x in ipairs(st.entries) do
    if x.round == st.round and x.counted and x.key == key then return x end
  end
end

local function already(x) return "already rolled " .. x.roll .. ", " .. LABEL[HOW[x.group]] end

-- The range hi when lo-hi is one of RANGES, else nil.
local function rangeHi(e) return e.lo == 1 and RR.RANGES[e.hi] and e.hi or nil end

-- Sets round, at, counted, why and (when counted) group on e. typed: entered by hand, so neither the time limit nor
-- Close applies (the window stops offering it once the roll is assigned).
local function judge(st, e, t, typed)
  e.round, e.at, e.counted = st.round, t, false
  local hi = rangeHi(e)
  if not st.group[e.key] then
    e.why = "not in the group"
  elseif not typed and (st.closed or t >= st.closesAt) then
    e.why = "too late"
  elseif st.tie and not st.tie[e.key] then
    e.why = "not in the tie"
  elseif not hi or (st.tie and hi ~= st.tieHi) then
    e.why = e.lo .. "-" .. e.hi
  else
    local prior = countedOf(st, e.key)
    if prior then
      e.why = already(prior)
    else
      e.counted, e.group = true, groupOf(st, e.key, hi)
    end
  end
  return e
end

-- roll = { name, key, roll, lo, hi } -> the stored entry (counted or not, with why). A roll that counts is always
-- stored; a line that does not count is dropped (st.dropped + 1) past PERPLAYER of that key or MAXENTRIES in all this
-- round.
function RR.Add(st, r, t)
  if type(r) ~= "table" or type(r.name) ~= "string" or type(r.key) ~= "string" or not isInt(r.lo)
    or not isInt(r.hi) or type(t) ~= "number" then
    return nil, "not a roll"
  end
  if not isInt(r.roll) or r.roll < r.lo or r.roll > r.hi then return nil, "roll" end
  local e = judge(st, { name = r.name, key = r.key, roll = r.roll, lo = r.lo, hi = r.hi }, t, false)
  if not e.counted then
    local all, mine = 0, 0
    for _, x in ipairs(st.entries) do
      if x.round == e.round and not x.counted then
        all = all + 1
        if x.key == e.key then mine = mine + 1 end
      end
    end
    local why = mine >= PERPLAYER and "repeat" or all >= RR.MAXENTRIES and "full" or nil
    if why then
      st.dropped = (st.dropped or 0) + 1
      return nil, why
    end
  end
  st.entries[#st.entries + 1] = e
  return e
end

-- A roll typed in by the leader: { name, key, roll, hi }, lo is 1. Stored only when it counts.
function RR.Typed(st, t, r)
  if type(r) ~= "table" or type(r.name) ~= "string" or type(r.key) ~= "string" or type(t) ~= "number" then
    return nil, "not a roll"
  end
  if not RR.RANGES[r.hi] then return nil, "not a roll range" end
  if not isInt(r.roll) or r.roll < 1 or r.roll > r.hi then return nil, "roll 1 to " .. r.hi end
  local e = judge(st, { name = r.name, key = r.key, roll = r.roll, lo = 1, hi = r.hi, byHand = true }, t, true)
  if not e.counted then return nil, e.why end
  st.entries[#st.entries + 1] = e
  return e
end

-- ---------- by hand ----------

-- Makes entry i the player's counted roll in this round; the player's other counted roll stops counting.
function RR.Pick(st, i)
  local e = st.entries[i]
  if type(e) ~= "table" then return nil, "no such roll" end
  if e.round ~= st.round then return nil, "not in this round" end
  local hi = rangeHi(e)
  if not st.group[e.key] then return nil, "not in the group" end
  if st.tie and not st.tie[e.key] then return nil, "not in the tie" end
  if not hi then return nil, "not a roll range" end
  e.counted, e.why, e.byHand, e.group = true, nil, true, groupOf(st, e.key, hi)
  for _, x in ipairs(st.entries) do
    if x ~= e and x.round == st.round and x.key == e.key and x.counted then
      x.counted, x.why = false, already(e)
    end
  end
  return true
end

-- Moves a counted main-spec roll of this round to off spec.
function RR.Down(st, i)
  local e = st.entries[i]
  if type(e) ~= "table" then return nil, "no such roll" end
  if e.round ~= st.round then return nil, "not in this round" end
  if not e.counted or e.group > 2 then return nil, "not main spec" end
  e.group, e.byHand = 3, true
  return true
end

-- Marks key as a fill-in (on) or a team member; its counted main-spec roll moves group with it.
function RR.SetFill(st, key, on)
  if type(key) ~= "string" then return nil, "no player" end
  st.fill[key] = on and true or nil
  local e = countedOf(st, key)
  if e and e.group <= 2 then e.group = on and 2 or 1 end
  return true
end

-- ---------- time ----------

function RR.More(st, t)
  if type(t) ~= "number" then return st.closesAt end
  st.closesAt = math.max(st.closesAt, t) + RR.EXTRA
  return st.closesAt
end

function RR.Close(st, t)
  st.closed, st.closedAt = true, t
end

function RR.IsOpen(st, t)
  return not st.closed and type(t) == "number" and t < st.closesAt
end

-- The count of rollers not yet read rises while the roll is not closed, up to and at closesAt; frozen after.
function RR.Unread(st, n, t)
  if isInt(n) and n >= 0 and type(t) == "number" and not st.closed and t <= st.closesAt then st.unread = n end
end

-- ---------- outcome ----------

-- The current round's entries: counted by group, roll (high first), name; then the rest in arrival order.
function RR.Rank(st)
  local good, bad = {}, {}
  for _, e in ipairs(st.entries) do
    if e.round == st.round then
      if e.counted then good[#good + 1] = e else bad[#bad + 1] = e end
    end
  end
  table.sort(good, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    if a.roll ~= b.roll then return a.roll > b.roll end
    return a.name < b.name
  end)
  for _, e in ipairs(bad) do good[#good + 1] = e end
  return good
end

local function same(a, b) return a and b and a.group == b.group and a.roll == b.roll end

-- { kind, winners, tied, places, left, hi }: winners hold the places settled in earlier rounds first; a tie at the cut
-- gives the places above it as winners, the equal rolls as tied and hi as their range; left is the copies nobody won.
-- A roll-off nobody answers is a win for the settled places alone.
function RR.Result(st)
  local c, winners = {}, {}
  for _, e in ipairs(RR.Rank(st)) do if e.counted then c[#c + 1] = e end end
  for _, s in ipairs(st.settled) do winners[#winners + 1] = s.entry end
  local p = st.count - #st.settled
  if #c == 0 then
    return { kind = #winners > 0 and "win" or "none", winners = winners, tied = {}, places = #winners,
      left = st.count - #winners }
  end
  if p >= 1 and same(c[p], c[p + 1]) then
    local tied = {}
    for _, e in ipairs(c) do
      if same(e, c[p]) then
        tied[#tied + 1] = e
      elseif #tied == 0 then
        winners[#winners + 1] = e
      end
    end
    return { kind = "tie", winners = winners, tied = tied, places = #winners, left = st.count - #winners,
      hi = GROUPHI[c[p].group] }
  end
  for i = 1, math.min(p, #c) do winners[#winners + 1] = c[i] end
  local kind = (#st.settled == 0 and c[1].group == 4) and "de" or "win"
  return { kind = kind, winners = winners, tied = {}, places = #winners, left = st.count - #winners }
end

-- A roll-off of the tied players: the places above the tie are settled, a new round opens for the tied keys only.
function RR.Again(st, t, rollTime)
  local res = RR.Result(st)
  if res.kind ~= "tie" then return nil, "no tie" end
  if type(t) ~= "number" then return nil, "no time" end
  for i = #st.settled + 1, #res.winners do st.settled[i] = { key = res.winners[i].key, entry = res.winners[i] } end
  st.tie = {}
  for _, e in ipairs(res.tied) do st.tie[e.key] = true end
  st.tieHi, st.round = res.hi, st.round + 1
  st.closesAt, st.closed = t + RR.RollTime(rollTime), nil
  return true
end

-- ---------- record ----------

-- pick = { entry } | { who, how, roll?, byHand = true } | { how = "bank" } -> the award table for the loot log.
function RR.Record(st, pick, at, session, n, place)
  if type(pick) ~= "table" then return nil, "no pick" end
  local ref = tostring(session) .. "." .. tostring(n) .. "." .. tostring(place)
  if #ref > RR.REFMAX then return nil, "ref" end
  local t, e = { item = st.item, suffix = st.suffix, at = at, ref = ref }, pick.entry
  if pick.how == "bank" then
    t.how = "bank"
  elseif type(e) == "table" then
    t.who, t.how, t.roll = e.name, HOW[e.group], e.roll
    if e.byHand then t.why = "by hand" end
    local others = {}
    for _, x in ipairs(RR.Rank(st)) do
      if x.counted and x.key ~= e.key then others[#others + 1] = x.name end
    end
    local s = join(others, ", ", RR.OTHERSMAX)
    if s ~= "" then t.others = s end
  else
    t.who, t.how, t.roll, t.why = pick.who, pick.how, pick.roll, "by hand"
  end
  return t
end

local CASE = { time = "council: no decision in two minutes", nobody = "council: no Raider wanted it" }

-- A council decision -> the award table for the loot log, the ref shaped as RR.Record's.
function RR.CouncilRecord(row, pick, at, session, place)
  if type(row) ~= "table" or type(pick) ~= "table" then return nil, "no pick" end
  if not clean(pick.who) then return nil, "who" end
  if type(pick.why) ~= "string" or pick.why == "" or #pick.why > RR.WHYMAX then return nil, "why" end
  local others = text(pick.others)
  if #others > RR.OTHERSMAX then return nil, "others" end
  local ref = tostring(session) .. "." .. tostring(row.n) .. "." .. tostring(place)
  if #ref > RR.REFMAX then return nil, "ref" end
  return { item = row.item, suffix = row.suffix, who = pick.who, how = "council", why = pick.why,
    others = others ~= "" and others or nil, at = at, ref = ref }
end

-- The why of a council item that was rolled instead; why is RR.Record's (nil or "by hand").
function RR.CouncilWhy(case, why)
  local s = CASE[case]
  if not s then return why end
  return why and s .. ", " .. why or s
end

-- The change sent for an award set by hand: every field named, false for none.
function RR.Correction(pick)
  if type(pick) ~= "table" then return nil, "no pick" end
  local e = type(pick.entry) == "table" and pick.entry or {}
  local bank = pick.how == "bank"
  return { who = not bank and (pick.who or e.name) or false, how = pick.how or HOW[e.group],
    roll = not bank and (pick.roll or e.roll) or false, why = "by hand" }
end

local function rollText(rec)
  return (LABEL[rec.how] or "?") .. (type(rec.roll) == "number" and " " .. rec.roll or "")
end

function RR.DoneText(rec)
  if type(rec) ~= "table" then return "" end
  if rec.how == "bank" then return "Guild bank" end
  if rec.how == "council" then return text(rec.who) .. ", council" end
  local why = text(rec.why)
  local hand = why == "by hand" or why:sub(-#", by hand") == ", by hand"
  return text(rec.who) .. ", " .. rollText(rec) .. (hand and " (by hand)" or "")
end

-- ---------- chat ----------

function RR.OpenLine(itemText, seconds)
  return "Roll for " .. text(itemText) .. ": /roll 100 main spec, /roll 99 off spec, /roll 98 disenchant. "
    .. (isInt(seconds) and seconds or RR.ROLLTIME) .. " s."
end

function RR.AgainLine(itemText, names)
  local list = {}
  for _, n in ipairs(type(names) == "table" and names or {}) do
    if clean(n) then list[#list + 1] = n end
  end
  local head = "Roll again for " .. text(itemText) .. ": "
  return head .. join(list, ", ", RR.CHATMAX - #head)
end

function RR.WinLine(itemText, recs)
  local pieces = {}
  for _, r in ipairs(type(recs) == "table" and recs or {}) do
    if type(r) == "table" and r.how == "bank" then
      pieces[#pieces + 1] = "the guild bank"
    elseif type(r) == "table" and clean(r.who) then
      pieces[#pieces + 1] = r.who .. " (" .. rollText(r) .. ")"
    end
  end
  local head = text(itemText) .. " goes to "
  return head .. join(pieces, ", ", RR.CHATMAX - #head)
end

function RR.Channel(groupKind, leads)
  if groupKind == "raid" then return leads and "RAID_WARNING" or "RAID" end
  if groupKind == "party" then return "PARTY" end
  return nil
end
