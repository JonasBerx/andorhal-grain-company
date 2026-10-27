-- GuildSyncNoticeBoard: the store for officer notices, polls and members' votes, and the "board" domain the hub syncs
-- (brief AC1-AC8, AC10-AC13, AC17, AC43; plan R-rev, R-gone, R-codec). Kept in GuildSyncNoticeBoardDB:
--   { v = 2, board = { [key] = rec }, officers = { [key] = rec }, members = { [memberKey] = { rev, by, votes = { [pollKey] = { option, at } } } },
--     gone = { [domain] = { [key] = { rev, till, why, seq } } }, lastSeen, lead, guild }
-- lastSeen: the server time the board last told me about notices (saved at PLAYER_LOGOUT, advanced by Store.MarkSeen
-- after the login line); notices created after it by someone else are new.
-- Writes check demo, officer (roster known, not partial), the clock, the attached domain, removed, then Rules; every
-- write updates the held record table in place (by, the fields, packed) and calls M.Sync.Changed once: the engine mints
-- rev and hash, never this file. Readers judge expiry at call time; the saved table is pruned on the session's first
-- roster read out of demo with a readable guild (guild: the one the store belongs to), and by every store call.
-- board_m holds the members' vote records (copy rule, R-own adoption, the vote wait); board_o holds the officers-only
-- notices in db.officers (R-officers): each store reads only its own table, Store.Notices alone lists both.

local name, ns = ...
if not ns.M then return end

local M, C, Rules = ns.M, ns.C, ns.Rules
local Store = {}
ns.Store = Store

local DAY, HOUR = 86400, 3600
local INERT = "Demo: nothing is done to made-up members."

local session = { v = 2, board = {}, officers = {}, members = {}, gone = {} } -- until ADDON_LOADED adopts the saved table
local db = session
local rosterSeen = false   -- a rosterRead came this session
local rosterPartial = true -- the last rosterRead was partial (f6: vote checks read this, not a Roster() copy)
local officerHeard = false -- this session made an officer write
-- R-own: my own board_m record this session (adopted from a peer, when, and whether I called Changed on it)
local adopted, adoptedAt, wroteOwn = false, nil, false
local rosterAt -- server time of the session's first rosterRead (the vote wait's cap counts from it)
local SETTLE = 30 -- seconds an adopted record waits for a newer copy before I may vote (N2)

-- ---------- the saved table ----------

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("ADDON_LOADED")
loadFrame:RegisterEvent("PLAYER_LOGOUT")
loadFrame:SetScript("OnEvent", function(_, event, loaded)
  if event == "PLAYER_LOGOUT" then
    local t = ns.Now()
    if type(t) == "number" then db.lastSeen = math.max(db.lastSeen or 0, math.floor(t)) end
    return
  end
  if loaded ~= name then return end
  if type(GuildSyncNoticeBoardDB) ~= "table" then GuildSyncNoticeBoardDB = { v = 2 } end
  db = GuildSyncNoticeBoardDB
  -- d1013: an older saved layout is wiped (pre-launch: nothing to migrate)
  if db.v ~= 2 then db.board, db.officers, db.members, db.gone, db.v = {}, {}, {}, {}, 2 end
  if type(db.board) ~= "table" then db.board = {} end
  if type(db.officers) ~= "table" then db.officers = {} end
  if type(db.members) ~= "table" then db.members = {} end
  if type(db.gone) ~= "table" then db.gone = {} end
end)

function ns.DB() return db end

local NO_TIME = "The server time is not readable now."
local NO_SYNC = "The board cannot sync right now; try again after a /reload."
local LONG = "Too long once packed. Shorten it."
local WAIT = "Wait a second before posting again."

-- The server time in whole seconds, nil when it cannot be read (writes refuse; readers judge no expiry).
local function now()
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  return math.floor(t)
end

-- The guild this character is in, by name only (as CraftCompat does: Forever is realmless, and a realm part that
-- reads on one character and not another would wipe the board on every switch); nil when none or secret.
local function guildNow()
  local gname = M.Compat.call("GetGuildInfo", "player")
  if type(gname) ~= "string" or gname == "" then return nil end
  return gname
end

-- ---------- helpers ----------

local function myKey() return GuildSync.Comm.MyKey() end

local function isNotice(key) return type(key) == "string" and key:sub(1, 1) == "n" end
local function isPoll(key) return type(key) == "string" and key:sub(1, 1) == "q" end

-- A record the store can hold: a table with a numeric keepUntil (the prune's test), not past it at t; with t nil (no
-- server time) expiry is not judged.
local function holdable(rec, t)
  return type(rec) == "table" and type(rec.keepUntil) == "number" and (t == nil or not Rules.Expired(rec, t))
end

-- The held records of one kind (prefix "n" or "q") in tbl (db.board when nil) not past keepUntil at t.
local function heldOf(test, t, tbl)
  local out = {}
  for key, rec in pairs(tbl or db.board) do
    if test(key) and holdable(rec, t) then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- A held record of one kind in tbl (db.board when nil), nil when absent or past keepUntil.
local function held(key, test, t, tbl)
  local rec = test(key) and (tbl or db.board)[key]
  if not holdable(rec, t) then return nil end
  return rec
end

-- ---------- gone and the expiry prune (plan R-gone) ----------

local GONE_MAX = 50

local function goneOf(domain)
  local g = db.gone[domain]
  if type(g) ~= "table" then
    g = {}
    db.gone[domain] = g
  end
  return g
end

-- The latest keepUntil a key can carry: key time + 60 days for a notice, + 21 days for a poll; nil (never) for a
-- member's key.
local function tillOf(key)
  local kt = Rules.KeyTime(key)
  if not kt then return nil end
  if isNotice(key) then return kt + C.NOTICE_DAYS_MAX * DAY end
  return kt + C.POLL_HOURS_MAX * HOUR + C.POLL_KEEP_DAYS * DAY
end

-- Remembers key at rev: not asked for again at or below it. One cap per domain; the lowest seq is forgotten first.
local function forget(domain, key, rev, why)
  local g = goneOf(domain)
  local seq = 0
  for _, e in pairs(g) do seq = math.max(seq, tonumber(e.seq) or 0) end
  g[key] = { rev = rev, till = tillOf(key), why = why, seq = seq + 1 }
  while true do
    local n, low = 0, nil
    for k, e in pairs(g) do
      n = n + 1
      if not low or (tonumber(e.seq) or 0) < (tonumber(g[low].seq) or 0) then low = k end
    end
    if n <= GONE_MAX then return end
    g[low] = nil
  end
end

-- A held record of domain (table tname) that reached its keepUntil is dropped and remembered as "expired" with its rev
-- (N1); gone entries are dropped at their till. Nothing is judged without a server time, nor while demo is on (f9:
-- the first roster read after demo turns off prunes).
local function prune(t, domain, tname)
  if not t or ns.InDemo() then return end
  local tbl = db[tname]
  for key, rec in pairs(tbl) do
    if type(rec) == "table" and type(rec.keepUntil) == "number" and Rules.Expired(rec, t) then
      tbl[key] = nil
      if type(rec.rev) == "number" then forget(domain, key, rec.rev, "expired") end
    end
  end
  local g = goneOf(domain)
  for key, e in pairs(g) do
    if type(e) ~= "table" or (type(e.till) == "number" and t >= e.till) then g[key] = nil end
  end
end

-- Security f1 + f9: the first time the guild reads (at a roster read or at the top of a gated store call, demo on or
-- off: f6111), the store is tied to it; another guild than db.guild clears the board, members' votes and lastSeen (as
-- CraftCompat.UseGuild). An unreadable guild clears nothing and is tried again at the next read or call. Then the
-- expiry prune. Returns whether the check has run (f6150: every board store serves and takes nothing until then).
local guildChecked = false
local officerSeen = false  -- d1017: a full, known rosterRead this session found me an officer

local function checkGuild()
  if guildChecked then return true end
  local guild = guildNow()
  if not guild then return false end
  guildChecked = true
  if db.guild ~= nil and db.guild ~= guild then
    db.board, db.officers, db.members, db.gone, db.lastSeen = {}, {}, {}, {}, nil
  end
  db.guild = guild
  local t = now()
  if not t then return true end
  for domain, tname in pairs({ board = "board", board_o = "officers" }) do
    local tbl = db[tname]
    for key, rec in pairs(tbl) do
      if type(rec) ~= "table" or type(rec.keepUntil) ~= "number" then tbl[key] = nil end
    end
    prune(t, domain, tname)
  end
  return true
end

M.On("rosterRead", function(partial)
  rosterPartial = partial and true or false
  rosterSeen = true
  rosterAt = rosterAt or now()
  -- f15: a full, known read drops the members' records whose key left the roster (receivers refuse them anyway)
  if not rosterPartial and not ns.InDemo() and select(4, GuildSync.Comm.Roster()) then
    for key in pairs(db.members) do
      if GuildSync.Comm.Member(key) == nil then db.members[key] = nil end
    end
    -- d1016, d1017: a demotion seen live (an earlier full read this session found me an officer) drops the
    -- officers-only notices (no gone entry: a re-promoted officer asks again); a first read that says "not officer"
    -- only hides them (Store.Notices), and they leave at keepUntil
    local me = myKey()
    if me ~= nil and GuildSync.Comm.IsOfficer(me) then
      officerSeen = true
    elseif me ~= nil and officerSeen then
      officerSeen = false
      db.officers = {}
    end
  end
  if checkGuild() then -- f9: every roster read out of demo runs the expiry prune
    prune(now(), "board", "board")
    prune(now(), "board_o", "officers")
  end
end)

local function officer()
  local Comm = GuildSync.Comm
  local _, partial, _, known = Comm.Roster()
  if not known then return false, "The guild roster is not read yet." end
  if partial then return false, "The guild roster is only partly read. Try again in a moment." end
  if not Comm.IsOfficer(myKey()) then return false, "Only officers can do this." end
  return true
end

local attached = {} -- domain id -> true, or why it did not register or attach (Store.Attached)

-- Every write starts here: demo says the inert line and does nothing; then the officer check, the clock and the
-- attached domain (RC2: the engine mints nothing on a domain that is not attached; with domain nil the caller checks it
-- once it knows the domain). Returns the server time, or nil and the refusal.
local function canWrite(domain)
  if ns.InDemo() then
    ns.Inert()
    return nil, INERT
  end
  local ok, why = officer()
  if not ok then return nil, why end
  local t = now()
  if not t then return nil, NO_TIME end
  if domain and attached[domain] ~= true then return nil, NO_SYNC end
  return t
end

local function demoState() return ns.DemoState() or {} end

-- ---------- readers ----------

local function list(kind, test)
  if ns.InDemo() then
    local out = {}
    for _, rec in ipairs(demoState()[kind] or {}) do out[#out + 1] = rec end
    return out
  end
  return heldOf(test, now())
end

-- Notices and polls held now, tombstones included (removed truthy) until keepUntil.
-- Notices lists db.board, and db.officers only while I count as an officer now (f6152: hidden, not deleted); a
-- db.officers record is listed as a copy marked officers = true (f6110: never written into the saved record).
function Store.Notices()
  if ns.InDemo() then return list("notices", isNotice) end
  local t = now()
  local out = heldOf(isNotice, t)
  if GuildSync.Comm.IsOfficer(myKey()) then
    for _, rec in ipairs(heldOf(isNotice, t, db.officers)) do
      local copy = { officers = true }
      for k, v in pairs(rec) do copy[k] = v end
      out[#out + 1] = copy
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end
function Store.Polls() return list("polls", isPoll) end

local function members()
  if ns.InDemo() then return demoState().members or {} end
  return db.members
end

local function findPoll(key)
  for _, rec in ipairs(Store.Polls()) do if rec.key == key then return rec end end
  return nil
end

function Store.CanPost() return officer() end

-- ---------- notices ----------

-- A key minted this second on either table (board or officers-only) waits a second.
local function taken(key)
  return db.board[key] ~= nil or db.officers[key] ~= nil
end

-- rec's packed body for kind, or nil when it would not fit 16 chunks on domain (board when nil; R-codec).
local function packFor(rec, kind, domain)
  local body = Rules.EncodeRecord(kind, rec)
  if not Rules.Fits((domain or "board") .. ".P", rec.key, rec.by, body) then return nil end
  return body
end

-- R-rev: the held table is written first; the engine then mints rev and hash through store.stamp.
local function changed(key, t, domain)
  officerHeard = true
  M.Sync.Changed(domain or "board", key, t)
end

local AMBIGUOUS = "This notice is ambiguous; ask an officer to remove it."

-- RC3/f3: the domain and table holding a notice key (Edit and Remove act there; Edit never moves it). Returns domain,
-- table, record; nil and a refusal when the key is in both tables, nil when in neither.
local function holder(key, t)
  local inB, inO = held(key, isNotice, t), held(key, isNotice, t, db.officers)
  if inB and inO then return nil, AMBIGUOUS end
  if inO then return "board_o", db.officers, inO end
  return "board", db.board, inB or held(key, isPoll, t)
end

-- f.officers = true mints on board_o into db.officers (R-officers); the caps count per table.
function Store.Post(f)
  local domain, tbl = "board", db.board
  if f.officers then domain, tbl = "board_o", db.officers end
  local t, why = canWrite(domain)
  if not t then return false, why end
  local ok, me = true, myKey()
  ok, why = Rules.CheckNotice(f, me, t, heldOf(isNotice, t, tbl))
  if not ok then return false, why end
  local key = Rules.NoticeKey(t, me)
  if taken(key) then return false, WAIT end
  local expiresAt = t + (f.days or C.NOTICE_DAYS) * DAY
  local rec = { key = key, by = me, author = me, title = f.title, body = f.body or "",
    pinned = f.pinned and true or false, expiresAt = expiresAt, keepUntil = expiresAt }
  rec.packed = packFor(rec, "notice", domain)
  if not rec.packed then return false, LONG end
  tbl[key] = rec
  changed(key, t, domain)
  return true
end

function Store.Edit(key, f)
  local t, why = canWrite()
  if not t then return false, why end
  local ok, me = true, myKey()
  local domain, tbl, rec = holder(key, t)
  if not domain then return false, tbl end
  if not isNotice(key) or not rec then return false, "This notice is gone." end
  if attached[domain] ~= true then return false, NO_SYNC end
  if rec.removed then return false, "This notice was removed." end
  ok, why = Rules.CheckNotice(f, rec.author, t, heldOf(isNotice, t, tbl), key)
  if not ok then return false, why end
  local expiresAt, keepUntil
  ok, why, expiresAt, keepUntil = Rules.EditExpiry(rec, f.days or C.NOTICE_DAYS, t)
  if not ok then return false, why end
  local packed = packFor({ key = key, by = me, author = rec.author, title = f.title, body = f.body or "",
    pinned = f.pinned, expiresAt = expiresAt, keepUntil = keepUntil }, "notice", domain)
  if not packed then return false, LONG end
  rec.title, rec.body, rec.pinned = f.title, f.body or "", f.pinned and true or false
  rec.expiresAt, rec.keepUntil = expiresAt, keepUntil
  rec.by, rec.packed = me, packed
  changed(key, t, domain)
  return true
end

-- A notice or a poll: a tombstone kept until its keepUntil, its text cleared (AC7: a removed body). key, by, author,
-- keepUntil and a poll's firstCloseAt stay; the engine raises rev.
function Store.Remove(key)
  local t, why = canWrite()
  if not t then return false, why end
  local me = myKey()
  local domain, refusal, rec = holder(key, t)
  if not domain then return false, refusal end
  if not rec then return false, "This is gone." end
  if attached[domain] ~= true then return false, NO_SYNC end
  if rec.removed then return false, "This was already removed." end
  rec.removed = true
  rec.title, rec.body, rec.question, rec.options = nil, nil, nil, nil
  rec.by = me
  rec.packed = Rules.EncodeRecord(isPoll(key) and "poll" or "notice", rec)
  changed(key, t, domain)
  return true
end

-- ---------- polls ----------

function Store.PostPoll(f)
  local t, why = canWrite("board")
  if not t then return false, why end
  local ok, me = true, myKey()
  ok, why = Rules.CheckPoll(f, me, t, heldOf(isPoll, t))
  if not ok then return false, why end
  local key = Rules.PollKey(t, me)
  if taken(key) then return false, WAIT end
  local options = {}
  for i, o in ipairs(f.options) do options[i] = o end
  local closeAt = t + (f.hours or C.POLL_HOURS) * HOUR
  local rec = { key = key, by = me, author = me, question = f.question, options = options,
    closeAt = closeAt, firstCloseAt = closeAt, keepUntil = closeAt + C.POLL_KEEP_DAYS * DAY }
  rec.packed = packFor(rec, "poll")
  if not rec.packed then return false, LONG end
  db.board[key] = rec
  changed(key, t)
  return true
end

function Store.ClosePoll(key)
  local t, why = canWrite("board")
  if not t then return false, why end
  local me = myKey()
  local rec = held(key, isPoll, t)
  if not rec then return false, "This poll is gone." end
  if rec.removed then return false, "This poll was removed." end
  if t >= rec.closeAt then return false, "This poll is closed." end
  rec.closeAt, rec.by = t, me
  rec.packed = Rules.EncodeRecord("poll", rec)
  changed(key, t)
  return true
end

-- ---------- votes ----------

-- My vote entries kept at a mint: one for a held, not removed poll; one for a poll not held yet only while its key
-- time + 21 days is ahead (f6102: its P may not have arrived). Returns the kept entries, the count on held polls (the
-- VOTES_MAX refusal counts only those, f6156) and the not-held keys, oldest key time first (dropped first).
local function liveVotes(votes, t)
  local out, n, spare = {}, 0, {}
  for key, v in pairs(votes or {}) do
    local rec, till = held(key, isPoll, t), isPoll(key) and tillOf(key)
    if rec and not rec.removed then
      out[key] = v
      n = n + 1
    elseif not rec and till and t < till then
      out[key] = v
      spare[#spare + 1] = key
    end
  end
  table.sort(spare) -- "q" + 10-digit time: key order is key time order
  return out, n, spare
end

local function voteCheck(pollKey, option)
  -- a rosterRead this session means the roster is known (a new guild table); no Roster() copy per call (f6)
  if not rosterSeen then return false, "The guild roster is not read yet." end
  if rosterPartial then return false, "The guild roster is only partly read. Try again in a moment." end
  local t, me = now(), myKey()
  -- AC13: a nil key, or one the roster does not hold (a name fallback), is not a key receivers accept (f7)
  if me == nil or GuildSync.Comm.Member(me) == nil then return false, "The guild roster is not read yet." end
  if not t then return false, NO_TIME end
  local rec = held(pollKey, isPoll, t)
  if not rec then return false, "This poll is gone." end
  if Store.VoteWaiting() then return false, "Your earlier votes may still be on their way; try again in a moment." end
  local mine = db.members[me]
  local ok, why = Rules.CanVote(rec, mine and mine.votes, option, t)
  if not ok then return false, why end
  local kept, n, spare = liveVotes(mine and mine.votes, t)
  if n >= C.VOTES_MAX then return false, "You have voted in " .. C.VOTES_MAX .. " polls; wait for one to end." end
  return true, nil, kept, t, me, spare
end

function Store.CanVote(pollKey)
  if ns.InDemo() then return false, INERT end
  local rec = findPoll(pollKey)
  return (voteCheck(pollKey, rec and rec.options and #rec.options > 0 and 1 or nil))
end

-- One vote per poll; entries for removed polls or past their latest keepUntil are dropped at this vote (liveVotes).
function Store.Vote(pollKey, option)
  if ns.InDemo() then
    ns.Inert()
    return false, INERT
  end
  local ok, why, kept, t, me, spare = voteCheck(pollKey, option)
  if not ok then return false, why end
  if attached.board_m ~= true then return false, NO_SYNC end
  kept[pollKey] = { option = option, at = t }
  -- f6156: over VOTES_MAX, the entries for polls not held go first, oldest first
  local total = 0
  for _ in pairs(kept) do total = total + 1 end
  for _, key in ipairs(spare) do
    if total <= C.VOTES_MAX then break end
    kept[key], total = nil, total - 1
  end
  local body = Rules.EncodeRecord("votes", { votes = kept })
  if not Rules.Fits("board_m.P", me, me, body) then return false, LONG end
  local mine = db.members[me] or {}
  db.members[me] = mine
  mine.votes, mine.by, mine.packed = kept, me, body
  wroteOwn = true -- adoption is closed: a newer copy of my record is re-minted over from now on
  M.Sync.Changed("board_m", me, t)
  return true
end

-- R-own vote wait: before the first rosterRead + SECOND_WAIT, true while I hold no own record, or while a record
-- adopted this session (and not yet written by me) is inside the settle after its last adoption. No digest condition.
function Store.VoteWaiting()
  if ns.InDemo() then return false end
  local t, me = now(), myKey()
  if not rosterAt or not t then return true end
  if t >= rosterAt + C.SECOND_WAIT then return false end
  local mine = me and db.members[me]
  if type(mine) ~= "table" or type(mine.rev) ~= "number" then return true end
  return (adopted and not wroteOwn and t < adoptedAt + SETTLE) and true or false
end

function Store.MyVote(pollKey)
  local mine = members()[myKey()]
  local v = mine and mine.votes and mine.votes[pollKey]
  return v and v.option or nil
end

-- counts and total for everyone; voters = { [option] = { name, ... } } only for an officer caller.
function Store.Tally(pollKey)
  local rec = findPoll(pollKey)
  if not rec or rec.removed then return nil end -- a tombstone has no options to count
  local all = members()
  local counts, total = Rules.Tally(rec, all)
  if not ns.InDemo() and not GuildSync.Comm.IsOfficer(myKey()) then return counts, total, nil end -- R-demo: officer view
  local voters = {}
  for key, m in pairs(all) do
    local v = m.votes and m.votes[pollKey]
    if v and counts[v.option] and type(v.at) == "number" and v.at <= rec.closeAt then
      voters[v.option] = voters[v.option] or {}
      local list = voters[v.option]
      list[#list + 1] = ns.MemberName(key) -- one row, not a copy of the whole roster (f6)
    end
  end
  for _, l in pairs(voters) do table.sort(l) end
  return counts, total, voters
end

-- ---------- status ----------

function Store.OfficerHeardThisSession() return officerHeard end

-- The newest rev held (notices and polls; a record without a number rev is skipped), nil when none.
function Store.LastOfficerUpdate()
  local best
  for _, list in ipairs({ Store.Notices(), Store.Polls() }) do
    for _, rec in ipairs(list) do
      if type(rec.rev) == "number" and (not best or rec.rev > best) then best = rec.rev end
    end
  end
  return best
end

-- Live notices someone else created after lastSeen. Counted by the key's post time, so an edit is not a new notice.
function Store.SinceLastLogin()
  local t, since, me, n = now(), db.lastSeen or 0, myKey(), 0
  if not t then return 0 end -- no server time: nothing is judged live
  for _, rec in ipairs(Store.Notices()) do
    local created = Rules.KeyTime(rec.key)
    if not rec.removed and t < rec.expiresAt and rec.author ~= me and created and created > since then n = n + 1 end
  end
  return n
end

-- The board has told me about its notices: lastSeen moves to now (never back; nothing while demo is on).
function Store.MarkSeen()
  if ns.InDemo() then return end
  local t = now()
  if not t then return end
  db.lastSeen = math.max(db.lastSeen or 0, t)
end

-- Open polls without my vote.
function Store.OpenUnvoted()
  local t, n = now(), 0
  if not t then return 0 end
  for _, rec in ipairs(Store.Polls()) do
    if not rec.removed and t < rec.closeAt and not Store.MyVote(rec.key) then n = n + 1 end
  end
  return n
end

-- Live notices and open polls.
function Store.Counts()
  local t, notices, polls = now(), 0, 0
  if not t then return 0, 0 end
  for _, rec in ipairs(Store.Notices()) do if not rec.removed and t < rec.expiresAt then notices = notices + 1 end end
  for _, rec in ipairs(Store.Polls()) do if not rec.removed and t < rec.closeAt then polls = polls + 1 end end
  return notices, polls
end

-- ---------- the board domain (CommSync.lua:7-14; Raids Store.lua as the model) ----------

local ROLE = { H = "round", D = "digest", R = "ask", P = "record" }
local KINDS = { round = "H", digest = "D", ask = "R", record = "P" }

local function newer(rev1, hash1, rev2, hash2)
  if (rev1 or 0) ~= (rev2 or 0) then return (rev1 or 0) > (rev2 or 0) end
  return (hash1 or "") > (hash2 or "")
end

local function kindOf(key) return (isNotice(key) and "notice") or (isPoll(key) and "poll") or nil end

-- A record with a number rev (minted or received); readers skip one without (RC2).
local function minted(rec) return type(rec) == "table" and type(rec.rev) == "number" end

local refreshing = false
local function refreshSoon()
  if refreshing then return end
  refreshing = true
  M.After(1, function()
    refreshing = false
    M.RefreshPage()
  end)
end

local function stillWanted(get, w)
  local r = get(w.subject)
  if w.t == "P" then return r ~= nil and r.rev == tonumber(w.version) end
  if w.t == "R" then return ((r and r.rev) or 0) == (tonumber(w.version) or 0) end
  return true
end
local function subject(msg)
  if msg.t == "P" then return msg.key, msg.rev end
  return "-", 0
end
local function parts(msg) return { msg } end

-- A held record's P message, nil when it has no rev or no packed body.
local function recordMsg(key, r)
  if not minted(r) or type(r.packed) ~= "string" then return nil end
  return { t = "P", key = key, rev = r.rev, hash = r.hash, by = r.by, body = r.packed }
end

-- What every board store shares: tbl() is its table at call time, keysAt(t) its sorted keys as sent.
local function shared(store, tbl, keysAt)
  function store.get(key) return tbl()[key] end
  function store.content(key)
    local r = tbl()[key]
    return r and ((r.by or "") .. "~" .. (r.packed or "")) or nil
  end
  function store.stamp(key, rev, hash)
    local r = tbl()[key]
    if r then r.rev, r.hash = rev, hash end
  end
  function store.heardOwn() end
  function store.round(t)
    local list = {}
    for _, k in ipairs(keysAt(t)) do list[#list + 1] = k .. "=" .. tbl()[k].rev .. "=" .. (tbl()[k].hash or "") end
    return { t = "H", hash = Rules.Adler(table.concat(list, "/")) }
  end
  function store.digest(t)
    local entries = {}
    for _, k in ipairs(keysAt(t)) do
      entries[#entries + 1] = { key = k, rev = tbl()[k].rev, hash = tbl()[k].hash }
    end
    return { t = "D", entries = entries }
  end
  store.pack, store.parts, store.subject = Rules.PackMsg, parts, subject
end

-- The board store factory (R-officers): board over db.board, board_o over db.officers. Each store reads only its own
-- table (db[tname] at call time: the saved table, the guild switch and the officers drop replace it).
local function boardStore(domain, tname)
  local store = { recordRule = "officer", kinds = KINDS, maxRecords = 100 }
  local function tbl() return db[tname] end

  local function listKeys(t)
    if not checkGuild() then return {} end -- f6150: keys, digest and round stay empty while the guild is unreadable
    prune(t, domain, tname)
    local list = {}
    for k, r in pairs(tbl()) do if minted(r) and holdable(r, t) then list[#list + 1] = k end end
    table.sort(list)
    return list
  end

  shared(store, tbl, listKeys)
  function store.keys() return listKeys(now()) end
  -- Never own: an officer's copy of another officer's newer record must not be re-minted (as Raids).
  function store.isOwn() return false end
  function store.build(key, t)
    if not checkGuild() then return nil end
    prune(t, domain, tname)
    return recordMsg(key, tbl()[key])
  end

  -- A rev at or below the gone rev is dropped. A body that does not decode is remembered as "bad", one past its
  -- keepUntil as "expired" (R-gone). A good one is ranked with the held records (Rules.KeepSet, AC5): kept, it replaces
  -- the held record (msg.body verbatim as packed) and clears gone, and every held key it pushes out is dropped and
  -- remembered as "cap"; not kept, it is remembered as "cap".
  function store.merge(msg, t)
    if not checkGuild() then return true end -- f6150: dropped, not held
    prune(t, domain, tname)
    local g = goneOf(domain)[msg.key]
    if g and msg.rev <= (tonumber(g.rev) or 0) then return true end
    local kind = kindOf(msg.key)
    local rec = kind and Rules.DecodeRecord(kind, msg.key, msg.body, t)
    if not rec then
      forget(domain, msg.key, msg.rev, "bad")
    elseif t and t >= rec.keepUntil then
      forget(domain, msg.key, msg.rev, "expired")
    else
      rec.key, rec.rev, rec.hash, rec.by, rec.packed = msg.key, msg.rev, msg.hash, msg.by, msg.body
      local test = kind == "poll" and isPoll or isNotice
      local set = { rec }
      for _, r in ipairs(heldOf(test, t, tbl())) do if r.key ~= msg.key then set[#set + 1] = r end end
      local keep = Rules.KeepSet(set, t)
      if not keep[msg.key] then
        forget(domain, msg.key, msg.rev, "cap")
        return true
      end
      for _, r in ipairs(set) do
        if not keep[r.key] then
          tbl()[r.key] = nil
          if type(r.rev) == "number" then forget(domain, r.key, r.rev, "cap") end
        end
      end
      tbl()[msg.key] = rec
      goneOf(domain)[msg.key] = nil
      if GuildSync.Comm.IsOfficer(msg.by) then officerHeard = true end
      refreshSoon()
    end
    return true
  end

  -- A peer key is neither asked for nor counted past its latest keepUntil, or at or below its gone rev (R-gone). It is
  -- not asked for when its author part is not an officer or its key time is past now + FUTURE (f6154: merge would
  -- refuse it), but still counts as theirs, so an equal held record is not pushed again (f6157).
  function store.compare(msg, t)
    if not checkGuild() then return {}, {} end
    prune(t, domain, tname)
    local g = goneOf(domain)
    local send, ask, theirs = {}, {}, {}
    for _, e in ipairs(msg.entries or {}) do
      local k, rev = e.key, tonumber(e.rev) or 0
      local till = Rules.ValidKey(k) and kindOf(k) and tillOf(k)
      if till and t < till and not (g[k] and (tonumber(g[k].rev) or 0) >= rev) then
        theirs[k] = e
        local r = tbl()[k]
        if Rules.KeyTime(k) > t + Rules.FUTURE or not GuildSync.Comm.IsOfficer(k:sub(12)) then -- luacheck: ignore 542
          -- not asked for (f6154)
        elseif minted(r) and holdable(r, t) then
          if newer(rev, e.hash, r.rev, r.hash) then ask[#ask + 1] = { key = k, rev = r.rev } end
        else
          ask[#ask + 1] = { key = k, rev = 0 }
        end
      end
    end
    for _, k in ipairs(listKeys(t)) do
      local e, r = theirs[k], tbl()[k]
      if not e or newer(r.rev, r.hash, tonumber(e.rev) or 0, e.hash) then send[#send + 1] = k end
    end
    return send, ask
  end
  function store.stillWanted(w, t)
    prune(t, domain, tname)
    return stillWanted(store.get, w)
  end
  return store
end

-- ---------- board_m: members' vote records (copy rule; one record per member key, never expires) ----------

local mstore = { recordRule = "copy", kinds = KINDS, maxRecords = 100 }

local function memberKeys()
  if not checkGuild() then return {} end -- f6150, as listKeys
  local list = {}
  for k, r in pairs(db.members) do if minted(r) then list[#list + 1] = k end end
  table.sort(list)
  return list
end

shared(mstore, function() return db.members end, memberKeys)
function mstore.keys() return memberKeys() end
function mstore.isOwn(key) return key ~= nil and key == myKey() end
function mstore.build(key)
  if not checkGuild() then return nil end
  return recordMsg(key, db.members[key])
end

-- R-recv: the body must decode as votes and by must be the key; a refusal is remembered as "bad" (R-gone).
function mstore.merge(msg, t)
  if not checkGuild() then return true end
  local g = goneOf("board_m")[msg.key]
  if g and msg.rev <= (tonumber(g.rev) or 0) then return true end
  local rec = msg.by == msg.key and Rules.DecodeRecord("votes", msg.key, msg.body, t)
  if not rec then
    forget("board_m", msg.key, msg.rev, "bad")
    return true
  end
  rec.rev, rec.hash, rec.by, rec.packed = msg.rev, msg.hash, msg.by, msg.body
  db.members[msg.key] = rec
  goneOf("board_m")[msg.key] = nil
  refreshSoon()
  return true
end

-- A key off the roster is not asked for (f6154: receivers refuse it); it still counts as theirs (f6157).
function mstore.compare(msg)
  if not checkGuild() then return {}, {} end
  local g = goneOf("board_m")
  local send, ask, theirs = {}, {}, {}
  for _, e in ipairs(msg.entries or {}) do
    local k, rev = e.key, tonumber(e.rev) or 0
    if Rules.ValidKey(k) and not (g[k] and (tonumber(g[k].rev) or 0) >= rev) then
      theirs[k] = e
      local r = db.members[k]
      if GuildSync.Comm.Member(k) == nil then -- luacheck: ignore 542
        -- not asked for (f6154)
      elseif minted(r) then
        if newer(rev, e.hash, r.rev, r.hash) then ask[#ask + 1] = { key = k, rev = r.rev } end
      else
        ask[#ask + 1] = { key = k, rev = 0 }
      end
    end
  end
  for _, k in ipairs(memberKeys()) do
    local e, r = theirs[k], db.members[k]
    if not e or newer(r.rev, r.hash, tonumber(e.rev) or 0, e.hash) then send[#send + 1] = k end
  end
  return send, ask
end
function mstore.stillWanted(w) return stillWanted(mstore.get, w) end

-- R-own, before the engine sees a board_m P: a valid copy of my own record (my key from the roster, by == key, not
-- ahead of now + 300) is adopted when I hold none, or replaces an adopted one I have not written while it is newer.
-- Then the engine finds an equal (rev, hash) and sends nothing; otherwise it re-mints above a newer copy (AC16).
-- f6151: only while the vote wait is open (Store.VoteWaiting); after it the engine drops a copy of my key.
local function adoptOwn(msg, t)
  if not checkGuild() or not Store.VoteWaiting() then return end
  local me = myKey()
  if type(msg) ~= "table" or me == nil or msg.key ~= me or msg.by ~= me then return end
  if GuildSync.Comm.Member(me) == nil or type(t) ~= "number" then return end
  if type(msg.rev) ~= "number" or msg.rev > t + 300 then return end
  local rec = Rules.DecodeRecord("votes", me, msg.body, t)
  if not rec then return end
  local mine = db.members[me]
  if minted(mine) and not (adopted and not wroteOwn and newer(msg.rev, msg.hash, mine.rev, mine.hash)) then return end
  mine = mine or {}
  db.members[me] = mine
  mine.rev, mine.hash, mine.by, mine.packed, mine.votes = msg.rev, msg.hash, msg.by, msg.body, rec.votes
  adopted, adoptedAt = true, t
  refreshSoon()
end

-- f13: the first board D, H, P or R handled after login runs every WhenBoardHeard fn once.
local boardHeard, heardFns = false, {}
local function heard()
  if boardHeard then return end
  boardHeard = true
  local fns = heardFns
  heardFns = {}
  for _, fn in ipairs(fns) do M.Safe(fn) end
end

function Store.WhenBoardHeard(fn)
  if boardHeard then M.Safe(fn) else heardFns[#heardFns + 1] = fn end
end

function Store.Attached()
  return { board = attached.board, board_m = attached.board_m, board_o = attached.board_o }
end

-- ---------- the domains: register, then attach, last ----------

local function domain(id, audience, owner, rule, s, onHandled, beforeP)
  local handle = {}
  for kind, role in pairs(ROLE) do
    handle[kind] = function(msg, from, t)
      if beforeP and kind == "P" then beforeP(msg, t) end
      M.Sync.Handle(id, role, msg, from, t)
      if onHandled then onHandled() end
    end
  end
  local ok, why = M.Comm.Register({
    id = id, prefix = audience == "officers" and "GSyncO" or "GSync", audience = audience, owner = owner,
    maxChunks = 16, kinds = { H = { rule = "round" }, D = { rule = "digest" }, R = { rule = "ask" }, P = { rule = rule } },
    unpack = Rules.UnpackMsg, handle = handle,
  })
  if ok then ok, why = M.Sync.Attach(id, s) end
  attached[id] = ok == true or tostring(why or "not attached")
end

domain("board", "guild", "officer", "officer", boardStore("board", "board"), heard)
domain("board_m", "guild", "self", "copy", mstore, nil, adoptOwn)
domain("board_o", "officers", "officer", "officer", boardStore("board_o", "officers"))
