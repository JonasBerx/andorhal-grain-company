-- Annals AnnalsRules: every tunable number and rule of the annals. The health bands come first (AC10), then
-- the gone rule, guild-log times, max level and milestones, ding windows and their ranking,
-- new members and anniversaries, former expiry, name keys and UTC civil dates.
-- Last, Rules.DemoGuild(now): the made-up guild /annals demo shows.
-- Pure Lua 5.1, no client calls: times are GetServerTime() seconds, passed in.
local _, ns = ...
local Rules = {}
ns.AnnalsRules = Rules

-- Days since last online, per band; maxDays nil is open-ended. The first table in this file, so it is easy to find.
Rules.BANDS = {
  { key = "active", label = "Active", maxDays = 3 },
  { key = "cooling", label = "Cooling", maxDays = 7 },
  { key = "fading", label = "Fading", maxDays = 14 },
  { key = "atrisk", label = "At risk", maxDays = 30 },
  { key = "gone", label = "Gone", maxDays = nil },
}
Rules.UNKNOWN_KEY, Rules.UNKNOWN_LABEL = "unknown", "No data"

local DAY = 86400
local floor = math.floor

Rules.READ_GAP = 60             -- seconds between roster reads (as Roster.lua)
Rules.LOGIN_REQUEST = 5         -- after login: ask for the roster and the guild log
Rules.LOGIN_READ = 12           -- after login: the first read
Rules.REQUEST_GAP = 60          -- from login on, ask for the roster this often (the read throttle, review f5)
Rules.LOG_REQUEST_EVERY = 10    -- and for the guild log every this many roster requests (10 min)
Rules.RETRY_GAP = 10            -- a nil Members() or a missing guild name is retried this often
Rules.RETRY_MAX = 12
Rules.GONE_FULL_READS = 3       -- counted full reads in a row that must miss a character
Rules.GONE_SPAN = 2 * DAY       -- between the first and the latest of those misses
Rules.LOG_SLACK = DAY           -- a guild-log entry may be this much older than the last read that listed them
Rules.FORMER_KEEP = 180 * DAY   -- former characters are dropped this long after they went
Rules.FORMER_MAX = 50           -- and only the newest this many are kept (security s3: the saved-file bound;
                                -- with RANK_KEEP it holds up to about 200 current members, f1549)
Rules.NEW_DAYS = 7
Rules.RETURN_DAYS = 7
Rules.LEADERS = 10
Rules.TIE_NAMES = 5
Rules.REASON_MAX = 100
Rules.MILESTONE_STEP = 10
Rules.MAX_LEVEL_FALLBACK = 60   -- GuildSync's View.MAX_LEVEL
Rules.RANK_SLACK = 3600         -- a promote/demote log entry may lie this far outside a rank change's read window
Rules.RANK_KEEP = 12           -- only the newest this many rank changes per character are kept (d308, d310);
                               -- the size bound with FORMER_MAX holds up to about 200 current members (f1549)
Rules.RANK_FOLD = DAY          -- a change back to the rank before, this soon after the last change, cancels it (d308)
Rules.RANK_USED_KEEP = 2       -- a cancelled change's log time is kept this many deep in rec.ru (review r3, r4)
Rules.AWAY_GAP = 900            -- a read window wider than this is "while you were away"
Rules.FOLD_MIN = 5              -- a run of more than this many old rises folds into one Journey row
Rules.FOLD_AGE = 7 * DAY        -- rises older than this may fold
Rules.LOG_ROWS = 200            -- Level log rows per page
Rules.RANK_USED_RADIUS = 5400   -- a log entry this close to a time in rec.ru is used (d314: LogTime's error span)
-- Achievements (phase B)
Rules.NIGHT_HOUR = 3            -- Night Shift: a read in this realm hour
Rules.MUSTER = 25               -- Full Muster: online with at least this many others
Rules.DING_TOGETHER = 600       -- Ding Together: two dings to one level surely this close
Rules.FRESH_LEVEL = 10          -- Fresh From the Grave: this level within a day of a log join
Rules.RECRUIT_LEVEL = 20        -- Recruiter: an invitee reached this level in the guild
Rules.LOG_ERROR = 5400          -- LogTime lies in [T - 1800, T + 5400)
Rules.FOUNDING_BY = 1794438000  -- Founding Hand: in the Company by 12 Nov 2026 00:00 CET (D15)
Rules.RECRUIT_COUNT = 3         -- Recruiter: three: this many invitees reached RECRUIT_LEVEL
Rules.ROLL_CALL = 10            -- Roll Call: online at a read with this many guildmates
Rules.GRAND_MUSTER = 50         -- Grand Muster: the same, this many
Rules.WELL_DECORATED = 500      -- Well Decorated: achievement points on the roster
Rules.DING_FRIENDS = 5          -- Ding Together: five: Ding Together pairs with this many different guildmates
Rules.EARLY_JOIN_LEVEL = 10     -- Early Harvest: a log join below this level ...
Rules.EARLY_DAYS = 30           -- ... reaching the max level within this many days
Rules.COIN = 1000000            -- A Coin for the Company: copper held at once (100 gold)
Rules.PURSE = 10000000          -- A Purse for the Company: the same, 1,000 gold
Rules.CAPITALS = { "Orgrimmar", "Thunder Bluff", "Undercity" } -- Every Capital: zone texts, exact (enUS)
Rules.SILENT_DAYS = 30          -- Strong, Silent Type: days with no own guild line
Rules.AC_MAX = 512              -- a saved ac longer than this is malformed: read as "", replaced at the next write
-- Zone musters (D14): need online guildmates in one of the zones (English names) at one read.
Rules.MUSTER_ZONES = {
  dm = { need = 5,  zones = { "Ragefire Chasm", "Wailing Caverns", "The Deadmines", "Deadmines", "Shadowfang Keep",
         "Blackfathom Deeps", "The Stockade", "Stormwind Stockade", "Gnomeregan", "Razorfen Kraul", "Scarlet Monastery",
         "Razorfen Downs", "Uldaman", "Zul'Farrak", "Maraudon", "The Temple of Atal'Hakkar", "Sunken Temple",
         "Blackrock Depths", "Blackrock Spire", "Lower Blackrock Spire", "Upper Blackrock Spire", "Dire Maul",
         "Stratholme", "Scholomance" } },
  rm = { need = 10, zones = { "Molten Core", "Onyxia's Lair", "Blackwing Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj",
         "Ahn'Qiraj", "Temple of Ahn'Qiraj", "Naxxramas" } },
  bm = { need = 5,  zones = { "Warsong Gulch", "Arathi Basin", "Alterac Valley" } },
  ag = { need = 10, zones = { "Stormwind City", "Ironforge", "Darnassus" } },
  ma = { need = 10, zones = { "Western Plaguelands" } },
}
-- The earned string, F2 (d516, d518): "<id><3-char base-36 realm day>;" each, AnnalsDB.v = DB_VERSION
Rules.DB_VERSION = 2
Rules.REALM_OFFSET_FALLBACK = 3600 -- realm time minus UTC in seconds when the realm clock cannot be read
Rules.HALF_DAY = 43200          -- an earned day reads back at realm noon
Rules.EA_MAX = 4096             -- a saved ea longer than this is malformed and read as "" (f3580)

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local DAY_MAX = 46655           -- "zzz"

-- One earned entry: id .. the realm day of t (t clamped to 0, the day to 0..DAY_MAX) in 3 base-36 characters .. ";".
function Rules.EarnEntry(id, t, offset)
  local d = floor((math.max(0, t) + (offset or Rules.REALM_OFFSET_FALLBACK)) / DAY)
  if d < 0 then d = 0 elseif d > DAY_MAX then d = DAY_MAX end
  local a, b, c = floor(d / 1296) + 1, floor(d / 36) % 36 + 1, d % 36 + 1
  return id .. B36:sub(a, a) .. B36:sub(b, b) .. B36:sub(c, c) .. ";"
end
-- Away runs (D10, f3524): in memory per session, never saved
Rules.AFK_READ_GAP = 300        -- a run continues only while the previous read is at most this old
Rules.AFK_RUN = 3 * 3600        -- Asleep at the Desk: a run this long

-- { [guid] = since } for every member away at this read: since is kept from prev when the previous read (prevAt) is
-- at most AFK_READ_GAP old and the member was away then too; otherwise the run starts now.
function Rules.AfkRuns(prev, prevAt, members, now)
  local keep = prev and prevAt and now - prevAt <= Rules.AFK_READ_GAP
  local out = {}
  for guid, m in pairs(members or {}) do
    if m.away then out[guid] = (keep and prev[guid]) or now end
  end
  return out
end
-- The page in the GuildSync window (window plan D17): widths in px
Rules.DEMO_MAX_LEVEL = 60       -- the max level Rules.DemoGuild is laid out for, whatever the client's max
Rules.PAGE_W_DEFAULT = 726      -- the page width before the first size event (the default 900-wide window)
Rules.SCROLL_W = 24             -- the scroll bar
Rules.COL_GAP = 10
Rules.TWO_COL_MIN = 610         -- two columns of at least 300 each, plus COL_GAP
Rules.CAT_W = 170               -- the Achievements category buttons
Rules.CARD_MAX = 516
Rules.BAR_MAX = 520
Rules.LEVEL_BAR_MAX = 360
Rules.RELAYOUT_SETTLE = 0.2     -- seconds after a resize within a step before the page redraws once

-- The layout for a page `w` wide; nil, not a number, or not above 0 takes PAGE_W_DEFAULT.
function Rules.PageLayout(w)
  if type(w) ~= "number" or w <= 0 then w = Rules.PAGE_W_DEFAULT end
  local inner = w - Rules.SCROLL_W
  local two = inner >= Rules.TWO_COL_MIN
  return {
    inner = inner,
    cols = two and 2 or 1,
    colW = two and (inner - Rules.COL_GAP) / 2 or inner,
    cardW = math.min(Rules.CARD_MAX, inner - Rules.CAT_W - Rules.COL_GAP),
    barW = math.min(Rules.BAR_MAX, inner - 120),
    levelBarW = math.min(Rules.LEVEL_BAR_MAX, inner - 220),
  }
end
Rules.FEAT_LOG_SLACK = 3 * DAY  -- a log join counts toward tenure only from j + this (q253)
Rules.FEED_ROWS = 5             -- rows in "Lately in the Company"
Rules.PCT_STEPS = 100           -- a title bar's steps
Rules.TRACK_CARD_MAX = 144      -- the reward track's title cards (d504, lg-1): widest card
Rules.TRACK_INSET = 18          -- the track spans the page width less this (d514): 708 at PAGE_W_DEFAULT
Rules.TRACK_OVERLAP = 3         -- neighbouring cards overlap this much
Rules.TRACK_H = 175             -- the track's height; the columns start under it

-- The track for `inner` px and n cards: cardW is the largest c <= TRACK_CARD_MAX with n * c - (n - 1) * overlap
-- <= inner, found by multiplication only (f1454). xs and centres per card from 0; span is the bar's width.
function Rules.TrackLayout(inner, n)
  local o = Rules.TRACK_OVERLAP
  local c = Rules.TRACK_CARD_MAX
  while c > 1 and n * c - (n - 1) * o > inner do c = c - 1 end
  local step = c - o
  local xs, centres = {}, {}
  for i = 1, n do
    xs[i] = (i - 1) * step
    centres[i] = xs[i] + c * 0.5
  end
  return { cardW = c, step = step, xs = xs, centres = centres, span = n * c - (n - 1) * o }
end

-- The fill's end on track T at title cur with pct (Rules.Title): pct of the way between cur's centre and the
-- next one's; at the top title the whole span.
function Rules.TrackFill(T, cur, pct)
  local a, b = T.centres[cur], T.centres[cur + 1]
  if not b then return T.span end
  return a + floor((b - a) * pct / Rules.PCT_STEPS)
end

-- Health ---------------------------------------------------------------------------------------------------------

-- Whole days from t to now, nil when t is unknown.
function Rules.DaysSince(t, now)
  if type(t) ~= "number" or type(now) ~= "number" then return nil end
  local d = floor((now - t) / DAY)
  if d < 0 then d = 0 end
  return d
end

-- Online is Active; no last-online data is "unknown" (listed last as "No data").
function Rules.Band(days, online)
  local bands = Rules.BANDS
  if online then return bands[1].key, bands[1].label end
  if type(days) ~= "number" then return Rules.UNKNOWN_KEY, Rules.UNKNOWN_LABEL end
  for _, b in ipairs(bands) do
    if b.maxDays == nil or days <= b.maxDays then return b.key, b.label end
  end
end

-- Gone by absence: enough counted full misses, and the first of them far enough back (D6).
function Rules.GoneByAbsence(missCount, firstMiss, now)
  return type(missCount) == "number" and missCount >= Rules.GONE_FULL_READS
    and type(firstMiss) == "number" and now - firstMiss >= Rules.GONE_SPAN
end

-- A guild-log entry's age (year, month, day, hour, as Blizzard's pane reads them) as server time, hour-rounded.
-- Months are 30.5 days, as Roster.lua does.
function Rules.LogTime(entry, now)
  local hoursAgo = ((((entry.year or 0) * 12 + (entry.month or 0)) * 30.5 + (entry.day or 0)) * 24 + (entry.hour or 0))
  return floor((now - hoursAgo * 3600) / 3600 + 0.5) * 3600
end

-- A log entry speaks about a character only when it is no older than their last listing minus LOG_SLACK.
function Rules.LogApplies(ts, lastSeen)
  return type(ts) == "number" and type(lastSeen) == "number" and ts >= lastSeen - Rules.LOG_SLACK
end

function Rules.Expired(goneAt, now)
  return type(goneAt) == "number" and now - goneAt > Rules.FORMER_KEEP
end

-- Level race -----------------------------------------------------------------------------------------------------

local function positive(n) return type(n) == "number" and n > 0 end

-- The lower of the two client answers when both are positive numbers, the one that is, else the fallback (D8).
function Rules.MaxLevel(playerMax, expansionMax)
  if positive(playerMax) and positive(expansionMax) then return math.min(playerMax, expansionMax) end
  if positive(playerMax) then return playerMax end
  if positive(expansionMax) then return expansionMax end
  return Rules.MAX_LEVEL_FALLBACK
end

-- Every MILESTONE_STEP below the max, then the max.
function Rules.Milestones(maxLevel)
  local out = {}
  local m = Rules.MILESTONE_STEP
  while m < maxLevel do
    out[#out + 1] = m
    m = m + Rules.MILESTONE_STEP
  end
  out[#out + 1] = maxLevel
  return out
end

-- The milestones M a rise from -> to passes: from < M <= to.
function Rules.Crosses(from, to, milestones)
  local out = {}
  for _, m in ipairs(milestones) do
    if from < m and m <= to then out[#out + 1] = m end
  end
  return out
end

-- q194 lives here only: a character first seen at or above M counts, with the window (-inf, first seen].
function Rules.FirstSeenWindow(fl, fs, M)
  if type(fl) == "number" and fl >= M then return { after = nil, by = fs } end
  return nil
end

-- Windows are (after, by]; after == by is the exact instant by; after nil is minus infinity.
-- a is surely before b when a ends before b starts, or ends where b starts and b is not exact.
function Rules.Surely(a, b)
  if b.after == nil then return false end
  if a.by < b.after then return true end
  return a.by == b.after and b.after ~= b.by
end

local function before(a, b)
  if a.by ~= b.by then return a.by < b.by end
  if a.after ~= b.after then
    if a.after == nil then return true end
    if b.after == nil then return false end
    return a.after < b.after
  end
  return (a.name or "") < (b.name or "")
end

-- Candidates ranked by by, then after (nil first), then name. sure: the leader is surely before every other one.
function Rules.Rank(cands)
  local sorted = {}
  for i, c in ipairs(cands) do sorted[i] = c end
  table.sort(sorted, before)
  if #sorted == 0 then return sorted, false end
  local sure = true
  for i = 2, #sorted do
    if not Rules.Surely(sorted[1], sorted[i]) then sure = false break end
  end
  return sorted, sure
end

-- Dates (UTC civil days, Hinnant's algorithms; no date()) -----------------------------------------------------------

local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  local y = yoe + era * 400
  if m <= 2 then y = y + 1 end
  return y, m, d
end

function Rules.Civil(t)
  return civilFromDays(floor(t / DAY))
end

-- New and anniversaries --------------------------------------------------------------------------------------------

function Rules.IsNew(joinAt, now)
  return type(joinAt) == "number" and now - joinAt < Rules.NEW_DAYS * DAY
end

-- An anniversary due in [today, today + 6] (UTC days): 1 to 11 months, then whole years. A join on a day the due
-- month lacks is due on that month's last day. Returns nil, or { months = n } / { years = n } and the due day's start.
function Rules.Anniversary(joinAt, now)
  if type(joinAt) ~= "number" then return nil end
  local jy, jm, jd = Rules.Civil(joinAt)
  local ty, tm = Rules.Civil(now)
  local today = floor(now / DAY)
  local diff = (ty * 12 + tm) - (jy * 12 + jm)
  for k = diff, diff + 1 do
    if k >= 1 then
      local idx = jy * 12 + (jm - 1) + k
      local y, m = floor(idx / 12), idx % 12 + 1
      local last = daysFromCivil(m == 12 and y + 1 or y, m == 12 and 1 or m + 1, 1) - daysFromCivil(y, m, 1)
      local due = daysFromCivil(y, m, math.min(jd, last))
      if due >= today and due <= today + 6 then
        if k < 12 then return { months = k }, due * DAY end
        if k % 12 == 0 then return { years = k / 12 }, due * DAY end
        return nil
      end
    end
  end
  return nil
end

-- Titles and tenure (phase B) --------------------------------------------------------------------------------------

Rules.TITLES = { { name = "Hand", at = 0 }, { name = "Foreman", at = 100 }, { name = "Overseer", at = 250 },
  { name = "Quartermaster", at = 500 }, { name = "Steward", at = 1000 } }

-- The title for a points total and the bar to the next one. pct is the largest whole k <= PCT_STEPS with
-- (points - at) * PCT_STEPS >= k * (nextAt - at): multiplication only (f1454). At the top title pct is 100.
function Rules.Title(points)
  local titles = Rules.TITLES
  local i = 1
  while titles[i + 1] and points >= titles[i + 1].at do i = i + 1 end
  local cur, nxt = titles[i], titles[i + 1]
  if not nxt then return { name = cur.name, at = cur.at, pct = 100 } end
  local pct = 0
  while pct < Rules.PCT_STEPS and (points - cur.at) * Rules.PCT_STEPS >= (pct + 1) * (nxt.at - cur.at) do
    pct = pct + 1
  end
  return { name = cur.name, at = cur.at, nextName = nxt.name, nextAt = nxt.at, pct = pct }
end

-- d322: the start of the current stretch in the guild: the return, else first seen or a log join plus slack.
-- A coarse log join (jc) adds nothing: it may lie earlier than the truth by more than the slack (f1537).
function Rules.StretchStart(rec)
  if rec.ret then return rec.ret end
  local start = rec.fs
  if rec.js == "log" and type(rec.j) == "number" and rec.jc == nil then
    local j = rec.j + Rules.FEAT_LOG_SLACK
    if type(start) ~= "number" or j < start then start = j end
  end
  return start
end

-- Seconds surely in the guild: banked closed stretches plus the current one.
function Rules.Tenure(rec, now)
  return (rec.tb or 0) + math.max(0, now - (Rules.StretchStart(rec) or now))
end

-- Names ----------------------------------------------------------------------------------------------------------

-- Class tokens as shown (Journey, "First <Class> to N"); Feats loads before View, so the table lives here.
Rules.CLASS_NAMES = {
  WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
  DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", MONK = "Monk",
  DRUID = "Druid", DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker",
}

-- Race names as shown ("First Forsaken to 60"); any other race shows as the roster gives it.
Rules.RACE_NAMES = { Undead = "Forsaken" }

-- The race's key in G.rs ("f<M><token>", D8): its letters and digits, at most 19; nil for no race.
function Rules.RaceToken(raceName)
  if type(raceName) ~= "string" then return nil end
  local t = raceName:gsub("%W", ""):sub(1, 19)
  if t == "" then return nil end
  return t
end

-- "First Surname-Realm" -> "first surname": realm cut at the first "-", lowercased, trimmed. nil if empty.
function Rules.NameKey(name)
  if type(name) ~= "string" then return nil end
  local k = (name:match("^([^-]*)") or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

-- The last space-separated word of a name, NameKey-folded; nil for a one-word name (Family Reunion).
function Rules.Surname(name)
  local k = Rules.NameKey(name)
  return k and k:match(" (%S+)$") or nil
end

-- Demo -----------------------------------------------------------------------------------------------------------

Rules.DEMO_SELF = "Demo-0000" -- the viewer's own character in the demo (Journey opens on it)

-- The made-up guild for /annals demo, in the real G shape (AnnalsStore) and rec.d's "to:after:width;" form, laid out
-- on the plan's time grid before now so every Race and Health row kind shows at max level 60. Pure: a new table tree
-- each call, nothing random, never the roster. Every first level is below 10, so no first-seen window shows.
function Rules.DemoGuild(now)
  now = floor(now)
  local H = 3600
  local slot = { [10] = now - 20 * DAY, [20] = now - 16 * DAY, [30] = now - 12 * DAY, [40] = now - 8 * DAY,
    [50] = now - 4 * DAY, [60] = now - DAY }
  -- The first to each milestone: (after, by] ends on the slot; wide at 10, exact at 50, one minute at 60.
  local win = { [10] = slot[10] - 2 * DAY, [20] = slot[20] - 2 * H, [30] = slot[30] - 2 * H, [50] = slot[50],
    [60] = slot[60] - 60 }
  local ranks = { [0] = "Grand Executor", "Executor", "Deathstalker", "Deathguard", "Recruit" }
  -- name, class, level, days since online (true: online); w: first to reach w. Days: j, ret, ga (former).
  local rows = {
    { "Mirela Coldwake", "MAGE", 60, true, w = 60, r = 0, ra = "Undead",
      ea = { { "sl" }, { "dt", 12 }, { "fm", 3 }, { "f60", 1 } } },
    { "Darrow Ashgrave", "WARRIOR", 52, 1, w = 50, r = 1, ea = { { "sl" } } },
    { "Vesna Graves", "HUNTER", 27, 1, w = 10, r = 2, ea = { { "sl" } } },
    { "Corvin Blackmoor", "ROGUE", 33, 5, w = 20, r = 2, fr = 4, rk = { { 3, 18 } }, ea = { { "sl" }, { "ns", 6 } } },
    { "Ilsa Mournwood", "PRIEST", 36, 1, w = 30, r = 1, fr = 3, rk = { { 2, 14, 1 } }, ea = { { "sl" } } },
    { "Thane Holloway", "WARLOCK", 45, true, ea = { { "dt", 12 }, { "ns", 2 } } },
    { "Rhea Thornfield", "SHAMAN", 44, 1, ea = { { "ns", 11 }, { "rm", 5 }, { "dm", 3 } } },
    { "Edric Vale", "DRUID", 43, 5, ea = { { "ns", 11 }, { "rm", 5 }, { "dm", 3 } } },
    { "Lysa Dunmore", "WARRIOR", 42, 1 },
    { "Garrik Stonehand", "HUNTER", 41, 5 },
    { "Nessa Grimward", "PRIEST", 40, 1 },
    { "Osric Fenn", "ROGUE", 40, 5, ea = { { "ns", 15 }, { "rm", 5 }, { "dm", 3 } } },
    { "Tamsin Rook", "MAGE", 38, 10 },
    { "Bram Hollis", "SHAMAN", 31, 1, ea = { { "ns", 2 } } },
    { "Wren Ashby", "WARLOCK", 26, 10, ea = { { "ns", 15 } } },
    { "Kael Morrow", "DRUID", 21, 5 },
    { "Sorrel Dane", "HUNTER", 18, 10 },
    { "Ivo Crane", "WARRIOR", 14, 1, dni = "Pulls before the tank is ready, every single time" },
    { "Maren Lusk", "PRIEST", 12, 5 },
    { "Fenwick Grey", "ROGUE", 10, 10 },
    { "Corra Wick", "WARRIOR", 16, 1, j = 363, js = "log" },
    { "Jory Blight", "HUNTER", 24, true, ret = 2 },
    { "Hester Pike", "MAGE", 9, 20 },
    { "Ulric Barrow", "WARLOCK", 7, 45 },
    { "Agna Thistle", "SHAMAN", 5, true, j = 2, js = "log", r = 4, iv = "Ilsa Mournwood" },
    { "Pell Varrin", "DRUID", 3, 1, j = 3, js = "seen", r = 4 },
    { "Silas Marrow", "ROGUE", 34, ga = 6, gh = "left", j = 70, nt = "Alt of a friend", no = "Owes the bank ten bars" },
    { "Edda Kell", "MAGE", 22, ga = 9, gh = "removed", gb = "Darrow Ashgrave" },
    { "Rowan Tallow", "PRIEST", 15, ga = 3, gh = "left" },
    { "Bastian Crowe", "WARLOCK", 8, ga = 25, gh = "unknown" },
    -- The viewer: two matched promotions (Recruit -> Deathguard -> Deathstalker), an inviter and a race.
    { "Aveline Hollow", "PRIEST", 31, true, j = 26, js = "log", r = 2, self = true, fr = 5, ra = "Undead",
      iv = "Darrow Ashgrave", rk = { { 4, 20, 1 }, { 3, 9, 2 } },
      ea = { { "sl" }, { "fh" }, { "dt", 9 }, { "rl", 4 }, { "dm", 3 }, { "ns", 2 }, { "ma", 1 },
        { "g1", 7 }, { "ec", 5 } },
      mb = 19, sn = "sl;fh;rl;dm;ma;g1;ec;", ac = "cp=7;" }, -- the new rows (runs A, B) are seen, so the lg-5 dots stay
                                                             -- on ns and dt; st stays unearned (d1191)
  }
  local base, last = now - 30 * DAY, now - 5 * 60
  -- G.ranks / G.actors as the Store keeps them (append-only name lists, plan D3); rk ids index them.
  local G = { chars = {}, former = {}, dni = {}, ranks = {}, actors = { "Mirela Coldwake", "Darrow Ashgrave" },
    base = base, last = last, lastPartial = false }
  -- Achievements (D13), as Rules.EarnEntry strings; milestone 40 was too close to call, so nobody holds it.
  G.rs = "r10;r20;r30;r40;r50;r60;c10HUNTER;c20ROGUE;c30PRIEST;c50WARRIOR;c60MAGE;f60Undead;"
  for r = 0, #ranks do G.ranks[r + 1] = ranks[r] end
  local k, count = {}, 0
  for i, row in ipairs(rows) do
    local guid = row.self and Rules.DEMO_SELF or string.format("Demo-%04d", i)
    local l = row[3]
    local rec = { n = row[1], c = row[2], l = l, fl = l < 10 and l or 1 + i % 9, r = row.r or 3, nt = row.nt,
      no = row.no, js = row.js, gh = row.gh, gb = row.gb, fr = row.fr, ra = row.ra, iv = row.iv, sn = row.sn,
      ac = row.ac }
    -- rk: { rank id, days ago, actor id or nil }: a promotion seen in a 3-hour window, its log time 1 hour in.
    if row.rk then
      local rk = ""
      for _, e in ipairs(row.rk) do
        local after = now - e[2] * DAY - 2 * H
        rk = rk .. "+" .. e[1] .. ":" .. after .. ":" .. 3 * H .. (e[3] and (":" .. H .. ":" .. e[3]) or "") .. ";"
      end
      rec.rk = rk
    end
    rec.rn = ranks[rec.r]
    if row.j then rec.j = now - row.j * DAY end
    if row.ret then rec.ret = now - row.ret * DAY end
    rec.fs = rec.j and rec.j > base and rec.j or base
    local d, by = "", rec.fs
    for M = 10, l, 10 do
      local after
      if row.w == M then
        after, by = win[M], slot[M]
      else
        k[M] = (k[M] or -1) + 1
        if M == 40 then
          after, by = slot[40] + k[M] * 600, slot[40] + 6 * H
        else
          after = slot[M] + H + k[M] * 600
          by = after + H
        end
      end
      d = d .. M .. ":" .. after .. ":" .. (by - after) .. ";"
    end
    if l > 10 and l % 10 ~= 0 then d = d .. l .. ":" .. (by + 12 * H) .. ":" .. H .. ";" end
    if d ~= "" then rec.d = d end
    -- ea: { id, days ago } (no days: dated the join), plus the race firsts at the slot; sorted oldest first.
    if row.ea then
      local list = {}
      for _, e in ipairs(row.ea) do list[#list + 1] = { e[1], e[2] and now - e[2] * DAY or rec.fs } end
      if row.w then
        list[#list + 1] = { "r" .. row.w, slot[row.w] }
        list[#list + 1] = { "c" .. row.w, slot[row.w] }
      end
      for n, e in ipairs(list) do e[3] = n end
      table.sort(list, function(a, b)
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
      end)
      local ea = ""
      for _, e in ipairs(list) do ea = ea .. Rules.EarnEntry(e[1], e[2], Rules.REALM_OFFSET_FALLBACK) end
      rec.ea, rec.mb = ea, row.mb
    end
    if row.ga then
      rec.ga = now - row.ga * DAY
      rec.ls = rec.ga - DAY
      rec.lo = rec.ls
      G.former[guid] = rec
    else
      rec.ls = last
      if row[4] == true then rec.on, rec.lo = true, last else rec.lo = now - row[4] * DAY end
      G.chars[guid] = rec
      count = count + 1
    end
    if row.dni then G.dni[guid] = { g = guid, n = row[1], why = row.dni, at = now - 6 * DAY } end
  end
  G.lastCount, G.lastTotal = count, count
  G.dni["n:" .. Rules.NameKey("Grubb Haskell")] = { n = "Grubb Haskell", why = "Took the raid's loot and left",
    at = now - 15 * DAY }
  return G
end
