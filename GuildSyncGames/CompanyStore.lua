-- GuildSyncGames CompanyStore.lua (S13 Task 3, S14 Task 3): the Company state, account-wide in
-- GuildSyncGamesDB.company = { era, token, owned = { [id] = true }, title, colour, badge, gifts = { x6 },
-- tickets = { week, count, key, prevWeek, prevCount, prevKey }, officer = { hides, draw }, paidWeek, paidPot }.
-- Made at call time; a preview-era or unsound table is replaced whole (S11's era rule). An S13 latch is ignored.
-- Local ids everywhere: store items CC.ITEMS[i].id, an earned project badge k is CC.PROJECT_BADGE_BASE + k; only the
-- wire body (ns.CompanyBody) carries the place in its kind (badge 1-4 store, 5-10 project 1-6).
-- S14 (o1773): a week's tickets sit on one character's row (tickets.key, prevKey after a roll); their numbers are
-- CC.Number(week, that key, i). An officer (ns.IsOfficer(ns.MyKey()) at call time) keeps hides (own entries marked
-- own, then carried resolved ones) and the week's draw in company.officer; CompanySync packs them into the own row.
-- The payout reads only the resolved officer draw (ns.CompanyOfficerDraw) once it has held PAY_HOLD (d1601).
-- CompanySync's functions are read at call time: ns.CompanyProjects for actions, the unwrapped ns.CompanyRaw for
-- the badge latch, ns.CompanyOfficerDraw, ns.CompanyDrawRows, ns.CompanyHeardOfficers, ns.CompanyHides and
-- ns.CompanyMembers for the officer state and the payout (d1588, d1617). Play grain only.

local _, ns = ...

if not ns.M then return end
local M, CC, GC = ns.M, ns.CompanyCore, ns.GrainCore

local WEEK = 604800
local SESSION_MIN = 300 -- an officer draws only with a session at least this old (d1585)
local WAIT = 600        -- a higher-key officer waits this long past settleAt before drawing its own (d1601)
local PAY_HOLD = 600    -- a resolved draw pays only after it has been the same for this long (d1601)
local SALT_MAX = 2147483646
local CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
local KINDS = { title = true, colour = true, badge = true }

local function int(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and (not lo or v >= lo) and (not hi or v <= hi)
end

local function newToken()
  local out = {}
  for i = 1, 6 do
    local n = math.random(1, #CHARS)
    out[i] = CHARS:sub(n, n)
  end
  return table.concat(out)
end

local function isProjectBadge(id)
  return int(id, CC.PROJECT_BADGE_BASE + 1, CC.PROJECT_BADGE_BASE + #CC.PROJECTS)
end

local function sound(v)
  if type(v) ~= "table" or (v.era ~= "live" and v.era ~= "preview") then return false end
  if type(v.token) ~= "string" or #v.token ~= 6 or v.token:find("[^0-9a-z]") then return false end
  if type(v.owned) ~= "table" then return false end
  for id, on in pairs(v.owned) do
    if on ~= true or not (CC.Item(id) or isProjectBadge(id)) then return false end
  end
  for _, k in ipairs({ "title", "colour", "badge" }) do
    if not int(v[k], 0) then return false end
  end
  if type(v.gifts) ~= "table" then return false end
  for k = 1, #CC.PROJECTS do
    if not int(v.gifts[k], 0, CC.PROJECTS[k].goal) then return false end
  end
  local tk = v.tickets
  if type(tk) ~= "table" or not int(tk.week) or not int(tk.count, 0, CC.TICKETS_MAX) or not int(tk.prevWeek)
    or not int(tk.prevCount, 0, CC.TICKETS_MAX) then return false end
  if (tk.key ~= nil and type(tk.key) ~= "string") or (tk.prevKey ~= nil and type(tk.prevKey) ~= "string") then
    return false
  end
  local off = v.officer
  if off ~= nil then
    if type(off) ~= "table" or type(off.hides) ~= "table" then return false end
    for k, h in pairs(off.hides) do
      if type(k) ~= "string" or type(h) ~= "table" or type(h.on) ~= "boolean" or not int(h.at, 0) then return false end
    end
    if off.draw ~= nil and (type(off.draw) ~= "table" or not int(off.draw.week) or not int(off.draw.total, 0)) then
      return false
    end
  end
  if v.paidWeek ~= nil and not int(v.paidWeek) then return false end
  if v.paidPot ~= nil and not int(v.paidPot, 0) then return false end
  return true
end

-- old: the replaced table's token; the new one differs from it (AC10), within a few draws.
local function fresh(t, old)
  local token = newToken()
  for _ = 1, 8 do
    if token ~= old then break end
    token = newToken()
  end
  local gifts = {}
  for k = 1, #CC.PROJECTS do gifts[k] = 0 end
  return { era = (type(t) == "number" and t >= GC.LAUNCH) and "live" or "preview", token = token, owned = {},
    title = 0, colour = 0, badge = 0, gifts = gifts, tickets = { week = 0, count = 0, prevWeek = 0, prevCount = 0 } }
end

-- The saved company, made at call time. In demo a missing, unsound or pre-launch table is a fresh unsaved one and
-- nothing is written (d1588).
local function company()
  local t, demo = ns.Now(), M.Demo()
  local d = GuildSyncGamesDB
  local v = type(d) == "table" and d.company or nil
  local ok = sound(v)
  local reset = type(t) == "number" and t >= GC.LAUNCH and ok and v.era ~= "live"
  if demo then return (ok and not reset) and v or fresh(t) end
  if type(d) ~= "table" then
    d = {}
    GuildSyncGamesDB = d
  end
  if not ok or reset then d.company = fresh(t, type(v) == "table" and v.token or nil) end
  v = d.company
  -- a worn id that is not owned of its kind is reset to 0; the rest stays (review f6). Never in demo (security f4).
  for _, k in ipairs({ "title", "colour", "badge" }) do
    local id, it = v[k], CC.Item(v[k])
    local fits = (it and it.kind == k) or (k == "badge" and isProjectBadge(id))
    if id ~= 0 and not (fits and v.owned[id]) then v[k] = 0 end
  end
  return v
end

local function changed()
  if ns.CompanyChanged then M.Safe(ns.CompanyChanged) end
end

local function offset()
  if ns.RealmOffset then return ns.RealmOffset() end
  return 0, false
end

-- The account's tickets for week w (the current or the rolled-out week) and the key whose row holds them.
local function ownTickets(tk, w)
  if tk.count > 0 and tk.week == w then return tk.count, tk.key end
  if tk.prevCount > 0 and tk.prevWeek == w then return tk.prevCount, tk.prevKey end
  return 0, nil
end

local function nameOf(key)
  local m = key and ns.Member and ns.Member(key)
  return type(m) == "table" and m.name or key
end

-- Badge k is latched into owned the first time own g[k] > 0 and k is done; it stays when k reopens (o1710).
local function latchBadges(v)
  local raw = ns.CompanyRaw
  if M.Demo() or type(raw) ~= "table" or type(raw.projects) ~= "function" then return end
  local p = raw.projects()
  if type(p) ~= "table" or type(p.done) ~= "table" then return end
  for k = 1, #CC.PROJECTS do
    if v.gifts[k] > 0 and p.done[k] == true then v.owned[CC.PROJECT_BADGE_BASE + k] = true end
  end
end

-- ---------- actions ----------

function ns.BuyItem(id)
  if ns.Inert() then return nil, "demo" end
  local it = CC.Item(id)
  if not it then return nil, "unknown" end
  local v = company()
  if v.owned[it.id] then return nil, "owned" end
  if not ns.Spend(it.price) then return nil, "short" end
  v.owned[it.id] = true
  changed()
  return true
end

function ns.Wear(kind, id)
  if ns.Inert() then return nil, "demo" end
  if not KINDS[kind] then return nil, "unknown" end
  local v = company()
  if id ~= 0 then
    local it = CC.Item(id)
    local fits = (it and it.kind == kind) or (kind == "badge" and isProjectBadge(id))
    if not fits or not v.owned[id] then return nil, "unknown" end
  end
  v[kind] = id
  changed()
  return true
end

function ns.Donate(n)
  if ns.Inert() then return nil, "demo" end
  local give = false
  for _, g in ipairs(CC.GIVES) do give = give or n == g end
  if not give then return nil, "amount" end
  local raw = ns.CompanyRaw
  local p = type(raw) == "table" and type(raw.projects) == "function" and raw.projects() or nil
  local k = type(p) == "table" and p.current or nil
  if not CC.PROJECTS[k] then return nil, "done" end
  local v = company()
  if v.gifts[k] + n > CC.PROJECTS[k].goal then return nil, "cap" end
  if not ns.Spend(n) then return nil, "short" end
  v.gifts[k] = v.gifts[k] + n
  changed()
  return true
end

-- d1583: the first buy of a new week rolls week into prevWeek; a clock week below the stored week while tickets are
-- held is "rolled" and the stored week is never lowered. o1773: the week's first ticket puts the week on the own key
-- (tickets.key; the rolled week keeps its key as prevKey); a buy that week from another character is "other", with
-- the holder's name. Without the own key nothing is bought ("clock": the character is not known yet).
function ns.BuyTicket()
  if ns.Inert() then return nil, "demo" end
  local t = ns.Now()
  if type(t) ~= "number" then return nil, "clock" end
  local me = ns.MyKey()
  if me == nil then return nil, "clock" end
  local w, _, _, _, open = CC.Week(t, (offset()))
  if not open then return nil, "closed" end
  local v = company()
  local tk = v.tickets
  if tk.count > 0 and tk.week > w then return nil, "rolled" end
  local roll = tk.count == 0 or tk.week < w
  if not roll and tk.key ~= me then return nil, "other", nameOf(tk.key) end
  if not roll and tk.count >= CC.TICKETS_MAX then return nil, "max" end
  if not ns.Spend(CC.TICKET_PRICE) then return nil, "short" end
  if roll then
    if tk.count > 0 then tk.prevWeek, tk.prevCount, tk.prevKey = tk.week, tk.count, tk.key end
    tk.week, tk.count, tk.key = w, 0, me
  end
  tk.count = tk.count + 1
  changed()
  return true
end

-- ---------- reads ----------

function ns.CompanyState()
  local v = company()
  latchBadges(v)
  return v
end

local function wire(kind, id)
  if id == 0 then return 0 end
  if kind == "badge" and isProjectBadge(id) then return id - CC.PROJECT_BADGE_BASE + 4 end
  return id - CC.WIRE_BASE[kind]
end
-- o1773: the week packs only on tickets.key's row, the previous week only on prevKey's.
function ns.CompanyBody()
  local v = company()
  local tk, gifts, me = v.tickets, {}, ns.MyKey()
  for k = 1, #CC.PROJECTS do gifts[k] = v.gifts[k] end
  local here, prev = me ~= nil and tk.key == me, me ~= nil and tk.prevKey == me
  return { a = v.token, week = here and tk.week or 0, count = here and tk.count or 0,
    prevWeek = prev and tk.prevWeek or 0, prevCount = prev and tk.prevCount or 0,
    gifts = gifts, title = wire("title", v.title), colour = wire("colour", v.colour), badge = wire("badge", v.badge) }
end

-- ---------- officer state (d1601-d1609) ----------

local function officerMe()
  local me = ns.MyKey and ns.MyKey()
  return me ~= nil and ns.IsOfficer ~= nil and ns.IsOfficer(me) == true, me
end

local function charsOf(key)
  local out = {}
  local p = ns.Person and ns.Person(key)
  for _, c in ipairs(type(p) == "table" and type(p.chars) == "table" and p.chars or {}) do
    if type(c) == "table" and c.key then out[c.key] = true end
  end
  return out
end

-- The own section, or nil while this character is no officer (CompanySync packs it into the own row).
function ns.CompanyOfficer()
  if not officerMe() then return nil end
  return company().officer
end

-- Own entries first (all of them, at most HIDE_MAX), then carried ones newest first, then by key.
local function trimmed(own, carried)
  local out, n = {}, 0
  for k, h in pairs(own) do
    out[k] = { on = h.on, at = h.at, own = true }
    n = n + 1
  end
  table.sort(carried, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.key < b.key end)
  for _, c in ipairs(carried) do
    if n >= CC.HIDE_MAX then break end
    if not out[c.key] then
      out[c.key] = { on = c.on, at = c.at }
      n = n + 1
    end
  end
  return out
end

local function ownOf(hides)
  local own, carried = {}, {}
  for k, h in pairs(hides) do
    if h.own then own[k] = h else carried[#carried + 1] = { key = k, on = h.on, at = h.at } end
  end
  return own, carried
end

-- d1607: one entry per Hide, stamped ns.Now(). Refusals in order: demo, officer, unknown, self, full (d1615). An
-- unhide frees its place: at HIDE_MAX own entries a new key replaces the oldest own unhide, else "full".
function ns.SetHidden(key, on)
  if ns.Inert() then return nil, "demo" end
  local isOfficer, me = officerMe()
  if not isOfficer then return nil, "officer" end
  local rows, isPartial, _, known
  if ns.Roster then rows, isPartial, _, known = ns.Roster() end
  if type(key) ~= "string" or type(rows) ~= "table" or rows[key] == nil then return nil, "unknown" end
  if key == me or charsOf(me)[key] then return nil, "self" end
  local t = ns.Now()
  if type(t) ~= "number" then return nil, "clock" end
  local v = company()
  local off = v.officer or { hides = {} }
  local own, carried = ownOf(off.hides)
  -- At HIDE_MAX the place needed comes from the oldest own unhide, else (f7524, f7535) the oldest own entry whose key
  -- is off a full, known roster; until its place is needed such an entry stays own, so a re-invited player stays hidden.
  if not own[key] then
    local full = known and not isPartial and ns.CompanyMembers and ns.CompanyMembers() ~= nil
    local n, oldest, gone = 0, nil, nil
    for k, h in pairs(own) do
      n = n + 1
      if not h.on and (not oldest or h.at < own[oldest].at) then oldest = k end
      if full and rows[k] == nil and (not gone or h.at < own[gone].at) then gone = k end
    end
    if n >= CC.HIDE_MAX then
      oldest = oldest or gone
      if not oldest then return nil, "full" end
      own[oldest] = nil
    end
  end
  own[key] = { on = on and true or false, at = t }
  off.hides = trimmed(own, carried)
  v.officer = off
  changed()
  return true
end

local function sameHides(a, b)
  for k, h in pairs(a) do
    local o = b[k]
    if not o or o.on ~= h.on or o.at ~= h.at or (o.own or false) ~= (h.own or false) then return false end
  end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

-- The own entries stay; the carried ones are the resolved hides of every officer section (ns.CompanyHides), within
-- HIDE_MAX (d1604, o1759). Answers true when the section changed.
local function rebuildHides(v)
  local res = ns.CompanyHides and ns.CompanyHides() or {}
  local off = v.officer or { hides = {} }
  local own = ownOf(off.hides)
  local carried = {}
  for k, h in pairs(res) do
    if not own[k] and type(h) == "table" and type(h.at) == "number" then
      carried[#carried + 1] = { key = k, on = h.on and true or false, at = h.at }
    end
  end
  local new = trimmed(own, carried)
  if sameHides(new, off.hides) then return false end
  off.hides = new
  v.officer = off
  return true
end

-- A week with no tickets is no draw: the officer keeps looking until tickets are visible (late rows, the wipe).
local function copyDraw(d, last)
  if type(d) ~= "table" or not int(d.total, 1) then return nil end
  return { week = last, key = d.key, i = d.i, number = d.number, target = d.target, total = d.total, pot = d.pot,
    salt = d.salt }
end

local function drawOwn(last)
  local rows = ns.CompanyDrawRows and ns.CompanyDrawRows(last) or {}
  local d = CC.Draw(last, rows, math.random(SALT_MAX))
  return copyDraw(d, last)
end

-- d1601, d1619: past settleAt an officer that sees a resolved draw for the week adopts it, lowest key or not. With none
-- visible, the lowest key among the heard officers plus me draws within WAIT of settleAt; any other officer (or one
-- that came online later) draws its own once WAIT has passed both since settleAt and since its session started. One
-- draw a week; none before a full roster read (d1608, d1617). Answers true when the section changed.
local function officerDraw(v, t, me, last, settleAt, started)
  if v.officer and v.officer.draw and v.officer.draw.week == last then return false end
  if not (ns.CompanyMembers and ns.CompanyMembers() ~= nil) then return false end
  local lowest = true
  for _, k in ipairs(ns.CompanyHeardOfficers and ns.CompanyHeardOfficers() or {}) do
    if k < me then lowest = false end
  end
  local seen = ns.CompanyOfficerDraw and ns.CompanyOfficerDraw(last)
  local d = type(seen) == "table" and seen.week == last and copyDraw(seen, last) or nil
  if not d and ((lowest and t < settleAt + WAIT) or (t >= settleAt + WAIT and t >= started + WAIT)) then
    d = drawOwn(last)
  end
  if not d then return false end
  v.officer = v.officer or { hides = {} }
  v.officer.draw = d
  return true
end

-- ---------- the payout (AC5) ----------

local held -- session memory: { sig, since } of the resolved draw last seen (d1601)

-- Pays from the resolved officer draw once it has held PAY_HOLD: once per week past paidWeek, d.key the key holding
-- the account's tickets for that week, d.i within their count, the launch guard (d1586). Never from a saved latch.
local function payout(v, t, last, lastDraw)
  local d = ns.CompanyOfficerDraw and ns.CompanyOfficerDraw(last)
  if type(d) ~= "table" or d.week ~= last then
    held = nil
    return
  end
  local sig = table.concat({ tostring(d.by), d.week, tostring(d.key), tostring(d.i), tostring(d.salt) }, "^")
  if not held or held.sig ~= sig then held = { sig = sig, since = t } end
  if t - held.since < PAY_HOLD then return end
  if v.paidWeek ~= nil and v.paidWeek >= last then return end
  local count, key = ownTickets(v.tickets, last)
  if key == nil or d.key ~= key or not int(d.i, 1, count) or not int(d.pot, 1) then return end
  if not (t < GC.LAUNCH or lastDraw >= GC.LAUNCH) then return end
  v.paidWeek, v.paidPot = last, nil
  local ran, credited = M.Safe(ns.Credit, d.pot)
  if ran and credited == true then v.paidPot = d.pot end
end

-- Officer hides at any time; the officer draw and the payout past settleAt with a session at least SESSION_MIN old.
-- Nothing in demo.
function ns.CompanySettle(t)
  if M.Demo() or type(ns.SessionStart) ~= "function" then return end
  t = type(t) == "number" and t or ns.Now()
  if type(t) ~= "number" then return end
  -- no own key yet: the account's draw rows and its tickets' key are unknown (security f3)
  local me = type(ns.MyKey) == "function" and ns.MyKey() or nil
  if me == nil then return end
  local v = company()
  latchBadges(v)
  local isOfficer = officerMe()
  local dirty = isOfficer and rebuildHides(v) or false
  local started = ns.SessionStart()
  if type(started) == "number" and t - started >= SESSION_MIN then
    local w, _, drawAt = CC.Week(t, (offset()))
    local last, lastDraw = w - 1, drawAt - WEEK
    local settleAt = lastDraw + CC.SETTLE_AFTER
    if t >= settleAt then
      if isOfficer and officerDraw(v, t, me, last, settleAt, started) then dirty = true end
      payout(v, t, last, lastDraw)
    end
  end
  if dirty then changed() end
end

-- draw: the resolved officer draw of the last week (name and byName added); waiting while there is none, with the
-- last week's draw-row ticket count (q1604).
function ns.Lottery()
  local v = ns.CompanyState()
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  local off, known = offset()
  local w, closeAt, drawAt, settleAt, open = CC.Week(t, off)
  local mine = {}
  local count, key = ownTickets(v.tickets, w)
  if key then
    for i = 1, count do mine[i] = CC.Number(w, key, i) end
  end
  local cur = ns.CompanyDraw and ns.CompanyDraw(w)
  local total = type(cur) == "table" and cur.total or #mine
  local last = w - 1
  local d = ns.CompanyOfficerDraw and ns.CompanyOfficerDraw(last)
  local draw, waitTotal
  if type(d) == "table" then
    draw = {}
    for k, x in pairs(d) do draw[k] = x end
    draw.name, draw.byName = d.key and nameOf(d.key) or nil, d.by and nameOf(d.by) or nil
  else
    waitTotal = 0
    for _, r in ipairs(ns.CompanyDrawRows and ns.CompanyDrawRows(last) or {}) do
      waitTotal = waitTotal + CC.TicketsFor(r.b, last)
    end
  end
  return { week = w, closeAt = closeAt, drawAt = drawAt, settleAt = settleAt, open = open, utc = not known,
    lastWeek = last, mine = mine, pot = total * CC.TICKET_PRICE, total = total, draw = draw, waiting = draw == nil,
    waitWeek = draw == nil and last or nil, waitTotal = waitTotal,
    paid = v.paidPot and { week = v.paidWeek, pot = v.paidPot } or nil }
end
