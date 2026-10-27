local _, ns = ...
if not ns.M then return end

-- The ready check (S9 L2, Raids 0.5 Ready): the own read of this character's buffs and fire resistance, on the
-- game's READY_CHECK and on Check my buffs (ns.ReadyCheckMine), the Options (which categories count as missing, the
-- fire resistance mark) and the memory-only state the Ready tab draws (ns.ReadyState). Only the player's own auras
-- are read, never another unit's (d341). Nothing from READY_CHECK's args is read: its initiator is secret in chat
-- lockdown. While /gsync demo is on nothing is read and the state does not change. Never says anything in chat.

local M = ns.M
local Plain = GuildSync.Compat.Plain
local call, Try = M.Compat.call, M.Compat.Try

local FIRE = 2 -- Enum.Damageclass.Fire
local FIRE_RETURN = 2 -- UnitResistance's return shown as the fire resistance (the displayed total, d1245)
local AURAMAX = 255 -- helpful aura indexes read at most; a list this long without its end is not a read

local DEFAULTS = { flask = true, elixir = true, food = true, world = false, fire = 0 }

local function noDrops() return { leader = 0, roster = 0, old = 0, bad = 0 } end

-- Memory only: the own read and when and why it was taken, the check's time and the role at it.
local state = { heard = 0, dropped = noDrops() }

-- A fire resistance the wire carries: an integer in 0-FIREMAX.
local function fireOk(v)
  return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= ns.ReadyRules.FIREMAX
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

-- Whole seconds (the wire carries integers; the game's GetServerTime already is one).
local function now()
  local t = Plain(call("GetServerTime"))
  return type(t) == "number" and math.floor(t) or nil
end

-- The saved Options (GuildSyncRaidsDB.ready), made on first use; a missing or broken field starts at the defaults
-- (pre-launch: no migration).
local function saved()
  local db = ns.DB()
  if type(db.ready) ~= "table" then db.ready = copy(DEFAULTS) end
  return db.ready
end

-- The Options, each key with its default when it is missing or of the wrong type.
function ns.ReadyOptions()
  local opts = saved()
  local out = {}
  for k, d in pairs(DEFAULTS) do
    local v = opts[k]
    if (k == "fire" and fireOk(v)) or (k ~= "fire" and type(v) == "boolean") then out[k] = v
    else out[k] = d end
  end
  return out
end

-- Sets one Option: a category (flask, elixir, food, world) to true or false, or the fire mark to an integer in
-- 0-FIREMAX (0 = off).
function ns.SetReadyOption(key, value)
  if DEFAULTS[key] == nil then return nil, "unknown option" end
  if key == "fire" then
    if not fireOk(value) then
      return nil, "the fire resistance mark is a whole number from 0 to " .. ns.ReadyRules.FIREMAX
    end
  elseif type(value) ~= "boolean" then
    return nil, "not true or false"
  end
  saved()[key] = value
  return true
end

-- The own read, all or nothing: { flask, elixir, food, world = {id}, fire = n }, or nil and why ("demo", "combat",
-- "secret", "no api", "incomplete"). Only a plain false from InCombatLockdown, ShouldAurasBeSecret and each index's
-- ShouldUnitAuraIndexBeSecret lets the read go on; a secret, a throw, a missing call, a non-table aura or the
-- AURAMAX cap gives no read, never a partial one.
function ns.ReadOwn()
  if M.Demo() then return nil, "demo" end
  if call("InCombatLockdown") ~= false then return nil, "combat" end
  local good, hidden = Try("C_Secrets.ShouldAurasBeSecret")
  if not good or hidden ~= false then return nil, "secret" end
  local r = { Try("UnitResistance", "player", FIRE) }
  if not r[1] then return nil, "no api" end
  local fire = r[1 + FIRE_RETURN]
  if type(fire) ~= "number" or fire ~= math.floor(fire) then return nil, "secret" end
  local ids = {}
  for i = 1, AURAMAX do
    local okIndex, secret = Try("C_Secrets.ShouldUnitAuraIndexBeSecret", "player", i, "HELPFUL")
    if not okIndex or secret ~= false then return nil, "secret" end
    local okAura, aura = Try("C_UnitAuras.GetAuraDataByIndex", "player", i, "HELPFUL")
    if not okAura then return nil, "no api" end
    if aura == nil then
      local read = ns.ReadyRules.Classify(ids, ns.ReadyData)
      read.fire = fire
      return read
    end
    if type(aura) ~= "table" then return nil, "no api" end
    local id = Plain(aura.spellId)
    if type(id) ~= "number" then return nil, "secret" end
    ids[#ids + 1] = id
  end
  return nil, "incomplete"
end

-- Reads and keeps the result (a failed read keeps no read), with its time and what asked for it.
local function take(by)
  local read, why = ns.ReadOwn()
  state.own, state.why, state.ownBy, state.ownAt = read, why, by, now()
  return read, why
end

-- Check my buffs: reads again, sends nothing.
function ns.ReadyCheckMine()
  if M.Demo() then return nil, "demo" end
  return take("check")
end

-- Leader or assistant: a plain true from either call.
local function leads(unit)
  return call("UnitIsGroupLeader", unit) == true or call("UnitIsGroupAssistant", unit) == true
end

local function inRaid() return call("UnitInRaid", "player") ~= nil end

-- ---------- the raid: its leader, its roster ----------

local RAID = {}
for i = 1, 40 do RAID[i] = "raid" .. i end

-- The wire key of the raid unit's two plain name parts and the name ("First Second"), or nil.
local function unitKey(unit)
  local first, second = call("UnitName", unit)
  if type(first) ~= "string" or type(second) ~= "string" then return nil end
  local name = first .. " " .. second
  return ns.Key(name), name
end

-- The one leader key and name (f4, f6705): the raid unit for which UnitIsGroupLeader answers plain true, both name
-- parts plain.
local function leaderKey()
  for _, unit in ipairs(RAID) do
    if call("UnitIsGroupLeader", unit) == true then return unitKey(unit) end
  end
  return nil
end

-- true when from is the key of a raid unit that is the leader or an assistant (plain true).
local function askerLeads(from)
  for _, unit in ipairs(RAID) do
    if leads(unit) and unitKey(unit) == from then return true end
  end
  return false
end

-- Only a leader or assistant (live) reads raid1-40, out of combat, through PullRules.Snapshot (d1233). A nil
-- snapshot (a secret or missing part) keeps the last roster.
local function readRoster()
  if call("InCombatLockdown") ~= false or not leads("player") then return end
  local reads = {}
  for i, unit in ipairs(RAID) do
    local exists = call("UnitExists", unit)
    local r = { exists = exists }
    if exists == true then
      r.guid = call("UnitGUID", unit)
      r.first, r.second = call("UnitName", unit)
    end
    reads[i] = r
  end
  local people = ns.PullRules.Snapshot(reads)
  if people then state.roster = people end
end

-- ---------- the report domain raids_r ----------

local ID = "raids_r"
local lastAnswer, rosterDirty, refreshing

-- One pending page refresh, only while the Ready tab is chosen (Store.lua's refreshSoon).
local function refreshSoon()
  if refreshing then return end
  refreshing = true
  M.After(1, function()
    refreshing = false
    if ns.PageState and ns.PageState.tab == "ready" then M.RefreshPage() end
  end)
end

-- Sends one raids_r message: nil when queued, else why. Never in demo, in combat or outside a raid; the leader key
-- must be known; a closed gate keeps the why for the tab and sends nothing.
local function send(msg, priority)
  if M.Demo() then return "demo" end
  if call("InCombatLockdown") ~= false then return "combat" end
  if not inRaid() then return "not in a raid" end
  if not msg.leader then return "no raid leader known" end
  local open, why = M.Comm.Gate(ID)
  if not open then
    state.gateWhy = why
    return why
  end
  local okSend, whySend = M.Comm.Send(ID, msg, priority)
  if not okSend then return tostring(whySend) end
  return nil
end

-- The own read as a report for leader at time at ("own"); sets lastAnswer when it goes. A fire resistance outside
-- 0-FIREMAX is never packed (no receiver would accept it).
local function report(read, at, leader)
  if read.fire < 0 or read.fire > ns.ReadyRules.FIREMAX then return "fire resistance out of range" end
  local why = send({ t = "Y", key = ns.MyKey(), at = at, leader = leader, flask = read.flask, elixir = read.elixir,
    food = read.food, world = read.world, fire = read.fire }, "own")
  if not why then
    lastAnswer, state.sent = at, true
  end
  state.sentWhy = why
  return why
end

-- A new check (READY_CHECK, Ask again): the leader recorded now, the counts from zero.
local function newCheck()
  state.checkLeader, state.leaderName = leaderKey()
  state.heard, state.dropped = 0, noDrops()
end

-- The hub runs unpack first: a refused text counts as bad. ReadyRules.Unpack is looked up at call time; a throw
-- goes to the hub, which records it under Raids.
local function unpackReport(logical)
  local msg = ns.ReadyRules.Unpack(logical, ns.Key)
  if msg == nil then state.dropped.bad = state.dropped.bad + 1 end
  return msg
end

-- true when key is on the roster, or no roster is known (S2-f2).
local function onRoster(key)
  if type(state.roster) ~= "table" then return true end
  for _, p in ipairs(state.roster) do
    if ns.Key(p.name) == key then return true end
  end
  return false
end

-- Y: every guild client hears it; kept only in a raid, for the recorded leader, from checkAt - SINCE on, never more
-- than Wire.FUTURE (300 s) past now (S2-f1). The newest report (by its time) per member wins; heard counts only
-- roster keys when a roster is known (S2-f2).
local function onReport(msg)
  if not inRaid() then return end
  local t = now()
  if type(t) ~= "number" or msg.at > t + 300 then
    state.dropped.bad = state.dropped.bad + 1
    return
  end
  if msg.leader ~= state.checkLeader then
    state.dropped.leader = state.dropped.leader + 1
    return
  end
  if type(state.checkAt) ~= "number" or msg.at < state.checkAt - ns.ReadyRules.SINCE then
    state.dropped.old = state.dropped.old + 1
    return
  end
  if onRoster(msg.key) then state.heard = state.heard + 1 end
  state.reports = state.reports or {}
  local old = state.reports[msg.key]
  if not old or msg.at >= old.at then state.reports[msg.key] = msg end
  refreshSoon()
end

-- A: answered once with a fresh read, in a raid, out of combat, when the asker leads this raid, at most once per
-- ASKHOLD.
local function onAsk(_, from)
  if M.Demo() or not inRaid() or call("InCombatLockdown") ~= false or not askerLeads(from) then return end
  local t = now()
  if type(t) ~= "number" or (lastAnswer and t - lastAnswer < ns.ReadyRules.ASKHOLD) then return end
  local read = take("ready")
  if read then report(read, t, leaderKey()) end
end

-- Ask again (leader or assistant): re-records the leader and askAt (and checkAt from it when no check was seen,
-- f6708), re-reads the own buffs, sends one ask. nil when sent, else why.
function ns.ReadyAsk()
  if M.Demo() then return "demo" end
  if not inRaid() then return "not in a raid" end
  if not leads("player") then return "only the raid leader or an assistant can ask" end
  newCheck()
  state.askAt = now()
  if type(state.checkAt) ~= "number" then state.checkAt = state.askAt end
  take("ready")
  return send({ t = "A", by = ns.MyKey(), at = state.askAt, leader = state.checkLeader }, "user")
end

-- READY_CHECK and GROUP_ROSTER_UPDATE (called through M.Safe by Raids.lua). The event's args are never read.
function ns.OnReadyEvent(event)
  if M.Demo() then return end
  if event == "READY_CHECK" then
    state.checkAt = now()
    state.role = (inRaid() and leads("player")) and "leader" or "raider"
    state.sent, state.sentWhy, state.gateWhy = false, nil, nil
    newCheck()
    readRoster()
    local read = take("ready")
    if read and type(state.checkAt) == "number" then report(read, state.checkAt, state.checkLeader) end
  elseif event == "GROUP_ROSTER_UPDATE" then
    if not inRaid() then -- left the raid: its roster and reports go
      state.roster, state.reports = nil, nil
      return
    end
    if rosterDirty then return end
    rosterDirty = true -- read at most once a second
    M.After(1, function()
      rosterDirty = false
      if not M.Demo() and inRaid() then readRoster() end
    end)
  end
end

-- A copy of the state, for the Ready tab and the tests, with the table's rows and dropped.roster.
function ns.ReadyState()
  local out = copy(state)
  local rows, lost = ns.ReadyRules.Table(state.roster, state.reports, state.checkAt, state.checkLeader,
    { read = state.own }, Plain(call("UnitGUID", "player")))
  out.rows, out.dropped.roster = copy(rows), lost
  return out
end

local pull = {}
function pull.pack(msg) return ns.ReadyRules.Pack(msg) end
function pull.subject(msg)
  if type(msg) ~= "table" then return nil end
  if msg.t == "Y" then return msg.key, msg.at end
  if msg.t == "A" then return "ask", msg.at end
  return nil
end
function pull.build() return nil end -- this domain only sends: nothing is asked for or rebuilt
function pull.stillWanted() return false end

local okDomain, whyDomain = M.Comm.Register({ id = ID, prefix = "GSync", audience = "guild", owner = "self",
  maxChunks = ns.ReadyRules.MAXCHUNKS, kinds = { Y = { rule = "put" }, A = { rule = "action" } },
  actions = { A = { actor = "sender", field = "by" } }, unpack = unpackReport, handle = { Y = onReport, A = onAsk } })
if okDomain then okDomain, whyDomain = M.Sync.Pull(ID, pull) end
if not okDomain then state.domainWhy = tostring(whyDomain) end
