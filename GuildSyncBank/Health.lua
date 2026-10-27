-- GuildSyncBank selftest and status (brief J22 as the UI slice adapts it, B4, D11, H18, J23).
--   ns.Health.SelfTest() -> "pass" | "wait" | "fail", text   from ns.Data(now, true): live, never demo
--   ns.Health.Status() -> line                                one line, no newline
-- WAIT before the roster is read, while the roster is partial, or while no rank names were read this session and no saved bank-character set
-- exists; FAIL when this character has the Banker rank but does not count as officer; PASS with the number of holders,
-- open requisitions and open requests, plus "guild bank: not readable" and "mail: not readable" when so. t42 (V4): FAIL
-- "domain <id> not attached: <why>"; PASS lines "cut: <holder>", "N own records held by other officers (/gsbank
-- adopt)", and "waiting for the full guild roster" or else "catching up with the other officers" when so (f5314). t58:
-- "N items running low" (view.low, V5) and "more than 6 bank characters: some bank records may arrive late" (d1091).

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Health = {}
ns.Health = Health

local OWN_FAMILIES = { "l", "t", "a", "q", "n" } -- the officer families a stash can hold (d784, d1077)

local function plain(v) return GuildSync.Compat.Plain(v) end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

function Health.SelfTest()
  local _, partial, _, known = GuildSync.Comm.Roster()
  if not known then return "wait", "waiting for the guild roster" end
  local state = ns.Ranks.State()
  if state == "noroster" then return "wait", "waiting for the guild roster" end
  if state ~= "ready" then return "wait", "waiting for rank names" end

  -- IsOfficer is false for everyone while the roster is partial (CommRegistry.lua officerKey): wait, never FAIL.
  if partial then return "wait", "waiting for the full guild roster" end

  local rank, officer = ns.Ranks.Mine()
  if type(rank) == "string" and rank:lower() == ns.Ranks.BANKER and not officer then
    return "fail", "this character has the Banker rank but does not count as officer"
  end

  -- t42 V4: the sync's state (ns.Sync seams, Store.lua; ns.Scan.Cut, Scan.lua)
  local Sync = ns.Sync or {}
  local attached = type(Sync.Attached) == "function" and Sync.Attached() or {}
  local ids = {}
  for id in pairs(attached) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if attached[id] ~= true then return "fail", "domain " .. id .. " not attached: " .. tostring(attached[id]) end
  end

  local data = ns.Data(plain(M.Compat.call("GetServerTime")), true)
  local view = data.view
  local holders, reqs, requests = 0, 0, 0
  for _ in pairs(view.holders) do holders = holders + 1 end
  if view.guild then holders = holders + 1 end -- the guild bank is one holder, whoever scanned it
  for _, r in ipairs(view.reqs) do
    if r.status == "open" then reqs = reqs + 1 end
  end
  for _, q in ipairs(view.requests) do
    if q.answer == nil then requests = requests + 1 end
  end

  local parts = { plural(holders, "holder"), plural(reqs, "open requisition"), plural(requests, "open request") }
  local low = type(view.low) == "table" and #view.low or 0
  if low > 0 then parts[#parts + 1] = plural(low, "item") .. " running low" end
  local bankChars = 0
  for _ in pairs((ns.DB().ranks or {}).bank or {}) do bankChars = bankChars + 1 end
  if bankChars > ns.LIMITS.maxBankChars then
    parts[#parts + 1] = "more than " .. ns.LIMITS.maxBankChars .. " bank characters: some bank records may arrive late"
  end
  if not ns.Scan.GuildBankReadable() then parts[#parts + 1] = "guild bank: not readable" end
  if not ns.Mail.Readable() then parts[#parts + 1] = "mail: not readable" end
  local cut = ns.Scan.Cut()
  if cut then parts[#parts + 1] = "cut: " .. tostring(cut) end
  local held, catching = 0, false
  if type(Sync.Stashed) == "function" then
    for _, family in ipairs(OWN_FAMILIES) do held = held + (tonumber(Sync.Stashed(family)) or 0) end
  end
  if held > 0 then parts[#parts + 1] = held .. " own records held by other officers (/gsbank adopt)" end
  if type(Sync.CatchingUp) == "function" then
    for _, id in ipairs(ids) do if Sync.CatchingUp(id) then catching = true end end
  end
  if type(Sync.WaitingRoster) == "function" and Sync.WaitingRoster() then
    parts[#parts + 1] = "waiting for the full guild roster"
  elseif catching then
    parts[#parts + 1] = "catching up with the other officers"
  end
  return "pass", table.concat(parts, ", ")
end

function Health.Status()
  local _, text = Health.SelfTest()
  return (tostring(text):gsub("[\r\n]+", " "))
end
