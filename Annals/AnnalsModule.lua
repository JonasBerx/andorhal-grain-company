-- Annals AnnalsModule: Annals as a GuildSync module (window plan D2, D4-D8, D14, D17). Registers with the hub
-- (needs 4), builds the Annals page in the GuildSync window with one Kit tab per tab file, owns /annals, the selftest,
-- the status line, the demo hand-off and the recorded page width, and exports the seam ns.AnnalsModule: the only
-- thing the tab files (AnnalsJourney, AnnalsRace, AnnalsLevelLog, AnnalsAchievements, AnnalsHealth) reach.
-- ns.AnnalsModule is always a table; M and Kit are set only when GuildSync registered the module (D2).
-- Reads only ns.Annals* and the Lua whitelist; every client call goes through ns.AnnalsHost. AnnalsCore loads after
-- this file, so every Core call is looked up when it runs.
local _, ns = ...
local Rules, View, Host = ns.AnnalsRules, ns.AnnalsView, ns.AnnalsHost
local A = {}
ns.AnnalsModule = A

local TAB_FILES = { "AnnalsJourney", "AnnalsRace", "AnnalsLevelLog", "AnnalsAchievements", "AnnalsHealth" }
local TAB_H = 32
local BUTTON_H = 22
local FALLBACK_TAB_W = 110
local T_NO_HUB_DEMO = "/gsync demo is not available."
local T_DEMO_USAGE = "Usage: /annals demo [on | off]"

local function core() return ns.AnnalsCore end

local function tabOf(key)
  for _, name in ipairs(TAB_FILES) do
    local t = ns[name]
    if type(t) == "table" and t.key == key then return t end
  end
  return nil
end

-- ---------- shared pieces (moved from the old page file, D8) ----------

-- `|` doubled so the client draws it as a plain character; nil stays nil.
function A.esc(v)
  if v == nil then return nil end
  return (string.gsub(tostring(v), "|", "||"))
end

-- One line, left, never wrapped; a width ends it in an ellipsis in the client.
function A.Label(parent, text, font, width)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  fs:SetMaxLines(1)
  if width then fs:SetWidth(width) end
  fs:SetText(text or "")
  return fs
end

function A.Button(parent, text, width, onClick)
  local b = Host.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  if not b then return nil end
  b:SetSize(width, BUTTON_H)
  b:SetText(text)
  b:SetScript("OnClick", function(self) if A.M and onClick then A.M.Safe(onClick, self) end end)
  return b
end

-- A UIPanelScrollFrameTemplate over the holder and its content frame, whose width follows the scroll.
function A.Scroll(holder)
  local scroll = Host.CreateFrame("ScrollFrame", nil, holder, "UIPanelScrollFrameTemplate")
  if not scroll then return nil end
  scroll:SetPoint("TOPLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", -Rules.SCROLL_W, 0)
  local content = Host.CreateFrame("Frame", nil, scroll)
  if not content then return scroll, nil end
  content:SetSize(A.Layout().inner, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(_, w) if type(w) == "number" and w > 0 then content:SetWidth(w) end end)
  return scroll, content
end

-- A plain frame of `kind` (default "Frame") under parent, with no template: the per-row frames the kit does not offer.
function A.Frame(parent, kind)
  return Host.CreateFrame(kind or "Frame", nil, parent)
end

function A.ClassColour(token)
  local r, g, b = Host.ClassColor(token)
  if r then return r, g, b end
  return 1, 1, 1
end

-- A button that opens the Journey of b.guid as it is at click time (A.OpenJourney looked up then too); nil without
-- row.guid. A pooled row reused for another character sets b.guid again each time it draws: b.guid = row.guid.
function A.NameButton(parent, row)
  if type(row) ~= "table" or row.guid == nil then return nil end
  local b = Host.CreateFrame("Button", nil, parent)
  if not b then return nil end
  b.guid = row.guid
  b:SetScript("OnClick", function(self) if A.M and self.guid then A.M.Safe(A.OpenJourney, self.guid) end end)
  return b
end

function A.Tooltip(owner, title, lines) Host.Tooltip(owner, title, lines) end
function A.TooltipHide() Host.TooltipHide() end

-- While the mouse is over f, the tooltip tip(self) gives (title, lines; read on enter, nil title: none).
function A.HoverTip(f, tip)
  if not f then return end
  local function enter(self)
    local title, lines = tip(self)
    if title ~= nil then A.Tooltip(self, title, lines) end
  end
  f:SetScript("OnEnter", function(self) if A.M then A.M.Safe(enter, self) end end)
  f:SetScript("OnLeave", function() if A.M then A.M.Safe(function() A.TooltipHide() end) end end)
end

-- ---------- Core and Host, for the tab files ----------

function A.PageG() return core().PageG() end
-- True when the page draws the demo G itself, not merely while the demo is on (security s2).
function A.DrawsDemo(G) return G ~= nil and core().Demo() and G ~= core().G() end
function A.PageMaxLevel(G)
  if A.DrawsDemo(G) then return Rules.DEMO_MAX_LEVEL end
  return core().MaxLevel()
end
function A.JourneySelf() return core().JourneySelf() end
-- True once the first roster read of the session was applied: the selftest waits on it (the tabs use A.NoGuild).
function A.ReadDone() return core().readDone == true end
-- The one "No guild data yet" rule for every tab (f3005, f3022): no G, or a G with no characters. Last session's saved
-- annals draw at once after login, before the first read; the demo G has characters, so it draws too.
function A.NoGuild(G) return type(G) ~= "table" or next(G.chars or {}) == nil end
function A.Now() return core().Now() end
function A.DemoGen() return core().DemoGen() end
function A.DniAdd(name, guid, reason) return core().DniAdd(name, guid, reason) end
function A.DniRemove(id) return core().DniRemove(id) end
function A.Date(fmt, t) return Host.Date(fmt, t) end
function A.CanViewOfficerNote() return Host.CanViewOfficerNote() end
function A.Say(text) return Host.Say(text) end

-- Health shows in the demo or for an officer: whoever the hub counts as one (D6, D240).
function A.HealthVisible()
  return core().Demo() or Host.IsOfficer()
end

-- ---------- the page state (D4, D17) ----------

local current = "journey"
local page = nil          -- { frame, tabs (Kit) or buttons (fallback), holders = { [key] = frame } }
local storedW = nil       -- the page width from its OnSizeChanged (D17); nil gives PAGE_W_DEFAULT
local lastCols = nil
local pending = false
local refresh             -- the page refresh, below

function A.Layout() return Rules.PageLayout(storedW) end
function A.Current() return current end

local function refreshTab()
  if not page then return end
  -- Health no longer visible (demo off, rank lost): the page refresh hides it and moves to Journey (f3012).
  if current == "health" and not A.HealthVisible() then return refresh() end
  local t = tabOf(current)
  local holder = page.holders[current]
  if t and holder and type(t.refresh) == "function" then A.M.Safe(t.refresh, holder) end
end

local function show()
  if not page then return end
  for key, holder in pairs(page.holders) do
    if key == current then holder:Show() else holder:Hide() end
  end
  if page.tabs then page.tabs:Select(current) end
  if page.buttons then
    for key, b in pairs(page.buttons) do
      if key == current then b:LockHighlight() else b:UnlockHighlight() end
    end
  end
  refreshTab()
end

function A.Select(key)
  if not tabOf(key) then return end
  if key == "health" and not A.HealthVisible() then return end
  current = key
  show()
end

-- That guid's Journey (nil: yours), folds closed, the page shown.
function A.OpenJourney(guid)
  local J = ns.AnnalsJourney
  if type(J) == "table" and type(J.open) == "function" then J.open(guid) end
  A.Select("journey")
  if A.M then A.M.OpenPage() end
end

local function onSize(w)
  storedW = w
  local cols = A.Layout().cols
  if cols ~= lastCols then
    lastCols = cols
    refreshTab()
    return
  end
  if pending then return end
  pending = true
  A.M.After(Rules.RELAYOUT_SETTLE, function()
    pending = false
    refreshTab()
  end)
end

-- A click on a tab: the tab's home() first when it has one, then the tab shows. The hub's Kit tabs ignore a click on
-- the selected tab (GuildSync/Kit.lua:579), so from someone else's Journey the way back to your own is Back; home()
-- runs here when Journey is clicked from another tab (and on the fallback buttons).
local function clicked(key)
  local t = tabOf(key)
  if t and type(t.home) == "function" then t.home() end
  A.Select(key)
end

local function build(frame)
  page = { frame = frame, holders = {} }
  local entries = {}
  for _, name in ipairs(TAB_FILES) do
    local t = ns[name]
    if type(t) == "table" and t.key then entries[#entries + 1] = { key = t.key, text = t.text } end
  end
  page.tabs = A.Kit and A.Kit.Tabs(frame, entries, function(key) A.M.Safe(clicked, key) end)
  if not page.tabs then
    page.buttons = {}
    for i, e in ipairs(entries) do
      local key = e.key
      local b = A.Button(frame, e.text, FALLBACK_TAB_W, function() clicked(key) end)
      if b then
        b:SetPoint("TOPLEFT", 4 + (i - 1) * (FALLBACK_TAB_W + 2), -4)
        page.buttons[key] = b
      end
    end
  end
  for _, e in ipairs(entries) do
    local holder = Host.CreateFrame("Frame", nil, frame)
    if holder then
      holder:SetPoint("TOPLEFT", 0, -TAB_H)
      holder:SetPoint("BOTTOMRIGHT", 0, 0)
      holder:Hide()
      page.holders[e.key] = holder
      local t = tabOf(e.key)
      if type(t.build) == "function" then A.M.Safe(t.build, holder) end
    end
  end
  lastCols = A.Layout().cols
  frame:SetScript("OnSizeChanged", function(_, w) A.M.Safe(onSize, w) end)
end

-- Health's tab follows its visibility; a hidden current Health falls back to Journey (D6). Then the current tab draws.
refresh = function()
  if not page then return end
  local health = tabOf("health")
  local shows = health ~= nil and type(health.visible) == "function" and health.visible() == true
  local b = (page.tabs and page.tabs.health) or (page.buttons and page.buttons.health)
  if b then if shows then b:Show() else b:Hide() end end
  if current == "health" and not shows then current = "journey" end
  show()
  A.PaintTabDot()
end

-- ---------- new marks (plan D9-D11) ----------
-- The marks write on the page G for the viewer (under /gsync demo the demo G in memory, never AnnalsDB). Neither runs
-- Host.Refresh nor the page refresh (that would re-enter the tab's refresh, f3101).

function A.SeenStart()
  local G = A.PageG()
  if type(G) ~= "table" then return false end
  return ns.AnnalsStore.SeenStart(G, A.JourneySelf()) == true
end

function A.MarkSeen(leafKey)
  local G, guid = A.PageG(), A.JourneySelf()
  if type(G) ~= "table" then return end
  ns.AnnalsStore.MarkSeen(G, guid, View.LeafIds(G, guid, leafKey))
end

-- The tab dot alone: the Achievements tab's dot() (read when this runs) shows or hides the notification on its tab.
local function paintTabDot()
  if not page then return end
  local b = (page.tabs and page.tabs.achievements) or (page.buttons and page.buttons.achievements)
  if not b then return end
  if not page.dot then
    page.dot = b:CreateTexture(nil, "OVERLAY")
    page.dot:SetSize(14, 14)
    page.dot:SetPoint("TOP", b, "TOP", 0, -2)
    page.dot:Hide()
  end
  local T = ns.AnnalsAchievements
  if type(T) == "table" and type(T.dot) == "function" and T.dot() == true then
    A.Kit.Atlas(page.dot, "UI-HUD-MicroMenu-Communities-Icon-Notification")
  else
    page.dot:Hide()
  end
end

function A.PaintTabDot()
  if A.M then A.M.Safe(paintTabDot) end
end

-- ---------- /annals, selftest, status ----------

local function open()
  local J = ns.AnnalsJourney
  if type(J) == "table" and type(J.home) == "function" then J.home() end
  A.Select("journey")
  A.M.OpenPage()
end

local function slash(msg)
  local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "status" then
    local Core = core()
    local pm, em = Host.MaxLevels()
    local text = View.StatusText(Core.G(), Host.Guild(), pm, em, Host.IsOfficer(), Core.Demo())
    for line in string.gmatch(tostring(text or ""), "[^\n]+") do Host.Say(line) end
  elseif cmd == "demo" then
    local arg = string.lower(rest or "")
    if arg ~= "" and arg ~= "on" and arg ~= "off" then
      Host.Say(T_DEMO_USAGE)
    else
      local hubMsg = string.match("demo " .. arg, "^%s*(.-)%s*$")
      if not Host.HubSlash(hubMsg) then Host.Say(T_NO_HUB_DEMO) end
    end
  else
    open()
  end
end

local function selftest()
  local Core = core()
  if not Core.readDone then return "wait", "no read yet" end
  local G = Core.G()
  local n = 0
  for _ in pairs(G and G.chars or {}) do n = n + 1 end
  return "pass", n .. " members, last read " .. ((G and G.lastPartial) and "partial" or "full") .. ", Health "
    .. (A.HealthVisible() and "shown" or "hidden")
end

local function status()
  local Core = core()
  local pm, em = Host.MaxLevels()
  local text = View.StatusText(Core.G(), Host.Guild(), pm, em, Host.IsOfficer(), Core.Demo())
  -- The hub escapes the status field itself (API.md), so View's doubled | is undone here (f3021).
  return (string.gsub(string.match(tostring(text or ""), "^[^\n]*"), "||", "|"))
end

-- ---------- registration (D2) ----------

local M = Host.RegisterModule({
  id = "annals",
  title = "Annals",
  version = "0.3",
  needs = 4,
  page = {
    title = "Annals",
    icon = "Interface\\Icons\\INV_Misc_Book_09",
    build = function(frame) build(frame) end,
    refresh = function() refresh() end,
  },
  slash = function(rest) slash(rest) end,
  selftest = function() return selftest() end,
  status = function() return status() end,
  -- D7: the made-up guild, session only; Rules.DemoGuild is looked up when the hub calls this.
  demo = function(_, now) return Rules.DemoGuild(now or Host.Now()) end,
})
if not M then return end
-- A.Kit is Annals' own table over the hub's read-only M.Kit, so a test can wrap one piece on it. A.M is the handle
-- seen through a table of Annals' own whose Kit is A.Kit (so A.M.Kit == A.Kit); every other field is M's.
A.Kit = setmetatable({}, { __index = M.Kit })
A.M = setmetatable({ Kit = A.Kit }, { __index = M })

M.On("demo", function() Host.Refresh() end)
-- Each window show ends the Achievements tab's visit (D10, f3103); the tab's windowOpened is read when it runs.
M.On("windowOpened", function()
  A.M.Safe(function()
    local T = ns.AnnalsAchievements
    if type(T) == "table" and type(T.windowOpened) == "function" then T.windowOpened() end
  end)
end)
Host.SetRefresh(function() M.RefreshPage() end)
Host.Slash(slash)
