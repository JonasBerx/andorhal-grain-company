-- GuildKOS Confirm: officers' decisions on confirmed kills (R6 Task G1; spec AC25, AC31). Every write goes through
-- ns.Store.WriteHunter / WriteTarget, which gate it (roster, demo, officer) and shape it. A claim id is (member key,
-- kill time, victim GUID).
local _, ns = ...
local Confirm = {}
ns.Confirm = Confirm

-- Confirm.Strike(memberKey, time, victimGuid, now) -> true | nil, why. The officer gate comes before any lookup. The
-- hunter record drops the kill, total - 1; when the struck kill was the only kept kill of its week and that week is
-- at or after since, since moves to the week after. The held target lists { hunter, time } in rejected.
function Confirm.Strike(memberKey, time, victimGuid, now)
  local can, why = ns.Store.CanWriteOfficer()
  if not can then return nil, why end
  if type(memberKey) ~= "string" or type(time) ~= "number" or type(victimGuid) ~= "string"
    or type(now) ~= "number" then
    return nil, "args"
  end
  local held = ns.Store.Hunter(memberKey)
  if type(held) ~= "table" then return nil, "hunter" end
  local B = ns.RulesBoard
  local kept, struck = {}, nil
  for _, k in ipairs(type(held.kills) == "table" and held.kills or {}) do
    if not struck and k.time == time and k.victim == victimGuid then
      struck = B.Week(time)
    else
      kept[#kept + 1] = { time = k.time, victim = k.victim, officer = k.officer }
    end
  end
  if not struck then return nil, "kill" end
  local since = tonumber(held.since)
  if since and struck >= since then
    local other = false
    for _, k in ipairs(kept) do
      if B.Week(k.time) == struck then other = true end
    end
    if not other then since = struck + 1 end
  end
  local t = math.floor(now)
  local total = math.max((tonumber(held.total) or 0) - 1, 0)
  local hunterRec = { total = total, best = held.best, since = since, kills = kept }
  local target = ns.Store.Target(victimGuid)
  local rec
  if type(target) == "table" then
    rec = {}
    for k, v in pairs(target) do rec[k] = v end
    for _, list in ipairs({ "kills", "rejected" }) do
      local out = {}
      for i, e in ipairs(target[list] or {}) do out[i] = { hunter = e.hunter, time = e.time } end
      rec[list] = out
    end
    rec.rejected[#rec.rejected + 1] = { hunter = memberKey, time = time }
  end
  -- both writes are checked with Store's own CanWrite before either is made (f5435, f5448): a refused target write
  -- (settle, status or the open cap) leaves the hunter record as it was
  local R = ns.RulesRecords
  local ok, bad = ns.Store.CanWrite("kos_h", (R.HunterKey(memberKey)), hunterRec, t)
  if not ok then return nil, bad end
  if rec then
    ok, bad = ns.Store.CanWrite("kos", (R.TargetKey(victimGuid)), rec, t)
    if not ok then return nil, bad end
  end
  local done, why2 = ns.Store.WriteHunter(memberKey, hunterRec, t)
  if not done then return nil, why2 end
  if not rec then return true end
  return ns.Store.WriteTarget(victimGuid, rec, t)
end
