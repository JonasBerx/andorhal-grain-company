-- GuildSyncGames Demo.lua: what /gsync demo shows, ns.DemoState (plan Task 9, AC10).
-- ns.DemoState(guild, now) is pure: it reads only the made-up guild and the `now` it is handed and returns the mock's
-- finished day (wd-2: MURLOC solved in 4, streak 5), its stats and six guild rows over the demo guild's keys. The hub
-- calls it once per session through Module.lua's demo field and hands it back as M.Demo().
-- While demo is on, ns.Today, ns.Stats and ns.GuildToday answer from that state, so the page shows it; the day keeps
-- the real N, label and countdown (Sync.lua's cutoff and merge read them). Nothing here is saved or sent.
-- Harvest and Kodo races (S11 Task 8): ns.Farm, Purse, MyBet, RaceHist, GuildBoards and RaceClock answer from the state's
-- grain, boards and raceT (318/360 at 6 a minute, purse 1,240, a race 24 s in with a 40-grain bet); ns.Now is not wrapped.
-- Vendor price (S12 Task 7): ns.VendorToday, VendorStats, VendorGuild and VendorBoard answer from the state's vendor, a
-- finished made-up run 8/10 on VC.Daily(DEMO_DAY) (never today's pairs, f7252); only the label and countdown are real.
-- Company (S13 Task 7, V8): ns.CompanyState, CompanyProjects, CompanyDonors, Lottery, Caravan and CompanyLook answer from
-- the state's company, projects, donors, draw (week 2), caravan (on the road) and looks; nothing is saved.
-- S14 Task 7 (AC6, mock of-1, of-2): officer = { players, draw }. ns.GamesPlayers answers the demo guild with two
-- players hidden by a demo officer; ns.Lottery waits for an officer on the clock week - 1 (124 tickets) and shows the
-- officer draw (salted, by a demo officer) of the week before, so a member sees the officer views in demo. ns.SetHidden
-- says the demo line through ns.Inert. Nothing is saved, sent or credited (d1588).

local _, ns = ...

if not ns.M then return end
local M, Core = ns.M, ns.Core

local WORD = "MURLOC"

-- { tries (0 = X), streak, minutes ago, guesses }; the first row is you.
local ROWS = {
  { 4, 5, 95, { "SHAMAN", "MOLTEN", "TURTLE", "MURLOC" } },
  { 2, 12, 240, { "MOLTEN", "MURLOC" } },
  { 3, 7, 30, { "RAPTOR", "SUMMON", "MURLOC" } },
  { 4, 2, 180, { "SPIDER", "PORTAL", "MOLTEN", "MURLOC" } },
  { 5, 1, 60, { "SHADOW", "DRAGON", "TURTLE", "MOLTEN", "MURLOC" } },
  { 0, 0, 15, { "HUNTER", "PRIEST", "TAUREN", "GOBLIN", "SPIDER", "MOLTEN" } },
}

-- Harvest and Kodo races (mock hv-1, kr-1): harvested in all, grain won, biggest win, a winning stake on the last
-- finished race (0 = none) per member in ROWS order; the first row is you.
local FARMS = {
  { 5860, 160, 160, 0 },
  { 12480, 900, 450, 30 },
  { 9215, 400, 100, 0 },
  { 4970, 1200, 600, 0 },
  { 2310, 60, 60, 20 },
  { 1145, 0, 0, 0 },
}

-- Vendor price: a day outside VC.Daily's real run; marks, best endless, daily streak, minutes ago per member in ROWS
-- order (the first row is you: 8/10, 40 grain).
local DEMO_DAY = -1000
local VROWS = {
  { "1101111011", 14, 6, 95 },
  { "1111111111", 22, 12, 240 },
  { "1110110111", 9, 7, 30 },
  { "1011101100", 17, 2, 180 },
  { "0110011010", 5, 1, 60 },
  { "1100100100", 3, 0, 15 },
}

-- The VendorToday() shape plus stats, guild and board (pure).
local function vendorState(ids, guild, now)
  local VC = ns.VendorCore
  local run, items = VC.Daily(DEMO_DAY), VC.Items()
  local prs = {}
  for k, p in ipairs(run or {}) do prs[k] = { a = items[p.a], b = items[p.b] } end
  local list, board = {}, {}
  for i, spec in ipairs(VROWS) do
    local m = ids[i] and guild.members[ids[i]]
    local key = m and ns.Key(m.name)
    if key then
      list[#list + 1] = { key = key, name = m.name, class = m.class, score = VC.Rights(spec[1]), marks = spec[1],
        at = now - spec[4] * 60, you = i == 1 }
      board[#board + 1] = { key = key, name = m.name, class = m.class, best = spec[2], streak = spec[3], you = i == 1 }
    end
  end
  table.sort(list, function(a, b) return a.at > b.at end)
  table.sort(board, function(a, b) return a.best > b.best end)
  local marks = VROWS[1][1]
  return { n = DEMO_DAY, pairs = prs, picks = marks, done = true, score = VC.Rights(marks), earned = VC.Pay(marks),
    stats = { best = VROWS[1][2], cur = VROWS[1][3] }, guild = list, board = board }
end

-- Company (S13 Task 7, V8): per member in ROWS order a gift to project 1 (6,420 in all) and a worn title, colour and
-- store badge by CC id (0 = none); the first row is you. The officer draw (clock week - 2) went to the second row,
-- drawn by the third (an Overseer in the demo guild); the last two members are hidden by the second.
local CROWS = {
  { 300, 2, 9, 13 },
  { 2500, 6, 11, 16 },
  { 1620, 1, 7, 0 },
  { 1000, 0, 0, 14 },
  { 600, 3, 0, 0 },
  { 400, 0, 0, 0 },
}
local OWNED = { 1, 2, 7, 9, 13, 17, 18, 20 } -- eight owned: Grain Runner, Brass and Sickle worn
local DRAW_TICKETS, DRAW_SALT = 124, 918273645 -- the demo draws' ticket count (mock of-1, of-2) and the made-up salt

-- The Officers rows (ns.GamesPlayers' shape) over every demo member, by name, and the officer draw for week.
local function officerState(ids, guild, week)
  local CC = ns.CompanyCore
  local function member(i)
    local m = ids[i] and guild.members[ids[i]]
    return m, m and ns.Key(m.name)
  end
  local hider = member(2)
  local players = {}
  for i, id in ipairs(ids) do
    local m = guild.members[id]
    local hidden = i > 3 and i > #ids - 2
    players[#players + 1] = { key = ns.Key(m.name), name = m.name, class = m.class, hidden = hidden,
      byName = hidden and hider and hider.name or nil }
  end
  table.sort(players, function(a, b) return a.name < b.name end)
  local winner, wkey = member(2)
  local officer, okey = member(3)
  local draw = wkey and okey and { week = week, key = wkey, i = 1, number = CC.Number(week, wkey, 1),
    target = CC.Target(week, DRAW_TICKETS, DRAW_SALT), total = DRAW_TICKETS, pot = DRAW_TICKETS * CC.TICKET_PRICE,
    salt = DRAW_SALT, by = okey, name = winner.name, byName = officer.name } or nil
  return { players = players, draw = draw }
end

local function companyState(ids, guild, now)
  local CC = ns.CompanyCore
  local owned, gifts, totals = {}, {}, {}
  for _, id in ipairs(OWNED) do owned[id] = true end
  for k = 1, #CC.PROJECTS do gifts[k], totals[k] = 0, 0 end
  gifts[1] = CROWS[1][1]
  local looks, donors = {}, {}
  for i, spec in ipairs(CROWS) do
    local m = ids[i] and guild.members[ids[i]]
    local key = m and ns.Key(m.name)
    if key then
      totals[1] = totals[1] + spec[1]
      donors[#donors + 1] = { key = key, name = m.name, class = m.class, given = spec[1], you = i == 1 }
      local t, c, b = CC.Item(spec[2]), CC.Item(spec[3]), CC.Item(spec[4])
      looks[key] = { title = t and t.name, hex = c and c.hex, badge = b and b.icon }
    end
  end
  local projects = CC.Projects(totals)
  projects.totals = totals
  table.sort(donors, function(a, b) return a.given > b.given end)
  local week = CC.Week(now, 0)
  local you = ids[1] and guild.members[ids[1]]
  local officer = officerState(ids, guild, week - 2)
  return {
    company = { era = "live", token = "dm0you", owned = owned, title = CROWS[1][2], colour = CROWS[1][3],
      badge = CROWS[1][4], gifts = gifts, tickets = { week = week, count = 3, prevWeek = 0, prevCount = 0,
        key = you and ns.Key(you.name) or "dm0you" } },
    projects = projects,
    officer = officer,
    draw = officer.draw, -- the same table: S13's field name, kept for the state's readers
    caravan = { start = now - 6600, hours = 4, stake = 250 }, -- back in 2 h 10 min
    looks = looks,
    donors = { [1] = donors },
  }
end

function ns.DemoState(guild, now)
  now = math.floor(now)
  local ids = {}
  for id in pairs(guild.members or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local n, label, secsLeft = Core.Puzzle(now, nil)
  local h = math.floor(now / 3600)
  local GC = ns.GrainCore
  local last = GC.Race(h - 1) -- the race h runs 24 s in (raceT), so h - 1 is the last finished one
  local pays = last.field[last.winner].pays
  local list, boards = {}, { harvest = {}, lastHour = h - 1, winners = {}, biggest = {} }
  for i, spec in ipairs(ROWS) do
    local m = ids[i] and guild.members[ids[i]]
    local key = m and ns.Key(m.name)
    if key then
      local codes = {}
      for j, r in ipairs(Core.Scored(spec[4], WORD)) do codes[j] = r.codes end
      list[#list + 1] = { key = key, name = m.name, class = m.class, tries = spec[1], rows = codes, streak = spec[2],
        at = now - spec[3] * 60, you = i == 1 }
      local f = FARMS[i]
      boards.harvest[#boards.harvest + 1] = { key = key, name = m.name, class = m.class, harvested = f[1], you = i == 1 }
      local pay = f[4] > 0 and GC.Payout(f[4], pays, true) or 0
      if pay > 0 then
        boards.winners[#boards.winners + 1] = { key = key, name = m.name, class = m.class, pay = pay, pays = pays,
          you = i == 1 }
      end
      local big = math.max(f[3], pay) -- as in real data, the biggest win is never below a pay
      if big > 0 then
        boards.biggest[#boards.biggest + 1] = { key = key, name = m.name, class = m.class, big = big, you = i == 1 }
      end
    end
  end
  table.sort(list, Core.ByResult)
  table.sort(boards.harvest, function(a, b) return a.harvested > b.harvested end)
  table.sort(boards.winners, function(a, b) return a.pay > b.pay end)
  table.sort(boards.biggest, function(a, b)
    if a.big ~= b.big then return a.big > b.big end
    return a.name < b.name -- a raised big can tie another
  end)
  local co = companyState(ids, guild, now)
  return {
    company = co.company, projects = co.projects, draw = co.draw, officer = co.officer, caravan = co.caravan,
    looks = co.looks, donors = co.donors,
    day = { n = n, label = label or "#1", word = WORD, len = #WORD, rows = Core.Scored(ROWS[1][4], WORD), done = true, won = true,
      secsLeft = secsLeft },
    stats = { played = 14, won = 12, cur = 5, best = 9, dist = { 0, 1, 3, 5, 2, 1 } },
    guild = list,
    grain = { purse = 1240, standing = 318, harvested = 5860, ranks = { farmhand = 2, scythes = 1, granary = 1 },
      bet = { hour = h, lane = 3, stake = 40 },
      hist = { { hour = h - 3, lane = 4, stake = 40, pay = 160 }, { hour = h - 2, lane = 2, stake = 25, pay = 0 } } },
    boards = boards,
    raceT = h * 3600 + 24, -- 24 s into the current hour's race (kr-1)
    vendor = vendorState(ids, guild, now),
    at = now,
  }
end

-- The demo state while demo is on, else nil (Facts.lua reads it too).
local function state()
  local on, s = M.Demo()
  if on and type(s) == "table" then return s end
  return nil
end
ns.DemoOn = state

local realToday, realStats, realGuild = ns.Today, ns.Stats, ns.GuildToday

-- In demo the real N, label and countdown are computed from the clock and the saved reset phase, read only: the real
-- reader's day roll and ns.Day's phase update would write GuildSyncGamesDB (d1588).
function ns.Today()
  local s = state()
  if not s then return realToday() end
  local day = {}
  for k, v in pairs(s.day) do day[k] = v end
  local t, saved = ns.Now(), type(GuildSyncGamesDB) == "table" and GuildSyncGamesDB.phase or nil
  local n, label, secsLeft
  if type(t) == "number" then n, label, secsLeft = Core.Puzzle(t, saved) end
  if n and label then day.n, day.label, day.secsLeft = n, label, secsLeft end
  return day
end

function ns.Stats()
  local s = state()
  if not s then return realStats() end
  return s.stats
end

function ns.GuildToday()
  local s = state()
  if not s then return realGuild() end
  return s.guild
end

-- Harvest and Kodo races: the grain, the boards and the race clock. ns.Now stays real (every rule reads it).
local realFarm, realPurse, realBet, realHist = ns.Farm, ns.Purse, ns.MyBet, ns.RaceHist
local realBoards, realClock = ns.GuildBoards, ns.RaceClock

function ns.Farm()
  local s = state()
  if not s then return realFarm() end
  local g, GC = s.grain, ns.GrainCore
  local r = g.ranks
  return { standing = g.standing, cap = GC.Cap(r), rate = GC.Rate(r), harvested = g.harvested,
    ranks = { farmhand = r.farmhand, scythes = r.scythes, granary = r.granary } }
end

function ns.Purse()
  local s = state()
  if not s then return realPurse() end
  return s.grain.purse
end

function ns.MyBet()
  local s = state()
  if not s then return realBet() end
  local b = s.grain.bet
  return { hour = b.hour, lane = b.lane, stake = b.stake }
end

function ns.RaceHist()
  local s = state()
  if not s then return realHist() end
  local out = {}
  for i, r in ipairs(s.grain.hist) do out[i] = { hour = r.hour, lane = r.lane, stake = r.stake, pay = r.pay } end
  return out
end

function ns.GuildBoards()
  local s = state()
  if not s then return realBoards() end
  return s.boards
end

-- The demo race runs on from raceT at the real pace, so a watched replay moves.
function ns.RaceClock()
  local s = state()
  if not s then return realClock() end
  local t = ns.Now()
  return s.raceT + (type(t) == "number" and math.max(0, t - s.at) or 0)
end

-- Vendor price: the made-up run, list and board; the day's label and countdown stay real.
local realVendorToday, realVendorStats = ns.VendorToday, ns.VendorStats
local realVendorGuild, realVendorBoard = ns.VendorGuild, ns.VendorBoard

function ns.VendorToday()
  local s = state()
  if not s then return realVendorToday() end
  local v = s.vendor
  local _, label, secsLeft = ns.Day()
  return { n = v.n, label = label, pairs = v.pairs, picks = v.picks, done = v.done, score = v.score,
    earned = v.earned, secsLeft = secsLeft }
end

function ns.VendorStats()
  local s = state()
  if not s then return realVendorStats() end
  return { best = s.vendor.stats.best, cur = s.vendor.stats.cur }
end

function ns.VendorGuild()
  local s = state()
  if not s then return realVendorGuild() end
  return s.vendor.guild
end

function ns.VendorBoard()
  local s = state()
  if not s then return realVendorBoard() end
  return s.vendor.board
end

-- Company (S13 Task 7): the store, granary, donors, lottery, caravan and looks answer from the state at call time. The
-- badge latch and Donate read ns.CompanyRaw (unwrapped) and the settle returns in demo, so nothing here is saved (d1588).
local realCompanyState, realCompanyProjects, realCompanyDonors = ns.CompanyState, ns.CompanyProjects, ns.CompanyDonors
local realLottery, realCaravan, realCompanyLook = ns.Lottery, ns.Caravan, ns.CompanyLook
local realPlayers, realSetHidden = ns.GamesPlayers, ns.SetHidden

function ns.CompanyState()
  local s = state()
  if not s then return realCompanyState() end
  local v = {}
  for k, x in pairs(s.company) do v[k] = x end
  return v
end

function ns.CompanyProjects()
  local s = state()
  if not s then return realCompanyProjects() end
  return s.projects
end

function ns.CompanyDonors(k)
  local s = state()
  if not s then return realCompanyDonors(k) end
  return s.donors[k] or {}
end

-- The real clock and realm offset; the current week's pot, last week's wait and the officer draw (the state's own
-- table, week - 2) are made up.
function ns.Lottery()
  local s = state()
  if not s then return realLottery() end
  local t = ns.Now()
  if type(t) ~= "number" then return nil end
  local CC, off, known = ns.CompanyCore, ns.RealmOffset()
  local w, closeAt, drawAt, settleAt, open = CC.Week(t, off)
  local mine = {}
  for i = 1, s.company.tickets.count do mine[i] = CC.Number(w, s.company.tickets.key, i) end
  return { week = w, closeAt = closeAt, drawAt = drawAt, settleAt = settleAt, open = open, utc = not known,
    lastWeek = w - 1, mine = mine, pot = DRAW_TICKETS * CC.TICKET_PRICE, total = DRAW_TICKETS, draw = s.officer.draw,
    waiting = true, waitWeek = w - 1, waitTotal = DRAW_TICKETS }
end

-- The Officers rows: the demo guild, two of them hidden by a demo officer.
if realPlayers then
  function ns.GamesPlayers()
    local s = state()
    if not s then return realPlayers() end
    return s.officer.players
  end
end

-- A Hide or Unhide in demo says the hub's demo line and changes nothing.
if realSetHidden then
  function ns.SetHidden(key, on)
    if ns.Inert() then return nil, "demo" end
    return realSetHidden(key, on)
  end
end

-- Always on the road: the demo caravan never comes home (Harvest shows no time left once it is due).
function ns.Caravan()
  local s = state()
  if not s then return realCaravan() end
  local v = s.caravan
  return { start = v.start, hours = v.hours, stake = v.stake }
end

function ns.CompanyLook(key)
  local s = state()
  if not s then return realCompanyLook(key) end
  return s.looks[key]
end
