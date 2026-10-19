-- GuildSyncNoticeBoard: the local store for officer notices, polls and members' votes (brief AC5-AC8, AC10-AC13, AC17,
-- AC43 as sliced by ui-slice.md: local data only, nothing sent). Kept in GuildSyncNoticeBoardDB:
--   { v = 1, board = { [key] = rec }, members = { [memberKey] = { rev, by, votes = { [pollKey] = { option, at } } } },
--     lastSeen, lead, guild }
-- lastSeen: the server time the board last told me about notices (saved at PLAYER_LOGOUT, advanced by Store.MarkSeen
-- after the login line); notices created after it by someone else are new.
-- Writes check demo, officer (roster known, not partial), removed, then Rules; edits and removals change the held
-- record table in place. hash stays nil until the sync run. Readers judge expiry at call time; the saved table is pruned
-- on the session's first roster read out of demo with a readable guild (guild: the one the store belongs to).

local name, ns = ...
if not ns.M then return end

local M, C, Rules = ns.M, ns.C, ns.Rules
local Store = {}
ns.Store = Store

local DAY, HOUR = 86400, 3600
local INERT = "Demo: nothing is done to made-up members."

local session = { v = 1, board = {}, members = {} } -- until ADDON_LOADED adopts the saved table
local db = session
local rosterSeen = false   -- a rosterRead came this session
local rosterPartial = true -- the last rosterRead was partial (f6: vote checks read this, not a Roster() copy)
local officerHeard = false -- this session made an officer write

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
  if type(GuildSyncNoticeBoardDB) ~= "table" then GuildSyncNoticeBoardDB = { v = 1 } end
  db = GuildSyncNoticeBoardDB
  if type(db.board) ~= "table" then db.board = {} end
  if type(db.members) ~= "table" then db.members = {} end
  db.v = db.v or 1
end)

function ns.DB() return db end

local NO_TIME = "The server time is not readable now."

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

-- Security f1 + f9: on the first roster read out of demo (not just the session's first), the store is tied to the
-- guild read then; another guild than db.guild clears the board, members' votes and lastSeen (as CraftCompat.UseGuild).
-- An unreadable guild clears nothing and is tried again on the next read. Then the expiry prune.
local guildChecked = false

M.On("rosterRead", function(partial)
  rosterPartial = partial and true or false
  rosterSeen = true
  if guildChecked or ns.InDemo() then return end
  local guild = guildNow()
  if not guild then return end
  guildChecked = true
  if db.guild ~= nil and db.guild ~= guild then
    db.board, db.members, db.lastSeen = {}, {}, nil
  end
  db.guild = guild
  local t = now()
  if not t then return end
  for key, rec in pairs(db.board) do
    if type(rec) ~= "table" or type(rec.keepUntil) ~= "number" or Rules.Expired(rec, t) then db.board[key] = nil end
  end
end)

-- ---------- helpers ----------

local function myKey() return GuildSync.Comm.MyKey() end

local function isNotice(key) return type(key) == "string" and key:sub(1, 1) == "n" end
local function isPoll(key) return type(key) == "string" and key:sub(1, 1) == "q" end

-- A record the store can hold: a table with a numeric keepUntil (the prune's test), not past it at t; with t nil (no
-- server time) expiry is not judged.
local function holdable(rec, t)
  return type(rec) == "table" and type(rec.keepUntil) == "number" and (t == nil or not Rules.Expired(rec, t))
end

-- The held records of one kind (prefix "n" or "q") not past keepUntil at t.
local function heldOf(test, t)
  local out = {}
  for key, rec in pairs(db.board) do
    if test(key) and holdable(rec, t) then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- A held record of one kind, nil when absent or past keepUntil.
local function held(key, test, t)
  local rec = test(key) and db.board[key]
  if not holdable(rec, t) then return nil end
  return rec
end

local function bump(rec, t, me)
  rec.rev = math.max(t, (rec.rev or 0) + 1)
  rec.by = me
end

local function officer()
  local Comm = GuildSync.Comm
  local _, partial, _, known = Comm.Roster()
  if not known then return false, "The guild roster is not read yet." end
  if partial then return false, "The guild roster is only partly read. Try again in a moment." end
  if not Comm.IsOfficer(myKey()) then return false, "Only officers can do this." end
  return true
end

-- Every write starts here: demo says the inert line and does nothing; then the officer check, then the clock.
-- Returns the server time, or nil and the refusal.
local function canWrite()
  if ns.InDemo() then
    ns.Inert()
    return nil, INERT
  end
  local ok, why = officer()
  if not ok then return nil, why end
  local t = now()
  if not t then return nil, NO_TIME end
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
function Store.Notices() return list("notices", isNotice) end
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

function Store.Post(f)
  local t, why = canWrite()
  if not t then return false, why end
  local ok, me = true, myKey()
  ok, why = Rules.CheckNotice(f, me, t, heldOf(isNotice, t))
  if not ok then return false, why end
  local key = Rules.NoticeKey(t, me)
  if db.board[key] then return false, "Wait a second before posting again." end
  local expiresAt = t + (f.days or C.NOTICE_DAYS) * DAY
  db.board[key] = { key = key, rev = t, by = me, author = me, title = f.title, body = f.body or "",
    pinned = f.pinned and true or false, expiresAt = expiresAt, keepUntil = expiresAt }
  officerHeard = true
  return true
end

function Store.Edit(key, f)
  local t, why = canWrite()
  if not t then return false, why end
  local ok, me = true, myKey()
  local rec = held(key, isNotice, t)
  if not rec then return false, "This notice is gone." end
  if rec.removed then return false, "This notice was removed." end
  ok, why = Rules.CheckNotice(f, rec.author, t, heldOf(isNotice, t), key)
  if not ok then return false, why end
  local expiresAt, keepUntil
  ok, why, expiresAt, keepUntil = Rules.EditExpiry(rec, f.days or C.NOTICE_DAYS, t)
  if not ok then return false, why end
  rec.title, rec.body, rec.pinned = f.title, f.body or "", f.pinned and true or false
  rec.expiresAt, rec.keepUntil = expiresAt, keepUntil
  bump(rec, t, me)
  officerHeard = true
  return true
end

-- A notice or a poll: a tombstone kept until its keepUntil, its text cleared (AC7: a removed body). key, rev, by,
-- author, keepUntil and a poll's firstCloseAt stay.
function Store.Remove(key)
  local t, why = canWrite()
  if not t then return false, why end
  local ok, me = true, myKey()
  local rec = held(key, isNotice, t) or held(key, isPoll, t)
  if not rec then return false, "This is gone." end
  if rec.removed then return false, "This was already removed." end
  rec.removed = true
  rec.title, rec.body, rec.question, rec.options = nil, nil, nil, nil
  bump(rec, t, me)
  officerHeard = true
  return true
end

-- ---------- polls ----------

function Store.PostPoll(f)
  local t, why = canWrite()
  if not t then return false, why end
  local ok, me = true, myKey()
  ok, why = Rules.CheckPoll(f, me, t, heldOf(isPoll, t))
  if not ok then return false, why end
  local key = Rules.PollKey(t, me)
  if db.board[key] then return false, "Wait a second before posting again." end
  local options = {}
  for i, o in ipairs(f.options) do options[i] = o end
  local closeAt = t + (f.hours or C.POLL_HOURS) * HOUR
  db.board[key] = { key = key, rev = t, by = me, author = me, question = f.question, options = options,
    closeAt = closeAt, firstCloseAt = closeAt, keepUntil = closeAt + C.POLL_KEEP_DAYS * DAY }
  officerHeard = true
  return true
end

function Store.ClosePoll(key)
  local t, why = canWrite()
  if not t then return false, why end
  local ok, me = true, myKey()
  local rec = held(key, isPoll, t)
  if not rec then return false, "This poll is gone." end
  if rec.removed then return false, "This poll was removed." end
  if t >= rec.closeAt then return false, "This poll is closed." end
  rec.closeAt = t
  bump(rec, t, me)
  officerHeard = true
  return true
end

-- ---------- votes ----------

-- My vote entries that still point at a held, not removed poll.
local function liveVotes(votes, t)
  local out, n = {}, 0
  for key, v in pairs(votes or {}) do
    local rec = held(key, isPoll, t)
    if rec and not rec.removed then
      out[key] = v
      n = n + 1
    end
  end
  return out, n
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
  local mine = db.members[me]
  local ok, why = Rules.CanVote(rec, mine and mine.votes, option, t)
  if not ok then return false, why end
  local kept, n = liveVotes(mine and mine.votes, t)
  if n >= C.VOTES_MAX then return false, "You have voted in " .. C.VOTES_MAX .. " polls; wait for one to end." end
  return true, nil, kept, t, me
end

function Store.CanVote(pollKey)
  if ns.InDemo() then return false, INERT end
  local rec = findPoll(pollKey)
  return (voteCheck(pollKey, rec and rec.options and #rec.options > 0 and 1 or nil))
end

-- One vote per poll; entries for polls removed or no longer held are dropped at this vote.
function Store.Vote(pollKey, option)
  if ns.InDemo() then
    ns.Inert()
    return false, INERT
  end
  local ok, why, kept, t, me = voteCheck(pollKey, option)
  if not ok then return false, why end
  local mine = db.members[me] or {}
  db.members[me] = mine
  kept[pollKey] = { option = option, at = t }
  mine.votes = kept
  mine.by = me
  mine.rev = math.max(t, (mine.rev or 0) + 1)
  return true
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
  if not GuildSync.Comm.IsOfficer(myKey()) then return counts, total, nil end
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

-- The newest rev held (notices and polls), nil when none.
function Store.LastOfficerUpdate()
  local best
  for _, rec in ipairs(Store.Notices()) do if not best or rec.rev > best then best = rec.rev end end
  for _, rec in ipairs(Store.Polls()) do if not best or rec.rev > best then best = rec.rev end end
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
