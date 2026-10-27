-- GuildSyncBank derived state: what every author's records add up to. Pure: no client call, no clock.
--   ns.Derive.TimeOk(t, now) -> bool      a finite number at most LIMITS.future seconds ahead of now
--   ns.Derive.State(records, ctx) -> view records = { [domain] = { [key] = { rev, by, at, body } } }
--   ctx  = { now, me, roster = { [key] = row }, isBankChar = fn(key), isOfficer = fn(key), keyOf = fn(name), limits }
--   view = { ctx, reqs, byId, requests, holders, items, contributions, ignored = { [key] = why },
--            aged = { [id] = true }        closed requisitions left out past keepClosedDays,
--            slots = { [q key] = id | false } every kept q record: the id its body holds, false when it has no posted time,
--            guild = { scanned, by, tabs = { [tab] = { scanned, by } } } | nil   the guild bank: per tab the newest g
--                    record across bank characters; its items count once in items[id].by[Derive.GUILD] }
--   holders = { [key] = { scanned, money } }  bag (b) and bank (k) scans only; a g record makes no holder
--   gold = { total, holders = { { key, money, at } }, guild = { money, at, by } | nil,
--            entries = { { t, d, k, w, holder, after } } }   newest first; an unknown k reads as "o"
--   mins = { [id] = { min, raid, at, by, n } }   min 0 is a clear; n = bank characters holding an entry for id
--   low  = { { id, have, min, short, raid } }    short desc, then id ; raid = { { id, have, min, low } } low first, then id
--   ns.Derive.GUILD  the guild bank's holder key in items[id].by (holds "~", so it is never a member key)
-- Every family is read over all n through ns.ParseKey. Order: drop whole records (key, author, B5, roster, time),
-- then requisitions, pledges, sends, receipts, overrides, cancels, status, expiry, answers, requests, contents, contributions.

local _, ns = ...
if not ns.M then return end

local Derive = {}
ns.Derive = Derive

local DAY = 86400
Derive.GUILD = "~guild"
local BANK_FAMILIES = { b = true, k = true, g = true, t = true, q = true, l = true, a = true, j = true, n = true }

function Derive.TimeOk(t, now)
  if type(t) ~= "number" or t ~= t or t == math.huge or t == -math.huge then return false end
  return t <= now + ns.LIMITS.future
end

local function isNum(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function int(v, lo, hi) return isNum(v) and v == math.floor(v) and v >= lo and v <= hi end
local MAX_ID = 2147483647
local function isItem(v) return int(v, 1, MAX_ID) end
local function str(v) if type(v) == "string" then return v end end

-- Every time a body carries, by family (optional ones only when present). A missing time or a malformed entry (not
-- a table) gives false, so TimeOk refuses the record as "time".
local function f(t, k) if type(t) == "table" then return t[k] end end

local function bodyTimes(family, body, out)
  local function add(t) if t == nil then t = false end out[#out + 1] = t end
  local function opt(t) if t ~= nil then add(t) end end
  if family == "q" then
    if next(body) ~= nil then add(body.posted) end
    opt(body.cancelled)
  elseif family == "b" or family == "k" or family == "g" then
    add(body.scanned)
  elseif family == "j" then
    add(body.scanned)
    opt(body.guildAt)
    for _, e in ipairs(type(body.e) == "table" and body.e or {}) do add(f(e, "t")) end
  elseif family == "n" then
    for _, e in pairs(body) do add(f(e, "t")) end
  elseif family == "l" then
    for _, r in ipairs(type(body.receipts) == "table" and body.receipts or {}) do add(f(r, "at")); opt(f(r, "sent")) end
    for _, u in ipairs(type(body.unpledges) == "table" and body.unpledges or {}) do add(f(u, "at")) end
    for _, u in ipairs(type(body.unsends) == "table" and body.unsends or {}) do add(f(u, "at")) end
  elseif family == "a" then
    for _, x in ipairs(body) do add(f(x, "at")); add(f(x, "when")) end
  elseif family == "x" then
    for _, t in pairs(body) do add(t) end
  elseif family == "m" then
    for _, p in pairs(type(body.pledges) == "table" and body.pledges or {}) do add(f(p, "at")) end
    for _, s in pairs(type(body.sends) == "table" and body.sends or {}) do add(f(s, "at")) end
    for _, r in ipairs(type(body.requests) == "table" and body.requests or {}) do add(f(r, "at")) end
  end
  return out
end

-- Why a record does not count, or nil when it does.
local function refusal(key, rec, family, author, ctx)
  if not family then return "key" end
  if type(rec) ~= "table" or type(rec.body) ~= "table" then return "body" end
  if type(rec.by) ~= "string" or #rec.by > 48 or ctx.keyOf(rec.by) ~= author then return "author" end
  if BANK_FAMILIES[family] and not ctx.isBankChar(author) then return "notbank" end
  if family == "x" and not (ctx.isOfficer(author) or ctx.isBankChar(author)) then return "notofficer" end
  if family == "m" and not ctx.roster[author] then return "roster" end
  for _, t in ipairs(bodyTimes(family, rec.body, {})) do
    if not Derive.TimeOk(t, ctx.now) then return "time" end
  end
  return nil
end

local function byPostedThenId(a, b)
  if a.posted ~= b.posted then return a.posted < b.posted end
  return a.id < b.id
end

function Derive.State(records, ctx)
  local L = ctx.limits or ns.LIMITS
  local now = ctx.now
  local view = { ctx = ctx, reqs = {}, byId = {}, requests = {}, holders = {}, items = {}, contributions = {},
    ignored = {}, aged = {}, slots = {} }

  -- 1. whole records: kept ones grouped by family as { key, n, author, body }
  local fam = { b = {}, k = {}, g = {}, t = {}, q = {}, l = {}, a = {}, x = {}, m = {}, j = {}, n = {} }
  for _, domain in pairs(type(records) == "table" and records or {}) do
    for key, rec in pairs(type(domain) == "table" and domain or {}) do
      local family, n, author
      if type(key) == "string" then family, n, author = ns.ParseKey(key) end
      if family and not fam[family] then family = nil end
      local why = refusal(key, rec, family, author, ctx)
      if why then
        view.ignored[key] = why
      else
        local list = fam[family]
        list[#list + 1] = { key = key, n = n, author = author, body = rec.body }
      end
    end
  end

  -- 2. requisitions: one per used slot, id = slot key .. "@" .. posted
  local all = {}
  for _, r in ipairs(fam.q) do
    local b = r.body
    view.slots[r.key] = isNum(b.posted) and (r.key .. "@" .. b.posted) or false
    if isNum(b.posted) and isItem(b.item) and int(b.wanted, 1, L.wanted) then
      all[#all + 1] = { id = r.key .. "@" .. b.posted, key = r.key, slot = r.n, poster = r.author, item = b.item,
        wanted = b.wanted, why = str(b.why), posted = b.posted, cancelledAt = b.cancelled,
        pledges = {}, sends = {}, receipts = {}, delivered = 0, pledged = 0 }
    end
  end
  local byId = {}
  for _, req in ipairs(all) do byId[req.id] = req end

  -- officers' cancels
  for _, x in ipairs(fam.x) do
    for id, t in pairs(x.body) do
      local req = byId[id]
      if req and isNum(t) and (req.cancelledAt == nil or t < req.cancelledAt) then req.cancelledAt = t end
    end
  end

  -- ledgers: receipts and overrides from every bank character's l<n>
  local unpledged, unsent = {}, {}
  for _, l in ipairs(fam.l) do
    for _, rc in ipairs(type(l.body.receipts) == "table" and l.body.receipts or {}) do
      local req = byId[f(rc, "req")]
      if req and type(rc) == "table" and type(rc.member) == "string" and int(rc.amount, 1, L.sent) and isNum(rc.at) then
        req.receipts[#req.receipts + 1] = { member = rc.member, amount = rc.amount, sent = rc.sent, at = rc.at,
          by = l.author }
      end
    end
    for _, u in ipairs(type(l.body.unpledges) == "table" and l.body.unpledges or {}) do
      if type(u) == "table" then unpledged[tostring(u.req) .. "\n" .. tostring(u.member) .. "\n" .. tostring(u.at)] = true end
    end
    for _, u in ipairs(type(l.body.unsends) == "table" and l.body.unsends or {}) do
      if type(u) == "table" then unsent[tostring(u.req) .. "\n" .. tostring(u.member) .. "\n" .. tostring(u.at)] = true end
    end
  end

  -- status: filled at the receipt that reaches wanted, cancelled, or open; the earlier close wins
  for _, req in ipairs(all) do
    table.sort(req.receipts, function(a, b) return a.at < b.at end)
    local filledAt
    for _, rc in ipairs(req.receipts) do
      req.delivered = req.delivered + rc.amount
      if not filledAt and req.delivered >= req.wanted then filledAt = rc.at end
    end
    if filledAt and (req.cancelledAt == nil or filledAt <= req.cancelledAt) then
      req.status, req.closedAt = "filled", filledAt
    elseif req.cancelledAt then
      req.status, req.closedAt = "cancelled", req.cancelledAt
    else
      req.status = "open"
    end
    req.cancelledAt = nil
  end

  -- E13: at most openReqs open ones (the oldest by posted); closed ones show for keepClosedDays
  local open, closed = {}, {}
  for _, req in ipairs(all) do
    if req.status == "open" then open[#open + 1] = req else closed[#closed + 1] = req end
  end
  table.sort(open, byPostedThenId)
  table.sort(closed, byPostedThenId)
  for i, req in ipairs(open) do
    if i <= L.openReqs then
      view.reqs[#view.reqs + 1] = req
      view.byId[req.id] = req
    else
      view.ignored[req.key] = "cap"
    end
  end
  for _, req in ipairs(closed) do
    if req.closedAt >= now - L.keepClosedDays * DAY then
      view.reqs[#view.reqs + 1] = req
      view.byId[req.id] = req
    else
      view.aged[req.id] = true
    end
  end

  -- answers: from bank characters' a<n>, matched by member key and request time; the latest answer wins
  local answers = {}
  for _, a in ipairs(fam.a) do
    for _, x in ipairs(a.body) do
      if type(x) == "table" and (x.verdict == "fulfilled" or x.verdict == "declined") and isNum(x.when) then
        local k = tostring(x.member) .. "\n" .. tostring(x.at)
        local had = answers[k]
        if not had or x.when > had.when then
          answers[k] = { verdict = x.verdict, reason = str(x.reason), by = a.author, when = x.when }
        end
      end
    end
  end

  -- 3. member records: pledges, sends (confirmed only by a bank character's receipt with that send's time), requests
  local asks = {}
  for _, m in ipairs(fam.m) do
    local member, b = m.author, m.body
    for id, p in pairs(type(b.pledges) == "table" and b.pledges or {}) do
      local req = view.byId[id]
      if req and type(p) == "table" and int(p.amount, 1, req.wanted) and isNum(p.at)
          and p.at >= now - L.pledgeDays * DAY and not unpledged[id .. "\n" .. member .. "\n" .. tostring(p.at)] then
        -- a delivery received after the pledge eats it, as the bot's book() does (bounties-core.js:79-80)
        local left = p.amount
        for _, rc in ipairs(req.receipts) do if rc.member == member and rc.at >= p.at then left = left - rc.amount end end
        if left > 0 then
          req.pledges[member] = { amount = left, at = p.at }
          req.pledged = req.pledged + left
        end
      end
    end
    for id, s in pairs(type(b.sends) == "table" and b.sends or {}) do
      local req = view.byId[id]
      if req and type(s) == "table" and int(s.amount, 1, L.sent) and isNum(s.at) then
        local status = "pending"
        if unsent[id .. "\n" .. member .. "\n" .. tostring(s.at)] then
          status = "cancelled"
        else
          for _, rc in ipairs(req.receipts) do
            if rc.member == member and rc.sent == s.at then status = "received" end
          end
        end
        req.sends[member] = { amount = s.amount, at = s.at, status = status }
      end
    end
    local mine = {}
    for _, q in ipairs(type(b.requests) == "table" and b.requests or {}) do
      local note = type(q) == "table" and (q.note == nil and "" or q.note)
      if type(q) == "table" and isItem(q.item) and int(q.count, 1, L.askCount)
          and type(note) == "string" and #note <= L.note and isNum(q.at) and q.at >= now - L.requestDays * DAY then
        mine[#mine + 1] = { member = member, item = q.item, count = q.count, note = note, at = q.at,
          answer = answers[member .. "\n" .. tostring(q.at)] }
      end
    end
    -- an open request is unexpired and unanswered: every answered one stays, at most openRequests open (the oldest)
    table.sort(mine, function(x, y) return x.at < y.at end)
    local open = 0
    for _, q in ipairs(mine) do
      if q.answer then
        asks[#asks + 1] = q
      elseif open < L.openRequests then
        open = open + 1
        asks[#asks + 1] = q
      end
    end
  end

  table.sort(asks, function(x, y)
    if x.at ~= y.at then return x.at < y.at end
    return x.member < y.member
  end)
  for _, q in ipairs(asks) do
    view.requests[#view.requests + 1] = q
  end

  -- 4. contents: bags (b), bank tabs (k) and guild bank tabs (g), every n
  local function holder(h)
    view.holders[h] = view.holders[h] or {}
    return view.holders[h]
  end
  local function addItems(h, items)
    for id, count in pairs(type(items) == "table" and items or {}) do
      if isItem(id) and int(count, 1, 1e6) then
        local it = view.items[id] or { total = 0, by = {} }
        view.items[id] = it
        it.total = it.total + count
        it.by[h] = (it.by[h] or 0) + count
      end
    end
  end
  for _, family in ipairs({ "b", "k" }) do
    for _, s in ipairs(fam[family]) do
      local hd = holder(s.author)
      if not hd.scanned or s.body.scanned > hd.scanned then hd.scanned = s.body.scanned end
      -- only the b piece that carries money sets it, whatever the order (f5283)
      if family == "b" and s.body.money ~= nil then hd.money = int(s.body.money, 0, 1e12) and s.body.money or nil end
      addItems(s.author, s.body.items)
    end
  end
  -- the guild bank: per tab only the newest scan across every bank character (a tie: the lower author key), counted
  -- once under Derive.GUILD
  local tabs = {}
  for _, s in ipairs(fam.g) do
    -- the body's tab, else the key's n; a g record with neither as a whole 1..16 is refused (f5256)
    local tab = s.body.tab
    if tab == nil then tab = s.n end
    local had = tabs[tab] or false
    if not int(tab, 1, 16) then
      view.ignored[s.key] = "tab"
    elseif not had or s.body.scanned > had.scanned or (s.body.scanned == had.scanned and s.author < had.by) then
      tabs[tab] = { scanned = s.body.scanned, by = s.author, items = s.body.items }
    end
  end
  for tab, t in pairs(tabs) do
    local g = view.guild or { tabs = {} }
    view.guild = g
    g.tabs[tab] = { scanned = t.scanned, by = t.by }
    if not g.scanned or t.scanned > g.scanned or (t.scanned == g.scanned and t.by < g.by) then
      g.scanned, g.by = t.scanned, t.by
    end
    addItems(Derive.GUILD, t.items)
  end

  -- gold: per bank character the money of the newer of its j1 and its money-carrying b; the guild bank's gold from
  -- the newest guildAt (a tie: the lower author key); ledger entries newest first, each with the balance after it
  local KINDS = { m = true, g = true, v = true, o = true, s = true }
  local gold = { total = 0, holders = {}, entries = {} }
  view.gold = gold
  local purse = {}
  local function seen(author, money, at)
    local had = purse[author]
    if int(money, 0, 1e12) and isNum(at) and (not had or at > had.at) then
      purse[author] = { money = money, at = at }
    end
  end
  for _, s in ipairs(fam.b) do
    if s.body.money ~= nil then seen(s.author, s.body.money, s.body.scanned) end
  end
  for _, s in ipairs(fam.j) do
    local b = s.body
    seen(s.author, b.money, b.scanned)
    local g = gold.guild
    if int(b.guild, 0, 1e12) and isNum(b.guildAt)
        and (not g or b.guildAt > g.at or (b.guildAt == g.at and s.author < g.by)) then
      gold.guild = { money = b.guild, at = b.guildAt, by = s.author }
    end
    local e = type(b.e) == "table" and b.e or {}
    local after = int(b.money, 0, 1e12) and b.money or 0
    for i = #e, 1, -1 do
      local x = e[i]
      if type(x) == "table" and isNum(x.t) and isNum(x.d) then
        gold.entries[#gold.entries + 1] = { t = x.t, d = x.d, k = KINDS[x.k] and x.k or "o", w = str(x.w),
          holder = s.author, after = after }
        after = after - x.d
      end
    end
  end
  for author, p in pairs(purse) do
    gold.holders[#gold.holders + 1] = { key = author, money = p.money, at = p.at }
    gold.total = gold.total + p.money
  end
  table.sort(gold.holders, function(x, y) return x.key < y.key end)
  if gold.guild then gold.total = gold.total + gold.guild.money end
  table.sort(gold.entries, function(x, y)
    if x.t ~= y.t then return x.t > y.t end
    if x.holder ~= y.holder then return x.holder < y.holder end
    return x.after < y.after
  end)

  -- minimums: per item over every bank character's n1 the newest t (a tie: the higher m, then the lower author);
  -- m = 0 is a clear. Low: an item whose stock (b, k and the guild bank) is under its minimum; raid: the raid items
  view.mins, view.low, view.raid = {}, {}, {}
  for _, s in ipairs(fam.n) do
    for id, x in pairs(s.body) do
      if isItem(id) and type(x) == "table" and int(x.m, 0, L.minimum) and isNum(x.t) then
        local had = view.mins[id]
        local n = had and had.n + 1 or 1
        if not had or x.t > had.at or (x.t == had.at and (x.m > had.min or (x.m == had.min and s.author < had.by))) then
          view.mins[id] = { min = x.m, raid = x.r ~= nil or nil, at = x.t, by = s.author, n = n }
        else
          had.n = n
        end
      end
    end
  end
  for id, m in pairs(view.mins) do
    if m.min > 0 then
      local have = view.items[id] and view.items[id].total or 0
      local low = have < m.min
      if low then
        view.low[#view.low + 1] = { id = id, have = have, min = m.min, short = m.min - have, raid = m.raid }
      end
      if m.raid then view.raid[#view.raid + 1] = { id = id, have = have, min = m.min, low = low } end
    end
  end
  table.sort(view.low, function(x, y)
    if x.short ~= y.short then return x.short > y.short end
    return x.id < y.id
  end)
  table.sort(view.raid, function(x, y)
    if x.low ~= y.low then return x.low end
    return x.id < y.id
  end)

  -- 5. contributions: summed across every bank character's t<n>; this month through ns.Month (UTC)
  local month = ns.Month(now)
  local totals, order = {}, {}
  for _, t in ipairs(fam.t) do
    for member, e in pairs(t.body) do
      if type(member) == "string" and type(e) == "table" and int(e.all, 0, 1e9) then
        local c = totals[member]
        if not c then
          c = { member = member, all = 0, month = 0 }
          totals[member] = c
          order[#order + 1] = c
        end
        c.all = c.all + e.all
        if e.month == month and int(e.inMonth, 0, 1e9) then c.month = c.month + e.inMonth end
      end
    end
  end
  table.sort(order, function(x, y)
    if x.all ~= y.all then return x.all > y.all end
    return x.member < y.member
  end)
  view.contributions = order

  return view
end
