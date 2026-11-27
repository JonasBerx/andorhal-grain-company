local _, ns = ...
if not ns.M then return end

-- Pure rules over the held raids_n records (ticket 61, N1 and N2; plan Task 2): raid matching, the joined view with
-- the deleted rules, your jobs, the You line and the demo set. Exports ns.NotesRules: Words, Tokens, MatchRaid, View,
-- ForEvent, Holders, YourJobs, YouLine, Url, Demo. Built on ns.NotesCodec. No client calls; only string, table, math.

local R = {}
ns.NotesRules = R

local NC = ns.NotesCodec

local function lower(s) return type(s) == "string" and string.lower(s) or "" end

-- The bot's rule (tactics-match.js:6): lowercased runs of [a-z'] longer than 2 bytes.
function R.Words(s)
  local out = {}
  for w in string.gmatch(lower(s), "[a-z']+") do if #w > 2 then out[#out + 1] = w end end
  return out
end

-- Lowercased runs of ASCII letters, digits and apostrophe, any length (the officer's match words).
function R.Tokens(s)
  local out = {}
  for w in string.gmatch(lower(s), "[%w']+") do out[#out + 1] = w end
  return out
end

local function set(list)
  local s = {}
  for _, w in ipairs(list) do s[w] = true end
  return s
end

-- Id order: digit strings by length, then by value.
local function before(a, b)
  if #a ~= #b then return #a < #b end
  return a < b
end

function R.MatchRaid(raids, title)
  if type(raids) ~= "table" then return nil end
  local W, T = set(R.Words(title)), set(R.Tokens(title))
  local list = {}
  for _, r in ipairs(raids) do if type(r) == "table" and type(r.id) == "string" then list[#list + 1] = r end end
  table.sort(list, function(a, b) return before(a.id, b.id) end)
  for _, r in ipairs(list) do
    for _, w in ipairs(R.Words(r.name)) do if W[w] then return r end end
    for _, w in ipairs(R.Tokens(r.words)) do if T[w] then return r end end
  end
  return nil
end

-- The view. An X replaces the record on its own key, so the deleted rules follow from what is live: a boss needs a
-- live b part 1 and a live r for its raid; jobs need a live j part 1; a part 2 counts only with its part 1's gen.
-- So while an X is held, a related key at or below its gen never shows. A newer record on the X's key replaces the X,
-- and then every related key shows again whatever its gen: the view does not compare gens across keys (a writer never
-- reuses an id; NOTES-FORMAT.md). A note's text loses its invalid UTF-8 here, after the join or alone as incomplete.
function R.View(records, t)
  local d = {}
  for key, r in pairs(type(records) == "table" and records or {}) do
    if type(r) == "table" then d[key] = NC.Decode(key, r.body) end
  end
  local function live(key, kind, part)
    local x = d[key]
    if x and x.kind == kind and x.part == part then return x end
  end
  local function second(p1, key)
    local p2 = p1.n == 2 and live(key, p1.kind, 2)
    if p2 and p2.gen == p1.gen then return p2 end
  end

  local function jobsOf(id)
    local p1 = live("j" .. id, "j", 1)
    if not p1 then return {} end
    local jobs, byNo, loose = {}, {}, { p1.loose }
    for _, j in ipairs(p1.jobs) do jobs[#jobs + 1] = j; byNo[j.no] = j end
    local p2 = second(p1, "j" .. id .. "b")
    if p2 and #jobs + #p2.jobs <= NC.LIMITS.JOBS then
      local clash = false
      for _, j in ipairs(p2.jobs) do if byNo[j.no] then clash = true end end
      if not clash then
        for _, j in ipairs(p2.jobs) do jobs[#jobs + 1] = j; byNo[j.no] = j end
        loose[2] = p2.loose
      end
    end
    -- h rows that landed in the other part than their job; the first list for a team wins.
    for _, l in ipairs(loose) do
      for no, teams in pairs(l) do
        local j = byNo[no]
        if j then for team, names in pairs(teams) do if j.holders[team] == nil then j.holders[team] = names end end end
      end
    end
    return jobs
  end

  local byId, order, found = {}, {}, {}
  for key, x in pairs(d) do
    if x.kind == "r" then
      byId[x.id] = { id = x.id, name = x.name, words = x.words, sketches = x.sketches, rev = records[key].rev,
        bosses = {} }
      order[x.id], found[x.id] = x.bosses, {}
    end
  end
  for key, x in pairs(d) do
    if x.kind == "b" and x.part == 1 and byId[x.raid] then
      local boss = { id = x.id, name = x.name, text = x.text, rev = records[key].rev, jobs = jobsOf(x.id) }
      if x.n == 2 then
        local p2 = second(x, key .. "b")
        if p2 and x.escLen + p2.escLen <= NC.LIMITS.NOTE then boss.text = x.text .. p2.text
        else boss.incomplete = true end
      end
      boss.text = NC.Utf8(boss.text)
      found[x.raid][x.id] = boss
    end
  end

  local raids = {}
  for id, raid in pairs(byId) do
    local held, rest = found[id], {}
    for _, bid in ipairs(order[id]) do
      if held[bid] then raid.bosses[#raid.bosses + 1] = held[bid]; held[bid] = nil end
    end
    for bid in pairs(held) do rest[#rest + 1] = bid end
    table.sort(rest, before)
    for _, bid in ipairs(rest) do raid.bosses[#raid.bosses + 1] = held[bid] end
    raids[#raids + 1] = raid
  end
  table.sort(raids, function(a, b) return before(a.id, b.id) end)
  return { raids = raids }
end

-- The event's notes raid: MatchRaid over the raids with at least one boss.
function R.ForEvent(nv, ev)
  if type(nv) ~= "table" or type(nv.raids) ~= "table" or type(ev) ~= "table" then return nil end
  local list = {}
  for _, r in ipairs(nv.raids) do if #r.bosses > 0 then list[#list + 1] = r end end
  return R.MatchRaid(list, ev.title)
end

-- A job's holders for one team; no team reads the "" list.
function R.Holders(job, team)
  if type(job) ~= "table" or type(job.holders) ~= "table" then return {} end
  local list = job.holders[team == nil and "" or team]
  return type(list) == "table" and list or {}
end

-- Every job on the raid held by one of myKeys (keyFn(name) is the key), for the raid's team.
function R.YourJobs(raid, team, myKeys, keyFn)
  local out = {}
  if type(raid) ~= "table" or type(raid.bosses) ~= "table" or type(myKeys) ~= "table" or type(keyFn) ~= "function" then
    return out
  end
  for _, boss in ipairs(raid.bosses) do
    for _, job in ipairs(boss.jobs or {}) do
      for _, name in ipairs(R.Holders(job, team)) do
        local k = keyFn(name)
        if k ~= nil and myKeys[k] then out[#out + 1] = { boss = boss, job = job }; break end
      end
    end
  end
  return out
end

-- Job names on the called boss, else "n jobs", else nil.
function R.YouLine(mine, calledBossId)
  if type(mine) ~= "table" or #mine == 0 then return nil end
  if calledBossId ~= nil then
    local names, called = {}, tostring(calledBossId)
    for _, e in ipairs(mine) do if e.boss.id == called then names[#names + 1] = e.job.name end end
    if #names > 0 then return table.concat(names, ", ") end
  end
  return #mine == 1 and "1 job" or (#mine .. " jobs")
end

-- The first http(s) address in s, without trailing .,;:!?)]'" (inner dots and brackets stay).
function R.Url(s)
  if type(s) ~= "string" then return nil end
  local url = string.match(s, "https?://%S+")
  if not url then return nil end
  url = string.gsub(url, "[%.,;:!%?%)%]'\"]+$", "")
  return string.match(url, "^https?://.+") and url or nil
end

-- Made-up records in the store shape, for demo only.
function R.Demo(names, me, t)
  local who = {}
  for _, n in ipairs(type(names) == "table" and names or {}) do if type(n) == "string" then who[#who + 1] = n end end
  local mine = type(me) == "string" and me or nil
  local function list(...)
    local out = {}
    for i = 1, select("#", ...) do
      local n = select(i, ...)
      if type(n) == "string" then out[#out + 1] = n end
    end
    return out
  end
  local long = string.rep("Stay out of the fire and keep the adds off the healers. ", 6)
  local recs = {
    { kind = "r", id = "1", gen = t, name = "Molten Core", words = "MC",
      sketches = "Sketches: https://example.org/mc-sketches", bosses = { "11", "12", "13", "14" } },
    { kind = "b", id = "11", gen = t, raid = "1", name = "Lucifron",
      text = "Decurse the tanks first.\n" .. long .. "\nKill the guards, then Lucifron." },
    { kind = "b", id = "12", gen = t, raid = "1", name = "Magmadar", text = "Fear ward on the main tank." },
    { kind = "b", id = "13", gen = t, raid = "1", name = "Gehennas", text = "Spread for the rain of fire." },
    { kind = "b", id = "14", gen = t, raid = "1", name = "Garr", text = "Banish the adds, then kill Garr." },
    { kind = "j", id = "11", gen = t, jobs = {
      { no = 1, name = "Main tank", hint = "Face him away from the raid.",
        holders = { ["Team 1"] = list(mine, who[1]), ["Team 2"] = list(mine, who[3]) } },
      { no = 2, name = "Decurse", hint = "Mages and druids.",
        holders = { ["Team 1"] = list(who[2]), ["Team 2"] = list(who[4]) } } } },
    { kind = "j", id = "12", gen = t, jobs = {
      { no = 1, name = "Fear ward", hint = "Priest on the main tank.",
        holders = { ["Team 1"] = list(mine, who[2]), ["Team 2"] = list(mine, who[4]) } } } },
    { kind = "r", id = "2", gen = t, name = "Blackwing Lair", words = "BWL", sketches = "", bosses = { "21" } },
    { kind = "b", id = "21", gen = t, raid = "2", name = "Razorgore", text = "One player controls the orb." },
  }
  local out = {}
  for _, r in ipairs(recs) do
    for key, body in pairs(NC.Pack(r) or {}) do out[key] = { rev = t, hash = "", by = "demo", body = body } end
  end
  return out
end
