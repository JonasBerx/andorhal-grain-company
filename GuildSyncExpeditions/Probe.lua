-- GuildSyncExpeditions Probe.lua: the in-game probe (0.19 plan, Seams 13; B1 run Task 2). Jonas runs it in the client
-- and pastes the lines: it settles which quest kinds and which character-screen picture the later slices can build.
--   /gsync expeditions probe                    one line per apis name, in PROBE_CALLS order
--   /gsync expeditions probe arm <kind>         listens 5 minutes for that kind's events (place, mail, kill, talk);
--                                               one deadline per kind, refused while the server time is unknown
--   /gsync expeditions probe model <race> <sex> shows route 1 of the model routes in a labelled frame
--   /gsync expeditions probe model next         hides that route's frame and shows the next; "probe model done" last
--   /gsync expeditions probe clear              empties the saved lines
-- Every line names what it called and its class: "absent or error" (missing, refused or threw), "nil or secret"
-- (answered nil, or a secret the hub plains to nil) or "value" plus the plain value through GuildSync.Escape. A raw
-- payload value is never compared or joined: it goes through GuildSync.Compat.Plain first.
-- The probe sends nothing. It writes only its own lines, to GuildSyncExpeditionsDB.probeLog (the newest LOG_MAX, each
-- "<time()> <line>"), so they reach the SavedVariables file on /reload or logout.
-- manual-verify before the beta: the DISPLAY ids and the two ITEMS on wago.tools, and the portrait path in the art.

local _, ns = ...

if not ns.M then return end
local M = ns.M
local Plain = GuildSync.Compat.Plain
local Escape = ns.Escape

local ARM_FOR = 300 -- seconds an armed kind listens
local HEARTH = 6948 -- Hearthstone, the item calls' test item
local QUEST = 1 -- the quest-completed call's test quest
local MAIL_SLOTS = 12 -- ATTACHMENTS_MAX_SEND
local ITEMS = { 2575, 6125 } -- Red Linen Shirt, Brawler's Pants
local HOLDER_W, HOLDER_H = 300, 400

local USAGE = "probe: /gsync expeditions probe [arm <place|mail|kill|talk> | model <race> <sex> | model next | clear]."
  .. " Races: Human, Orc, Dwarf, NightElf, Scourge, Tauren, Gnome, Troll; sex male or female."
  .. " Arm needs the server time."

local LOG_MAX = 400 -- saved lines kept; the oldest goes first
local WHERE = "GuildSyncExpeditionsDB.probeLog in WTF/Account/<account>/SavedVariables/GuildSyncExpeditions.lua"

-- The saved lines, oldest first. Store.lua's rules: a saved table or a probeLog of the wrong type is made fresh. Kept
-- in demo too (not through ns.Part): the lines are about this client, not game data.
local function probeLog()
  if type(GuildSyncExpeditionsDB) ~= "table" then GuildSyncExpeditionsDB = {} end
  local d = GuildSyncExpeditionsDB
  if type(d.probeLog) ~= "table" then d.probeLog = {} end
  return d.probeLog
end

-- Prints one line and saves it. The line is already plain: every value in it went through text() or Escape.
local function say(line)
  ns.Say(line)
  local log = probeLog()
  while #log >= LOG_MAX do table.remove(log, 1) end
  log[#log + 1] = time() .. " " .. line
end

local function clear()
  probeLog()
  GuildSyncExpeditionsDB.probeLog = {}
  ns.Say("probe saved lines cleared.") -- not saved, so the list stays empty
end

local CUT = 200 -- bytes of one printed value, before Escape

-- A plain value as one safe piece of a line: control bytes removed, cut to CUT bytes, then escaped (security f2).
local function text(v)
  local s = string.gsub(tostring(v), "[%z\1-\31\127]", "")
  if #s > CUT then s = string.sub(s, 1, CUT) .. "..." end
  return Escape(s)
end

-- A plain value's class: "value <text>", or "nil or secret". A position table counts only when its x and y are both
-- plain numbers after Plain (security f1).
local function valueClass(v)
  if v == nil then return "nil or secret" end
  if type(v) == "table" and (v.x ~= nil or v.y ~= nil) then
    local x, y = Plain(v.x), Plain(v.y)
    if type(x) ~= "number" or type(y) ~= "number" then return "nil or secret" end
    return "value " .. string.format("%.4f, %.4f", x, y)
  end
  return "value " .. text(v)
end

-- The class of a call's first answer (ok false: absent or error).
local function class(ok, v)
  if not ok then return "absent or error" end
  return valueClass(Plain(v))
end

local function try(label, name, ...)
  local ok, v = M.Compat.Try(name, ...)
  say(label .. ": " .. class(ok, v))
  return ok and v or nil
end

-- ---------- /gsync expeditions probe ----------

local function probeCalls()
  say("probe lines are saved to " .. WHERE .. " on /reload or logout; /gsync expeditions probe clear empties them.")
  try("GetServerTime()", "GetServerTime")
  try("C_DateAndTime.GetSecondsUntilDailyReset()", "C_DateAndTime.GetSecondsUntilDailyReset")
  local map = try('C_Map.GetBestMapForUnit("player")', "C_Map.GetBestMapForUnit", "player")
  try('C_Map.GetPlayerMapPosition(map, "player")', "C_Map.GetPlayerMapPosition", map, "player")
  try("C_Map.GetMapInfo(map)", "C_Map.GetMapInfo", map)
  try("GetSendMailItem(1)", "GetSendMailItem", 1)
  try("C_Item.GetItemCount(" .. HEARTH .. ")", "C_Item.GetItemCount", HEARTH)
  try("C_Item.GetItemInfo(" .. HEARTH .. ")", "C_Item.GetItemInfo", HEARTH)
  try('UnitGUID("player")', "UnitGUID", "player")
  try('UnitName("player")', "UnitName", "player")
  try('UnitRace("player")', "UnitRace", "player")
  try('UnitSex("player")', "UnitSex", "player")
  try('UnitIsDead("player")', "UnitIsDead", "player")
  try("C_QuestLog.IsQuestFlaggedCompleted(" .. QUEST .. ")", "C_QuestLog.IsQuestFlaggedCompleted", QUEST)
end

-- ---------- probe arm <kind> ----------

local KIND_OF = {
  ZONE_CHANGED_NEW_AREA = "place",
  MAIL_SHOW = "mail", MAIL_SEND_INFO_UPDATE = "mail", MAIL_SEND_SUCCESS = "mail", MAIL_FAILED = "mail",
  MAIL_CLOSED = "mail",
  PARTY_KILL = "kill", PLAYER_TARGET_CHANGED = "kill",
  GOSSIP_SHOW = "talk", QUEST_GREETING = "talk", MERCHANT_SHOW = "talk",
}
local KINDS = { place = true, mail = true, kill = true, talk = true }
local deadline = {} -- kind -> { at = server second it stops listening }, one table per arm

-- Each arm's timer ends only its own arm: a re-arm puts a new table in deadline[kind], so an earlier timer finds a
-- different one and says nothing. The timer does not read the clock, so a server clock a second behind the timer
-- still ends the arm (review f4).
local function arm(kind)
  if not KINDS[kind] then say(USAGE) return end
  local now = ns.Now()
  if not now then say(USAGE) return end
  local mine = { at = now + ARM_FOR }
  deadline[kind] = mine
  say("probe " .. kind .. " armed for 5 minutes.")
  M.After(ARM_FOR, function()
    if deadline[kind] == mine then
      deadline[kind] = nil
      say("probe " .. kind .. " ended.")
    end
  end)
end

local function mailLines()
  for i = 1, MAIL_SLOTS do try("GetSendMailItem(" .. i .. ")", "GetSendMailItem", i) end
  local box = SendMailNameEditBox
  local ok, v = false, nil
  if type(box) == "table" and type(box.GetText) == "function" then ok, v = pcall(box.GetText, box) end
  say("SendMailNameEditBox:GetText(): " .. class(ok, v))
end

function ns.OnProbeEvent(event, ...)
  local kind = KIND_OF[event]
  local d = kind and deadline[kind]
  if not d then return end
  local now = ns.Now()
  if not now or now >= d.at then return end
  local n = select("#", ...)
  local parts = { event .. ": " .. n .. " field(s)" }
  for i = 1, n do
    parts[#parts + 1] = i .. " " .. class(true, (select(i, ...)))
  end
  say(table.concat(parts, "; "))
  if kind == "mail" then
    mailLines()
  elseif kind == "talk" then
    try('UnitGUID("npc")', "UnitGUID", "npc")
  elseif kind == "place" then
    local map = try('C_Map.GetBestMapForUnit("player")', "C_Map.GetBestMapForUnit", "player")
    try('C_Map.GetPlayerMapPosition(map, "player")', "C_Map.GetPlayerMapPosition", map, "player")
  elseif event == "PLAYER_TARGET_CHANGED" then
    try('UnitGUID("target")', "UnitGUID", "target")
    try('UnitIsDead("target")', "UnitIsDead", "target")
  end
end

-- ---------- probe model ----------

-- One display id per race and sex (manual-verify on wago.tools CreatureDisplayInfo).
local RACES = { "Human", "Orc", "Dwarf", "NightElf", "Scourge", "Tauren", "Gnome", "Troll" }
local DISPLAY = {
  Human = { 49, 50 }, Orc = { 51, 52 }, Dwarf = { 53, 54 }, NightElf = { 55, 56 }, Scourge = { 57, 58 },
  Tauren = { 59, 60 }, Gnome = { 1563, 1564 }, Troll = { 1478, 1479 },
}
local SEX = { male = 2, female = 3 } -- UnitSex's answers

-- Each route: its label, the frame type it makes, and its calls ({ method, args } on the frame, or on a ModelScene
-- actor). "id" stands for the asked display id, "item" for each test item.
local ROUTES = {
  { label = "SetUnit", kind = "DressUpModel",
    calls = { { "SetUnit", "player" }, { "Undress" }, { "TryOn", "item" } } },
  { label = "DressUpModel", kind = "DressUpModel",
    calls = { { "SetDisplayInfo", "id" }, { "Undress" }, { "TryOn", "item" } } },
  { label = "PlayerModel", kind = "PlayerModel",
    calls = { { "SetDisplayInfo", "id" }, { "Undress" }, { "TryOn", "item" } } },
  { label = "CinematicModel", kind = "CinematicModel",
    calls = { { "SetDisplayInfo", "id" }, { "Undress" }, { "TryOn", "item" } } },
  { label = "ModelScene actor", kind = "ModelScene", actor = true,
    calls = { { "SetModelByCreatureDisplayID", "id" }, { "Undress" }, { "TryOn", "item" }, { "Dress" } } },
  { label = "SetDisplayInfo / SetModelByCreatureDisplayID", kind = "DressUpModel",
    calls = { { "SetModelByCreatureDisplayID", "id" }, { "SetDisplayInfo", "id" }, { "Undress" }, { "TryOn", "item" },
      { "Dress" } },
    -- review f2: SetItemTransmogInfo needs a transmog-info object, so the probe only reports whether it exists.
    exists = { "SetItemTransmogInfo" } },
}

local view = { frames = {}, actors = {} } -- holder, label, portrait, the frame per route (made once), the run
local run -- { race, sex, id, counted, step } while a model run is open

local function holder()
  if view.holder then return view.holder end
  local h = CreateFrame("Frame", nil, UIParent)
  h:SetSize(HOLDER_W, HOLDER_H)
  h:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  view.label = h:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  view.label:SetPoint("TOPLEFT", h, "TOPLEFT", 8, -8)
  view.label:SetPoint("RIGHT", h, "RIGHT", -8, 0)
  view.label:SetJustifyH("LEFT")
  view.portrait = h:CreateTexture(nil, "ARTWORK")
  view.portrait:SetSize(64, 64)
  view.portrait:SetPoint("TOPRIGHT", h, "TOPRIGHT", -8, -40)
  view.holder = h
  return h
end

-- The route's frame, made once on first use (pcall: a missing widget type answers nil).
local function routeFrame(i)
  if view.frames[i] ~= nil then return view.frames[i] or nil end
  local ok, f = pcall(CreateFrame, ROUTES[i].kind, nil, holder())
  if not ok or type(f) ~= "table" then view.frames[i] = false return nil end
  if type(f.SetPoint) == "function" then pcall(f.SetPoint, f, "BOTTOMLEFT", holder(), "BOTTOMLEFT", 8, 8) end
  if type(f.SetSize) == "function" then pcall(f.SetSize, f, HOLDER_W - 16, HOLDER_H - 120) end
  view.frames[i] = f
  return f
end

local function callOn(obj, method, ...)
  if type(obj) ~= "table" or type(obj[method]) ~= "function" then return false end
  local ok, v = pcall(obj[method], obj, ...)
  return ok, v
end

local function hideRoutes()
  for _, f in pairs(view.frames) do
    if f and type(f.Hide) == "function" then pcall(f.Hide, f) end
  end
end

local function showRoute(i)
  local r, route = run, ROUTES[i]
  hideRoutes()
  local f = routeFrame(i)
  if f and type(f.Show) == "function" then pcall(f.Show, f) end
  local tag = "route " .. i .. " " .. route.label
  local head = tag .. ": asked " .. r.race .. " " .. r.sexWord .. " (display " .. r.id .. "), items " .. ITEMS[1]
    .. " and " .. ITEMS[2]
  if i == 1 and not r.counted then head = head .. "; not counted (not your own race and sex)" end
  say(head)
  if not f then say(tag .. " CreateFrame(" .. route.kind .. "): absent or error") end
  local target = f
  if f and route.actor then
    if view.actors[i] == nil then
      local ok, a = callOn(f, "CreateActor")
      view.actors[i] = (ok and type(a) == "table") and a or false
      say(tag .. " CreateActor(): " .. class(ok, ok and (view.actors[i] and true or nil) or nil))
    end
    target = view.actors[i] or nil
  end
  for _, c in ipairs(route.calls) do
    local method, arg = c[1], c[2]
    if arg == "item" then
      for _, item in ipairs(ITEMS) do
        local ok, v = callOn(target, method, "item:" .. item)
        say(tag .. " " .. method .. "(item:" .. item .. "): " .. class(ok, v))
      end
    else
      local a = arg == "id" and r.id or arg
      local ok, v = callOn(target, method, a)
      say(tag .. " " .. method .. "(" .. (a ~= nil and Escape(tostring(a)) or "") .. "): " .. class(ok, v))
    end
  end
  for _, method in ipairs(route.exists or {}) do
    local has = type(target) == "table" and type(target[method]) == "function"
    say(tag .. " " .. method .. " exists: " .. (has and "value function" or "absent or error"))
  end
  view.label:SetText(Escape(tag) .. "\nAsked: " .. r.race .. " " .. r.sexWord .. ", items " .. ITEMS[1] .. " and "
    .. ITEMS[2] .. ".\nRead off the race and sex shown and whether the items show, then type /gsync expeditions"
    .. " probe model next.")
  say(tag .. ": read off the race and sex shown and whether both items show, then /gsync expeditions probe model next.")
end

local function modelStart(raceWord, sexWord)
  local race
  for _, name in ipairs(RACES) do
    if string.lower(name) == string.lower(raceWord or "") then race = name end
  end
  local sex = SEX[string.lower(sexWord or "")]
  if not race or not sex then say(USAGE) return end
  local _, _, file = M.Compat.Try("UnitRace", "player")
  local _, own = M.Compat.Try("UnitSex", "player")
  run = { race = race, sex = sex, sexWord = sex == 2 and "male" or "female", id = DISPLAY[race][sex - 1],
    counted = (file == race and own == sex), step = 1 }
  local h = holder()
  h:Show()
  view.portrait:SetTexture("Interface\\CharacterFrame\\TemporaryPortrait-" .. (sex == 2 and "Male" or "Female") .. "-"
    .. race)
  showRoute(1)
end

local function modelNext()
  if not run then say(USAGE) return end
  run.step = run.step + 1
  if run.step > #ROUTES then
    run = nil
    hideRoutes()
    if view.holder then view.holder:Hide() end
    say("probe model done.")
    return
  end
  showRoute(run.step)
end

function ns.Probe(rest)
  local words = {}
  for w in string.gmatch(rest or "", "%S+") do words[#words + 1] = w end
  local cmd = string.lower(words[1] or "")
  if cmd == "" then
    probeCalls()
  elseif cmd == "arm" then
    arm(string.lower(words[2] or ""))
  elseif cmd == "model" and string.lower(words[2] or "") == "next" then
    modelNext()
  elseif cmd == "model" then
    modelStart(words[2], words[3])
  elseif cmd == "clear" then
    clear()
  else
    say(USAGE)
  end
end
