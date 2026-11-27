local _, ns = ...
if not ns.M then return end
-- LootWindow.lua: the loot window, where the loot runner lists items, runs one roll at a time and assigns the winner.
-- Exports:
--   ns.Cards.loot = { build(card), draw(card, view, rows, t, L) }  the "loot" owner card (Page.lua's ns.Cards contract)
--   ns.OnLootWindow(event)        LOOT_OPENED merges the boss loot window into the list; anything else does nothing
--   ns.DrawLootBar(bar, ev) -> h  the "Loot to roll" bar button for the Loot tab; (bar, nil) hides it and answers 0
--   ns.WantLootTab(ev) -> bool    true when this player runs the loot and ev's raid is chosen or already holds a list
--   ns.RollSlash()                /gsraids roll: the page, then the loot card
--   ns.SetSessionOption(key, v) -> true | nil  writes rollTime or send in GuildSyncRaidsDB.session
-- Only the raid leader, an assistant or the party leader runs the loot (ns.Leads("player")); anyone may see the list.
-- The item list: { items = { { n, item, suffix, count, from } }, done = {}, next } in ns.Night(<shown raid>).session
-- while a raid is shown, else in a session-only table; demo always uses its own session-only table. n is the list's
-- next number (1-999), never reused. Items come from the item box (a typed or pasted link or id, or a shift-click
-- through ns.Items.Box), "From raid chat" (the player's own raid lines of the last 2 minutes) and the boss loot window
-- (ns.OnLootWindow on LOOT_OPENED, merged by item and suffix, never doubled on a re-open).
-- Kinds: each row is a Roll or a Council item (ns.LootPolicy over ns.Items.Info, the raid size and the flags); the
-- size is the linked lineup's (ns.Lineups), else GetInstanceInfo's, else the group's. A hand choice is saved on the
-- row as kind ("roll" | "council") and case ("time" | "nobody": why a council item went to a roll, recorded through
-- RR.CouncilWhy). The raid leader's council flags, set before the first pull (ns.PullRules, ns.PullList), are saved
-- as ns.Night(<shown raid>).flagged = { [itemId] = true }. A Council row opens the council form (winner, reason,
-- others considered), which records how "council" through RR.CouncilRecord; Change on a council award uses the same form.
-- Every library (Items, Group, Nights, Chat, RollRules, LootPolicy, Store, PullRules) is read at call time.
-- Every handler runs under M.Safe. Text from another player or typed by this one goes through ns.Escape before SetText. Nothing is sent on any comm domain.
-- Layout: state and inputs, the list, the roll, the bar, the card (build, draw), the slash and the settings. The roll
-- section (top of the card) sits in V.roll.

local M = ns.M
local K = M.Kit
local Plain = GuildSync.Compat.Plain

local LOOT_BUTTON = "Loot to roll"
local LEAD_WHY = "Only the raid leader, an assistant or the party leader runs the loot."
local NO_BOX = "No edit box on this client."
local HEARD_SECONDS, HEARD_MAX = 120, 20
local MAX_N, MAX_COUNT, MAX_ID = 999, 9, 2147483647
local FULL = "The list is full (" .. MAX_N .. " items this night)."
local ROW_H = 24

-- A text role of the kit, read at call time (the kit makes its font object on the first read).
local function role(name) return K.Tokens.text[name] end

local function now()
  local t = M.Compat.call("GetServerTime")
  t = Plain(t)
  return type(t) == "number" and t or 0
end

local function esc(s) return ns.Escape(tostring(s or "")) end

-- true only when ns.Leads("player") answers true; a missing function counts as not allowed.
local function leads()
  if type(ns.Leads) ~= "function" then return false end
  local a = ns.Leads("player")
  return Plain(a) == true
end

local function redraw()
  local u = ns.UI and ns.UI()
  if u and ns.PageState and ns.PageState.card == "loot" then ns.RefreshPage(u.page) end
end

-- ---------- the item list ----------

local loose = { items = {}, done = {}, next = 0 } -- no raid shown
local demoList = { items = {}, done = {}, next = 0 }

local function whole(v, lo, hi) return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi end

-- Saved rows are read back as written by this file only; anything else (a hand edit, an old shape) is dropped.
local function goodRow(r)
  return type(r) == "table" and whole(r.n, 1, MAX_N) and whole(r.item, 1, MAX_ID) and whole(r.count, 1, MAX_COUNT)
    and (r.suffix == nil or type(r.suffix) == "number")
end
local function goodDone(d)
  return type(d) == "table" and type(d.rec) == "table" and whole(d.rec.item, 1, MAX_ID) and type(d.rec.how) == "string"
end
local function keep(list, good)
  local out = {}
  for _, x in ipairs(list) do if good(x) then out[#out + 1] = x end end
  return out
end

local function fixList(s)
  s.items = keep(type(s.items) == "table" and s.items or {}, goodRow)
  s.done = keep(type(s.done) == "table" and s.done or {}, goodDone)
  if not whole(s.next, 0, MAX_N) then s.next = 0 end
  for _, r in ipairs(s.items) do if r.n > s.next then s.next = r.n end end
  return s
end

-- -> the shown raid's event from ns.View().events, or nil (no raid chosen, or demo).
local function shownEvent()
  if M.Demo() == true then return nil end
  local chosen = ns.PageState and ns.PageState.chosen
  local ev
  if chosen ~= nil and type(ns.View) == "function" then
    for _, x in ipairs(ns.View().events) do if x.key == chosen then ev = x end end
  end
  return ev
end

-- -> the item list of the shown raid, else the session-only table.
local function currentList()
  if M.Demo() == true then return demoList end
  local ev = shownEvent()
  local key = ev and ev.id
  local night = key ~= nil and type(ns.Night) == "function" and ns.Night(key) or nil
  if type(night) ~= "table" then return fixList(loose) end
  if type(night.session) ~= "table" then night.session = {} end
  return fixList(night.session)
end

local function findRow(list, id, suffix)
  for i, r in ipairs(list.items) do
    if r.item == id and r.suffix == suffix then return r, i end
  end
  return nil
end

-- Adds one of id (suffix) to list -> row | nil, why. The same item again raises its count.
local function addItem(list, id, suffix, from)
  local r = findRow(list, id, suffix)
  if r then
    if r.count >= MAX_COUNT then return nil, "At most " .. MAX_COUNT .. " of one item." end
    r.count = r.count + 1
    return r
  end
  if list.next >= MAX_N then return nil, FULL end
  list.next = list.next + 1
  r = { n = list.next, item = id, suffix = suffix, count = 1, from = from }
  list.items[#list.items + 1] = r
  return r
end

local function removeRow(list, n)
  for i, r in ipairs(list.items) do
    if r.n == n then table.remove(list.items, i) return true end
  end
  return nil
end

local function itemName(id)
  local info = ns.Items and ns.Items.Info(id)
  return type(info) == "table" and info.name or ("item #" .. tostring(id))
end

-- The item shown on a row: its name (escaped), and the count past 1.
local function itemText(r)
  local s = esc(itemName(r.item))
  if r.count > 1 then s = s .. " x" .. r.count end
  return s
end

-- ---------- kinds (LOOT-POLICY.md through ns.LootPolicy) ----------

local SIZES = { [10] = true, [20] = true, [40] = true }

-- The raid's size: the linked roster's, else the game's instance answer, else the group's -> 10 | 20 | 40 | "party"
-- | nil (a raid of unknown size: the council rules apply).
local function raidSize(ev)
  if ev ~= nil and type(ns.Lineups) == "function" then
    local ls = ns.Lineups()
    for _, l in ipairs(type(ls) == "table" and ls or {}) do
      if type(l) == "table" and tostring(l.event) == tostring(ev.id) and SIZES[l.size] then return l.size end
    end
  end
  -- the 2nd value is the instance type, the 5th the most players; a compat call can answer nothing
  local _, kind, _, _, most = M.Compat.call("GetInstanceInfo")
  if kind == "raid" and most ~= nil and SIZES[most] then return most end
  if kind == "party" then return "party" end
  local g = type(ns.GroupKind) == "function" and ns.GroupKind() or nil
  if Plain(g) == "party" then return "party" end
  return nil
end

-- The raid leader's council flags for ev: { [itemId] = true }, read from ns.Night(ev.id).flagged; bad entries are
-- dropped. ns.Night is called only for an event found in ns.View().events (shownEvent).
local function flagsOf(ev)
  local out = {}
  if ev == nil or type(ns.Night) ~= "function" then return out end
  local night = ns.Night(ev.id)
  local f = type(night) == "table" and night.flagged or nil
  if type(f) == "table" then
    for k, v in pairs(f) do if whole(k, 1, MAX_ID) and v == true then out[k] = true end end
  end
  return out
end

-- Flags close at the raid's first pull: -> false, or true, why. A missing pull record or a throw counts as done.
local PULLED, NO_PULLS = "the first pull is done", "the pull record is missing"
local function firstPullDone(ev)
  local PR = ns.PullRules
  if type(PR) ~= "table" or type(PR.ForRaid) ~= "function" or type(ns.PullList) ~= "function"
    or type(ns.View) ~= "function" then return true, NO_PULLS end
  local n
  if not M.Safe(function() n = #PR.ForRaid(ns.PullList(), ev, ns.View().events) end) or type(n) ~= "number" then
    return true, NO_PULLS
  end
  if n > 0 then return true, PULLED end
  return false
end

-- A row's kind -> "roll" | "council", reason | nil, hand. A hand choice saved on the row (r.kind) wins.
local function kindOf(r, size, flags)
  if r.kind == "roll" or r.kind == "council" then return r.kind, nil, true end
  local LP = ns.LootPolicy
  if type(LP) ~= "table" or type(LP.Kind) ~= "function" then return "roll", "loading" end
  local info = ns.Items and ns.Items.Info(r.item)
  return LP.Kind(info, size, flags[r.item] == true)
end

-- What the kinds are read against, now: -> the shown raid's size, its flags, its event (or nil).
local function policyNow()
  local ev = shownEvent()
  return raidSize(ev), flagsOf(ev), ev
end

-- A row's kind, read now for the list's own raid.
local function kindNow(r)
  local size, flags = policyNow()
  return kindOf(r, size, flags)
end

-- -> row n of list, or nil.
local function rowAt(list, n)
  for _, r in ipairs(list.items) do if r.n == n then return r end end
end

local CASES = { { "time", "Roll: no decision in two minutes" }, { "nobody", "Roll: no Raider wanted it" } }

local function kindText(kind, reason, hand, case)
  local word = kind == "council" and "Council" or "Roll"
  if hand then
    if kind == "council" then return "Council: by the loot master" end
    for _, c in ipairs(CASES) do if c[1] == case then return c[2] end end
    return word
  end
  local LP = ns.LootPolicy
  return type(LP) == "table" and type(LP.Text) == "function" and LP.Text(kind, reason) or word
end

-- ---------- inputs ----------

local V -- the card's pieces, set by build
local function say(text)
  if V and V.why then V.why:SetText(text or "") end
end

-- A typed or pasted value -> id, suffix | nil, why (why escaped).
local function parseInput(text)
  text = Plain(text)
  if type(text) ~= "string" then return nil, "Type or paste an item link or id." end
  local s = text:match("^%s*(.-)%s*$")
  if s == "" then return nil, "Type or paste an item link or id." end
  if s:find("|Hitem:", 1, true) then
    local id, suffix = ns.Items.Id(s)
    if id then return id, suffix end
    return nil, "Not an item link: " .. esc(s)
  end
  local digits = s:match("^%d+$")
  local id = digits and tonumber(digits)
  if id and id >= 1 and id <= MAX_ID then return id, nil end
  if digits then return nil, "Not an item id: " .. esc(s) end
  return nil, "Not an item link or id: " .. esc(s)
end

local function submitBox(box)
  local text = box:GetText()
  box:SetText("")
  local id, suffix = parseInput(text)
  if not id then
    say(suffix)
  else
    local r, why = addItem(currentList(), id, suffix, "typed")
    say(r and "" or why)
  end
  redraw()
end

-- The player's own item links in raid chat: { item, suffix, at }, the last HEARD_SECONDS, at most HEARD_MAX.
local heard = {}

local function pruneHeard(t)
  local keep = {}
  for _, h in ipairs(heard) do
    if t - h.at <= HEARD_SECONDS then keep[#keep + 1] = h end
  end
  while #keep > HEARD_MAX do table.remove(keep, 1) end
  heard = keep
end

local function onRaidLine(text, name)
  if type(text) ~= "string" or type(name) ~= "string" then return end
  local me = ns.MyKey()
  if me == nil or ns.Key(name) ~= me then return end
  local t = now()
  for link in text:gmatch("|Hitem:[^|]*") do
    local id, suffix = ns.Items.Id(link)
    if id then heard[#heard + 1] = { item = id, suffix = suffix, at = t } end
  end
  pruneHeard(t)
end
if type(ns.OnChat) == "function" then ns.OnChat("raid", onRaidLine) end

local function fromChat()
  pruneHeard(now())
  if #heard == 0 then
    say("No item links from you in raid chat in the last 2 minutes.")
  else
    local list, why = currentList(), nil
    for _, h in ipairs(heard) do
      local r, w = addItem(list, h.item, h.suffix, "chat")
      if not r then why = w end
    end
    heard = {}
    say(why or "")
  end
  redraw()
end

-- Routed by Raids.lua for LOOT_OPENED and LOOT_CLOSED. The loot window's slots merge into the list by item and suffix
-- at the window's count, so a re-open never doubles a row. LOOT_CLOSED does nothing.
function ns.OnLootWindow(event)
  if event ~= "LOOT_OPENED" or not leads() then return end
  local kind = type(ns.GroupKind) == "function" and ns.GroupKind() or nil
  kind = Plain(kind)
  if kind ~= "raid" and kind ~= "party" then return end
  local n = M.Compat.call("GetNumLootItems")
  n = Plain(n)
  if type(n) ~= "number" or n < 1 then return end
  local seen, order = {}, {}
  for i = 1, math.min(n, 50) do
    local link = M.Compat.call("GetLootSlotLink", i)
    local id, suffix = ns.Items.Id(link)
    -- only uncommon or better: a quality known and below 2 (poor, common) is skipped; a loading item is kept
    local info = id and ns.Items.Info(id)
    if id and type(info) == "table" and type(info.quality) == "number" and info.quality < 2 then id = nil end
    if id then
      local k = tostring(id) .. ":" .. tostring(suffix)
      if not seen[k] then
        seen[k] = { item = id, suffix = suffix, count = 0 }
        order[#order + 1] = seen[k]
      end
      seen[k].count = seen[k].count + 1
    end
  end
  if #order == 0 then return end
  local list = currentList()
  for _, s in ipairs(order) do
    local r = findRow(list, s.item, s.suffix)
    if r then
      r.count = math.min(MAX_COUNT, math.max(r.count, s.count))
    elseif list.next < MAX_N then
      list.next = list.next + 1
      list.items[#list.items + 1] = { n = list.next, item = s.item, suffix = s.suffix,
        count = math.min(MAX_COUNT, s.count), from = "loot" }
    else
      say(FULL)
    end
  end
  redraw()
end

-- ---------- the roll ----------

-- The open roll, memory only (one at a time): { list, row, n, rr, hiddenBase, chat, over }. list is the item list it
-- was started from, so Assign and Close write there whatever raid is shown. A row marked rolling with no open roll
-- (after a /reload) says the roll was lost.
local RR = ns.RollRules
local R
local MARK = { "main spec", "main spec, fill-in", "off spec", "disenchant" }
local HOW_TEXT = { ms = "Main spec", os = "Off spec", de = "Disenchant", bank = "Guild bank" }
local HOW_HI = { ms = 100, os = 99, de = 98 }
local LOST = "The open roll was lost in a reload."

-- The game's roll line format, read in the one pinned form (a translated client has its own).
local function rollFormat()
  return type(RANDOM_ROLL_RESULT) == "string" and RANDOM_ROLL_RESULT or RR.ENGLISH
end

local function demo() return M.Demo() == true end

-- The one chat path: ns.SayLine on the channel for this group, from a click only, never in demo.
local function sayLine(text)
  if demo() or type(ns.SayLine) ~= "function" then return end
  local kind = type(ns.GroupKind) == "function" and ns.GroupKind() or nil
  local channel = RR.Channel(Plain(kind), leads())
  if channel then ns.SayLine(channel, text) end
end

local function hiddenNow()
  local counts = type(ns.ChatCounts) == "function" and ns.ChatCounts() or nil
  local row = type(counts) == "table" and counts.system or nil
  return type(row) == "table" and row.hidden or 0
end

-- The unread count: hidden system lines since Start roll, taken while the roll may still count them.
local function takeUnread(t)
  if R then RR.Unread(R.rr, hiddenNow() - R.hiddenBase, t) end
end

-- A 1 s tick while a roll runs: it redraws, and takes the unread count once at the closing moment. It never assigns,
-- says or records.
local ticking, tick
local function startTick()
  if ticking then return end
  ticking = true
  M.After(1, function() M.Safe(tick) end)
end
function tick()
  ticking = false
  if not R or R.rr.closed then return end
  local t = now()
  if not R.over and t >= R.rr.closesAt then
    takeUnread(R.rr.closesAt)
    R.over = true
  end
  redraw()
  if not R.over then startTick() end
end

local function startRoll(list, n)
  if not leads() or (R and RR.IsOpen(R.rr, now())) then return end
  if R then
    R.row.rolling = nil
    say(esc(itemName(R.row.item)) .. "'s roll was dropped.")
    R = nil
  end
  local row
  for _, r in ipairs(list.items) do if r.n == n then row = r end end
  if not row then return end
  local t = now()
  if type(list.session) ~= "number" then list.session = t end
  local group = {}
  local roster = type(ns.RaidRoster) == "function" and ns.RaidRoster() or nil
  for _, m in ipairs(type(roster) == "table" and roster or {}) do
    if type(m) == "table" and type(m.key) == "string" and type(m.name) == "string" then group[m.key] = m.name end
  end
  local db = ns.DB()
  local rollTime = type(db.session) == "table" and db.session.rollTime or nil
  local rr = RR.Open(t, { item = row.item, suffix = row.suffix, count = row.count, rollTime = rollTime,
    group = group, fill = {} })
  R = { list = list, row = row, n = row.n, rr = rr, hiddenBase = hiddenNow(), chat = "[" .. itemName(row.item) .. "]" }
  row.rolling = true
  sayLine(RR.OpenLine(R.chat, rr.rollTime))
  startTick()
  redraw()
end

-- A roll line from the system chat goes into the open roll (counted or not, with its why).
local function onSystem(text)
  if not R then return end
  local p = RR.ParseRoll(text, rollFormat())
  if not p then return end
  local key = ns.Key(p.name) or string.lower(p.name)
  -- a line not stored ("full", "repeat", "roll") is not listed: RR.Add counts the dropped ones in st.dropped, and the
  -- 1 s tick redraws that count
  local e = RR.Add(R.rr, { name = p.name, key = key, roll = p.roll, lo = p.lo, hi = p.hi }, now())
  if e then redraw() end
end
if type(ns.OnChat) == "function" then ns.OnChat("system", onSystem) end

local function more()
  if not R or R.rr.closed or not leads() then return end
  RR.More(R.rr, now())
  R.over = false
  startTick()
  redraw()
end

local function closeRoll()
  if not R or R.rr.closed or not leads() then return end
  local t = now()
  takeUnread(t)
  RR.Close(R.rr, t)
  redraw()
end

local function rollAgain()
  if not R or not leads() then return end
  local res = RR.Result(R.rr)
  if res.kind ~= "tie" then return end
  local db = ns.DB()
  local rollTime = type(db.session) == "table" and db.session.rollTime or nil
  local t = now()
  local good, why = RR.Again(R.rr, t, rollTime)
  if not good then say(esc(why)) redraw() return end
  -- the roll-off counts its own unread lines from 0
  R.hiddenBase = hiddenNow()
  RR.Unread(R.rr, 0, t)
  local names = {}
  for _, e in ipairs(res.tied) do names[#names + 1] = e.name end
  R.over = false
  sayLine(RR.AgainLine(R.chat, names))
  startTick()
  redraw()
end

-- Records each pick in the loot log, adds the done rows to the roll's own list, says one line. The row stays with the
-- copies nobody won (its places go on from the ones given). A Record that throws counts as not recorded, so the click
-- always finishes and no place is given twice.
local function award(picks)
  local S = R
  if not S or #picks == 0 then return end
  local rr, list, row = S.rr, S.list, S.row
  local at = now()
  local base = whole(row.placed, 0, MAX_COUNT) and row.placed or 0
  local recs, refused, seen = {}, {}, {}
  local function refuse(why)
    if not seen[why] then seen[why] = true refused[#refused + 1] = why end
  end
  for i, pick in ipairs(picks) do
    local place = base + i
    local rec = RR.Record(rr, pick, at, list.session, S.n, place)
    -- a council item rolled for (the row's case) records the council's reason with the roll's
    if rec and row.case ~= nil then rec.why = RR.CouncilWhy(row.case, rec.why) end
    local id, why
    if rec and not demo() then
      local loot = ns.Loot
      if type(loot) == "table" and type(loot.Record) == "function" then
        if not M.Safe(function() id, why = loot.Record(rec) end) then id, why = nil, "the loot log failed" end
        if id == nil then refuse(tostring(why or "refused")) end
      else
        refuse("the loot log is missing")
      end
    end
    if rec then
      list.done[#list.done + 1] = { n = S.n, place = place, rec = rec, id = id, recorded = demo() or id ~= nil,
        case = row.case }
      recs[#recs + 1] = rec
    end
  end
  local left = row.count - #picks -- the row's count now (a copy added while rolling stays on it)
  if left > 0 then
    row.count, row.placed, row.rolling = left, base + #picks, nil
  else
    removeRow(list, S.n)
  end
  R = nil
  say(#refused > 0 and ("Not recorded: " .. esc(table.concat(refused, "; "))) or "")
  sayLine(RR.WinLine(S.chat, recs))
  redraw()
end

-- Asks "Give <item> to <to>?" (to already escaped), then awards the picks, but only while the roll is the one asked
-- about: the same open roll, round and closing time, not running, and the player still leads.
local CHANGED = "That roll changed. Nothing was assigned."
local function confirmAward(picks, to)
  local S, round, closesAt = R, R.rr.round, R.rr.closesAt
  K.Confirm("GSRaidsLootAssign", "Give " .. esc(R.chat) .. " to " .. to .. "?", "Assign", function()
    M.Safe(function()
      if R ~= S or R.rr.round ~= round or R.rr.closesAt ~= closesAt or RR.IsOpen(R.rr, now()) or not leads() then
        say(CHANGED)
        redraw()
        return
      end
      award(picks)
    end)
  end)
end

local function assign()
  if not R or RR.IsOpen(R.rr, now()) or not leads() then return end
  local res = RR.Result(R.rr)
  if res.kind ~= "win" and res.kind ~= "de" then return end
  local picks, names = {}, {}
  for _, e in ipairs(res.winners) do
    picks[#picks + 1] = { entry = e }
    names[#names + 1] = esc(e.name)
  end
  if #picks == 0 then return end
  confirmAward(picks, table.concat(names, ", "))
end

local function toBank()
  if not R or RR.IsOpen(R.rr, now()) or not leads() then return end
  local picks = {}
  for i = 1, R.rr.count do picks[i] = { how = "bank" } end
  confirmAward(picks, "the guild bank")
end

-- ---------- the bar ----------

local function openCard()
  M.OpenPage()
  ns.ShowCard("loot")
end

local bars = setmetatable({}, { __mode = "k" })

-- One "Loot to roll" button per bar, made once and reused -> the height used; (bar, nil) hides it -> 0.
function ns.DrawLootBar(bar, ev)
  if type(bar) ~= "table" then return 0 end
  local B = bars[bar]
  if ev == nil then
    if B then
      B.button:Hide()
      B.why:Hide()
      B.rolling:Hide()
    end
    return 0
  end
  if not B then
    B = { button = K.Button(bar, LOOT_BUTTON, 120), why = ns.Label(bar, role("disable")) }
    B.button:SetPoint("TOPLEFT", 0, 0)
    B.button:SetScript("OnClick", function() M.Safe(openCard) end)
    B.why:SetPoint("LEFT", B.button, "RIGHT", 8, 0)
    B.why:SetText(LEAD_WHY)
    B.rolling = ns.Label(bar, role("highlightSmall"))
    B.rolling:SetPoint("TOPLEFT", B.button, "BOTTOMLEFT", 2, -4)
    bars[bar] = B
  end
  local lead = leads()
  B.button:SetEnabled(lead)
  B.button:Show()
  B.why:SetShown(not lead)
  B.rolling:SetText(R and ("Rolling: " .. esc(itemName(R.rr.item))) or "")
  B.rolling:SetShown(R ~= nil)
  return R and ROW_H + 18 or ROW_H
end

-- ---------- the card ----------

-- A how button: its text is the form's how; a click opens a Kit.Menu of the hows (bank only in the Change form).
local function howButton(parent, form, withBank)
  local b = K.Button(parent, HOW_TEXT.ms, 100)
  b:SetScript("OnClick", function(self)
    M.Safe(function()
      K.Menu(self, function(_, root)
        for _, how in ipairs(withBank and { "ms", "os", "de", "bank" } or { "ms", "os", "de" }) do
          root:CreateButton(HOW_TEXT[how], function()
            M.Safe(function()
              form.how = how
              self:SetText(HOW_TEXT[how])
            end)
          end)
        end
      end)
    end)
  end)
  return b
end

-- Opens the council form for row n of list (defined with the form below).
local openCouncil

-- A row's main button: read the row's kind at the click (the button is bound once and rows are reused).
local function rowButtonClick(self)
  local list = currentList()
  local r = rowAt(list, self.n)
  if not r then return end
  if kindNow(r) == "council" then openCouncil(list, r.n) else startRoll(list, r.n) end
end

-- The two cases where a council item goes to a roll after all (RR.CouncilWhy).
local FLAG, UNFLAG = "Flag for the council", "Remove the council flag"

-- Writes (or clears) the council flag for item id in ev's night, unless the first pull is done.
local function setFlag(ev, id, on)
  local done, why = firstPullDone(ev)
  if done then say(why) return end
  local night = ns.Night(ev.id)
  if type(night) ~= "table" then return end
  local f = flagsOf(ev)
  f[id] = on or nil
  night.flagged = f
end

local function itemRowMenu(row)
  local list, n = currentList(), row.n
  local function rolling() return R and R.list == list and R.n == n end
  K.Menu(row, function(_, root)
    local function entry(text, fn)
      root:CreateButton(text, function()
        M.Safe(function()
          local r = rowAt(list, n)
          if not leads() then
            say(LEAD_WHY)
          elseif rolling() then say("That item is being rolled for.") elseif r then fn(r) end
          redraw()
        end)
      end)
    end
    entry("Remove", function() removeRow(list, n) end)
    local r = rowAt(list, n)
    if not r or rolling() then return end
    local size, flags, ev = policyNow()
    if kindOf(r, size, flags) == "council" then
      for _, c in ipairs(CASES) do entry(c[2], function(x) x.kind, x.case = "roll", c[1] end) end
    else
      entry("Make it Council", function(x) x.kind, x.case = "council", nil end)
    end
    -- the flag: the raid leader's, for a raid shown (never demo or the loose list) where the policy has a council
    if ev == nil or not leads() or size == 10 or size == "party" then return end
    local on = flags[r.item] == true
    local text = on and UNFLAG or FLAG
    local done, why = firstPullDone(ev)
    if done then
      root:CreateButton(text .. " (closed: " .. why .. ")", function()
        M.Safe(function() say(why) redraw() end)
      end)
    else
      entry(text, function(x) setFlag(ev, x.item, not on) end)
    end
  end)
end

-- The index of e in the open roll's entries.
local function indexOf(e)
  for i, x in ipairs(R.rr.entries) do if x == e then return i end end
end

local function lineMenu(line)
  local e = line.entry
  if not R or not e then return end
  K.Menu(line, function(_, root)
    local function item(text, fn)
      root:CreateButton(text, function()
        M.Safe(function()
          if not R or not indexOf(e) or not leads() then return end
          local good, why = fn()
          say(good and "" or esc(why))
          redraw()
        end)
      end)
    end
    item("Count this roll", function() return RR.Pick(R.rr, indexOf(e)) end)
    item("Set to off spec", function() return RR.Down(R.rr, indexOf(e)) end)
    local on = R.rr.fill[e.key] and true or false
    item(on and "Fill-in off" or "Fill-in on", function() return RR.SetFill(R.rr, e.key, not on) end)
  end)
end

-- A row Button (right-click: menu) with a label; extra is the right-hand button's text, or nil.
local function makeRow(parent, onMenu, extra, onExtra)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW_H)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, mouse)
    M.Safe(function() if mouse == "RightButton" then onMenu(self) end end)
  end)
  row.label = ns.Label(row, role("highlight"))
  row.label:SetPoint("LEFT", 4, 0)
  if extra then
    row.extra = K.Button(row, extra, 80)
    row.extra:SetPoint("RIGHT", -2, 0)
    row.extra:SetScript("OnClick", function() M.Safe(onExtra, row) end)
    row.label:SetPoint("RIGHT", row.extra, "LEFT", -6, 0)
  else
    row.label:SetPoint("RIGHT", -4, 0)
  end
  return row
end

-- The Type a roll form (name, number, how, Add) and the hand form (name, how, Save) for Assign by hand and Change.
local typing = { how = "ms" }
local form = { how = "ms" } -- mode "hand" | "change"; done = the done row being changed

local function rosterName(text)
  local key = ns.Key(text) or string.lower(text)
  local roster = type(ns.RaidRoster) == "function" and ns.RaidRoster() or nil
  for _, m in ipairs(type(roster) == "table" and roster or {}) do
    if type(m) == "table" and m.key == key and type(m.name) == "string" then return m.name, key end
  end
  return text, key
end

-- A player name typed by hand: 1-60 bytes with no |, ~, comma or control byte (it goes into the loot log and the
-- wire's who field) -> true | nil, why.
local NAME_MAX = 60
local BAD_NAME = "A name is 1 to " .. NAME_MAX .. " letters, with no |, ~, comma or control character."
local function goodName(s)
  if s == "" or #s > NAME_MAX or s:find("[|~,%c]") then return nil, BAD_NAME end
  return true
end

local function boxText(box)
  local s = box and box:GetText()
  s = Plain(s)
  return type(s) == "string" and s:match("^%s*(.-)%s*$") or ""
end

local function addTyped()
  if not R or not leads() then return end
  local name = boxText(V.tName)
  local n = tonumber(boxText(V.tNum))
  local okName, bad = goodName(name)
  if not okName then say(bad) redraw() return end
  local who, key = rosterName(name)
  local e, why = RR.Typed(R.rr, now(), { name = who, key = key, roll = n, hi = HOW_HI[typing.how] })
  if not e then say("Not added: " .. esc(why)) redraw() return end
  typing.open = false
  V.tName:SetText("")
  V.tNum:SetText("")
  say("")
  redraw()
end

-- The council form (Council on a row, Change on a council award): one at a time with the hand form.
-- council = { mode "assign" | "change", list, n (assign), done (change) }
local council = {}
local NEED_WHY = "A council item needs a one-line reason."
local BAD_TEXT = "The reason and others considered may not hold ~ or a control character."

local function showCouncil(mode, who, why, others)
  council.mode, council.from = mode, currentList()
  form.mode, form.done = nil, nil
  V.cWho:SetText(who or "")
  V.cWhy:SetText(why or "")
  V.cOthers:SetText(others or "")
  V.cSave:SetText(mode == "change" and "Save" or "Assign")
  say("")
  redraw()
end

function openCouncil(list, n)
  if not leads() or not V or not V.cWho then return end
  council.list, council.n, council.done = list, n, nil
  showCouncil("assign")
end

local function str(v) return type(v) == "string" and v or "" end

local function openForm(mode, done)
  if done and done.rec.how == "council" then
    if not V.cWho then return end
    council.list, council.n, council.done = nil, nil, done
    showCouncil("change", str(done.rec.who), str(done.rec.why), str(done.rec.others))
    return
  end
  council.mode = nil
  form.mode, form.done = mode, done
  form.how = done and done.rec.how or "ms"
  V.fHow:SetText(HOW_TEXT[form.how] or HOW_TEXT.ms)
  V.fName:SetText(done and type(done.rec.who) == "string" and done.rec.who or "")
  redraw()
end

-- Asks once, then sends fix for the done row d to the loot log and patches d.rec (false clears a field).
local function sendChange(d, fix)
  K.Confirm("GSRaidsLootChange", "Change this award to " .. esc(RR.DoneText(fix)) .. "?", "Save", function()
    M.Safe(function()
      if not leads() then return end
      local good, why = true, nil
      if not demo() then
        local loot = ns.Loot
        if type(loot) == "table" and type(loot.Change) == "function" then
          good, why = loot.Change(d.id, fix)
        else
          good, why = nil, "the loot log is missing"
        end
      end
      if good then
        for k, v in pairs(fix) do d.rec[k] = (v ~= false) and v or nil end
        d.note = nil
      else
        d.note = "Not changed: " .. tostring(why or "refused")
      end
      form.mode, form.done, council.mode = nil, nil, nil
      redraw()
    end)
  end)
end

-- Save: Assign by hand records a pick; Change sends the correction for the done row.
local function saveForm()
  if not leads() then return end
  local name = boxText(V.fName)
  local how = form.how
  if how ~= "bank" then
    local okName, bad = goodName(name)
    if not okName then say(bad) redraw() return end
  end
  local who = how ~= "bank" and (rosterName(name)) or nil
  if form.mode == "hand" then
    if not R then return end
    local picks = {}
    for i = 1, R.rr.count do
      picks[i] = how == "bank" and { how = "bank" } or { who = who, how = how, byHand = true }
    end
    form.mode = nil
    confirmAward(picks, who and esc(who) or "the guild bank")
    redraw()
    return
  end
  local d = form.done
  if not d then return end
  local fix = RR.Correction(how == "bank" and { how = "bank" } or { who = who, how = how })
  if d.case ~= nil then fix.why = RR.CouncilWhy(d.case, "by hand") end
  sendChange(d, fix)
end

-- The council form's boxes -> { who, why, others } | nil, why. Box caps are letters, so the bytes are checked here.
local function readCouncil()
  local name, why, others = boxText(V.cWho), boxText(V.cWhy), boxText(V.cOthers)
  local okName, bad = goodName(name)
  if not okName then return nil, bad end
  if why == "" then return nil, NEED_WHY end
  if #why > RR.WHYMAX then return nil, "A reason is at most " .. RR.WHYMAX .. " bytes (an accented letter counts as 2)." end
  if why:find("[~%c]") or others:find("[~%c]") then return nil, BAD_TEXT end
  if #others > RR.OTHERSMAX then
    return nil, "Others considered is at most " .. RR.OTHERSMAX .. " bytes (an accented letter counts as 2)."
  end
  return { who = (rosterName(name)), why = why, others = others ~= "" and others or nil }
end

local CHANGED_ROW = "That item changed. Nothing was assigned."

-- Gives one copy of row n to the council's pick: one confirm, re-checked in the OK, one loot log record, no chat line.
local function councilAssign()
  local list, n = council.list, council.n
  local row = list and rowAt(list, n)
  if not row then council.mode = nil redraw() return end
  local pick, bad = readCouncil()
  if not pick then say(bad) redraw() return end
  local function stale(r)
    return not leads() or not r or r.rolling or (R and R.list == list and R.n == n) or kindNow(r) ~= "council"
  end
  if stale(row) then say(leads() and CHANGED_ROW or LEAD_WHY) redraw() return end
  K.Confirm("GSRaidsLootCouncil", "Give " .. esc(itemName(row.item)) .. " to " .. esc(pick.who) .. " (council)?",
    "Assign", function()
    M.Safe(function()
      local r = rowAt(list, n)
      if stale(r) then say(CHANGED_ROW) redraw() return end
      local t = now()
      if type(list.session) ~= "number" then list.session = t end
      local place = (whole(r.placed, 0, MAX_COUNT) and r.placed or 0) + 1
      local rec, why = RR.CouncilRecord(r, pick, t, list.session, place)
      if not rec then say("Not recorded: " .. esc(why)) redraw() return end
      local id
      if not demo() then
        local loot = ns.Loot
        if type(loot) == "table" and type(loot.Record) == "function" then
          if not M.Safe(function() id, why = loot.Record(rec) end) then id, why = nil, "the loot log failed" end
        else
          why = "the loot log is missing"
        end
      end
      list.done[#list.done + 1] = { n = n, place = place, rec = rec, id = id, recorded = demo() or id ~= nil }
      if r.count > 1 then r.count, r.placed = r.count - 1, place else removeRow(list, n) end
      council.mode = nil
      say((demo() or id ~= nil) and "" or ("Not recorded: " .. esc(tostring(why or "refused"))))
      redraw()
    end)
  end)
end

-- Change on a council award: who, reason and others, sent after one confirm.
local function councilChange()
  local d = council.done
  if not d or not leads() then return end
  local pick, bad = readCouncil()
  if not pick then say(bad) redraw() return end
  sendChange(d, { who = pick.who, how = "council", why = pick.why, others = pick.others or false })
end

local function councilSave()
  if council.from ~= currentList() then council.mode = nil redraw() return end
  if council.mode == "change" then councilChange() else councilAssign() end
end

local function build(card)
  local body = card.body
  V = { rows = {}, lines = {}, doneRows = {}, kinds = {} } -- kinds: the kind label of each to-roll row
  V.lead = ns.Label(body, role("disable"))
  V.lead:SetText(LEAD_WHY)
  -- the roll section
  V.roll = CreateFrame("Frame", nil, body)
  V.roll:SetHeight(1)
  V.rHead = ns.Label(V.roll, role("highlight"))
  V.rUnread = ns.Label(V.roll, role("disable"))
  V.rOutcome = ns.Label(V.roll, role("normal"))
  V.rDropped = ns.Label(V.roll, role("disable"))
  local function btn(parent, text, w, fn)
    local b = K.Button(parent, text, w)
    b:SetScript("OnClick", function() M.Safe(fn) end)
    return b
  end
  V.bMore = btn(V.roll, "10 s more", 80, more)
  V.bClose = btn(V.roll, "Close", 70, closeRoll)
  V.bType = btn(V.roll, "Type a roll", 90, function() typing.open = not typing.open redraw() end)
  V.bAgain = btn(V.roll, "Roll again", 90, rollAgain)
  V.bAssign = btn(V.roll, "Assign", 80, assign)
  V.bBank = btn(V.roll, "Guild bank", 90, toBank)
  V.bHand = btn(V.roll, "Assign by hand", 110, function() if leads() then openForm("hand", nil) end end)
  V.tName = K.InputBox(V.roll, 120, 120)
  V.tNum = K.InputBox(V.roll, 40, 40)
  if V.tName then V.tName:SetMaxLetters(NAME_MAX) end
  if V.tNum then V.tNum:SetMaxLetters(3) end
  V.tHow = howButton(V.roll, typing, false)
  V.tAdd = btn(V.roll, "Add", 50, addTyped)
  V.lineScroll, V.lineChild = ns.ScrollArea(V.roll)
  -- the item box
  V.addLabel = ns.Label(body, role("small"))
  V.addLabel:SetText("Add an item: shift-click it, or paste its link or id, then Enter.")
  V.box = K.InputBox(body, 220, 220)
  if V.box then
    V.box:SetScript("OnEnterPressed", function(self) M.Safe(submitBox, self) end)
    V.box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    V.box:SetText("")
    if ns.Items and ns.Items.Box then ns.Items.Box(V.box) end
  else
    V.noBox = ns.Label(body, role("disable"))
    V.noBox:SetText(NO_BOX)
  end
  V.chat = btn(body, "From raid chat", 120, fromChat)
  V.why = ns.Label(body, role("highlightSmall"))
  -- the hand form (Assign by hand, Change)
  V.form = CreateFrame("Frame", nil, body)
  V.form:SetHeight(24)
  V.fName = K.InputBox(V.form, 140, 140)
  if V.fName then V.fName:SetMaxLetters(NAME_MAX) end
  V.fHow = howButton(V.form, form, true)
  V.fSave = btn(V.form, "Save", 60, saveForm)
  -- the council form (winner, reason, others considered; Assign, or Save on a Change)
  V.council = CreateFrame("Frame", nil, body)
  V.council:SetHeight(44)
  V.cHead = ns.Label(V.council, role("small"))
  V.cHead:SetPoint("TOPLEFT", 6, 0)
  V.cHead:SetText("Council: the winner, the reason (one line, needed) and the others considered.")
  V.cWho = K.InputBox(V.council, 120, 120)
  V.cWhy = K.InputBox(V.council, 200, 200)
  V.cOthers = K.InputBox(V.council, 140, 140)
  if V.cWho then V.cWho:SetMaxLetters(NAME_MAX) end
  if V.cWhy then V.cWhy:SetMaxLetters(RR.WHYMAX) end
  if V.cOthers then V.cOthers:SetMaxLetters(RR.OTHERSMAX) end
  V.cSave = btn(V.council, "Assign", 70, councilSave)
  -- the lists
  V.toRollHead = ns.Label(body, role("normal"))
  V.toRollHead:SetText("To roll")
  V.scroll, V.child = ns.ScrollArea(body)
  V.doneHead = ns.Label(body, role("normal"))
  V.doneHead:SetText("Done")
  V.doneScroll, V.doneChild = ns.ScrollArea(body)
  if ns.Items and ns.Items.OnLoad then ns.Items.OnLoad(function() redraw() end) end
end

-- Pins f's top left at x, y in its parent, dropping its other points.
local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", x, y)
end

-- Lays shown buttons out left to right from 0 on V.roll at y.
local function rowOf(list, y)
  local x = 0
  for _, b in ipairs(list) do
    if b then
      at(b, x, y)
      b:Show()
      x = x + (b:GetWidth() or 80) + 6
    end
  end
end

-- Puts row i (from 1, h high) of a list across child and shows it.
local function placeRow(row, child, i, h)
  at(row, 0, -(i - 1) * h)
  row:SetPoint("RIGHT", child, "RIGHT", 0, 0)
  row:Show()
end

-- Hides the pool's rows past n (clearing their entry) and sizes child to n rows of h.
local function endRows(pool, n, child, h)
  for i = n + 1, #pool do pool[i].entry = nil pool[i]:Hide() end
  child:SetHeight(math.max(10, n * h))
end

local function lineText(e)
  local s = esc(e.name) .. "  " .. e.roll .. " (" .. e.lo .. "-" .. e.hi .. ")  "
  if e.counted then
    s = s .. MARK[e.group]
  else
    s = s .. "not counted: " .. esc(e.why)
  end
  if e.byHand then s = s .. ", by hand" end
  return s
end

-- The roll section on V.roll -> its height (0 with no open roll).
local function drawRoll(t, w)
  for _, b in ipairs({ V.bMore, V.bClose, V.bType, V.bAgain, V.bAssign, V.bBank, V.bHand, V.tHow, V.tAdd }) do b:Hide() end
  if V.tName then V.tName:Hide() end
  if V.tNum then V.tNum:Hide() end
  if not R then V.roll:Hide() return 0 end
  V.roll:Show()
  local rr = R.rr
  local open = RR.IsOpen(rr, t)
  if open then takeUnread(t) end
  local res = RR.Result(rr)
  local y = 0
  local state = open and ((rr.closesAt - t) .. " s left") or (rr.closed and "closed" or "time is up")
  at(V.rHead, 0, y)
  V.rHead:SetText("Rolling: " .. esc(itemName(rr.item)) .. (rr.count > 1 and (" x" .. rr.count) or "")
    .. " - " .. state)
  y = y - 18
  at(V.rUnread, 0, y)
  local u = rr.unread or 0
  V.rUnread:SetText(u == 1 and "1 roll could not be read" or (u .. " rolls could not be read"))
  V.rUnread:SetShown(u > 0)
  if u > 0 then y = y - 16 end
  at(V.rDropped, 0, y)
  local d = rr.dropped or 0
  V.rDropped:SetText(d == 1 and "1 line not listed" or (d .. " lines not listed"))
  V.rDropped:SetShown(d > 0)
  if d > 0 then y = y - 16 end
  local shown = {}
  if not rr.closed then
    shown[#shown + 1] = V.bMore
    shown[#shown + 1] = V.bClose
  end
  shown[#shown + 1] = V.bType -- until the roll is assigned (a roll typed after Close counts by hand)
  if res.kind == "win" or res.kind == "de" then
    shown[#shown + 1] = V.bAssign
    V.bAssign:SetEnabled(not open)
  elseif res.kind == "tie" and not open then
    shown[#shown + 1] = V.bAgain
  elseif res.kind == "none" and not open then
    shown[#shown + 1] = V.bBank
    shown[#shown + 1] = V.bHand
  end
  rowOf(shown, y)
  y = y - 26
  local outcome
  if res.kind == "tie" then
    outcome = "Tie: " .. #res.tied .. " players"
  elseif res.kind == "none" and not open then
    outcome = "Nobody rolled."
  end
  at(V.rOutcome, 0, y)
  V.rOutcome:SetText(outcome or "")
  V.rOutcome:SetShown(outcome ~= nil)
  if outcome then y = y - 18 end
  if typing.open and V.tName and V.tNum then
    rowOf({ V.tName, V.tNum, V.tHow, V.tAdd }, y)
    V.tHow:SetText(HOW_TEXT[typing.how])
    y = y - 26
  end
  local rank = RR.Rank(rr) -- RR.Add already limits the not-counted lines; every counted roll is shown
  for i, e in ipairs(rank) do
    local line = V.lines[i] or makeRow(V.lineChild, lineMenu)
    V.lines[i] = line
    line.entry = e
    line:SetHeight(20)
    line.label:SetFontObject(role(e.counted and "highlight" or "disable"))
    line.label:SetText(lineText(e))
    placeRow(line, V.lineChild, i, 20)
  end
  endRows(V.lines, #rank, V.lineChild, 20)
  local lh = math.min(math.max(#rank, 1), 8) * 20 + 4
  at(V.lineScroll, 0, y)
  V.lineScroll:SetSize(w - 22, lh)
  y = y - lh
  V.roll:SetHeight(-y)
  return -y + 6
end

local function doneText(d)
  local s = esc(itemName(d.rec.item)) .. ": " .. esc(RR.DoneText(d.rec))
  if not d.recorded then s = s .. " (not recorded)" end
  if d.note then s = s .. " - " .. esc(d.note) end
  return s
end

-- The card's draw; the page's view, rows and time are not used (the card reads its own list and the clock).
local function draw(_, _, _, _, L)
  if not V then return end
  local t = now()
  local w = (L and L.viewW or 400) - 16
  local h = L and L.cardH or 400
  local lead = leads()
  local y = -10
  at(V.lead, 8, y)
  V.lead:SetWidth(w)
  V.lead:SetShown(not lead)
  if not lead then y = y - 20 end
  at(V.roll, 8, y)
  V.roll:SetWidth(w)
  y = y - drawRoll(t, w) - 4
  at(V.addLabel, 8, y)
  y = y - 18
  at(V.box or V.noBox, 14, y)
  at(V.chat, 250, y + 2)
  y = y - 26
  at(V.why, 8, y)
  V.why:SetWidth(w)
  y = y - 18
  local formOn = form.mode ~= nil and V.fName ~= nil and (form.mode == "change" or R ~= nil)
  V.form:SetShown(formOn)
  if formOn then
    at(V.form, 8, y)
    V.form:SetWidth(w)
    V.fName:ClearAllPoints()
    V.fName:SetPoint("LEFT", 6, 0)
    V.fHow:ClearAllPoints()
    V.fHow:SetPoint("LEFT", V.fName, "RIGHT", 8, 0)
    V.fSave:ClearAllPoints()
    V.fSave:SetPoint("LEFT", V.fHow, "RIGHT", 6, 0)
    y = y - 28
  end
  if council.from ~= currentList() then council.mode = nil end -- the shown list changed: the form closes
  local councilOn = council.mode ~= nil and V.cWho ~= nil
  V.council:SetShown(councilOn)
  if councilOn then
    at(V.council, 8, y)
    V.council:SetWidth(w)
    V.cWho:ClearAllPoints()
    V.cWho:SetPoint("BOTTOMLEFT", 6, 2)
    V.cWhy:ClearAllPoints()
    V.cWhy:SetPoint("LEFT", V.cWho, "RIGHT", 8, 0)
    V.cOthers:ClearAllPoints()
    V.cOthers:SetPoint("LEFT", V.cWhy, "RIGHT", 8, 0)
    V.cSave:ClearAllPoints()
    V.cSave:SetPoint("LEFT", V.cOthers, "RIGHT", 6, 0)
    y = y - 48
  end
  at(V.toRollHead, 8, y)
  y = y - 18
  local doneH = 110
  local listH = math.max(ROW_H, h + y - doneH - 34)
  at(V.scroll, 8, y)
  V.scroll:SetSize(w - 22, listH)
  at(V.doneHead, 8, y - listH - 6)
  at(V.doneScroll, 8, y - listH - 24)
  V.doneScroll:SetSize(w - 22, doneH - 24)

  local list = currentList()
  local size, flags = policyNow()
  for i, r in ipairs(list.items) do
    local row = V.rows[i] or makeRow(V.child, itemRowMenu, "Start roll", rowButtonClick)
    V.rows[i] = row
    row.n = r.n
    local kl = V.kinds[row]
    if not kl then
      kl = ns.Label(row, role("highlightSmall"))
      V.kinds[row] = kl
      kl:SetPoint("RIGHT", row.extra, "LEFT", -6, 0)
      row.label:SetPoint("RIGHT", kl, "LEFT", -6, 0)
    end
    local text = itemText(r)
    if r.rolling and not (R and R.row == r) then text = text .. " - " .. LOST end
    row.label:SetText(text)
    local kind, reason, hand = kindOf(r, size, flags)
    kl:SetText(esc(kindText(kind, reason, hand, r.case)))
    row.extra:SetText(kind == "council" and "Council" or "Start roll")
    row.extra:SetShown(lead)
    row.extra:SetEnabled(kind == "council" or R == nil or not RR.IsOpen(R.rr, t))
    placeRow(row, V.child, i, ROW_H)
  end
  endRows(V.rows, #list.items, V.child, ROW_H)

  for i, d in ipairs(list.done) do
    local row = V.doneRows[i] or makeRow(V.doneChild, function() end, "Change", function(self)
      openForm("change", self.done)
    end)
    V.doneRows[i] = row
    row.done = d
    row.label:SetText(doneText(d))
    row.extra:SetShown(lead and d.id ~= nil)
    placeRow(row, V.doneChild, i, ROW_H)
  end
  endRows(V.doneRows, #list.done, V.doneChild, ROW_H)
end

ns.Cards.loot = { build = build, draw = draw }

-- ---------- slash and settings ----------

-- /gsraids roll: the page, then the loot card.
function ns.RollSlash()
  openCard()
end

-- The two session settings (Raids.lua's settings): rollTime and send, in GuildSyncRaidsDB.session. Any other key
-- writes nothing.
local OPTIONS = { rollTime = true, send = true }
function ns.SetSessionOption(key, v)
  if not OPTIONS[key] then return nil end
  local db = ns.DB()
  if type(db.session) ~= "table" then db.session = {} end
  db.session[key] = v
  return true
end

-- Ticket 59's Loot tab asks whether to show: exactly true when this player runs the loot and ev is the raid chosen
-- on the page or a raid whose night already holds a list (read without making a night), else false.
function ns.WantLootTab(ev)
  if not leads() or type(ev) ~= "table" then return false end
  if ev.key ~= nil and ns.PageState and ev.key == ns.PageState.chosen then return true end
  if demo() or ev.id == nil then return false end
  local night = ns.DB().nights[tostring(ev.id)]
  local s = type(night) == "table" and night.session or nil
  if type(s) ~= "table" then return false end
  local held = (type(s.items) == "table" and #s.items > 0) or (type(s.done) == "table" and #s.done > 0)
  return held and true or false
end
