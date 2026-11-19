-- GuildKOS RulesKills: when your own kill of a Kill on Sight target pays grain (issue 8, o14/d10). The game says who
-- landed the killing blow (PARTY_KILL), so no officer confirms the kill; caps and a few checks keep it from being a
-- farm. Officers set the reward and the caps for the guild (d23-d24: the kos_h settings record, RulesRecords
-- SETTINGS_RANGE); with no record held the defaults below apply. Pure Lua 5.1, no client calls: time, the week, the
-- settings and every record come in.
local _, ns = ...
local Kills = {}
ns.RulesKills = Kills

Kills.REWARD = 100     -- default grain a paid kill
Kills.WEEK_CAP = 5     -- default paid kills per account per week (RulesBoard.Week: Monday 00:00 UTC)
Kills.PER_TARGET = 1   -- default paid kills of one target per account per week
Kills.KEEP_WEEKS = 5   -- weeks of ledger kept

-- The choices the officers' options offer (Hub.lua); any whole number in RulesRecords.SETTINGS_RANGE is valid.
Kills.CHOICES = {
  reward = { 0, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000 },
  weekCap = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 15, 20 },
  perTarget = { 1, 2, 3 },
}

-- Kills.Settings(rec) -> { reward, weekCap, perTarget }: the held settings record's numbers, the defaults for any
-- field that is missing or outside its range (a held record passed Parse, so this only guards the defaults).
function Kills.Settings(rec)
  local range = ns.RulesRecords.SETTINGS_RANGE
  local out = { reward = Kills.REWARD, weekCap = Kills.WEEK_CAP, perTarget = Kills.PER_TARGET }
  if type(rec) ~= "table" then return out end
  for name, r in pairs(range) do
    local n = rec[name]
    if type(n) == "number" and n == math.floor(n) and n >= r[1] and n <= r[2] then out[name] = n end
  end
  return out
end

-- Kills.Id(victim, t) -> the ledger key of one kill.
function Kills.Id(victim, t)
  return tostring(victim) .. "/" .. tostring(t)
end

-- Kills.Judge(k) -> "pay" | "skip", why | "refuse", why. "skip" says nothing; "refuse" gets Kills.Line(why).
-- k = { mine (the killing blow is yours or your pet's), instance, target (the held kos record or nil/false), victim,
--   t, week, me = { [key] = true } (this account's characters; empty while the roster is unread), paid (the ledger),
--   cfg (Kills.Settings; the defaults when nil), all (every paid entry of the account, any guild, for the caps;
--   paid when nil) }. The caps count over all: the Games purse is the account's, so an account in two guilds shares
--   one week (review f2), and the most kill grain a week stays the top reward x the top weekly cap.
-- Only open targets pay, open (decidedAt, else markedAt) at or before the kill, marked by none of this account's characters,
-- cfg.perTarget per target a week and cfg.weekCap a week in all. A reward or weekly cap of 0 turns kill grain off.
function Kills.Judge(k)
  local cfg = k.cfg or Kills.Settings(nil)
  if type(k.t) ~= "number" or type(k.week) ~= "number" then return "skip", "clock" end
  if not k.mine then return "skip", "attacker" end
  if k.instance then return "skip", "instance" end
  local rec = k.target
  if type(rec) ~= "table" or rec.status ~= "open" then return "skip", "target" end
  if cfg.reward <= 0 or cfg.weekCap <= 0 then return "skip", "off" end
  local paid = type(k.paid) == "table" and k.paid or {}
  if paid[Kills.Id(k.victim, k.t)] ~= nil then return "skip", "paid" end
  if type(k.me) ~= "table" or next(k.me) == nil then return "refuse", "roster" end
  -- when the target opened: an approved member mark carries decidedAt; an officer's own mark (and a name entry it
  -- links) is open from markedAt, with no decidedAt (Mark.lua FromTarget, FromName; as RulesMarks.MayAutoLink)
  local opened = tonumber(rec.decidedAt) or tonumber(rec.markedAt)
  if not opened or opened > k.t then return "refuse", "early" end
  if type(rec.markedBy) == "string" and k.me[rec.markedBy] then return "refuse", "marker" end
  local n, same = 0, 0
  for _, e in pairs(type(k.all) == "table" and k.all or paid) do
    if type(e) == "table" and e.week == k.week then
      if e.victim == k.victim then same = same + 1 end
      n = n + 1
    end
  end
  if same >= cfg.perTarget then return "refuse", "again" end
  if n >= cfg.weekCap then return "refuse", "week" end
  return "pay"
end

-- Kills.Prune(paid, week): drops entries more than KEEP_WEEKS - 1 weeks before week, and anything malformed.
function Kills.Prune(paid, week)
  if type(paid) ~= "table" or type(week) ~= "number" then return end
  for id, e in pairs(paid) do
    if type(e) ~= "table" or type(e.week) ~= "number" or e.week <= week - Kills.KEEP_WEEKS then paid[id] = nil end
  end
end

-- Kills.Line(why, name, cfg) -> the chat line for a paid kill ("paid") or for why it paid nothing. name is
-- display-safe; cfg is Kills.Settings (the defaults when nil). "paid" names cfg.reward.
function Kills.Line(why, name, cfg)
  cfg = cfg or Kills.Settings(nil)
  local head = "KOS: You killed " .. name .. ". "
  if why == "paid" then return head .. "+" .. cfg.reward .. " grain." end
  if why == "again" then
    local n = cfg.perTarget == 1 and "one paid kill" or (cfg.perTarget .. " paid kills")
    return head .. "No grain: " .. n .. " of " .. name .. " a week."
  end
  if why == "week" then
    return head .. "No grain: " .. cfg.weekCap .. " paid kill" .. (cfg.weekCap == 1 and "" or "s")
      .. " this week already."
  end
  if why == "marker" then return head .. "No grain: you marked " .. name .. " yourself." end
  if why == "early" then return head .. "No grain: the kill came before an officer approved the mark." end
  if why == "roster" then return head .. "No grain: the guild roster is not read yet." end
  if why == "no purse" then return head .. "Grain needs the Games addon." end
  return head .. "The grain could not be paid right now."
end

-- Kills.SettingsLine(cfg) -> one line naming the guild's kill grain numbers (Kill.SetSetting's confirm and its line).
function Kills.SettingsLine(cfg)
  cfg = cfg or Kills.Settings(nil)
  if cfg.reward <= 0 or cfg.weekCap <= 0 then return "Kill grain is off." end
  return "Kill grain: " .. cfg.reward .. " a kill, " .. cfg.weekCap .. " paid kill" .. (cfg.weekCap == 1 and "" or "s")
    .. " a week per account, " .. cfg.perTarget .. " of each target a week."
end

return Kills
