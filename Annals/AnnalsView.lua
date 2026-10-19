-- Annals AnnalsView: the rows of the pages (Journey, Race, Level log, Achievements, Health) and the status line,
-- built from the saved data.
-- Pure Lua 5.1, no client calls and no frames: AnnalsUI lays these rows out. A row is
--   { kind = "header"|"char"|"note"|"former"|"dni"|"alert", text, right, class, guid, id, action }.
-- Leaders char rows also carry level (a number). A Race tie row carries names = { { name, class, guid, former } },
-- former true for a former member, else nil (the tab appends View.T_LEFT).
-- Achievements rows (plan D12): { kind = "head", text, right, points (a number), pct, next, track, cur },
-- { kind = "lately", text, right, class, guid }, { kind = "feat", text, desc, status, points, tag,
-- state = "done"|"open"|"secret", vis, key, id, def, leaf, t, details = { counts, sure, alsoHead, also, alsoCount } },
-- also = { { name, class, guid, day, former }, ... } on vis guild rows only (former true or nil; the tab adds T_LEFT).
-- On Journey a feat row is { kind = "feat", text, right, when }; show.self (the viewer's guid) marks the own
-- Journey, and every other Journey shows only vis-guild feats and points (d306).
-- Only "Level N" headers on the Race page carry the words "Level <number>".
-- JourneyRows, RaceRows, LevelLogRows and HealthRows take an optional last argument `show`:
--   show.date(fmt, t)     the client's local-time formatter (Host.Date); "*t" gives a table. Without it, or when it
--                         gives no table, dates and clock times are UTC.
--   show.officerNotes     false hides former members' officer notes (the host's CanViewOfficerNote() at draw time).
-- Every name, note, rank name, log actor and reason in a row text has `|` doubled (`||`), so the client draws it
-- as a plain character and never as an escape sequence (security s1).
local _, ns = ...
local Rules, Store, Feats = ns.AnnalsRules, ns.AnnalsStore, ns.AnnalsFeats
local View = {}
ns.AnnalsView = View

local DAY = 86400
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Texts
View.T_JOURNEY, View.T_RACE, View.T_LEVELLOG, View.T_HEALTH = "Journey", "Race", "Level log", "Health"
View.T_LEVEL = "Level %d"
View.T_FIRST = "First: %s"
View.T_NOBODY = "Nobody yet."
View.T_TIE = "Too close to call: %s"
View.T_MORE = " and %d more"
View.T_LEFT = " (left)"
View.T_LEADERS = "Leaders"
View.T_NEW = "New this week"
View.T_ANNIV = "Anniversaries"
View.T_FORMER = "Former"
View.T_DNI = "Do not invite"
View.T_NONE = "None."
View.T_LOCAL = "This list is local: it stays on this computer and is never sent to anyone."
View.T_ALERT = "Do not invite: %s is in the guild (%s)"
View.T_BEFORE = "before the annals"
View.T_NO_GUILD = "No guild data yet. Annals reads the roster a few seconds after login."
View.T_EMPTY = "Nothing recorded for you yet. Annals reads the roster a few seconds after login."
View.T_RETURNING = "returning, back %s"
View.T_HOW = { left = "left", removed = "removed", unknown = "gone, no log entry" }
View.T_ACHIEVEMENTS = "Achievements"
View.T_LATELY = "Lately in the Company"
View.T_YOURS = "Yours"
View.T_HONEST = "Each member's Annals keeps its own record: who was online at a read, how close two dings were, and "
  .. "when someone was first seen can differ between members."
View.T_TAGS = { guild = "Seen by the guild", you = "Only you, until sharing", later = "Comes with sharing" }
View.T_EARNED = "Earned %s"
View.T_NOT_YET = "Not yet"
View.T_SECRET = "A secret"
View.T_SECRET_DESC = "Keep playing to find it."
View.T_SECRET_IN = "A secret in "
View.T_OPEN_PARAM = { r = "First to a milestone", c = "First of your class to a milestone",
  f = "First of your race to the max level" }
-- A card's details (plan D8, Copy, q508): What counts, How sure once earned (%day from the earned day, d510)
-- and How sure while not yet; then "Also in the guild" (D12, vis guild only).
View.T_ALSO, View.T_ALSO_OPEN, View.T_NOBODY_ELSE = "Also in the guild", "In the guild", "Nobody else yet."
do
  local slack = math.floor(Rules.FEAT_LOG_SLACK / DAY)
  local mins = math.floor(Rules.DING_TOGETHER / 60)
  local checksNot = "Annals doesn't check this yet."
  local function oldHand(n)
    return { counts = n .. " days in the Company. Time away doesn't count, and a join from the guild log counts from "
        .. slack .. " days after it.",
      sure = "Dated %day by your days in the Company as your Annals counts them. Days before it first saw you count "
        .. "only through the guild log.",
      open = "Your Annals counts from its first read of you, or " .. slack
        .. " days after your join in the guild log." }
  end
  local firstSure = "Your Annals ranked every ding it saw, and this one was surely first, by %day."
  local firstOpen = "Your Annals settles each level once, after a full roster read."
  local sharing = "This comes with sharing, in a later Annals."
  local atRead = "Your Annals saw it at a roster read on %day."
  local onlineSure = atRead .. " Another member's Annals reads at other moments, so theirs can differ."
  local onlineOpen = "Your Annals counts who's online at each read on your own client."
  local zoneOpen = "The roster has to show the zone. Inside some instances it shows none."
  View.T_DETAILS = {
    sl = { counts = "In the Company. Dated by your join in the guild log, or by the first roster read that listed you.",
      sure = "Dated %day, from the guild log or your Annals' first read of you.",
      open = "You get it at the first read that lists you, or when your Annals reads your join in the guild log." },
    o1 = oldHand(30), o2 = oldHand(90), o3 = oldHand(365),
    rc = { counts = "Someone you invited reaches level " .. Rules.RECRUIT_LEVEL .. " in the Company. The guild log has "
        .. "to name you as the inviter.",
      sure = "Your Annals saw your recruit pass level " .. Rules.RECRUIT_LEVEL .. " on %day. It only "
        .. "knows invites it read in the guild log.",
      open = "Your Annals checks at each roster read, against the invites in the guild log." },
    ns = { counts = "Online with a guildmate at a roster read between " .. Rules.NIGHT_HOUR .. ":00 and "
        .. (Rules.NIGHT_HOUR + 1) .. ":00 realm time. Everyone online at that read gets it.",
      sure = "Your Annals saw it at a roster read on %day. A guildmate whose game was off then may not "
        .. "have it.",
      open = "Your Annals checks at each roster read on your own client, about once a minute while you play." },
    fm = { counts = "Online at a roster read with at least " .. Rules.MUSTER .. " guildmates. Everyone online at that "
        .. "read gets it.",
      sure = "Your Annals saw it at a roster read on %day. Another member's Annals reads at other "
        .. "moments, so theirs can differ.",
      open = "Your Annals counts who's online at each read on your own client." },
    r = { counts = "First in the Company to the level. A level gained before joining doesn't count, and too close to "
        .. "call earns nobody.", sure = firstSure, open = firstOpen },
    c = { counts = "First of your class in the Company to the level. Too close to call earns nobody.", sure = firstSure,
      open = firstOpen },
    dt = { counts = "Reach a level within " .. mins .. " minutes of a guildmate reaching the same one. You both "
        .. "get it.",
      sure = "Your Annals saw both dings surely within " .. mins .. " minutes, by %day.",
      open = "A ding seen while you were away has a wide window and can't prove " .. mins .. " minutes." },
    fg = { counts = "Reach level " .. Rules.FRESH_LEVEL .. " within a day of a join the guild log shows.",
      sure = "Your Annals saw level " .. Rules.FRESH_LEVEL .. " by %day, inside a day of your join.",
      open = "Only a join read from the guild log counts. A member first seen at a roster read can't get it." },
    cr = { counts = "Clear a dungeon in a group of five guildmates.", sure = checksNot, open = checksNot },
    mv = { counts = "An officer gives it.", sure = sharing, open = sharing },
    fh = { counts = "In the Company by 11 Nov 2026, realm time.",
      sure = "Your Annals saw you in the Company on %day, from the guild log or a roster read.",
      open = "Only a join the guild log dates, or a roster read that listed you, by 11 Nov counts." },
    rt = { counts = "Three people you invited reach level " .. Rules.RECRUIT_LEVEL .. " in the Company. The guild log "
        .. "has to name you as the inviter.",
      sure = "Your Annals saw your third recruit pass level " .. Rules.RECRUIT_LEVEL .. " on %day.",
      open = "It counts invites it read in the guild log." },
    pr = { counts = "An officer promotes you for the first time.",
      sure = "Your Annals matched a promotion in the guild log to your rank change on %day.",
      open = "A rank change counts once the guild log shows who promoted you." },
    o6 = oldHand(180),
    bn = { counts = "First seen in the Company at level 1.",
      sure = "Your Annals first listed you at level 1 on %day.",
      open = "Only the level at your first roster read counts." },
    rg = { counts = "Leave the Company and come back.",
      sure = "Your Annals saw you back on %day.",
      open = "It counts a return after your Annals saw you leave. If your Annals has already dropped your old "
        .. "record, it can't tell you came back." },
    rl = { counts = "Online at a roster read with at least " .. Rules.ROLL_CALL .. " guildmates. Everyone online at "
        .. "that read gets it.",
      sure = onlineSure, open = onlineOpen },
    gm = { counts = "Online at a roster read with at least " .. Rules.GRAND_MUSTER .. " guildmates. Everyone online "
        .. "at that read gets it.",
      sure = onlineSure, open = onlineOpen },
    fy = { counts = "Online at a roster read with a guildmate who shares your surname.",
      sure = "Your Annals saw you both online on %day.",
      open = "Only names with a surname count." },
    wd = { counts = "Show " .. Rules.WELL_DECORATED .. " achievement points on the guild roster.",
      sure = "Your Annals read your points on the roster on %day.",
      open = "If the roster shows no points, this can't be earned." },
    az = { counts = "Show as away on the guild roster for 3 hours in a row.",
      sure = "Your Annals saw you away at every read for 3 hours, ending %day.",
      open = "A gap in your Annals' reads (a /reload, or a boss fight, when reads pause) starts the count again." },
    dm = { counts = "In the same dungeon as 4 guildmates at one roster read.",
      sure = atRead,
      open = zoneOpen },
    rm = { counts = "In the same raid as 9 guildmates at one roster read.",
      sure = atRead,
      open = zoneOpen },
    bm = { counts = "In the same battleground as 4 guildmates at one roster read.",
      sure = atRead,
      open = zoneOpen },
    ag = { counts = "In Stormwind, Ironforge or Darnassus with 9 guildmates at one roster read.",
      sure = atRead,
      open = zoneOpen },
    ma = { counts = "In Western Plaguelands with 9 guildmates at one roster read.",
      sure = atRead,
      open = zoneOpen },
    d5 = { counts = "Reach a level within " .. mins .. " minutes of a guildmate, with " .. Rules.DING_FRIENDS
        .. " different guildmates over time.",
      sure = "Your Annals saw your fifth surely within " .. mins .. " minutes on %day.",
      open = "A ding seen while you were away can't prove " .. mins .. " minutes." },
    f = { counts = "First of your race in the Company to the max level. A level gained before joining doesn't count, "
        .. "and too close to call earns nobody.", sure = firstSure, open = firstOpen },
    fu = { counts = "Reach the max level while you're in the Company.",
      sure = "Your Annals saw you reach it on %day.",
      open = "A level gained before joining, or while away, doesn't count." },
    eh = { counts = "Reach the max level within " .. Rules.EARLY_DAYS .. " days of a join the guild log shows, after "
        .. "joining below level " .. Rules.EARLY_JOIN_LEVEL .. ".",
      sure = "Your Annals saw it on %day, inside " .. Rules.EARLY_DAYS .. " days of your join.",
      open = "Only a join read from the guild log counts." },
  }
end

-- Small helpers ----------------------------------------------------------------------------------------------------

-- The show options of the current page-rows call (set at their start; nil means UTC, notes shown).
local show = {}

-- A text from saved or client data, with `|` doubled.
local function esc(v)
  if v == nil then return nil end
  return (string.gsub(tostring(v), "|", "||"))
end

-- { month, day, hour, min, year } of t in the client's local time when show.date gives it, else UTC.
local function civil(t)
  if type(show.date) == "function" then
    local good, d = pcall(show.date, "*t", math.floor(t))
    if good and type(d) == "table" and type(d.month) == "number" and MONTHS[d.month] and type(d.day) == "number"
      and type(d.hour) == "number" and type(d.min) == "number" and type(d.year) == "number" then
      return d.month, d.day, d.hour, d.min, d.year
    end
  end
  local y, m, dd = Rules.Civil(t)
  local s = math.floor(t) % DAY
  return m, dd, math.floor(s / 3600), math.floor(s % 3600 / 60), y
end

local function day(t)
  local m, d = civil(t)
  return d .. " " .. MONTHS[m]
end

-- "4 Nov 2026"
local function fullDay(t)
  local m, d, _, _, y = civil(t)
  return d .. " " .. MONTHS[m] .. " " .. y
end

local function clock(t)
  local _, _, h, mi = civil(t)
  return string.format("%02d:%02d", h, mi)
end

-- "6 Oct 21:14"
local function stamp(t)
  return day(t) .. " " .. clock(t)
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

local function span(sec)
  if sec < 3600 then return plural(math.max(1, math.ceil(sec / 60)), "min") end
  if sec < DAY then return plural(math.ceil(sec / 3600), "hour") end
  return plural(math.ceil(sec / DAY), "day")
end

-- (after, by]: exact, open below, or a read window.
local function windowText(w)
  if w.after == nil then return "first seen " .. day(w.by) end
  if w.after == w.by then return "at " .. stamp(w.by) end
  return "by " .. stamp(w.by) .. ", within " .. span(w.by - w.after)
end

local function byName(a, b) return (a.n or "") < (b.n or "") end

-- { { guid, rec }, ... } sorted by name.
local function sortedRecs(list)
  local out = {}
  for guid, rec in pairs(list or {}) do out[#out + 1] = { guid = guid, rec = rec } end
  table.sort(out, function(a, b)
    if a.rec.n ~= b.rec.n then return byName(a.rec, b.rec) end
    return a.guid < b.guid
  end)
  return out
end

-- The lowest level a rise reached: from + 1, or `to` when `from` is unknown.
local function firstLevel(r)
  return type(r.from) == "number" and r.from + 1 or r.to
end

-- The date the annals begin, or "the first full read" before it is known.
local function beginText(G)
  return type(G.base) == "number" and fullDay(G.base) or "the first full read"
end

local function charRow(guid, rec, right)
  return { kind = "char", text = esc(rec.n) or "?", right = right, class = rec.c, guid = guid }
end

-- Pages ------------------------------------------------------------------------------------------------------------

-- Journey, Race, Level log, Achievements, and Health for officers (plan D7, D12).
function View.Pages(isOfficer)
  local pages = { { key = "journey", label = View.T_JOURNEY }, { key = "race", label = View.T_RACE },
    { key = "levellog", label = View.T_LEVELLOG }, { key = "achievements", label = View.T_ACHIEVEMENTS } }
  if isOfficer == true then pages[#pages + 1] = { key = "health", label = View.T_HEALTH } end
  return pages
end

-- Precision, folds, Journey ----------------------------------------------------------------------------------------

-- The read window (after, by] of a rise as text (plan D8); local time through show.date (R3).
local function precision(after, by)
  if after == nil or after == by then return "exact" end
  local w = by - after
  if w <= Rules.AWAY_GAP then return "within " .. math.max(1, math.ceil(w / 60)) .. " min" end
  if day(after) == day(by) then return "while you were away, " .. clock(after) .. " to " .. clock(by) end
  return "while you were away, " .. stamp(after) .. " to " .. stamp(by)
end

function View.Precision(after, by, opts)
  show = type(opts) == "table" and opts or {}
  return precision(after, by)
end

-- "Level 13", or "Level 11 to 12" for a rise over more than one level.
local function levelText(r)
  if type(r.from) == "number" and r.to - r.from > 1 then return "Level " .. (r.from + 1) .. " to " .. r.to end
  return "Level " .. r.to
end

-- Items oldest first: { rise = r } each, except a run of more than FOLD_MIN consecutive rises with
-- by < now - FOLD_AGE, which is one { key = first.by, rises = { ... }, by = last.by } (plan D5, d305). Data only.
function View.FoldRises(rises, now)
  local items, run = {}, {}
  local function flush()
    if #run > Rules.FOLD_MIN then
      items[#items + 1] = { key = run[1].by, rises = run, by = run[#run].by }
    else
      for _, r in ipairs(run) do items[#items + 1] = { rise = r, by = r.by } end
    end
    run = {}
  end
  for _, r in ipairs(rises or {}) do
    if r.by < now - Rules.FOLD_AGE then
      run[#run + 1] = r
    else
      flush()
      items[#items + 1] = { rise = r, by = r.by }
    end
  end
  flush()
  return items
end

-- "Levels 2 to 31, 6 to 7 Oct"; both dates in full when the months differ.
local function foldLabel(rises)
  local first, last = rises[1], rises[#rises]
  local a = firstLevel(first)
  local m1, d1 = civil(first.by)
  local m2, d2 = civil(last.by)
  local when
  if day(first.by) == day(last.by) then when = day(last.by)
  elseif m1 == m2 then when = d1 .. " to " .. d2 .. " " .. MONTHS[m2]
  else when = day(first.by) .. " to " .. day(last.by) end
  return "Levels " .. a .. " to " .. last.to .. ", " .. when
end

local function riseEvent(r, guid)
  return { kind = "event", text = levelText(r), when = stamp(r.by),
    right = precision(r.after, r.by), guid = guid, tag = "level" }
end

-- The join, in the header (with its date) and in the timeline (plan R8).
local function joinText(rec, withDate)
  if type(rec.j) ~= "number" then return "In the Company since " .. View.T_BEFORE end
  local at = withDate and (" " .. fullDay(rec.j) .. " at " .. clock(rec.j)) or ""
  if rec.js == "log" then
    return "Joined" .. (withDate and at or " the Company")
      .. (rec.iv and (", invited by " .. esc(rec.iv)) or "") .. " (guild log)"
  end
  return "First seen" .. (withDate and at or " in the Company")
end

function View.JourneyRows(G, guid, now, opts)
  if guid == nil or not G then return nil end
  local rec = G.chars and G.chars[guid]
  local former = false
  if not rec then rec, former = G.former and G.former[guid], true end
  if not rec then return nil end
  show = type(opts) == "table" and opts or {}
  local opened = show.opened or {}
  local title = { kind = "title", text = esc(rec.n) or "?", class = rec.c, guid = guid }
  local rows = { title }
  local who = "Level " .. tostring(rec.l or "?")
  if type(rec.ra) == "string" and rec.ra ~= "" then who = who .. " " .. esc(rec.ra) end
  if rec.c then who = who .. " " .. (Rules.CLASS_NAMES[rec.c] or esc(rec.c)) end
  if rec.rn then who = who .. ", " .. esc(rec.rn) end
  if former then who = who .. View.T_LEFT end
  rows[#rows + 1] = { kind = "line", text = who, part = "who" }
  -- Someone else's Journey counts and lists vis-guild feats only (d306).
  local own = show.self ~= nil and show.self == guid
  local points = Feats.Points(rec, not own)
  title.title, title.points, title.count = Rules.Title(points).name, points, 0
  rows[#rows + 1] = { kind = "line", text = title.title .. ", " .. points .. " points", part = "title" }
  if type(rec.j) == "number" then
    local till = former and type(rec.ga) == "number" and rec.ga or now
    rows[#rows + 1] = { kind = "line", text = plural(Rules.DaysSince(rec.j, till), "day") .. " in the Company",
      part = "days" }
  end
  rows[#rows + 1] = { kind = "line", text = joinText(rec, true), part = "join" }

  -- Timeline items { t, row(s) }, newest first; ties keep the order they were added in. A feat is dated realm noon of
  -- its day, so it sorts at the end of that realm day: after the same day's events (f3518).
  local items = {}
  local function add(t, list, s) items[#items + 1] = { t = t, s = s or t, list = list, i = #items + 1 } end
  for _, it in ipairs(View.FoldRises(Store.Rises(rec), now)) do
    if it.rises then
      local list = { { kind = "fold", text = foldLabel(it.rises), key = it.key, guid = guid } }
      if opened[it.key] then
        for k = #it.rises, 1, -1 do list[#list + 1] = riseEvent(it.rises[k], guid) end
      end
      add(it.by, list)
    else
      add(it.by, { riseEvent(it.rise, guid) })
    end
  end
  for _, c in ipairs(Store.RankChanges(G, rec)) do
    local t = c.by
    if c.actor and type(c.at) == "number" then t = math.min(math.max(c.at, c.after or c.at), c.by) end
    local text = (c.up and "Promoted to " or "Demoted to ") .. (esc(c.to) or "?")
    if c.actor then text = text .. " by " .. esc(c.actor) end
    add(t, { { kind = "event", text = text .. ", " .. day(t), when = day(t), tag = "rank" } })
  end
  if type(rec.j) == "number" then
    add(rec.j, { { kind = "event", text = joinText(rec, false), when = stamp(rec.j), tag = "joined" } })
  end
  if type(rec.ret) == "number" then
    add(rec.ret, { { kind = "event", text = "Rejoined the Company", when = stamp(rec.ret), tag = "joined" } })
  end
  -- ea is oldest first and a feat carries only its day, so feats are added newest first: the same day's keep that order.
  local earned = Feats.Earned(rec)
  for k = #earned, 1, -1 do
    local e = earned[k]
    if own or e.def.vis == "guild" then
      title.count = title.count + 1
      add(e.t, { { kind = "feat", text = esc(Feats.Name(e.id, rec)), right = e.def.points .. " points",
        when = day(e.t), tag = "feat" } }, e.t + Rules.HALF_DAY)
    end
  end
  table.sort(items, function(a, b)
    if a.s ~= b.s then return a.s > b.s end
    return a.i < b.i
  end)
  local month
  for _, it in ipairs(items) do
    local m, _, _, _, y = civil(it.t)
    local label = MONTHS[m] .. " " .. y
    if label ~= month then
      month = label
      rows[#rows + 1] = { kind = "month", text = label }
    end
    for _, r in ipairs(it.list) do rows[#rows + 1] = r end
  end
  rows[#rows + 1] = { kind = "end",
    text = "The annals begin on " .. beginText(G) }
  return rows
end

-- Level log --------------------------------------------------------------------------------------------------------

-- Every rise of current and former recs, { guid, rec, rise } each, newest first (plan R12).
function View.AllRises(G)
  local out = {}
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      for _, r in ipairs(Store.Rises(rec)) do out[#out + 1] = { guid = guid, rec = rec, rise = r } end
    end
  end
  table.sort(out, function(a, b)
    if a.rise.by ~= b.rise.by then return a.rise.by > b.rise.by end
    if a.guid ~= b.guid then return a.guid < b.guid end
    return a.rise.to > b.rise.to
  end)
  return out
end

-- Bad or empty level text is an open end (plan D8).
function View.LevelFilter(nameText, class, fromText, toText, milestonesOnly, maxLevel)
  local name = type(nameText) == "string" and string.lower((string.gsub(nameText, "^%s+", ""):gsub("%s+$", ""))) or ""
  return {
    name = name ~= "" and name or nil,
    class = (class ~= nil and class ~= "ALL") and class or nil,
    lo = tonumber(fromText) or -math.huge,
    hi = tonumber(toText) or math.huge,
    milestones = milestonesOnly and Rules.Milestones(maxLevel or Rules.MAX_LEVEL_FALLBACK) or nil,
  }
end

function View.MatchRise(rise, rec, filter)
  if not filter then return true end
  if filter.name and not string.find(string.lower(rec.n or ""), filter.name, 1, true) then return false end
  if filter.class and rec.c ~= filter.class then return false end
  if firstLevel(rise) > filter.hi or rise.to < filter.lo then return false end
  if filter.milestones then
    if type(rise.from) ~= "number" or #Rules.Crosses(rise.from, rise.to, filter.milestones) == 0 then return false end
  end
  return true
end

-- At most LOG_ROWS ding rows from opts.offset in the filtered list, keeping the order of opts.rises (plan D8, R2).
function View.LevelLogRows(G, now, filter, opts)
  show = type(opts) == "table" and opts or {}
  local all = show.rises or View.AllRises(G)
  local hits = {}
  for _, x in ipairs(all) do if View.MatchRise(x.rise, x.rec, filter) then hits[#hits + 1] = x end end
  local offset = math.max(0, math.floor(tonumber(show.offset) or 0))
  local last = math.min(#hits, offset + Rules.LOG_ROWS)
  local rows = {}
  if #hits == 0 then
    rows[1] = { kind = "note", text = "No level-ups match." }
  else
    rows[1] = { kind = "note", text = "Showing " .. math.min(offset + 1, #hits) .. " to " .. last .. " of " .. #hits }
  end
  local header
  for i = offset + 1, last do
    local x = hits[i]
    local d = fullDay(x.rise.by)
    if d ~= header then
      header = d
      rows[#rows + 1] = { kind = "header", text = d }
    end
    -- longRight: the clock, levels and an away window need the wider right column (review f2).
    local time, levels, how = clock(x.rise.by), levelText(x.rise), precision(x.rise.after, x.rise.by)
    rows[#rows + 1] = { kind = "char", text = esc(x.rec.n) or "?", class = x.rec.c, guid = x.guid, longRight = true,
      right = time .. ", " .. levels .. ", " .. how, time = time, levels = levels, how = how }
  end
  rows[#rows + 1] = { kind = "note", text = #all .. " level-ups recorded since " .. beginText(G) }
  return rows
end

-- Race -------------------------------------------------------------------------------------------------------------

local function classOk(rec, classFilter)
  return classFilter == nil or classFilter == "ALL" or rec.c == classFilter
end

-- One candidate per character for milestone M: the rise that crossed it, else the first-seen window (q194).
-- Feats.Candidate gives a new table, so the escaped name never reaches G.
local function candidate(guid, rec, M, former)
  local c = Feats.Candidate(guid, rec, M, former)
  if c then c.name = esc(c.name) or "?" end
  return c
end

local function shownName(c)
  return c.name .. (c.former and View.T_LEFT or "")
end

function View.RaceRows(G, now, maxLevel, classFilter, opts)
  show = type(opts) == "table" and opts or {}
  local rows = {}
  for _, M in ipairs(Rules.Milestones(maxLevel)) do
    rows[#rows + 1] = { kind = "header", text = string.format(View.T_LEVEL, M) }
    local cands = {}
    for _, list in ipairs({ { G.chars, false }, { G.former, true } }) do
      for guid, rec in pairs(list[1] or {}) do
        if classOk(rec, classFilter) then
          local c = candidate(guid, rec, M, list[2])
          if c then cands[#cands + 1] = c end
        end
      end
    end
    local sorted, sure = Rules.Rank(cands)
    local lead = sorted[1]
    if not lead then
      rows[#rows + 1] = { kind = "note", text = View.T_NOBODY }
    elseif sure then
      rows[#rows + 1] = { kind = "char", text = string.format(View.T_FIRST, shownName(lead)), right = windowText(lead),
        class = lead.class, guid = lead.guid }
    else
      local tied = { lead }
      for i = 2, #sorted do
        if not Rules.Surely(lead, sorted[i]) then tied[#tied + 1] = sorted[i] end
      end
      local names, all = {}, {}
      for i = 1, math.min(#tied, Rules.TIE_NAMES) do names[i] = shownName(tied[i]) end
      for i, c in ipairs(tied) do
        all[i] = { name = c.name, class = c.class, guid = c.guid, former = c.former or nil }
      end
      local text = string.format(View.T_TIE, table.concat(names, ", "))
      if #tied > Rules.TIE_NAMES then text = text .. string.format(View.T_MORE, #tied - Rules.TIE_NAMES) end
      rows[#rows + 1] = { kind = "note", text = text, right = windowText(lead), names = all, count = #tied }
    end
  end
  return rows
end

-- "ALL", then every class present among current and former characters, sorted.
function View.ClassFilters(G)
  local seen, out = {}, {}
  for _, list in ipairs({ G.chars, G.former }) do
    for _, rec in pairs(list or {}) do
      if type(rec.c) == "string" and not seen[rec.c] then seen[rec.c] = true out[#out + 1] = rec.c end
    end
  end
  table.sort(out)
  table.insert(out, 1, "ALL")
  return out
end

-- The highest levels among current characters, highest first.
function View.LeaderRows(G, limit)
  limit = limit or Rules.LEADERS
  local list = sortedRecs(G.chars)
  table.sort(list, function(a, b)
    local la, lb = a.rec.l or 0, b.rec.l or 0
    if la ~= lb then return la > lb end
    if a.rec.n ~= b.rec.n then return byName(a.rec, b.rec) end
    return a.guid < b.guid
  end)
  local rows = { { kind = "header", text = View.T_LEADERS } }
  for i = 1, math.min(limit, #list) do
    local x = list[i]
    local row = charRow(x.guid, x.rec, tostring(x.rec.l or "?"))
    row.level = tonumber(x.rec.l) or 0
    rows[#rows + 1] = row
  end
  return rows
end

-- Achievements -----------------------------------------------------------------------------------------------------

-- The newest FEED_ROWS vis-guild entries over current and former characters; ties by guid, then id (plan D12).
local function latelySection(G, rows)
  local all = {}
  for _, list in ipairs({ G.chars or {}, G.former or {} }) do
    for guid, rec in pairs(list) do
      for _, e in ipairs(Feats.Earned(rec)) do
        if e.def.vis == "guild" then all[#all + 1] = { guid = guid, rec = rec, e = e } end
      end
    end
  end
  table.sort(all, function(a, b)
    if a.e.t ~= b.e.t then return a.e.t > b.e.t end
    if a.guid ~= b.guid then return a.guid < b.guid end
    return a.e.id < b.e.id
  end)
  rows[#rows + 1] = { kind = "header", text = View.T_LATELY }
  for i = 1, math.min(#all, Rules.FEED_ROWS) do
    local x = all[i]
    rows[#rows + 1] = { kind = "lately", text = (esc(x.rec.n) or "?") .. " earned " .. esc(Feats.Name(x.e.id, x.rec)),
      right = day(x.e.t), class = x.rec.c, guid = x.guid }
  end
  if #all == 0 then rows[#rows + 1] = { kind = "note", text = View.T_NONE } end
  rows[#rows + 1] = { kind = "note", text = View.T_HONEST }
end

local function featRow(d, text, state, status)
  return { kind = "feat", text = esc(text), desc = d.desc, status = status, points = tostring(d.points),
    tag = View.T_TAGS[d.vis], state = state, vis = d.vis }
end

-- Every earn of a vis-guild def over current and former recs, { guid, rec, former, e } each (D12).
local function guildEarns(G)
  local all = {}
  for _, list in ipairs({ { G.chars or {}, false }, { G.former or {}, true } }) do
    for guid, rec in pairs(list[1]) do
      for _, e in ipairs(Feats.Earned(rec)) do
        if e.def.vis == "guild" then all[#all + 1] = { guid = guid, rec = rec, former = list[2], e = e } end
      end
    end
  end
  return all
end

-- Others holding that earned id (an open row: any id of def d), each once at their newest such earn, newest first,
-- then name; never the viewer. The names are escaped; the tab appends View.T_LEFT to a former one (D12).
local function alsoList(all, selfGuid, d, id)
  local best, list = {}, {}
  for _, x in ipairs(all) do
    if x.guid ~= selfGuid and (id and x.e.id == id or not id and x.e.def == d) then
      local b = best[x.guid]
      if not b then
        b = { guid = x.guid, rec = x.rec, former = x.former, t = x.e.t }
        best[x.guid] = b
        list[#list + 1] = b
      elseif x.e.t > b.t then
        b.t = x.e.t
      end
    end
  end
  table.sort(list, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    if a.rec.n ~= b.rec.n then return byName(a.rec, b.rec) end
    return a.guid < b.guid
  end)
  local out = {}
  for i, b in ipairs(list) do
    out[i] = { name = esc(b.rec.n) or "?", class = b.rec.c, guid = b.guid, day = day(b.t), former = b.former or nil }
  end
  return out
end

-- The card's key, id, def, leaf, t and details (plan D8, D12, Seams); e is the earn, nil for an open row.
local function addDetails(row, d, e, all, selfGuid)
  local id = e and e.id or d.id
  row.key, row.id, row.def, row.leaf, row.t = id, id, d.id, d.leaf, e and e.t or nil
  local texts = View.T_DETAILS[d.id]
  local sure = e and (string.gsub(texts.sure, "%%(%a+)", { day = day(e.t) })) or texts.open
  local details = { counts = texts.counts, sure = sure }
  if d.vis == "guild" then
    details.also = alsoList(all, selfGuid, d, e and e.id)
    details.alsoHead = e and View.T_ALSO or View.T_ALSO_OPEN
    details.alsoCount = #details.also
  end
  row.details = details
  return row
end

-- An unearned secret's name, riddle and "A secret in <hint>" (nil without a hint); once earned, its own name and desc
-- (D12, d517).
function View.SecretText(def, earned)
  if earned then return def.name, def.desc end
  return View.T_SECRET, def.riddle or View.T_SECRET_DESC, def.hint and (View.T_SECRET_IN .. def.hint) or nil
end

-- Whether def d shows under category: "ALL" or nil keeps every def; a leaf key its defs; a parent key its leaves'
-- defs (d504). A soon key matches none.
local function inCategory(d, category)
  return category == nil or category == "ALL" or d.leaf == category or Feats.ParentOf(d.leaf) == category
end

-- The reward track (d504, lg-1): one card per title, { name, at, state, toGo }; toGo only on the next card.
local function track(points)
  local cards, cur = {}, 1
  for i, t in ipairs(Rules.TITLES) do
    if points >= t.at then cur = i end
    cards[i] = { name = t.name, at = t.at }
  end
  for i, c in ipairs(cards) do
    if i < cur then
      c.state = "earned"
    elseif i == cur then
      c.state = "current"
    elseif i == cur + 1 then
      c.state, c.toGo = "next", c.at - points
    else
      c.state = "later"
    end
  end
  return cards, cur
end

-- The page for the viewer's character selfGuid: the head with its track, Lately with its note (only under "ALL" or
-- nil, d504), then Yours filtered by category (inCategory), in Feats.DEFS order (plan D3, D12, Seams).
function View.AchievementRows(G, selfGuid, now, category, opts)
  show = type(opts) == "table" and opts or {}
  local me = selfGuid and ((G.chars or {})[selfGuid] or (G.former or {})[selfGuid]) or {}
  local earned = Feats.Earned(me)
  local byDef, defsEarned = {}, 0
  for _, e in ipairs(earned) do
    if not byDef[e.def] then
      byDef[e.def] = {}
      defsEarned = defsEarned + 1
    end
    local list = byDef[e.def]
    list[#list + 1] = e
  end
  local points = Feats.Points(me)
  local title = Rules.Title(points)
  local cards, cur = track(points)
  local rows = { { kind = "head", text = title.name,
    right = points .. " points \194\183 " .. defsEarned .. " of " .. #Feats.DEFS .. " earned", points = points,
    pct = title.pct,
    next = title.nextName and (title.nextName .. " at " .. title.nextAt) or nil, track = cards, cur = cur } }
  if category == nil or category == "ALL" then latelySection(G, rows) end
  rows[#rows + 1] = { kind = "header", text = View.T_YOURS }
  local all = guildEarns(G)
  for _, d in ipairs(Feats.DEFS) do
    if inCategory(d, category) then
      local got = byDef[d]
      if got then
        for _, e in ipairs(got) do
          rows[#rows + 1] = addDetails(featRow(d, Feats.Name(e.id, me), "done",
            string.format(View.T_EARNED, day(e.t))), d, e, all, selfGuid)
        end
      elseif d.secret then
        -- An unearned secret carries only its riddle and hint: no progress and no details (D12, f3516).
        local name, riddle, hint = View.SecretText(d, false)
        local row = featRow(d, name, "secret", hint or View.T_NOT_YET)
        row.desc, row.tag, row.points = riddle, nil, nil -- f3565: no points until earned
        row.key, row.id, row.def, row.leaf = d.id, d.id, d.id, d.leaf
        rows[#rows + 1] = row
      else
        local status = d.progress and d.progress(G, me, now) or View.T_NOT_YET
        rows[#rows + 1] = addDetails(featRow(d, d.param and View.T_OPEN_PARAM[d.id] or d.name, "open", status), d, nil,
          all, selfGuid)
      end
    end
  end
  return rows
end

-- The category column (d504, lg-4): Feats.TREE as rows, a parent's leaves under it while open[parent] (d4: tab
-- memory). marks is View.NewMarks' shape; a leaf's dot is marks.leaves, a parent's marks.parents, never on "ALL".
function View.TreeRows(open, selected, marks)
  open = open or {}
  local leaves = marks and marks.leaves or {}
  local parents = marks and marks.parents or {}
  local rows = {}
  local function add(kind, item, depth, dot)
    rows[#rows + 1] = { kind = kind, key = item.key, text = item.text, depth = depth, selected = item.key == selected,
      dot = dot == true }
    return rows[#rows]
  end
  for _, item in ipairs(Feats.TREE) do
    if item.leaves then
      add("parent", item, 0, parents[item.key]).open = open[item.key] == true
      if open[item.key] then
        for _, leaf in ipairs(item.leaves) do
          if Feats.LeafLive(leaf.key) then add("leaf", leaf, 1, leaves[leaf.key]) else add("soon", leaf, 1, false) end
        end
      end
    elseif item.key == "ALL" or Feats.LeafLive(item.key) then
      add("leaf", item, 0, item.key ~= "ALL" and leaves[item.key])
    else
      add("soon", item, 0, false)
    end
  end
  return rows
end

-- New marks (plan D9, d505, d507). rec.sn = "<id>;" each: the earned ids the viewer has seen. An sn that is missing
-- or not a string reads as nil (the quiet start: nothing marked; Store.SeenStart writes it). An earned id is new when
-- sn does not hold it, bounded on both sides as Feats.Has. Its leaf and the leaf's parent are marked, never "ALL".
local function viewerRec(G, guid)
  return guid and G and ((G.chars or {})[guid] or (G.former or {})[guid]) or nil
end

function View.NewMarks(G, selfGuid)
  local m = { started = false, ids = {}, leaves = {}, parents = {}, any = false }
  local rec = viewerRec(G, selfGuid)
  local sn = rec and type(rec.sn) == "string" and rec.sn
  if not sn then return m end
  m.started = true
  for _, e in ipairs(Feats.Earned(rec)) do
    if not (";" .. sn):find(";" .. e.id .. ";", 1, true) then
      m.ids[e.id], m.any = true, true
      if e.def.leaf then
        m.leaves[e.def.leaf] = true
        local parent = Feats.ParentOf(e.def.leaf)
        if parent then m.parents[parent] = true end
      end
    end
  end
  return m
end

-- The viewer's earned ids in one leaf, oldest first ({} with no rec).
function View.LeafIds(G, selfGuid, leafKey)
  local out = {}
  local rec = viewerRec(G, selfGuid)
  if not rec then return out end
  for _, e in ipairs(Feats.Earned(rec)) do
    if e.def.leaf == leafKey then out[#out + 1] = e.id end
  end
  return out
end

-- Health -----------------------------------------------------------------------------------------------------------

local function returning(rec, now)
  return type(rec.ret) == "number" and now - rec.ret < Rules.RETURN_DAYS * DAY
end

local function healthRight(rec, now, days)
  local parts = { "level " .. tostring(rec.l or "?") }
  if rec.on then parts[#parts + 1] = "online"
  elseif days then parts[#parts + 1] = plural(days, "day") .. " ago" end
  if returning(rec, now) then parts[#parts + 1] = string.format(View.T_RETURNING, day(rec.ret)) end
  return table.concat(parts, ", ")
end

local function bandSections(G, now, rows)
  local byBand = {}
  for _, x in ipairs(sortedRecs(G.chars)) do
    local days = Rules.DaysSince(x.rec.lo, now)
    local key = Rules.Band(days, x.rec.on)
    byBand[key] = byBand[key] or {}
    table.insert(byBand[key], charRow(x.guid, x.rec, healthRight(x.rec, now, days)))
  end
  local order = {}
  for _, b in ipairs(Rules.BANDS) do order[#order + 1] = { key = b.key, label = b.label } end
  order[#order + 1] = { key = Rules.UNKNOWN_KEY, label = Rules.UNKNOWN_LABEL }
  for _, b in ipairs(order) do
    local list = byBand[b.key] or {}
    rows[#rows + 1] = { kind = "header", text = b.label .. " (" .. #list .. ")", section = "band", band = b.key,
      count = #list }
    for _, r in ipairs(list) do rows[#rows + 1] = r end
  end
end

local function newSection(G, now, rows)
  rows[#rows + 1] = { kind = "header", text = View.T_NEW, section = "new" }
  local n = 0
  for _, x in ipairs(sortedRecs(G.chars)) do
    local rec = x.rec
    local parts = {}
    if rec.j and rec.js and Rules.IsNew(rec.j, now) then
      parts[#parts + 1] = "joined " .. day(rec.j) .. " (" .. (rec.js == "log" and "guild log" or "first seen") .. ")"
    end
    if returning(rec, now) then parts[#parts + 1] = string.format(View.T_RETURNING, day(rec.ret)) end
    if #parts > 0 then
      rows[#rows + 1] = charRow(x.guid, rec, table.concat(parts, ", "))
      n = n + 1
    end
  end
  if n == 0 then rows[#rows + 1] = { kind = "note", text = View.T_NONE } end
end

local function annivSection(G, now, rows)
  rows[#rows + 1] = { kind = "header", text = View.T_ANNIV, section = "anniv" }
  local n = 0
  for _, x in ipairs(sortedRecs(G.chars)) do
    local a, due = Rules.Anniversary(x.rec.j, now)
    if a then
      local what = a.years and plural(a.years, "year") or plural(a.months, "month")
      rows[#rows + 1] = charRow(x.guid, x.rec, what .. " on " .. day(due))
      n = n + 1
    end
  end
  if n == 0 then rows[#rows + 1] = { kind = "note", text = View.T_NONE } end
end

local function formerSection(G, now, rows)
  rows[#rows + 1] = { kind = "header", text = View.T_FORMER, section = "former" }
  local list = sortedRecs(G.former)
  table.sort(list, function(a, b)
    local ga, gb = a.rec.ga or 0, b.rec.ga or 0
    if ga ~= gb then return ga > gb end
    return a.guid < b.guid
  end)
  for _, x in ipairs(list) do
    local rec = x.rec
    rows[#rows + 1] = { kind = "former", text = esc(rec.n) or "?", right = "level " .. tostring(rec.l or "?")
      .. (rec.rn and (", " .. esc(rec.rn)) or ""), class = rec.c, guid = x.guid, action = "dni" }
    local how = View.T_HOW[rec.gh or "unknown"] or tostring(rec.gh)
    if rec.gb then how = how .. " by " .. esc(rec.gb) end
    local stay
    if type(rec.j) == "number" and type(rec.ga) == "number" then
      stay = plural(Rules.DaysSince(rec.j, rec.ga), "day") .. " in the guild"
    else
      stay = "in the guild since " .. View.T_BEFORE
    end
    rows[#rows + 1] = { kind = "note", text = how .. (rec.ga and (" on " .. day(rec.ga)) or "") .. ", " .. stay }
    local officerNote = show.officerNotes ~= false and rec.no or nil
    if rec.nt or officerNote then
      local notes = {}
      if rec.nt then notes[#notes + 1] = "note: " .. esc(rec.nt) end
      if officerNote then notes[#notes + 1] = "officer note: " .. esc(officerNote) end
      rows[#rows + 1] = { kind = "note", text = table.concat(notes, "; ") }
    end
  end
  if #list == 0 then rows[#rows + 1] = { kind = "note", text = View.T_NONE } end
end

local function dniSection(G, rows)
  rows[#rows + 1] = { kind = "header", text = View.T_DNI, section = "dni" }
  rows[#rows + 1] = { kind = "note", text = View.T_LOCAL }
  local ids = {}
  for id in pairs(G.dni or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local e = G.dni[id]
    -- The guid only while the annals still know it, so a pruned one gets no name overlay (review f5).
    local known = e.g ~= nil and ((G.chars or {})[e.g] ~= nil or (G.former or {})[e.g] ~= nil)
    rows[#rows + 1] = { kind = "dni", text = esc(e.n) or "?", right = esc(e.why), id = id, guid = known and e.g or nil,
      action = "undni" }
  end
  if #ids == 0 then rows[#rows + 1] = { kind = "note", text = View.T_NONE } end
end

function View.HealthRows(G, now, opts)
  show = type(opts) == "table" and opts or {}
  local rows = {}
  for _, hit in ipairs(Store.DniHits(G)) do
    rows[#rows + 1] = { kind = "alert", text = string.format(View.T_ALERT, esc(hit.name) or "?", esc(hit.why) or ""),
      guid = hit.guid, id = hit.id }
  end
  bandSections(G, now, rows)
  newSection(G, now, rows)
  annivSection(G, now, rows)
  formerSection(G, now, rows)
  dniSection(G, rows)
  return rows
end

-- Status -----------------------------------------------------------------------------------------------------------

local function answer(v) return v == nil and "none" or tostring(v) end

-- One line per fact, for /annals status (beta step 3). `demo` adds the demo line; every other line stays real.
function View.StatusText(G, guildName, playerMax, expansionMax, isOfficer, demo)
  local lines = { "Annals: " .. (esc(guildName) or "no guild") }
  if G and G.last then
    local n = 0
    for _ in pairs(G.chars or {}) do n = n + 1 end
    lines[#lines + 1] = "Last read: " .. tostring(G.lastCount or "?") .. " of " .. tostring(G.lastTotal or "?")
      .. ", " .. (G.lastPartial and "partial" or "full") .. "; " .. n .. " members in the annals"
  else
    lines[#lines + 1] = "Last read: none yet"
  end
  lines[#lines + 1] = "Max level: GetMaxPlayerLevel " .. answer(playerMax) .. ", GetMaxLevelForPlayerExpansion "
    .. answer(expansionMax) .. ", chosen " .. Rules.MaxLevel(playerMax, expansionMax)
  lines[#lines + 1] = "Officer: " .. (isOfficer == true and "yes" or "no") .. ", Health "
    .. (demo and "shown (demo)" or isOfficer == true and "shown" or "hidden")
  if demo then lines[#lines + 1] = "Demo: on, the pages show a made-up guild" end
  return table.concat(lines, "\n")
end
