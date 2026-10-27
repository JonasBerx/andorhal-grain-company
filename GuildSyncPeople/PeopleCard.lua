-- GuildSyncPeople: the tooltip lines, the editor state, the link parser (plan Task 2) and the member section (run
-- r-20261018-o696).
-- Pure: no guard, no client call, no global outside the Annals allow-list (check-rules/GuildSyncPeople.json).
-- view = { key, name, classToken, className, race, level, rank, rankIndex, online, colour = { r, g, b }, rec }
-- clock = { weekday, hour, minute }, read once by the redraw's owner and passed in (Card never reads the calendar).
-- standing = { title, points } (Annals' facts, raw) or nil, passed in like clock (Card never asks the hub).

local _, ns = ...
local C = {}
ns.Card = C

C.TOOLTIP_LETTERS = 60 -- the note in the tooltip, then "..."
C.TOOLTIP_LIKES = 4    -- labels in the tooltip's "Likes:" line, then " +<n>"
C.TOOLTIP_GROUPS = 2   -- hour groups in the tooltip, then " +<n> more"
C.TOOLTIP_ALTS = 3     -- alt names in the tooltip's "Alts:" line, then " +<n>" (d832)
C.STANDING_AT = "top"  -- the Annals title line: first in the section and the tooltip (Look A, d1130)

local function labels(tags)
  local out = {}
  for _, code in ipairs(tags or {}) do
    local label = ns.Rules.LABEL[code]
    if label then out[#out + 1] = label end
  end
  return out
end

-- the first n labels joined with ", ", then " +<rest>"
local function firstLabels(list, n)
  local shown = {}
  for i = 1, math.min(n, #list) do shown[i] = list[i] end
  local text = table.concat(shown, ", ")
  if #list > n then text = text .. " +" .. (#list - n) end
  return text
end

local function when(rec, clock, maxGroups)
  return ns.Rules.WhenText(rec.mask, clock and clock.weekday, clock and clock.hour, maxGroups)
end

local function hex(x)
  x = tonumber(x) or 1
  if x < 0 then x = 0 elseif x > 1 then x = 1 end
  return string.format("%02x", math.floor(x * 255 + 0.5))
end

-- "|cffrrggbb" for r, g, b from 0 to 1 (a missing part reads as 1)
function C.ColourCode(r, g, b) return "|cff" .. hex(r) .. hex(g) .. hex(b) end

-- "<name in class colour>, 58 Raider" (the chat and roster paths, where no game line names the member)
local function headerLine(view)
  local c = type(view.colour) == "table" and view.colour or {}
  local text = C.ColourCode(c.r, c.g, c.b) .. ns.Escape(tostring(view.name)) .. "|r"
  local rest = {}
  if type(view.level) == "number" then rest[#rest + 1] = tostring(view.level) end
  if type(view.rank) == "string" and view.rank ~= "" then rest[#rest + 1] = ns.Escape(view.rank) end
  if #rest > 0 then text = text .. ", " .. table.concat(rest, " ") end
  return text
end

-- The main/alt line (d832): "Alt of <main>" on an alt, "Alts: a, b, c +<n>" on a main, nil for a person of one.
-- Confirmed characters only (person.chars); unconfirmed links are never named. Plain text, names escaped.
local function linkLine(person)
  if type(person) ~= "table" or type(person.chars) ~= "table" then return nil end
  if person.main ~= person.key then
    for _, ch in ipairs(person.chars) do
      if type(ch) == "table" and ch.key == person.main then return "Alt of " .. ns.Escape(tostring(ch.name)) end
    end
    return nil
  end
  local names = {}
  for _, ch in ipairs(person.chars) do
    if type(ch) == "table" and ch.key ~= person.main then names[#names + 1] = ns.Escape(tostring(ch.name)) end
  end
  if #names == 0 then return nil end
  local more = #names - C.TOOLTIP_ALTS
  for i = #names, C.TOOLTIP_ALTS + 1, -1 do names[i] = nil end
  return "Alts: " .. table.concat(names, ", ") .. (more > 0 and (" +" .. more) or "")
end

-- "<title> \194\183 <n> points" (title escaped, points floored); nil below 1 point or with no title (d1134).
function C.StandingText(standing)
  if type(standing) ~= "table" then return nil end
  local title, points = standing.title, standing.points
  if type(title) ~= "string" or title == "" or type(points) ~= "number" then return nil end
  points = math.floor(points)
  if points < 1 then return nil end
  return ns.Escape(title) .. " \194\183 " .. points .. (points == 1 and " point" or " points")
end

-- The tooltip lines: the title line, the main/alt line, note (60 letters, cut before Escape, f4),
-- "Usually online: ...", "Likes: ...".
-- person = GuildSync.Comm.Person's shape or nil. No record, no link line and no title line, no lines (d1133).
function C.Tooltip(view, clock, withHeader, person, standing)
  local lines = {}
  local rec, link, title = view.rec, linkLine(person), C.StandingText(standing)
  if not rec and not link and not title then return lines end
  if withHeader then lines[#lines + 1] = headerLine(view) end
  if title then lines[#lines + 1] = title end
  if link then lines[#lines + 1] = link end
  if not rec then return lines end
  if type(rec.note) == "string" and rec.note ~= "" then
    local text, cut = ns.Rules.CutLetters(rec.note, C.TOOLTIP_LETTERS)
    lines[#lines + 1] = ns.Escape(text) .. (cut and "..." or "")
  end
  local w = when(rec, clock, C.TOOLTIP_GROUPS)
  if w then lines[#lines + 1] = "Usually online: " .. w end
  local likes = labels(rec.tags)
  if #likes > 0 then lines[#lines + 1] = "Likes: " .. firstLabels(likes, C.TOOLTIP_LIKES) end
  return lines
end

-- "player:Mortis Vale-Forever:15:CHANNEL:1" -> the roster's "Mortis Vale"; a name off the roster gives nil.
function C.LinkName(link)
  if type(link) ~= "string" then return nil end
  local name = link:match("^player:([^:]*)")
  if not name or name == "" then return nil end
  local row = ns.Member(name)
  return type(row) == "table" and row.name or nil
end

-- The guild-chat tag (items 27-29): "(Main: <main's roster name>) " for a confirmed alt's line, else nil. Pure: every
-- lookup is passed in, and it fails closed. Checks in order: the switch, the lockdown plainly off, text, playerName and
-- guid plain strings, the guid a player's ("Player-"), discordInfo.fromDiscord not true (the only field read), the
-- speaker a confirmed alt, a main name.
-- t = { on, lockdown, plain, text, playerName, guid, discordInfo, keyOfGuid, key, person, member, escape };
-- lockdown() -> ok, locked (M.Compat.Try's shape).
function C.ChatTag(t)
  if t.on ~= true then return nil end
  local plain = t.plain
  local callOk, ok, locked = pcall(t.lockdown)
  if not (callOk and ok == true and plain(locked) == false) then return nil end
  local text, playerName, guid = plain(t.text), plain(t.playerName), plain(t.guid)
  if type(text) ~= "string" or type(playerName) ~= "string" or type(guid) ~= "string" then return nil end
  if not guid:match("^Player%-") then return nil end
  local info = plain(t.discordInfo)
  if type(info) == "table" and plain(info.fromDiscord) == true then return nil end
  local key = t.keyOfGuid(guid) or t.key(playerName)
  local person = type(key) == "string" and t.person(key) or nil
  if type(person) ~= "table" or type(person.chars) ~= "table" or #person.chars < 2 or person.main == key then
    return nil
  end
  local found = false
  for _, ch in ipairs(person.chars) do
    if type(ch) == "table" and ch.key == key then found = true end
  end
  if not found then return nil end
  local row = t.member(person.main)
  local name = type(row) == "table" and row.name or nil
  if type(name) ~= "string" or name == "" then return nil end
  return "(Main: " .. t.escape(name) .. ") "
end

-- My profile's editor state: the letter counter, a check per tag code, the mask.
function C.Editor(profile)
  local checks = {}
  for _, code in ipairs(profile and profile.tags or {}) do checks[code] = true end
  return {
    counter = ns.Rules.Counter(profile and profile.note),
    checks = checks,
    mask = profile and profile.mask or "",
  }
end

-- ---------- the member section on the Roster panel (look A, d831; NOTES-o696 rp-1, rp-5) ----------

-- Class colours (the game's RAID_CLASS_COLORS values; Card is pure, so it carries its own copy).
C.CLASS_COLOUR = {
  WARRIOR = { 0.78, 0.61, 0.43 }, HUNTER = { 0.67, 0.83, 0.45 }, ROGUE = { 1, 0.96, 0.41 }, PRIEST = { 1, 1, 1 },
  SHAMAN = { 0, 0.44, 0.87 }, MAGE = { 0.25, 0.78, 0.92 }, WARLOCK = { 0.53, 0.53, 0.93 },
  DRUID = { 1, 0.49, 0.04 }, PALADIN = { 0.96, 0.55, 0.73 },
}
C.LETTER_PX = 4.5  -- the line count model: greedy word wrap at this many px per letter (the sim cannot wrap)
C.NOTE_LINES = 4   -- the note in the section, then cut
C.VALUE_LINES = 4  -- at least this many lines for "Usually online" and "Likes", so the client's real wrap is not cut
C.LINE = 12        -- px per text line
local LABEL_GAP, ROW_GAP, BLOCK_GAP, WRAP_GAP = 15, 14, 20, 9
local LABEL, VALUE, NONE = "GameFontNormalSmall", "GameFontHighlightSmall", "GameFontDisableSmall"
local GREY = { 0.5, 0.5, 0.5 }

local function letters(s) return #s - select(2, string.gsub(s, "[\128-\191]", "")) end

-- The lines `text` takes at `width`, by the letter model.
local function lineCount(text, width)
  local per = math.max(1, math.floor((tonumber(width) or 0) / C.LETTER_PX))
  local lines, used = 1, 0
  for word in string.gmatch(text, "%S+") do
    local n = letters(word)
    if used > 0 and used + 1 + n <= per then
      used = used + 1 + n
    else
      if used > 0 then lines = lines + 1 end
      while n > per do lines, n = lines + 1, n - per end
      used = n
    end
  end
  return lines
end

local function charName(ch)
  local col = C.CLASS_COLOUR[ch.class] or {}
  return C.ColourCode(col[1], col[2], col[3]) .. ns.Escape(tostring(ch.name)) .. "|r"
end

-- The profile shown for a person: the newest editedAt across person.chars, a tie to the lowest key (item 14).
-- recOf(key) -> rec | nil. Unconfirmed links are not part of the person. -> rec, key | nil
function C.ProfileOf(person, recOf)
  if type(person) ~= "table" then return nil end
  local best, bestKey, bestAt
  for _, ch in ipairs(person.chars or {}) do
    local rec = type(ch) == "table" and type(ch.key) == "string" and recOf(ch.key) or nil
    if rec then
      local at = tonumber(rec.editedAt) or 0
      if not best or at > bestAt or (at == bestAt and ch.key < bestKey) then best, bestKey, bestAt = rec, ch.key, at end
    end
  end
  return best, bestKey
end

-- The next block's top after a block at y that is h px high (one line, or wrapped to more).
function C.NextTop(y, h) return y + (h > C.LINE and h + WRAP_GAP or BLOCK_GAP) end

-- The section's lines: { text, font, x, y, lines, colour, wrap } top to bottom, y from the frame's top, then its height.
-- view = { key, rec, standing } (rec the profile shown; standing as C.StandingText takes it, drawn first, d1130);
-- person = GuildSync.Comm.Person's shape or nil. Names come from person.
function C.Section(view, person, clock, width)
  local items, y = {}, 0
  -- wrap (the note and the values): the string's max lines; the section then lays it out from its measured height
  local function add(text, font, lines, colour, wrap)
    items[#items + 1] = { text = text, font = font, x = 0, y = y, lines = lines or 1, colour = colour, wrap = wrap }
  end
  local function after(lines) y = C.NextTop(y, lines * C.LINE) end

  local title = C.StandingText(view and view.standing)
  if title and C.STANDING_AT == "top" then
    add(title, LABEL)
    after(1)
  end

  if type(person) == "table" then
    local main
    if person.main ~= person.key then
      for _, ch in ipairs(person.chars or {}) do if ch.key == person.main then main = ch end end
    end
    local rows = {}
    for _, ch in ipairs(person.chars or {}) do
      if ch.key ~= person.key and ch.key ~= person.main then
        rows[#rows + 1] = { charName(ch) .. (type(ch.level) == "number" and (" " .. ch.level) or "") }
      end
    end
    for _, ch in ipairs(person.unconfirmed or {}) do
      rows[#rows + 1] = { ns.Escape(tostring(ch.name)) .. " (unconfirmed)", GREY }
    end
    if main then
      add("Alt of " .. charName(main), LABEL)
      after(1)
    end
    if #rows > 0 then
      add(main and "Other alts" or "Alts", LABEL)
      y = y + LABEL_GAP
      for i, row in ipairs(rows) do
        if i > 1 then y = y + ROW_GAP end
        add(row[1], VALUE, 1, row[2])
      end
      after(1)
    end
  end

  local rec, drawn = view and view.rec, false
  if type(rec) == "table" then
    if type(rec.note) == "string" and rec.note ~= "" then
      local n = math.min(lineCount(rec.note, width), C.NOTE_LINES)
      add(ns.Escape(rec.note), VALUE, n, nil, C.NOTE_LINES)
      after(n)
      drawn = true
    end
    for _, block in ipairs({ { "Usually online", when(rec, clock) }, { "Likes", table.concat(labels(rec.tags), ", ") } }) do
      local value = block[2]
      if type(value) == "string" and value ~= "" then
        add(block[1], LABEL)
        y = y + LABEL_GAP
        local n = lineCount(value, width)
        add(value, VALUE, n, nil, math.max(n, C.VALUE_LINES))
        after(n)
        drawn = true
      end
    end
  end
  if not drawn then add("No profile yet.", NONE) end

  local last = items[#items]
  return items, last.y + last.lines * C.LINE
end
