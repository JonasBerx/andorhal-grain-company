local _, ns = ...
if not ns.M then return end

-- Pure rules (plan "Newest wins, stale guard, snapshot", "Expiry, gone, compare"): the paste plan, the held data,
-- compare, the view, status, age, weeks, selfcheck. Built on ns.Codec. No client calls; only string, table, math.
-- records = { [key] = { rev, hash, by, body } }; gone = { [key] = { at, rev } }; now = epoch seconds.

local Codec = ns.Codec
local Rules = { STALE = 3600, FUTURE = 300, MAX_SHARE = 90 }
ns.Rules = Rules

local DAY, TEAM_DAYS, MAX_TEAMS, WARN_AGE = 86400, 15, 6, 6 * 3600
local KINDS = { "primary", "late", "tentative", "bench", "absence" }
local ROLE_CODE = { Tank = "T", Healer = "H", ["Melee DPS"] = "M", ["Ranged DPS"] = "R" }

local function isX(body) return string.sub(body or "", 1, 2) == "X," end
local function live(r, now) return r and type(r.body) == "string" and not Codec.Expired(r.body, now) end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- When a record stops being kept: its finish + 1 day, or (team lists and their X) its gen + 15 days.
local function expiry(body)
  local d = Codec.Decode(body)
  if not d then return nil end
  if d.finish then return d.finish + DAY end
  return d.gen + TEAM_DAYS * DAY
end

-- "25 min", "4 h", "3 d" (Page.lua words its age lines with it too).
local function duration(s)
  s = math.max(0, math.floor(s))
  if s < 3600 then return math.floor(s / 60) .. " min" end
  if s < 2 * DAY then return math.floor(s / 3600) .. " h" end
  return math.floor(s / DAY) .. " d"
end
Rules.Duration = duration

-- The held data: the non-expired record with the highest rev (its gen, at and by).
function Rules.Held(records, now)
  local best, bestRev, bestKey
  for key, r in pairs(records or {}) do
    if live(r, now) then
      local rev = tonumber(r.rev) or 0
      if not best or rev > bestRev or (rev == bestRev and key > bestKey) then
        local d = Codec.Decode(r.body)
        if d then best, bestRev, bestKey = { gen = d.gen, at = d.at, by = r.by }, rev, key end
      end
    end
  end
  return best
end

-- Newest wins (RAIDCAL-FORMAT.md:97): effective time is dataAt, or generatedAt when dataAt is unknown; a tie goes to
-- the later generatedAt. An identical (dataAt, generatedAt) is not newer.
local function newerThan(gen, at, held)
  local mine, theirs = tonumber(at) or gen, tonumber(held.at) or held.gen
  if mine ~= theirs then return mine > theirs end
  return gen > held.gen
end

local function eventName(ev)
  if ev.title and ev.title ~= "" then return ev.title .. " (" .. tostring(ev.id) .. ")" end
  return "event " .. tostring(ev.id)
end

-- Refusal order: stale, future, older, teams, parts, empty, records. Stale wins over older when both apply: it needs no
-- held data, and the fix is the same either way (copy it again from /officers/). A generatedAt or dataAt above
-- now + FUTURE would lock out every later paste as "older" (f1491).
function Rules.Plan(cal, records, now, by)
  records = records or {}
  local gen, at = cal.generatedAt, cal.dataAt
  local age = now - gen
  if age > Rules.STALE then return nil, "stale", { age = age } end
  if gen > now + Rules.FUTURE or (tonumber(at) or 0) > now + Rules.FUTURE then return nil, "future", {} end
  local held = Rules.Held(records, now)
  if held and not newerThan(gen, at, held) then return nil, "older", { held = held } end
  local teams = cal.teams or {}
  if #teams > MAX_TEAMS then return nil, "teams", {} end

  local put = {}
  local rb = { raids = 0, signups = 0, teams = #teams, records = 0, skipped = 0, gen = gen, at = at }
  for _, ev in ipairs(cal.events or {}) do
    local id = tostring(ev.id or "")
    if string.match(id, "^%d+$") and Codec.ValidKey("e" .. id) and ev.start and ev.finish then
      if ev.finish <= now - DAY then
        rb.skipped = rb.skipped + 1
      else
        local bodies = Codec.EncodeEvent(ev, gen, at)
        if not bodies then return nil, "parts", { name = eventName(ev) } end
        for key, body in pairs(bodies) do put[key] = body end
        rb.raids = rb.raids + 1
        for _, s in ipairs(ev.signups or {}) do
          for _, k in ipairs(KINDS) do if s.kind == k then rb.signups = rb.signups + 1 end end
        end
      end
    end
  end
  for i, team in ipairs(teams) do
    local bodies = Codec.EncodeTeam(team, i, gen, at)
    if not bodies then return nil, "parts", { name = tostring(team.name) } end
    for key, body in pairs(bodies) do put[key] = body end
  end

  -- Snapshot: every held, live, non-X key the paste does not make gets an X; an event only inside the paste's window.
  for key, r in pairs(records) do
    if not put[key] and Codec.ValidKey(key) and live(r, now) and not isX(r.body) then
      local d = Codec.Decode(r.body)
      if d and (string.sub(key, 1, 1) == "t" or (d.finish and d.finish > gen - DAY)) then
        put[key] = Codec.Cancel(r.body, gen, at)
      end
    end
  end
  if next(put) == nil then return nil, "empty", {} end

  -- Held-set cap: the put plus every kept live held key, X included.
  local total, xCount, oldest = count(put), 0, nil
  local function seeX(body)
    if not isX(body) then return end
    xCount = xCount + 1
    local e = expiry(body)
    if e and (not oldest or e < oldest) then oldest = e end
  end
  for _, body in pairs(put) do seeX(body) end
  for key, r in pairs(records) do
    if not put[key] and Codec.ValidKey(key) and live(r, now) then
      total = total + 1
      seeX(r.body)
    end
  end
  if total > Rules.MAX_SHARE then return nil, "records", { xCount = xCount, oldestExpiry = oldest } end

  rb.records = count(put)
  return { put = put, readback = rb }
end

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

-- Hello.lua's compare plus: invalid keys are never asked; a gone key or an expired held key is asked only at a rev
-- above the gone or held rev; only live held keys are offered.
function Rules.Compare(records, gone, entries, now)
  records, gone = records or {}, gone or {}
  local send, ask, theirs = {}, {}, {}
  for _, e in ipairs(entries or {}) do
    if Codec.ValidKey(e.key) then
      theirs[e.key] = e
      local r, g = records[e.key], gone[e.key]
      local rev = tonumber(e.rev) or 0
      if live(r, now) then
        if newer(rev, e.hash, r.rev, r.hash) then ask[#ask + 1] = { key = e.key, rev = r.rev } end
      elseif r or g then
        local floor = math.max(r and tonumber(r.rev) or 0, g and tonumber(g.rev) or 0)
        if rev > floor then ask[#ask + 1] = { key = e.key, rev = r and r.rev or 0 } end
      else
        ask[#ask + 1] = { key = e.key, rev = 0 }
      end
    end
  end
  local mine = {}
  for key, r in pairs(records) do
    if Codec.ValidKey(key) and live(r, now) then mine[#mine + 1] = key end
  end
  table.sort(mine)
  for _, key in ipairs(mine) do
    local e, r = theirs[key], records[key]
    if not e or newer(r.rev, r.hash, tonumber(e.rev) or 0, e.hash) then send[#send + 1] = key end
  end
  return send, ask
end

-- Parts of base key k: { [i] = decoded } for live, valid records.
local function gather(records, now, letter)
  local groups = {}
  for key, r in pairs(records or {}) do
    if string.sub(key, 1, 1) == letter and Codec.ValidKey(key) and live(r, now) and not isX(r.body) then
      local base, suf = string.match(key, "^(%a%d+)([bcd]?)$")
      local d = Codec.Decode(r.body)
      if d then
        local i = (suf == "" and 1) or (suf == "b" and 2) or (suf == "c" and 3) or 4
        groups[base] = groups[base] or {}
        groups[base][i] = { d = d, rev = tonumber(r.rev) or 0 }
      end
    end
  end
  return groups
end

-- Items of the parts that carry part 1's gen, and whether all n parts are there.
local function assemble(parts)
  local head = parts[1].d
  local items, complete = {}, true
  for i = 1, head.n do
    local p = parts[i]
    if p and p.d.gen == head.gen and p.d.n == head.n then
      for _, it in ipairs(p.d.items) do items[#items + 1] = it end
    else
      complete = false
    end
  end
  return items, complete
end

local function idLess(a, b)
  if #a ~= #b then return #a < #b end
  return a < b
end

function Rules.View(records, now, keyFn)
  local view = { held = Rules.Held(records, now), incomplete = 0, events = {}, teams = {} }

  -- Team lists: the newest gen per team name (f1456).
  for _, parts in pairs(gather(records, now, "t")) do
    if parts[1] and parts[1].d.team then
      local head = parts[1].d
      local items = assemble(parts)
      local cur = view.teams[head.team]
      if not cur or head.gen > cur.gen or (head.gen == cur.gen and parts[1].rev > cur.rev) then
        local t = { name = head.team, colour = head.colour, gen = head.gen, rev = parts[1].rev, active = {}, bench = {} }
        for _, it in ipairs(items) do
          local list = (it.kind == "bench") and t.bench or t.active
          list[#list + 1] = it.character
        end
        view.teams[head.team] = t
      end
    end
  end

  for base, parts in pairs(gather(records, now, "e")) do
    if parts[1] and parts[1].d.title then
      local head = parts[1].d
      local items, complete = assemble(parts)
      local ev = { key = base, id = string.sub(base, 2), team = head.team, title = head.title, start = head.start,
        finish = head.finish, sr = head.sr, complete = complete, signups = {}, noAnswer = {},
        counts = { T = 0, H = 0, M = 0, R = 0 }, kinds = { primary = 0, late = 0, tentative = 0, bench = 0, absence = 0 } }
      local signed = {}
      for _, it in ipairs(items) do
        local s = { character = it.character, discord = it.discord, role = it.role, class = it.class, kind = it.kind,
          key = keyFn(it.character) }
        ev.signups[#ev.signups + 1] = s
        if s.key then signed[s.key] = true end
        ev.kinds[s.kind] = (ev.kinds[s.kind] or 0) + 1
        local code = ROLE_CODE[s.role]
        if code and (s.kind == "primary" or s.kind == "late") then ev.counts[code] = ev.counts[code] + 1 end
      end
      local team = view.teams[head.team]
      if team then
        ev.colour = team.colour
        for _, list in ipairs({ team.active, team.bench }) do
          for _, name in ipairs(list) do
            local k = keyFn(name)
            if k and not signed[k] then ev.noAnswer[#ev.noAnswer + 1] = name end
          end
        end
      end
      if not complete then view.incomplete = view.incomplete + 1 end
      view.events[#view.events + 1] = ev
    end
  end
  table.sort(view.events, function(a, b)
    if (a.start or 0) ~= (b.start or 0) then return (a.start or 0) < (b.start or 0) end
    return idLess(a.id, b.id)
  end)
  for _, t in pairs(view.teams) do t.rev = nil end
  return view
end

-- "arriving" for everyone on an incomplete event (f1454): the sign-up may sit in a part not held yet.
function Rules.Status(ev, meKey)
  if not ev.complete then return { state = "arriving" } end
  for _, s in ipairs(ev.signups or {}) do
    if meKey and s.key == meKey then return { state = "signed", signup = s } end
  end
  return { state = "none" }
end

function Rules.Age(held, now)
  if not held then return "no raid data yet", false end
  local at = tonumber(held.at)
  if not at then return "Raid-Helper time unknown, copied " .. duration(now - held.gen) .. " ago", true end
  return "data " .. duration(now - at) .. " old", now - at >= WARN_AGE
end

-- Monday-start weeks in local time. Each start is moved to its day's noon before stepping back to Monday, so a DST
-- change between them cannot move the date. A time date() cannot show (nil) keeps t and sorts last (f1490).
local function mondayNoon(t, dateFn)
  local d = dateFn("*t", t)
  if not d then return t end
  local noon = t - (d.hour * 3600 + d.min * 60 + d.sec) + 43200
  return noon - ((d.wday + 5) % 7) * DAY
end

local function dayKey(t, dateFn)
  local d = dateFn("*t", t)
  if not d then return math.huge end
  return d.year * 10000 + d.month * 100 + d.day
end

function Rules.Weeks(events, now, dateFn)
  local this = mondayNoon(now, dateFn)
  local thisKey, nextKey = dayKey(this, dateFn), dayKey(this + 7 * DAY, dateFn)
  local groups, byKey = {}, {}
  for _, ev in ipairs(events or {}) do
    local m = mondayNoon(ev.start or now, dateFn)
    local k = dayKey(m, dateFn)
    local g = byKey[k]
    if not g then
      local label = (k == thisKey and "This week") or (k == nextKey and "Next week") or ("Week of " .. (dateFn("%a %d %b", m) or "?"))
      g = { label = label, events = {}, sort = k }
      byKey[k] = g
      groups[#groups + 1] = g
    end
    g.events[#g.events + 1] = ev
  end
  table.sort(groups, function(a, b) return a.sort < b.sort end)
  for _, g in ipairs(groups) do g.sort = nil end
  return groups
end

-- Fail first (a failed attach never resolves), then wait for the roster, then pass.
function Rules.SelfCheck(o)
  if not o.attached then return "fail", "raids domain not attached: " .. tostring(o.why or "unknown reason") end
  if not o.known then return "wait", "waiting for the guild roster" end
  local view = o.view or { events = {}, incomplete = 0 }
  local n = #(view.events or {})
  local text = n .. (n == 1 and " raid" or " raids") .. ", " .. (view.incomplete or 0) .. " incomplete"
  if view.held then text = text .. ", " .. (Rules.Age(view.held, o.now)) else text = text .. ", no raid data yet" end
  return "pass", text
end
