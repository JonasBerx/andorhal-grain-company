-- GuildSyncCrafting, CraftHost: the one adapter between the crafting files and GuildSync's public API (API 5,
-- addon/API.md). It reads no GuildSync ns field: everything goes through the global GuildSync and the handle M that
-- GuildSync.RegisterModule returns (CraftHost.M, set by Register at the end of CraftUI.lua).
--
-- Roster "known" is GuildSync.Comm.Roster's: until GuildSync has read the roster this session, crafting sends and
-- accepts nothing. Own characters come from M.Professions (this account's characters, keyed by GUID in the hub).

local _, ns = ...

local CraftHost = {}
ns.CraftHost = CraftHost

local CraftCompat = ns.CraftCompat

local ID, MODULE, VERSION = "crafting", "Crafting", "0.1"
local CHANGED_GAP = 5 -- seconds between two page refreshes (f1013)
local GUILD_RETRY, GUILD_TRIES = 5, 24 -- the guild name can be missing right at login
local RELAYOUT_SETTLE = 0.2 -- seconds after a resize before the page is laid out again
local INERT = "Demo: nothing is done to made-up members." -- GuildSync's demo inert line (Demo.lua), copied

CraftHost.M = nil -- the handle, once Register ran

local function pack(...) return { n = select("#", ...), ... } end

-- ---------- small passthroughs ----------

-- Runs fn under M.Safe (recorded under Crafting); before Register, under a plain pcall.
function CraftHost.Safe(fn, ...)
  local M = CraftHost.M
  if M then return M.Safe(fn, ...) end
  local r = pack(pcall(fn, ...))
  return r[1], r[2]
end
function CraftHost.After(seconds, fn)
  local M = CraftHost.M
  if M then M.After(seconds, fn) end
end
function CraftHost.Say(text) if GuildSync then GuildSync.Say(text) end end

-- ---------- kit bridges (the only way the Craft files reach M.Kit) ----------
-- Every kit callback runs under the module's title (API.md, M.Kit). Nil or false = the caller keeps its own widget.

local function kit() return CraftHost.M and CraftHost.M.Kit end

-- A yes/no question through the kit (StaticPopup, else the kit's own confirm window).
function CraftHost.Confirm(which, text, okText, onOk)
  local K = kit()
  return K and K.Confirm(which, text, okText, onOk)
end
function CraftHost.Tabs(parent, entries, onSelect) local K = kit() return K and K.Tabs(parent, entries, onSelect) end
function CraftHost.Card(parent, w, h) local K = kit() return K and K.Card(parent, w, h) end
function CraftHost.Checkbox(parent, text) local K = kit() return K and K.Checkbox(parent, text) end
function CraftHost.SearchBox(parent, width, hint) local K = kit() return K and K.SearchBox(parent, width, hint) end
function CraftHost.InputBox(parent, width, fallbackWidth)
  local K = kit()
  return K and K.InputBox(parent, width, fallbackWidth)
end
function CraftHost.Dropdown(parent, width, generate)
  local K = kit()
  return K and K.Dropdown(parent, width, generate)
end
function CraftHost.DropdownText(dd, text) local K = kit() return K and K.DropdownText(dd, text) end
function CraftHost.List(parent, rowH, build, init) local K = kit() return K and K.List(parent, rowH, build, init) end
function CraftHost.MatchMenu(owner, entries, onPick, emptyText)
  local K = kit()
  return K and K.MatchMenu(owner, entries, onPick, emptyText)
end
function CraftHost.CloseMenu(menu) local K = kit() return K and K.CloseMenu(menu) end
function CraftHost.Ask(which, text, okText, cancelText, onOk)
  local K = kit()
  return K and K.Ask(which, text, okText, cancelText, onOk)
end
function CraftHost.Atlas(tex, name, fallback) local K = kit() return K and K.Atlas(tex, name, fallback) end
-- Crafters and Recipes pieces. None of these hands the kit a callback: CraftUI sets their OnClick and hooks itself and
-- runs each body through CraftHost.Safe.
function CraftHost.FavouriteStar(parent) local K = kit() if not K then return nil end return K.FavouriteStar(parent) end
function CraftHost.SetFavourite(star, on) local K = kit() if not K then return nil end return K.SetFavourite(star, on) end
function CraftHost.ListHover(frame, fallback) local K = kit() if not K then return nil end return K.ListHover(frame, fallback) end
function CraftHost.BookRow(parent, w, h) local K = kit() if not K then return nil end return K.BookRow(parent, w, h) end
function CraftHost.SetBookRow(row, spec) local K = kit() if not K then return nil end return K.SetBookRow(row, spec) end
function CraftHost.Divider(parent) local K = kit() if not K then return nil end return K.Divider(parent) end
function CraftHost.CloseDropdown(dd) local K = kit() if not K then return nil end return K.CloseDropdown(dd) end
function CraftHost.ClassIcon(tex, token)
  local K = kit()
  return K and K.ClassIcon(tex, token, "groupfinder-icon-class-")
end

-- Icon of a profession by its skill line id, then by its name (a copy of GuildSync's View.ProfessionIcon).
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
local UNKNOWN_ICON = ICONS .. "INV_Misc_QuestionMark"

function CraftHost.ProfessionIcon(id, name)
  local file = PROF_ICONS[id]
  if not file and type(name) == "string" then file = PROF_ICONS[PROF_IDS[string.lower(name)] or 0] end
  return file and (ICONS .. file) or UNKNOWN_ICON
end
-- The "online" green (a copy of GuildSync's View.ONLINE_GREEN).
local ONLINE_GREEN = { 0.1, 1.0, 0.1 }
function CraftHost.Green() return ONLINE_GREEN[1], ONLINE_GREEN[2], ONLINE_GREEN[3] end
-- The game's GameTooltip, or nil (M.Compat.Tooltip). The caller runs its OnEnter/OnLeave under CraftHost.Safe.
function CraftHost.Tooltip()
  local M = CraftHost.M
  return M and M.Compat.Tooltip() or nil
end

-- ---------- module fields, demo ----------

local fields = {} -- what CraftSync handed over (CraftHost.RegisterModule): demo, events, onEvent, status, selftest
function CraftHost.RegisterModule(mod)
  if type(mod) == "table" then fields = mod end
end

local demoSerial, demoFns = 0, {}

-- /gsync demo, through M.Demo: on, the Crafting module's demo state (nil when off), the session serial (a module
-- counter raised each time demo turns on), the inert line (true when it was said) and the demo event.
function CraftHost.DemoOn()
  local M = CraftHost.M
  return M ~= nil and (M.Demo()) == true
end
function CraftHost.DemoState()
  local M = CraftHost.M
  if not M then return nil end
  local on, state = M.Demo()
  if on then return state end
  return nil
end
function CraftHost.DemoSerial() return demoSerial end
function CraftHost.DemoInert()
  if not CraftHost.DemoOn() then return false end
  CraftHost.Say(INERT)
  return true
end
-- fn(on) on each demo change; stored until Register, which hears the hub's "demo" event.
function CraftHost.OnDemo(fn)
  if type(fn) ~= "function" then return nil end
  demoFns[#demoFns + 1] = fn
  return true
end
-- "tell" | "fallback": the hub API's whisper helper.
function CraftHost.OpenWhisper(name, link) return GuildSync.OpenWhisper(name, link) end

-- ---------- roster ----------

local cache = { serial = nil, keys = nil, version = 0 }

local function profSame(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  return a.id == b.id and a.rank == b.rank and a.name == b.name
end

-- true when two keys tables list the same members with the same name, class, online flag and professions
local function sameRows(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for key, r in pairs(a) do
    local o = b[key]
    if not o or o.name ~= r.name or o.class ~= r.class or o.online ~= r.online
       or not profSame(o.prof1, r.prof1) or not profSame(o.prof2, r.prof2) then
      return false
    end
  end
  for key in pairs(b) do if not a[key] then return false end end
  return true
end

-- keys, partial, serial, known: GuildSync.Comm.Roster's. keys = { [key] = { name, class, online, prof1, prof2, rankIndex } }.
function CraftHost.Roster()
  local keys, partial, serial, known = GuildSync.Comm.Roster()
  if serial ~= cache.serial then
    if not sameRows(keys, cache.keys) then cache.version = cache.version + 1 end
    cache.serial, cache.keys = serial, keys
  end
  return keys, partial, serial, known
end

-- Raised only when a newly read roster lists different members or rows (a re-read with the same rows keeps it), so
-- the UI's id index is not rebuilt on every roster read (f1025).
function CraftHost.RosterVersion()
  CraftHost.Roster()
  return cache.version
end

-- ---------- own characters ----------

local mine = nil -- the MyChars cache; nil = rebuild
local mineVersion = nil

-- Drops the MyChars cache (the "professions" event, a roster change, a share toggle).
function CraftHost.ResetMyChars() mine = nil end

-- This account's characters on the roster: { { key, name, class, profs }, ... }, sorted by key, from M.Professions.
-- profs = { [skillLineID] = { name, rank, max, recipes = { [spellID] = itemID | name } } }. Records of one key fold
-- into one entry; for a profession both hold, the more recently updated record wins.
function CraftHost.MyChars()
  local M = CraftHost.M
  if not M then return {} end
  if mine and mineVersion == cache.version then return mine end
  local chars = M.Professions()
  local byKey = {}
  for _, c in ipairs(type(chars) == "table" and chars or {}) do
    if type(c) == "table" and c.onRoster and type(c.key) == "string" then
      local e = byKey[c.key]
      if not e then
        e = { key = c.key, name = c.name, class = c.class, profs = {}, at = {} }
        byKey[c.key] = e
      end
      local updated = type(c.updated) == "number" and c.updated or 0
      for id, prof in pairs(type(c.professions) == "table" and c.professions or {}) do
        if e.at[id] == nil or updated > e.at[id] then e.profs[id], e.at[id] = prof, updated end
      end
    end
  end
  local out = {}
  for _, e in pairs(byKey) do out[#out + 1] = { key = e.key, name = e.name, class = e.class, profs = e.profs } end
  table.sort(out, function(a, b) return a.key < b.key end)
  mine, mineVersion = out, cache.version
  return out
end

-- The character logged in now: key, name (no realm), or nil. GuildSync.Comm.MyKey (found by GUID once the roster is
-- read), with the roster's display name, before that the name UnitName gives.
function CraftHost.Me()
  local key = GuildSync.Comm.MyKey()
  if not key then return nil end
  local row = GuildSync.Comm.Member(key)
  local name = row and type(row.name) == "string" and row.name or CraftCompat.PlayerName()
  if not name then return nil end
  return key, (string.gsub(name, "%-.*$", ""))
end

function CraftHost.MyKeys()
  local out = {}
  for _, c in ipairs(CraftHost.MyChars()) do out[c.key] = true end
  return out
end

-- what = "i<itemID>" (an own recipe makes that item) or "s<spellID>" (an own recipe is that spell).
function CraftHost.CanMake(what)
  if type(what) ~= "string" then return false end
  local kind, id = string.match(what, "^([is])(%d+)$")
  id = tonumber(id)
  if not id then return false end
  for _, c in ipairs(CraftHost.MyChars()) do
    for _, prof in pairs(c.profs) do
      local recipes = type(prof) == "table" and prof.recipes
      if type(recipes) == "table" then
        if kind == "s" then
          if recipes[id] ~= nil then return true end
        else
          for _, itemID in pairs(recipes) do
            if itemID == id then return true end
          end
        end
      end
    end
  end
  return false
end

function CraftHost.GuildName() return CraftCompat.GuildName() end

-- ---------- the page ----------

local lastChanged, changedQueued = nil, false

local function tellPage()
  lastChanged = time()
  if CraftHost.M then CraftHost.M.RefreshPage() end
end

-- A stored change: refreshes the Crafting page (M.RefreshPage, only while it is the open page) at most once per 5 s.
-- A change inside the 5 s is not lost: one call follows when the 5 s are over.
function CraftHost.Changed()
  if changedQueued then return end
  local now = time()
  if not lastChanged or now - lastChanged >= CHANGED_GAP then
    tellPage()
    return
  end
  changedQueued = true
  CraftHost.After(CHANGED_GAP - (now - lastChanged), function()
    changedQueued = false
    tellPage()
  end)
end

-- This module's hold on the minimap button's glow (M.Glow).
function CraftHost.SetGlow(on)
  local M = CraftHost.M
  if M then M.Glow(on and true or false) end
end

-- The Crafting page is a module page of the GuildSync window (D3): the hub builds it, marks it and runs refresh only
-- while it is the current page. One page and one settings spec: a second AddPage or AddSettings replaces the first.
local pageSpec, settingsSpec

function CraftHost.AddPage(spec) pageSpec = spec end
function CraftHost.AddSettings(spec) settingsSpec = spec end

-- Opens the window (when closed) on the Crafting page; tab goes to spec.onShow.
function CraftHost.ShowCraft(tab)
  if pageSpec and pageSpec.onShow then CraftHost.Safe(pageSpec.onShow, tab) end
  if CraftHost.M then CraftHost.M.OpenPage() end
end

local sizeW, sizeH, settling = nil, nil, false

local function relayout()
  if not (pageSpec and pageSpec.relayout and sizeW and sizeH) then return end
  pageSpec.relayout({ contentW = sizeW, contentH = sizeH })
end

local function onSize(w, h)
  if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
  sizeW, sizeH = w, h
  if settling then return end
  settling = true
  CraftHost.After(RELAYOUT_SETTLE, function()
    settling = false
    relayout()
  end)
end

local function buildPage(frame)
  pageSpec.build(frame)
  if frame.GetWidth and frame.GetHeight then
    sizeW, sizeH = frame:GetWidth(), frame:GetHeight()
    if type(sizeW) == "number" and type(sizeH) == "number" and sizeW > 0 and sizeH > 0 then relayout() end
  end
  frame:SetScript("OnSizeChanged", function(_, w, h) CraftHost.Safe(onSize, w, h) end)
end

local function refreshPage(frame)
  if pageSpec.seen then CraftHost.Safe(pageSpec.seen) end -- the shown tab is seen (the Work board clears the glow)
  if pageSpec.dirty and pageSpec.dirty() then pageSpec.draw(frame) end
end

-- ---------- the game's Options window (settings(S), D11) ----------
-- Keys follow the hub's rule (lower case); get and set bridge to the saved camelCase keys. The hub calls set and
-- onClick only once its category is in place, and never while demo is on.

local function retentionValues()
  local CraftView, out, v = ns.CraftView, {}, 14
  repeat
    out[#out + 1] = { v, (string.gsub(CraftView.RetentionLabel(v), "^%l", string.upper)) } -- "forever" -> "Forever"
    v = CraftView.NextRetention(v)
  until v == 14 or #out >= 10
  return out
end

local function addSettings(S)
  local spec = settingsSpec
  for _, sw in ipairs(spec.switches or {}) do
    local key, set = string.lower(sw.key), sw.onSet
    if key == "share" and set then -- a share toggle rebuilds the MyChars cache
      set = function(...) CraftHost.ResetMyChars() return sw.onSet(...) end
    end
    S.Checkbox(key, sw.text, CraftCompat.SettingDefault(sw.key), sw.get, set)
  end
  local r = spec.retention
  if r then
    S.Dropdown("retention", "Keep crafters not seen for", CraftCompat.SettingDefault("retention"), retentionValues,
      r.get, r.set)
  end
  for i, c in ipairs(spec.clears or {}) do S.Button("clear" .. i, c.name, c.button, c.click) end
end

-- ---------- login ----------

local loggedIn = false
-- true once PLAYER_LOGIN ran (the saved variables have loaded; the selftest says "wait" before)
function CraftHost.LoggedIn() return loggedIn end

local function useGuild(tries)
  local name = CraftHost.GuildName()
  if name then
    CraftCompat.UseGuild(name)
  elseif tries < GUILD_TRIES then
    CraftHost.After(GUILD_RETRY, function() useGuild(tries + 1) end)
  end
end

local function hostLogin()
  loggedIn = true
  local db = CraftCompat.DB()
  CraftCompat.Dir()
  useGuild(0)
  -- the glow of an alert not yet seen comes back after a reload or relog (f1017)
  if db.glow == true and db.settings.alertGlow then CraftHost.SetGlow(true) end
end

-- The probe's facts for the selftest line (CraftCompat.Probe, read only): "build X, crafting orders ..., guild recipe
-- lookup yes|no".
function CraftHost.ProbeLine()
  local p = CraftCompat.Probe()
  local o = p.craftingOrders
  local orders = not o.exists and "none" or o.showTab == true and "tab shown" or o.showTab == false and "tab hidden"
    or "tab unknown"
  return "build " .. tostring(p.build or "unknown") .. ", crafting orders " .. orders .. ", guild recipe lookup "
    .. (p.guildRecipeLookup and "yes" or "no")
end

-- ---------- registration (D12) ----------

-- Registers the module once with the hub (the last line of CraftUI.lua), then attaches CraftSync. Returns M or nil.
function CraftHost.Register()
  if CraftHost.M then return CraftHost.M end
  if not (GuildSync and GuildSync.RegisterModule) then return nil end
  local stored = fields
  local M = GuildSync.RegisterModule({
    id = ID, title = MODULE, version = VERSION, needs = 5, apis = CraftCompat.APIS,
    demo = stored.demo, status = stored.status,
    -- a pass carries the probe's facts: build, crafting orders, guild recipe lookup (d422 q350)
    selftest = stored.selftest and function()
      local state, text = stored.selftest()
      if state == "pass" then text = tostring(text) .. "; " .. CraftHost.ProbeLine() end
      return state, text
    end or nil,
    events = { "PLAYER_LOGIN" }, -- CraftHost's login work below; CraftSync's stored events are this same one
    -- CraftHost's login work (saved tables, guild) first, then CraftSync's
    onEvent = function(event, ...)
      if event == "PLAYER_LOGIN" then hostLogin() end
      if stored.onEvent then return stored.onEvent(event, ...) end
    end,
    page = pageSpec and {
      title = pageSpec.label or MODULE, icon = pageSpec.icon,
      build = buildPage, refresh = refreshPage,
    } or nil,
    settings = settingsSpec and addSettings or nil,
  })
  if not M then return nil end
  CraftHost.M = M
  M.On("demo", function(on)
    if on then demoSerial = demoSerial + 1 end
    for _, fn in ipairs(demoFns) do M.Safe(fn, on) end
  end)
  M.On("professions", function() mine = nil end)
  M.On("rosterRead", function() CraftHost.RosterVersion() end)
  local CraftSync = ns.CraftSync
  if CraftSync and CraftSync.Attach then CraftSync.Attach(M) end
  return M
end
