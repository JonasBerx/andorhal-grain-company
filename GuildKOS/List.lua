-- GuildKOS List: officers' writes on the target list (R6 Task C; spec AC12, AC13). Every write goes through
-- ns.Store.WriteTarget, which gates it (roster first, then officer), shapes it and holds the open cap. The keep times
-- (removed 30 days, rejected 7 days, then a gone tombstone, d757 item 2) are Store's tidy.
local _, ns = ...
local List = {}
ns.List = List

local function myKey()
  local c = type(GuildSync) == "table" and GuildSync.Comm or nil
  return c and c.MyKey() or nil
end

-- List.CanWrite() -> true | false, "roster" | "guild" | "demo" | "officer"
function List.CanWrite()
  return ns.Store.CanWriteOfficer()
end

-- A copy of the held target with fn applied, written back; the gate comes before any lookup.
local function rewrite(guid, now, fn)
  local can, why = List.CanWrite()
  if not can then return nil, why end
  if type(now) ~= "number" then return nil, "args" end
  local held = ns.Store.Target(guid)
  if type(held) ~= "table" then return nil, "target" end
  local rec = {}
  for k, v in pairs(held) do rec[k] = v end
  for _, list in ipairs({ "kills", "rejected" }) do
    local out = {}
    for i, e in ipairs(held[list] or {}) do
      local c = {}
      for k, v in pairs(e) do c[k] = v end
      out[i] = c
    end
    rec[list] = out
  end
  fn(rec, math.floor(now))
  return ns.Store.WriteTarget(guid, rec, math.floor(now))
end

-- List.Remove(guid, now) -> true | nil, why: status removed, decided by me at now.
function List.Remove(guid, now)
  return rewrite(guid, now, function(rec, t)
    rec.status, rec.decidedBy, rec.decidedAt = "removed", myKey(), t
  end)
end

-- List.EditWhy(guid, why, now) -> true | nil, why: the reason only, cut to its cap.
function List.EditWhy(guid, why, now)
  return rewrite(guid, now, function(rec)
    rec.why = ns.RulesRecords.Safe(why, ns.RulesRecords.CAPS.why)
  end)
end

local LINES = {
  roster = "Waiting for the guild roster.",
  guild = "Waiting for the guild name.",
  demo = "Not in the demo.",
  officer = "Only officers can change the list.",
  target = "That target is not on the list.",
  status = "A target is open, removed or rejected.",
}

-- List.RefusalLine(why) -> one line for the page and /kos.
function List.RefusalLine(why)
  if why == "open" then
    return "The list is full: " .. tostring(ns.Store.OPEN_MAX) .. " open targets. Remove one first."
  end
  return LINES[why] or ("Not saved (" .. tostring(why) .. ").")
end

-- List.Open() -> the open targets held (own and learned), { guid, rec } each, sorted by name then guid.
function List.Open()
  local out = {}
  local g = ns.Core and ns.Core.Guild()
  for key in pairs(g and type(g.kos) == "table" and g.kos or {}) do
    local guid = type(key) == "string" and key:sub(2) or nil
    local rec = guid and ns.Store.Target(guid)
    if type(rec) == "table" and rec.status == "open" then out[#out + 1] = { guid = guid, rec = rec } end
  end
  table.sort(out, function(a, b)
    local na, nb = a.rec.name or "", b.rec.name or ""
    if na ~= nb then return na < nb end
    return a.guid < b.guid
  end)
  return out
end
