local _, ns = ...
if not ns.M then return end
-- RollPopup.lua: the raider's side of the loot master's roll session: the roll popup (an O) and the told award (a W).
-- Exports:
--   ns.SessionCounts() -> a copy of { O = { [why] = n }, W = { [why] = n } } (what each reader dropped or kept)
--   ns.RollPopupFrame() -> the popup frame, or nil
-- Sets at load the handles of SessionWire's O and W entries: ns.RaidsR.O.handle(msg, from) and
-- ns.RaidsR.W.handle(msg, from); never a new entry and never a pack, so this file sends nothing on any comm domain.
-- Saved key written: GuildSyncRaidsDB.session.popup = { x, y } (on drag stop).
--
-- Both readers first: demo -> "demo"; not in a raid -> "group"; the sender not exactly leading my raid
-- (ns.LeadsMyRaid, a throw counts as no) -> "sender".
-- The O reader then: closes at or before now -> "late"; closes more than 300 s
-- ahead -> "far"; not newer than the last O kept for its by (session, then n, then closes) -> "old"; a (by, session,
-- n) the player passed -> "passed"; else it is kept and shown through the combat gate. At most 40 senders are kept.
--
-- The combat gate (as JobCard.lua): fighting unless InCombatLockdown answers exactly false. In a fight the one O to
-- show is held (the last wins) and an item load's redraw is held; at the fight's end (ns.AfterCombat) the gate is
-- checked again, then the held O opens while still in time, else it counts "late". The player's own Pass, Close and
-- drag, and the close at the closing time (M.After), act at once, also in a fight: the popup is not a protected frame.
--
-- The popup names the item and "Run by <by>" (names: the raid roster's display name for a key, else the key, escaped).
-- Per kind: R the roll buttons for the O's ranges (100 Main spec, 99 Off spec, 98 Disenchant) and Pass; S the same
-- when my key is among the reservers, else "Reserved: <names>" and Close; C and N one line and Close. Close marks the
-- (by, session, n) passed, as Pass does. The one
-- roll seam is rollFor: a roll button's click asks the game for the roll through M.Compat.Try, and when that did not
-- run it opens the chat box with "/roll <hi>". After a click the roll buttons are grey for that (by, session, n) and
-- "In chat" opens the chat box with the same line again. Nothing rolls from a timer, a message or a fight's end.
-- Popup state is memory only, apart from the saved place.
--
-- The W reader (a told award) then: by is my own key -> "own" (my award is recorded under its own ref); 30 or more W's of
-- this sender handed to the store in the last 60 s -> "rate"; no subject or version (SessionWire.Subject) ->
-- "subject"; a version not higher than the last seen for that subject -> "old"; a new subject while the sender's set
-- holds 150 this login, or once 200 new subjects of all senders were acted on this login (TOTAL) -> "cap" (a
-- correction to a known subject is free). Only a W handed to the store adds its time
-- and its subject; at most 40 senders are kept, the oldest dropped with its state. The record is built field by field
-- (item, suffix, who, how, roll, why when not empty, at, ref = the subject, src = "told", from = the sender's roster
-- name or key): src, by, id and from are never read from the message, and the store cleans who and why. One
-- ns.Loot.Record: nil -> "refused <why>", "kept" ->
-- "kept". Recorded or kept, the line "<who> got <item> (<label> <roll>)" is printed locally with ns.Say (escaped
-- parts, never a chat send) and shown on the popup while it shows the same by, session and n.

local M = ns.M
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only (made on the first read)
local call = M.Compat.call
local WIDTH, HEIGHT, PAD, BW = 260, 146, 10, 76
local AHEAD = 300 -- an O may close at most this many seconds ahead
local SENDERS = 40 -- senders kept by the readers
local COUNCIL_LINE = "Council item: the council decides."
local NAMED_LINE = "Named item: the loot master assigns it."
local RANGES = { { 100, "Main spec" }, { 99, "Off spec" }, { 98, "Disenchant" } }

-- ---------- counts and shared reads ----------

local counts = { O = {}, W = {} }
local function count(kind, why) counts[kind][why] = (counts[kind][why] or 0) + 1 end

function ns.SessionCounts()
  local out = { O = {}, W = {} }
  for kind, t in pairs(counts) do
    for why, n in pairs(t) do out[kind][why] = n end
  end
  return out
end

local function now()
  local t = call("GetServerTime")
  return type(t) == "number" and t or 0
end

local function fighting()
  local v = call("InCombatLockdown")
  return v ~= false
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function esc(s) return ns.Escape(tostring(s or "")) end

-- A handler body under M.Safe: a throw is recorded under the module, never a script error.
local function safe(fn) return function(...) M.Safe(fn, ...) end end

-- true only when the sender exactly leads my raid (leader or assistant); a throw counts as no.
local function leads(from)
  local good, v = pcall(ns.LeadsMyRaid, from)
  return good and v == true
end

-- The checks both readers make first -> the why of a drop, or nil.
local function refused(from)
  if M.Demo() then return "demo" end
  if ns.GroupKind() ~= "raid" then return "group" end
  if not leads(from) then return "sender" end
end

-- ---------- the popup ----------

local f -- the popup
local current -- { msg, key, told } while shown
local held -- { msg, key }: the O held back in a fight
local redrawHeld = false
local clicked, passed = {}, {} -- [key] = the range clicked; [key] = true

local function keyOf(msg) return tostring(msg.by) .. " " .. tostring(msg.session) .. "." .. tostring(msg.n) end

local function mine(list)
  local me = ns.MyKey()
  if type(me) ~= "string" then return false end
  for _, k in ipairs(type(list) == "table" and list or {}) do
    if k == me then return true end
  end
  return false
end

local function offers(ranges, hi)
  for _, r in ipairs(ranges) do
    if r == hi then return true end
  end
  return false
end

-- key -> the raid roster's display name, read once per draw; empty when the roster is unknown or throws.
local function rosterNames()
  local names = {}
  local good, roster = pcall(ns.RaidRoster)
  if not good or type(roster) ~= "table" then return names end
  for _, r in ipairs(roster) do
    if type(r) == "table" and type(r.key) == "string" and type(r.name) == "string" then names[r.key] = r.name end
  end
  return names
end

local function draw(cur)
  local o = cur.msg
  local info = ns.Items.Info(o.item)
  local name = type(info) == "table" and type(info.name) == "string" and info.name or ("item #" .. tostring(o.item))
  local names = rosterNames()
  local canRoll, notice = false, ""
  if o.kind == "R" then
    canRoll = true
  elseif o.kind == "S" then
    if mine(o.reservers) then
      canRoll = true
    else
      local out = {}
      for i, k in ipairs(o.reservers) do out[i] = esc(names[k] or k) end
      notice = "Reserved: " .. table.concat(out, ", ")
    end
  elseif o.kind == "C" then
    notice = COUNCIL_LINE
  else
    notice = NAMED_LINE
  end
  f.item:SetText(esc(name))
  f.by:SetText("Run by " .. esc(names[o.by] or o.by))
  f.notice:SetText(notice)
  f.told:SetText(cur.told or "")
  local done = clicked[cur.key]
  for _, b in ipairs(f.rolls) do
    if canRoll and offers(o.ranges, b.hi) then b:Show() else b:Hide() end
    if done then b:Disable() else b:Enable() end
  end
  if canRoll then
    f.pass:Show()
    f.close:Hide()
  else
    f.pass:Hide()
    f.close:Show()
  end
  if canRoll and done then f.chat:Show() else f.chat:Hide() end
end

-- The saved place (finite numbers only), else the default; read on each open from hidden.
local function place()
  local s = ns.DB().session
  local p = type(s) == "table" and s.popup
  f:ClearAllPoints()
  if type(p) == "table" and finite(p.x) and finite(p.y) then
    f:SetPoint("TOPLEFT", nil, "BOTTOMLEFT", p.x, p.y)
  else
    f:SetPoint("TOP", 0, -160)
  end
end

local function hide()
  current, redrawHeld = nil, false
  f:Hide()
end

local function open(msg, key)
  local cur = { msg = msg, key = key }
  draw(cur)
  current = cur
  if not f:IsShown() then place() end
  f:Show()
  M.After(math.max(msg.closes - now(), 0), function()
    if current == cur then hide() end
  end)
end

-- Redraws the shown popup, or holds the redraw until the fight ends.
local function redrawSoon()
  if fighting() then redrawHeld = true else draw(current) end
end

-- The combat gate for the module's own changes: an O to show.
local function want(msg, key)
  if fighting() then
    held = { msg = msg, key = key }
    return
  end
  open(msg, key)
end

local function afterFight()
  if fighting() then return end
  local h = held
  held = nil
  if h then
    redrawHeld = false
    if h.msg.closes > now() then open(h.msg, h.key) else count("O", "late") end
  elseif redrawHeld then
    redrawHeld = false
    if current then draw(current) end
  end
end

local function itemLoaded(id)
  if current and current.msg.item == id then redrawSoon() end
end

-- The one roll seam, called only from a range button's click.
local function rollFor(hi)
  local ok = M.Compat.Try("RandomRoll", 1, hi)
  if ok ~= true then ns.OpenChat("/roll " .. hi) end
end

local function onRoll(self)
  local cur = current
  if not cur or clicked[cur.key] then return end
  local hi = self.hi
  clicked[cur.key] = hi
  rollFor(hi)
  draw(cur)
end

local function onChat()
  local hi = current and clicked[current.key]
  if hi then ns.OpenChat("/roll " .. hi) end
end

local function onPass()
  if current then passed[current.key] = true end
  hide()
end

local function onDragStop(self)
  self:StopMovingOrSizing()
  local x, y = self:GetLeft(), self:GetTop()
  if finite(x) and finite(y) then
    local db = ns.DB()
    if type(db.session) ~= "table" then db.session = {} end
    db.session.popup = { x = x, y = y }
  end
end

local function build()
  f = CreateFrame("Frame", nil, UIParent)
  f:Hide()
  f:SetSize(WIDTH, HEIGHT)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", safe(function(self) self:StartMoving() end))
  f:SetScript("OnDragStop", safe(onDragStop))
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], C.panel[4])
  f.item = ns.Label(f, T.normal)
  f.item:SetPoint("TOPLEFT", PAD, -PAD)
  f.item:SetWidth(WIDTH - 2 * PAD)
  f.by = ns.Label(f, T.highlightSmall)
  f.by:SetPoint("TOPLEFT", PAD, -PAD - 20)
  f.by:SetWidth(WIDTH - 2 * PAD)
  f.notice = ns.Label(f, T.highlightSmall)
  f.notice:SetPoint("TOPLEFT", PAD, -PAD - 38)
  f.notice:SetWidth(WIDTH - 2 * PAD)
  f.told = ns.Label(f, T.highlightSmall)
  f.told:SetPoint("BOTTOMLEFT", PAD, PAD + 30)
  f.told:SetWidth(WIDTH - 2 * PAD)
  f.rolls = {}
  for i, r in ipairs(RANGES) do
    local b = K.Button(f, r[2], BW)
    b.hi = r[1]
    b:SetPoint("TOPLEFT", PAD + (i - 1) * (BW + 6), -PAD - 60)
    b:SetScript("OnClick", safe(onRoll))
    f.rolls[i] = b
  end
  f.chat = K.Button(f, "In chat", BW)
  f.chat:SetPoint("BOTTOMLEFT", PAD, PAD)
  f.chat:SetScript("OnClick", safe(onChat))
  f.pass = K.Button(f, "Pass", BW)
  f.pass:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  f.pass:SetScript("OnClick", safe(onPass))
  f.close = K.Button(f, "Close", BW)
  f.close:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  f.close:SetScript("OnClick", safe(onPass)) -- Close marks the item passed, as Pass does
end

function ns.RollPopupFrame() return f end

-- ---------- the O reader ----------

local lastO, lastOrder = {}, {} -- [by] = { session, n, closes }; the senders in the order first kept

local function older(msg, l)
  if msg.session ~= l.session then return msg.session < l.session end
  if msg.n ~= l.n then return msg.n < l.n end
  return msg.closes <= l.closes
end

local function keepO(msg)
  if not lastO[msg.by] then
    lastOrder[#lastOrder + 1] = msg.by
    if #lastOrder > SENDERS then lastO[table.remove(lastOrder, 1)] = nil end
  end
  lastO[msg.by] = { session = msg.session, n = msg.n, closes = msg.closes }
end

local function onOpen(msg, from)
  if type(msg) ~= "table" then return end
  local no = refused(from)
  if no then return count("O", no) end
  local t = now()
  if msg.closes <= t then return count("O", "late") end
  if msg.closes > t + AHEAD then return count("O", "far") end
  local l = lastO[msg.by]
  if l and older(msg, l) then return count("O", "old") end
  local key = keyOf(msg)
  if passed[key] then return count("O", "passed") end
  keepO(msg)
  want(msg, key)
end

-- ---------- the W reader ----------

local RATE, WINDOW, SUBJECTS = 30, 60, 150 -- acted on per sender per WINDOW s; new subjects per sender per login
local TOTAL = 200 -- new told subjects per login across all senders (the store holds 500 records in all)
local wNew = 0 -- new told subjects acted on this login
local LABELS = { ms = "main spec", os = "off spec", de = "disenchant", sr = "soft reserve", council = "council" }
local wSenders, wOrder = {}, {} -- [from] = { times = { t, ... }, subjects = { [subject] = version }, n }; first-kept order

local function wState(from)
  local s = wSenders[from]
  if s then return s end
  s = { times = {}, subjects = {}, n = 0 }
  wSenders[from] = s
  wOrder[#wOrder + 1] = from
  if #wOrder > SENDERS then wSenders[table.remove(wOrder, 1)] = nil end
  return s
end

-- The times still inside the window (older ones dropped).
local function recent(s, t)
  local keep = {}
  for _, x in ipairs(s.times) do
    if x > t - WINDOW then keep[#keep + 1] = x end
  end
  s.times = keep
  return #keep
end

-- "<who> got <item> (<label> <roll>)" from escaped parts; the bank and an unknown how have their own forms.
local function gotLine(msg)
  local info = ns.Items.Info(msg.item)
  local item = esc(type(info) == "table" and type(info.name) == "string" and info.name or ("item #" .. tostring(msg.item)))
  if msg.how == "bank" then return "the guild bank got " .. item end
  local line = esc(msg.who) .. " got " .. item
  local label = LABELS[msg.how]
  if not label then return line end
  if type(msg.roll) == "number" then label = label .. " " .. tostring(msg.roll) end
  return line .. " (" .. label .. ")"
end

local function showTold(msg, line)
  local cur = current
  if not cur or cur.msg.by ~= msg.by or cur.msg.session ~= msg.session or cur.msg.n ~= msg.n then return end
  cur.told = line
  redrawSoon()
end

local function onWon(msg, from)
  if type(msg) ~= "table" then return end
  local no = refused(from)
  if no then return count("W", no) end
  if msg.by == ns.MyKey() then return count("W", "own") end
  local t = now()
  local s = wSenders[from]
  if s and recent(s, t) >= RATE then return count("W", "rate") end
  local subject, version = ns.SessionWire.Subject(msg)
  if type(subject) ~= "string" or type(version) ~= "number" then return count("W", "subject") end
  local last = s and s.subjects[subject]
  if last and version <= last then return count("W", "old") end
  if not last and (wNew >= TOTAL or (s and s.n >= SUBJECTS)) then return count("W", "cap") end
  -- handed to the store: the time and the subject are kept only now
  s = wState(from)
  s.times[#s.times + 1] = t
  if not last then
    s.n = s.n + 1
    wNew = wNew + 1
  end
  s.subjects[subject] = version
  -- the record, field by field: src, by, id and from are never read from the message. from is who gave the drop out:
  -- the sender's raid roster name, else its key, so the store folds my sighting of the loot master's pick-up in
  local rec = { item = msg.item, who = msg.who, how = msg.how, roll = msg.roll, at = msg.at, ref = subject,
    src = "told", from = rosterNames()[from] or from }
  if msg.suffix ~= nil then rec.suffix = msg.suffix end
  if type(msg.why) == "string" and msg.why ~= "" then rec.why = msg.why end
  local id, why = ns.Loot.Record(rec)
  if id == nil then return count("W", "refused " .. tostring(why)) end
  if why == "kept" then count("W", "kept") end
  local line = gotLine(msg)
  ns.Say("Raids: " .. line)
  showTold(msg, line)
end

-- ---------- wiring at load ----------

build()
ns.AfterCombat(afterFight)
if type(ns.Items) == "table" and type(ns.Items.OnLoad) == "function" then ns.Items.OnLoad(itemLoaded) end
local entries = type(ns.RaidsR) == "table" and ns.RaidsR or {}
if type(entries.O) == "table" then entries.O.handle = onOpen end
if type(entries.W) == "table" then entries.W.handle = onWon end
