-- GuildKOS Kill: grain for your own kill of an open Kill on Sight target (issue 8, o14/d10). Core's dispatcher calls
-- Kill.OnPartyKill(attacker, victim) with both GUIDs already plain (a secret reaches here as nil). The rules are
-- ns.RulesKills; this file reads the client through ns.Hub, keeps the ledger and pays through the hub purse.
-- The ledger is GuildKOSDB.guilds[guild].paid = { [RulesKills.Id] = { victim, week, at, hunter, amount } }: GuildKOSDB is
-- account-wide, so every character on the account shares the caps. Pay-once (as the Games lottery, S13): the entry
-- is written before the credit and removed when the credit does not answer true, so a payout can be lost, never paid
-- twice. The pay stays on this client. The kill is shared (issue 44, d78): every own kill of an open target, paid or
-- not, becomes a claim in the own kos_m record (Store.WriteOwn), which the hub's sync rounds carry; nothing is sent here.
local _, ns = ...
local Kill = {}
ns.Kill = Kill

local SKULL = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"

local function call(...) if ns.Hub then return ns.Hub.Call(...) end end

local function addChars(set, list)
  for _, ch in ipairs(type(list) == "table" and list or {}) do
    if type(ch) == "table" and type(ch.key) == "string" then set[ch.key] = true end
  end
end

-- me (the own key) and this account's characters in this guild as a set of member keys: the own key,
-- M.MyCharacters and the own person (GuildSync.Comm.Person; on its own client an account's characters are one
-- person), both through ns.Hub. me is nil and the set empty before the roster read.
local function myKeys()
  local set = {}
  local ok, me = pcall(ns.Hub.MyKey)
  if not ok or type(me) ~= "string" then return nil, set end
  set[me] = true
  local good, chars = pcall(ns.Hub.MyCharacters)
  if good then addChars(set, chars) end
  local fine, person = pcall(ns.Hub.Person, me)
  if fine and type(person) == "table" then addChars(set, person.chars) end
  return me, set
end

-- Every guild's ledger on this account, for the caps (review f2: the purse is the account's), pruned when prune.
local function accountPaid(week, prune)
  local all = {}
  local guilds = ns.Core.DB().guilds
  for gk, gg in pairs(type(guilds) == "table" and guilds or {}) do
    if type(gg) == "table" and type(gg.paid) == "table" then
      if prune then ns.RulesKills.Prune(gg.paid, week) end
      for pid, e in pairs(gg.paid) do all[tostring(gk) .. "|" .. pid] = e end
    end
  end
  return all
end

-- The kill as a claim in the own kos_m record (d78): { time, victim, zone }, the newest RulesKills.CLAIMS kept.
local function share(victim, t)
  local zone = call("GetZoneText")
  zone = type(zone) == "string" and ns.RulesRecords.Safe(zone, ns.RulesRecords.CAPS.zone) or ""
  local claim = { time = t, victim = victim, zone = zone ~= "" and zone or nil }
  ns.Store.WriteOwn(function(r) r.claims = ns.RulesKills.AddClaim(r.claims, claim) end, t)
end

function Kill.OnPartyKill(attacker, victim)
  if not ns.Hub or ns.Hub.InDemo() then return end
  if type(attacker) ~= "string" or type(victim) ~= "string" then return end
  local pet = call("UnitGUID", "pet")
  local mine = attacker == call("UnitGUID", "player") or (type(pet) == "string" and attacker == pet)
  if not mine then return end
  -- most killing blows are on mobs and unlisted players: nothing more is read or written for them
  local target = ns.Store.Target(victim)
  if type(target) ~= "table" or target.status ~= "open" then return end
  local t = math.floor(ns.Core.Now())
  -- shared whether or not it pays (a cap refusal still shares); a failed write never stops the pay
  pcall(share, victim, t)
  local g = ns.Core.Guild()
  if not g then return end
  if type(g.paid) ~= "table" then g.paid = {} end
  local K = ns.RulesKills
  local week = ns.RulesBoard.Week(t)
  local all = accountPaid(week, true)
  local me, set = myKeys()
  -- the officers' numbers for the guild, read at the kill (d23-d24); the defaults while no settings record is held
  local cfg = K.Settings(ns.Store.Settings())
  local verdict, why = K.Judge({ mine = true, instance = call("IsInInstance") == true, target = target,
    victim = victim, t = t, week = week, me = set, paid = g.paid, cfg = cfg, all = all })
  if verdict == "skip" then return end
  local shown = ns.Hub.Escape(target.name or "?")
  if verdict ~= "pay" then
    print(K.Line(why, shown, cfg))
    -- issue 44 s5: the weekly cap's refusal also toasts, once a week for the account (GuildKOSDB is account-wide)
    local db = ns.Core.DB()
    if why == "week" and db.capToastWeek ~= week then
      db.capToastWeek = week
      ns.Hub.Toast({ title = "Kill on Sight", text = K.CapToast(cfg), icon = SKULL })
    end
    return
  end
  local left = math.max(0, K.Week(all, week, cfg).left - 1)   -- after this kill
  local id = K.Id(victim, t)
  g.paid[id] = { victim = victim, week = week, at = t, hunter = me, amount = cfg.reward }
  local good, refused = ns.Hub.Credit(cfg.reward)
  if good ~= true then
    g.paid[id] = nil
    print(K.Line(refused == "no purse" and "no purse" or "failed", shown, cfg))
    return
  end
  print(K.Line("paid", shown, cfg))
  ns.Hub.Toast({ title = "Kill on Sight", text = tostring(target.name or "?") .. ": +" .. cfg.reward .. " grain"
    .. " \194\183 " .. left .. " left this week", icon = SKULL })
end

-- Kill.Week() -> RulesKills.Week's sum for this week over every guild's ledger on this account, and the guild's
-- settings (issue 44 s5, the List's strip). Reads only: nothing is pruned, written or sent.
function Kill.Week()
  local week = ns.RulesBoard.Week(math.floor(ns.Core.Now()))
  local cfg = Kill.Settings()
  return ns.RulesKills.Week(accountPaid(week, false), week, cfg), cfg
end

-- Kill.Recent(victim) -> RulesKills.Recent over every kos_m record held, now = Core.Now(): { { hunter, at }, ... }
-- newest first (issue 44, d78; the List's cards). {} before the store is ready, and on any error.
function Kill.Recent(victim)
  local good, out = pcall(function()
    if not (ns.Store and ns.Store.Ready()) then return {} end
    return ns.RulesKills.Recent(ns.Store.Members(), victim, ns.Core.Now())
  end)
  return good and type(out) == "table" and out or {}
end

-- ---------- the officers' settings (d23-d25) ----------

-- Kill.Settings() -> { reward, weekCap, perTarget }: the guild's numbers as a kill reads them.
function Kill.Settings()
  return ns.RulesKills.Settings(ns.Store and ns.Store.Settings() or nil)
end

-- Changes asked for within WINDOW seconds of each other (the Options panel's Defaults button sets all three at once,
-- review f1) are asked about in one confirm; a refusal line prints at most once per QUIET seconds.
local WINDOW, QUIET = 2, 5
local pending, pendingAt, refusedAt = nil, nil, nil

-- Writes want for the guild after the officer's OK; the officer gate is checked again at the click.
local function apply(want)
  local can, why = ns.Store.CanWriteOfficer()
  if not can then return nil, why end
  local t = math.floor(ns.Core.Now())
  local done, bad = ns.Store.WriteSettings({ reward = want.reward, weekCap = want.weekCap, perTarget = want.perTarget,
    setAt = t }, t)
  if not done then
    print("KOS: The kill grain settings could not be saved (" .. tostring(bad) .. ").")
    return nil, bad
  end
  print("KOS: " .. ns.RulesKills.SettingsLine(want))
  return true
end

-- Kill.SetSetting(name, value): an officer asks to change one number for the guild (the others stay). Nothing is
-- written until the officer confirms; the confirm names only what changed (issue 44 s8, RulesKills.Changes), so a
-- Defaults reset can be cancelled; no change asks nothing.
-- Anyone else gets one line saying why not. -> true, "asked" | true (no change) | nil, why
function Kill.SetSetting(name, value)
  local range = ns.RulesRecords.SETTINGS_RANGE[name]
  if not range or type(value) ~= "number" then return nil, "args" end
  local now = ns.Core.Now()
  local can, why = ns.Store.CanWriteOfficer()
  if not can then
    if not refusedAt or now - refusedAt >= QUIET then
      refusedAt = now
      if why == "officer" then print("KOS: Only officers set the kill grain for the guild.")
      elseif why == "roster" then print("KOS: The guild roster is not read yet; try again in a moment.") end
    end
    return nil, why
  end
  if not pending or not pendingAt or now - pendingAt > WINDOW then pending = {} end
  pendingAt = now
  pending[name] = value
  local cfg = Kill.Settings()
  local want = { reward = cfg.reward, weekCap = cfg.weekCap, perTarget = cfg.perTarget }
  for k, v in pairs(pending) do want[k] = v end
  local changes = ns.RulesKills.Changes(cfg, want)
  if not changes then return true end
  local text = "Change the kill grain for the whole guild?\n" .. changes
  local asked = ns.Hub.Confirm("killgrain", text, "Change", function()
    pending = nil
    apply(want)
  end)
  if not asked then return nil, "confirm" end
  return true, "asked"
end

return Kill
