-- GuildSyncBank rules: what a requisition, pledge, delivery or request may do (brief E13, E14, G17, I19; port of the
-- bot's bounties-core material kind). Pure: no client call, no clock, no Store; state in, own records edited.
--   ns.Rules.<verb>(view, who, args, now, own) -> result | nil, code, message
--   view = ns.Derive.State(...); who = { key, bank, officer }; own = { [ownKey] = body } (the actor's records only)
-- Permission first, then every check, then the edit: a refusal leaves own as it was. Writes land only in own keys:
-- the member's record, the bank character's q slots, l1 ledger, t1 totals and a1 answers, and an officer's x~ list.
-- Refusal messages never say "bounty" (the codes keep the bot's names).

local _, ns = ...
if not ns.M then return end

local Rules = {}
ns.Rules = Rules

local DAY = 86400

local function int(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function refuse(code, message) return nil, code, message end

local NOT_ALLOWED = "Only a bank character can do that."

-- The requisition named by id, or a refusal.
local function find(view, id)
  local req = type(id) == "string" and view.byId[id]
  if not req then return refuse("no-bounty", "That requisition doesn't exist.") end
  return req
end

local function member(own, key)
  own[key] = own[key] or {}
  return own[key]
end

local function ledger(own, who)
  local key = ns.Key("l", 1, who.key)
  own[key] = own[key] or {}
  return own[key]
end

local function list(t, field)
  if type(t[field]) ~= "table" then t[field] = {} end
  return t[field]
end

-- The send's state as a refusal, or nil when it is pending.
local function sendRefusal(s)
  if not s then return "no-delivery", "They have no delivery waiting on that requisition." end
  if s.status == "received" then return "already", "That delivery was already received." end
  if s.status == "cancelled" then return "cancelled", "That delivery was already cancelled." end
  return nil
end

-- A receipt into the bank character's l1 and its t1 totals (all time and this UTC month).
local function book(own, who, id, m, amount, sent, now)
  local l = ledger(own, who)
  local receipts = list(l, "receipts")
  receipts[#receipts + 1] = { req = id, member = m, amount = amount, sent = sent, at = now }
  local tkey = ns.Key("t", 1, who.key)
  own[tkey] = own[tkey] or {}
  local month = ns.Month(now)
  local e = own[tkey][m] or { all = 0, month = month, inMonth = 0 }
  if e.month ~= month then e.month, e.inMonth = month, 0 end
  e.all = e.all + amount
  e.inMonth = e.inMonth + amount
  own[tkey][m] = e
  return receipts[#receipts]
end

local function trim(s) return (s:match("^%s*(.-)%s*$")) end

local function isOpenRequest(q, now, L)
  return type(q) == "table" and type(q.at) == "number" and q.at >= now - L.requestDays * DAY
end

-- A requisition id that is gone: not in view, and its q record here is empty or holds another id. A slot with no
-- record here is unknown, and one held back by the 30 cap or a poster's lost rank is ignored, not gone.
local function gone(view, own, id)
  if type(id) ~= "string" or view.byId[id] then return false end
  local qkey = id:match("^(.*)@")
  if not qkey or view.ignored[qkey] then return false end
  local mine = own[qkey]
  if type(mine) == "table" and next(mine) == nil then return true end
  local holds = view.slots[qkey]
  if holds == nil then return false end
  return holds ~= id
end

-- f4 (AC8): after each write to the member's own record, keep it bounded. Requests past requestDays leave; past
-- openRequests (10) the oldest answered ones leave, never an open one. Pledges and sends leave when their requisition
-- is gone or aged (closed past keepClosedDays), and pledges past pledgeDays. Derive reads none of what leaves (pledges
-- and sends only through view.byId), so the derived open items stay the same.
-- d780: then at most pledgesMax pledges and sendsMax sends stay: those on a requisition that is not open leave first,
-- then the oldest; the entry this action just wrote (keep, its id) always stays.
local function cap(view, entries, max, keep)
  local ids = {}
  for id in pairs(entries) do if id ~= keep then ids[#ids + 1] = id end end
  local extra = #ids + (entries[keep] ~= nil and 1 or 0) - max
  if extra <= 0 then return end
  local function rank(id)
    local req = view.byId[id]
    local e = entries[id]
    local at = type(e) == "table" and type(e.at) == "number" and e.at or -math.huge
    return (req and req.status == "open") and 1 or 0, at
  end
  table.sort(ids, function(a, b)
    local oa, ta = rank(a)
    local ob, tb = rank(b)
    if oa ~= ob then return oa < ob end
    if ta ~= tb then return ta < tb end
    return tostring(a) < tostring(b)
  end)
  for i = 1, math.min(extra, #ids) do entries[ids[i]] = nil end
end

local function prune(view, who, now, own, keep)
  local m = own[who.key]
  if type(m) ~= "table" then return end
  local L = view.ctx.limits or ns.LIMITS
  if type(m.requests) == "table" then
    local kept = {}
    for _, q in ipairs(m.requests) do
      if isOpenRequest(q, now, L) then kept[#kept + 1] = q end
    end
    local extra = #kept - L.openRequests
    if extra > 0 then
      local answered = {}
      for _, q in ipairs(view.requests) do
        if q.member == who.key and q.answer ~= nil then answered[q.at] = true end
      end
      local ats = {}
      for _, q in ipairs(kept) do if answered[q.at] then ats[#ats + 1] = q.at end end
      table.sort(ats)
      local drop = {}
      for i = 1, math.min(extra, #ats) do drop[ats[i]] = true end
      local out = {}
      for _, q in ipairs(kept) do if not drop[q.at] then out[#out + 1] = q end end
      kept = out
    end
    m.requests = kept
  end
  if type(m.pledges) == "table" then
    for id, p in pairs(m.pledges) do
      if gone(view, own, id) or view.aged[id]
          or not (type(p) == "table" and type(p.at) == "number" and p.at >= now - L.pledgeDays * DAY) then
        m.pledges[id] = nil
      end
    end
  end
  if type(m.sends) == "table" then
    for id in pairs(m.sends) do
      if gone(view, own, id) or view.aged[id] then m.sends[id] = nil end
    end
  end
  if type(m.pledges) == "table" then cap(view, m.pledges, L.pledgesMax, keep) end
  if type(m.sends) == "table" then cap(view, m.sends, L.sendsMax, keep) end
end

function Rules.post(view, who, args, now, own)
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local L = view.ctx.limits or ns.LIMITS
  if not int(args.slot, 1, L.slots) then return refuse("slot", "There is no free requisition slot.") end
  if not int(args.item, 1, math.huge) then return refuse("item", "Pick the item from the list or shift-click it.") end
  if not int(args.wanted, 1, L.wanted) then
    return refuse("wanted", "The amount wanted must be a whole number from 1 to " .. L.wanted .. ".")
  end
  local why = args.why
  if why ~= nil and type(why) ~= "string" then return refuse("why", "The reason must be text.") end
  why = trim(why or "")
  if #why > L.why then return refuse("why", "The reason is too long (" .. L.why .. " bytes at most).") end
  local key = ns.Key("q", args.slot, who.key)
  local open = 0
  for _, req in ipairs(view.reqs) do
    if req.key == key then return refuse("slot", "That requisition slot is still in use.") end
    if req.status == "open" then open = open + 1 end
  end
  if open >= L.openReqs then
    return refuse("full", "There are already " .. L.openReqs .. " open requisitions. Close one first.")
  end
  own[key] = { item = args.item, wanted = args.wanted, why = why, posted = now }
  return { id = key .. "@" .. now }
end

function Rules.pledge(view, who, args, now, own)
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  if req.status ~= "open" then return refuse("closed", "That requisition is closed.") end
  if not int(args.amount, 0, req.wanted) then
    return refuse("amount", "A pledge must be a whole number from 0 to " .. req.wanted .. ".")
  end
  local pledges = list(member(own, who.key), "pledges")
  pledges[req.id] = args.amount > 0 and { amount = args.amount, at = now } or nil
  prune(view, who, now, own, req.id)
  return { id = req.id, amount = args.amount }
end

function Rules.sent(view, who, args, now, own)
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  if req.status ~= "open" then return refuse("closed", "That requisition is closed.") end
  local L = view.ctx.limits or ns.LIMITS
  if not int(args.amount, 1, L.sent) then
    return refuse("amount", "The amount sent must be a whole number from 1 to " .. L.sent .. ".")
  end
  local s = req.sends[who.key]
  if s and s.status == "pending" then
    return refuse("pending", "You already have a delivery waiting on that requisition.")
  end
  list(member(own, who.key), "sends")[req.id] = { amount = args.amount, at = now }
  prune(view, who, now, own, req.id)
  return { id = req.id, amount = args.amount }
end

function Rules.receive(view, who, args, now, own)
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  local s = req.sends[args.member]
  local scode, smsg = sendRefusal(s)
  if scode then return refuse(scode, smsg) end
  return book(own, who, req.id, args.member, s.amount, s.at, now)
end

function Rules.record(view, who, args, now, own)
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  if req.status ~= "open" then return refuse("closed", "That requisition is closed.") end
  if type(args.member) ~= "string" or not view.ctx.roster[args.member] then
    return refuse("no-member", "That member is not in the guild.")
  end
  local L = view.ctx.limits or ns.LIMITS
  if not int(args.amount, 1, L.sent) then
    return refuse("amount", "The amount must be a whole number from 1 to " .. L.sent .. ".")
  end
  return book(own, who, req.id, args.member, args.amount, nil, now)
end

function Rules.unpledge(view, who, args, now, own)
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  if req.status ~= "open" then return refuse("closed", "That requisition is closed.") end
  local p = req.pledges[args.member]
  if not p then return refuse("no-pledge", "That pledge is gone.") end
  local u = list(ledger(own, who), "unpledges")
  u[#u + 1] = { req = req.id, member = args.member, at = p.at }
  return u[#u]
end

function Rules.unsend(view, who, args, now, own)
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  local s = req.sends[args.member]
  local scode, smsg = sendRefusal(s)
  if scode then return refuse(scode, smsg) end
  local u = list(ledger(own, who), "unsends")
  u[#u + 1] = { req = req.id, member = args.member, at = s.at }
  return u[#u]
end

function Rules.cancel(view, who, args, now, own)
  if not (who.bank or who.officer) then
    return refuse("not-allowed", "Only a bank character or an officer can cancel a requisition.")
  end
  local req, code, msg = find(view, args.id)
  if not req then return nil, code, msg end
  if req.status ~= "open" then return refuse("closed", "That requisition is closed.") end
  local slot = own[req.key]
  if req.poster == who.key and type(slot) == "table" and slot.posted == req.posted then
    slot.cancelled = now
  else
    local key = ns.Key("x", nil, who.key)
    own[key] = own[key] or {}
    own[key][req.id] = now
  end
  return { id = req.id, cancelled = now }
end

function Rules.ask(view, who, args, now, own)
  local L = view.ctx.limits or ns.LIMITS
  if not int(args.item, 1, math.huge) then return refuse("item", "Pick the item from the list or shift-click it.") end
  if not int(args.count, 1, L.askCount) then
    return refuse("count", "The count must be a whole number from 1 to " .. L.askCount .. ".")
  end
  local note = args.note
  if note ~= nil and type(note) ~= "string" then return refuse("note", "The note must be text.") end
  note = trim(note or "")
  if #note > L.note then return refuse("note", "The note is too long (" .. L.note .. " bytes at most).") end
  -- open = unexpired and unanswered, as Derive lists them and the selftest counts them
  local open = 0
  for _, q in ipairs(view.requests) do
    if q.member == who.key and q.answer == nil then open = open + 1 end
  end
  if open >= L.openRequests then return refuse("full", "You already have " .. L.openRequests .. " open requests.") end
  -- f10: a request is named by member and time, so one per second
  local mine = type(own[who.key]) == "table" and own[who.key].requests
  for _, q in ipairs(type(mine) == "table" and mine or {}) do
    if type(q) == "table" and q.at == now then return refuse("again", "Wait a moment before asking again.") end
  end
  local requests = list(member(own, who.key), "requests")
  local q = { item = args.item, count = args.count, note = note, at = now }
  requests[#requests + 1] = q
  prune(view, who, now, own)
  return q
end

local function answer(view, who, args, now, own, verdict, reason)
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local found
  for _, q in ipairs(view.requests) do
    if q.member == args.member and q.at == args.at then found = q end
  end
  if not found then return refuse("no-request", "That request is gone.") end
  local key = ns.Key("a", 1, who.key)
  own[key] = own[key] or {}
  local a = own[key]
  a[#a + 1] = { member = args.member, at = args.at, verdict = verdict, reason = reason, when = now }
  return a[#a]
end

function Rules.fulfil(view, who, args, now, own)
  return answer(view, who, args, now, own, "fulfilled", nil)
end

function Rules.decline(view, who, args, now, own)
  local L = view.ctx.limits or ns.LIMITS
  local reason = args.reason
  if reason ~= nil and type(reason) ~= "string" then return refuse("reason", "The reason must be text.") end
  reason = trim(reason or "")
  if #reason > L.reason then return refuse("reason", "The reason is too long (" .. L.reason .. " bytes at most).") end
  return answer(view, who, args, now, own, "declined", reason)
end

-- g1: first empty this character's own q slots whose requisition closed past keepClosedDays (view.aged; the key stays
-- and is published with an empty body). Then drop what names a requisition that is gone: its q record is here and is
-- empty or holds another id. A slot with no record here is unknown, and one held back by the 30 cap or a poster's lost
-- rank is ignored, not gone: both keep their entries. So no receipt or x~ entry leaves while a live slot body remains
-- (dropping receipts loses no contributions: book() adds to t1 at receipt time). Answers to requests past requestDays
-- leave too. In t, entries of members off the roster leave (d787); the rest of t is untouched.
function Rules.compact(view, who, args, now, own)
  local L = view.ctx.limits or ns.LIMITS
  local dropped = 0
  for key, body in pairs(own) do
    local family, _, author = ns.ParseKey(key)
    if family == "q" and author == who.key and type(body) == "table" and body.posted ~= nil
        and view.aged[key .. "@" .. tostring(body.posted)] then
      own[key] = {}
    end
  end
  local function keep(entries, test)
    if type(entries) ~= "table" then return entries end
    local out = {}
    for _, e in ipairs(entries) do
      if test(e) then out[#out + 1] = e else dropped = dropped + 1 end
    end
    return out
  end
  local function named(e) return not (type(e) == "table" and gone(view, own, e.req)) end
  for key, body in pairs(own) do
    local family = ns.ParseKey(key)
    if family == "l" then
      body.receipts = keep(body.receipts, named)
      body.unpledges = keep(body.unpledges, named)
      body.unsends = keep(body.unsends, named)
    elseif family == "x" then
      for id in pairs(body) do
        if gone(view, own, id) then body[id] = nil; dropped = dropped + 1 end
      end
    elseif family == "a" then
      own[key] = keep(body, function(e) return isOpenRequest(e, now, L) end)
    elseif family == "t" and type(body) == "table" then
      for m in pairs(body) do
        if not view.ctx.roster[m] then body[m] = nil; dropped = dropped + 1 end
      end
    end
  end
  return { dropped = dropped }
end

-- A bank character's minimum for an item (AC9): own n1[item] = { m, r = 1 | nil, t = now }; min 0 clears it as a
-- tombstone. At each write an own tombstone older than minClearDays leaves when no other bank character holds an
-- entry for the item (d1078 GC b). Past minItems entries it evicts (d1088): own tombstones no other author holds,
-- then own entries another author beats, oldest t first in each; a tombstone over another's entry is never evicted.
function Rules.minimum(view, who, args, now, own)
  local L = view.ctx.limits or ns.LIMITS
  if not who.bank then return refuse("not-allowed", NOT_ALLOWED) end
  local item, min = args.item, args.min
  if not int(item, 1, 2147483647) then return refuse("item", "Pick the item from the list or shift-click it.") end
  if not int(min, 0, L.minimum) then
    return refuse("min", "The minimum must be a whole number from 0 to " .. L.minimum .. ".")
  end
  local cur = view.mins and view.mins[item]
  if min == 0 and not (cur and cur.min > 0) then return refuse("no-minimum", "There is no minimum for that item.") end
  local key = ns.Key("n", 1, who.key)
  local old = type(own[key]) == "table" and own[key] or {}
  local counted = not view.ignored[key]
  -- what the view says about an own entry: another author holds one too; another author's entry wins
  local function others(id)
    local m = view.mins and view.mins[id]
    return (m and m.n or 0) - ((counted and old[id] ~= nil) and 1 or 0) > 0
  end
  local function beaten(id)
    local m = view.mins and view.mins[id]
    return counted and m ~= nil and m.by ~= who.key
  end
  local body, count = {}, 0
  for id, e in pairs(old) do
    local tomb = type(e) == "table" and e.m == 0
    if id ~= item and not (tomb and type(e.t) == "number" and e.t < now - L.minClearDays * DAY and not others(id)) then
      body[id] = e
      count = count + 1
    end
  end
  body[item] = { m = min, r = (min > 0 and args.raid) and 1 or nil, t = now }
  count = count + 1
  if count > L.minItems then
    local tombs, beats = {}, {}
    for id, e in pairs(body) do
      if id ~= item then
        if type(e) == "table" and e.m == 0 and not others(id) then tombs[#tombs + 1] = id
        elseif beaten(id) then beats[#beats + 1] = id end
      end
    end
    local function at(id) return type(body[id]) == "table" and tonumber(body[id].t) or 0 end
    local function older(a, b)
      local ta, tb = at(a), at(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end
    table.sort(tombs, older)
    table.sort(beats, older)
    for _, group in ipairs({ tombs, beats }) do
      for _, id in ipairs(group) do
        if count <= L.minItems then break end
        body[id] = nil
        count = count - 1
      end
    end
    if count > L.minItems then
      return refuse("full", "The minimums list is full (" .. L.minItems .. " items). A cleared item keeps its place "
        .. "until the other bank characters' settings for it are gone.")
    end
  end
  own[key] = body
  return { item = item }
end
