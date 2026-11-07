-- GuildKOS RulesMarks: Mark as bounty's pure rules (R6 Task D; spec AC16-AC19a): the refusal lines, the full name and
-- a mark's state against the target record. Adding by name: the synthetic name key, the display name, /kos add's
-- split, the open record a name entry is linked to, and when a sighting may link it. Pure Lua 5.1, no client calls.
-- Also the probe switch (d795).
local _, ns = ...
local Marks = {}
ns.RulesMarks = Marks

-- The probe switch (d795): combatMark false = the button is off in combat and says why; combatName false = in-combat
-- spotting matches by GUID only. The probe answer sets these defaults. kills false = 0.6 ships no kills (d1821): no
-- Kills or Hunters tab, no kill counts on the page, no demo kills (Page reads it at call time, the hub when it builds
-- the demo).
ns.Probe = { combatMark = false, combatName = false, kills = false }

Marks.MAX_WAITING = 3 -- waiting marks per member (d755 Open 1); the stored list holds no more (RulesRecords SPEC)

local LINES = {
  target = "Target an enemy player first.",
  player = "Your target is not a player.",
  enemy = "Your target is not an enemy.",
  secret = "The game hides who your target is, so it cannot be marked.",
  long = "Your target's id is too long to keep on the list.",
  name = "Your target shows no full name (first name and surname), so it cannot be marked.",
  open = "That target is already on the list.",
  waiting = "You already marked that target. It waits for an officer.",
  cap = "You have " .. Marks.MAX_WAITING .. " marks waiting for an officer. Withdraw one first.",
  combat = "Marking is off in combat. Try again after the fight.",
}

-- Marks.Refusal(reason) -> one plain line (no "KOS: " prefix), or nil for a reason it does not know.
function Marks.Refusal(reason)
  return LINES[reason]
end

-- Marks.FullName(first, second, realm, normalizedRealm) -> name | nil. The args are already plain (a secret read
-- reaches here as nil). The second return of UnitNameUnmodified is the surname unless it is empty or the realm.
function Marks.FullName(first, second, realm, normalizedRealm)
  if type(first) ~= "string" or first == "" then return nil end
  if type(second) ~= "string" or second == "" or second == realm or second == normalizedRealm then return first end
  return first .. " " .. second
end

-- Marks.State(mark, targetRec) -> "waiting" | "approved" | "rejected" | "removed" (AC19a). An open record approves
-- the mark; a rejection or removal counts only when decided at or after the mark's time.
function Marks.State(mark, targetRec)
  if type(targetRec) ~= "table" then return "waiting" end
  local status = targetRec.status
  if status == "open" then return "approved" end
  if status == "rejected" or status == "removed" then
    local at, t = tonumber(targetRec.decidedAt), type(mark) == "table" and tonumber(mark.time) or nil
    if at and t and at >= t then return status end
  end
  return "waiting"
end

-- ---------- adding by name (run r-20261107-guildkos-add-by-name) ----------

-- A player added by a typed name lives under a synthetic key made from the folded name: an ordinary kos record (or
-- kos_m mark) that no unit GUID ever equals. "N" is never a realm id, so it never looks like Player-<digits>-.
Marks.NAME_PREFIX = "Player-N-"
Marks.NAME_WHO = "Added by name"
LINES.fullname = "Type a first name and surname, as in /kos add First Surname [why]."
LINES.named = "That name is already on the list."

-- One space between words, no edge spaces.
local function squeeze(s) return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

local function lowerAscii(c) return string.char(c:byte() + 32) end
local function upperAscii(c) return string.char(c:byte() - 32) end
-- UTF-8 Latin-1 capitals U+00C0-U+00DE (but U+00D7, the times sign) and their small letters U+00E0-U+00FE (but U+00F7).
local function lowerLatin(b)
  local n = b:byte()
  if n == 151 then return "\195" .. b end
  return "\195" .. string.char(n + 32)
end
local function upperLatin(b)
  local n = b:byte()
  if n == 183 then return "\195" .. b end
  return "\195" .. string.char(n - 32)
end

-- Characters in a UTF-8 string (bytes that do not continue a sequence).
local function charCount(s) return select(2, s:gsub("[^\128-\191]", "")) end

-- The shared fold: spacing first (a tab becomes a space before Safe could drop it), then Safe, then lower case.
local function fold(name)
  if type(name) ~= "string" then return nil end
  local s = squeeze(ns.RulesRecords.Safe(squeeze(name)))
  s = s:gsub("[A-Z]", lowerAscii):gsub("\195([\128-\158])", lowerLatin)
  return s
end

-- The two-word name the key is made from, or nil (fewer than two words, or over NAME_CHARS characters).
local function keyName(name)
  local s = fold(name)
  if not s or not s:find(" ", 1, true) then return nil end
  if charCount(s) > ns.RulesRecords.NAME_CHARS then return nil end
  return s
end

-- Two independent polynomial hashes, each under a prime below 2^28 (h * m + byte stays far below 2^53), each 7 hex
-- digits. Every divisor is an inline literal (kos_static_test).
local function hash(s)
  local a, b = 0, 0
  for i = 1, #s do
    local c = s:byte(i)
    a = (a * 31 + c) % 268435399
    b = (b * 131 + c) % 268435367
  end
  return string.format("%07X%07X", a, b)
end

local keyCache, keyCached = {}, 0

-- Marks.NameKey(name) -> "Player-N-" .. 14 hex digits (23 bytes) | nil. Same key for any case or spacing of the name.
-- Cached per name (cleared at 512 names), so a scan over the open list hashes each record name once.
function Marks.NameKey(name)
  if type(name) ~= "string" then return nil end
  local hit = keyCache[name]
  if hit ~= nil then return hit or nil end
  local s = keyName(name)
  local key = s and (Marks.NAME_PREFIX .. hash(s)) or nil
  if keyCached >= 512 then keyCache, keyCached = {}, 0 end
  keyCache[name] = key or false
  keyCached = keyCached + 1
  return key
end

-- Marks.IsNameKey(guid) -> boolean.
function Marks.IsNameKey(guid)
  local p = Marks.NAME_PREFIX
  return type(guid) == "string" and guid:sub(1, #p) == p
end

-- Marks.NameDisplay(name) -> the folded name with each part capitalised (d2006), or nil when nothing is left.
function Marks.NameDisplay(name)
  local s = fold(name)
  if not s or s == "" then return nil end
  s = (" " .. s):gsub(" ([a-z])", function(c) return " " .. upperAscii(c) end)
    :gsub(" \195([\160-\190])", function(b) return " " .. upperLatin(b) end)
  return s:sub(2)
end

-- Marks.SplitAdd(text) -> name | nil, why | nil: the first two words (one word alone when there is only one) and the
-- rest (nil when empty).
function Marks.SplitAdd(text)
  if type(text) ~= "string" then return nil end
  local s = text:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  local first, second, rest = s:match("^(%S+)%s+(%S+)%s*(.-)$")
  if not first then return s, nil end
  return first .. " " .. second, rest ~= "" and rest or nil
end

-- Marks.SameName(a, b) -> boolean: both are full names (two words, at most NAME_CHARS characters) that fold to the
-- same text. True implies equal NameKeys; it also holds when two different names would share a key.
function Marks.SameName(a, b)
  local fa, fb = keyName(a), keyName(b)
  return fa ~= nil and fa == fb
end

-- Marks.FindLinked(nameKey, open, name) -> key | nil. open: "t" .. guid -> rec. The open real record (not a name key)
-- whose name folds to nameKey (and, when name is given, is the same name as it); the lowest key when several do.
function Marks.FindLinked(nameKey, open, name)
  if type(nameKey) ~= "string" or type(open) ~= "table" then return nil end
  local best
  for k, rec in pairs(open) do
    if type(k) == "string" and type(rec) == "table" and rec.status == "open" and not Marks.IsNameKey(k:sub(2))
      and (best == nil or k < best) and Marks.NameKey(rec.name) == nameKey
      and (name == nil or Marks.SameName(rec.name, name)) then
      best = k
    end
  end
  return best
end

-- Marks.TargetOf(mark, held, open) -> rec | nil. held: the record under mark.guid. A real-GUID mark is judged against
-- held; a name-key mark against the linked open record when there is one, else held.
function Marks.TargetOf(mark, held, open)
  if type(mark) ~= "table" or not Marks.IsNameKey(mark.guid) then return held end
  local k = Marks.FindLinked(mark.guid, open, mark.name)
  if k then return open[k] end
  return held
end

-- Marks.MayAutoLink(entry, realHeld) -> boolean. A sighting may link the open name entry to the real player unless the
-- real record was rejected or removed at or after the entry's decision time (decidedAt, else markedAt); a missing
-- time on either side answers false.
function Marks.MayAutoLink(entry, realHeld)
  if type(realHeld) ~= "table" or realHeld.status == "open" then return true end
  if type(entry) ~= "table" then return false end
  local at = tonumber(realHeld.decidedAt)
  local since = tonumber(entry.decidedAt) or tonumber(entry.markedAt)
  if not at or not since then return false end
  return at < since
end

return Marks
