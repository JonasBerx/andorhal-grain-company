-- GuildSyncNoticeBoard: the pure rules. No client call, no global, no os/date: keys, limits and caps of notices and
-- polls, one vote per member, the tally, the calendar type map and status table, minute arithmetic, the event form, and
-- the UTF-8 safe cap. Every limit is read from ns.C (Config.lua); this file keeps no defaults of its own.

local _, ns = ...
if not ns.M then return end

local C = ns.C
local Rules = {}
ns.Rules = Rules

local DAY = 86400
local FULL = "The board is full until older notices expire."
local NOTICE_GONE = "This notice was removed."
local POLL_GONE = "This poll was removed."

local function int(n) return type(n) == "number" and n == math.floor(n) end
local function within(n, lo, hi) return int(n) and n >= lo and n <= hi end
local function bytes(s, lo, hi) return type(s) == "string" and #s >= lo and #s <= hi end

-- ---------- keys ----------

function Rules.NoticeKey(t, author) return "n" .. string.format("%010d", t) .. author end
function Rules.PollKey(t, author) return "q" .. string.format("%010d", t) .. author end

function Rules.KeyTime(key)
  local t = type(key) == "string" and key:match("^[nq](%d%d%d%d%d%d%d%d%d%d)")
  return t and tonumber(t) or nil
end

-- ---------- expiry and the held set ----------

function Rules.Expired(rec, now) return now >= rec.keepUntil end

-- Counts the held records at now, leaving out exceptKey (an edit replaces its record, it does not add one).
-- isOpen(rec) says whether a held record counts against the open/live cap.
local function countHeld(held, now, exceptKey, isOpen)
  local heldN, openN = 0, 0
  for _, rec in ipairs(held or {}) do
    if rec.key ~= exceptKey and not Rules.Expired(rec, now) then
      heldN = heldN + 1
      if isOpen(rec) then openN = openN + 1 end
    end
  end
  return heldN, openN
end

-- ---------- notices ----------

function Rules.CheckNotice(f, author, now, held, exceptKey)
  if type(author) ~= "string" or author == "" or #author > C.AUTHOR_KEY_MAX then
    return false, "Your name is too long for a notice key."
  end
  if not bytes(f.title, 1, C.NOTICE_TITLE) then
    return false, "A title needs 1 to " .. C.NOTICE_TITLE .. " characters."
  end
  if f.body ~= nil and not bytes(f.body, 0, C.NOTICE_BODY) then
    return false, "The text is longer than " .. C.NOTICE_BODY .. " characters."
  end
  local days = f.days == nil and C.NOTICE_DAYS or f.days
  if not within(days, 1, C.NOTICE_DAYS_MAX) then
    return false, "A notice runs 1 to " .. C.NOTICE_DAYS_MAX .. " days."
  end
  local heldN, liveN = countHeld(held, now, exceptKey, function(rec)
    return not rec.removed and now < rec.expiresAt
  end)
  if liveN >= C.NOTICES_LIVE or heldN >= C.NOTICES_HELD then return false, FULL end
  return true
end

-- An edit's new expiry: days count from now, never past key time + NOTICE_DAYS_MAX days, never shorter than the held
-- expiry. keepUntil is raised to the new expiry, never lowered. rec is not written.
function Rules.EditExpiry(rec, days, now)
  if rec.removed then return false, NOTICE_GONE end
  if not within(days, 1, C.NOTICE_DAYS_MAX) then
    return false, "A notice runs 1 to " .. C.NOTICE_DAYS_MAX .. " days."
  end
  local requested = now + days * DAY
  local kt = Rules.KeyTime(rec.key)
  if not kt then
    return false, "A notice ends at most " .. C.NOTICE_DAYS_MAX .. " days after it was posted."
  end
  if rec.expiresAt and requested < rec.expiresAt then
    return false, "An edit can extend a notice, not shorten it."
  end
  -- Past the cap is clamped, not refused: a pre-filled days count near the cap must still save.
  local expiresAt = math.min(requested, kt + C.NOTICE_DAYS_MAX * DAY)
  if rec.expiresAt then expiresAt = math.max(expiresAt, rec.expiresAt) end
  return true, nil, expiresAt, math.max(rec.keepUntil or expiresAt, expiresAt)
end

-- ---------- polls ----------

function Rules.CheckPoll(f, author, now, held, exceptKey)
  if type(author) ~= "string" or author == "" or #author > C.AUTHOR_KEY_MAX then
    return false, "Your name is too long for a poll key."
  end
  if not bytes(f.question, 1, C.POLL_Q) then
    return false, "A question needs 1 to " .. C.POLL_Q .. " characters."
  end
  local opts = f.options
  if type(opts) ~= "table" or #opts < C.POLL_OPTS_MIN or #opts > C.POLL_OPTS_MAX then
    return false, "A poll needs " .. C.POLL_OPTS_MIN .. " to " .. C.POLL_OPTS_MAX .. " options."
  end
  for _, o in ipairs(opts) do
    if not bytes(o, 1, C.POLL_OPT) then
      return false, "Each option needs 1 to " .. C.POLL_OPT .. " characters."
    end
  end
  local hours = f.hours == nil and C.POLL_HOURS or f.hours
  if not within(hours, C.POLL_HOURS_MIN, C.POLL_HOURS_MAX) then
    return false, "A poll runs " .. C.POLL_HOURS_MIN .. " to " .. C.POLL_HOURS_MAX .. " hours."
  end
  local heldN, openN = countHeld(held, now, exceptKey, function(rec)
    return not rec.removed and now < rec.closeAt
  end)
  if openN >= C.POLLS_OPEN or heldN >= C.POLLS_HELD then return false, FULL end
  return true
end

function Rules.CanVote(poll, myVotes, option, now)
  if poll.removed then return false, POLL_GONE end
  if now >= poll.closeAt then return false, "This poll is closed." end
  if myVotes and myVotes[poll.key] then return false, "You have already voted." end
  if not within(option, 1, #poll.options) then return false, "Pick one of the options." end
  return true
end

-- counts: one number per option (zeros included); a vote counts when it is for this poll, its option is in range and
-- it was cast at or before closeAt.
function Rules.Tally(poll, members)
  local n = #poll.options
  local counts, total = {}, 0
  for i = 1, n do counts[i] = 0 end
  for _, m in pairs(members or {}) do
    local v = m.votes and m.votes[poll.key]
    if v and within(v.option, 1, n) and type(v.at) == "number" and v.at <= poll.closeAt then
      counts[v.option] = counts[v.option] + 1
      total = total + 1
    end
  end
  return counts, total
end

-- ---------- calendar types and statuses ----------

Rules.BOARD_TYPES = { "dungeon", "pvp", "social", "rp", "other" }
local TO_GAME = { dungeon = 1, pvp = 2, social = 3, rp = 4, other = 4 }
local RP_PREFIX = "RP: "
-- f1511: what the player reads for a kind; an unknown kind reads capitalised.
local TYPE_LABELS = { raid = "Raid", dungeon = "Dungeon", pvp = "PvP", social = "Social", rp = "RP", other = "Other",
  announcement = "Announcement" }

function Rules.TypeLabel(kind)
  kind = kind or "other"
  return TYPE_LABELS[kind] or (kind:gsub("^%l", string.upper))
end

function Rules.TypeToGame(boardType)
  local g = TO_GAME[boardType]
  if not g then return nil end
  return g, boardType == "rp" and RP_PREFIX or ""
end

function Rules.TypeFromGame(gameType, title)
  if gameType == 1 or gameType == 5 then return "dungeon" end
  if gameType == 2 then return "pvp" end
  if gameType == 3 then return "social" end
  if gameType == 0 then return "raid" end
  if type(title) == "string" and title:lower():sub(1, 3) == "rp:" then return "rp" end
  return "other"
end

-- f1515: the title after a type label ("RP: " .. ShownTitle). An rp event keeps its "RP: " prefix in the game's
-- calendar (that is how TypeFromGame knows it); after the label the prefix would show twice, so it is dropped (matched
-- as TypeFromGame does, plus any spaces after it). Any other kind, or nothing left after the prefix, is unchanged.
-- Lines without a label show the raw title, so the RP cue stays.
function Rules.ShownTitle(kind, title)
  if kind ~= "rp" or type(title) ~= "string" or title:lower():sub(1, 3) ~= "rp:" then return title end
  local rest = title:sub(4):gsub("^ +", "")
  return rest ~= "" and rest or title
end

-- Enum.CalendarStatus: 0 Invited, 1 Available, 2 Declined, 3 Confirmed, 4 Out, 5 Standby, 6 Signedup,
-- 7 NotSignedup, 8 Tentative.
local STATUS = {
  [0] = { "unanswered", "not answered" }, [1] = { "coming", "coming" }, [2] = { "notcoming", "not coming" },
  [3] = { "coming", "coming" }, [4] = { "notcoming", "not coming" }, [5] = { "standby", "standby" },
  [6] = { "coming", "coming" }, [7] = { "unanswered", "not answered" }, [8] = { "tentative", "tentative" },
}

function Rules.Status(n)
  local s = STATUS[n]
  if s then return s[1], s[2] end
  return "other", "status " .. tostring(n)
end

-- The member may answer only from Invited, Available, Declined, Signedup, NotSignedup and Tentative. Confirmed,
-- Out and Standby are set by the event's organiser, and an unknown status (or nil) gets no respond buttons.
local RESPONDABLE = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true, [8] = true }
function Rules.CanRespond(n) return n ~= nil and RESPONDABLE[n] == true end

-- ---------- minutes (realm calendar time, days-from-civil, no os/date) ----------

local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

function Rules.Minutes(ct)
  return (daysFromCivil(ct.year, ct.month, ct.monthDay) * 24 + (ct.hour or 0)) * 60 + (ct.minute or 0)
end

-- weekday 1 = Sunday (day 0, 1 Jan 1970, was a Thursday).
function Rules.FromMinutes(m)
  local days = math.floor(m / 1440)
  local rest = m - days * 1440
  local y, mo, d = civilFromDays(days)
  return { year = y, month = mo, monthDay = d, hour = math.floor(rest / 60), minute = rest % 60,
    weekday = (days + 4) % 7 + 1 }
end

-- ---------- text ----------

function Rules.Chars(text)
  return select(2, text:gsub("[^\128-\191]", ""))
end

function Rules.Cap(text, maxBytes)
  if #text <= maxBytes then return text end
  local i = maxBytes
  while i > 0 do
    local b = text:byte(i + 1)
    if b < 128 or b >= 192 then break end
    i = i - 1
  end
  return text:sub(1, i)
end

-- ---------- event form ----------

-- today is the realm calendar's now (Create.Range: C_DateAndTime.GetCurrentCalendarTime, with hour and minute; a
-- missing hour or minute reads as 0). A time on today's date must be after it.
function Rules.CheckEvent(f, today, maxDate)
  local isBoard = false
  for _, t in ipairs(Rules.BOARD_TYPES) do if t == f.type then isBoard = true end end
  if not isBoard then return false, "Pick a type: dungeon, PvP, social, RP or other." end
  local _, prefix = Rules.TypeToGame(f.type)
  if type(f.title) ~= "string" or f.title == "" then return false, "An event needs a title." end
  if Rules.Chars(prefix) + Rules.Chars(f.title) > C.EVENT_TITLE then
    return false, "A title is at most " .. (C.EVENT_TITLE - Rules.Chars(prefix)) .. " characters."
  end
  if f.description ~= nil and (type(f.description) ~= "string" or Rules.Chars(f.description) > C.EVENT_DESC) then
    return false, "A description is at most " .. C.EVENT_DESC .. " characters."
  end
  local d = f.date
  if type(d) ~= "table" or not (int(d.year) and within(d.month, 1, 12) and within(d.monthDay, 1, 31)) then
    return false, "Pick a date."
  end
  local day = daysFromCivil(d.year, d.month, d.monthDay)
  if day < daysFromCivil(today.year, today.month, today.monthDay)
    or day > daysFromCivil(maxDate.year, maxDate.month, maxDate.monthDay) then
    return false, "Pick a date from today to the last day the calendar takes."
  end
  if not within(f.hour, 0, 23) then return false, "Pick an hour from 0 to 23." end
  if not within(f.minute, 0, 59) or f.minute % C.MINUTE_STEP ~= 0 then
    return false, "Pick the minutes in steps of " .. C.MINUTE_STEP .. "."
  end
  local nowHour, nowMinute = int(today.hour) and today.hour or 0, int(today.minute) and today.minute or 0
  if day == daysFromCivil(today.year, today.month, today.monthDay)
    and f.hour * 60 + f.minute <= nowHour * 60 + nowMinute then
    return false, string.format("Pick a time after now: it is %02d:%02d realm time.", nowHour, nowMinute)
  end
  return true
end
