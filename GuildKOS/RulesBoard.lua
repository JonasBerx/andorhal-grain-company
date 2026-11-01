-- GuildKOS RulesBoard: the hunter board math (R6 Task G1; spec AC32, d755). Pure: no os, no date, no client. Weeks
-- start Monday 00:00 UTC; week 0 starts 1970-01-05 (345600). `since` (kos_h) is a week number: the first week of the
-- current run. Every division has a constant divisor.
local _, ns = ...
local Board = {}
ns.RulesBoard = Board

-- Board.Week(t) -> the week number of time t.
function Board.Week(t)
  return math.floor(((tonumber(t) or 0) - 345600) / 604800)
end

-- Board.Streak(kills, since, now) -> cur, best. cur: consecutive weeks with a kept kill, counted back from this week
-- (from last week while this week holds none); a gap inside the kept kills ends it. When the walk passes the oldest
-- kept week and since is older, the run counts back to since. best: the longest run among the kept weeks, at least cur.
function Board.Streak(kills, since, now)
  local has, oldest = {}, nil
  for _, k in ipairs(type(kills) == "table" and kills or {}) do
    local t = type(k) == "table" and tonumber(k.time)
    if t then
      local w = Board.Week(t)
      has[w] = true
      if not oldest or w < oldest then oldest = w end
    end
  end
  if not oldest then return 0, 0 end
  local cw = Board.Week(now)
  local start = has[cw] and cw or cw - 1
  local w, cur = start, 0
  while has[w] do
    cur = cur + 1
    w = w - 1
  end
  since = tonumber(since)
  if cur > 0 and w < oldest and since and since < oldest then cur = start - since + 1 end
  local best, run = 0, 0
  for x = oldest, math.max(cw, oldest) do
    if has[x] then
      run = run + 1
      if run > best then best = run end
    else
      run = 0
    end
  end
  if cur > best then best = cur end
  return cur, best
end

-- Board.Rows(hunters, onRoster, me, now) -> rows, mine. hunters: { key, rec } each. rows: the top 10 roster hunters by
-- total, then streak, then key, each { key, rank, total, streak, best, last }. mine: my row when I am on the roster and
-- outside the 10, else nil. Hunters off the roster are in neither.
function Board.Rows(hunters, onRoster, me, now)
  local all = {}
  for _, h in ipairs(type(hunters) == "table" and hunters or {}) do
    if type(h) == "table" and type(h.key) == "string" and onRoster(h.key) then
      local rec = type(h.rec) == "table" and h.rec or {}
      local cur, best = Board.Streak(rec.kills, rec.since, now)
      local last
      for _, k in ipairs(type(rec.kills) == "table" and rec.kills or {}) do
        local t = type(k) == "table" and tonumber(k.time)
        if t and (not last or t > last) then last = t end
      end
      all[#all + 1] = { key = h.key, total = tonumber(rec.total) or 0, streak = cur,
        best = math.max(tonumber(rec.best) or 0, best), last = last }
    end
  end
  table.sort(all, function(a, b)
    if a.total ~= b.total then return a.total > b.total end
    if a.streak ~= b.streak then return a.streak > b.streak end
    return a.key < b.key
  end)
  local rows, mine = {}, nil
  for i, r in ipairs(all) do
    r.rank = i
    if i <= 10 then rows[i] = r elseif r.key == me then mine = r end
  end
  return rows, mine
end
