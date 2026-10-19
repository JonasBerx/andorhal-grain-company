-- Annals AnnalsStore: the saved-data shape (plan D5) and every change to it: roster reads, the gone rule (D6),
-- level rises and own dings (D7), guild-log joins and departures, returners, pruning and the do-not-invite list.
-- Pure Lua 5.1, no client calls: data and time are passed in. Members come in the Compat.GuildMembers shape, log
-- entries in the Compat.GuildEvents shape (ages, oldest first).
local _, ns = ...
local Store = {}
ns.AnnalsStore = Store

local Rules = ns.AnnalsRules

-- The guild's table in the saved data, created on first use. Guilds are keyed by name, so alts never mix.
function Store.Guild(db, guildName)
  db.guilds = db.guilds or {}
  local G = db.guilds[guildName]
  if not G then
    G = { chars = {}, former = {}, dni = {} }
    db.guilds[guildName] = G
  end
  G.actors = G.actors or {} -- with ranks (every read), the one G shape the demo shares (plan Task 8)
  return G
end

-- Rises ----------------------------------------------------------------------------------------------------------

-- One rise as "to:after:width;" with width = by - after; from is the previous entry's to (or fl), so it is not stored.
-- Times are whole server seconds; floored so the string always decodes.
-- Every added rise raises G.rv (the rises version), so a cache of rises sees own dings too (Revision 2 C2).
local function addRise(G, rec, to, after, by)
  after, by = math.floor(after), math.floor(by)
  rec.d = (rec.d or "") .. to .. ":" .. after .. ":" .. (by - after) .. ";"
  G.rv = (G.rv or 0) + 1
end

-- The only reader of rec.d: { { from, to, after, by }, ... }, oldest first.
function Store.Rises(rec)
  local out = {}
  local from = rec.fl
  for to, after, width in string.gmatch(rec.d or "", "(%d+):(%d+):(%-?%d+);") do
    to, after = tonumber(to), tonumber(after)
    out[#out + 1] = { from = from, to = to, after = after, by = after + tonumber(width) }
    from = to
  end
  return out
end

-- PLAYER_LEVEL_UP for the own character: an exact window, and a wide one below when the stored level is stale.
-- Nothing without a rec (the first read creates it at the new level).
function Store.OwnDing(G, guid, level, now)
  local rec = G.chars and G.chars[guid]
  if not rec or type(level) ~= "number" or type(rec.l) ~= "number" or level <= rec.l then return false end
  if rec.l < level - 1 then addRise(G, rec, level - 1, rec.ls, now) end
  addRise(G, rec, level, now, now)
  rec.l = level
  return true
end

-- Rank history (plan D3, R11) --------------------------------------------------------------------------------------

-- Position of a name in an append-only list (G.ranks, G.actors), appended when new.
local function intern(G, field, name)
  G[field] = G[field] or {}
  local list = G[field]
  for i, v in ipairs(list) do if v == name then return i end end
  list[#list + 1] = name
  return #list
end

-- rec.rk entries "<s><id>:<after>:<width>[:<atOff>:<actorId>];", oldest first, decoded to tables and back.
local function decodeRanks(rec)
  local out = {}
  for s, id, after, width, rest in string.gmatch(rec.rk or "", "([%+%-])(%d+):(%-?%d+):(%-?%d+)([^;]*);") do
    local c = { up = s == "+", id = tonumber(id), after = tonumber(after) }
    c.by = c.after + tonumber(width)
    local atOff, actorId = rest:match("^:(%-?%d+):(%d+)$")
    if atOff then c.atOff, c.actorId = tonumber(atOff), tonumber(actorId) end
    out[#out + 1] = c
  end
  return out
end

local function encodeRanks(list)
  local parts = {}
  for i, c in ipairs(list) do
    local p = (c.up and "+" or "-") .. c.id .. ":" .. c.after .. ":" .. (c.by - c.after)
    if c.atOff then p = p .. ":" .. c.atOff .. ":" .. c.actorId end
    parts[i] = p .. ";"
  end
  return table.concat(parts)
end

-- d308: a change back to the rank the last change came from, within RANK_FOLD of that change (and after any
-- return), cancels it, so flips fold away; then only the newest RANK_KEEP are kept, and rec.fr moves to the rank
-- the oldest kept change starts from.
local function addRank(G, rec, name, up, after, by)
  after, by = math.floor(after), math.floor(by)
  local id = intern(G, "ranks", name)
  local list = decodeRanks(rec)
  local last = list[#list]
  local lastFrom = list[#list - 1] and list[#list - 1].id or rec.fr
  if last and lastFrom == id and by - last.after <= Rules.RANK_FOLD and last.after >= (rec.ret or 0) then
    list[#list] = nil
    -- review r1, r3: the cancelled change's log time stays used ("<s><t>;" in rec.ru, newest RANK_USED_KEEP): the
    -- matched log time, or for an unmatched change its read time by, so an entry within RANK_USED_RADIUS of it
    -- (which that change may own; d314: LogTime's error span, not an hour) is no one's.
    local used = {}
    for u in string.gmatch(rec.ru or "", "[%+%-]%-?%d+;") do used[#used + 1] = u end
    used[#used + 1] = (last.up and "+" or "-") .. (last.atOff and last.after + last.atOff or last.by) .. ";"
    while #used > Rules.RANK_USED_KEEP do table.remove(used, 1) end
    rec.ru = table.concat(used)
  else
    list[#list + 1] = { up = up, id = id, after = after, by = by }
  end
  while #list > Rules.RANK_KEEP do rec.fr = table.remove(list, 1).id end
  rec.rk = list[1] and encodeRanks(list) or nil
end

-- The only reader of rec.rk: { { from, to, up, after, by, at, actor }, ... }, oldest first. at and actor are nil
-- until a guild-log entry matched; at is the raw log time and may lie outside [after, by].
function Store.RankChanges(G, rec)
  local out = {}
  local ranks, actors = G.ranks or {}, G.actors or {}
  local from = rec and rec.fr and ranks[rec.fr]
  local prevBy
  for _, c in ipairs(rec and decodeRanks(rec) or {}) do
    local to = ranks[c.id]
    -- review f4: the first change after a return starts from an unknown rank (the return read is a fill).
    if rec.ret and c.after >= rec.ret and (prevBy == nil or prevBy < rec.ret) then from = nil end
    prevBy = c.by
    out[#out + 1] = {
      from = from, to = to, up = c.up, after = c.after, by = c.by,
      at = c.atOff and c.after + c.atOff or nil, actor = c.actorId and actors[c.actorId] or nil,
    }
    from = to
  end
  return out
end

-- Matches promote/demote entries (already reduced to { up, t, rank, actor }) to the rec's unmatched changes.
-- A change takes the latest candidate in its slack window; an entry within an hour of a matched change of the same
-- direction is the one that change already used (LogTime moves by an hour between passes, Revision 2 C1).
local function matchRanks(G, rec, entries)
  local list = decodeRanks(rec)
  local changed = false
  for _, c in ipairs(list) do
    if not c.atOff then
      local best
      for _, e in ipairs(entries) do
        local ok = e.up == c.up and e.t >= c.after - Rules.RANK_SLACK and e.t <= c.by + Rules.RANK_SLACK
          and (type(e.rank) ~= "string" or e.rank == G.ranks[c.id])
        local inOwn = e.t >= c.after and e.t <= c.by
        if ok and not inOwn then
          -- review f1: an entry outside this change's window that another same-direction change could also claim
          -- (inside that one's window or slack) cannot be told apart: no actor beats a wrong one.
          for _, o in ipairs(list) do
            if o ~= c and o.up == e.up and e.t >= o.after - Rules.RANK_SLACK and e.t <= o.by + Rules.RANK_SLACK then
              ok = false break
            end
          end
        end
        if ok then
          -- review r1: an entry a folded-away change used stays used.
          for s, t in string.gmatch(rec.ru or "", "([%+%-])(%-?%d+);") do
            if (s == "+") == e.up and math.abs(e.t - tonumber(t)) <= Rules.RANK_USED_RADIUS then ok = false break end
          end
        end
        if ok then
          for _, m in ipairs(list) do
            if m.atOff and m.up == e.up and math.abs(e.t - (m.after + m.atOff)) <= 3600 then ok = false break end
          end
        end
        if ok and (not best or e.t > best.t or (e.t == best.t and e.actor < best.actor)) then best = e end
      end
      if best then
        c.atOff, c.actorId = best.t - c.after, intern(G, "actors", best.actor)
        changed = true
      end
    end
  end
  if changed then rec.rk = encodeRanks(list) end
end

-- Reads ----------------------------------------------------------------------------------------------------------

local function text(s)
  if type(s) ~= "string" or s == "" then return nil end
  return s
end

local function toFormer(G, guid, rec, at, how, by)
  G.chars[guid] = nil
  rec.mc, rec.mf, rec.on = nil, nil, nil
  rec.ga, rec.gh, rec.gb = at, how, by
  G.former[guid] = rec
end

-- NameKey -> guid over a rec list; false when two recs share the key, so an ambiguous name matches nobody.
local function byKey(list)
  local out = {}
  for guid, rec in pairs(list) do
    local k = Rules.NameKey(rec.n)
    if k then out[k] = out[k] == nil and guid or false end
  end
  return out
end

-- A typed do-not-invite entry learns its guid when exactly one current character has its name key. An entry for a
-- guid that already has its own entry merges into that one.
local function bindDni(G)
  local chars
  for id, e in pairs(G.dni or {}) do
    if not e.g then
      chars = chars or byKey(G.chars)
      local guid = chars[Rules.NameKey(e.n) or ""]
      if guid then
        if G.dni[guid] then G.dni[id] = nil else e.g = guid end
      end
    end
  end
end

-- Upsert the listed members, count misses and do absence moves (counted full reads only), then note the read.
-- A read is partial when total is 0 or above count; a nil total is unknown, not partial. The session's first read
-- never counts a miss (D6).
function Store.ApplyRead(G, members, count, total, now, firstOfSession)
  local res = { rises = 0, gone = {}, back = {} }
  local partial = total == 0 or (type(total) == "number" and type(count) == "number" and total > count)
  for guid, m in pairs(members) do
    local rec = G.chars[guid]
    local back = false
    if not rec and G.former[guid] then
      back = true
      rec = G.former[guid]
      G.former[guid] = nil
      G.chars[guid] = rec
      rec.ga, rec.gh, rec.gb = nil, nil, nil
      -- d322: bank the closed stretch, which ends at the last listing (time away never counts).
      if type(rec.ls) == "number" then
        rec.tb = (rec.tb or 0) + math.max(0, rec.ls - (Rules.StretchStart(rec) or rec.ls))
      end
      rec.ret = now
      res.back[#res.back + 1] = guid
    end
    if not rec then
      rec = { fl = m.level, l = m.level, fs = now }
      if G.base then rec.j, rec.js = now, "seen" end
      G.chars[guid] = rec
      G.rv = (G.rv or 0) + 1 -- a new record can be a race candidate too (Revision 2 n1)
    elseif type(m.level) == "number" and type(rec.l) ~= "number" then
      rec.l, rec.fl = m.level, rec.fl or m.level -- the level was not known yet: a fill, not a rise
      G.rv = (G.rv or 0) + 1 -- a filled level can end a race hold and make a candidate (f1538)
    elseif type(m.level) == "number" and m.level > rec.l then
      addRise(G, rec, m.level, rec.ls, now)
      rec.l = m.level
      res.rises = res.rises + 1
    end
    -- A rank change needs both the index and the name to differ (an inserted or renamed rank changes one only).
    -- Unknown before, and a returner (R5), are fills.
    local rank = text(m.rank)
    if rank then
      local id = intern(G, "ranks", rank)
      if not back and rec.ls and type(rec.r) == "number" and type(rec.rn) == "string"
        and type(m.rankIndex) == "number" and m.rankIndex ~= rec.r and rank ~= rec.rn then
        addRank(G, rec, rank, m.rankIndex < rec.r, rec.ls, now)
      end
      rec.fr = rec.fr or id
    end
    rec.ra = text(m.race) or rec.ra
    rec.n, rec.c, rec.r, rec.rn = m.name, m.class, m.rankIndex, m.rank
    rec.nt, rec.no = text(m.note), text(m.officerNote)
    if m.online then
      rec.lo, rec.on = now, true
    else
      rec.on = nil
      if type(m.lastOnlineDays) == "number" then
        local est = now - m.lastOnlineDays * 86400
        if not rec.lo or est > rec.lo then rec.lo = est end
      end
    end
    rec.ls, rec.mc, rec.mf = now, nil, nil
  end
  for guid, rec in pairs(G.chars) do
    if not members[guid] then rec.on = nil end -- online counts only while a read lists them
  end
  if not partial and not firstOfSession then
    for guid, rec in pairs(G.chars) do
      if not members[guid] then
        rec.mc = (rec.mc or 0) + 1
        rec.mf = rec.mf or now
        if Rules.GoneByAbsence(rec.mc, rec.mf, now) then
          toFormer(G, guid, rec, now, "unknown", nil)
          res.gone[#res.gone + 1] = guid
        end
      end
    end
  end
  if not partial and not G.base then G.base = now end
  G.last, G.lastCount, G.lastTotal, G.lastPartial = now, count, total, partial
  bindDni(G)
  return res
end

-- Guild log ------------------------------------------------------------------------------------------------------

-- Joins and invites set the join time; quits and removals move a character the last read did not list to former,
-- or fill how and by for one the absence rule moved. "Earlier" and "later" come from the entry times only, never from
-- the list order (Forever lists the log oldest first, beta step 12 on 2026-10-06, but nothing relies on it).
-- The earliest log join sets j once (hour-rounded ages jitter, and a returner keeps j). A quit or removal is ignored when a join or invite for the same name is
-- later or in the same hour (removed and re-invited, or order unknown: the absence rule still catches a real
-- departure). Idempotent over the whole log; nothing of the log is kept.
-- An invite in the same hour as the join that set j names the inviter (rec.iv, plan D4), in either log order and
-- also on a later pass; a join alone leaves iv nil, and a set iv is kept (returners too).
-- Promote and demote entries fill the actor and log time of a rank change (plan D3): times decide, never positions.
-- review f8: the actor is stored realm-cut, as the roster's names are (Host shortName).
local function logTarget(e)
  if e.type == "invite" or e.type == "remove" or e.type == "promote" or e.type == "demote" then
    local actor = e.player1
    if type(actor) == "string" then actor = string.match(actor, "^([^-]+)") or actor end
    return Rules.NameKey(e.player2), actor
  end
  return Rules.NameKey(e.player1), nil
end

function Store.ApplyLog(G, rawEntries, now)
  local chars, former = byKey(G.chars), byKey(G.former)
  local firstIn, lastIn, invites, rankLog = {}, {}, {}, {}
  local coarse = {} -- the earliest join's entry had a month or year (D10: rec.jc)
  for _, e in ipairs(rawEntries or {}) do
    local k, actor = logTarget(e)
    if k and (e.type == "join" or e.type == "invite") then
      local t = Rules.LogTime(e, now)
      if not firstIn[k] or t < firstIn[k] then
        firstIn[k] = t
        coarse[k] = (e.year or 0) > 0 or (e.month or 0) > 0
      end
      if not lastIn[k] or t > lastIn[k] then lastIn[k] = t end
      if e.type == "invite" and text(actor) then
        invites[k] = invites[k] or {}
        table.insert(invites[k], { t = math.min(t, now), actor = actor })
      end
    elseif k and (e.type == "promote" or e.type == "demote") and text(actor) then
      rankLog[k] = rankLog[k] or {}
      table.insert(rankLog[k], { up = e.type == "promote", t = Rules.LogTime(e, now), rank = e.rank, actor = actor })
    end
  end
  for k, t in pairs(firstIn) do
    local rec = chars[k] and G.chars[chars[k]]
    if rec and rec.js ~= "log" then
      rec.j, rec.js = math.min(t, now), "log"
      if coarse[k] then rec.jc = 1 end -- written with j only, never cleared (Revision 2 n2)
    end
  end
  for k, list in pairs(invites) do
    local rec = chars[k] and G.chars[chars[k]]
    if rec and rec.js == "log" and rec.iv == nil and type(rec.j) == "number" then
      local best
      for _, v in ipairs(list) do
        local d = math.abs(v.t - rec.j)
        if d <= 3600 and (not best or d < best.d or (d == best.d and (v.t < best.t
          or (v.t == best.t and v.actor < best.actor)))) then
          best = { d = d, t = v.t, actor = v.actor }
        end
      end
      if best then rec.iv = best.actor end
    end
  end
  for k, entries in pairs(rankLog) do
    local guid = chars[k]
    if guid == nil then guid = former[k] end
    local rec = guid and (G.chars[guid] or G.former[guid])
    if rec and rec.rk then matchRanks(G, rec, entries) end
  end
  for _, e in ipairs(rawEntries or {}) do
    local raw = Rules.LogTime(e, now)
    local ts = math.min(raw, now)
    local k, actor = logTarget(e)
    if k and (e.type == "quit" or e.type == "remove") and not (lastIn[k] and lastIn[k] >= raw) then
      local how = e.type == "quit" and "left" or "removed"
      local guid = chars[k]
      local rec = guid and G.chars[guid]
      if rec and G.last and rec.ls < G.last and Rules.LogApplies(ts, rec.ls) then
        toFormer(G, guid, rec, ts, how, actor)
        chars[k], former[k] = nil, guid
      else
        rec = former[k] and G.former[former[k]]
        if rec and rec.gh == "unknown" and Rules.LogApplies(ts, rec.ls) then rec.gh, rec.gb = how, actor end
      end
    end
  end
end

-- Former characters are dropped FORMER_KEEP after they went, and only the newest FORMER_MAX (by ga) are kept.
function Store.Prune(G, now)
  local list = {}
  for guid, rec in pairs(G.former) do
    if Rules.Expired(rec.ga, now) then G.former[guid] = nil else list[#list + 1] = guid end
  end
  if #list <= Rules.FORMER_MAX then return end
  table.sort(list, function(a, b)
    local ga, gb = G.former[a].ga or 0, G.former[b].ga or 0
    if ga ~= gb then return ga > gb end
    return a < b
  end)
  for i = Rules.FORMER_MAX + 1, #list do G.former[list[i]] = nil end
end

-- The earned-string conversion (d518, plan D4) ------------------------------------------------------------------------

-- One ea rewritten part by part: an old "<id>:<hour>" part (hour < 2^31) through Rules.EarnEntry, an F2 part kept,
-- anything else dropped; an id already written is dropped (the first occurrence wins).
local function upgradeEa(ea, offset)
  local out, seen = {}, {}
  for part in string.gmatch(ea, "([^;]+);") do
    local id, h = part:match("^(%w+):(%d+)$")
    local entry
    if id then
      h = tonumber(h)
      if h < 2 ^ 31 then entry = Rules.EarnEntry(id, h * 3600, offset) end
    else
      id = part:match("^(%w+)%w%w%w$")
      if id then entry = part .. ";" end
    end
    if entry and not seen[id] then
      seen[id] = true
      out[#out + 1] = entry
    end
  end
  return table.concat(out)
end

local function upgradeRec(rec, offset)
  local ea = rec.ea
  if type(ea) ~= "string" then return end
  local new = #ea <= Rules.EA_MAX and upgradeEa(ea, offset) or "" -- f3580: over the cap is malformed
  if new ~= ea then rec.ea = new end
end

-- Run once per session from ADDON_LOADED, whatever db.v is (never from the DB accessor). Each record converts under
-- its own pcall, so one that throws is left as it was. Safe to run again, on a half-converted file, and on a v 2 file
-- that old code appended "<id>:<hour>;" parts to. Every other field is left alone.
function Store.Upgrade(db, offset)
  for _, G in pairs(type(db.guilds) == "table" and db.guilds or {}) do
    for _, part in ipairs({ "chars", "former" }) do
      local recs = type(G) == "table" and G[part]
      if type(recs) == "table" then
        for _, rec in pairs(recs) do pcall(upgradeRec, rec, offset) end
      end
    end
  end
  db.v = Rules.DB_VERSION
  return db
end

-- Seen marks (plan D9) ----------------------------------------------------------------------------------------------

-- rec.sn = "<id>;" each: the earned ids the viewer has seen, on its own record (current or former). AnnalsFeats loads
-- after this file, so it is looked up on ns at call time. sn only ever holds earned ids (the saved-size bound, T9).
local function seenRec(G, guid)
  return (G.chars or {})[guid] or (G.former or {})[guid]
end

-- The first visit (d505 quiet start): an sn that is missing or not a string becomes every earned id; true when
-- written, false otherwise (also with no rec).
function Store.SeenStart(G, guid)
  local rec = seenRec(G, guid)
  if not rec or type(rec.sn) == "string" then return false end
  local sn = ""
  for _, e in ipairs(ns.AnnalsFeats.Earned(rec)) do sn = sn .. e.id .. ";" end
  rec.sn = sn
  return true
end

-- Appends the earned ids not yet in sn (bounded ";id;" membership, as Feats.Has). Before SeenStart (sn not a string)
-- and with no rec it writes nothing.
function Store.MarkSeen(G, guid, ids)
  local rec = seenRec(G, guid)
  if not rec or type(rec.sn) ~= "string" then return end
  local sn = rec.sn
  for _, id in ipairs(ids or {}) do
    if ns.AnnalsFeats.Has(rec, id) and not (";" .. sn):find(";" .. id .. ";", 1, true) then sn = sn .. id .. ";" end
  end
  rec.sn = sn
end

-- Do not invite --------------------------------------------------------------------------------------------------

-- Keyed by guid, or "n:" .. NameKey(name) for a typed name. The reason is cut to REASON_MAX characters. Adding by
-- guid replaces a typed entry for the same name that is unbound or bound to that guid (one person, one entry).
function Store.DniAdd(G, name, guid, reason, now)
  local k = Rules.NameKey(name)
  if not k then return nil, "a name is needed" end
  if type(reason) ~= "string" or not reason:find("%S") then return nil, "a reason is needed" end
  local id = guid or ("n:" .. k)
  G.dni = G.dni or {}
  local typed = G.dni["n:" .. k]
  if guid and typed and (typed.g == nil or typed.g == guid) then G.dni["n:" .. k] = nil end
  G.dni[id] = { g = guid, n = name, why = reason:sub(1, Rules.REASON_MAX), at = now }
  return id
end

function Store.DniRemove(G, id)
  if G.dni then G.dni[id] = nil end
end

-- Entries whose character is current: by guid, else by a NameKey exactly one current character has (unless that
-- guid has its own entry). Reads only: the binding is learned in ApplyRead. Sorted by id.
function Store.DniHits(G)
  local hits = {}
  local chars = byKey(G.chars)
  for id, e in pairs(G.dni or {}) do
    local guid = e.g
    if not guid then
      guid = chars[Rules.NameKey(e.n) or ""]
      if guid and G.dni[guid] then guid = nil end
    end
    local rec = guid and G.chars[guid]
    if rec then hits[#hits + 1] = { id = id, guid = guid, name = rec.n, why = e.why } end
  end
  table.sort(hits, function(a, b) return a.id < b.id end)
  return hits
end
