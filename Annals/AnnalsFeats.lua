-- Annals AnnalsFeats: the achievements (phase B). The one definition table (DEFS), the earned string on a record
-- (rec.ea = "<id><ddd>;" entries, oldest first, ddd = the realm day in base 36, Rules.EarnEntry), points, the race
-- window (Candidate) and every check. Settled race slots live in G.rs ("<key>;" each, r<M>, c<M><CLASS> or
-- f<M><RACE>); rec.mb is the own record's best count of guildmates online at one read. Tunables, titles and tenure
-- live in AnnalsRules.
-- Pure Lua 5.1, no client calls: data and time are passed in. Check(G, now, ctx) is idempotent: nothing is earned
-- twice and nothing is ever removed.
local _, ns = ...
local Rules, Store = ns.AnnalsRules, ns.AnnalsStore
local Feats = {}
ns.AnnalsFeats = Feats

local DAY = 86400
local MINUTE = 60
local floor = math.floor

Feats.CATEGORIES = { "Company", "Levelling", "Collecting", "Tradeskills", "PvP", "Dungeons", "Secret", "Odd Jobs",
  "Exploration", "From officers" }

-- The category tree (d504, lg-4): parents carry leaves; a leaf no def names is "Coming soon" (D11, Feats.LeafLive).
-- Each def names its leaf. CATEGORIES and def.cat stay for older readers.
Feats.TREE = {
  { key = "ALL", text = "All" },
  { key = "Company", text = "Company", leaves = { { key = "Joining", text = "Joining" },
      { key = "Long service", text = "Long service" }, { key = "Together", text = "Together" },
      { key = "Notice Board", text = "Notice Board" } } },
  { key = "Levelling", text = "Levelling", leaves = { { key = "Firsts", text = "Firsts" },
      { key = "Milestones", text = "Milestones" }, { key = "Pace", text = "Pace" } } },
  { key = "Dungeons", text = "Dungeons", leaves = { { key = "Groups", text = "Groups" },
      { key = "Raids", text = "Raids" } } },
  { key = "Collecting", text = "Collecting", leaves = { { key = "Mounts and gold", text = "Mounts and gold" },
      { key = "Reputation", text = "Reputation" }, { key = "Travel", text = "Travel" },
      { key = "Legacy", text = "Legacy" } } },
  { key = "Tradeskills", text = "Tradeskills", leaves = { { key = "Skill", text = "Skill" },
      { key = "Work", text = "Work" } } },
  { key = "PvP", text = "PvP", leaves = { { key = "Honour", text = "Honour" },
      { key = "PvP Together", text = "Together" }, { key = "Enemy leaders", text = "Enemy leaders" } } },
  { key = "Secret", text = "Secret" }, { key = "Odd Jobs", text = "Odd Jobs" },
  { key = "Exploration", text = "Exploration" },
  { key = "From officers", text = "From officers" },
}

local parentOf = {}
for _, row in ipairs(Feats.TREE) do
  for _, leaf in ipairs(row.leaves or {}) do parentOf[leaf.key] = row.key end
end

-- The parent key of a leaf; nil for a top-level leaf, "ALL" or an unknown key.
function Feats.ParentOf(leafKey)
  return parentOf[leafKey]
end

function Feats.Never() end

-- Rises are decoded at most once per Check (the cache lives for one Check), and only for the records a check needs.
-- Store.Rises is looked up on the Store table at call time.
local cache
local function risesOf(rec)
  if not cache then return Store.Rises(rec) end
  local r = cache[rec]
  if not r then
    r = Store.Rises(rec)
    cache[rec] = r
  end
  return r
end

-- The rise with from < level <= to, or nil.
local function crossing(rec, level)
  for _, r in ipairs(risesOf(rec)) do
    if type(r.from) == "number" and r.from < level and level <= r.to then return r end
  end
  return nil
end

-- A rise made in the guild: not one that straddles the return (levels gained away), for Recruiter and the race.
local function inGuild(rec, r)
  return not rec.ret or r.after >= rec.ret or r.by < rec.ret
end

local function recOf(G, guid)
  return (G.chars or {})[guid] or (G.former or {})[guid]
end

-- Earned string -----------------------------------------------------------------------------------------------------

-- A saved ea that is not a string (hand edit, corruption) reads as empty (f1546).
-- An ea over Rules.EA_MAX is malformed and reads as "" (f3580: the scan stays bounded).
local function eaOf(rec)
  return type(rec.ea) == "string" and #rec.ea <= Rules.EA_MAX and rec.ea or ""
end

-- The session's realm offset (seconds), set once per session from ADDON_LOADED; nil is the fallback.
local offset = Rules.REALM_OFFSET_FALLBACK
function Feats.SetRealmOffset(seconds)
  offset = type(seconds) == "number" and seconds or Rules.REALM_OFFSET_FALLBACK
end

-- Ids are alphanumeric, so the id needs no escaping in the pattern.
function Feats.Has(rec, id)
  return (";" .. eaOf(rec)):find(";" .. id .. "%w%w%w;") ~= nil
end

function Feats.Earn(rec, id, t)
  if t ~= t or Feats.Has(rec, id) then return false end -- f3581: a NaN time writes nothing
  rec.ea = eaOf(rec) .. Rules.EarnEntry(id, t, offset)
  return true
end

-- Checks ------------------------------------------------------------------------------------------------------------

local function online(G)
  local out = {}
  for guid, rec in pairs(G.chars or {}) do
    if rec.on then out[#out + 1] = guid end
  end
  table.sort(out)
  return out
end

-- sl: a current member. A log join is dated j at once; otherwise first seen, once a log was read this
-- session or a log cycle has passed.
local function checkSl(G, now, ctx, earn)
  for guid, rec in pairs(G.chars or {}) do
    if rec.js == "log" and type(rec.j) == "number" then
      earn(guid, "sl", rec.j)
    elseif (ctx.logSeen or ctx.logCycle) and type(rec.fs) == "number" then
      earn(guid, "sl", rec.fs)
    end
  end
end

-- Old Hand (d322): Rules.Tenure over current members only, dated when it reached N days, not before the stretch.
local function oldHand(id, days)
  return function(G, now, ctx, earn)
    local need = days * DAY
    for guid, rec in pairs(G.chars or {}) do
      local tenure = Rules.Tenure(rec, now)
      if tenure >= need then
        local t = now - (tenure - need)
        local start = Rules.StretchStart(rec)
        if type(start) == "number" and t < start then t = start end
        earn(guid, id, t)
      end
    end
  end
end

local function oldHandProgress(days)
  return function(G, rec, now)
    return floor(Rules.Tenure(rec, now) / DAY) .. " of " .. days .. " days"
  end
end

-- NameKey -> the one guid with that name, or false when two records share it.
local function guidsByName(G)
  local out = {}
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      local k = Rules.NameKey(rec.n)
      if k then out[k] = out[k] == nil and guid or false end
    end
  end
  return out
end

-- Whether rec's join is a fine log join: read from the guild log, not coarse, dated j.
local function fineJoin(rec)
  return rec.js == "log" and rec.jc == nil and type(rec.j) == "number"
end

-- Whether rec was in the annals at t: first seen, or a fine log join, at or before t (f1548).
local function knownAt(rec, t)
  if type(rec.fs) == "number" and rec.fs <= t then return true end
  return fineJoin(rec) and rec.j <= t
end

-- Recruits (D6, D9): an invitee crossed RECRUIT_LEVEL, not across a return; the inviter is the one rec with that
-- name, already in the annals at the invite (f1548). Returns the inviters (sorted) and, per inviter, the qualifying
-- rises' by times, earliest first. Built at most once per Check (the cache lives for one Check).
local function recruitsOf(G)
  if cache and cache.recruits then return cache.recruits[1], cache.recruits[2] end
  local RL = Rules.RECRUIT_LEVEL
  local byName
  local bys, inviters = {}, {}
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for _, rec in pairs(list) do
      local key = Rules.NameKey(rec.iv)
      if key and type(rec.j) == "number" then
        byName = byName or guidsByName(G)
        local inviter = byName[key]
        local irec = inviter and recOf(G, inviter)
        if irec and irec ~= rec and knownAt(irec, rec.j) then
          local r = crossing(rec, RL)
          if r and inGuild(rec, r) then
            if bys[inviter] == nil then
              bys[inviter] = {}
              inviters[#inviters + 1] = inviter
            end
            local l = bys[inviter]
            l[#l + 1] = r.by
          end
        end
      end
    end
  end
  table.sort(inviters)
  for _, inviter in ipairs(inviters) do table.sort(bys[inviter]) end
  if cache then cache.recruits = { inviters, bys } end
  return inviters, bys
end

-- Recruiter: dated by the earliest qualifying rise (f1532). Recruiter: three: dated by the RECRUIT_COUNT-th.
local function checkRc(G, now, ctx, earn)
  local inviters, bys = recruitsOf(G)
  for _, inviter in ipairs(inviters) do earn(inviter, "rc", bys[inviter][1]) end
end

local function checkRt(G, now, ctx, earn)
  local inviters, bys = recruitsOf(G)
  for _, inviter in ipairs(inviters) do earn(inviter, "rt", bys[inviter][Rules.RECRUIT_COUNT]) end
end

-- Founding Hand (D15): first seen by FOUNDING_BY, dated fs, or a fine log join surely by it, dated j; the earlier.
local function checkFh(G, now, ctx, earn)
  local FB = Rules.FOUNDING_BY
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      local t
      if type(rec.fs) == "number" and rec.fs <= FB then t = rec.fs end
      if fineJoin(rec) and rec.j + Rules.LOG_ERROR <= FB and (t == nil or rec.j < t) then t = rec.j end
      if t then earn(guid, "fh", t) end
    end
  end
end

-- Promoted: the first up rank change the guild log matched to a promote (it names an actor), dated its by.
local function checkPr(G, now, ctx, earn)
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      if rec.rk and not Feats.Has(rec, "pr") then
        local t
        for _, c in ipairs(Store.RankChanges(G, rec)) do
          if c.up and c.actor and type(c.by) == "number" and (t == nil or c.by < t) then t = c.by end
        end
        if t then earn(guid, "pr", t) end
      end
    end
  end
end

-- Born Into the Company: first seen at level 1, dated fs.
local function checkBn(G, now, ctx, earn)
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      if rec.fl == 1 and type(rec.fs) == "number" then earn(guid, "bn", rec.fs) end
    end
  end
end

-- Risen Again: a former record listed again (Store sets ret), dated ret. A record pruned from former comes back
-- without ret and never earns it (f3525).
local function checkRg(G, now, ctx, earn)
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      if type(rec.ret) == "number" then earn(guid, "rg", rec.ret) end
    end
  end
end

-- Night Shift and Full Muster (D7): at a read, from who this read listed online.
local function checkNs(G, now, ctx, earn)
  if not ctx.read or ctx.hour ~= Rules.NIGHT_HOUR then return end
  local on = online(G)
  if #on < 2 then return end
  for _, guid in ipairs(on) do earn(guid, "ns", now) end
end

local function checkFm(G, now, ctx, earn)
  if not ctx.read then return end
  local on = online(G)
  if #on < Rules.MUSTER + 1 then return end
  for _, guid in ipairs(on) do earn(guid, "fm", now) end
end

local function fmProgress(G, rec, now)
  if type(rec.mb) == "number" then return "Best so far " .. rec.mb end
  return nil
end

-- Read-time rows (D10): from the read's roster in ctx (members, afk); a check that is no read has neither.
-- Roll Call and Grand Muster: everyone online at a read with at least need guildmates.
local function together(id, need)
  return function(G, now, ctx, earn)
    if not ctx.read then return end
    local on = online(G)
    if #on < need + 1 then return end
    for _, guid in ipairs(on) do earn(guid, id, now) end
  end
end

-- The online members grouped by keyOf(guid) (nil: in no group); every member of a group of at least need earns id.
local function earnGroups(G, now, earn, id, need, keyOf)
  local by = {}
  for _, guid in ipairs(online(G)) do
    local k = keyOf(guid)
    if k then
      by[k] = by[k] or {}
      by[k][#by[k] + 1] = guid
    end
  end
  for _, guids in pairs(by) do
    if #guids >= need then
      for _, guid in ipairs(guids) do earn(guid, id, now) end
    end
  end
end

-- Family Reunion: online at a read with a guildmate who shares the surname.
local function checkFy(G, now, ctx, earn)
  if not ctx.read then return end
  earnGroups(G, now, earn, "fy", 2, function(guid) return Rules.Surname(G.chars[guid].n) end)
end

-- Well Decorated: the roster shows WELL_DECORATED achievement points at a read.
local function checkWd(G, now, ctx, earn)
  if not (ctx.read and type(ctx.members) == "table") then return end
  for guid, m in pairs(ctx.members) do
    if type(m) == "table" and type(m.ap) == "number" and m.ap >= Rules.WELL_DECORATED then earn(guid, "wd", now) end
  end
end

-- Asleep at the Desk: an away run (Rules.AfkRuns) of AFK_RUN or more at this read.
local function checkAz(G, now, ctx, earn)
  if not (ctx.read and type(ctx.afk) == "table") then return end
  for guid, since in pairs(ctx.afk) do
    if type(since) == "number" and now - since >= Rules.AFK_RUN then earn(guid, "az", now) end
  end
end

-- Zone musters (D9, D14): at a read, every online member in a zone that holds at least need online members earns
-- id. Each zone name counts on its own; a nil zone never counts.
local function musterAt(id)
  local m = Rules.MUSTER_ZONES[id]
  local set = {}
  for _, z in ipairs(m.zones) do set[z] = true end
  return function(G, now, ctx, earn)
    if not (ctx.read and type(ctx.members) == "table") then return end
    earnGroups(G, now, earn, id, m.need, function(guid)
      local row = ctx.members[guid]
      local z = type(row) == "table" and row.zone or nil
      if z and set[z] then return z end
      return nil
    end)
  end
end

-- Race firsts (D8) --------------------------------------------------------------------------------------------------

function Feats.Candidate(guid, rec, M, former)
  local w = crossing(rec, M) or Rules.FirstSeenWindow(rec.fl, rec.fs, M)
  if not w or type(w.by) ~= "number" then return nil end
  return { after = w.after, by = w.by, name = rec.n, guid = guid, class = rec.c, former = former }
end

local function settled(G, key)
  return (";" .. (G.rs or "")):find(";" .. key .. ";", 1, true) ~= nil
end

-- One slot: the sure leader earns id, dated its by, only when it crossed M in the Company (d387); either way the key
-- is settled for good.
local function decide(G, key, id, cands, earn)
  if #cands == 0 then return end
  local sorted, sure = Rules.Rank(cands)
  if sure and sorted[1].rose then earn(sorted[1].guid, id, sorted[1].by) end
  G.rs = (G.rs or "") .. key .. ";"
end

-- Every candidate as D8, marked rose when it crossed M; a known recruit (first seen after G.base, at or above M, no
-- crossing) is dropped: it neither wins nor blocks (d387); so is a returner whose crossing straddles the return
-- (f1550).
local function candidates(G, M)
  local out = {}
  for _, list in ipairs({ { G.chars or {}, false }, { G.former or {}, true } }) do
    local guids = {}
    for guid in pairs(list[1]) do guids[#guids + 1] = guid end
    table.sort(guids)
    for _, guid in ipairs(guids) do
      local rec = list[1][guid]
      local c = Feats.Candidate(guid, rec, M, list[2])
      if c then
        local r = crossing(rec, M)
        c.rose = r ~= nil
        local recruit = not c.rose and type(G.base) == "number" and type(rec.fs) == "number" and rec.fs > G.base
        local away = r ~= nil and not inGuild(rec, r)
        c.race = Rules.RaceToken(rec.ra)
        if not recruit and not away then out[#out + 1] = c end
      end
    end
  end
  return out
end

-- The client's max level from ctx, or the fallback.
local function maxLevel(ctx)
  return ctx.maxLevel or Rules.MAX_LEVEL_FALLBACK
end

-- The milestones to decide: none unless rises changed and this is a full read (D4), and none while a current record's
-- level is unknown: it could still make a tie (f1538).
local function raceMilestones(G, ctx)
  if not (ctx.rises and ctx.read and ctx.full) then return {} end
  for _, rec in pairs(G.chars or {}) do
    if type(rec.l) ~= "number" then return {} end
  end
  return Rules.Milestones(maxLevel(ctx))
end

local function checkR(G, now, ctx, earn)
  for _, M in ipairs(raceMilestones(G, ctx)) do
    local key = "r" .. M
    if not settled(G, key) then decide(G, key, key, candidates(G, M), earn) end
  end
end

local function checkC(G, now, ctx, earn)
  for _, M in ipairs(raceMilestones(G, ctx)) do
    local byClass, classes = {}, {}
    for _, c in ipairs(candidates(G, M)) do
      if type(c.class) == "string" and not settled(G, "c" .. M .. c.class) then
        if not byClass[c.class] then
          byClass[c.class] = {}
          classes[#classes + 1] = c.class
        end
        local list = byClass[c.class]
        list[#list + 1] = c
      end
    end
    table.sort(classes)
    for _, class in ipairs(classes) do decide(G, "c" .. M .. class, "c" .. M, byClass[class], earn) end
  end
end

-- First of your race (D8): c's slots keyed by race token, only at the max level; no race is no candidate.
local function checkF(G, now, ctx, earn)
  local max = maxLevel(ctx)
  for _, M in ipairs(raceMilestones(G, ctx)) do
    if M == max then
      local byRace, races = {}, {}
      local cands = candidates(G, M)
      -- f3561: a candidate that rose with no race could be first of any race, so every f<M> slot is held.
      for _, c in ipairs(cands) do
        if c.rose and not c.race then cands = {} break end
      end
      for _, c in ipairs(cands) do
        if c.race and not settled(G, "f" .. M .. c.race) then
          if not byRace[c.race] then
            byRace[c.race] = {}
            races[#races + 1] = c.race
          end
          local list = byRace[c.race]
          list[#list + 1] = c
        end
      end
      table.sort(races)
      for _, race in ipairs(races) do decide(G, "f" .. M .. race, "f" .. M, byRace[race], earn) end
    end
  end
end

-- Full Measure: crossed the max level in the Company (not across a return), dated by; also outside a read, but only
-- when rises changed (as dt).
local function checkFu(G, now, ctx, earn)
  if not ctx.rises then return end
  local max = maxLevel(ctx)
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      if not Feats.Has(rec, "fu") then
        local r = crossing(rec, max)
        if r and inGuild(rec, r) then earn(guid, "fu", r.by) end
      end
    end
  end
end

-- Early Harvest (f3523): a fine log join below EARLY_JOIN_LEVEL that surely crossed the max level in the Company
-- within EARLY_DAYS, dated by.
local function checkEh(G, now, ctx, earn)
  local max = maxLevel(ctx)
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      if fineJoin(rec) and type(rec.fl) == "number" and rec.fl < Rules.EARLY_JOIN_LEVEL
        and not Feats.Has(rec, "eh") then
        local r = crossing(rec, max)
        if r and inGuild(rec, r) and r.by <= rec.j + Rules.EARLY_DAYS * DAY - Rules.LOG_ERROR then
          earn(guid, "eh", r.by)
        end
      end
    end
  end
end

-- Ding pairs (D9): two guildmates' rises to one level surely within DING_TOGETHER, dated the later by; earliest
-- first. Built at most once per Check (the cache lives for one Check).
local function dingPairs(G)
  if cache and cache.pairs then return cache.pairs end
  local DT = Rules.DING_TOGETHER
  local buckets, out = {}, {}
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      for _, r in ipairs(risesOf(rec)) do
        if type(r.after) == "number" then
          buckets[r.to] = buckets[r.to] or {}
          local b = buckets[r.to]
          b[#b + 1] = { guid = guid, after = r.after, by = r.by }
        end
      end
    end
  end
  for _, b in pairs(buckets) do
    table.sort(b, function(x, y)
      if x.by ~= y.by then return x.by < y.by end
      return x.guid < y.guid
    end)
    for i = 1, #b do
      local r = b[i]
      local k = i + 1
      while b[k] and b[k].by - r.by <= DT do
        local s = b[k]
        if s.guid ~= r.guid and math.max(r.by - s.after, s.by - r.after) <= DT then
          out[#out + 1] = { a = r.guid, b = s.guid, t = math.max(r.by, s.by) }
        end
        k = k + 1
      end
    end
  end
  table.sort(out, function(x, y)
    if x.t ~= y.t then return x.t < y.t end
    if x.a ~= y.a then return x.a < y.a end
    return x.b < y.b
  end)
  if cache then cache.pairs = out end
  return out
end

-- Ding Together: dated the earliest pair.
local function checkDt(G, now, ctx, earn)
  if not ctx.rises then return end
  for _, p in ipairs(dingPairs(G)) do
    earn(p.a, "dt", p.t)
    earn(p.b, "dt", p.t)
  end
end

-- Ding Together: five: pairs with DING_FRIENDS different guildmates, dated the pair that makes the count.
local function checkD5(G, now, ctx, earn)
  if not ctx.rises then return end
  local partners, count = {}, {}
  local function add(guid, other, t)
    partners[guid] = partners[guid] or {}
    if partners[guid][other] then return end
    partners[guid][other] = true
    count[guid] = (count[guid] or 0) + 1
    if count[guid] == Rules.DING_FRIENDS then earn(guid, "d5", t) end
  end
  for _, p in ipairs(dingPairs(G)) do
    add(p.a, p.b, p.t)
    add(p.b, p.a, p.t)
  end
end

-- Fresh From the Grave (D10): a log join (not coarse) that surely reached FRESH_LEVEL within its first day.
local function checkFg(G, now, ctx, earn)
  local FL = Rules.FRESH_LEVEL
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      if rec.js == "log" and rec.jc == nil and type(rec.j) == "number" and type(rec.fl) == "number"
        and rec.fl < FL and not Feats.Has(rec, "fg") then
        local r = crossing(rec, FL)
        if r and r.by <= rec.j + DAY - Rules.LOG_ERROR then earn(guid, "fg", r.by) end
      end
    end
  end
end

-- Definitions (D2) --------------------------------------------------------------------------------------------------

Feats.DEFS = {
  { id = "sl", name = "Signed the Ledger", desc = "Join the Company.", cat = "Company", points = 10, vis = "guild",
    check = checkSl, leaf = "Joining" },
  { id = "o1", name = "Old Hand: 30 days", desc = "30 days in the Company.", cat = "Company", points = 10,
    vis = "guild", check = oldHand("o1", 30), progress = oldHandProgress(30), leaf = "Long service" },
  { id = "o2", name = "Old Hand: 90 days", desc = "90 days in the Company.", cat = "Company", points = 25,
    vis = "guild", check = oldHand("o2", 90), progress = oldHandProgress(90), leaf = "Long service" },
  { id = "o3", name = "Old Hand: a year", desc = "365 days in the Company.", cat = "Company", points = 50,
    vis = "guild", check = oldHand("o3", 365), progress = oldHandProgress(365), leaf = "Long service" },
  { id = "rc", name = "Recruiter", desc = "Someone you invited reaches level " .. Rules.RECRUIT_LEVEL
    .. " in the Company.", cat = "Company", points = 25, vis = "guild", check = checkRc, leaf = "Joining" },
  { id = "ns", name = "Night Shift", desc = "Be online with a guildmate at " .. Rules.NIGHT_HOUR .. ":00, realm time.",
    cat = "Company", points = 10, vis = "guild", check = checkNs, leaf = "Together" },
  { id = "fm", name = "Full Muster", desc = "Be online at the same time as " .. Rules.MUSTER .. " guildmates.",
    cat = "Company", points = 25, vis = "guild", check = checkFm, progress = fmProgress, leaf = "Together" },
  { id = "r", name = "First to %d", desc = "First in the Company to a milestone level.", cat = "Levelling",
    points = 50, vis = "guild", check = checkR, param = "milestone", leaf = "Firsts" },
  { id = "c", name = "First %s to %d", desc = "First of your class in the Company to a milestone level.",
    cat = "Levelling", points = 25, vis = "guild", check = checkC, param = "milestone", leaf = "Firsts" },
  { id = "dt", name = "Ding Together", desc = "Reach a level within " .. floor(Rules.DING_TOGETHER / MINUTE)
    .. " minutes of a guildmate.", cat = "Levelling", points = 10, vis = "guild", check = checkDt, leaf = "Pace" },
  { id = "fg", name = "Fresh From the Grave", desc = "Reach level " .. Rules.FRESH_LEVEL .. " within a day of joining.",
    cat = "Levelling", points = 25, vis = "guild", check = checkFg, leaf = "Pace" },
  { id = "cr", name = "Company Run", desc = "Clear a dungeon in a group of five guildmates.", cat = "Dungeons",
    points = 25, vis = "you", check = Feats.Never, leaf = "Groups" },
  { id = "mv", name = "MVP of the Night", desc = "Given by an officer.", cat = "From officers", points = 25,
    vis = "later", check = Feats.Never, leaf = "From officers" },
  -- Run A Task 5 (Seams): appended after the 13 kept rows.
  { id = "fh", name = "Founding Hand", desc = "Be in the Company by 11 Nov 2026, realm time.", cat = "Company",
    points = 10, vis = "guild", check = checkFh, leaf = "Joining" },
  { id = "rt", name = "Recruiter: three", desc = Rules.RECRUIT_COUNT .. " people you invited reach level "
    .. Rules.RECRUIT_LEVEL .. " in the Company.", cat = "Company", points = 25, vis = "guild", check = checkRt,
    leaf = "Joining" },
  { id = "pr", name = "Promoted", desc = "An officer promotes you.", cat = "Company", points = 10, vis = "guild",
    check = checkPr, leaf = "Joining" },
  { id = "o6", name = "Old Hand: 180 days", desc = "180 days in the Company.", cat = "Company", points = 25,
    vis = "guild", check = oldHand("o6", 180), progress = oldHandProgress(180), leaf = "Long service" },
  { id = "bn", name = "Born Into the Company", desc = "First seen in the Company at level 1.", cat = "Odd Jobs",
    points = 10, vis = "guild", check = checkBn, leaf = "Odd Jobs" },
  { id = "rg", name = "Risen Again", desc = "Leave the Company and come back.", cat = "Secret", points = 10,
    vis = "guild", check = checkRg, leaf = "Secret", secret = true },
  -- Run A Task 6 (Seams): the read-time rows.
  { id = "rl", name = "Roll Call", desc = "Be online at the same time as " .. Rules.ROLL_CALL .. " guildmates.",
    cat = "Company", points = 10, vis = "guild", check = together("rl", Rules.ROLL_CALL), progress = fmProgress,
    leaf = "Together" },
  { id = "gm", name = "Grand Muster", desc = "Be online at the same time as " .. Rules.GRAND_MUSTER .. " guildmates.",
    cat = "Company", points = 50, vis = "guild", check = together("gm", Rules.GRAND_MUSTER), progress = fmProgress,
    leaf = "Together" },
  { id = "fy", name = "Family Reunion", desc = "Be online with a guildmate who shares your surname.", cat = "Odd Jobs",
    points = 10, vis = "guild", check = checkFy, leaf = "Odd Jobs", secret = true },
  { id = "wd", name = "Well Decorated", desc = "Show " .. Rules.WELL_DECORATED .. " achievement points on the guild "
    .. "roster.", cat = "Collecting", points = 25, vis = "guild", check = checkWd, leaf = "Legacy" },
  { id = "az", name = "Asleep at the Desk", desc = "Show as away on the guild roster for 3 hours in a row.",
    cat = "Odd Jobs", points = 10, vis = "guild", check = checkAz, leaf = "Odd Jobs", secret = true },
  -- Run A Task 7 (Seams): the zone musters.
  { id = "dm", name = "Dungeon Muster", desc = "Be in the same dungeon as 4 guildmates.", cat = "Dungeons",
    points = 10, vis = "guild", check = musterAt("dm"), leaf = "Groups" },
  { id = "rm", name = "Raid Muster", desc = "Be in the same raid as 9 guildmates.", cat = "Dungeons", points = 10,
    vis = "guild", check = musterAt("rm"), leaf = "Raids" },
  { id = "bm", name = "Battleground Muster", desc = "Be in the same battleground as 4 guildmates.", cat = "PvP",
    points = 10, vis = "guild", check = musterAt("bm"), leaf = "PvP Together" },
  { id = "ag", name = "At the Gates", desc = "Be in Stormwind, Ironforge or Darnassus with 9 guildmates.", cat = "PvP",
    points = 10, vis = "guild", check = musterAt("ag"), leaf = "Enemy leaders" },
  { id = "ma", name = "Muster at Andorhal", desc = "Be in Western Plaguelands with 9 guildmates.", cat = "Secret",
    points = 25, vis = "guild", check = musterAt("ma"), leaf = "Secret", secret = true },
  -- Run A Task 8 (Seams): rows from level rises.
  { id = "d5", name = "Ding Together: five", desc = "Ding within " .. floor(Rules.DING_TOGETHER / MINUTE)
    .. " minutes of " .. Rules.DING_FRIENDS .. " different guildmates.", cat = "Company",
    points = 25, vis = "guild", check = checkD5, leaf = "Together" },
  { id = "f", name = "First %s to %d", desc = "First of your race in the Company to the max level.",
    cat = "Levelling", points = 25, vis = "guild", check = checkF, param = "milestone", leaf = "Firsts" },
  { id = "fu", name = "Full Measure", desc = "Reach the max level in the Company.", cat = "Levelling", points = 25,
    vis = "guild", check = checkFu, leaf = "Milestones" },
  { id = "eh", name = "Early Harvest", desc = "Reach the max level within " .. Rules.EARLY_DAYS .. " days of joining "
    .. "below level " .. Rules.EARLY_JOIN_LEVEL .. ".", cat = "Levelling", points = 25, vis = "guild",
    check = checkEh, leaf = "Pace" },
}

local byId = {}
for _, d in ipairs(Feats.DEFS) do byId[d.id] = d end

-- Whether a def names leaf key; a leaf none names is "Coming soon" (D11).
function Feats.LeafLive(key)
  for _, d in ipairs(Feats.DEFS) do
    if d.leaf == key then return true end
  end
  return false
end

-- The def for an earned id and its milestone: "r50" is the r row at 50. nil for an unknown id.
function Feats.Def(id)
  if byId[id] then return byId[id], nil end
  local p, m = string.match(id or "", "^([rcf])(%d+)$")
  if p then return byId[p], tonumber(m) end
  return nil
end

local function className(token)
  if type(token) ~= "string" or token == "" then return nil end
  return Rules.CLASS_NAMES[token] or token:sub(1, 1):upper() .. token:sub(2):lower()
end

-- The shown name of an earned id: "First to 50", "First Priest to 30" (the class from rec).
function Feats.Name(id, rec)
  local d, m = Feats.Def(id)
  if not d then return nil end
  if d.id == "r" then return string.format(d.name, m) end
  if d.id == "c" then return string.format(d.name, className(rec and rec.c) or "of the class", m) end
  if d.id == "f" then
    local ra = rec and type(rec.ra) == "string" and rec.ra ~= "" and rec.ra or nil
    return string.format(d.name, ra and (Rules.RACE_NAMES[ra] or ra) or "of the race", m)
  end
  return d.name
end

-- { { id, t, def, m }, ... } oldest first, t at realm noon of the earned day; unknown ids and malformed parts are
-- left out (the tail is matched as 3 alphanumerics before tonumber, f3519).
function Feats.Earned(rec)
  local out = {}
  for part in string.gmatch(eaOf(rec), "([^;]+);") do
    local id, tail = part:match("^(%w+)(%w%w%w)$")
    local day = tail and tonumber(tail, 36)
    local d, m
    if day then d, m = Feats.Def(id) end
    if d then out[#out + 1] = { id = id, t = day * DAY + Rules.HALF_DAY - offset, def = d, m = m } end
  end
  return out
end

function Feats.Points(rec, guildOnly)
  local sum = 0
  for _, e in ipairs(Feats.Earned(rec)) do
    if not guildOnly or e.def.vis == "guild" then sum = sum + e.def.points end
  end
  return sum
end

-- Every check per D4; returns the new earns { { guid, id }, ... }. The own rec's mb is raised at a read.
function Feats.Check(G, now, ctx)
  ctx = ctx or {}
  local out = {}
  local function earn(guid, id, t)
    local rec = recOf(G, guid)
    if rec and type(t) == "number" and Feats.Earn(rec, id, t) then out[#out + 1] = { guid = guid, id = id } end
  end
  -- Each check under its own pcall, so one that throws stops none after it (f1547); the first error is raised at
  -- the end, after mb.
  cache = {}
  local firstErr
  for _, d in ipairs(Feats.DEFS) do
    local ok, err = pcall(d.check, G, now, ctx, earn)
    if not ok and firstErr == nil then firstErr = err end
  end
  cache = nil
  local me = ctx.read and ctx.self and (G.chars or {})[ctx.self]
  if me and me.on then
    local others = #online(G) - 1
    if others > (me.mb or 0) then me.mb = others end
  end
  if firstErr ~= nil then error(firstErr, 0) end
  return out
end
