-- GuildSyncExpeditions History.lua: the quest history on the Map Table (slice Y, plan Seams and Y1-Y10).
--   ns.HistoryRun(run, name, band, open)   Expeditions.lua settleRun, every band, once per run; open is ns.StoryStep() read before the settle
--   ns.HistoryWrit(w)                      Quests.lua FinishWrit, after the look is set
--   ns.HistoryRows() -> list               read only, newest first, then back-filled story steps:
--                                          { kind, title, who | nil, res, t | nil, c | nil, s | nil }
--   ns.AnnounceRun(run, name, band, open) -> { title | nil, word } | nil
--                                          Expeditions.lua settleRun, right after HistoryRun: keeps an unseen row, then
--                                          says "Expeditions: <name> is back from <title>: <result>." in chat; answers
--                                          that title and result word for the settle toast ({ word } with no title,
--                                          nil in demo and for a bad run or band)
--   ns.Unseen() -> list                    read only, newest first: { who, title, res, word, fid | nil, t }; {} in demo
--   ns.SeeAll()                            clears every unseen row, keeps next; nothing in demo. The third write outside
--                                          ns.SettleDue, beside R-quiet's two (o3033)
--   ns.History.Build(f, box, bar, cover)   once, from MapTab.Build; cover(on) hides or brings back the map's layers
--   ns.History.Refresh()                   from MapTab.Refresh; refills only while the list shows
--   ns.History.Open()                      opens the list; nothing before Build
-- Saved: history = { next, rows = { [id] = { kind, who, res, t, + c, s | wid | title } } }. A story row re-derives its
-- title and a writ its name. unseen = { next, rows = { [id] = { who, title, res, t, fid } } }, the last UNSEEN_KEEP
-- results not yet seen. A run whose follower is gone gets no History row, no unseen row and no line (settleRun returns
-- before its hooks). Personal: never sent, never in the record. Nothing is written or said in demo.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local FC = ns.FollowerCore
local D = ns.StoryData

local KEEP = 50
local UNSEEN_KEEP = 10
local DAY = 86400
local WRIT_DONE = "complete"
local RUN_RES = { succ = true, succw = true, fail = true, failw = true, dead = true, perma = true }
local WINS = { succ = true, succw = true }

-- Every word this file shows.
local WORDS = {
  history = "History", back = "Back", empty = "No quests finished yet.", today = "Today", yesterday = "Yesterday",
  res = { succ = "Success", succw = "Success, Wounded", fail = "Failed", failw = "Failed, Wounded", dead = "Killed",
    perma = "Killed for good", complete = "Complete" },
}
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local BUTTON_W, BUTTON_H, BUTTON_X = 80, 22, -8
local CARD_W, CARD_H, CARD_X, CARD_Y, CARD_LEVEL = 706, 458, 10, -42, 20
local LIST_X, LIST_Y, LIST_W, LIST_H = 8, -26, 690, 422
local ROW_H, ROW_STEP = 18, 20
local TITLE_X, TITLE_W, WHO_X, WHO_W, RES_X, RES_W, DAY_X, DAY_W = 0, 330, 340, 110, 460, 140, 610, 80
local WHEEL_STEP = 40
local ANYA_PX, ANYA_X, ANYA_Y = 44, 14, -14
local READER_X, READ_W, READ_H, READ_Y = 72, 666, 346, -76

local function whole(v, lo, hi)
  return type(v) == "number" and v >= lo and v <= hi and v == math.floor(v)
end

-- The part -------------------------------------------------------------------------------------------------------------

local function realStep(c, s)
  return whole(c, 1, #D) and whole(s, 1, #D[c].steps)
end

local function nameOf(who)
  if FC.ValidName(who) then return who end
  return nil
end

local function stamp(t)
  if whole(t, 0, FC.TIME_MAX) then return t end
  return 0
end

local function fresh() return { next = 1, rows = {} } end

-- Builds a new table of the known fields: a bad who or t is repaired, anything else bad drops the row alone.
local function soundRow(id, row)
  if not whole(id, 1, FC.ID_MAX) then return nil end
  local out = { kind = row.kind, res = row.res, who = nameOf(row.who), t = stamp(row.t) }
  if row.kind == "story" then
    if not RUN_RES[row.res] or not realStep(row.c, row.s) then return nil end
    out.c, out.s = row.c, row.s
  elseif row.kind == "writ" then
    if row.res ~= WRIT_DONE or not ns.WellFormed(row.wid) or not ns.QuestData.BY_ID[row.wid] then return nil end
    out.wid = row.wid
  elseif row.kind == "expedition" then
    if not RUN_RES[row.res] or type(row.title) ~= "string" or #row.title < 1 or #row.title > FC.TEXT_MAX then return nil end
    out.title = row.title
  else
    return nil
  end
  return out
end

local function part() return ns.Part("history", fresh, soundRow) end

local function isNewer(a, b)
  if a.row.t ~= b.row.t then return a.row.t > b.row.t end
  return a.id > b.id
end

-- Drops every row past the newest keep in one sorted pass, so an oversized hand-edited part costs n log n once.
local function trim(rows, keep)
  local n = 0
  for _ in pairs(rows) do n = n + 1 end
  if n <= keep then return end
  local all = {}
  for id, row in pairs(rows) do all[#all + 1] = { id = id, row = row } end
  table.sort(all, isNewer)
  for k = keep + 1, #all do rows[all[k].id] = nil end
end

local function addTo(p, row, keep)
  local id = FC.NextId(p)
  if not id then return end
  p.rows[id] = row
  p.next = id + 1
  trim(p.rows, keep)
end

local function add(row) addTo(part(), row, KEEP) end

-- An unseen row: a bad id, res, title or who drops it; a bad t is repaired to 0 and a bad fid to nil.
local function soundUnseen(id, row)
  if not whole(id, 1, FC.ID_MAX) or not RUN_RES[row.res] or not FC.ValidName(row.who) then return nil end
  if type(row.title) ~= "string" or #row.title < 1 or #row.title > FC.TEXT_MAX then return nil end
  local fid = whole(row.fid, 1, FC.ID_MAX) and row.fid or nil
  return { who = row.who, title = row.title, res = row.res, t = stamp(row.t), fid = fid }
end

local function unseenPart() return ns.Part("unseen", fresh, soundUnseen) end

-- The open story step a capstone run was at, as chapter and step numbers; nil when it was a plain run: off its step, in
-- another region, or a win on a day that does not finish the step (Story.lua's same-day case).
local function capstoneAt(run, band, open)
  if run.capstone ~= true or type(open) ~= "table" then return nil end
  for c, ch in ipairs(D) do
    if ch.name == open.chapter then
      local step = ch.region == run.region and ch.steps[open.step]
      if not step or not step.capstone then return nil end
      if WINS[band] then
        local now = ns.StoryStep()
        if now and now.chapter == open.chapter and now.step == open.step then return nil end
      end
      return c, open.step
    end
  end
  return nil
end

-- run.story is "c.s", read from the run itself so an advance at the settle cannot change it.
local function storyStepOf(run, band, open)
  if run.story == nil then return capstoneAt(run, band, open) end
  if type(run.story) ~= "string" then return nil end
  local c, s = run.story:match("^(%d+)%.(%d+)$")
  c, s = tonumber(c), tonumber(s)
  if realStep(c, s) then return c, s end
  return nil
end

-- The run's title: its story step's, else the board row's cut to TEXT_MAX; nil when there is none. Also the step c, s.
local function runTitle(run, band, open)
  local c, s = storyStepOf(run, band, open)
  if c then return D[c].steps[s].title, c, s end
  local title = ns.W.RowText({ id = run.rowId, region = run.region, kind = run.kind, capstone = run.capstone })
  if type(title) ~= "string" or title == "" then return nil end
  return title:sub(1, FC.TEXT_MAX)
end

function ns.HistoryRun(run, name, band, open)
  if M.Demo() or type(run) ~= "table" or not RUN_RES[band] then return end
  local row = { res = band, who = nameOf(name), t = stamp(run.ends) }
  local title, c, s = runTitle(run, band, open)
  if c then
    row.kind, row.c, row.s = "story", c, s
  elseif title then
    row.kind, row.title = "expedition", title
  else
    return
  end
  add(row)
end

-- Writes before it says: a throw in Say can lose a line but never doubles one. Escaped once here; the hub's Say does not.
function ns.AnnounceRun(run, name, band, open)
  if M.Demo() or type(run) ~= "table" or not RUN_RES[band] then return end
  local title = runTitle(run, band, open)
  if not title then return { word = WORDS.res[band] } end
  if FC.ValidName(name) then
    addTo(unseenPart(), { who = name, title = title, res = band, t = stamp(run.ends), fid = run.fid }, UNSEEN_KEEP)
  end
  ns.Say(ns.Escape(name) .. " is back from " .. ns.Escape(title) .. ": " .. WORDS.res[band] .. ".")
  return { title = title, word = WORDS.res[band] }
end

function ns.Unseen()
  if M.Demo() then return {} end
  local stored = {}
  for id, row in pairs(unseenPart().rows) do stored[#stored + 1] = { id = id, row = row } end
  table.sort(stored, isNewer)
  local out = {}
  for i = 1, math.min(#stored, UNSEEN_KEEP) do
    local row = stored[i].row
    out[i] = { who = row.who, title = row.title, res = row.res, word = WORDS.res[row.res], fid = row.fid, t = row.t }
  end
  return out
end

function ns.SeeAll()
  if M.Demo() then return end
  unseenPart().rows = {}
end

function ns.HistoryWrit(w)
  if M.Demo() or type(w) ~= "table" then return end
  local who
  for _, row in ipairs(ns.Followers()) do
    if w.look ~= nil and row.look == w.look then who = row.name break end
  end
  add({ kind = "writ", wid = w.id, who = nameOf(who), res = WRIT_DONE, t = stamp(ns.Now()) })
end

-- The list -------------------------------------------------------------------------------------------------------------

local function titleOf(row)
  if row.kind == "story" then return D[row.c].steps[row.s].title end
  if row.kind == "writ" then return ns.QuestData.BY_ID[row.wid].name end
  return row.title
end

-- Every step before the current one with no row in the list, (c, s) descending. Only a win advances, so each is a success.
local function backFill(out, listed)
  local open = ns.StoryStep and ns.StoryStep()
  local current = #ns.ChaptersDone() + 1
  for c = #D, 1, -1 do
    local last = 0
    if c < current then last = #D[c].steps elseif c == current and open then last = open.step - 1 end
    for s = last, 1, -1 do
      if not listed[c .. "." .. s] then
        out[#out + 1] = { kind = "story", title = D[c].steps[s].title, res = "succ", c = c, s = s }
      end
    end
  end
end

function ns.HistoryRows()
  local stored = {}
  for id, row in pairs(part().rows) do stored[#stored + 1] = { id = id, row = row } end
  table.sort(stored, isNewer)
  local out, listed = {}, {}
  for i = 1, math.min(#stored, KEEP) do
    local row = stored[i].row
    out[i] = { kind = row.kind, title = titleOf(row), who = row.who, res = row.res, t = row.t, c = row.c, s = row.s }
    if row.kind == "story" then listed[row.c .. "." .. row.s] = true end
  end
  backFill(out, listed)
  return out
end

-- The moment the current server day ends, rounded as Story.lua rounds it; nil when the clock or the reset is unknown.
local function dayEnd()
  local now, left = ns.Now(), ns.NextRefresh()
  if not now or not left then return nil end
  return math.floor((now + left) / 60 + 0.5) * 60
end

local function shortDate(t)
  if type(date) ~= "function" then return "" end
  local d = date("*t", t)
  if type(d) ~= "table" or not MONTHS[d.month] then return "" end
  return string.format("%d %s", d.day, MONTHS[d.month])
end

local function dayText(t, reset)
  if type(t) ~= "number" or t <= 0 then return "" end
  if reset then
    local n = math.floor((reset - t - 1) / DAY)
    if n <= 0 then return WORDS.today end
    if n == 1 then return WORDS.yesterday end
  end
  return shortDate(t)
end

-- The panel ------------------------------------------------------------------------------------------------------------

local History = {}
ns.History = History

local ui

local function showList()
  ui.reader:Hide()
  ui.heading:Show()
  ui.scroll:Show()
end

local function openReader(c, s)
  local ch, st = D[c], D[c].steps[s]
  ui.scroll:Hide()
  ui.empty:Hide()
  ui.heading:Hide()
  ui.readerTitle:SetText(st.title)
  ui.readerPlace:SetText(st.place .. ", " .. ch.name .. " (" .. s .. "/4)")
  ui.readerText:SetText(st.text)
  ui.reader:Show()
  if ns.ShowAnya then M.Safe(ns.ShowAnya, ui.anya) end
end

local function closeList()
  ui.card:Hide()
  showList()
  ui.cover(false)
end

local function clickRow(row)
  local data = row.data
  if data and data.kind == "story" then openReader(data.c, data.s) end
end

local function wheel(scroll, child, delta)
  local range = math.max(0, (child:GetHeight() or 0) - (scroll:GetHeight() or 0))
  scroll:SetVerticalScroll(math.max(0, math.min(range, (scroll:GetVerticalScroll() or 0) - delta * WHEEL_STEP)))
end

local function cell(row, x, w, justify)
  local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", row, "LEFT", x, 0)
  fs:SetWidth(w)
  fs:SetWordWrap(false)
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Row i, made the first time it is needed and kept.
local function newRow(i)
  if ui.rows[i] then return ui.rows[i] end
  local b = CreateFrame("Button", nil, ui.child)
  b:SetSize(LIST_W, ROW_H)
  b:SetPoint("TOPLEFT", ui.child, "TOPLEFT", 0, -(i - 1) * ROW_STEP)
  local hover = b:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints(b)
  hover:SetColorTexture(1, 0.82, 0, 0.12)
  local row = { b = b, title = cell(b, TITLE_X, TITLE_W), who = cell(b, WHO_X, WHO_W), res = cell(b, RES_X, RES_W),
    day = cell(b, DAY_X, DAY_W, "RIGHT") }
  b:SetScript("OnClick", function() M.Safe(clickRow, row) end)
  ui.rows[i] = row
  return row
end

local function fill()
  local list = ns.HistoryRows()
  local reset = dayEnd()
  for i, data in ipairs(list) do
    local row = newRow(i)
    local isStory = data.kind == "story"
    row.data = data
    row.title:SetText(ns.Escape(data.title))
    if isStory then row.title:SetTextColor(1, 0.82, 0) else row.title:SetTextColor(1, 1, 1) end
    row.who:SetText(data.who or "")
    row.res:SetText(WORDS.res[data.res] or "")
    row.day:SetText(dayText(data.t, reset))
    row.b:SetEnabled(isStory)
    row.b:Show()
  end
  for i = #list + 1, #ui.rows do ui.rows[i].b:Hide() end
  ui.child:SetSize(LIST_W, math.max(1, #list * ROW_STEP))
  ui.empty:SetShown(#list == 0)
end

local function toList()
  showList()
  fill()
end

local function openList()
  toList()
  ui.cover(true)
  ui.card:Show()
  ui.scroll:SetVerticalScroll(0)
  if ns.FadeIn then M.Safe(ns.FadeIn, ui.card) end
end

local function line(parent, font)
  return parent:CreateFontString(nil, "OVERLAY", font)
end

local function buildReader(card)
  local reader = CreateFrame("Frame", nil, card)
  reader:SetAllPoints(card)
  reader:Hide()
  ui.reader = reader

  ui.anya = CreateFrame("Frame", nil, reader)
  ui.anya:SetSize(ANYA_PX, ANYA_PX)
  ui.anya:SetPoint("TOPLEFT", reader, "TOPLEFT", ANYA_X, ANYA_Y)

  ui.readerTitle = line(reader, "GameFontNormal")
  ui.readerTitle:SetPoint("TOPLEFT", reader, "TOPLEFT", READER_X, -18)
  ui.readerPlace = line(reader, "GameFontHighlightSmall")
  ui.readerPlace:SetPoint("TOPLEFT", reader, "TOPLEFT", READER_X, -38)
  ui.readerText = line(reader, "GameFontHighlight")
  ui.readerText:SetPoint("TOPLEFT", reader, "TOPLEFT", 20, READ_Y)
  ui.readerText:SetSize(READ_W, READ_H)
  ui.readerText:SetJustifyH("LEFT")
  ui.readerText:SetJustifyV("TOP")

  local back = CreateFrame("Button", nil, reader, "UIPanelButtonTemplate")
  back:SetSize(BUTTON_W, BUTTON_H)
  back:SetPoint("BOTTOMLEFT", reader, "BOTTOMLEFT", 14, 12)
  back:SetText(WORDS.back)
  back:SetScript("OnClick", function() M.Safe(toList) end)
end

function History.Build(f, box, bar, cover)
  local card = M.Kit.Card(box, CARD_W, CARD_H)
  if not card then return end
  card:SetFrameLevel(box:GetFrameLevel() + CARD_LEVEL)
  card:SetPoint("TOPLEFT", box, "TOPLEFT", CARD_X, CARD_Y)
  card:EnableMouse(true)
  card:Hide()

  local heading = line(card, "GameFontNormal")
  heading:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
  heading:SetText(WORDS.history)

  local close = CreateFrame("Button", nil, card, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() M.Safe(closeList) end)

  local scroll = CreateFrame("ScrollFrame", nil, card)
  scroll:SetPoint("TOPLEFT", card, "TOPLEFT", LIST_X, LIST_Y)
  scroll:SetSize(LIST_W, LIST_H)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(LIST_W, 1)
  scroll:SetScrollChild(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta) M.Safe(wheel, self, child, delta) end)

  local empty = line(card, "GameFontHighlightSmall")
  empty:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -30)
  empty:SetText(WORDS.empty)
  empty:Hide()

  ui = { card = card, heading = heading, scroll = scroll, child = child, empty = empty, rows = {}, cover = cover }
  buildReader(card)

  local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  button:SetSize(BUTTON_W, BUTTON_H)
  button:SetPoint("RIGHT", bar, "RIGHT", BUTTON_X, 0)
  button:SetText(WORDS.history)
  button:SetScript("OnClick", function()
    M.Safe(function()
      if ui.card:IsShown() then closeList() else openList() end
    end)
  end)

  f:HookScript("OnHide", function() M.Safe(closeList) end)
end

function History.Open()
  if ui then openList() end
end

function History.Refresh()
  if ui and ui.card:IsShown() and not ui.reader:IsShown() then fill() end
end
