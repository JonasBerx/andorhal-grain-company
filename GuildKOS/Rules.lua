-- GuildKOS Rules: names, throttles, list gates, timing decisions and the lines the player reads.
-- Pure Lua 5.1, no client calls. Time (now) and randomness (r) are always passed in.
-- A nil version counts as 0 in every comparison.
local _, ns = ...
local Rules = {}
ns.Rules = Rules

Rules.WINDOW = 60              -- display throttle, push window, answer limit
Rules.RING = 100               -- sightings kept
Rules.BANNER = 5               -- seconds the banner shows
Rules.HEARD_PER_SENDER = 5     -- new heard sightings one record key gets through in any WINDOW of receive time (D89)
Rules.RING_PER_SENDER = 10     -- ring entries one record key may hold (D89)

-- Names ---------------------------------------------------------------------

-- Lowercased (ASCII only), trimmed, single-spaced name, or nil.
function Rules.Key(name)
  if type(name) ~= "string" then return nil end
  local k = name:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

-- Two or more space-separated parts.
function Rules.IsFullName(name)
  local k = Rules.Key(name)
  return k ~= nil and k:find(" ", 1, true) ~= nil
end

-- The entry whose target has the same Key as name; full names only.
function Rules.Find(targets, name)
  if type(targets) ~= "table" or not Rules.IsFullName(name) then return nil end
  local k = Rules.Key(name)
  for _, entry in ipairs(targets) do
    if Rules.Key(entry.target) == k then return entry end
  end
  return nil
end

-- R6 (spec AC21): the key ("t" .. GUID) of the record in targets (key -> kos record, open targets only) whose name has
-- the same Key as name; full names only. With two such records the lowest key wins.
function Rules.FindName(name, targets)
  if type(targets) ~= "table" or not Rules.IsFullName(name) then return nil end
  local k, found = Rules.Key(name), nil
  for key, rec in pairs(targets) do
    if type(key) == "string" and type(rec) == "table" and Rules.Key(rec.name) == k and (not found or key < found) then
      found = key
    end
  end
  return found
end

-- Timing ----------------------------------------------------------------------

function Rules.Throttle(seen, key, now, window)
  local last = seen[key]
  if last ~= nil and now - last < window then return false end
  seen[key] = now
  return true
end

-- perSender: at most this many entries with s.spotter in the ring; at the share that spotter's own oldest goes.
-- Entries without a spotter are never counted or evicted by the share; perSender nil is the 0.5 behaviour (D89).
function Rules.AddSighting(ring, s, cap, perSender)
  if perSender and s.spotter ~= nil then
    local n, first = 0, nil
    for i, e in ipairs(ring) do
      if e.spotter == s.spotter then
        n = n + 1
        first = first or i
      end
    end
    if n >= perSender then table.remove(ring, first) end
  end
  ring[#ring + 1] = s
  while #ring > cap do table.remove(ring, 1) end
  return ring
end

-- Whether last seen is the player's own (mine) and younger than WINDOW of receive time t, so a heard sighting leaves
-- it (D89, f8553).
function Rules.KeepOwn(seen, t)
  return type(seen) == "table" and seen.mine == true and type(seen.at) == "number" and t - seen.at < Rules.WINDOW
end

-- Lines -------------------------------------------------------------------------

-- A name or place made safe to print: "|" doubled so the chat frame shows it as text, bytes below 0x20 and 0x7F dropped.
-- Applied once per shown value, inside the line functions below; the identity on any other text.
function Rules.Clean(s)
  return ((s:gsub("[%z\1-\31\127]", ""):gsub("|", "||")))
end

local Clean = Rules.Clean

local function place(zone, subzone)
  zone = zone or ""
  if subzone and subzone ~= "" and subzone ~= zone then return Clean(subzone) .. ", " .. Clean(zone) end
  return Clean(zone)
end

local function who(entry)
  local parts = {}
  if entry.race and entry.race ~= "" then parts[#parts + 1] = Clean(entry.race) end
  if entry.class and entry.class ~= "" then parts[#parts + 1] = Clean(entry.class) end
  if #parts == 0 then return Clean(entry.target) end
  return Clean(entry.target) .. " (" .. table.concat(parts, " ") .. ")"
end

local function ago(seconds)
  local mins = math.floor(seconds / 60)
  if mins < 1 then return "just now" end
  if mins < 60 then return mins .. " min ago" end
  local hours = math.floor(mins / 60)
  if hours < 48 then return hours .. " h ago" end
  return math.floor(hours / 24) .. " days ago"
end

function Rules.SpotLine(entry, zone, subzone)
  return "KOS: " .. who(entry) .. " at " .. place(zone, subzone)
end

function Rules.HeardLine(spotter, target, zone, subzone)
  return Clean(spotter) .. " sees " .. Clean(target) .. " at " .. place(zone, subzone)
end

-- R6 (spec AC22): "<spotter> sees <target> at <subzone>, <zone>[, your shard | , other shard]". esc makes each value
-- safe to show (GuildSync.Escape; Clean when nil) and runs last on it; the values come in already capped (Records.Safe
-- at Parse). The shard word shows only when both shards are known.
function Rules.HeardShardLine(spotter, target, zone, subzone, shard, myShard, esc)
  esc = esc or Clean
  zone, subzone = zone or "", subzone or ""
  local at = esc(zone)
  if subzone ~= "" and subzone ~= zone then at = esc(subzone) .. ", " .. at end
  local line = esc(spotter or "") .. " sees " .. esc(target or "") .. " at " .. at
  if type(shard) == "string" and shard ~= "" and type(myShard) == "string" and myShard ~= "" then
    line = line .. (shard == myShard and ", your shard" or ", other shard")
  end
  return line
end

function Rules.ListLines(list, lastSeen, now)
  if list == nil then return { "KOS: No list yet. Copy it from the Kill on Sight page, then /kos import." } end
  lastSeen = lastSeen or {}
  local out = {}
  for _, entry in ipairs(list.targets or {}) do
    local line
    if not Rules.IsFullName(entry.target) then
      line = who(entry) .. ": one name only, can't be spotted"
    else
      local seen = lastSeen[Rules.Key(entry.target)]
      if seen then
        line = who(entry) .. ": seen " .. ago(now - seen.at) .. " at " .. place(seen.zone, seen.subzone)
        if seen.by and seen.by ~= "" then line = line .. " by " .. Clean(seen.by) end
      else
        line = who(entry) .. ": never seen"
      end
    end
    out[#out + 1] = line
  end
  return out
end

return Rules
