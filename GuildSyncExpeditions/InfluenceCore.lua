-- GuildSyncExpeditions InfluenceCore.lua: the influence ladder, ns.InfluenceCore (issue 6). Each granary project the
-- guild builds in Games opens one step here. Pure data and rules: string, table and math only, no ns.M guard (like
-- QuestData.lua), no game calls, no clock.
--   IC.MAX -> 6                              IC.STEPS -> { { built, key, text, say, live, early, sayKey }, ... }
--   IC.Valid(v) -> 0..6 | nil                a whole number in 0..6, else nil
--   IC.Need(key) -> 1..6 | nil               the built count a step needs
--   IC.Live(key) -> bool                     the step's content is in this version; false for an unknown key
--   IC.Step(n) -> step | nil                 the step at built = n
--   IC.Project(n) -> name | nil              Games' project n (copied, so this file never reads Games' tables)
--   IC.Newly(old, new) -> { step, ... }      the steps to say (live or early) with old < built <= new, in ladder order
-- live: the step's content is in this version. A step that is not live is held: its line is said once it goes live.
-- early: a step whose content waits, with a line that is true already; it is said, but the step stays shut (not live).
-- sayKey: the mark the said line leaves (Influence.lua's said set), the step's key when absent. An early line has its
-- own mark, so the step's real line is still said once the step goes live.

local _, ns = ...

local IC = {}
ns.InfluenceCore = IC

IC.MAX = 6

-- Copies of CC.PROJECTS[k].name (GuildSyncGames/CompanyCore.lua:140-147); a test pins them equal.
local PROJECTS = {
  "Rebuild Andorhal's mill",
  "Mend the granary roof",
  "Restock the seed store",
  "Raise the watchtower",
  "Dig the irrigation ditch",
  "Raise the Company hall",
}

local GROWS = "The Company's influence grows: "

IC.STEPS = {
  { built = 1, key = "supplies", text = "more supplies at the Quartermaster",
    say = GROWS .. "more supplies at the Quartermaster.", live = true },
  -- Hillsbrad waits for the follower cap raise (issue 19); its early line is true now. When its expeditions ship, the
  -- step goes live with its own line and drops early and sayKey.
  { built = 2, key = "hillsbrad", text = "Hillsbrad Foothills",
    say = "The Company's influence reaches Hillsbrad Foothills. Its expeditions come with a later update.", live = false,
    early = true, sayKey = "hillsbrad-later" },
  -- The Apothecary, the Tavern and the Arena open camp buildings (CampSoon.lua); the Forge's green gear comes later.
  { built = 3, key = "apothecary", text = "the Apothecary", say = GROWS .. "the Apothecary opens at the camp.",
    live = true },
  { built = 4, key = "tavern", text = "the Tavern", say = GROWS .. "the Tavern opens at the camp.", live = true },
  { built = 5, key = "forge", text = "the Forge", say = GROWS .. "the Forge opens at the camp.", live = true },
  { built = 6, key = "arena", text = "the Arena", say = GROWS .. "the Arena opens at the camp.", live = true },
}

local BY_KEY = {}
for _, s in ipairs(IC.STEPS) do BY_KEY[s.key] = s end

function IC.Valid(v)
  if type(v) ~= "number" or v ~= math.floor(v) or v < 0 or v > IC.MAX then return nil end
  return v
end

function IC.Need(key)
  local s = BY_KEY[key]
  return s and s.built or nil
end

function IC.Live(key)
  local s = BY_KEY[key]
  return s ~= nil and s.live == true
end

function IC.Step(n)
  return IC.Valid(n) and IC.STEPS[n] or nil
end

function IC.Project(n)
  return IC.Valid(n) and PROJECTS[n] or nil
end

function IC.Newly(old, new)
  local out = {}
  old, new = IC.Valid(old) or 0, IC.Valid(new) or 0
  for _, s in ipairs(IC.STEPS) do
    if (s.live or s.early) and s.built > old and s.built <= new then out[#out + 1] = s end
  end
  return out
end
