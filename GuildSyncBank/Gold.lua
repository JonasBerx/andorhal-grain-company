-- GuildSyncBank gold ledger: the j1 record of each bank character's bag gold (run t58, d1072, d1076, d1084).
-- Pure: no client call, no clock, no Store; body and readings in, a new body out. Scan.lua and Demo.lua call it:
--   ns.Ledger.Login(body, money, now), Change(body, money, now, window), Close(body, window, parts, named),
--   Trim(body, now, fits) -> body (plan Seams)
-- body = { scanned, money, guild?, guildAt?, e = { { t, d, k, w? }, ... } }, entries oldest first; a delta is always
-- money - body.money, never a sum of entries. window = { kind = "m"|"g"|"v", at } | nil; parts = { taken = { [name] =
-- copper }, sent = { { to, amount } }, sends } | nil; named(name) -> bool (a roster row); fits(body) -> bool.

local _, ns = ...
if not ns.M then return end

local Ledger = {}
ns.Ledger = Ledger

local DAY = 86400

-- A copy of body with its own entry list, so the caller's body is never edited.
local function copy(body)
  local out, e = {}, {}
  for k, v in pairs(body) do out[k] = v end
  for i, x in ipairs(body.e or {}) do e[i] = x end
  out.e = e
  return out
end

-- Adds d to the last entry (a new table), removing the entry at 0.
local function amend(e, d)
  local last = e[#e]
  local x = { t = last.t, d = last.d + d, k = last.k, w = last.w }
  if x.d == 0 then e[#e] = nil else e[#e] = x end
end

-- The window's own entry: the last one, of the window's kind, made at or after the open.
local function inWindow(e, window)
  local last = e[#e]
  return last and window and last.k == window.kind and last.t >= window.at
end

function Ledger.Login(body, money, now)
  if not body then return { scanned = now, money = money, e = {} } end
  local out = copy(body)
  out.scanned = now
  if money ~= body.money then out.e[#out.e + 1] = { t = now, d = money - body.money, k = "s" } end
  out.money = money
  return out
end

function Ledger.Change(body, money, now, window)
  local d = money - body.money
  if d == 0 then return body end
  local out = copy(body)
  out.scanned, out.money = now, money
  local last = out.e[#out.e]
  if inWindow(out.e, window) or (not window and last and last.k == "o" and now - last.t < ns.LIMITS.otherWindow) then
    amend(out.e, d)
  else
    out.e[#out.e + 1] = { t = now, d = d, k = window and window.kind or "o" }
  end
  return out
end

local function sortedKeys(map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Postage is per attached item, up to 12 per mail: the gate allows postage x 12 per send, but only postage x 1
-- when anything was taken from the mailbox, so a returned mail is never folded into a mail-out (f6395, f6375).
local POSTAGE_ITEMS = 12

-- The named split of a mail window's net (d1084), or nil when the parts do not explain it within the postage gate.
local function split(net, t, parts, named)
  local inSum, outSum = 0, 0
  local items = POSTAGE_ITEMS
  for _, v in pairs(parts.taken or {}) do
    inSum = inSum + v
    if v > 0 then items = 1 end -- any mail-in: postage x 1 (f6375)
  end
  for _, s in ipairs(parts.sent or {}) do outSum = outSum + s.amount end
  local r = net - (inSum - outSum)
  if r > 0 or r < -ns.LIMITS.postage * items * (parts.sends or 0) then return nil end
  local plus, minus, inAnon, outAnon, lastOut = {}, {}, 0, 0, nil
  for _, name in ipairs(sortedKeys(parts.taken or {})) do
    local v = parts.taken[name]
    if v > 0 and named(name) then plus[#plus + 1] = { t = t, d = v, k = "m", w = name }
    elseif v > 0 then inAnon = inAnon + v end
  end
  for _, s in ipairs(parts.sent or {}) do
    if s.amount > 0 and named(s.to) then
      lastOut = { t = t, d = -s.amount, k = "m", w = s.to }
      minus[#minus + 1] = lastOut
    elseif s.amount > 0 then outAnon = outAnon + s.amount end
  end
  if lastOut then lastOut.d = lastOut.d + r else outAnon = outAnon - r end
  if inAnon > 0 then plus[#plus + 1] = { t = t, d = inAnon, k = "m" } end
  if outAnon > 0 then minus[#minus + 1] = { t = t, d = -outAnon, k = "m" } end
  for _, x in ipairs(minus) do plus[#plus + 1] = x end
  return plus
end

function Ledger.Close(body, window, parts, named)
  if not (window and window.kind == "m" and parts and inWindow(body.e, window)) then return body end
  local out = copy(body)
  local entry = out.e[#out.e]
  local entries = split(entry.d, entry.t, parts, named)
  if not entries then return body end
  out.e[#out.e] = nil
  for _, x in ipairs(entries) do out.e[#out.e + 1] = x end
  return out
end

function Ledger.Trim(body, now, fits)
  local out = copy(body)
  local e = {}
  for _, x in ipairs(out.e) do
    if now - x.t <= ns.LIMITS.ledgerDays * DAY then e[#e + 1] = x end
  end
  out.e = e
  while #e > ns.LIMITS.ledgerMax do table.remove(e, 1) end
  while #e > 0 and not fits(out) do table.remove(e, 1) end
  return out
end
