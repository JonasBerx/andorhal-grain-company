local _, ns = ...
if not ns.M then return end

-- The officers' tools' logic (the invite plan and click, the Tonight lists, the whisper; Signups.lua draws them), the
-- soft-reserve Share rules, the raid-day reminder, the invite batch and ns.Demo. Nothing here invites, converts,
-- whispers or shares without a click: InviteClick, ShareClick and Whisper run only from OnClick. A whisper only fills
-- the chat box (GuildSync.OpenWhisper sends nothing); Share only fills the chat box too (ns.OpenChat): the module sends
-- nothing, the player presses Enter. In demo every action is inert. The reminder is one local chat line.

local M, Rules = ns.M, ns.Rules
local DAY, INVITE_PENDING, BATCH_MAX = 86400, 60, 40
local INVITE_KINDS = { primary = true, late = true }
local SHARE_HOLD, CHAT_MAX = 10, 255
local DEMO_LINE = "demo: nothing happens here (demo data)"
local NOT_IN_GROUP = "Join the raid group to share"
local MEMBER_WHY = "Only the raid leader, an assistant or an officer can share this."

local function now() return M.Compat.call("GetServerTime") or 0 end
local function call(...) return M.Compat.call(...) end
local function keyOf(name) return (ns.Key and ns.Key(name)) or string.lower(tostring(name or "")) end
local function noPipes(s) return (string.gsub(tostring(s or ""), "|", "")) end
local function demo() return (M.Demo()) == true or ns.DB().demo == true end

-- The player's group, read at click and render time.
local function groupState()
  local inRaid = call("UnitInRaid", "player") ~= nil
  return {
    inRaid = inRaid, inGroup = inRaid or (call("UnitInParty", "player") and true) or false,
    leader = call("UnitIsGroupLeader", "player") and true or false,
    assist = call("UnitIsGroupAssistant", "player") and true or false,
    partyFull = call("C_PartyInfo.IsPartyFull") and true or false,
  }
end
local function inGroupOf(name) return (call("UnitInParty", name) and true) or call("UnitInRaid", name) ~= nil end

-- An event that starts today (local date) or is running now.
local function tonight(ev, t, dateFn)
  if not ev.start then return false end
  if ev.start <= t and t < (ev.finish or ev.start) then return true end
  return dateFn("%Y-%m-%d", ev.start) == dateFn("%Y-%m-%d", t) and (ev.finish or ev.start) > t
end

-- ---------- invite batch ----------

function ns.SetBatch(n)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > BATCH_MAX then
    return nil, "the invite batch is a whole number from 1 to " .. BATCH_MAX
  end
  ns.DB().batch = n
  return true
end

-- ---------- invite plan (pure) and click ----------

-- inp: { complete, signups, me, batch, now, pending = { [key] = t }, member(name), inGroupOf(name), inRaid, inGroup,
-- leader (leader or assistant), partyFull } -> { kind = "invite", names } | { kind = "convert" } | { kind = "none", why }
function ns.InvitePlan(inp)
  if not inp.complete then return { kind = "none", why = "sign-ups still arriving" } end
  if inp.inGroup and not inp.leader then return { kind = "none", why = "only the group leader or an assistant can invite" } end
  if not inp.inRaid and inp.partyFull then return { kind = "convert" } end
  local pending, t = inp.pending or {}, inp.now or 0
  local used, candidates = 0, {}
  for _, s in ipairs(inp.signups or {}) do
    local name = s.character or ""
    local key = s.key or string.lower(name)
    if name ~= "" and key ~= inp.me then
      local fresh = pending[key] and t - pending[key] < INVITE_PENDING
      if inp.inGroupOf(name) or fresh then
        used = used + 1
      elseif INVITE_KINDS[s.kind] then
        local row = inp.member(name)
        if row and row.online then candidates[#candidates + 1] = row.name or name end
      end
    end
  end
  local limit = inp.batch or 5
  if not inp.inRaid then limit = math.min(limit, 4 - used) end
  if #candidates == 0 then
    return { kind = "none", why = "no one left to invite: every online primary or late sign-up is grouped or invited" }
  end
  if limit <= 0 then return { kind = "none", why = "the party seats are taken or invited: wait for answers" } end
  local names = {}
  for i = 1, math.min(limit, #candidates) do names[i] = candidates[i] end
  return { kind = "invite", names = names }
end

local pending = {} -- key -> time of the invite, this session only

-- One click: read the group, plan, act. With signup (a row's Invite) it plans over that one sign-up with a batch
-- of 1. Returns the result line.
function ns.InviteClick(ev, signup)
  if demo() then return DEMO_LINE end
  local g = groupState()
  local t = now()
  local action = ns.InvitePlan({
    complete = ev.complete, signups = signup and { signup } or ev.signups, me = ns.MyKey(),
    batch = signup and 1 or (ns.DB().batch or 5), now = t, pending = pending,
    member = function(name) return ns.Member(name) end,
    inGroupOf = inGroupOf,
    inRaid = g.inRaid, inGroup = g.inGroup, leader = g.leader or g.assist, partyFull = g.partyFull,
  })
  if action.kind == "convert" then
    -- Report conversion only when the call ran (f1496): ConvertToRaid may be missing or throw.
    if not M.Compat.Try("C_PartyInfo.ConvertToRaid") then
      return "Converting to a raid is not available on this client: convert by hand."
    end
    return "The party is full: converted to a raid. Click again to invite."
  end
  if action.kind ~= "invite" then return action.why end
  -- Only names the client took count as invited (f1473): InviteUnit is optional and may be missing or throw.
  local invited = {}
  for _, name in ipairs(action.names) do
    if M.Compat.Try("C_PartyInfo.InviteUnit", name) then
      invited[#invited + 1] = name
      pending[keyOf(name)] = t
    end
  end
  if #invited == 0 then return "The invite is not available on this client: invite by hand." end
  return "Invited " .. #invited .. ": " .. ns.Escape(table.concat(invited, ", "))
    .. ". The party count cannot see members who did not sign up: if the game refuses invites, click again to"
    .. " convert to a raid."
end

-- ---------- the Tonight lists (pure; Signups.lua draws them for officers) ----------

ns.Tonight = tonight

-- The two Tonight lists of ev for me at t: notIn = online primary and late sign-ups not in my group, not invited in
-- the last minute, not me ({ name, s }); notSigned = online no-answers, not me ({ name }); mayInvite = out of a group,
-- or leader, or assistant. Reads the roster and the group; changes nothing.
function ns.TonightLists(ev, me, t, dateFn) -- dateFn kept for the seam; the caller asks ns.Tonight
  local notIn, notSigned = {}, {}
  for _, s in ipairs(ev.signups or {}) do
    local name = s.character or ""
    local k = s.key or keyOf(name)
    local fresh = pending[k] and t - pending[k] < INVITE_PENDING
    if name ~= "" and INVITE_KINDS[s.kind] and k ~= me and not fresh then
      local row = ns.Member(name)
      if row and row.online and not inGroupOf(name) then notIn[#notIn + 1] = { name = row.name or name, s = s } end
    end
  end
  for _, name in ipairs(ev.noAnswer or {}) do
    local row = ns.Member(name)
    if row and row.online and keyOf(name) ~= me then notSigned[#notSigned + 1] = { name = row.name or name } end
  end
  local g = groupState()
  return { notIn = notIn, notSigned = notSigned, mayInvite = ((not g.inGroup) or g.leader or g.assist) and true or false }
end

-- The whisper: the module's own words plus the title with every | stripped (f1458). Never Escape'd: the player
-- sends what the box holds. Only fills the chat box (OpenWhisper sends nothing); inert in demo.
function ns.Whisper(name, text)
  if demo() then return end
  if ns.OpenWhisper(name, text) ~= "tell" then ns.Say("/w " .. name .. " " .. text) end
end

-- ---------- soft-reserve Share (fills the chat box only; the module sends nothing) ----------

-- Opens the chat box with text (its "/raid " or "/p " prefix switches the box's channel). Both calls are FrameXML
-- and optional apis; true when one ran. Tests replace ns.OpenChat.
function ns.OpenChat(text)
  if M.Compat.Try("ChatFrameUtil.OpenChat", text) then return true end
  return M.Compat.Try("ChatFrame_OpenChat", text) and true or false
end

-- nil when ev has no sr (no row); else true, or false and the why.
function ns.ShareState(ev)
  if not ev or not ev.sr then return nil end
  local g = groupState()
  if not g.inGroup then return false, NOT_IN_GROUP end
  local me = ns.MyKey()
  if g.leader or g.assist or (me and ns.IsOfficer(me)) then return true end
  return false, MEMBER_WHY
end

local lastShare -- when Share last opened the box, this session only

-- One click: nil when the chat box opened, else a line (without "Raids: ") for the caller to say once. Never says
-- anything itself.
function ns.ShareClick(ev)
  if demo() then return DEMO_LINE end
  local on, why = ns.ShareState(ev) -- again at click time: the group may have changed since the draw
  if on == nil then return "this raid has no soft reserve link" end
  if not on then return why end
  local t = now()
  if lastShare and t - lastShare < SHARE_HOLD then return "wait a few seconds before sharing again" end
  local inRaid = groupState().inRaid
  local prefix = inRaid and "/raid " or "/p "
  -- never cut; ns.SrUrl keeps it to 200 printable bytes with no |; escapes in uppercase hex (%f0 -> %F0)
  local url = (string.gsub(ev.sr, "%%(%x%x)", function(h) return "%" .. string.upper(h) end))
  local room = CHAT_MAX - #prefix - #"Soft reserve for " - #": " - #url
  local text = "Soft reserve for " .. ns.Codec.Clean(noPipes(ev.title), math.max(0, room)) .. ": " .. url
  lastShare = t
  if ns.OpenChat(prefix .. text) then return nil end
  return "copy this into " .. (inRaid and "raid" or "party") .. " chat: " .. text
end

-- ---------- raid-day reminder (every member) ----------

-- One line when a team I am on (active or bench) raids today and I have no sign-up; incomplete events are skipped
-- (my sign-up may sit in a part not held yet, f1454).
function ns.ReminderLine(view, meKey, t, dateFn)
  if not meKey or not view then return nil end
  local mine = {}
  for name, team in pairs(view.teams or {}) do
    for _, list in ipairs({ team.active or {}, team.bench or {} }) do
      for _, n in ipairs(list) do if keyOf(n) == meKey then mine[name] = true end end
    end
  end
  local first, more = nil, 0
  for _, ev in ipairs(view.events or {}) do
    if ev.complete and mine[ev.team] and tonight(ev, t, dateFn) and Rules.Status(ev, meKey).state == "none" then
      if first then more = more + 1 else first = ev end
    end
  end
  if not first then return nil end
  return "Raids: your team raids today: " .. ns.Escape(first.title or "?") .. " at " .. dateFn("%H:%M", first.start)
    .. " (" .. ns.Escape(first.team or "?") .. "), and you have not signed up on Discord (Raid-Helper)"
    .. (more > 0 and (" (+" .. more .. " more)") or "") .. "."
end

local reminded = false
M.On("rosterRead", function(partial)
  if partial or reminded then return end
  reminded = true
  local text = ns.ReminderLine(ns.View(), ns.MyKey(), now(), date)
  if text then ns.Say(text) end
end)

-- ---------- demo (pure; R5 wires it) ----------

local DEMO_GUILD = {
  { name = "Borin Ash", class = "Warrior" }, { name = "Cela Moor", class = "Priest" },
  { name = "Dain Holt", class = "Rogue" }, { name = "Edda Frost", class = "Mage" },
  { name = "Fenn Ray", class = "Hunter" }, { name = "Gale Stone", class = "Paladin" },
  { name = "Hal Brook", class = "Warlock" }, { name = "Ivo Pike", class = "Druid" },
  { name = "Jora Venn", class = "Shaman" }, { name = "Kip Lowe", class = "Warrior" },
}
local DEMO_ROLES = { Warrior = "Tank", Priest = "Healer", Paladin = "Healer", Druid = "Healer", Shaman = "Healer",
  Rogue = "Melee DPS", Mage = "Ranged DPS", Hunter = "Ranged DPS", Warlock = "Ranged DPS" }
local DEMO_KINDS = { "primary", "primary", "primary", "late", "tentative", "bench", "absence" }
local DEMO_SR = "https://softres.it/raid/demo"

-- A made-up two-team calendar from guild (a list of { name, class }; built-in names when nil), as records in the
-- store's shape, and its first event. Every time comes from now; no client call. The first event starts at now, so it
-- is this week on any weekday; the others are 2, 7 and 9 days on.
function ns.Demo(guild, t)
  guild = (guild and #guild > 0) and guild or DEMO_GUILD
  local half = math.max(1, math.floor(#guild / 2))
  local teams = { { name = "Team 1", colour = 1, active = {}, bench = {} },
    { name = "Team 2", colour = 2, active = {}, bench = {} } }
  for i, m in ipairs(guild) do
    local team = teams[i <= half and 1 or 2]
    local list = (#team.active < 8) and team.active or team.bench
    list[#list + 1] = m.name
  end
  local titles = { "Molten Core", "Onyxia's Lair", "Blackwing Lair", "Zul'Gurub" }
  local events = {}
  for i, offset in ipairs({ 0, 2, 7, 9 }) do
    local teamNo = (i % 2 == 1) and 1 or 2
    local signups = {}
    for j, m in ipairs(guild) do
      if (j <= half) == (teamNo == 1) then
        signups[#signups + 1] = { character = m.name, discord = "", role = DEMO_ROLES[m.class] or "Melee DPS",
          class = m.class or "", kind = DEMO_KINDS[(j + i) % #DEMO_KINDS + 1] }
      end
    end
    events[i] = { id = "90000000000000000" .. i, team = teams[teamNo].name, title = titles[i],
      start = t + offset * DAY, finish = t + offset * DAY + 3 * 3600, url = "", signups = signups,
      sr = (i == 1) and DEMO_SR or nil }
  end
  local cal = { generatedAt = t, dataAt = t, count = #events, events = events, teams = teams }
  local plan = Rules.Plan(cal, {}, t, "demo")
  local records = {}
  for key, body in pairs(plan and plan.put or {}) do records[key] = { rev = t, hash = "", by = "demo", body = body } end
  return records, events[1]
end

-- Made-up pulls for the demo's tonight raid ev (Molten Core) over the made-up guild list: 5 pulls from start + 14 min,
-- 4 kills and a wipe. Every primary or late sign-up is at every pull but two: the second last joins from the third
-- pull, the last is at none. The first guild member with no sign-up on ev is at every pull. GUIDs are made up.
-- Built in memory only (Pulls.lua's ns.PullList reads it); never saved, never sent.
local DEMO_PULLS = { { 663, "Lucifron", true }, { 664, "Magmadar", true }, { 665, "Gehennas", false },
  { 665, "Gehennas", true }, { 666, "Garr", true } }
local function demoPulls(ev, list)
  if not ev then return {} end
  local guid, onRaid, signed = {}, {}, {}
  for i, m in ipairs(list) do guid[m.name] = string.format("Player-0-DEMO0%03d", i) end
  for _, s in ipairs(ev.signups) do
    onRaid[s.character] = true
    if s.kind == "primary" or s.kind == "late" then signed[#signed + 1] = s.character end
  end
  local unsigned
  for _, m in ipairs(list) do if not onRaid[m.name] then unsigned = m.name break end end
  local pulls = {}
  for i, b in ipairs(DEMO_PULLS) do
    local people = {}
    for j, name in ipairs(signed) do
      if j < #signed - 1 or (j == #signed - 1 and i >= 3) then people[#people + 1] = { guid = guid[name], name = name } end
    end
    if unsigned then people[#people + 1] = { guid = guid[unsigned], name = unsigned } end
    pulls[i] = { at = ev.start + (14 + (i - 1) * 22) * 60, encounterID = b[1], name = b[2], difficultyID = 9,
      groupSize = 40, success = b[3], duration = b[3] and 150 or 95, snapAge = 20, people = people }
  end
  return pulls
end

-- A made-up ready check for the demo's tonight raid ev at t (ReadyView.lua draws it): 2 minutes ago, led by the
-- player when an officer, else by the first made-up sign-up (f6713), one row per primary or late sign-up.
-- The answered rows cycle through four made-up reads (ReadyData ids):
-- no flask with fire res 112, no food, everything with fire res 100, no world buffs; the last two rows did not
-- answer. heard is the number of answered rows; the fire res mark is 100. own is the player's made-up read. Built in
-- memory only; nothing is read from the client's buffs, nothing is sent.
local DEMO_READS = {
  { flask = {}, elixir = { 17538 }, food = { 1248422 }, world = { 22888, 15366 }, fire = 112 },
  { flask = { 17626 }, elixir = { 17538, 17539 }, food = {}, world = { 22888 }, fire = 64 },
  { flask = { 17626 }, elixir = { 17539 }, food = { 1248422 }, world = { 22888, 15366 }, fire = 100 },
  { flask = { 17626 }, elixir = { 17538 }, food = { 1248422 }, world = {}, fire = 31 },
}
local function demoReady(ev, t)
  local me = noPipes(GuildSync.Compat.Plain(call("UnitName", "player")))
  local ready = { checkAt = t - 120, checkLeader = ns.MyKey(), leader = { name = me }, rows = {}, heard = 0, mark = 100,
    own = { flask = {}, elixir = { 17538 }, food = { 1248422 }, world = { 22888, 15366 }, fire = 47 } }
  local signed = {}
  for _, s in ipairs(ev and ev.signups or {}) do
    if s.kind == "primary" or s.kind == "late" then signed[#signed + 1] = s.character end
  end
  local mine = ns.MyKey()
  if not (mine and ns.IsOfficer(mine)) and signed[1] then
    ready.checkLeader, ready.leader = keyOf(signed[1]), { name = signed[1] }
  end
  for i, name in ipairs(signed) do
    local row = { name = name, key = keyOf(name), mine = false, cannot = false }
    if i <= #signed - 2 then
      local r = DEMO_READS[(i - 1) % #DEMO_READS + 1]
      row.report = { flask = r.flask, elixir = r.elixir, food = r.food, world = r.world, fire = r.fire }
      ready.heard = ready.heard + 1
    end
    ready.rows[i] = row
  end
  return ready
end

-- The demo state (Raids.lua's demo field holds the hub's guild and time): records from ns.Demo over the made-up
-- members (sorted by key, so the same guild gives the same calendar), their roster rows, the tonight raid's made-up
-- pulls and its made-up ready check, built on first read and kept in the state. nil when demo is off; empty when the
-- hub has no state for this module.
local DEMO_EMPTY = { records = {}, rows = {}, pulls = {} }
function ns.DemoData()
  local on, st = M.Demo()
  if not on then return nil end
  if type(st) ~= "table" then return DEMO_EMPTY end
  if not st.records then
    local members = type(st.guild) == "table" and type(st.guild.members) == "table" and st.guild.members or {}
    local keys, list, rows = {}, {}, {}
    for k in pairs(members) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local m = members[k]
      if type(m) == "table" and type(m.name) == "string" then
        local cls = tostring(m.class or "")
        list[#list + 1] = { name = m.name, class = string.upper(cls:sub(1, 1)) .. string.lower(cls:sub(2)) }
        local key = ns.Key(m.name)
        if key then rows[key] = { name = m.name, class = m.class, online = m.online and true or false, rankIndex = m.rankIndex } end
      end
    end
    -- never ns.Demo's built-in names: an empty made-up guild gives an empty calendar
    local records, tonightEv = {}, nil
    if #list > 0 then records, tonightEv = ns.Demo(list, tonumber(st.now) or now()) end
    st.records, st.rows, st.pulls = records, rows, demoPulls(tonightEv, list)
    st.ready = demoReady(tonightEv, tonumber(st.now) or now())
  end
  return st
end

-- The hub's demo switch redraws the page (demo data on, the real store off).
M.On("demo", function() M.RefreshPage() end)
