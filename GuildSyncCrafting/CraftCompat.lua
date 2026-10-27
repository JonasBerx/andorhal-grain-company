-- GuildSync crafting, CraftCompat: the ONLY crafting file that touches client globals, wrapped and guarded.
-- A missing function means "not there", never an error. Functions are called through the module's handle
-- (CraftHost.M.Compat, limited to APIS), presence through GuildSync.Compat.Has, secrets through GuildSync.Compat.Plain.
--
-- Every client function is reached through call() with a dotted name listed in CraftCompat.APIS, or through resolve()
-- for the names in CraftCompat.VALUES. The probe records the presence of everything in APIS, WATCH and VALUES.
-- It also owns the two saved variables: GuildSyncCraftDB (account-wide: settings, own stamps, own cooldowns,
-- favourites, the work board, alert marks, the probe) and GuildSyncCraftDir (per character: guildmates' recipes and
-- cooldowns).
-- Checked against build 1.60.1.69893: the generated API documentation and Blizzard's own interface code.

local _, ns = ...

local CraftCompat = {}
ns.CraftCompat = CraftCompat

-- ---------- plumbing ----------

-- Functions CraftCompat calls. The probe walks this list.
CraftCompat.APIS = {
  "GetBuildInfo", "GetServerTime", "issecretvalue", "IsInGuild", "GetGuildInfo", "InCombatLockdown", "UnitName", "UnitGUID",
  "C_ChatInfo.InChatMessagingLockdown",
  "C_RestrictedActions.GetAddOnRestrictionState",
  "C_Item.GetItemInfo", "C_Item.IsItemDataCachedByID", "C_Item.GetItemIconByID", "C_Item.GetItemQualityColor", "C_Item.RequestLoadItemDataByID",
  "C_Spell.GetSpellName", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeSchematic",
  "C_TradeSkillUI.IsGuildTradeSkillsEnabled",
  "PlaySound", "CreateFrame", "hooksecurefunc", "C_ClassColor.GetClassColor", "GetTime",
  -- FrameXML helpers (not in the API documentation; in Blizzard's chat code)
  "ChatFrameUtil.SendTell", "ChatFrameUtil.InsertLink",
  -- may be missing without failing the selftest (d536); the probe asks for it first
  -- the cooldown reads (f6614): without them the Cooldowns board shows unknown; GetRecipeCooldown is not in the dump
  optional = { "C_CraftingOrders.ShouldShowCraftingOrderTab",
               "C_Spell.GetSpellCooldown", "C_Item.GetItemCooldown", "C_Item.GetItemCount",
               "C_Secrets.ShouldSpellCooldownBeSecret", "C_Secrets.ShouldCooldownsBeSecret",
               "C_TradeSkillUI.GetRecipeCooldown" },
}

-- Names CraftCompat does not call, recorded by the probe only.
CraftCompat.WATCH = {
  "C_CraftingOrders.GetMyOrders", "C_CraftingOrders.GetCrafterOrders", "C_CraftingOrders.GetOrderClaimInfo",
  "C_CraftingOrders.GetClaimedOrder", "C_CraftingOrders.ListMyOrders",
  "C_GuildInfo.QueryGuildMembersForRecipe",
}
-- The C_CraftingOrders names the probe reports under craftingOrders.apis.
local ORDER_APIS = {
  "C_CraftingOrders.ShouldShowCraftingOrderTab", "C_CraftingOrders.GetMyOrders", "C_CraftingOrders.GetCrafterOrders",
  "C_CraftingOrders.GetOrderClaimInfo", "C_CraftingOrders.GetClaimedOrder", "C_CraftingOrders.ListMyOrders",
}

-- Non-function globals and enums CraftCompat reads. Also recorded by the probe. Functions are not listed here (resolve()
-- answers nil for them): the deprecated ChatEdit_InsertLink is checked with GuildSync.Compat.Has (f4521).
CraftCompat.VALUES = {
  "Enum.AddOnRestrictionType", "Enum.CraftingOrderType.Guild", "Enum.CraftingReagentType.Basic",
  "SOUNDKIT", "SOUNDKIT.UI_PROFESSIONS_NEW_RECIPE_LEARNED_TOAST", "ChatFrameUtil",
  "C_CraftingOrders", "UIParent", "RAID_CLASS_COLORS",
}

-- A non-function value by dotted name (the names in VALUES), or nil. Functions are never called through it.
local function resolve(path)
  local obj = _G
  for part in string.gmatch(path, "[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
    if obj == nil then return nil end
  end
  if type(obj) == "function" then return nil end
  return obj
end

-- Calls a client function listed in APIS through the module's handle (M.Compat.call, every value plain). Returns
-- nothing before Register, when it is missing or when it throws.
local function call(path, ...)
  local M = ns.CraftHost and ns.CraftHost.M
  if not M then return nil end
  return M.Compat.call(path, ...)
end

local function has(path) return GuildSync ~= nil and GuildSync.Compat.Has(path) == true end

-- A secret value turns into nil (GuildSync.Compat.Plain).
local function plain(v)
  if GuildSync then return GuildSync.Compat.Plain(v) end
  return v
end
CraftCompat.Plain = plain

local function str(v)
  v = plain(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function num(v)
  v = plain(v)
  if type(v) == "number" then return v end
  return nil
end

-- ---------- saved variables ----------

local SETTINGS = { share = true, retention = 30, alertChat = true, alertSound = true, alertGlow = true, alertPopup = false }

-- The store default of one setting (the Options page's Defaults, CraftHost).
function CraftCompat.SettingDefault(key) return SETTINGS[key] end

-- GuildSyncCraftDB, created and filled. Any shape version but 2 resets it (dev data, a wipe is fine). Shape 2 marks
-- the move out of GuildSync: a v-1 table carried over from GuildSync's old saved file is wiped (f4525).
local DB_SHAPE = 2
function CraftCompat.DB()
  local db = _G.GuildSyncCraftDB
  if type(db) ~= "table" or db.v ~= DB_SHAPE then
    db = { v = DB_SHAPE }
    _G.GuildSyncCraftDB = db
  end
  if type(db.settings) ~= "table" then db.settings = {} end
  for k, v in pairs(SETTINGS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  for _, k in ipairs({ "own", "favourites", "board", "alerted", "posted", "cooldowns" }) do
    if type(db[k]) ~= "table" then db[k] = {} end
  end
  if type(db.glow) ~= "boolean" then db.glow = false end
  return db
end

-- The two saved variables as they are, never created or filled (DB and Dir write; the selftest only reads).
function CraftCompat.Saved()
  return _G.GuildSyncCraftDB, _G.GuildSyncCraftDir
end

-- GuildSyncCraftDir (per character), created and filled. Any shape version but 2 resets it (f4530, like DB_SHAPE).
local DIR_SHAPE = 2
function CraftCompat.Dir()
  local dir = _G.GuildSyncCraftDir
  if type(dir) ~= "table" or dir.v ~= DIR_SHAPE then
    dir = { v = DIR_SHAPE }
    _G.GuildSyncCraftDir = dir
  end
  for _, k in ipairs({ "crafters", "cooldowns" }) do
    if type(dir[k]) ~= "table" then dir[k] = {} end
  end
  return dir
end

-- Records the guild both saved variables belong to. A different guild than the stored one clears the work board,
-- alert marks, posted ids, favourites and the directory (recipes and cooldowns); settings, own stamps and own
-- cooldowns stay.
function CraftCompat.UseGuild(name)
  if type(name) ~= "string" or name == "" then return end
  local db, dir = CraftCompat.DB(), CraftCompat.Dir()
  if db.guild ~= nil and db.guild ~= name then
    db.board, db.alerted, db.favourites, db.posted = {}, {}, {}, {}
  end
  db.guild = name
  if dir.guild ~= nil and dir.guild ~= name then dir.crafters, dir.cooldowns = {}, {} end
  dir.guild = name
end

-- ---------- time, guild, the send gate ----------

-- Server time, or nil. Never the local clock: without server time crafting sync stays off.
function CraftCompat.Now()
  local t = num(call("GetServerTime"))
  if t and t > 0 then return t end
  return nil
end

-- The name of the character logged in now (no realm), or nil. On Forever this is the first name only.
function CraftCompat.PlayerName()
  return str((call("UnitName", "player")))
end

-- The GUID of the character logged in now, or nil.
function CraftCompat.PlayerGUID()
  return str((call("UnitGUID", "player")))
end

function CraftCompat.GuildName()
  if plain(call("IsInGuild")) ~= true then return nil end
  return str((call("GetGuildInfo", "player")))
end

-- ok, why. why: "guild" | "time" | "roster not known" | "combat" | "lockdown" | "restricted (<kind>)".
-- The roster's known (GuildSync.Comm.Roster), then the hub's gate for the crafting domain (M.Comm.Gate, D6).
function CraftCompat.CanSend(rosterKnown)
  if not rosterKnown then return false, "roster not known" end
  local M = ns.CraftHost and ns.CraftHost.M
  if not M then return false, "not registered" end
  return M.Comm.Gate("crafting")
end

-- ---------- items, spells, recipes ----------

-- name, quality, icon, link from the client's cache, or nil. Never waits, and never starts a load: GetItemInfo of an
-- uncached item asks the server for it, so an item the cache does not hold is not looked up (f1018). Without
-- IsItemDataCachedByID the cache read is tried as before.
function CraftCompat.ItemInfo(itemID)
  if type(itemID) ~= "number" then return nil end
  if has("C_Item.IsItemDataCachedByID") and plain(call("C_Item.IsItemDataCachedByID", itemID)) ~= true then return nil end
  local name, link, quality, _, _, _, _, _, _, icon = call("C_Item.GetItemInfo", itemID)
  name = str(name)
  if not name then return nil end
  icon = plain(icon)
  if icon == nil then icon = plain(call("C_Item.GetItemIconByID", itemID)) end
  return name, num(quality), icon, str(link)
end

-- r, g, b, hex of an item quality, or nil.
function CraftCompat.QualityColor(quality)
  if type(quality) ~= "number" then return nil end
  local r, g, b, hex = call("C_Item.GetItemQualityColor", quality)
  return num(r), num(g), num(b), str(hex)
end

-- Asks the client to load an item's data; GET_ITEM_INFO_RECEIVED / ITEM_DATA_LOAD_RESULT say when it is there.
function CraftCompat.RequestItem(itemID)
  if type(itemID) ~= "number" then return end
  call("C_Item.RequestLoadItemDataByID", itemID)
end

function CraftCompat.SpellName(spellID)
  if type(spellID) ~= "number" then return nil end
  return str((call("C_Spell.GetSpellName", spellID)))
end

-- The spell name first; the recipe info only while this character's profession window is open; else nil.
function CraftCompat.RecipeName(spellID, windowOpen)
  local name = CraftCompat.SpellName(spellID)
  if name or not windowOpen or type(spellID) ~= "number" then return name end
  local info = plain(call("C_TradeSkillUI.GetRecipeInfo", spellID))
  if type(info) ~= "table" then return nil end
  return str(info.name)
end

-- { { itemID, count }, ... } of the basic reagents, or nil when the game does not give them.
function CraftCompat.Reagents(spellID)
  if type(spellID) ~= "number" then return nil end
  local schematic = plain(call("C_TradeSkillUI.GetRecipeSchematic", spellID, false))
  if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then return nil end
  local basic = resolve("Enum.CraftingReagentType.Basic")
  local out = {}
  for _, slot in ipairs(schematic.reagentSlotSchematics) do
    if type(slot) == "table" and (basic == nil or slot.reagentType == basic) and type(slot.reagents) == "table" then
      local first = slot.reagents[1]
      local itemID = type(first) == "table" and num(first.itemID) or nil
      local count = num(slot.quantityRequired)
      if itemID and count then out[#out + 1] = { itemID = itemID, count = count } end
    end
  end
  if #out == 0 then return nil end
  return out
end

-- r, g, b of a class token ("WARRIOR"), or nil: C_ClassColor.GetClassColor first, then RAID_CLASS_COLORS
-- (Compat.ClassColor's order).
function CraftCompat.ClassColor(token)
  if type(token) ~= "string" then return nil end
  local c = plain(call("C_ClassColor.GetClassColor", token))
  if type(c) ~= "table" then
    local all = resolve("RAID_CLASS_COLORS")
    c = type(all) == "table" and plain(all[token]) or nil
  end
  if type(c) ~= "table" then return nil end
  local r, g, b = num(c.r), num(c.g), num(c.b)
  if r and g and b then return r, g, b end
  return nil
end

-- ---------- cooldowns ----------

-- The client's uptime clock (GetTime), the one cooldown starts are on, or nil.
function CraftCompat.Clock() return num(call("GetTime")) end

-- How many of an item this character holds, bags and bank (includeBank), or nil.
function CraftCompat.ItemCount(itemID)
  if type(itemID) ~= "number" then return nil end
  return num(call("C_Item.GetItemCount", itemID, true))
end

local function secretField(v) return plain(call("issecretvalue", v)) == true end
-- A C_Secrets answer: true or false, or "missing" when the client lacks the call.
local function secretFlag(path, ...)
  if not has(path) then return "missing" end
  return plain(call(path, ...)) == true
end

-- One CraftStore.COOLDOWNS entry -> a plain read { start, duration, enabled, onGCD } for CraftStore.CooldownReadyAt,
-- or nil, why ("combat" | "missing" | "secret" | "malformed"). Out of combat only: an InCombatLockdown that is not
-- exactly false (nil, a secret) means no read. Then the C_Secrets answers, then the answer and each of its fields
-- through plain before anything compares them (f6613; a SpellCooldownInfo's fields are not plained by call).
function CraftCompat.CooldownRead(entry)
  if type(entry) ~= "table" then return nil, "malformed" end
  if plain(call("InCombatLockdown")) ~= false then return nil, "combat" end
  local spell = entry.kind == "spell"
  local path = spell and "C_Spell.GetSpellCooldown" or "C_Item.GetItemCooldown"
  if not has(path) then return nil, "missing" end
  if secretFlag("C_Secrets.ShouldCooldownsBeSecret") == true
     or (spell and secretFlag("C_Secrets.ShouldSpellCooldownBeSecret", entry.spell) == true) then
    return nil, "secret"
  end
  if not spell then
    -- start, duration, enable: the third is a bool here, a number in C_Container; CooldownReadyAt takes both
    local start, duration, enable = call(path, entry.item)
    start, duration = num(start), num(duration)
    if not start or not duration then return nil, "malformed" end
    return { start = start, duration = duration, enabled = plain(enable) }
  end
  local info = plain(call(path, entry.spell))
  if type(info) ~= "table" then return nil, info == nil and "secret" or "malformed" end
  if secretField(info.startTime) or secretField(info.duration) then return nil, "secret" end
  local start, duration = num(info.startTime), num(info.duration)
  if not start or not duration then return nil, "malformed" end
  return { start = start, duration = duration, enabled = plain(info.isEnabled), onGCD = plain(info.isOnGCD) }
end

-- For `/gsync crafting cd` only (AC13): what the client answers for one entry ({ kind, spell | item }), raw, in combat
-- too. Each field comes back plain, the word "secret" (the issecretvalue test runs before anything touches the raw
-- value, f6628) or "missing" for an absent C_Secrets call. Item fields come from call(), which has already plained
-- them, so a secret and no answer look the same: either reads "nil (none or secret)" (f6640, s3). recipe is
-- GetRecipeCooldown's first value, hasRecipe true only when the client has it. Reads only.
local function shown(v)
  if secretField(v) then return "secret" end
  return plain(v)
end
local function itemField(v)
  if v == nil then return "nil (none or secret)" end
  return v
end
function CraftCompat.CooldownProbe(entry)
  local out = { allSecret = secretFlag("C_Secrets.ShouldCooldownsBeSecret") }
  if entry.kind == "item" then
    local start, duration, enable = call("C_Item.GetItemCooldown", entry.item)
    out.start, out.duration, out.enabled = itemField(start), itemField(duration), itemField(enable)
    return out
  end
  out.spellSecret = secretFlag("C_Secrets.ShouldSpellCooldownBeSecret", entry.spell)
  local info = plain(call("C_Spell.GetSpellCooldown", entry.spell))
  if type(info) == "table" then
    out.start, out.duration = shown(info.startTime), shown(info.duration)
    out.enabled, out.onGCD = shown(info.isEnabled), shown(info.isOnGCD)
  end
  if has("C_TradeSkillUI.GetRecipeCooldown") then
    out.hasRecipe, out.recipe = true, call("C_TradeSkillUI.GetRecipeCooldown", entry.spell)
  end
  return out
end

-- ---------- chat helpers, sound, frames ----------

-- Opening a tell with a link in the box is the hub's: GuildSync.OpenWhisper (Compat.lua), through CraftHost.OpenWhisper.

-- Calls fn(link) after every chat link insert (shift-click on an item). Hooks ChatFrameUtil.InsertLink, which
-- Blizzard's code calls directly; the deprecated global ChatEdit_InsertLink only when the util table is absent.
-- Returns true when a hook is in place.
function CraftCompat.HookShiftClick(fn)
  if type(fn) ~= "function" or not has("hooksecurefunc") then return false end
  local function after(text)
    local link = plain(text)
    if type(link) == "string" then pcall(fn, link) end
  end
  local M = ns.CraftHost and ns.CraftHost.M
  if not M then return false end
  local util = resolve("ChatFrameUtil")
  if type(util) == "table" and has("ChatFrameUtil.InsertLink") then
    return M.Compat.Try("hooksecurefunc", util, "InsertLink", after) and true or false
  end
  if has("ChatEdit_InsertLink") then
    return M.Compat.Try("hooksecurefunc", "ChatEdit_InsertLink", after) and true or false
  end
  return false
end

-- the alert sound: SOUNDKIT.UI_PROFESSIONS_NEW_RECIPE_LEARNED_TOAST (Blizzard_SharedXML/Mainline/SoundKitConstants.lua:256)
local ALERT_SOUND = 73919

function CraftCompat.PlaySound()
  local id = resolve("SOUNDKIT.UI_PROFESSIONS_NEW_RECIPE_LEARNED_TOAST")
  if type(id) ~= "number" then id = ALERT_SOUND end
  call("PlaySound", id)
end

function CraftCompat.CreateFrame(kind, name, parent, template)
  return call("CreateFrame", kind, name, parent or resolve("UIParent"), template)
end

-- ---------- probe ----------

-- What this client offers for crafting: { checked, build, craftingOrders = { exists, apis, showTab, guildType },
-- guildTradeSkills, guildRecipeQuery, guildRecipeLookup, presence }. Calls nothing that changes anything.
function CraftCompat.Probe()
  local version, build = call("GetBuildInfo")
  version, build = str(version), str(build)
  local orders = resolve("C_CraftingOrders")
  local apis = {}
  for _, name in ipairs(ORDER_APIS) do apis[name] = has(name) end
  local showTab = nil
  if has("C_CraftingOrders.ShouldShowCraftingOrderTab") then
    local v = plain(call("C_CraftingOrders.ShouldShowCraftingOrderTab"))
    if v ~= nil then showTab = v and true or false end
  end
  local guildType = resolve("Enum.CraftingOrderType.Guild")
  local tradeSkills = plain(call("C_TradeSkillUI.IsGuildTradeSkillsEnabled")) == true
  local query = has("C_GuildInfo.QueryGuildMembersForRecipe")
  local presence = {}
  for _, name in ipairs(CraftCompat.APIS) do presence[name] = has(name) end
  for _, name in ipairs(CraftCompat.APIS.optional) do presence[name] = has(name) end
  for _, name in ipairs(CraftCompat.WATCH) do presence[name] = has(name) end
  for _, name in ipairs(CraftCompat.VALUES) do presence[name] = resolve(name) ~= nil end
  return {
    checked = CraftCompat.Now(),
    build = (version and build) and (version .. "." .. build) or build,
    craftingOrders = {
      exists = type(orders) == "table",
      apis = apis,
      showTab = showTab,
      guildType = type(guildType) == "number" and guildType or nil,
    },
    guildTradeSkills = tradeSkills,
    guildRecipeQuery = query,
    guildRecipeLookup = tradeSkills and query,
    presence = presence,
  }
end
