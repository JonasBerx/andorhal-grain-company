-- GuildSyncRaids: the guild's raid calendar (Raid-Helper) in the GuildSync window. An officer pastes the string the
-- website's /officers/ "Copy for the game" builds; the module shares it on GuildSync's comms (domain "raids") and every
-- member sees the raids, sign-ups and team lists read-only. This file is the host: it registers the module, captures
-- the GuildSync reads the other files use, owns the SavedVariable and the slash command.
-- Files (TOC order): Raids (host), Decode (GSR1 decoder), Codec (record bodies), Rules (pure rules), Store (domain,
-- share), Page (the Raids page), RaidList, RaidView, Signups, Paste (its cards), Tools (officers' tools, reminder,
-- demo).

local _, ns = ...

-- Delegates are looked up at call time: later files define them, and a test may replace them.
local function slash(rest) if ns.Slash then ns.Slash(rest) end end

local M = GuildSync and GuildSync.RegisterModule({
  id = "raids",
  title = "Raids",
  version = "0.3",
  needs = 3,
  page = {
    title = "Raids",
    icon = "Interface\\Icons\\INV_Misc_Book_11",
    build = function(frame) if ns.BuildPage then ns.BuildPage(frame) end end,
    refresh = function(frame) if ns.RefreshPage then ns.RefreshPage(frame) end end,
  },
  slash = slash,
  selftest = function()
    if not ns.Selftest then return "wait", "not ready" end
    return ns.Selftest()
  end,
  status = function()
    if not ns.Status then return "no raid data yet" end
    return ns.Status()
  end,
  onLogin = function() if ns.Login then ns.Login() end end,
  -- /gsync demo: the hub's made-up guild and its time; Tools.lua builds the calendar from them on first read
  -- (ns.DemoData), so a call made while this file registers still works. Never saved, never sent.
  demo = function(guild, now) return { guild = guild, now = now } end,
  apis = { "GetServerTime", optional = { "C_PartyInfo.InviteUnit", "C_PartyInfo.ConvertToRaid",
    "C_PartyInfo.IsPartyFull", "UnitInParty", "UnitInRaid", "UnitIsGroupLeader", "UnitIsGroupAssistant",
    "ChatFrameUtil.OpenChat", "ChatFrame_OpenChat" } },
  -- The invite batch in Options. get reads the SavedVariable directly and writes nothing (it may run before the
  -- files ran); set goes through ns.SetBatch, looked up at call time.
  settings = function(S)
    local values = {}
    for n = 1, 40 do values[n] = { n, tostring(n) } end
    S.Dropdown("batch", "Raids: invite batch", 5, values,
      function()
        local db = GuildSyncRaidsDB
        if type(db) == "table" and db.v == 1 then return db.batch end
        return nil
      end,
      function(v) if ns.SetBatch then ns.SetBatch(v) end end,
      "How many invites one click on the invite button sends.")
  end,
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code

-- The reads this addon uses, captured once right after the guard (API.md: capture what you need at load).
ns.Say, ns.Escape, ns.OpenWhisper = GuildSync.Say, GuildSync.Escape, GuildSync.OpenWhisper
ns.Roster, ns.Member, ns.Key = GuildSync.Comm.Roster, GuildSync.Comm.Member, GuildSync.Comm.Key
ns.MyKey, ns.IsOfficer = GuildSync.Comm.MyKey, GuildSync.Comm.IsOfficer

-- In demo the roster reads answer from the made-up guild (the player's own rank stays the real one: IsOfficer).
local realRoster, realMember = ns.Roster, ns.Member
function ns.Roster()
  local d = ns.DemoData and ns.DemoData()
  if d then return d.rows, false, 0, true end
  return realRoster()
end
function ns.Member(name)
  local d = ns.DemoData and ns.DemoData()
  if not d then return realMember(name) end
  local r = type(name) == "string" and d.rows[ns.Key(name) or ""]
  return r and { name = r.name, class = r.class, online = r.online, rankIndex = r.rankIndex } or nil
end

local function say(text) ns.Say("Raids: " .. text) end

-- The saved data, bound lazily: the SavedVariable is set only after the files ran. A missing or other version
-- starts empty (nothing to migrate).
function ns.DB()
  local db = GuildSyncRaidsDB
  if type(db) ~= "table" or db.v ~= 1 then
    db = { v = 1, records = {}, gone = {}, batch = 5 }
    GuildSyncRaidsDB = db
  end
  return db
end

-- /gsraids (and /gsync raids ...): open the page, or set the invite batch.
function ns.Slash(rest)
  local cmd, arg = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "" then
    M.OpenPage()
  elseif cmd == "batch" and ns.SetBatch then
    local okBatch, why = ns.SetBatch(tonumber(arg))
    if okBatch then say("invite batch set to " .. tostring(tonumber(arg))) else say(tostring(why)) end
  else
    say("/gsraids opens the page; /gsraids batch <1-40> sets how many invites one click sends")
  end
end

SLASH_GSRAIDS1 = "/gsraids"
SlashCmdList.GSRAIDS = function(msg) M.Safe(slash, msg) end
