-- GuildSync View: the words and numbers the window, the minimap button and /gsync show.
-- Pure: no client calls and no globals, so addon/test/gsync_view_test.lua runs it outside the game.

local ADDON, ns = ...

local View = {}
ns.View = View

View.RADIUS = 80          -- distance from the minimap's centre to the button's centre
View.DEFAULT_ANGLE = 200  -- degrees, 0 = east, counter-clockwise. GuildKOS starts at 240 so the two don't overlap.
View.TOOLTIP = { "GuildSync", "Left-click: open", "Right-click: rescan", "Drag: move" }

local HEAD, LABEL, WARN, END = "|cffd4a24c", "|cffaaaaaa", "|cffff8800", "|r"

-- ---------- minimap button ----------

-- Angle in degrees -> x, y offset from the minimap's centre.
function View.Offset(angle, radius)
  local a = math.rad(type(angle) == "number" and angle or View.DEFAULT_ANGLE)
  radius = radius or View.RADIUS
  return math.cos(a) * radius, math.sin(a) * radius
end

-- x, y offset from the minimap's centre (the cursor while dragging) -> angle in degrees, 0 <= angle < 360.
function View.Angle(dx, dy)
  if type(dx) ~= "number" or type(dy) ~= "number" or (dx == 0 and dy == 0) then return nil end
  local a = math.deg(math.atan2(dy, dx))
  if a < 0 then a = a + 360 end
  if a >= 360 then a = a - 360 end
  return a
end

-- ---------- status ----------

-- Money as the game writes it: each non-zero part ("19s", "1g 5s", "2g 3s 4c", "57c"); "0g" for none.
function View.Gold(copper)
  copper = (type(copper) == "number" and copper == copper and copper > 0) and math.floor(copper) or 0
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 then parts[#parts + 1] = c .. "c" end
  if #parts == 0 then return "0g" end
  return table.concat(parts, " ")
end

-- The first line /gsync prints.
function View.CharacterLine(c)
  if type(c) ~= "table" then return "character not known yet." end
  return tostring(c.name) .. ", level " .. tostring(c.level or "?") .. ", " .. View.Gold(c.gold) .. "."
end

-- { { label, text }, ... } for "This character".
function View.CharacterRows(c)
  if type(c) ~= "table" then return { { "Character", "not known yet" } } end
  return {
    { "Name", tostring(c.name or "?") },
    { "Level", tostring(c.level or "?") },
    { "Gold", View.Gold(c.gold) },
  }
end

-- A module's { label, text } row, or nil: a module with a selftest and no status gets no row.
local function moduleRow(mod)
  if type(mod.status) == "function" or type(mod.selftest) ~= "function" then
    local line = "no status"
    if type(mod.status) == "function" then
      local ok, result = pcall(mod.status)
      line = ok and tostring(result) or ("status failed: " .. tostring(result))
    end
    return { tostring(mod.name), line }
  end
end

-- { { label, text }, ... }: one row per module with its status() line, in load order.
function View.ModuleRows(modules)
  local rows = {}
  for _, mod in ipairs(modules or {}) do
    local row = moduleRow(mod)
    if row then table.insert(rows, row) end
  end
  return rows
end

-- Money as Forever's player money frame draws it: leading zero parts hidden, lower parts shown once a higher one
-- shows, copper always. { g = n|nil, s = n|nil, c = n }.
function View.MoneyParts(copper)
  copper = (type(copper) == "number" and copper == copper and copper > 0) and math.floor(copper) or 0
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return { g = g, s = s, c = c } end
  if s > 0 then return { s = s, c = c } end
  return { c = c }
end

-- ---------- /gsync selftest ----------

View.SELFTEST_COLOURS = { pass = "|cff20ff20", wait = "|cffffd200", fail = "|cffff2020" }
View.SELFTEST_MAX = 300 -- bytes kept of a selftest's text (Core's missing-API line runs to about 150)

-- s without a trailing incomplete UTF-8 sequence (a lead byte followed by fewer continuation bytes than it announces).
local function wholeUtf8(s)
  local i, cont = #s, 0
  while i > 0 and cont < 3 do
    local b = string.byte(s, i)
    if b < 128 or b >= 192 then break end
    cont, i = cont + 1, i - 1
  end
  local lead = i > 0 and string.byte(s, i) or 0
  if lead >= 192 then
    local need = lead >= 240 and 3 or lead >= 224 and 2 or 1
    if cont < need then return string.sub(s, 1, i - 1) end
  end
  return s
end

-- First line, cut (never inside a character), every | doubled so a text cannot colour or link the chat line.
local function selftestText(v)
  local s = string.match(tostring(v), "^[^\r\n]*")
  if #s > View.SELFTEST_MAX then s = wholeUtf8(string.sub(s, 1, View.SELFTEST_MAX)) end
  return (string.gsub(s, "|", "||"))
end

-- mod.selftest's answer as state, text; anything outside the contract is "fail", "bad answer".
local function selftestAnswer(mod, plain)
  local state, text = mod.selftest()
  state = plain(state)
  if type(state) ~= "string" or (state ~= "pass" and state ~= "wait" and state ~= "fail") then
    return "fail", "bad answer"
  end
  text = plain(text)
  if text == nil or text == "" then return state, "no reason given" end
  return state, selftestText(text)
end

-- One line per module with a selftest, in order, then "no self-test: A, B" (when any), then the total.
-- plain is Compat.Plain (secret -> nil). A selftest that throws or answers wrongly is FAIL; the rest still run.
function View.SelftestLines(modules, plain)
  local lines, counts, missing = {}, { pass = 0, wait = 0, fail = 0 }, {}
  for _, mod in ipairs(modules or {}) do
    local name = (string.gsub(tostring(mod.name), "|", "||"))
    if type(mod.selftest) == "function" then
      local ok, state, text = pcall(selftestAnswer, mod, plain)
      if not ok then
        local okText, errText = pcall(function() return selftestText(plain(state)) end)
        state, text = "fail", okText and errText or "error"
      end
      counts[state] = counts[state] + 1
      table.insert(lines, name .. ": " .. View.SELFTEST_COLOURS[state] .. string.upper(state) .. "|r - " .. text)
    else
      table.insert(missing, name)
    end
  end
  if #missing > 0 then table.insert(lines, "no self-test: " .. table.concat(missing, ", ")) end
  table.insert(lines, "selftest: " .. counts.pass .. " pass, " .. counts.wait .. " wait, " .. counts.fail .. " fail")
  return lines, counts
end

function View.ErrorsRow(errors)
  local n = type(errors) == "table" and #errors or 0
  if n == 0 then return { "Errors", "none" } end
  return { "Errors", WARN .. n .. END .. " (Show errors lists them)" }
end

-- ---------- This character page ----------

local function identity(v) return v end

-- The state /gsync selftest prints for mod (same wrapper): "pass"|"wait"|"fail", nil without a selftest.
-- plain is Compat.Plain (identity when nil). A throw, a bad answer or a secret is "fail".
function View.SelftestState(mod, plain)
  if type(mod.selftest) ~= "function" then return nil end
  local ok, state = pcall(selftestAnswer, mod, plain or identity)
  return ok and state or "fail"
end

-- { { name, status, state }, ... }: View.ModuleRows' rows (same filter, same texts) with each module's state.
function View.CharRows(modules, plain)
  local rows = {}
  for _, mod in ipairs(modules or {}) do
    local row = moduleRow(mod)
    if row then table.insert(rows, { row[1], row[2], View.SelftestState(mod, plain) }) end
  end
  return rows
end

-- The Errors row with its mark: pass with none, wait (the warning mark) with any.
function View.ErrorsMark(errors)
  local row = View.ErrorsRow(errors)
  return { row[1], row[2], (type(errors) == "table" and #errors > 0) and "wait" or "pass" }
end

-- { word, r, g, b } per state, from /gsync selftest's words and colours.
View.STATE_WORD = {}
for state, code in pairs(View.SELFTEST_COLOURS) do
  local hex = string.sub(code, 5, 10)
  View.STATE_WORD[state] = { string.upper(state), tonumber(string.sub(hex, 1, 2), 16) / 255,
    tonumber(string.sub(hex, 3, 4), 16) / 255, tonumber(string.sub(hex, 5, 6), 16) / 255 }
end

-- The page's numbers, y in px down from the page top (Window negates). Status width = page width - statusX - statusRight.
View.CHAR = {
  header = { x = 0, y = 0, h = 26 }, recorded = { x = 0, y = 118, h = 26 },
  -- the This character card (d530) and what sits on it; icon, name, level and gold are page numbers too
  card = { x = 0, y = 30, h = 84 },
  icon = { x = 12, y = 52, size = 40 }, name = { x = 62, y = 47 }, level = { x = 62, y = 67 }, gold = { x = 62, y = 81 },
  rowY = 150, rowH = 22, mark = { x = 6, y = 3, w = 16 }, nameX = 28, statusX = 132, statusRight = 8,
  buttons = { x = { 0, 128, 256 }, w = 120, h = 22 },
  -- the class art on the card's left (d530), card-relative: rows top..bottom of the artH-tall UI-Character-Info-<Class>-BG,
  -- the first solidW of its w px solid, the rest fading out to the right
  classBg = { x = 0, y = 0, w = 233, solidW = 133, h = 84, top = 165, bottom = 241, artH = 383 },
}

-- The window's portrait (d471): "crest" shows the player's faction banner; anything else, or no faction, the bag.
local BAG_ICON = "Interface\\Icons\\INV_Misc_Bag_10"
local CRESTS = { Horde = "Interface\\Icons\\INV_BannerPVP_01", Alliance = "Interface\\Icons\\INV_BannerPVP_02" }
function View.WindowIcon(choice, faction)
  return choice == "crest" and CRESTS[faction] or BAG_ICON
end

-- How many of n module rows to draw on a page pageH tall so they and the Errors row (one more slot, always last)
-- end strictly above the buttons.
function View.RowsThatFit(pageH, n)
  local C = View.CHAR
  local room = pageH - C.buttons.h - C.rowY
  local slots = math.ceil(room / C.rowH) - 1
  return math.max(0, math.min(n, slots - 1))
end

View.COMBAT_LINE = "Settings open after combat."
View.OPTIONS_FAILED_LINE = "Settings did not open. Find them under Esc > Options > AddOns > GuildSync."

local PATH_LINES = {
  vertical = "Settings: options (vertical)", canvas = "Settings: options (canvas)", window = "Settings: window",
}

-- The probe's line for Window.SettingsPath().
function View.SettingsPathLine(path)
  return PATH_LINES[path] or PATH_LINES.window
end

-- The title bar gear's tooltip lines for Window.SettingsPath().
function View.GearTooltip(path)
  if path == "vertical" or path == "canvas" then return { "Settings", "Opens Esc > Options > AddOns > GuildSync." } end
  return { "Settings" }
end

local function addRows(lines, rows)
  for _, row in ipairs(rows) do table.insert(lines, LABEL .. row[1] .. ":" .. END .. " " .. row[2]) end
end

-- The window's text: "This character", then "What's recorded" with the errors row last.
function View.InfoText(c, modules, errors)
  local lines = { HEAD .. "This character" .. END }
  addRows(lines, View.CharacterRows(c))
  table.insert(lines, "")
  table.insert(lines, HEAD .. "What's recorded" .. END)
  addRows(lines, View.ModuleRows(modules))
  addRows(lines, { View.ErrorsRow(errors) })
  return table.concat(lines, "\n")
end

-- ---------- Roster page ----------
-- Rows, sorting, chips, search and the side panel for the recorded roster (GuildSyncDB3.guild, Roster.lua).

View.ROSTER_EMPTY = "No roster yet. Open the guild window or /gsync scan."
View.NO_MATCH = "No member matches."
View.PICK_MEMBER = "Click a member to see the details."
View.INACTIVE_DAYS = 21 -- days offline before a member counts as away
View.DEFAULT_SORT = "rank"
View.COLUMNS = {
  { key = "name", label = "Name" }, { key = "rank", label = "Rank" },
  { key = "level", label = "Level" }, { key = "last", label = "Last online" },
}
local FIRST_DESCENDING = { level = true } -- a first click on Level shows the highest first
local LAST = 1e9 -- sorts after every real rank and every real day count

local CLASS_NAMES = { DEATHKNIGHT = "Death Knight", DEMONHUNTER = "Demon Hunter" }

-- "WARLOCK" -> "Warlock"
function View.ClassName(token)
  if type(token) ~= "string" or token == "" then return "?" end
  return CLASS_NAMES[token] or (string.upper(string.sub(token, 1, 1)) .. string.lower(string.sub(token, 2)))
end

-- "online", "2 h", "today", "yesterday", "3 days", "5 weeks", "2 months" or "unknown".
-- hours: only when the client gave them; the recorded roster holds whole days.
function View.LastOnlineText(online, days, hours)
  if online then return "online" end
  if type(hours) == "number" and (days == nil or days == 0) then return math.max(1, math.floor(hours)) .. " h" end
  if type(days) ~= "number" then return "unknown" end
  if days <= 0 then return "today" end
  if days == 1 then return "yesterday" end
  if days < 14 then return days .. " days" end
  if days < 60 then return math.floor(days / 7) .. " weeks" end
  return math.floor(days / 30) .. " months"
end

-- 0-based rank order: the recorded rankIndex, else the rank's place in the guild's rank list, else LAST.
local function rankOrder(m, ranks)
  if type(m.rankIndex) == "number" then return m.rankIndex end
  if type(m.rank) == "string" and type(ranks) == "table" then
    for i, name in ipairs(ranks) do if name == m.rank then return i - 1 end end
  end
  return LAST
end

local function str(v) if type(v) == "string" and v ~= "" then return v end return nil end
-- Text from other players (rank names, notes) drawn as typed: every | doubled, so it cannot colour, link or show
-- a texture in a FontString, a menu entry or a chat line.
local function escape(v) return (string.gsub(tostring(v), "|", "||")) end

-- One row per recorded member, unsorted.
function View.RosterRows(guild)
  local rows = {}
  if type(guild) ~= "table" or type(guild.members) ~= "table" then return rows end
  local ranks = guild.ranks
  for guid, m in pairs(guild.members) do
    if type(m) == "table" then
      local order = rankOrder(m, ranks)
      local days = type(m.lastOnlineDays) == "number" and m.lastOnlineDays or nil
      table.insert(rows, {
        guid = tostring(guid), name = tostring(m.name or "?"),
        rank = escape(str(m.rank) or (type(ranks) == "table" and order ~= LAST and str(ranks[order + 1])) or "?"),
        rankOrder = order, level = type(m.level) == "number" and m.level or nil, class = str(m.class), race = str(m.race),
        online = m.online and true or false, days = days, last = View.LastOnlineText(m.online, days, m.lastOnlineHours),
        zone = str(m.zone), note = str(m.note), officerNote = str(m.officerNote), prof1 = m.prof1, prof2 = m.prof2,
      })
    end
  end
  return rows
end

local SORT_KEYS = {
  name = function(r) return string.lower(r.name) end,
  rank = function(r) return r.rankOrder end,
  level = function(r) return r.level or -1 end,
  last = function(r) if r.online then return -1 end return r.days or LAST end,
}

-- Sorts rows in place and returns them. Ties always go by name, then GUID, in either direction.
function View.SortRows(rows, column, descending)
  local key = SORT_KEYS[column] or SORT_KEYS[View.DEFAULT_SORT]
  table.sort(rows, function(a, b)
    local ka, kb = key(a), key(b)
    if ka ~= kb then
      if descending then return ka > kb end
      return ka < kb
    end
    local na, nb = string.lower(a.name), string.lower(b.name)
    if na ~= nb then return na < nb end
    return a.guid < b.guid
  end)
  return rows
end

-- A click on a column header: the same column flips, another starts in its own first direction.
function View.NextSort(column, descending, clicked)
  if clicked == column then return column, not descending end
  return clicked, FIRST_DESCENDING[clicked] or false
end

function View.HeaderText(key, column, descending)
  local label = key
  for _, c in ipairs(View.COLUMNS) do if c.key == key then label = c.label end end
  if key ~= column then return label end
  return label .. (descending and " v" or " ^")
end

local function isInactive(r)
  return not r.online and type(r.days) == "number" and r.days >= View.INACTIVE_DAYS
end

local function trim(s) return (string.gsub(string.gsub(s or "", "^%s+", ""), "%s+$", "")) end

local function chipMatches(r, key)
  if key == nil or key == "all" then return true end
  if key == "offline" then return isInactive(r) end
  return key == "rank:" .. r.rankOrder
end

-- { { key, label, count }, ... }: All, one per rank that has members (in rank order), Offline 21+ days.
function View.RosterChips(rows)
  local byOrder, orders, inactive = {}, {}, 0
  for _, r in ipairs(rows) do
    if not byOrder[r.rankOrder] then
      byOrder[r.rankOrder] = { key = "rank:" .. r.rankOrder, label = r.rank, count = 0 }
      table.insert(orders, r.rankOrder)
    end
    byOrder[r.rankOrder].count = byOrder[r.rankOrder].count + 1
    if isInactive(r) then inactive = inactive + 1 end
  end
  table.sort(orders)
  local chips = { { key = "all", label = "All", count = #rows } }
  for _, o in ipairs(orders) do table.insert(chips, byOrder[o]) end
  table.insert(chips, { key = "offline", label = "Offline " .. View.INACTIVE_DAYS .. "+ days", count = inactive })
  return chips
end

function View.ChipText(chip)
  return chip.label .. " (" .. chip.count .. ")"
end

-- The rank filter's menu: { key, text } per chip in order, and a divider right before the offline entry.
function View.RosterFilterEntries(chips)
  local out = {}
  for _, c in ipairs(chips) do
    if c.key == "offline" then table.insert(out, { divider = true }) end
    table.insert(out, { key = c.key, text = View.ChipText(c) })
  end
  return out
end

-- Name, public note or officer note contains the search, any case, as plain text.
function View.MatchesSearch(r, query)
  query = string.lower(trim(query))
  if query == "" then return true end
  for _, field in ipairs({ r.name, r.note or "", r.officerNote or "" }) do
    if string.find(string.lower(field), query, 1, true) then return true end
  end
  return false
end

-- The rows the chip and the search both let through, in their current order.
function View.FilterRows(rows, chipKey, query)
  local out = {}
  for _, r in ipairs(rows) do
    if chipMatches(r, chipKey) and View.MatchesSearch(r, query) then table.insert(out, r) end
  end
  return out
end

local function profText(p)
  if type(p) ~= "table" or not str(p.name) then return nil end
  return p.name .. (type(p.rank) == "number" and (" " .. p.rank) or "")
end

-- The member's professions as one line, nil when none is recorded.
local function profsText(r)
  local profs = {}
  local p1, p2 = profText(r.prof1), profText(r.prof2)
  if p1 then table.insert(profs, p1) end
  if p2 then table.insert(profs, p2) end
  if #profs > 0 then return table.concat(profs, ", ") end
  return nil
end

local function memberSub(r)
  return (r.race and (r.race .. " ") or "") .. View.ClassName(r.class) .. ", level " .. tostring(r.level or "?")
end

-- The member as one text card: { name, sub = "Undead Priest, level 60", facts, notes }, or nil when nothing is
-- selected. The Roster panel draws View.MemberPanel now; this card has no caller in the addon.
function View.MemberCard(r, canSeeOfficerNotes)
  if type(r) ~= "table" then return nil end
  local sub = memberSub(r)
  local rows = { { "Rank", r.rank } }
  local profs = profsText(r)
  if profs then table.insert(rows, { "Professions", profs }) end
  table.insert(rows, { "Last online", r.last })
  if r.online and r.zone then table.insert(rows, { "Zone", r.zone }) end
  local facts = {}
  addRows(facts, rows)
  local notes = {}
  addRows(notes, { { "Public note", r.note or "none" } })
  if canSeeOfficerNotes then
    addRows(notes, { { "Officer note", r.officerNote or "none" } })
  else
    table.insert(notes, LABEL .. "Officer notes hidden" .. END)
  end
  return { name = r.name, sub = sub, facts = table.concat(facts, "\n"), notes = table.concat(notes, "\n") }
end

-- The Roster's member panel as data: name, sub, rank in its tier colour, facts { label, value, green } (Last online,
-- Zone when online, Professions when recorded), the notes; nil when nothing is selected.
function View.MemberPanel(r, canSeeOfficerNotes, raiderOrder)
  if type(r) ~= "table" then return nil end
  local facts = { { label = "Last online", value = r.last, green = r.online or nil } }
  if r.online and r.zone then table.insert(facts, { label = "Zone", value = r.zone }) end
  local profs = profsText(r)
  if profs then table.insert(facts, { label = "Professions", value = profs }) end
  local p = {
    name = r.name, sub = memberSub(r), rank = r.rank,
    rankColor = View.TIER_TEXT[View.RankTier(r.rankOrder, raiderOrder)],
    facts = facts, publicNote = r.note and escape(r.note) or "none",
  }
  if canSeeOfficerNotes then p.officerNote = r.officerNote and escape(r.officerNote) or "none" else p.officerHidden = "Officer notes hidden" end
  return p
end

-- Chip button width for its text, estimated (the fake client and some fonts give no text width).
function View.ChipWidth(text)
  return #tostring(text) * 6 + 24
end

-- Places chips left to right, wrapping to a new line when the next one would pass maxWidth.
-- Returns { { x, line }, ... }, line 0-based.
function View.ChipLayout(widths, maxWidth, gap)
  local out, x, line = {}, 0, 0
  for i, w in ipairs(widths) do
    if x > 0 and x + w > maxWidth then x, line = 0, line + 1 end
    out[i] = { x = x, line = line }
    x = x + w + gap
  end
  return out
end

-- ---------- the window: pages, title, size ----------

-- The sidebar, top to bottom. Pages that do not exist yet (Guild log, Professions) are not listed (d139).
View.PAGES = {
  { key = "overview", label = "Overview", icon = "Interface\\Icons\\INV_Misc_Map_01" },
  { key = "roster", label = "Roster", icon = "Interface\\Icons\\Ability_Warrior_RallyingCry" },
  { key = "char", label = "This character", icon = "Interface\\Icons\\INV_Misc_Bag_10" },
  { key = "modules", label = "Modules", icon = "Interface\\Icons\\INV_Misc_Gear_01" }, -- the suite's addons (R7, q316)
  -- opened by the gear in the title bar, not by a sidebar row
  { key = "settings", label = "Settings", icon = "Interface\\Icons\\INV_Misc_Gear_01", gear = true },
  -- opened by the search box in the title band, not by a sidebar row (landing 2)
  { key = "search", label = "Search", icon = "Interface\\Icons\\INV_Misc_Spyglass_03", band = true },
}
View.DEFAULT_PAGE = "overview" -- the page the window opens on after a login or a reload
-- Window size (d140): the size it starts at, and how small and how large the corner grip lets it go.
View.WINDOW = { w = 900, h = 600, minW = 760, minH = 480, maxW = 1400, maxH = 1000 }
View.DETAIL_W = 200    -- the Roster page's side panel, which keeps its width when the window grows
View.GAP = 10          -- between blocks
View.SCROLLBAR_W = 26  -- what a scroll frame's bar takes on its right
View.LIST_BAR_W = 18   -- what the Roster list's minimal scroll bar takes on its right (rowW = listW - this)
-- The Roster page, px from the page top (y down, positive; Window negates): filter dropdown, search box (right edge
-- on the list area's right edge, rowW), column headers, rows.
View.ROSTER = {
  filter = { x = 8, y = 1, w = 160, h = 25 },
  search = { y = 2, w = 180, h = 22 },
  headerY = 32, headerH = 19, rowY = 54, rowH = 20, bar = View.LIST_BAR_W,
}
-- The Roster's member panel, px from the panel's top left (y down, positive).
View.MEMBER_PANEL = {
  header = { x = 6, y = 8, w = 188, h = 26 },
  icon = { x = 10, y = 42, size = 36 },
  sub = { x = 54, y = 47 },
  rank = { x = 54, y = 65 },
  facts = { y = 92, step = 16, labelX = 10, valueX = 86 },
  divider = { x = 6, y = 146, w = 188, h = 1 },
  notes = { x = 10, publicLabel = 156, publicValue = 171, officerLabel = 191, officerValue = 206 },
  pick = { x = 10, y = 42 },
  -- module member sections (API 7) under the notes: a second divider at (6,228), then a scroll area from y top to
  -- View.SectionArea's bottom (scrollW wide, classicW with the classic bar); sections at contentX, pad from the top,
  -- gap apart; the bar from barX. minH: a shorter area is hidden.
  sections = { divider = { 6, 228, 188, 1 }, top = 232, scrollW = 178, classicW = 176, contentX = 10, pad = 6, gap = 12,
    barX = 184, minH = 12 },
}
View.SECTION_W = 166 -- a member section's width
View.MAX_SECTION_H = 2000 -- a taller member section is cut to this

-- The member sections' area for a panel panelH tall with that many officer buttons: top and bottom, px down from the
-- panel top. The bottom is 8 above the topmost button (22 high, 4 apart, from 8 up), or 10 above the foot line with
-- none. nil when the area would be under minH high.
function View.SectionArea(panelH, buttons)
  local S = View.MEMBER_PANEL.sections
  if type(panelH) ~= "number" then return nil end
  local n = tonumber(buttons) or 0
  local bottom = panelH - (n > 0 and (n * 26 + 12) or 30)
  if bottom - S.top < S.minH then return nil end
  return S.top, bottom
end
View.ONLINE_GREEN = { 0.1, 1.0, 0.1 }
View.SEARCH_HINT = "Search name or note"
View.SEARCH_HINT_BAND = "Search everything" -- the title band's search box (mock se-1)
-- Roster rows: the class icon, then the name (takes what is left), then fixed rank, level and last online columns.
View.ROW_COLS = { icon = 20, rank = 110, level = 44, last = 84 }

-- The window shell, in px from the window's TOPLEFT (TOPRIGHT for counts and gear; BOTTOMRIGHT for right/bottom).
-- side = the sidebar inset, content = the content inset, page = the page area (content inset + pad on every side).
View.SHELL = {
  side = { x = 8, top = -62, bottom = 10, w = 132 },
  content = { left = 146, top = -62, right = -8, bottom = 10 },
  pad = 10,
  page = { left = 156, top = -72, right = -18, bottom = 20 },
  banner = { x = 146, y = -34 },
  counts = { x = -59, y = -7 },
  gear = { x = -28, y = 0, w = 25, h = 23 },
  search = { x = -8, y = -28, w = 200, h = 22 }, -- the title band's search box, TOPRIGHT (mock se-1)
}
-- Sidebar rows inside the sidebar inset: Overview, Roster, This character, Modules at rows[i]; module row i at
-- moduleY - (i - 1) * step.
View.SIDE = {
  rowW = 124, rowH = 26, iconX = 6, icon = 18, labelX = 30,
  rows = { -6, -36, -66, -96 },
  moduleY = -136, step = 30,
}

local DOT = " \194\183 " -- " · "

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v) return math.floor(v + 0.5) end

-- "Andorhal Grain Company · GuildSync", or "GuildSync" with no guild recorded.
function View.TitleText(guild)
  local name = type(guild) == "table" and str(guild.name) or nil
  if not name then return "GuildSync" end
  return name .. DOT .. "GuildSync"
end

-- "12 members · 3 online" for the right side of the title bar; "" with no roster.
function View.TitleCounts(rows)
  if type(rows) ~= "table" or #rows == 0 then return "" end
  local online = 0
  for _, r in ipairs(rows) do if r.online then online = online + 1 end end
  return #rows .. " members" .. DOT .. online .. " online"
end

-- Width and height kept between the min and the max, and never larger than the screen (when it is known).
function View.ClampSize(w, h, screenW, screenH)
  local W = View.WINDOW
  local maxW, maxH = W.maxW, W.maxH
  if type(screenW) == "number" and screenW > 0 then maxW = math.max(W.minW, math.min(maxW, math.floor(screenW))) end
  if type(screenH) == "number" and screenH > 0 then maxH = math.max(W.minH, math.min(maxH, math.floor(screenH))) end
  w = type(w) == "number" and w or W.w
  h = type(h) == "number" and h or W.h
  return clamp(round(w), W.minW, maxW), clamp(round(h), W.minH, maxH)
end

-- Where the window opens: w, h, and x, y of its top-left corner from the screen's bottom-left, or nil, nil for
-- the centre. saved = GuildSyncDB3.settings.window { w, h, x, y }. The window is kept on the screen.
function View.WindowPlacement(saved, screenW, screenH)
  local s = type(saved) == "table" and saved or {}
  local w, h = View.ClampSize(s.w, s.h, screenW, screenH)
  local x, y = s.x, s.y
  if type(x) ~= "number" or type(y) ~= "number" then return w, h, nil, nil end
  if type(screenW) == "number" and screenW > 0 then x = clamp(x, 0, math.max(0, screenW - w)) end
  if type(screenH) == "number" and screenH > 0 then y = clamp(y, math.min(h, screenH), screenH) end
  return w, h, round(x), round(y)
end

-- The sizes every page lays out from, for a window of w x h: the page area of View.SHELL (w - 174, h - 92).
function View.WindowLayout(w, h)
  local G = View.GAP
  local P = View.SHELL.page
  local contentW = w - P.left + P.right
  local contentH = h + P.top - P.bottom
  local listW = contentW - View.DETAIL_W - G
  return {
    contentW = contentW, contentH = contentH,
    listW = listW, rowW = listW - View.LIST_BAR_W,
    cellW = contentW / 4,
    colW = math.floor((contentW - G) / 2),
  }
end

-- The Overview's block tops (px below the page top) for a page contentH tall. The guild log shows only when its
-- last row fits (contentH >= need).
function View.OverviewLayout(contentH)
  local headerH, rowH = 26, 20
  local cols = 131
  local logHeader = 367
  local logRows = logHeader + 30
  local need = logRows + View.LOG_LIMIT * rowH
  return {
    strip = 0, mix = 66, chips = 99, cols = cols, rows = cols + headerH + 4,
    logHeader = logHeader, logRows = logRows, need = need,
    headerH = headerH, rowH = rowH, stripH = 56, barX = 120, barH = 29, fillY = 7, fillH = 15,
    logShown = type(contentH) == "number" and contentH >= need,
  }
end

-- x and width of the Name, Rank, Level and Last online headers (View.COLUMNS order) in a row rowW wide.
function View.RosterColumns(rowW)
  local c = View.ROW_COLS
  local rest = rowW - c.icon - c.rank - c.level - c.last
  local widths = { math.max(40, rest), c.rank, c.level, c.last }
  local x = c.icon
  local out = {}
  for i, w in ipairs(widths) do
    out[i] = { x = x, w = w }
    x = x + w
  end
  return out
end

-- ---------- rank badges ----------

View.RAIDER_RANK = "Raider" -- the Raiders tile counts members at this rank or above it in the guild's rank order
View.TIER_COLORS = {
  lead = { 0.83, 0.64, 0.30 }, officer = { 0.55, 0.40, 0.80 }, raider = { 0.25, 0.50, 0.80 }, member = { 0.40, 0.40, 0.40 },
}
-- Rank names as text (the Overview); the Roster badges keep TIER_COLORS.
View.TIER_TEXT = {
  lead = { 0.83, 0.64, 0.30 }, officer = { 0.55, 0.40, 0.80 }, raider = { 0.25, 0.50, 0.80 }, member = { 0.6, 0.6, 0.6 },
}

-- 0-based place of RAIDER_RANK in the guild's rank list, or nil when the guild has no rank of that name.
function View.RaiderOrder(ranks)
  if type(ranks) ~= "table" then return nil end
  for i, name in ipairs(ranks) do if name == View.RAIDER_RANK then return i - 1 end end
  return nil
end

-- Badge colour of a rank: lead (the top rank), officer (above Raider), raider, member (below Raider or unknown).
function View.RankTier(order, raiderOrder)
  if order == 0 then return "lead" end
  if type(order) ~= "number" or type(raiderOrder) ~= "number" then return "member" end
  if order < raiderOrder then return "officer" end
  if order == raiderOrder then return "raider" end
  return "member"
end

-- ---------- Overview page ----------

View.MAX_LEVEL = 60
View.ONLINE_LIMIT = 8
View.PROF_MAX_SKILL = 300 -- a profession counts as maxed at this skill
View.PROF_TARGET = 2      -- members at max skill the guild wants in each profession: the bar is full at this many
View.PROF_LIMIT = 10 -- every primary profession fits (a roster records two per member)
View.LOG_LIMIT = 5
View.NOBODY_ONLINE = "Nobody online."
View.NO_PROFESSIONS = "No professions recorded yet."
View.LOG_EMPTY = "No guild log recorded yet."

-- The four tiles: { { key, label, value, hint }, ... }. value nil = can't be counted (shown as "?").
function View.StatTiles(rows, ranks)
  local online, raiders, maxed, away = 0, 0, 0, 0
  local ro = View.RaiderOrder(ranks)
  for _, r in ipairs(rows or {}) do
    if r.online then online = online + 1 end
    if ro and r.rankOrder <= ro then raiders = raiders + 1 end
    if type(r.level) == "number" and r.level >= View.MAX_LEVEL then maxed = maxed + 1 end
    if isInactive(r) then away = away + 1 end
  end
  return {
    { key = "online", label = "Online now", value = online, hint = "Online at the last scan" },
    { key = "raiders", label = "Raiders", value = ro and raiders or nil,
      hint = ro and ("Rank " .. View.RAIDER_RANK .. " or above") or ("The guild has no rank named " .. View.RAIDER_RANK) },
    { key = "max", label = "Level " .. View.MAX_LEVEL, value = maxed, hint = "Members at level " .. View.MAX_LEVEL },
    { key = "away", label = "Away " .. View.INACTIVE_DAYS .. "+ days", value = away,
      hint = "Offline " .. View.INACTIVE_DAYS .. " days or more" },
  }
end

function View.TileValue(tile)
  if type(tile) ~= "table" or type(tile.value) ~= "number" then return "?" end
  return tostring(tile.value)
end

-- Classes of the members at MAX_LEVEL: { { class, name, count }, ... }, most first, then by name; and the total.
function View.ClassMix(rows)
  local by, list, total = {}, {}, 0
  for _, r in ipairs(rows or {}) do
    if r.class and type(r.level) == "number" and r.level >= View.MAX_LEVEL then
      if not by[r.class] then
        by[r.class] = { class = r.class, name = View.ClassName(r.class), count = 0 }
        table.insert(list, by[r.class])
      end
      by[r.class].count = by[r.class].count + 1
      total = total + 1
    end
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  return list, total
end

-- "Warrior 7 · Paladin 5 · ..."
function View.ClassMixCaption(list)
  if type(list) ~= "table" or #list == 0 then return "Nobody at " .. View.MAX_LEVEL .. " yet." end
  local parts = {}
  for i, c in ipairs(list) do parts[i] = c.name .. " " .. c.count end
  return table.concat(parts, DOT)
end

-- Whole-pixel widths of the class mix segments, in list order, adding up to width exactly.
function View.SegmentWidths(list, width)
  local total = 0
  for _, c in ipairs(list or {}) do total = total + c.count end
  local out = {}
  if total == 0 or type(width) ~= "number" or width <= 0 then return out end
  width = math.floor(width)
  local used, rest = 0, {}
  for i, c in ipairs(list) do
    local exact = width * c.count / total
    out[i] = math.floor(exact)
    used = used + out[i]
    rest[i] = { i = i, frac = exact - out[i] }
  end
  table.sort(rest, function(a, b)
    if a.frac ~= b.frac then return a.frac > b.frac end
    return a.i < b.i
  end)
  for k = 1, width - used do out[rest[k].i] = out[rest[k].i] + 1 end
  return out
end

-- Members online, in rank order then by name: the first `limit` rows, and how many more there are.
function View.OnlineList(rows, limit)
  local on = {}
  for _, r in ipairs(rows or {}) do if r.online then table.insert(on, r) end end
  table.sort(on, function(a, b)
    if a.rankOrder ~= b.rankOrder then return a.rankOrder < b.rankOrder end
    local na, nb = string.lower(a.name), string.lower(b.name)
    if na ~= nb then return na < nb end
    return a.guid < b.guid
  end)
  limit = limit or View.ONLINE_LIMIT
  local shown = {}
  for i = 1, math.min(limit, #on) do shown[i] = on[i] end
  return shown, #on - #shown
end

function View.MoreText(n)
  if type(n) ~= "number" or n <= 0 then return "" end
  return n .. " more"
end

-- Icon of a profession by its skill line id, then by its name. These are the professions' own spell icons.
local PROF_ICONS = {
  [164] = "Trade_BlackSmithing", [165] = "Trade_LeatherWorking", [171] = "Trade_Alchemy", [182] = "Spell_Nature_NatureTouchGrow",
  [186] = "Trade_Mining", [197] = "Trade_Tailoring", [202] = "Trade_Engineering", [333] = "Trade_Engraving",
  [393] = "INV_Misc_Pelt_Wolf_01", [755] = "INV_Misc_Gem_01", [773] = "INV_Inscription_Tradeskill01",
  [185] = "INV_Misc_Food_15", [129] = "Spell_Holy_SealOfSacrifice", [356] = "Trade_Fishing",
}
local PROF_IDS = {
  blacksmithing = 164, leatherworking = 165, alchemy = 171, herbalism = 182, mining = 186, tailoring = 197,
  engineering = 202, enchanting = 333, skinning = 393, jewelcrafting = 755, inscription = 773, cooking = 185,
  ["first aid"] = 129, fishing = 356,
}
local ICONS = "Interface\\Icons\\"
View.UNKNOWN_ICON = ICONS .. "INV_Misc_QuestionMark"

function View.ProfessionIcon(id, name)
  local file = PROF_ICONS[id]
  if not file and type(name) == "string" then file = PROF_ICONS[PROF_IDS[string.lower(name)] or 0] end
  return file and (ICONS .. file) or View.UNKNOWN_ICON
end

-- True for an icon from Interface\Icons (those get their border trimmed).
function View.IsGameIcon(path)
  return type(path) == "string" and string.sub(path, 1, #ICONS) == ICONS
end

-- One row per profession in the recorded roster: { name, id, icon, count, maxed, bar, barText, who }, the best
-- covered first. bar = members at max skill, up to PROF_TARGET; who = { "Anya 300", ... }, highest skill first.
function View.ProfessionsCovered(rows)
  local by, list = {}, {}
  for _, r in ipairs(rows or {}) do
    for _, p in ipairs({ r.prof1 or false, r.prof2 or false }) do
      local name = type(p) == "table" and str(p.name) or nil
      if name then
        local e = by[name]
        if not e then
          e = { name = name, id = type(p.id) == "number" and p.id or nil, count = 0, maxed = 0, members = {} }
          by[name] = e
          table.insert(list, e)
        end
        local rank = type(p.rank) == "number" and p.rank or nil
        e.count = e.count + 1
        if rank and rank >= View.PROF_MAX_SKILL then e.maxed = e.maxed + 1 end
        table.insert(e.members, { name = r.name, rank = rank or -1 })
      end
    end
  end
  for _, e in ipairs(list) do
    table.sort(e.members, function(a, b)
      if a.rank ~= b.rank then return a.rank > b.rank end
      return string.lower(a.name) < string.lower(b.name)
    end)
    e.who = {}
    for i, m in ipairs(e.members) do e.who[i] = m.name .. (m.rank >= 0 and (" " .. m.rank) or "") end
    e.members = nil
    e.icon = View.ProfessionIcon(e.id, e.name)
    e.bar = math.min(e.maxed, View.PROF_TARGET)
    e.barText = e.maxed .. "/" .. View.PROF_TARGET .. " at " .. View.PROF_MAX_SKILL
  end
  table.sort(list, function(a, b)
    if a.maxed ~= b.maxed then return a.maxed > b.maxed end
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  return list
end

-- Tooltip lines for a profession row: the name, then who has it.
function View.ProfessionTooltip(p)
  local lines = { p.name .. ": " .. p.count .. (p.count == 1 and " member" or " members") }
  for _, w in ipairs(p.who or {}) do table.insert(lines, w) end
  return lines
end

-- ---------- guild log ----------

View.LOG_ICONS = {
  join = ICONS .. "Spell_ChargePositive", leave = ICONS .. "Spell_ChargeNegative",
  promote = "Interface\\Buttons\\Arrow-Up-Up", demote = "Interface\\Buttons\\Arrow-Down-Up",
  remove = "Interface\\Buttons\\UI-GroupLoot-Pass-Up", invite = ICONS .. "INV_Letter_15",
}
local LOG_KINDS = { join = "join", quit = "leave", promote = "promote", demote = "demote", remove = "remove", invite = "invite" }

-- "<1 h", "5 h", "1 day", "3 days", "2 weeks", "4 months", or "?" without a time.
function View.AgeText(seconds)
  if type(seconds) ~= "number" then return "?" end
  if seconds < 3600 then return "<1 h" end
  local hours = math.floor(seconds / 3600)
  if hours < 24 then return hours .. " h" end
  local days = math.floor(hours / 24)
  if days == 1 then return "1 day" end
  if days < 14 then return days .. " days" end
  if days < 60 then return math.floor(days / 7) .. " weeks" end
  return math.floor(days / 30) .. " months"
end

-- The entry's sentence ("Anya Dusk promoted Esk Thorn to Veteran"), each recorded name through esc.
local function logSentence(kind, e, esc)
  local actor, target, rank = esc(str(e.actor) or "?"), esc(str(e.target) or "?"), str(e.rank)
  rank = rank and esc(rank)
  if kind == "join" then return target .. " joined" end
  if kind == "leave" then return target .. " left" end
  if kind == "promote" or kind == "demote" then
    return actor .. " " .. kind .. "d " .. target .. (rank and (" to " .. rank) or "")
  end
  if kind == "remove" then return actor .. " removed " .. target end
  return actor .. " invited " .. target
end

-- LogEntry's sentence from the raw fields, unescaped (the search matches it; View.SearchList escapes it), nil for
-- other kinds.
function View.LogEntryRaw(e)
  if type(e) ~= "table" or not LOG_KINDS[e.type] then return nil end
  return logSentence(LOG_KINDS[e.type], e, function(v) return v end)
end

-- A recorded guild log entry { type, actor, target, rank, ts } -> { kind, icon, text, age }, nil for other kinds.
function View.LogEntry(e, now)
  if type(e) ~= "table" then return nil end
  local kind = LOG_KINDS[e.type]
  if not kind then return nil end
  local text = logSentence(kind, e, escape)
  local age = (type(e.ts) == "number" and type(now) == "number") and View.AgeText(math.max(0, now - e.ts)) or "?"
  return { kind = kind, icon = View.LOG_ICONS[kind], text = text, age = age }
end

-- The recorded entries of GuildSyncDB3.guildLog as { e }, newest first (later in the list first on a tie).
local function logNewestFirst(log)
  local entries = type(log) == "table" and type(log.entries) == "table" and log.entries or {}
  local order = {}
  for i, e in ipairs(entries) do
    if type(e) == "table" then table.insert(order, { i = i, ts = type(e.ts) == "number" and e.ts or -1, e = e }) end
  end
  table.sort(order, function(a, b)
    if a.ts ~= b.ts then return a.ts > b.ts end
    return a.i > b.i
  end)
  return order
end

-- The newest `limit` entries of GuildSyncDB3.guildLog, newest first.
function View.RecentLog(log, now, limit)
  local order = logNewestFirst(log)
  local out = {}
  limit = limit or View.LOG_LIMIT
  for _, o in ipairs(order) do
    if #out >= limit then break end
    local entry = View.LogEntry(o.e, now)
    if entry then table.insert(out, entry) end
  end
  return out
end

-- ---------- officer actions on the Roster's side panel (0.9) ----------
-- Who may do what to the selected member, note checks and the chat lines. Window.lua asks the client
-- (Compat.GuildPermissions) and makes the one client call a click allows; everything it decides is here.
-- Rank indexes are 0-based (0 = Guild Master), as in the recorded roster.

View.NOTE_MAX = 31 -- letters in a public or officer note on the classic family
View.CONFIRM_SECONDS = 8 -- after an action, how long the roster has to show it before GuildSync says it did not
View.NOT_YOURS = "Not yours to change."
View.WAIT_LOADING = "Officer actions wait until the roster has loaded."
View.WAIT_OTHER = "The roster was recorded on another character: rescan on this one first."
View.WAIT_COMBAT = "Officer actions wait until combat ends."
View.WAIT_PENDING = "Waiting for the roster to show the last change."

-- me = Compat.GuildPermissions(): { guid, rankIndex, promote, demote, remove, editPublic, editOfficer }, or nil.
-- r = a roster row. numRanks = how many ranks the guild has. Returns { promote, demote, remove, editPublic,
-- editOfficer, any }: never yourself, never anyone at or above your own rank, never a promote to your rank or above,
-- never a demote below the lowest rank. Notes need only their permission.
function View.MemberActions(me, r, numRanks)
  local out = { promote = false, demote = false, remove = false, editPublic = false, editOfficer = false, any = false }
  if type(me) ~= "table" or type(r) ~= "table" then return out end
  out.editPublic = me.editPublic == true
  out.editOfficer = me.editOfficer == true
  local mine, theirs = me.rankIndex, r.rankOrder
  local isSelf = me.guid ~= nil and me.guid == r.guid
  if not isSelf and type(mine) == "number" and type(theirs) == "number" and theirs ~= LAST and theirs > mine then
    out.promote = me.promote == true and theirs - 1 > mine
    out.demote = me.demote == true and type(numRanks) == "number" and theirs < numRanks - 1
    out.remove = me.remove == true
  end
  out.any = out.promote or out.demote or out.remove or out.editPublic or out.editOfficer
  return out
end

-- Why no action may run right now, or nil. s = { own (the roster was recorded by this character), partial, combat,
-- pending (a rank change or removal the roster does not show yet) }.
function View.ActionBlock(s)
  if type(s) ~= "table" then return View.WAIT_LOADING end
  if not s.own then return View.WAIT_OTHER end
  if s.partial then return View.WAIT_LOADING end
  if s.combat then return View.WAIT_COMBAT end
  if s.pending then return View.WAIT_PENDING end
  return nil
end

local function letterCount(s)
  local _, n = string.gsub(s, "[^\128-\191]", "")
  return n
end

-- A note as typed -> the note to save (line breaks become spaces, outer spaces dropped), or nil and why.
function View.CleanNote(text)
  local s = trim((string.gsub(tostring(text or ""), "[\r\n\t]", " ")))
  if letterCount(s) > View.NOTE_MAX then return nil, "A note holds at most " .. View.NOTE_MAX .. " letters." end
  return s
end

-- The notes window's changes, in the order Save makes them (public first): { { isPublic, note }, ... }, or nil and
-- why. saved / edited = { public, officer }; can = { editPublic, editOfficer }. One Save click saves one of them.
function View.NoteChanges(saved, edited, can)
  saved, edited, can = saved or {}, edited or {}, can or {}
  local out = {}
  local fields = { { key = "public", isPublic = true, allowed = can.editPublic },
    { key = "officer", isPublic = false, allowed = can.editOfficer } }
  for _, f in ipairs(fields) do
    if f.allowed and edited[f.key] ~= nil then
      local note, why = View.CleanNote(edited[f.key])
      if not note then return nil, why end
      if note ~= (saved[f.key] or "") then table.insert(out, { isPublic = f.isPublic, note = note }) end
    end
  end
  return out
end

-- A note box's text -> the note: an edit box holds a typed "|" as "||".
function View.NoteFromBox(text)
  return (string.gsub(tostring(text or ""), "||", "|"))
end

-- A note -> the note box's text: every "|" doubled, so a stored colour or link code shows as text, not markup.
function View.NoteToBox(note)
  return (string.gsub(tostring(note or ""), "|", "||"))
end

-- Lines when a member's rank in game is not the recorded one at click time (Window.lua: no call then).
function View.RankChangedLine(name)
  return tostring(name) .. "'s rank changed since the last scan: nothing done, the roster is read again."
end
function View.RankUnreadLine(name)
  return "could not read " .. tostring(name) .. "'s rank in game: nothing done."
end

-- The chat line after a call (ns.Say puts "GuildSync: " in front).
function View.ActionLine(kind, name, rank)
  name = tostring(name)
  if kind == "promote" then return "promoted " .. name .. " to " .. escape(rank) .. "." end
  if kind == "demote" then return "demoted " .. name .. " to " .. escape(rank) .. "." end
  if kind == "remove" then return "removed " .. name .. " from the guild." end
  if kind == "public" then return "public note saved for " .. name .. "." end
  if kind == "officer" then return "officer note saved for " .. name .. "." end
  return tostring(kind) .. " " .. name .. "."
end

function View.RemoveQuestion(name)
  return "Remove " .. tostring(name) .. " from the guild? They can be invited again."
end

-- Has the recorded roster caught up with an action? p = { kind, guid, rankOrder (expected), note }, guild =
-- GuildSyncDB3.guild. "done", "notyet", or "unknown" (the roster cannot show it: a partial list, a hidden officer note).
function View.PendingResult(p, guild)
  if type(p) ~= "table" or type(guild) ~= "table" or type(guild.members) ~= "table" then return "notyet" end
  local m = guild.members[p.guid]
  if p.kind == "remove" then
    if m ~= nil then return "notyet" end
    return guild.partial and "unknown" or "done"
  end
  if type(m) ~= "table" then return "unknown" end
  if p.kind == "promote" or p.kind == "demote" then return m.rankIndex == p.rankOrder and "done" or "notyet" end
  if p.kind == "public" then return (m.note or "") == p.note and "done" or "notyet" end
  if p.kind == "officer" then
    if not guild.canSeeOfficerNotes then return "unknown" end
    return (m.officerNote or "") == p.note and "done" or "notyet"
  end
  return "unknown"
end

-- The plain line when the roster did not show an action in time.
function View.FailLine(p)
  local name = tostring(type(p) == "table" and p.name or "?")
  local tail = ": the game did not take it (see its message in chat)."
  if type(p) == "table" and p.kind == "remove" then return name .. " is still in the guild" .. tail end
  if type(p) == "table" and (p.kind == "public" or p.kind == "officer") then
    return name .. "'s " .. p.kind .. " note did not change" .. tail
  end
  return name .. "'s rank did not change" .. tail
end

-- ---------- the Modules page (R7, d407-d409, q319) ----------
-- Rows from ns.SUITE (Suite.lua) and Compat.AddOn: names, lines and icons only from Suite.lua (d409); the TOC version
-- is shown only when it is a good version (else "?"). Guildmates are counts only (d408).

-- An addon version we accept: CommVersion.lua's goodVersion (f1194; up to 16 letters, digits, dots, dashes or
-- underscores, so never a "|"). Repeated here because View loads before CommVersion.
local function goodVersion(v)
  return type(v) == "string" and #v <= 16 and v:match("^[%w%.%-_]+$") ~= nil
end

View.SUITE_DASH = "\226\128\147" -- "–", the version of an addon that is not installed
View.SUITE_SUBLINE = "The guild's addons. Installed ones are on this character's AddOns list."
View.SUITE_COLUMNS = { "Name", "Version", "State", "Guildmates" }
View.SUITE_MATES_TIP = { "Guildmates", "Guildmates heard running it this week." }
View.SUITE_HEARD_DAYS = 7
-- state -> pill text, tone and group (q322: the hub, then On, Off, Needs newer, Error, Not installed)
local SUITE_STATES = {
  hub = { "Always on", "gold", 0 }, on = { "On", "green", 1 }, off = { "Off", "grey", 2 },
  needsNewer = { "Needs newer GuildSync", "red", 3 }, error = { "Error", "red", 4 },
  missing = { "Not installed", "grey", 5 },
}

-- "<name> [<version> ]needs GuildSync API <needs>. This GuildSync is <hubVersion> with API <api>. Update GuildSync."
-- The version is left out when missing or not a good version; every value escaped once. Api.lua's refusal uses it too.
function View.NeedsNewerLine(name, version, needs, hubVersion, api)
  local who = escape(name)
  if goodVersion(version) then who = who .. " " .. version end
  return who .. " needs GuildSync API " .. escape(needs) .. ". This GuildSync is " .. escape(hubVersion) .. " with API "
    .. escape(api) .. ". Update GuildSync."
end

-- suite = ns.SUITE, read = Compat.AddOn, needsNewer = ns.NeedsNewer, heard = View.SuiteHeard's map (or demo counts).
-- -> { { folder, id, name, icon, line, state, pill, tone, version, sub, count, dim, needs }, ... } in q322 order.
function View.SuiteRows(suite, read, needsNewer, heard)
  local rows = {}
  needsNewer = type(needsNewer) == "table" and needsNewer or {}
  heard = type(heard) == "table" and heard or {}
  for _, s in ipairs(type(suite) == "table" and suite or {}) do
    local a = (type(read) == "function" and read(s.folder)) or {}
    local r = { folder = s.folder, id = s.id, name = s.name, icon = s.icon, line = s.line,
      count = tonumber(heard[s.id]) or 0 }
    if s.hub then
      r.state, r.version, r.sub = "hub", escape(ns.VERSION), "API " .. escape(ns.API or "?")
    else
      if not a.exists then r.state = "missing"
      elseif not a.loaded then r.state = a.reason == "DISABLED" and "off" or "error"
      elseif needsNewer[s.id] then r.state, r.needs = "needsNewer", needsNewer[s.id]
      else r.state = "on" end
      -- only a good version is shown (f3352: up to 16 letters, never a "|"); Compat.AddOn already maps a non-X.Y.Z TOC Version to 0.0.0-dev, so "?" is only a defence
      r.version = (a.exists and type(a.version) == "string") and (goodVersion(a.version) and a.version or "?")
        or View.SUITE_DASH
      if r.needs then r.sub = "needs API " .. escape(r.needs) end
      r.dim = r.state == "missing" or nil
    end
    local st = SUITE_STATES[r.state]
    r.pill, r.tone, r.group = st[1], st[2], st[3]
    rows[#rows + 1] = r
  end
  table.sort(rows, function(x, y)
    if x.group ~= y.group then return x.group < y.group end
    return tostring(x.name) < tostring(y.name)
  end)
  return rows
end

-- versions = Comm.Version.Versions(), roster = Comm.Roster() -> { [id] = n, total = roster size }: roster keys seen in
-- the last 7 days holding mods[id]; the hub id counts entries with addon set. Counts only, no names (d408).
function View.SuiteHeard(versions, roster, now)
  local out, total = {}, 0
  roster = type(roster) == "table" and roster or {}
  versions = type(versions) == "table" and versions or {}
  local since = (tonumber(now) or 0) - View.SUITE_HEARD_DAYS * 86400
  for key in pairs(roster) do
    total = total + 1
    local e = versions[key]
    if type(e) == "table" and (tonumber(e.seen) or -math.huge) >= since then
      if e.addon then out.guildsync = (out.guildsync or 0) + 1 end
      for id in pairs(type(e.mods) == "table" and e.mods or {}) do out[id] = (out[id] or 0) + 1 end
    end
  end
  out.total = total
  return out
end

-- The page's columns for a page pageW wide (the approved mock): Name flexes, Version 70, State 132, Guildmates 76.
function View.SuiteLayout(pageW)
  local nameW = pageW - 292
  return { name = { x = 0, w = nameW }, version = { x = nameW, w = 70 }, state = { x = nameW + 70, w = 132 },
    mates = { x = nameW + 202, w = 76 }, listW = pageW - 14, lineW = nameW - 56, barX = pageW - 8 }
end

-- The row's tooltip line (the header is the name).
function View.SuiteTooltip(row, api, hubVersion)
  local st, name = row.state, escape(row.name)
  if st == "hub" then
    return "GuildSync " .. escape(hubVersion) .. ", API " .. escape(api) .. ". The hub; always on."
  end
  if st == "on" then -- no version named when the TOC has none (f3309)
    return name .. (row.version ~= View.SUITE_DASH and " " .. tostring(row.version) or "") .. ". On for this character."
  end
  if st == "off" then
    return name .. " is turned off for this character. Turn it on in the AddOns list at the character screen."
  end
  if st == "error" then return "Did not load: see /gsync errors." end
  if st == "needsNewer" then return View.NeedsNewerLine(row.name, row.version, row.needs, hubVersion, api) end
  return "Not installed. Ask an officer for the suite download."
end

-- ---------- the Guildmates tab (API 8, f6209, d1047, d1049) ----------
-- One row per roster member in three groups (heard this week, as SuiteHeard counts; heard earlier; no addon heard),
-- over one merged map (Versions() plus this client's own entry). Rows carry kind "header" or "member".

View.WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" } -- fixed English, never the locale's %a
View.HEARD_NOW = 600 -- seconds that read "now"
View.TRACKER_OLD = { 1, 0.5, 0.1 } -- an older version's colour
View.TRACKER_GROUPS = { { "week", "Heard this week" }, { "earlier", "Heard earlier" }, { "none", "No addon heard" } }

-- -> text, grey: "now" within 10 minutes, "HH:MM" earlier today, the weekday under 7 days, then "<n> days" (7-13) and
-- "<n> weeks", grey from 7 days; "" for no seen.
function View.HeardText(seen, now)
  seen, now = tonumber(seen), tonumber(now) or 0
  if not seen then return "" end
  if now - seen < View.HEARD_NOW then return "now" end
  if date("%Y-%m-%d", seen) == date("%Y-%m-%d", now) then return date("%H:%M", seen) end
  local n = math.floor((now - seen) / 86400)
  if n < 7 then return View.WEEKDAYS[date("*t", seen).wday] end
  if n <= 13 then return n .. " days", true end
  return math.floor(n / 7) .. " weeks", true
end

-- -1 | 0 | 1, numeric per dotted part, a missing part 0 (CommVersion's Compare; View loads before it).
local function compareDotted(a, b)
  local pa, pb = {}, {}
  for part in tostring(a or ""):gmatch("[^.]+") do pa[#pa + 1] = tonumber(part) or 0 end
  for part in tostring(b or ""):gmatch("[^.]+") do pb[#pb + 1] = tonumber(part) or 0 end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  return 0
end

local function isDev(v) return v == (ns.Compat and ns.Compat.DEV_VERSION) end

-- The entry's module ids in suite order (never the hub).
local function modIds(e)
  local out = {}
  if type(e.mods) ~= "table" then return out end
  for _, s in ipairs(type(ns.SUITE) == "table" and ns.SUITE or {}) do
    if type(s) == "table" and not s.hub and e.mods[s.id] then out[#out + 1] = s.id end
  end
  return out
end

-- members = { { key, name, class }, ... }, versions = key -> entry, opts = { own = this release version or nil on a
-- dev build, isOfficer = function(key), ownKey }. -> rows, { week, earlier, none, total }, older (rows marked old).
-- Old: below the higher of own and the newest officer version (an ordinary member never raises the bar; a dev advert
-- neither raises it nor is old).
function View.TrackerRows(members, versions, now, opts)
  opts, versions = opts or {}, type(versions) == "table" and versions or {}
  local isOfficer = type(opts.isOfficer) == "function" and opts.isOfficer or function() return false end
  local bar = opts.own
  for key, e in pairs(versions) do
    if type(e) == "table" and goodVersion(e.addon) and not isDev(e.addon) and isOfficer(key)
      and (not bar or compareDotted(e.addon, bar) > 0) then bar = e.addon end
  end
  local since = (tonumber(now) or 0) - View.SUITE_HEARD_DAYS * 86400
  local groups, total, older = { week = {}, earlier = {}, none = {} }, 0, 0
  for _, m in ipairs(type(members) == "table" and members or {}) do
    total = total + 1
    local e = versions[m.key]
    local r = { kind = "member", key = m.key, name = escape(m.name or m.key or "?"), class = m.class,
      you = m.key ~= nil and m.key == opts.ownKey or nil }
    local g = "none"
    if type(e) == "table" and e.addon then
      g = (tonumber(e.seen) or -math.huge) >= since and "week" or "earlier"
      r.entry, r.dev, r.mods = e, isDev(e.addon), modIds(e)
      r.version = r.dev and "dev" or escape(e.addon)
      r.old = not r.dev and bar ~= nil and compareDotted(e.addon, bar) < 0
      r.heard, r.heardGrey = View.HeardText(e.seen, now)
      if r.old then older = older + 1 end
    end
    table.insert(groups[g], r)
  end
  local rows = {}
  for _, gr in ipairs(View.TRACKER_GROUPS) do
    local list = groups[gr[1]]
    if #list > 0 then
      table.sort(list, function(x, y) return x.name < y.name end)
      rows[#rows + 1] = { kind = "header", text = gr[2] .. DOT .. #list }
      for _, r in ipairs(list) do rows[#rows + 1] = r end
    end
  end
  return rows, { week = #groups.week, earlier = #groups.earlier, none = #groups.none, total = total }, older
end

-- The line over the list (mock tr-1): grey labels, white numbers.
function View.TrackerSummary(summary, older)
  local function n(v) return "|cffffffff" .. tostring(tonumber(v) or 0) .. "|r" end
  return n(summary.week) .. " of " .. n(summary.total) .. " heard this week" .. DOT .. n(summary.earlier) .. " earlier"
    .. DOT .. n(summary.none) .. " not heard" .. DOT .. n(older) .. " on an older version"
end

-- A row's tooltip: { header = name, lines = { "GuildSync <v>", "<Module> <v>, ..." (left out with none), "Heard <t>" } },
-- or nil for an entry without addon. Every stored value escaped once.
function View.TrackerTooltip(e, suite, now)
  if type(e) ~= "table" or not e.addon then return nil end
  local lines, mods = { "GuildSync " .. escape(e.addon) }, {}
  if type(e.mods) == "table" then
    for _, s in ipairs(type(suite) == "table" and suite or {}) do
      local v = type(s) == "table" and not s.hub and e.mods[s.id]
      if v then mods[#mods + 1] = escape(s.name) .. " " .. escape(v) end
    end
  end
  if #mods > 0 then lines[#lines + 1] = table.concat(mods, ", ") end
  lines[#lines + 1] = "Heard " .. View.HeardText(e.seen, now)
  return { header = escape(e.name or "?"), lines = lines }
end

-- ---------- What's new (API 8, d1040, d1051) ----------
-- Sections from ns.CHANGELOG (Changelog.lua). The login panel filters (the seen rule, loaded addons, empty sections
-- dropped, at most NEWS_MAX); the Modules page's tab shows the whole changelog. Lines stay raw until NewsRows.

View.NEWS_DELAY = 5 -- seconds after PLAYER_LOGIN before the panel check (retried every 5 s while in combat)
View.NEWS_MAX = 3   -- sections the login panel shows at most

local function xyz(v) return type(v) == "string" and v:match("^%d+%.%d+%.%d+$") ~= nil end

local function suiteEntry(folder)
  for _, e in ipairs(type(ns.SUITE) == "table" and ns.SUITE or {}) do
    if e.folder == folder then return e end
  end
end

local function copyLines(lines)
  local out = {}
  for _, l in ipairs(type(lines) == "table" and lines or {}) do
    if type(l) == "string" then out[#out + 1] = l end
  end
  return out
end

-- changelog = ns.CHANGELOG; seen = settings.seenVersion; version = ns.VERSION; loaded(folder) -> boolean;
-- opts = { login = true|nil, max = n|nil }. -> { { version, lines, addons = { { folder, name, lines } } } }, newest
-- first. login: sections above seen (a release build also not above its own version; no seen or a seen that is not
-- X.Y.Z: the newest only), only loaded addons' groups (GuildSync always), sections with nothing left dropped, then at
-- most max. No login: every section and every group; loaded is not called.
function View.NewsSections(changelog, seen, version, loaded, opts)
  local login = type(opts) == "table" and opts.login == true
  local firstInstall = not xyz(seen)
  local out = {}
  for _, s in ipairs(type(changelog) == "table" and changelog or {}) do
    local v = type(s) == "table" and s.version
    local eligible = xyz(v)
    if eligible and login then
      eligible = (firstInstall or compareDotted(v, seen) > 0) and (not xyz(version) or compareDotted(v, version) <= 0)
    end
    if eligible then
      local section = { version = v, lines = copyLines(s.lines), addons = {} }
      for _, g in ipairs(type(s.addons) == "table" and s.addons or {}) do
        local folder = type(g) == "table" and g.folder
        if type(folder) == "string" and (not login or folder == "GuildSync" or loaded(folder)) then
          local e = suiteEntry(folder)
          section.addons[#section.addons + 1] = { folder = folder, name = e and e.name or folder, lines = copyLines(g.lines) }
        end
      end
      if not login or #section.lines > 0 or #section.addons > 0 then out[#out + 1] = section end
    end
  end
  if login then
    local max = firstInstall and 1 or (type(opts.max) == "number" and opts.max or View.NEWS_MAX)
    for i = #out, max + 1, -1 do out[i] = nil end
  end
  return out
end

-- -> { { kind = "version"|"addon"|"line", text, icon? } }: a version row per section, its suite-wide lines, then per
-- addon group a row with its Suite.lua name (and icon) and its lines. Every text escaped once.
function View.NewsRows(sections)
  local rows = {}
  for _, s in ipairs(type(sections) == "table" and sections or {}) do
    rows[#rows + 1] = { kind = "version", text = escape(s.version) }
    for _, l in ipairs(s.lines or {}) do rows[#rows + 1] = { kind = "line", text = escape(l) } end
    for _, g in ipairs(s.addons or {}) do
      local e = suiteEntry(g.folder)
      rows[#rows + 1] = { kind = "addon", text = escape(g.name or g.folder), icon = e and e.icon }
      for _, l in ipairs(g.lines or {}) do rows[#rows + 1] = { kind = "line", text = escape(l) } end
    end
  end
  return rows
end

-- ---------- search (API 8; Search.lua runs these) ----------
-- The hub sources take the query already trimmed and lower-cased (Search.lua) and answer raw rows
-- { text, detail?, icon?, class?, go? }: nothing is escaped before View.SearchList (f6205).

View.SEARCH_MIN = 2   -- bytes a query needs
View.SEARCH_MAX = 40  -- bytes of a query any source sees
View.SEARCH_SHOWN = 5 -- rows per group before "Show all <n>"
View.SEARCH_CAP = 25  -- rows kept per group
View.SEARCH_CUT = 80  -- bytes of a module row's text and detail
View.SEARCH_SHORT = "Type at least 2 letters."
View.SEARCH_COUNT = "%d results. Escape clears the search and goes back." -- n = every hit kept (d1057)

-- RAID_CLASS_COLORS as hex, so a search row's class colour needs no client call.
View.CLASS_HEX = {
  WARRIOR = "c79c6e", PALADIN = "f58cba", HUNTER = "abd473", ROGUE = "fff569", PRIEST = "ffffff", SHAMAN = "0070de",
  MAGE = "69ccf0", WARLOCK = "9482c9", DRUID = "ff7d0a", DEATHKNIGHT = "c41f3b", MONK = "00ff96",
  DEMONHUNTER = "a330c9", EVOKER = "33937f",
}

local function hit(s, q) return type(s) == "string" and string.find(string.lower(s), q, 1, true) ~= nil end

-- Members by name or public note, and by officer note only when the guild table says this character sees them
-- (the member panel's rule). detail = the rank, plus the matched note. Sorted by name.
function View.SearchMembers(guild, q)
  local out = {}
  if type(guild) ~= "table" or type(guild.members) ~= "table" then return out end
  local ranks = guild.ranks
  for guid, m in pairs(guild.members) do
    if type(m) == "table" and str(m.name) then
      local note = str(m.note)
      local officerNote = guild.canSeeOfficerNotes == true and str(m.officerNote) or nil
      local byName = hit(m.name, q)
      local matched = not byName and ((hit(note, q) and note) or (hit(officerNote, q) and officerNote)) or nil
      if byName or matched then
        local order = rankOrder(m, ranks)
        local rank = str(m.rank) or (type(ranks) == "table" and order ~= LAST and str(ranks[order + 1])) or "?"
        -- mock se-1: "<rank> · <level> <class>", the note in quotes only when it matched (f6297, d1065)
        local detail = rank .. DOT .. tostring(m.level or "?") .. " " .. View.ClassName(m.class)
        out[#out + 1] = { text = m.name, class = str(m.class), detail = matched and (detail .. DOT .. '"' .. matched .. '"') or detail,
          go = { page = "roster", guid = tostring(guid) } }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.text ~= b.text then return a.text < b.text end
    return a.go.guid < b.go.guid
  end)
  return out
end

-- rows = SearchMembers' rows; personOf(key) -> a Links person { main, chars }; keyOf(name) -> key. One row per person
-- of 2+ characters, on its main: "Alts: a, b" in the person's order, go = the main's row when it matched.
function View.SearchAlts(rows, personOf, keyOf)
  local out, seen, guidOf = {}, {}, {}
  for _, r in ipairs(rows or {}) do
    local k = keyOf(r.text)
    if k and r.go then guidOf[k] = r.go.guid end
  end
  for _, r in ipairs(rows or {}) do
    local key = keyOf(r.text)
    local p = key and personOf(key)
    if type(p) == "table" and type(p.chars) == "table" and #p.chars >= 2 and p.main and not seen[p.main] then
      seen[p.main] = true
      local main, alts = nil, {}
      for _, c in ipairs(p.chars) do
        if c.key == p.main then main = c else alts[#alts + 1] = tostring(c.name) end
      end
      if main then
        out[#out + 1] = { text = tostring(main.name), class = str(main.class), detail = "Alts: " .. table.concat(alts, ", "),
          go = guidOf[p.main] and { page = "roster", guid = guidOf[p.main] } or nil }
      end
    end
  end
  return out
end

-- Guild log sentences (LogEntryRaw) that hold the query, newest first; detail = the date.
function View.SearchLog(log, q)
  local out = {}
  for _, o in ipairs(logNewestFirst(log)) do
    local text = View.LogEntryRaw(o.e)
    if text and hit(text, q) then
      out[#out + 1] = { text = text, icon = View.LOG_ICONS[LOG_KINDS[o.e.type]], go = { page = "overview" },
        detail = o.ts >= 0 and type(date) == "function" and date("%Y-%m-%d", o.ts) or nil }
    end
  end
  return out
end

-- chars = ns.ProfessionsCopy(): profession names, then recipe names stored as strings (an item id is skipped: naming
-- it would need a client call). By character, profession and recipe name.
function View.SearchProfessions(chars, q)
  local out, list = {}, {}
  for _, c in ipairs(type(chars) == "table" and chars or {}) do
    if type(c) == "table" and type(c.professions) == "table" then list[#list + 1] = c end
  end
  table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
  for _, c in ipairs(list) do
    local who, profs = tostring(c.name), {}
    for id, p in pairs(c.professions) do
      if type(p) == "table" and str(p.name) then profs[#profs + 1] = { id = id, p = p } end
    end
    table.sort(profs, function(a, b) return a.p.name < b.p.name end)
    for _, e in ipairs(profs) do
      local p = e.p
      if hit(p.name, q) then
        out[#out + 1] = { text = p.name, detail = who, icon = View.ProfessionIcon(e.id, p.name), go = { page = "char" } }
      end
      local names = {}
      for _, r in pairs(type(p.recipes) == "table" and p.recipes or {}) do
        if hit(r, q) then names[#names + 1] = r end
      end
      table.sort(names)
      for _, r in ipairs(names) do out[#out + 1] = { text = r, detail = p.name .. DOT .. who, go = { page = "char" } } end
    end
  end
  return out
end

-- suite = ns.SUITE by name or line; pages = { ["m:<id>"] = true } for the registered module pages (else Modules).
function View.SearchModules(suite, q, pages)
  local out = {}
  pages = type(pages) == "table" and pages or {}
  for _, e in ipairs(type(suite) == "table" and suite or {}) do
    if type(e) == "table" and (hit(e.name, q) or hit(e.line, q)) then
      local key = "m:" .. tostring(e.id)
      out[#out + 1] = { text = tostring(e.name), detail = str(e.line), icon = e.icon,
        go = { page = pages[key] and key or "modules" } }
    end
  end
  return out
end

local function searchText(text, class)
  local hex = class and View.CLASS_HEX[class]
  if hex then return "|cff" .. hex .. escape(text) .. "|r" end -- the colour wraps the escaped text
  return escape(text)
end

-- groups = ns.Search.Run's answer (nil: the query was short) -> display rows { kind = "group"|"row"|"more"|"line",
-- text, detail?, icon?, class?, group?, row? }: per group its label, 5 rows (all when expanded[key]), then
-- "Show all <n>". Every text and detail escaped once here. query: the box text, trimmed, for 'No results for "<query>".'.
-- A group row reads "<label> · <total>" (mock se-2).
function View.SearchList(groups, expanded, query)
  if type(groups) ~= "table" then return { { kind = "line", text = View.SEARCH_SHORT } } end
  if #groups == 0 then return { { kind = "line", text = 'No results for "' .. escape(query or "") .. '".' } } end
  expanded = type(expanded) == "table" and expanded or {}
  local out = {}
  for _, g in ipairs(groups) do
    local rows = type(g.rows) == "table" and g.rows or {}
    out[#out + 1] = { kind = "group", text = escape(g.label) .. DOT .. tostring(g.total or #rows), group = g.key }
    local n = expanded[g.key] and #rows or math.min(#rows, View.SEARCH_SHOWN)
    for i = 1, n do
      local r = rows[i]
      out[#out + 1] = { kind = "row", text = searchText(r.text, r.class), detail = r.detail and escape(r.detail) or nil,
        icon = r.icon, class = r.class, group = g.key, row = r }
    end
    if n < #rows then out[#out + 1] = { kind = "more", text = "Show all " .. tostring(g.total or #rows), group = g.key } end
  end
  return out
end
