-- CraftBoard: the work board rules. Post, join (W, C, X actor-bound; F bound per field, provisional or hinted when
-- relayed), effective claim, state, hash, board digest and compare, cleanup, lists and the alert decision.
-- Pure Lua 5.1: no client calls, no globals. State and time are passed in. Takes decoded message tables.
local _, ns = ...
local Board = {}
ns.CraftBoard = Board

local FUTURE = 300            -- any time later than now + 300 is refused
local MAX_OPEN = 10           -- open requests per requester
local MAX_CLAIMS = 20         -- claimers kept per request
local NOTE_MAX = 80           -- raw bytes
local DAY = 86400
local KEEP_DAYS = 2           -- expired and cancelled stay this long
local HISTORY = 20            -- done requests kept
local HISTORY_DAYS = 7
local CAP = 135               -- stored held requests (f1081: the worst case fits 600 KB)
local PROVISIONAL_CAP = 50    -- stored provisional requests (d207 part 2), apart from CAP
local PROV_PER = 10           -- provisionals per relaying sender and per requester (f1077, d214)
local MAX_KEPT = 15           -- stored held records of any state per requester (f1073, d215)
local OFF_ROSTER = 5          -- claims and drops per record whose keys are off the roster (f1073)
local WHAT_MAX = 13           -- "i"/"s" and at most 12 digits (f1070)
local HOURS = { [1] = true, [4] = true, [12] = true, [24] = true, [48] = true }

-- Adler-32 of the bytes, as "%04x%04x" of b, a (copy of addon/GuildKOS/Codec.lua:11-18).
local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end
Board.Adler32 = adler32

-- Character key: realm cut, lowercased, trimmed, inner whitespace collapsed.
local function key(name)
  if type(name) ~= "string" then return nil end
  local k = name:gsub("%-.*$", ""):lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if k == "" then return nil end
  return k
end

local function isInt(v, lo, hi)
  return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

local function isTime(v) return isInt(v, 0, 2 ^ 40) end

-- Cut to at most max bytes without splitting a UTF-8 sequence.
local function truncUtf8(s, max)
  if #s <= max then return s end
  local n = max
  while n > 0 do
    local c = s:byte(n + 1)
    if not c or c < 0x80 or c >= 0xC0 then break end
    n = n - 1
  end
  return s:sub(1, n)
end

local function onRoster(roster, k) return roster ~= nil and k ~= nil and roster[k] ~= nil end

local function can(canMake, what)
  if type(canMake) == "function" then return canMake(what) and true or false end
  if type(canMake) == "table" then return canMake[what] and true or false end
  return false
end

-- (at, Adler-32 of id/key, key): the claim order used by Effective and the claim cap.
local function claimBefore(id, ka, ata, kb, atb)
  if ata ~= atb then return ata < atb end
  local ha, hb = adler32(id .. "/" .. ka), adler32(id .. "/" .. kb)
  if ha ~= hb then return ha < hb end
  return ka < kb
end

-- Static fields -------------------------------------------------------------------------------------------------

-- Checks the static fields of a W or F; returns the requester key or nil.
local function checkStatic(m)
  if type(m.id) ~= "string" or not isTime(m.postedAt) then return nil end
  local idKey = key(m.byName)
  if not idKey or m.id ~= tostring(m.postedAt) .. "-" .. idKey then return nil end -- exactly, no padding (f1070)
  if type(m.what) ~= "string" or #m.what > WHAT_MAX or not m.what:match("^[is]%d+$") then return nil end
  if not isInt(m.qty, 1, 200) or type(m.mats) ~= "boolean" or not isInt(m.tip, 0, 9999) then return nil end
  if m.note ~= nil and (type(m.note) ~= "string" or #m.note > NOTE_MAX) then return nil end
  if not isTime(m.postedAt) or not isTime(m.expiresAt) then return nil end
  if (m.expiresAt - m.postedAt) % 3600 ~= 0 or not HOURS[(m.expiresAt - m.postedAt) / 3600] then return nil end
  return idKey
end

local function staticText(r)
  return table.concat({ r.byName, r.what, r.qty, r.mats and 1 or 0, r.tip, r.postedAt, r.expiresAt, #r.note, r.note }, "\n")
end

local function newRecord(m, by)
  return { id = m.id, by = by, byName = m.byName, what = m.what, qty = m.qty, mats = m.mats, tip = m.tip,
           note = m.note or "", postedAt = m.postedAt, expiresAt = m.expiresAt,
           claims = {}, drops = {}, releasedAt = 0 }
end

-- Static fields of a held request come from the requester only (W, or an F the requester sent): theirs replace
-- mine (d206). This also repairs a forged copy a newcomer took whole before the requester was heard.
local function setStatic(req, m)
  local theirs = { byName = m.byName, what = m.what, qty = m.qty, mats = m.mats, tip = m.tip, postedAt = m.postedAt,
                   expiresAt = m.expiresAt, note = m.note or "" }
  if staticText(req) == staticText(theirs) then return false end
  req.byName, req.what, req.qty, req.mats, req.tip = m.byName, m.what, m.qty, m.mats, m.tip
  req.note, req.expiresAt = theirs.note, m.expiresAt
  return true
end

-- Dynamic joins (all monotone) ----------------------------------------------------------------------------------

local function joinClaim(req, k, name, at)
  local c = req.claims[k]
  if c and (c.at > at or (c.at == at and c.name <= name)) then return false end
  req.claims[k] = { name = name, at = at }
  local n, worst = 0, nil
  for ck, cc in pairs(req.claims) do
    n = n + 1
    if not worst or claimBefore(req.id, worst, req.claims[worst].at, ck, cc.at) then worst = ck end
  end
  if n > MAX_CLAIMS then req.claims[worst] = nil end
  return true
end

local function joinDrop(req, k, at)
  if req.drops[k] and req.drops[k] >= at then return false end
  req.drops[k] = at
  return true
end

local function joinRelease(req, at)
  if req.releasedAt >= at then return false end
  req.releasedAt = at
  return true
end

local function joinFinal(req, kind, at)
  local f = req.final
  if f and (f.at > at or (f.at == at and (f.kind == kind or f.kind == "cancel"))) then return false end
  req.final = { kind = kind, at = at }
  return true
end

-- Reading -------------------------------------------------------------------------------------------------------

function Board.Effective(req)
  local bestK, bestAt
  for k, c in pairs(req.claims or {}) do
    if c.at > (req.drops[k] or -1) and c.at > (req.releasedAt or 0) then
      if not bestK or claimBefore(req.id, k, c.at, bestK, bestAt) then bestK, bestAt = k, c.at end
    end
  end
  if not bestK then return nil end
  return { key = bestK, name = req.claims[bestK].name, at = bestAt }
end

function Board.State(req, now)
  if req.final then return req.final.kind end
  if now >= req.expiresAt then return "expired" end
  if Board.Effective(req) then return "claimed" end
  return "open"
end

local function isOpen(req, now)
  local s = Board.State(req, now)
  return s == "open" or s == "claimed"
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- Adler-32 of the canonical F form.
function Board.Hash(req)
  local claims, drops = {}, {}
  for _, k in ipairs(sortedKeys(req.claims)) do
    claims[#claims + 1] = k .. "," .. req.claims[k].name .. "," .. req.claims[k].at
  end
  for _, k in ipairs(sortedKeys(req.drops)) do drops[#drops + 1] = k .. "," .. req.drops[k] end
  return adler32(table.concat({ req.id, staticText(req), table.concat(claims, ";"), table.concat(drops, ";"),
    req.releasedAt, req.final and req.final.kind or "", req.final and req.final.at or "" }, "\n"))
end

local function byPosted(a, b)
  if a.postedAt ~= b.postedAt then return a.postedAt < b.postedAt end
  return a.id < b.id
end

-- Final first, then expired, then open; oldest posted first within each (d215).
local function evictRank(r, now)
  if r.final then return 0 end
  if Board.State(r, now) == "expired" then return 1 end
  return 2
end

local function evictBefore(now)
  return function(a, b)
    local ra, rb = evictRank(a, now), evictRank(b, now)
    if ra ~= rb then return ra < rb end
    return byPosted(a, b)
  end
end

-- Held requests over CAP: final ones first, then expired, then the oldest posted, are removed (remove(id) does it).
-- Provisionals over PROVISIONAL_CAP: the oldest posted. The two caps count apart (d207 part 2).
-- own (optional, { [key] = true }): an open held request by one of these keys is never removed (d210); it still
-- counts toward CAP.
local function capBoard(board, now, remove, own)
  local all, prov, held = {}, {}, 0
  for _, r in pairs(board) do
    if r.provisional then
      prov[#prov + 1] = r
    else
      held = held + 1
      if not (own and own[r.by] and isOpen(r, now)) then all[#all + 1] = r end
    end
  end
  -- f1077: over PROV_PER per relaying sender, then per requester, the oldest posted within that group go first,
  -- so one sender's burst never removes another sender's provisionals. Then the global PROVISIONAL_CAP.
  table.sort(prov, byPosted)
  for _, field in ipairs({ "provisional", "by" }) do
    local seen, kept = {}, {}
    for i = #prov, 1, -1 do
      local r, g = prov[i], prov[i][field]
      seen[g] = (seen[g] or 0) + 1
      if seen[g] > PROV_PER then remove(r.id) else kept[#kept + 1] = r end
    end
    prov = {}
    for i = #kept, 1, -1 do prov[#prov + 1] = kept[i] end
  end
  for i = 1, #prov - PROVISIONAL_CAP do remove(prov[i].id) end
  if held <= CAP then return end
  table.sort(all, evictBefore(now))
  for i = 1, math.min(#all, held - CAP) do remove(all[i].id) end
end

local function countOpen(board, by, now)
  local n = 0
  for _, r in pairs(board) do
    if r.by == by and not r.provisional and isOpen(r, now) then n = n + 1 end -- relays cannot fill a requester's 10
  end
  return n
end

-- d215 (f1038, f1078): a requester keeps at most MAX_KEPT held records of any state. Run after a new record went in
-- (the new one included): over the cap, the oldest record that is not open goes (final first, then expired), which
-- may be the new one. Only when none is left to go is the new record taken out again: returns false.
local function capKept(board, by, now, newId, remove)
  local n, out = 0, {}
  for _, r in pairs(board) do
    if r.by == by and not r.provisional then
      n = n + 1
      if not isOpen(r, now) then out[#out + 1] = r end
    end
  end
  if n <= MAX_KEPT then return true end
  if #out == 0 then
    board[newId] = nil
    return false
  end
  table.sort(out, evictBefore(now))
  for i = 1, math.min(#out, n - MAX_KEPT) do remove(out[i].id) end
  return true
end

-- f1073: a record keeps at most OFF_ROSTER claims and OFF_ROSTER drops whose keys are off the roster. The ones kept
-- are the earliest (claims in claim order, drops by time, then key), so every arrival order keeps the same ones.
local function trimOffRoster(req, roster)
  if roster == nil then return end
  local offC, offD = {}, {}
  for k, c in pairs(req.claims) do if not roster[k] then offC[#offC + 1] = { k = k, at = c.at } end end
  for k, at in pairs(req.drops) do if not roster[k] then offD[#offD + 1] = { k = k, at = at } end end
  table.sort(offC, function(a, b) return claimBefore(req.id, a.k, a.at, b.k, b.at) end)
  table.sort(offD, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.k < b.k
  end)
  for i = OFF_ROSTER + 1, #offC do req.claims[offC[i].k] = nil end
  for i = OFF_ROSTER + 1, #offD do req.drops[offD[i].k] = nil end
end

-- Post ----------------------------------------------------------------------------------------------------------

-- Bytes below 0x20 never survive the wire (CraftWire.Unescape drops them), so they are not stored either:
-- the requester's copy then hashes the same as every other copy.
local function cleanNote(note) return ((note or ""):gsub("[%z\1-\31]", "")) end

-- fields = { by, byName, what, qty, mats, tip, hours, note }. Returns the stored request, or nil and why.
function Board.Post(board, f, now, openByRequester)
  local by = key(f.by)
  if not by or key(f.byName) ~= by then return nil, "requester" end
  if not isInt(f.hours, 1, 48) or not HOURS[f.hours] then return nil, "duration" end
  if f.note ~= nil and type(f.note) ~= "string" then return nil, "note" end
  local m = { id = string.format("%d-%s", now, by), byName = f.byName, what = f.what, qty = f.qty, mats = f.mats,
              tip = f.tip, note = truncUtf8(cleanNote(f.note), NOTE_MAX), postedAt = now, expiresAt = now + f.hours * 3600 }
  if not checkStatic(m) then return nil, "limit" end
  if board[m.id] then return nil, "same second" end
  if (openByRequester or countOpen(board, by, now)) >= MAX_OPEN then return nil, "too many open" end
  local req = newRecord(m, by)
  board[m.id] = req
  if not capKept(board, by, now, m.id, function(id) board[id] = nil end) then return nil, "too many kept" end
  return req
end

-- Apply ---------------------------------------------------------------------------------------------------------

-- remove(id) for the cap step inside Apply: the alerted mark goes with the request (f1071).
local function remover(board, alerted)
  return function(id)
    board[id] = nil
    if alerted then alerted[id] = nil end
  end
end

-- f1080: a provisional just confirmed counts like a new record: MAX_OPEN, then the kept cap (which may evict it).
-- On a refusal the record goes, with its alerted mark. Returns true, or false and why.
local function admit(board, req, now, alerted)
  local remove = remover(board, alerted)
  if isOpen(req, now) and countOpen(board, req.by, now) > MAX_OPEN then
    remove(req.id)
    return false, "too many open"
  end
  if not capKept(board, req.by, now, req.id, remove) then
    remove(req.id)
    return false, "too many kept"
  end
  if board[req.id] == nil then return false, "too many kept" end
  return true
end

local function applyW(board, m, sender, roster, now, alerted, own)
  local by = checkStatic(m)
  if not by or by ~= sender or not onRoster(roster, by) then return false, "actor" end
  if m.postedAt > now + FUTURE then return false, "future" end
  local req = board[m.id]
  if req then
    local promoted = req.provisional ~= nil
    req.provisional = nil -- the requester's own W confirms a provisional (d207 part 2)
    if promoted then
      local ok, why = admit(board, req, now, alerted)
      if not ok then return false, why end
    end
    return setStatic(req, m) or promoted
  end
  if countOpen(board, by, now) >= MAX_OPEN then return false, "too many open" end
  board[m.id] = newRecord(m, by)
  if not capKept(board, by, now, m.id, remover(board, alerted)) then return false, "too many kept" end
  capBoard(board, now, remover(board, alerted), own)
  return true
end

-- A provisional holds no claims (d207 part 2), so a C for it is refused.
local function applyC(board, m, sender, roster, now)
  local req = board[m.id]
  if not req then return false, "unknown" end
  if req.provisional then return false, "provisional" end
  local k = key(m.name)
  if not k or k ~= sender or k == req.by or not onRoster(roster, k) then return false, "actor" end
  if not isTime(m.at) or m.at < req.postedAt or m.at > req.expiresAt then return false, "time" end
  if m.at > now + FUTURE then return false, "future" end
  return joinClaim(req, k, m.name, m.at)
end

-- Any X from the requester clears a reported hint (d207 part 4). On a provisional only the requester's release,
-- done or cancel is taken (it stays provisional), so a requester who never posted it can cancel it everywhere.
local function applyX(board, m, sender, roster, now)
  local req = board[m.id]
  if not req then return false, "unknown" end
  local k = key(m.name)
  if not k or k ~= sender or not onRoster(roster, k) then return false, "actor" end
  if not isTime(m.at) or m.at < req.postedAt then return false, "time" end
  if m.at > now + FUTURE then return false, "future" end
  if m.kind ~= "drop" and m.kind ~= "release" and m.kind ~= "done" and m.kind ~= "cancel" then return false, "kind" end
  if m.kind ~= "drop" and k ~= req.by then return false, "actor" end
  if m.kind == "drop" and req.provisional then return false, "provisional" end
  local cleared = k == req.by and req.reported ~= nil
  if cleared then req.reported = nil end
  if m.kind == "drop" then return joinDrop(req, k, m.at) or cleared end
  if m.kind == "release" then return joinRelease(req, m.at) or cleared end
  return joinFinal(req, m.kind, m.at) or cleared
end

-- F is relayed: the requester must be on the roster and every time in bounds; claim and drop names may be leavers
-- (f1022). From the requester-sender an F is taken whole, and confirms a provisional. Otherwise (d206, d207):
-- an id not held is stored provisional (static fields only); a provisional takes nothing more; a held id takes
-- only the sender's own claim and drop, and a final it carries becomes the reported hint, never the state.
local function applyF(board, m, sender, roster, now, alerted, own)
  local by = checkStatic(m)
  if not by or not onRoster(roster, by) then return false, "roster" end
  local limit = now + FUTURE
  if m.postedAt > limit then return false, "future" end
  if type(m.claims) ~= "table" or type(m.drops) ~= "table" then return false, "format" end
  local claims, drops = {}, {}
  for _, c in ipairs(m.claims) do
    local k = key(c.name)
    if not k or k == by then return false, "roster" end
    if not isTime(c.at) or c.at < m.postedAt or c.at > m.expiresAt or c.at > limit then return false, "time" end
    claims[#claims + 1] = { k = k, name = c.name, at = c.at }
  end
  for _, d in ipairs(m.drops) do
    local k = key(d.name)
    if not k then return false, "roster" end
    if not isTime(d.at) or d.at < m.postedAt or d.at > limit then return false, "time" end
    drops[#drops + 1] = { k = k, at = d.at }
  end
  local rel = m.releasedAt or 0
  if not isTime(rel) or (rel ~= 0 and (rel < m.postedAt or rel > limit)) then return false, "time" end
  if m.finalKind ~= nil then
    if m.finalKind ~= "done" and m.finalKind ~= "cancel" then return false, "format" end
    if not isTime(m.finalAt) or m.finalAt < m.postedAt or m.finalAt > limit then return false, "time" end
  elseif m.finalAt ~= nil then
    return false, "format"
  end

  local changed = false
  local req = board[m.id]
  local whole = sender == by
  if req == nil and not whole then
    req = newRecord(m, by)
    req.provisional = sender
    board[m.id] = req
    capBoard(board, now, remover(board, alerted), own)
    return true
  end
  if req and req.provisional and not whole then return false end
  local inserted = req == nil
  if inserted then
    if countOpen(board, by, now) >= MAX_OPEN then return false, "too many open" end
    req = newRecord(m, by)
    board[m.id] = req
    changed = true
  elseif whole then
    if req.provisional or req.reported then changed = true end
    req.provisional, req.reported = nil, nil
    if setStatic(req, m) then changed = true end
  end
  for _, c in ipairs(claims) do
    if (whole or c.k == sender) and joinClaim(req, c.k, c.name, c.at) then changed = true end
  end
  for _, d in ipairs(drops) do
    if (whole or d.k == sender) and joinDrop(req, d.k, d.at) then changed = true end
  end
  trimOffRoster(req, roster)
  if whole and joinRelease(req, rel) then changed = true end
  if whole and m.finalKind and joinFinal(req, m.finalKind, m.finalAt) then changed = true end
  if not whole and m.finalKind and not req.final then
    local h = req.reported
    if not h or h.state ~= m.finalKind or h.by ~= sender then
      req.reported = { state = m.finalKind, by = sender }
      changed = true
    end
  end
  if inserted then
    -- d215: the cap step runs on the whole record (a final F counts as final); the new one may be the one that goes
    if not capKept(board, by, now, m.id, remover(board, alerted)) then return false, "too many kept" end
    capBoard(board, now, remover(board, alerted), own)
  end
  return changed
end

-- msg.t in W, C, X (actor-bound to senderKey), F (relayed, bound to senderKey, see applyF). Returns changed, why.
-- A refusal changes nothing. alerted (optional) loses the marks of requests the cap step removes; own (optional,
-- { [key] = true }) protects those keys' open requests from the cap step (d210).
function Board.Apply(board, msg, senderKey, roster, now, alerted, own)
  if type(msg) ~= "table" or type(msg.id) ~= "string" then return false, "format" end
  if msg.t == "W" then return applyW(board, msg, senderKey, roster, now, alerted, own) end
  if msg.t == "C" then return applyC(board, msg, senderKey, roster, now) end
  if msg.t == "X" then return applyX(board, msg, senderKey, roster, now) end
  if msg.t == "F" then return applyF(board, msg, senderKey, roster, now, alerted, own) end
  return false, "unknown"
end

-- B entry (d207 part 2): a provisional is confirmed when its requester lists it with the same hash.
-- now and alerted (f1080): the promotion obeys MAX_OPEN and the kept cap; a refused one removes the record and its
-- alerted mark. Without now (older callers) only the confirm itself runs.
function Board.Promote(board, id, senderKey, hash, now, alerted)
  local req = board[id]
  if not req or not req.provisional or senderKey ~= req.by or hash ~= Board.Hash(req) then return false end
  req.provisional = nil
  if now == nil then return true end
  return (admit(board, req, now, alerted))
end

-- d207 part 1: would my F change the record their F describes, under their rules? Their F is taken as held
-- (applied as from its requester); mine is applied from myKey. True when the hash moved.
function Board.WouldChange(theirF, myF, myKey, roster, now)
  local by = type(theirF) == "table" and key(theirF.byName)
  local b = {}
  if not by or not applyF(b, theirF, by, roster, now) or not b[theirF.id] then return false end
  local before = Board.Hash(b[theirF.id])
  if type(myF) ~= "table" or myF.id ~= theirF.id then return false end
  applyF(b, myF, myKey, roster, now)
  return Board.Hash(b[theirF.id]) ~= before
end

-- Digest and compare --------------------------------------------------------------------------------------------

-- A provisional is left out (d208): only the requester's word puts a request in my digest.
function Board.Digest(board, now)
  local entries, parts = {}, {}
  for _, id in ipairs(sortedKeys(board)) do
    if not board[id].provisional and isOpen(board[id], now) then
      local h = Board.Hash(board[id])
      entries[#entries + 1] = { id = id, hash = h }
      parts[#parts + 1] = id .. "," .. h
    end
  end
  return entries, adler32(table.concat(parts, ";"))
end

-- part = { did, pi, pn, from, to, entries }. Returns the ids to send as F and the entries to ask for with R:b.
function Board.Compare(board, part, now)
  local theirs = {}
  for _, e in ipairs(part.entries or {}) do theirs[e.id] = e.hash end
  local send, ask = {}, {}
  for _, id in ipairs(sortedKeys(board)) do
    local inRange = (part.from == nil or id >= part.from) and (part.to == nil or id <= part.to)
    local h = theirs[id]
    if h ~= nil then
      if h ~= Board.Hash(board[id]) then send[#send + 1] = id end
    elseif inRange and isOpen(board[id], now) then
      send[#send + 1] = id
    end
  end
  for _, e in ipairs(part.entries or {}) do
    if not board[e.id] then ask[#ask + 1] = { id = e.id } end
  end
  return send, ask
end

-- want = { t, subject, version, askers }: an F want stands while I hold the id and my hash is still `version`.
function Board.StillWanted(board, want, now)
  if want.t == "F" then
    local req = board[want.subject]
    return req ~= nil and Board.Hash(req) == want.version
  end
  return want.t == "B"
end

-- Cleanup -------------------------------------------------------------------------------------------------------

function Board.Cleanup(board, alerted, now, own)
  local function remove(id)
    board[id] = nil
    if alerted then alerted[id] = nil end
  end
  local done = {}
  for id, r in pairs(board) do
    if r.provisional then
      if now >= r.expiresAt then remove(id) end -- no grace for a provisional (d207 part 2)
    elseif r.final and r.final.kind == "done" then
      if now >= r.final.at + HISTORY_DAYS * DAY then remove(id) else done[#done + 1] = r end
    elseif r.final then
      if now >= r.final.at + KEEP_DAYS * DAY then remove(id) end
    elseif now >= r.expiresAt + KEEP_DAYS * DAY then
      remove(id)
    end
  end
  table.sort(done, function(a, b)
    if a.final.at ~= b.final.at then return a.final.at > b.final.at end
    return a.id > b.id
  end)
  for i = HISTORY + 1, #done do remove(done[i].id) end

  capBoard(board, now, remove, own)

  -- f1071: a mark whose request is gone, or whose expiresAt is over KEEP_DAYS old, is dropped.
  if alerted then
    for id, at in pairs(alerted) do
      if board[id] == nil or type(at) ~= "number" or now - at > KEEP_DAYS * DAY then alerted[id] = nil end
    end
  end
end

-- Lists and alert -----------------------------------------------------------------------------------------------

local function claimedByMine(req, myKeys)
  for k, c in pairs(req.claims) do
    if myKeys[k] and c.at > (req.drops[k] or -1) and c.at > req.releasedAt then return true end
  end
  return false
end

-- Returns forYou, allOpen, mine (lists of requests). Leavers' requests are hidden, never changed. A provisional
-- is listed in allOpen only, never in forYou (d207 part 2); a request with a reported hint stays in forYou (d213).
function Board.Lists(board, now, myKeys, canMake, roster)
  myKeys = myKeys or {}
  local forYou, allOpen, mine = {}, {}, {}
  for _, r in pairs(board) do
    if isOpen(r, now) and onRoster(roster, r.by) then
      allOpen[#allOpen + 1] = r
      if not myKeys[r.by] and not r.provisional and can(canMake, r.what) then forYou[#forYou + 1] = r end
    end
    if myKeys[r.by] or claimedByMine(r, myKeys) then mine[#mine + 1] = r end
  end
  table.sort(forYou, byPosted)
  table.sort(allOpen, byPosted)
  table.sort(mine, byPosted)
  return forYou, allOpen, mine
end

function Board.ShouldAlert(req, now, myKeys, canMake, alerted)
  if alerted and alerted[req.id] then return false end
  if myKeys and myKeys[req.by] then return false end
  if req.provisional or req.reported then return false end
  return isOpen(req, now) and can(canMake, req.what)
end

return Board
