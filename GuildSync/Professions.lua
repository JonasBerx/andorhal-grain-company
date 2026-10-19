-- GuildSync Professions: the character's own professions and learned recipes.
--   c.professions[skillLineID] = { name, rank, max, recipes = { [recipeSpellID] = outputItemID, or the recipe name when it makes no item } }
-- The key is the base profession's skill line id. Recipes are read while the profession window is open,
-- from the list the window itself shows (GetFilteredRecipeIDs), keeping only learned ones. Recipes are merged,
-- never removed, so a search text or filter in the window cannot make recorded recipes disappear.

local ADDON, ns = ...
local Compat = ns.Compat

local scanQueued = false
local lastAnnounced = {} -- skillLineID -> recipe count last printed
local loginAt = nil
local PRUNE_AFTER_LOGIN = 30 -- seconds; skill data may still be arriving right after login

-- Compare before write: a writer sets changed only when a profession, rank, max, name or recipe was added, changed
-- or pruned; recorded() then raises the serial and fires the hub event "professions" once (M.Professions).
local changed = false
local serial = 0

local function recorded()
  if not changed then return end
  changed = false
  serial = serial + 1
  ns.Fire("professions")
end

local function professionEntry(c, id, name)
  if type(c.professions) ~= "table" then c.professions, changed = {}, true end
  local p = c.professions[id]
  if type(p) ~= "table" then
    p = { recipes = {} }
    c.professions[id] = p
    changed = true
  end
  if type(p.recipes) ~= "table" then p.recipes, changed = {}, true end
  if name and p.name ~= name then p.name, changed = name, true end
  p.rank = p.rank or 0
  p.max = p.max or 0
  return p
end

local function setRank(p, rank, max)
  if p.rank ~= rank or p.max ~= max then p.rank, p.max, changed = rank, max, true end
end

local function setRecipe(p, id, value)
  if p.recipes[id] ~= value then p.recipes[id], changed = value, true end
end

-- Ranks for every profession the character has, without any window. Also drops professions that were unlearned.
local function readKnown()
  local c = ns.Char()
  if not c then return end
  local known = Compat.KnownProfessions()
  if not known or #known == 0 then return end
  local ids, names = {}, {}
  for _, k in ipairs(known) do
    ids[k.id] = true
    if k.name then names[k.name] = true end
    local p = professionEntry(c, k.id, k.name)
    if k.max and k.max > 0 then setRank(p, k.rank or 0, k.max) end
  end
  if not loginAt or time() - loginAt < PRUNE_AFTER_LOGIN then return end
  for id, p in pairs(c.professions or {}) do
    local name = type(p) == "table" and p.name or nil
    if not ids[id] and not (name and names[name]) then c.professions[id], changed = nil, true end
  end
end

local function refreshKnown()
  readKnown()
  recorded()
end

local function scanTradeSkill()
  scanQueued = false
  if not Compat.TradeSkillIsOwn() then return end
  local base = Compat.TradeSkillBase()
  if not base then return end
  local ids = Compat.TradeSkillRecipeIDs()
  if not ids then return end
  local c = ns.Char()
  if not c then return end

  local p = professionEntry(c, base.id, base.name)
  if base.max and base.max > 0 then setRank(p, base.rank or 0, base.max) end

  for _, recipeID in ipairs(ids) do
    if type(recipeID) == "number" then
      local learned, canonicalID = Compat.RecipeLearned(recipeID)
      if learned then
        local id = canonicalID or recipeID
        local known = p.recipes[id]
        if known == nil or known == true then
          setRecipe(p, id, Compat.RecipeOutput(id) or Compat.RecipeName(id) or true)
        end
      end
    end
  end

  refreshKnown()
  local count = ns.Count(p.recipes)
  if lastAnnounced[base.id] ~= count then
    lastAnnounced[base.id] = count
    ns.Say(tostring(p.name or "profession") .. " " .. tostring(p.rank) .. "/" .. tostring(p.max) .. ": " .. count .. " recipes recorded.")
  end
end

local function queueScan()
  if scanQueued then return end
  scanQueued = true
  ns.After(0.5, scanTradeSkill, "Professions")
end

local function onRecipeLearned(recipeID)
  recipeID = Compat.Plain(recipeID)
  if type(recipeID) ~= "number" then return end
  local prof = Compat.RecipeProfession(recipeID)
  if not prof then return end
  local c = ns.Char()
  if not c then return end
  local p = professionEntry(c, prof.id, prof.name)
  setRecipe(p, recipeID, Compat.RecipeOutput(recipeID) or Compat.RecipeName(recipeID) or true)
  refreshKnown()
end

-- M.Professions: chars, serial. chars = { { key, name, class, onRoster, updated, professions }, ... } sorted by key, a
-- deep copy of every recorded character. key and name: the roster's entry for the record's GUID (name without the
-- realm), else the recorded name and its key (the GuildSync.Comm.MyKey rule). The GUID is not handed out. Reads only:
-- before the saved data loads it answers {}, 0 and creates nothing.
local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepCopy(x) end
  return out
end

function ns.ProfessionsCopy()
  local db = ns.SavedDB()
  if not db or type(db.chars) ~= "table" then return {}, serial end
  local Comm = ns.Comm
  local Key = Comm and Comm.Wire and Comm.Wire.Key
  local rows = Comm and type(Comm.Roster) == "function" and Comm.Roster() or {}
  local g = type(db.guild) == "table" and db.guild or nil
  local members = g and type(g.members) == "table" and g.members or nil
  local out = {}
  for _, c in pairs(db.chars) do
    if type(c) == "table" and Key then
      local key, name
      local m = members and type(c.guid) == "string" and members[c.guid] or nil
      if type(m) == "table" and type(m.name) == "string" then
        key, name = Key(m.name), (string.gsub(m.name, "%-.*$", ""))
      end
      if not key then key, name = Key(c.name), c.name end
      if key then
        out[#out + 1] = {
          key = key, name = name, class = c.class, onRoster = rows[key] ~= nil, updated = c.updated,
          professions = type(c.professions) == "table" and deepCopy(c.professions) or {},
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out, serial
end

-- "Alchemy 300/300 (12 recipes)" for each profession recorded on c, sorted.
local function professionList(c)
  local parts = {}
  for _, p in pairs(c and type(c.professions) == "table" and c.professions or {}) do
    if type(p) == "table" then
      table.insert(parts, tostring(p.name or "?") .. " " .. tostring(p.rank or 0) .. "/" .. tostring(p.max or 0) .. " (" .. ns.Count(p.recipes) .. " recipes)")
    end
  end
  table.sort(parts)
  return parts
end

ns.RegisterModule({
  name = "Professions",
  events = { "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED" },
  onEvent = function(event, arg1)
    if event == "PLAYER_LOGIN" then
      loginAt = time()
      ns.After(4, refreshKnown, "Professions")
    elseif event == "SKILL_LINES_CHANGED" then
      ns.WhenUnrestricted("professions-known", refreshKnown, "Professions")
    elseif event == "NEW_RECIPE_LEARNED" then
      local recipeID = arg1
      ns.WhenUnrestricted("professions-recipe-" .. tostring(Compat.Plain(recipeID)), function() onRecipeLearned(recipeID) end, "Professions")
    else
      queueScan()
    end
  end,
  scan = function()
    refreshKnown()
    scanTradeSkill()
  end,
  status = function()
    local parts = professionList(ns.Char())
    if #parts == 0 then return "nothing recorded yet, open each profession window once" end
    return table.concat(parts, ", ")
  end,
  -- /gsync selftest: read only (ns.PeekChar creates and stamps nothing)
  selftest = function()
    local c = ns.PeekChar()
    if not c then return "wait", "character not known yet" end
    local parts = professionList(c)
    if #parts == 0 then return "wait", "open a profession window once" end
    return "pass", table.concat(parts, ", ")
  end,
})
