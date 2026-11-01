-- GuildKOS RulesMarks: Mark as bounty's pure rules (R6 Task D; spec AC16-AC19a): the refusal lines, the full name and
-- a mark's state against the target record. Pure Lua 5.1, no client calls. Also the probe switch (d795).
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

return Marks
