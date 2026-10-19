-- GuildKOS Rules: names, throttles, list gates, timing decisions and the lines the player reads.
-- Pure Lua 5.1, no client calls. Time (now) and randomness (r) are always passed in.
-- A nil version counts as 0 in every comparison.
local _, ns = ...
local Rules = {}
ns.Rules = Rules

Rules.WINDOW = 60              -- display throttle, push window, answer limit
Rules.FUTURE = 86400           -- a list dated further ahead than this is refused
Rules.RING = 100               -- sightings kept
Rules.HOLD = 120               -- a complete list held while the roster isn't ready
Rules.REBUILD_EVERY = 10       -- roster names rebuild spacing
Rules.BANNER = 5               -- seconds the banner shows
Rules.OFFICER_MAX_RANK = 1     -- not read since 0.5: officers are GuildSync.Comm.IsOfficer's (D240); kept for rules_test

-- Names ---------------------------------------------------------------------

-- Lowercased (ASCII only), trimmed, single-spaced name, or nil.
function Rules.Key(name)
  if type(name) ~= "string" then return nil end
  local k = name:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  if k == "" then return nil end
  return k
end

-- Key of an addon-message sender or roster name, without a trailing "-<own realm>".
function Rules.SenderKey(s, realm)
  if type(s) ~= "string" then return nil end
  if type(realm) == "string" and realm ~= "" then
    local suffix = "-" .. realm
    if #s > #suffix and s:sub(-#suffix):lower() == suffix:lower() then
      s = s:sub(1, #s - #suffix)
    end
  end
  return Rules.Key(s)
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

-- Timing ----------------------------------------------------------------------

function Rules.Throttle(seen, key, now, window)
  local last = seen[key]
  if last ~= nil and now - last < window then return false end
  seen[key] = now
  return true
end

function Rules.NextSlot(last, now, window)
  if last == nil or now >= last + window then return now end
  return last + window
end

function Rules.PushDelay(r) return 2 + 4 * r end

function Rules.AnswerDelay(r) return 1 + 4 * r end

function Rules.CancelPush(mine, chunkVersion)
  return (chunkVersion or 0) >= (mine or 0)
end

function Rules.CancelAnswer(mine, heard)
  if type(heard) ~= "table" then return false end
  local v, m = heard.version or 0, mine or 0
  if heard.kind == "O" then return v <= m end
  if heard.kind == "L" then return v > m end
  return false
end

function Rules.Hold(held, senderKey, item, now)
  held[senderKey] = { item = item, at = now }
  return held
end

function Rules.TakeHeld(held, now)
  local out = {}
  for key, h in pairs(held) do
    if now - h.at <= Rules.HOLD then out[#out + 1] = h.item end
    held[key] = nil
  end
  return out
end

function Rules.ShouldReoffer(expired, mine, passedGate)
  return passedGate == true and (expired.version or 0) > (mine or 0)
end

function Rules.AddSighting(ring, s, cap)
  ring[#ring + 1] = s
  while #ring > cap do table.remove(ring, 1) end
  return ring
end

-- Lists -----------------------------------------------------------------------

function Rules.ImportVerdict(mine, theirs, now)
  local m, t = mine or 0, theirs or 0
  if t > now + Rules.FUTURE then return "future" end
  if t > m then return "take" end
  if t == m then return "same" end
  return "older"
end

function Rules.AcceptList(channel, rankIndex, maxRank, mine, theirs, rosterReady, now)
  if channel ~= "GUILD" then return false, "channel" end
  local verdict = Rules.ImportVerdict(mine, theirs, now)
  if verdict ~= "take" then return false, verdict end
  if not rosterReady then return false, "wait" end
  if rankIndex == nil then return false, "unknown" end
  if rankIndex > maxRank then return false, "rank" end
  return true
end

function Rules.OnOffer(mine, theirs, iAmOfficer, senderIsOfficer, now)
  local m, t = mine or 0, theirs or 0
  if t > now + Rules.FUTURE then return nil end
  if m > t and iAmOfficer then return "push" end
  if m < t and senderIsOfficer then return "offer" end
  return nil
end

-- Lines -------------------------------------------------------------------------

-- A name or place made safe to print: "|" doubled so the chat frame shows it as text, bytes below 0x20 and 0x7F dropped.
-- Applied once per shown value, inside the line functions below; the identity on any other text.
function Rules.Clean(s)
  return ((s:gsub("[%z\1-\31\127]", ""):gsub("|", "||")))
end

local Clean = Rules.Clean

local function targets(n)
  if n == 1 then return "1 target" end
  return n .. " targets"
end

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

function Rules.ImportLine(n, dateText)
  return "KOS: " .. targets(n) .. ", list of " .. dateText
end

function Rules.ReceivedLine(sender, n, dateText)
  return "KOS: New list from " .. Clean(sender) .. ", " .. targets(n) .. ", list of " .. dateText .. "."
end

local REFUSALS = {
  format = function() return "KOS: That isn't a list from the Kill on Sight page. Copy it again with Copy for addon." end,
  cut = function() return "KOS: That list is cut off. Copy it again, type /kos import and paste it in the window." end,
  older = function(d) return "KOS: That list is older than yours (list of " .. d .. "). Yours stays." end,
  same = function(d) return "KOS: You already have the list of " .. d .. "." end,
  future = function(d) return "KOS: That list is dated " .. d .. ", which is in the future, so it can't be right. Yours stays." end,
}

function Rules.RefusalLine(reason, dateText)
  return (REFUSALS[reason] or REFUSALS.format)(dateText or "")
end

function Rules.SpotLine(entry, zone, subzone)
  return "KOS: " .. who(entry) .. " at " .. place(zone, subzone)
end

function Rules.HeardLine(spotter, target, zone, subzone)
  return Clean(spotter) .. " sees " .. Clean(target) .. " at " .. place(zone, subzone)
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

-- Window and minimap button ---------------------------------------------------------

Rules.MINIMAP_ANGLE = 240      -- default button angle in degrees; GuildSync starts at 200, so the two buttons do not overlap
Rules.MINIMAP_RADIUS = 80      -- distance from the minimap centre to the button centre

-- A saved angle as a number in [0, 360), or the default when it isn't a usable number.
function Rules.MinimapAngle(angle)
  if type(angle) ~= "number" or angle ~= angle or angle == math.huge or angle == -math.huge then
    return Rules.MINIMAP_ANGLE
  end
  return angle % 360
end

-- x, y offset of the button from the minimap centre for an angle (0 = right, 90 = up).
function Rules.MinimapOffset(angle, radius)
  local a = math.rad(Rules.MinimapAngle(angle))
  radius = radius or Rules.MINIMAP_RADIUS
  return radius * math.cos(a), radius * math.sin(a)
end

-- The angle of a point dx, dy away from the minimap centre (the cursor while dragging), in [0, 360).
function Rules.AngleFrom(dx, dy)
  return math.deg(math.atan2(dy, dx)) % 360
end

-- The window's header: the target count and the list date, or a nudge to import.
function Rules.HeaderLine(list, dateText)
  if list == nil then return "No list yet. Import one." end
  return targets(#(list.targets or {})) .. ", list of " .. (dateText or "")
end

-- One row per target, in list order (as ListLines): who = name (race class), status = last seen or why it can't be,
-- warn = true for a one-word name that can never be spotted.
function Rules.ListRows(list, lastSeen, now)
  local out = {}
  if list == nil then return out end
  lastSeen = lastSeen or {}
  for _, entry in ipairs(list.targets or {}) do
    local row = { who = who(entry), warn = false }
    if not Rules.IsFullName(entry.target) then
      row.status, row.warn = "one name, can't spot", true
    else
      local seen = lastSeen[Rules.Key(entry.target)]
      if seen then
        row.status = "seen " .. ago(now - seen.at) .. " at " .. place(seen.zone, seen.subzone)
        if seen.by and seen.by ~= "" then row.status = row.status .. " by " .. Clean(seen.by) end
      else
        row.status = "never seen"
      end
    end
    out[#out + 1] = row
  end
  return out
end

-- Demo (/kos demo) ----------------------------------------------------------------------
-- Made-up enemies to show the addon without a real list. Lives only in memory on this client: never saved, never sent.

-- name, race, class, then where and how long ago it was seen (ago in seconds; nil = never seen).
local DEMO_PLACES = {
  { ago = 120, zone = "Hillsbrad Foothills", subzone = "Tarren Mill" },
  { ago = 86400, zone = "Hillsbrad Foothills", subzone = "Southshore", by = "Mortis" },
  {},
  { ago = 2400, zone = "Arathi Highlands", subzone = "" },
  { ago = 3 * 86400, zone = "Stranglethorn Vale", subzone = "Booty Bay", by = "Velra" },
  {},
  { ago = 6 * 3600, zone = "Arathi Highlands", subzone = "Refuge Pointe" },
  {},
}

local DEMO_ALLIANCE = {
  { "Aldric Vane", "Human", "Rogue" },
  { "Brenna Stoutforge", "Dwarf", "Hunter" },
  { "Elowen Duskbrook", "Night Elf", "Druid" },
  { "Fizzik Gearwhistle", "Gnome", "Mage" },
  { "Garrick Holt", "Human", "Warrior" },
  { "Thalia Moonveil", "Night Elf", "Priest" },
  { "Durgan Ironbeard", "Dwarf", "Paladin" },
  { "Snibble", "Gnome", "Warlock" },
}

local DEMO_HORDE = {
  { "Grakk Bloodfang", "Orc", "Rogue" },
  { "Morwen Blackveil", "Undead", "Mage" },
  { "Tahu Stormhoof", "Tauren", "Druid" },
  { "Zul Rakasha", "Troll", "Hunter" },
  { "Durok Skullsplitter", "Orc", "Warrior" },
  { "Silas Graves", "Undead", "Priest" },
  { "Hana Mistrunner", "Tauren", "Shaman" },
  { "Vexx", "Troll", "Warlock" },
}

-- list, lastSeen in the shapes the real data uses ({ version, text, targets } and Key -> { at, zone, subzone, by }).
-- faction is the player's own ("Horde" | "Alliance"); the demo shows the other side. Anything else gets the Alliance set.
function Rules.DemoList(now, faction)
  local names = faction == "Alliance" and DEMO_HORDE or DEMO_ALLIANCE
  local targets, lastSeen = {}, {}
  for i, n in ipairs(names) do
    targets[i] = { id = i, target = n[1], race = n[2], class = n[3], zone = "", why = "Demo" }
    local p = DEMO_PLACES[i]
    if p.ago and Rules.IsFullName(n[1]) then
      lastSeen[Rules.Key(n[1])] = { at = now - p.ago, zone = p.zone, subzone = p.subzone, by = p.by }
    end
  end
  return { version = now, text = "", targets = targets }, lastSeen
end

function Rules.DemoHeader(n)
  return "Demo list, " .. targets(n) .. ". /kos demo off ends it."
end

function Rules.DemoSpotLine(entry, zone, subzone)
  return "KOS (demo): " .. who(entry) .. " at " .. place(zone, subzone)
end

-- Tooltip lines for the minimap button, the first is the title.
function Rules.ButtonTooltip(muted)
  return {
    "GuildKOS",
    "Left-click: open",
    "Right-click: alerts " .. (muted and "on" or "off"),
    "Drag: move",
  }
end

return Rules
