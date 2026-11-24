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

-- ---------- the List tab's sort, search and seen pills (issue 44 s4, p3 to p5; pure) ----------
-- An entry is { guid, rec, seen }: rec the target record, seen its lastSeen entry ({ at, zone, subzone, by }) or nil.

List.SORTS = { "seen", "name", "added" }   -- Recently seen first is the default (q1)
local SORT_OK = { seen = true, name = true, added = true }

-- List.SortBy(by) -> by when it is one of List.SORTS, else "seen".
function List.SortBy(by) return SORT_OK[by] and by or "seen" end

local function nameOf(e) return type(e.rec.name) == "string" and e.rec.name or "" end
local function numOr(v) return type(v) == "number" and v or nil end
local KEYS = {
  seen = function(e) return numOr(type(e.seen) == "table" and e.seen.at or nil) end,
  added = function(e) return numOr(e.rec.markedAt) end,
}

-- List.Sort(entries, by): in place; seen and added newest first, none last; ties by name, then guid (as List.Open).
function List.Sort(entries, by)
  local key = KEYS[List.SortBy(by)]
  table.sort(entries, function(a, b)
    if key then
      local ka, kb = key(a), key(b)
      if ka ~= kb then
        if ka == nil or kb == nil then return kb == nil end
        return ka > kb
      end
    end
    local na, nb = nameOf(a), nameOf(b)
    if na ~= nb then return na < nb end
    return (a.guid or "") < (b.guid or "")
  end)
  return entries
end

-- UTF-8 Latin-1 letters U+00C0-U+00FF by their second byte (0x80-0xBF) -> the bare small letter; the times and
-- division signs (D7, F7) stay as they are.
local BARE = {}
do
  local low = { "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
    "d", "n", "o", "o", "o", "o", "o", false, "o", "u", "u", "u", "u", "y", "th" }
  for i, s in ipairs(low) do
    if s then
      BARE[string.char(127 + i)] = s
      BARE[string.char(159 + i)] = s
    end
  end
  BARE["\159"], BARE["\191"] = "ss", "y"
end

-- List.Fold(s) -> lower case, accents dropped, one space between words, no edge spaces ("" for a non-string).
function List.Fold(s)
  if type(s) ~= "string" then return "" end
  s = s:lower():gsub("\195([\128-\191])", function(b) return BARE[b] or ("\195" .. b) end)
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- List.Filter(entries, query) -> the entries whose name, why, zone or subzone (the record's or the sighting's) holds
-- the folded query as plain text; a blank query keeps them all. A new list; entries is not changed.
function List.Filter(entries, query)
  local q = List.Fold(query)
  local out = {}
  for _, e in ipairs(entries) do
    local seen = type(e.seen) == "table" and e.seen or {}
    local hit = q == ""
    if not hit then
      local fields = { e.rec.name, e.rec.why, e.rec.zone, e.rec.subzone, seen.zone, seen.subzone }
      for i = 1, 6 do   -- not ipairs: a missing field must not end the walk
        if List.Fold(fields[i]):find(q, 1, true) then hit = true break end
      end
    end
    if hit then out[#out + 1] = e end
  end
  return out
end

local RECENT = 600
-- List.SeenPill(at, now) -> "Seen just now" (under 10 min), "Seen today" (the same UTC day), or nil.
function List.SeenPill(at, now)
  if type(at) ~= "number" or type(now) ~= "number" then return nil end
  if now - at < RECENT then return "Seen just now" end
  if math.floor(at / 86400) == math.floor(now / 86400) then return "Seen today" end   -- a literal divisor (static pin)
  return nil
end
