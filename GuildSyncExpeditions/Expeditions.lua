-- GuildSyncExpeditions Expeditions.lua: the saved runs and board, the send, the settle and the raise (0.19 plan, Seams 5, 6, 7).
--   ns.TodayRows() -> rows                    `taken = true` on those sent today; {} with no day
--   ns.NextRefresh() -> seconds | nil         ns.StoryRunOut(storyId) -> bool
--   ns.OutNow() -> { fid, name, rowId, untilT, title, place, region } | nil   the run due back first; a read
--   ns.RunOut(rowId) -> bool                  a read: true while a run from that board row is out
--   ns.ChancesFor(fid, row) -> chances | nil  a read: never ns.CheckPack
--   ns.Send(fid, rowId) -> run id | nil, why
--   ns.SettleDue(t) -> { { fid, name, band, gear, slot, rowId, found }, ... }   one sound per call that settled a run
--                                             and one hub toast (M.Toast) per settled run History answered for: title
--                                             "<name> is back", text "<run title>: <result word>", icon the last Rare
--                                             that run landed, else TOAST_ICON. The first toast of the cue's kind carries
--                                             the sound and is pushed first; ns.PlayCue plays unless that push answered true
--   ns.PlayCue "find" | "good" | "bad" -> played   the one place the module plays a sound; false in demo
--   ns.RaisePrice(fid) -> n | nil             ns.Raise(fid) -> true | nil, why
-- The later slices' ns.IsReserve, CheckPack, ClearPack, LeaveWorn, BreakGear, LoseGear, ApplyRewards, PersonalRows,
-- OnRaised, TraitMods, SupplyMods, SetMods, KitScore, SupplyChoices, TakeStack, OpenRegions and HeldMaps are read at
-- call time and skipped while they are missing. ns.HistoryRun then ns.AnnounceRun (History.lua) follow every settled
-- run, each in its own M.Safe: a throw in one never skips the other, and the run stays settled.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local FC = ns.FollowerCore
local RC = ns.RiskCore
local BC = ns.BoardCore
local SLOTS = ns.GearData.SLOTS

local SEED_MAX = 2147483646
local HOUR = 3600
local REFRESH_MAX = 86400
local RAISE_HOURS = 8
local SUPPLIES_MAX = 2
local CHANCE_FIELDS = { "success", "wound", "death", "perma", "broken", "lost" }
local BAND_FIELDS = { "perma", "dead", "failw", "fail", "succw", "succ" }
local STATE_AFTER = { succ = "idle", fail = "idle", succw = "rest", failw = "rest", dead = "dead" }
local WINS = { succ = true, succw = true }
local CUE = { find = 31578, good = 878, bad = 847 }
local TOAST_ICON = "Interface\\Icons\\INV_Misc_Map_01"

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

local function text(v)
  return type(v) == "string" and #v >= 1 and #v <= FC.TEXT_MAX
end

local function soundChances(c)
  if type(c) ~= "table" or type(c.bands) ~= "table" then return nil end
  local out, bands, sum = {}, {}, 0
  for _, k in ipairs(CHANCE_FIELDS) do
    if not whole(c[k], 0, 100) then return nil end
    out[k] = c[k]
  end
  for _, k in ipairs(BAND_FIELDS) do
    local v = c.bands[k]
    if not whole(v, 0, 100) then return nil end
    bands[k] = v
    sum = sum + v
  end
  if sum ~= 100 then return nil end
  out.bands = bands
  return out
end

local function soundSupplies(list)
  local out = {}
  if type(list) == "table" then
    for _, v in ipairs(list) do
      if text(v) then out[#out + 1] = v end
      if #out == SUPPLIES_MAX then break end
    end
  end
  return out
end

-- A new table of the known fields, or nil: any bad field but story, capstone and supplies drops the run alone.
local function soundRun(id, r)
  if r.id ~= id or not whole(id, 1, FC.ID_MAX) or not whole(r.fid, 1, FC.ID_MAX) then return nil end
  if not (text(r.rowId) and text(r.region) and text(r.kind)) then return nil end
  if not (whole(r.hours, 1, 24) and whole(r.level, 1, 10) and whole(r.danger, 1, 4) and whole(r.rest, 1, 8)) then return nil end
  if not (whole(r.start, 0, FC.TIME_MAX) and whole(r.ends, 0, FC.TIME_MAX) and whole(r.seed, 1, SEED_MAX)) then return nil end
  local chances = soundChances(r.chances)
  if not chances then return nil end
  return {
    id = id, fid = r.fid, rowId = r.rowId, region = r.region, kind = r.kind, hours = r.hours, level = r.level,
    danger = r.danger, capstone = r.capstone == true or nil, story = text(r.story) and r.story or nil, start = r.start,
    ends = r.ends, seed = r.seed, rest = r.rest, chances = chances, supplies = soundSupplies(r.supplies),
  }
end

local function soundTaken(id, row)
  if not text(id) or not whole(row.fid, 1, FC.ID_MAX) then return nil end
  return { fid = row.fid }
end

local function freshRows() return { next = 1, rows = {} } end
local function freshBoard() return { day = 0, rows = {} } end

-- At use, never at file load: saved variables are not ready then.
local function followers() return ns.Part("followers", freshRows, FC.SoundRow) end
local function runs() return ns.Part("runs", freshRows, soundRun) end
local function board() return ns.Part("board", freshBoard, soundTaken) end

local function ask(name, ...)
  if ns[name] then return ns[name](...) end
  return nil
end

-- Under its own Safe, so a throw stops only this hook. Answers Safe's first value; nil when the hook is missing.
local function hook(name, ...)
  if ns[name] then return M.Safe(ns[name], ...) end
  return nil
end

local function serverDay(now)
  return BC.Day(now, M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset"))
end

local function rowsFor(day)
  return BC.Rows(day, ask("OpenRegions") or ns.Regions.Open(), ask("HeldMaps") or {}, ask("PersonalRows", day) or {})
end

-- In order race, trait, supply, set; a source with nothing to say adds no entry.
local function modsOf(fid, row, ids)
  local list = { ns.RaceMods(fid) }
  list[#list + 1] = ask("TraitMods", fid, row)
  list[#list + 1] = ask("SupplyMods", ids, row)
  list[#list + 1] = ask("SetMods", fid, row)
  return list
end

local function chancesOf(fid, row, list)
  return RC.Chances(ns.PowerOf(fid, row), RC.Need(row.level, row.danger), row.danger, list)
end

local function restHours(danger, list)
  local hours = danger * 2
  for _, mod in ipairs(list) do
    if type(mod) == "table" and type(mod.rest) == "number" then hours = hours + mod.rest end
  end
  return math.max(1, math.min(8, math.floor(hours)))
end

function ns.TodayRows()
  local now = ns.Now()
  local day = now and serverDay(now)
  if not day then return {} end
  local rows = rowsFor(day)
  local b = board()
  if b.day == day then
    for _, row in ipairs(rows) do
      if b.rows[row.id] then row.taken = true end
    end
  end
  return rows
end

function ns.NextRefresh()
  local left = M.Compat.call("C_DateAndTime.GetSecondsUntilDailyReset")
  if type(left) == "number" and left >= 0 and left <= REFRESH_MAX then return left end
  return nil
end

function ns.StoryRunOut(storyId)
  if storyId == nil then return false end
  for _, run in pairs(runs().rows) do
    if run.story == storyId then return true end
  end
  return false
end

function ns.RunOut(rowId)
  for _, run in pairs(runs().rows) do
    if run.rowId == rowId then return true end
  end
  return false
end

-- Ties by lowest run id; a run whose follower has gone is skipped. W.RowText takes a board row, so the row's id goes in
-- place of the run's own number.
function ns.OutNow()
  local first
  for _, run in pairs(runs().rows) do
    if ns.Follower(run.fid) and (not first or run.ends < first.ends or (run.ends == first.ends and run.id < first.id)) then
      first = run
    end
  end
  if not first then return nil end
  local title, _, place = ns.W.RowText({ id = first.rowId, region = first.region, kind = first.kind, capstone = first.capstone })
  local step = first.story and ask("StoryStep")
  if type(step) == "table" then title, place = step.title or title, step.place or place end
  return { fid = first.fid, name = ns.Follower(first.fid).name, rowId = first.rowId, untilT = first.ends, title = title,
    place = place, region = first.region }
end

-- The packed ids still in their stacks, at most two.
local function packedSupplies(fid)
  local out = {}
  for _, s in ipairs(ask("SupplyChoices", fid) or {}) do
    if s.packed and (s.n or 0) >= 1 then out[#out + 1] = s.id end
    if #out == SUPPLIES_MAX then break end
  end
  return out
end

function ns.ChancesFor(fid, row)
  if not row or not ns.Follower(fid) then return nil end
  return chancesOf(fid, row, modsOf(fid, row, packedSupplies(fid)))
end

local function findRow(day, rowId)
  for _, row in ipairs(rowsFor(day)) do
    if row.id == rowId then return row end
  end
  return nil
end

-- Every refusal comes before this function's one plain write, which waits for the mods because they can throw. The
-- seal's "row" is the only refusal after ns.CheckPack, F's own write that drops empty packs.
function ns.Send(fid, rowId)
  if ns.Inert() then return nil, "demo" end
  local now = ns.Now()
  local day = now and serverDay(now)
  if not day then return nil, "clock" end
  local f = ns.Follower(fid)
  if not f then return nil, "unknown" end
  local reserve = f.reserve == true
  if ns.IsReserve then reserve = ns.IsReserve(fid) end
  if reserve then return nil, "reserve" end
  if f.state == "out" or (f.state == "rest" and f.untilT and f.untilT > now) then return nil, "busy" end
  if f.state == "dead" then return nil, "dead" end
  local row = findRow(day, rowId)
  if not row then return nil, "row" end
  local b = board()
  if row.taken or (b.day == day and b.rows[row.id]) then return nil, "taken" end
  local good, why = BC.CanSend(f.level, ask("KitScore", fid) or 0, row)
  if not good then return nil, why end
  local p = runs()
  local id = FC.NextId(p)
  if not id then return nil, "full" end

  ask("CheckPack", fid)
  local supplies = packedSupplies(fid)
  local mods = modsOf(fid, row, supplies)
  local chances = chancesOf(fid, row, mods)
  local salt = p.salt
  if not whole(salt, 1, SEED_MAX) then salt = math.random(SEED_MAX) end
  local ends = now + row.hours * HOUR

  local built = {
    id = id, fid = fid, rowId = row.id, region = row.region, kind = row.kind, hours = row.hours, level = row.level,
    danger = row.danger, capstone = row.capstone, story = row.story, start = now, ends = ends,
    seed = RC.Seed(fid .. ":" .. row.id, now, salt), rest = restHours(row.danger, mods), chances = chances,
    supplies = supplies,
  }
  local sealed = soundRun(id, built)
  if not sealed then return nil, "row" end

  p.rows[id] = sealed
  p.next = id + 1
  p.salt = salt
  f.state, f.untilT = "out", ends
  if b.day ~= day then b.day, b.rows = day, {} end
  b.rows[row.id] = { fid = fid }

  for _, supply in ipairs(supplies) do hook("TakeStack", "supply", supply, 1) end
  hook("ClearPack", fid)
  return id
end

local function wornSlots(f)
  local out = {}
  for _, slot in ipairs(SLOTS) do
    if f.gear[slot.key] then out[#out + 1] = slot.key end
  end
  return out
end

local function bump(f, stat)
  f.stats[stat] = math.min(f.stats[stat] + 1, FC.STAT_MAX)
end

local function writeOutcome(f, run, band)
  f.state = STATE_AFTER[band]
  f.untilT = f.state == "rest" and run.ends + run.rest * HOUR or nil
  bump(f, "runs")
  if WINS[band] then
    bump(f, "wins")
    if run.danger == 4 then bump(f, "deadly") end
  end
  if f.state == "rest" then bump(f, "wounds") end
end

-- The row goes only when ns.LeaveWorn answered: without that its gear is still on it. Moves no stat.
local function permadeath(fid, f)
  f.state, f.untilT = "dead", nil
  local left = hook("LeaveWorn", fid)
  hook("ClearPack", fid)
  if left then followers().rows[fid] = nil end
end

-- The icon of the last Rare piece run fid landed (ns.Finds()[1], newest first), else nil. A read.
local function findIcon(fid)
  local last = ns.Finds()[1]
  if last and last.fid == fid then return ns.GearData.Row(last.row).icon end
  return nil
end

-- The run is cleared first, so a throw anywhere after this can never pay twice.
local function settleRun(run, reports, toasts)
  if runs().rows[run.id] ~= run then return end
  runs().rows[run.id] = nil
  local fid = run.fid
  local f = ns.Follower(fid)
  if not f then return end
  local name = f.name
  local outcome = RC.Roll(run.chances, run.seed, wornSlots(f))
  local _, open = hook("StoryStep") -- read before the settle: ApplyRewards can advance the step
  local found -- nil after a perma: no rewards
  if outcome.band == "perma" then
    permadeath(fid, f)
  else
    writeOutcome(f, run, outcome.band)
    if outcome.gear == "broken" then
      hook("BreakGear", fid, outcome.slot)
    elseif outcome.gear == "lost" then
      hook("LoseGear", fid, outcome.slot)
    end
    found = select(2, hook("ApplyRewards", fid, run, outcome)) -- the first value is M.Safe's ok flag
  end
  hook("HistoryRun", run, name, outcome.band, open)
  local _, said = hook("AnnounceRun", run, name, outcome.band, open)
  local icon = found == true and select(2, M.Safe(findIcon, fid)) or nil
  reports[#reports + 1] = { fid = fid, name = name, band = outcome.band, gear = outcome.gear, slot = outcome.slot, rowId = run.rowId,
    found = found == true }
  toasts[#toasts + 1] = { name = name, band = outcome.band, found = found == true, said = said, icon = icon }
end

-- A Rare find beats a win, a win beats a loss.
local function cueOf(reports)
  local good = false
  for _, r in ipairs(reports) do
    if r.found then return "find" end
    if WINS[r.band] then good = true end
  end
  return good and "good" or "bad"
end

-- Raw text: the hub escapes at draw and cuts to its caps. True only when the hub answered true.
local function pushOne(entry, kit)
  local said = entry.said
  local spec = { title = entry.name .. " is back", text = said.title and (said.title .. ": " .. said.word) or said.word,
    icon = entry.icon or TOAST_ICON, sound = kit }
  return M.Toast(spec) == true
end

-- One toast per entry History answered for. The first entry of the cue's kind carries the sound and goes first; heard
-- is that push's answer alone. Each other entry is pushed in settle order under its own M.Safe, with no sound.
local function raiseToasts(toasts, cue)
  if type(M.Toast) ~= "function" or M.Demo() then return false end
  local carrier
  for _, entry in ipairs(toasts) do
    local kind = entry.found and "find" or (WINS[entry.band] and "good" or "bad")
    if type(entry.said) == "table" and kind == cue then
      carrier = entry
      break
    end
  end
  local heard = false
  if carrier then
    local ran, pushed = M.Safe(pushOne, carrier, CUE[cue])
    heard = ran == true and pushed == true
  end
  for _, entry in ipairs(toasts) do
    if entry ~= carrier and type(entry.said) == "table" then M.Safe(pushOne, entry) end
  end
  return heard
end

-- No handle is kept and no finish event asked for; the game's own sound switches apply. The fallback runs only when
-- the global is missing or threw, and a plain false answer counts as not played.
function ns.PlayCue(kind)
  local kit = CUE[kind]
  if not kit or M.Demo() then return false end
  local ran, success = M.Compat.Try("PlaySound", kit, "SFX", true)
  if not ran then ran, success = M.Compat.Try("C_Sound.PlaySound", kit) end
  return ran == true and success ~= false
end

function ns.SettleDue(t)
  local reports = {}
  if type(t) ~= "number" or M.Demo() then return reports end
  local due, toasts = {}, {}
  for _, run in pairs(runs().rows) do
    if run.ends <= t then due[#due + 1] = run end
  end
  table.sort(due, function(a, b)
    if a.ends ~= b.ends then return a.ends < b.ends end
    return a.id < b.id
  end)
  for _, run in ipairs(due) do M.Safe(settleRun, run, reports, toasts) end
  if #reports > 0 then
    local cue = cueOf(reports)
    local ran, heard = M.Safe(raiseToasts, toasts, cue)
    if not (ran and heard) then M.Safe(ns.PlayCue, cue) end
  end
  local rested = false
  for _, f in pairs(followers().rows) do
    if f.state == "rest" and (not f.untilT or f.untilT <= t) then
      f.state, f.untilT = "idle", nil
      rested = true
    end
  end
  if rested then M.RefreshPage() end -- a rest ending writes no report, so the page would not redraw
  return reports
end

function ns.RaisePrice(fid)
  local f = ns.Follower(fid)
  if not f then return nil end
  return 40 + 20 * f.level
end

function ns.Raise(fid)
  if ns.Inert() then return nil, "demo" end
  local f = ns.Follower(fid)
  if not f then return nil, "unknown" end
  if f.state ~= "dead" then return nil, "state" end
  local now = ns.Now()
  if not now then return nil, "clock" end
  local hours = math.max(1, RAISE_HOURS + (ns.RaceMods(fid).rest or 0))
  local paid, why = ns.Grain("spend", ns.RaisePrice(fid))
  if not paid then return nil, why end
  f.state, f.untilT = "rest", now + hours * HOUR
  bump(f, "raised")
  hook("OnRaised", fid)
  return true
end

-- A follower out with no run (its run was dropped at load) is freed before the settle. No grain moves.
local function freeOrphans()
  local busy = {}
  for _, run in pairs(runs().rows) do busy[run.fid] = true end
  for fid, f in pairs(followers().rows) do
    if f.state == "out" and not busy[fid] then f.state, f.untilT = "idle", nil end
  end
end

ns.LoginHooks[#ns.LoginHooks + 1] = function()
  if M.Demo() then return end
  freeOrphans()
  ns.SettleDue(ns.Now())
end
