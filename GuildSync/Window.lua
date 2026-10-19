-- GuildSync Window: the minimap button and the window it opens.
--   Minimap button: left-click opens or closes the window, right-click rescans, drag moves it round the minimap.
--   Window (0.7): Forever's portrait frame (the classic frame on a client without it), a sidebar with three pages
--   and a gear in the title bar for Settings. Overview (counts strip, class mix, who is online, professions covered,
--   the last guild log entries), Roster (the recorded guild roster: rank filter dropdown, search, sortable list, member
--   panel, a right-click menu per row; chip buttons and a scroll frame on a client without them), This character (one status line per module, the /gsync actions as buttons) and Settings.
--   The window is resizable from its bottom-right corner; its size and place are saved in GuildSyncDB3.settings.window.
--   /gsync ui (or /gsync window) opens the window, /gsync minimap shows or hides the button.
--   Officer actions (0.9): the Roster's member panel and row menu get Promote, Demote, Remove from guild (asks first)
--   and Edit notes, each shown only to a character the client says may use it; one client call per click, from the click handler.
-- Every button calls the same function the slash command calls (ns.Commands in Core.lua). The words, the rows, the
-- counts and the sizes come from View.lua; this file only builds frames, through Compat and Kit. Row frames are built
-- once and reused; a page is drawn only while it is shown.

local ADDON, ns = ...
local Compat, View, Kit = ns.Compat, ns.View, ns.Kit

local Window = {}
ns.Window = Window

local ICON = "Interface\\Icons\\INV_Misc_Bag_10"
local GEAR_ICON = "Interface\\Icons\\INV_Misc_Gear_01" -- the Settings gear without its atlas
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GRIP_UP = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up"
local GRIP_DOWN = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down"
local GRIP_HIGHLIGHT = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight"
local GOLD = { 1, 0.82, 0 }
local PANEL_BG = Kit.PANEL_BG
local FLAT_BG = { 1, 1, 1, 0.06 }

local GAP = View.GAP
local BUTTON_W, BUTTON_H = 120, 22
local ROW_H, HEADER_H, CHIP_LINE, CHIP_H = 18, 20, 22, 20
local SEARCH_W = 150

local frame, ui, minimapButton, refreshQueued
-- For the selftest: nil (never tried) | "building" (threw) | "built" | "failed" (nil back or an error recorded)
local buttonBuild, windowBuild
local frameKind -- "modern" (PortraitFrameTemplate with its NineSlice and TitleContainer) | "classic", once built
local currentPage = View.DEFAULT_PAGE -- the last page used, for this session only
-- Where Settings live: "window" (the in-window page) until Window.RegisterOptions registered "vertical" or "canvas".
-- verticalLive: the vertical category reached the AddOns list, so its proxy setters may act.
local settingsPath, optionsCategory, verticalLive, optionsRegistered = "window", nil, false, false

-- GuildSyncDB3.settings.minimap = { angle, hidden }
local function minimapSettings()
  local s = ns.DB().settings
  if type(s.minimap) ~= "table" then s.minimap = {} end
  if type(s.minimap.angle) ~= "number" then s.minimap.angle = View.DEFAULT_ANGLE end
  s.minimap.hidden = s.minimap.hidden and true or false
  return s.minimap
end

-- GuildSyncDB3.settings.window = { w, h, x, y } (x, y: the top-left corner from the screen's bottom-left)
local function windowSettings()
  local s = ns.DB().settings
  if type(s.window) ~= "table" then s.window = {} end
  return s.window
end

-- GuildSyncDB3.settings.windowIcon = "crest" | "bag" (nil or anything else reads as the bag). Read only.
local function crestOn() return ns.DB().settings.windowIcon == "crest" end

-- The window's portrait: the bag or the faction crest (View.WindowIcon). Modern frame only; the classic one has none.
local function applyPortrait(f)
  if not f or frameKind ~= "modern" or type(f.SetPortraitToAsset) ~= "function" then return end
  pcall(f.SetPortraitToAsset, f, View.WindowIcon(ns.DB().settings.windowIcon, Compat.Faction()))
end

-- Saves the choice and puts it on the window at once; before the window exists it only saves.
function Window.SetWindowIcon(choice)
  ns.DB().settings.windowIcon = choice == "crest" and "crest" or "bag"
  applyPortrait(ui and ui.frame)
end

-- Runs a command from a click, then shows what changed.
local function run(fn, ...)
  if type(fn) == "function" then ns.Safe("Window", fn, ...) end
  Window.Refresh()
end

local function safely(fn) return function(...) ns.Safe("Window", fn, ...) end end

-- anchor (optional): the tooltip's BOTTOMLEFT goes on that frame's TOPRIGHT and the lines wrap (the Modules rows).
local function showTooltip(owner, lines, anchor)
  local tip = Compat.Tooltip()
  if not tip or type(lines) ~= "table" or #lines == 0 then return end
  if anchor then
    tip:SetOwner(owner, "ANCHOR_NONE")
    tip:ClearAllPoints() -- the shared GameTooltip may still hold another owner's points (f3303)
    tip:SetPoint("BOTTOMLEFT", anchor, "TOPRIGHT")
  else
    tip:SetOwner(owner, "ANCHOR_RIGHT")
  end
  tip:SetText(lines[1])
  for i = 2, #lines do tip:AddLine(lines[i], 1, 1, 1, anchor ~= nil) end
  tip:Show()
end

local function hideTooltip()
  local tip = Compat.Tooltip()
  if tip then tip:Hide() end
end

-- ---------- minimap button ----------

local function placeButton()
  local map = Compat.Minimap()
  if not minimapButton or not map then return end
  local w = map:GetWidth()
  local x, y = View.Offset(minimapSettings().angle, type(w) == "number" and w > 0 and w / 2 + 5 or nil) -- any minimap size (f712)
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", map, "CENTER", x, y)
end

local function followCursor()
  local map = Compat.Minimap()
  if not map then return end
  local mx, my = map:GetCenter()
  local px, py = Compat.CursorPosition()
  local scale = map:GetEffectiveScale()
  if not mx or not px or not scale or scale <= 0 then return end
  local angle = View.Angle(px / scale - mx, py / scale - my)
  if angle then
    minimapSettings().angle = angle
    placeButton()
  end
end

local function buildButton()
  local map = Compat.Minimap()
  if not map then return nil end
  local b = Compat.CreateFrame("Button", "GuildSyncMinimapButton", map)
  if not b then return nil end
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local back = b:CreateTexture(nil, "BACKGROUND")
  back:SetSize(20, 20)
  back:SetPoint("TOPLEFT", 7, -5)
  back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexture(ICON)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  b:SetScript("OnClick", function(_, which)
    if which == "RightButton" then run(ns.Commands.Scan) else ns.Safe("Window", Window.Toggle) end
  end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function() ns.Safe("Window", followCursor) end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self) showTooltip(self, View.TOOLTIP) end)
  b:SetScript("OnLeave", hideTooltip)
  return b
end

local function showButton()
  if minimapSettings().hidden then
    if minimapButton then minimapButton:Hide() end
    return
  end
  if not minimapButton then
    buttonBuild = "building"
    local errors = ns.SessionErrors("Window")
    minimapButton = buildButton()
    buttonBuild = (minimapButton and ns.SessionErrors("Window") == errors) and "built" or "failed"
  end
  if not minimapButton then return end
  placeButton()
  minimapButton:Show()
end

-- /gsync minimap and the "Show minimap button" checkbox.
function Window.ToggleMinimap()
  local m = minimapSettings()
  m.hidden = not m.hidden
  showButton()
  if m.hidden then
    ns.Say("minimap button hidden. /gsync minimap brings it back.")
  elseif minimapButton then
    ns.Say("minimap button shown.")
  else
    ns.Say("this client has no minimap to put the button on. /gsync ui opens the window.")
  end
  Window.Refresh()
end

-- ---------- building blocks ----------

local function label(parent, text, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetText(text or "")
  return fs
end

local function button(parent, text, x, y, onClick, width, point)
  local b = Compat.CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  if not b then return nil end
  b:SetSize(width or BUTTON_W, BUTTON_H)
  b:SetPoint(point or "BOTTOMLEFT", x, y)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function checkbox(parent, text, x, y, onClick)
  local c = Compat.CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  if not c then return nil end
  c:SetSize(24, 24)
  c:SetPoint("TOPLEFT", x, y)
  c:SetScript("OnClick", onClick)
  local fs = label(parent, text)
  fs:SetPoint("LEFT", c, "RIGHT", 4, 0)
  return c
end

local function background(f, c)
  local t = f:CreateTexture(nil, "BACKGROUND")
  t:SetAllPoints(f)
  t:SetColorTexture(c[1], c[2], c[3], c[4])
  return t
end

local function icon(parent, size, layer)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  t:SetSize(size, size)
  return t
end

-- A flat button: its text on a faint plate. The highlight shows on hover and stays while it is the chosen one.
local function flatButton(parent, w, h, font)
  local b = Compat.CreateFrame("Button", nil, parent)
  if not b then return nil end
  b:SetSize(w, h)
  b:SetNormalFontObject(font or "GameFontHighlightSmall")
  b:SetHighlightTexture(HIGHLIGHT, "ADD")
  b.bg = background(b, FLAT_BG)
  return b
end

local function markSelected(b, on)
  if on then b:LockHighlight() else b:UnlockHighlight() end
  if on then b.bg:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.22) else b.bg:SetColorTexture(FLAT_BG[1], FLAT_BG[2], FLAT_BG[3], FLAT_BG[4]) end
end

-- getLines(frame) -> the tooltip lines, or nil for none; getAnchor(frame) (optional) -> showTooltip's anchor
local function withTooltip(f, getLines, getAnchor)
  f:EnableMouse(true)
  f:SetScript("OnEnter", function(self)
    ns.Safe("Window", function() showTooltip(self, getLines(self), getAnchor and getAnchor(self)) end)
  end)
  f:SetScript("OnLeave", hideTooltip)
end

local function setNameColor(fs, class)
  local r, g, b = Compat.ClassColor(class)
  if r then fs:SetTextColor(r, g, b) else fs:SetTextColor(1, 1, 1) end
end

-- Class icon on a reused row: only touched when the class changes. prefix: an atlas family tried first (Kit.ClassIcon).
local function setClassIcon(holder, class, prefix)
  if holder.iconClass == class then return end
  holder.iconClass = class
  Kit.ClassIcon(holder.icon, class, prefix)
end

-- A rank badge: the rank on a plate in its tier's colour. Two regions on the row, no frame of its own.
local function makeBadge(parent)
  local text = label(parent, "", "GameFontHighlightSmall")
  text:SetWordWrap(false)
  local plate = parent:CreateTexture(nil, "BORDER")
  plate:SetPoint("TOPLEFT", text, "TOPLEFT", -4, 2)
  plate:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 4, -2)
  return { text = text, plate = plate }
end

local function setBadge(badge, rank, order, raiderOrder, maxW)
  badge.text:SetText(rank or "?")
  local w = badge.text:GetStringWidth()
  badge.text:SetWidth((type(w) == "number" and w > 0) and math.min(math.ceil(w) + 2, maxW) or maxW)
  local c = View.TIER_COLORS[View.RankTier(order, raiderOrder)]
  badge.plate:SetColorTexture(c[1], c[2], c[3], 0.5)
end

-- Every page frame (hub, module and Crafting's) fills the page area: the content inset less its padding (View.SHELL).
-- The demo banner sits in the title bar's band above it, so no page moves for it.
function Window.PlacePage(p)
  local P = View.SHELL.page
  p:ClearAllPoints()
  p:SetPoint("TOPLEFT", P.left, P.top)
  p:SetPoint("BOTTOMRIGHT", P.right, P.bottom)
end

local function pageFrame(f)
  local p = Compat.CreateFrame("Frame", nil, f)
  if not p then return nil end
  Window.PlacePage(p)
  return p
end

-- A sidebar row (Kit.SideRow) whose button also carries the text, through its own font string (the label).
function Window.SideRow(parent, text, icon, onClick)
  local b = Kit.SideRow(parent, text, icon, onClick)
  if not b then return nil end
  if b.label then b:SetFontString(b.label) end
  b:SetText(text)
  return b
end

-- The chosen sidebar entry: the row's chosen look (Kit.SetChosen; the gear has none) and its locked highlight.
function Window.MarkChosen(b, on)
  if type(b) ~= "table" then return end
  Kit.SetChosen(b, on)
  if on then b:LockHighlight() else b:UnlockHighlight() end
end

-- ---------- the recorded roster, shared by Overview and Roster ----------
-- Rows come from View.RosterRows(GuildSyncDB3.guild) and are rebuilt only when Roster.lua writes a new roster (a new
-- table); the selection (a GUID) and the scroll stay where they were.

local roster = { sort = View.DEFAULT_SORT, desc = false, chip = "all", query = "", all = {}, shown = {}, stamp = 0 }

-- Officer actions (0.9) the roster has not shown yet: { kind, guid, name, rankOrder | note }, oldest first.
local acting = { pending = {} }

-- Drops the actions the recorded roster now shows. final: the action whose time is up; if the roster still does not
-- show it, a plain line says so. True when that line was said.
local function checkPending(final)
  local guild = ns.DB().guild
  local keep, failed = {}, false
  for _, p in ipairs(acting.pending) do
    local result = View.PendingResult(p, guild)
    if result == "notyet" and p == final then
      ns.Say(View.FailLine(p))
      failed = true
    elseif result == "notyet" then
      table.insert(keep, p)
    end
  end
  acting.pending = keep
  return failed
end

-- The pages' one data source (Demo.lua, D5): guild, log, perms. Without Demo.lua loaded (a test that loads only
-- Compat, Core, View and Window), the recorded roster, log and this character's permissions.
local function demoOn() return ns.Demo ~= nil and ns.Demo.On() end
local function source()
  if ns.Demo then return ns.Demo.Source() end
  local db = ns.DB()
  return db.guild, db.guildLog, Compat.GuildPermissions()
end

local function syncRows()
  local guild = source() -- the demo guild while demo is on, else the recorded roster
  if type(guild) ~= "table" then guild = nil end
  if guild ~= roster.guild and #acting.pending > 0 then checkPending(nil) end
  if guild ~= roster.guild then
    roster.guild = guild
    roster.all = View.RosterRows(guild)
    View.SortRows(roster.all, roster.sort, roster.desc)
    roster.raiderOrder = View.RaiderOrder(guild and guild.ranks)
    roster.stamp = roster.stamp + 1
  end
  return guild
end

local function selectedRow()
  for _, r in ipairs(roster.shown) do if r.guid == roster.selected then return r end end
  return nil
end

-- ---------- This character and Settings ----------

-- This character (View.CHAR): two header bars, the class icon, name, level and the money line, one Kit.ModuleRow per
-- module (View.CharRows) and the Errors row last, the three /gsync buttons at the foot. Row frames come from a pool
-- that only grows (drawChar); placeChar re-places them for the page size and makes no frame.
local function buildCharPage(p, u)
  local C = View.CHAR
  local ch = { page = p, rows = {}, n = 0 }
  ch.header = Kit.HeaderBar(p, "This character", 1)
  ch.recorded = Kit.HeaderBar(p, "What's recorded", 1)
  -- the card (d530): the inset border and a dark fill, the class art on its left; the icon, name, level and money line
  -- are on the card so they draw in front of it (a child frame draws above every region of its parent)
  ch.card = Kit.Inset(p)
  ch.money = ch.card and Kit.MoneyLine(ch.card)
  ch.errors = Kit.ModuleRow(p)
  if not ch.header or not ch.recorded or not ch.card or not ch.money or not ch.errors then return false end
  -- the whole status text, hidden, filled on every Refresh (View.InfoText; tests and module addons read ui.info.text)
  u.info = label(p, "")
  u.info:SetPoint("TOPLEFT", 0, 0)
  u.info:SetJustifyV("TOP")
  u.info:Hide()
  ch.header:SetPoint("TOPLEFT", C.header.x, -C.header.y)
  ch.recorded:SetPoint("TOPLEFT", C.recorded.x, -C.recorded.y)
  local cd, A = ch.card, C.classBg
  cd:SetPoint("TOPLEFT", C.card.x, -C.card.y)
  cd:SetHeight(C.card.h)
  local fill = cd:CreateTexture(nil, "BACKGROUND")
  fill:SetAllPoints(cd)
  fill:SetColorTexture(0, 0, 0, 0.42)
  ch.classBg = cd:CreateTexture(nil, "BACKGROUND", nil, 1) -- the solid part of the class art, above the fill
  ch.classBg:SetPoint("TOPLEFT", A.x, -A.y)
  ch.classBg:SetSize(A.solidW, A.h)
  ch.classFade = cd:CreateTexture(nil, "BACKGROUND", nil, 1) -- the rest, fading out to the right
  ch.classFade:SetPoint("TOPLEFT", A.x + A.solidW, -A.y)
  ch.classFade:SetSize(A.w - A.solidW, A.h)
  -- page numbers (View.CHAR) placed on the card
  local function onCard(f, at) f:SetPoint("TOPLEFT", at.x - C.card.x, -(at.y - C.card.y)) end
  ch.icon = icon(cd, C.icon.size)
  onCard(ch.icon, C.icon)
  ch.name = label(cd, "", "GameFontNormalLarge")
  onCard(ch.name, C.name)
  ch.level = label(cd, "", "GameFontHighlightSmall")
  onCard(ch.level, C.level)
  onCard(ch.money, C.gold)
  u.char = ch

  -- actions: the same functions /gsync calls
  local B = C.buttons
  button(p, "Rescan", B.x[1], 0, function() run(ns.Commands.Scan) end, B.w)
  button(p, "Show errors", B.x[2], 0, function() run(ns.Commands.Errors) end, B.w)
  button(p, "Probe", B.x[3], 0, function() run(ns.Commands.Probe) end, B.w)
  return true
end

local function fillRow(row, data)
  row.name:SetText(data[1])
  row.status:SetText(data[2])
  Kit.SetState(row.mark, data[3], View.STATE_WORD[data[3]])
end

-- Places the rows for the page box L (View.WindowLayout): the first View.RowsThatFit modules, then the Errors row in
-- the next slot; the rest hidden. Widths follow the page width. Makes no frame.
local function placeChar(L)
  local ch = ui and ui.char
  if not ch or type(L) ~= "table" then return end
  local C = View.CHAR
  ch.header:SetWidth(L.contentW)
  ch.recorded:SetWidth(L.contentW)
  ch.card:SetWidth(L.contentW)
  local statusW = L.contentW - C.statusX - C.statusRight
  local fit = View.RowsThatFit(L.contentH, ch.n)
  for i, row in ipairs(ch.rows) do
    Kit.PlaceModuleRow(row, statusW)
    row:SetShown(i <= fit)
  end
  ch.errors:ClearAllPoints()
  ch.errors:SetPoint("TOPLEFT", 0, -(C.rowY + fit * C.rowH))
  Kit.PlaceModuleRow(ch.errors, statusW)
  ch.errors:Show()
end

-- The class art on the card (d530): Kit.ClassBackground sets the atlas on both textures (which resets the tex coords in
-- the game; an unknown class or a missing atlas hides them), then the rows of the art inside the atlas's own coords,
-- split at solidW: classBg the solid part, classFade the rest, faded from alpha 1 to 0 (hidden when it cannot fade).
local function drawClassArt(ch, class)
  local okBg, okFade = Kit.ClassBackground(ch.classBg, class), Kit.ClassBackground(ch.classFade, class)
  if not okBg or not okFade then
    ch.classBg:Hide()
    ch.classFade:Hide()
    return
  end
  local A = View.CHAR.classBg
  local info = Compat.AtlasInfo(Kit.ClassBackgroundAtlas(class))
  if type(info) ~= "table" then return end
  local l, r, t, b = info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord
  if type(l) ~= "number" or type(r) ~= "number" or type(t) ~= "number" or type(b) ~= "number" then return end
  local top, bottom = t + (b - t) * A.top / A.artH, t + (b - t) * A.bottom / A.artH
  local mid = l + (r - l) * A.solidW / A.w
  ch.classBg:SetTexCoord(l, mid, top, bottom)
  ch.classFade:SetTexCoord(mid, r, top, bottom)
  if not Compat.FadeHorizontal(ch.classFade, 1, 0) then ch.classFade:Hide() end
end

-- The character block from ns.Char(): cheap, so Refresh fills it whatever the current page (as ui.info).
local function drawCharBlock()
  local ch = ui and ui.char
  if not ch then return end
  local c = ns.Char()
  local rows = View.CharacterRows(c)
  local class = type(c) == "table" and c.class or nil
  ch.name:SetText(type(c) == "table" and tostring(c.name or "?") or rows[1][2])
  setNameColor(ch.name, class)
  ch.level:SetText(type(c) == "table" and ("Level " .. tostring(c.level or "?")) or "")
  setClassIcon(ch, class, "groupfinder-icon-class-")
  drawClassArt(ch, class)
  local gold = type(c) == "table" and c.gold or nil
  Kit.SetMoney(ch.money, View.MoneyParts(gold), View.Gold(gold))
end

-- The module rows (each module's selftest runs here) and the Errors row; only while the page is current (Refresh).
local function drawChar()
  local ch = ui and ui.char
  if not ch then return end
  local C = View.CHAR
  local list = View.CharRows(ns.modules, Compat.Plain)
  ch.n = 0
  for i, data in ipairs(list) do
    local row = ch.rows[i]
    if not row then
      row = Kit.ModuleRow(ch.page)
      if not row then break end
      row:SetPoint("TOPLEFT", 0, -(C.rowY + (i - 1) * C.rowH))
      ch.rows[i] = row
    end
    fillRow(row, data)
    ch.n = i
  end
  fillRow(ch.errors, View.ErrorsMark(ns.DB().errors))
  placeChar(ui.layout)
end

local function buildSettingsPage(p, u)
  u.minimap = checkbox(p, "Show minimap button", 4, -14, function() run(Window.ToggleMinimap) end)
  -- on the minimap row (d526); a failure here never fails the page
  ns.Safe("Window", function()
    u.crest = checkbox(p, "Show faction crest", 220, -14, function(self)
      run(Window.SetWindowIcon, self:GetChecked() and "crest" or "bag")
    end)
  end)
end

-- ---------- Modules (R7, d407-d409) ----------
-- The suite's addons (View.SuiteRows) in one Kit.List under four column headers; the hub's row sits on a Kit.Card.
-- Plain frames only (nothing protected), so it draws in combat. Row cells hang off the row's right edge, as the
-- Roster's, so recycled rows never need placing again; placeModules sizes the header, column headers and list.
local MOD = { rowH = 52, headerY = 52, listY = 74, sub = { x = 6, y = 32 }, grey = 0.72 }
do -- the columns' offsets from the row's right edge (a row is SuiteLayout's listW wide at any page width)
  local Z = View.SuiteLayout(0)
  MOD.versionX, MOD.stateX, MOD.matesX = Z.version.x - Z.listW + 8, Z.state.x - Z.listW + 8, Z.mates.x - Z.listW + 8
  MOD.lineRight = 52 + Z.lineW - Z.listW
  MOD.versionW = Z.version.w - 8 -- the version text, inside its column (f3352)
end

local function modulesBuildRow(row)
  row.card = Kit.Card(row, 712, 50)
  if row.card then
    row.card:ClearAllPoints()
    row.card:SetPoint("TOPLEFT", 0, -1)
    row.card:SetPoint("TOPRIGHT", 0, -1)
    row.card:Hide()
    local level = row:GetFrameLevel() -- the card draws below the row's icon, texts and hover (f4442)
    if type(level) == "number" then row.card:SetFrameLevel(math.max(0, level - 1)) end
  end
  local edge = row:CreateTexture(nil, "BORDER")
  edge:SetColorTexture(0, 0, 0, 1)
  edge:SetSize(38, 38)
  edge:SetPoint("TOPLEFT", 7, -7)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(36, 36)
  row.icon:SetPoint("TOPLEFT", 8, -8)
  row.name = label(row, "", "GameFontNormal")
  row.name:SetPoint("TOPLEFT", 52, -8)
  row.folder = label(row, "", "GameFontHighlightSmall")
  row.folder:SetPoint("BOTTOMLEFT", row.name, "BOTTOMRIGHT", 6, 0)
  row.line = label(row, "", "GameFontHighlightSmall")
  row.line:SetPoint("TOPLEFT", 52, -24)
  row.line:SetPoint("TOPRIGHT", row, "TOPRIGHT", MOD.lineRight, -24)
  row.line:SetJustifyV("TOP")
  if row.line.SetMaxLines then row.line:SetMaxLines(2) end
  row.version = label(row, "", "GameFontHighlightSmall")
  row.version:SetWidth(MOD.versionW)
  row.version:SetWordWrap(false)
  row.sub = label(row, "", "GameFontHighlightSmall")
  row.sub:SetPoint("TOPLEFT", row, "TOPRIGHT", MOD.versionX, -28)
  row.sub:SetTextColor(MOD.grey, MOD.grey, MOD.grey)
  row.pill = Kit.Pill(row, "", "grey")
  if row.pill then row.pill:SetPoint("TOPLEFT", row, "TOPRIGHT", MOD.stateX, -16) end
  row.count = label(row, "", "GameFontHighlightSmall")
  row.count:SetPoint("TOPLEFT", row, "TOPRIGHT", MOD.matesX, -21)
  Kit.ListHover(row)
  withTooltip(row, function(self)
    local r = self.data
    if type(r) ~= "table" then return nil end
    return { r.name, View.SuiteTooltip(r, ns.API, ns.VERSION) }
  end, function(self) return self.pill end)
end

-- Fills a row; every state-dependent piece is set both ways (frames are recycled). A missing row is dimmed piece by
-- piece (never row:SetAlpha, which would dim the pill too).
local function modulesInitRow(row, r)
  row.data = r
  local dim, g = r.dim == true, r.dim and 0.5 or MOD.grey
  if row.card then row.card:SetShown(r.state == "hub") end
  row.icon:SetTexture(r.icon)
  if row.icon.SetDesaturated then row.icon:SetDesaturated(dim) end
  row.icon:SetAlpha(dim and 0.5 or 1)
  row.name:SetFontObject(dim and "GameFontDisable" or "GameFontNormal")
  row.name:SetText(r.name)
  row.folder:SetText(r.folder or "")
  row.folder:SetTextColor(g, g, g)
  row.folder:SetShown(r.folder ~= r.name)
  row.line:SetFontObject(dim and "GameFontDisableSmall" or "GameFontHighlightSmall")
  row.line:SetText(r.line or "")
  row.version:SetFontObject(dim and "GameFontDisableSmall" or "GameFontHighlightSmall")
  row.version:SetText(r.version or "")
  row.version:ClearAllPoints()
  row.version:SetPoint("TOPLEFT", row, "TOPRIGHT", MOD.versionX, r.sub and -14 or -21)
  row.sub:SetText(r.sub or "")
  row.sub:SetShown(r.sub ~= nil)
  Kit.SetPill(row.pill, r.pill, r.tone)
  row.count:SetFontObject(r.count == 0 and "GameFontDisableSmall" or "GameFontHighlightSmall")
  row.count:SetText(tostring(r.count) .. " of " .. tostring(ui and ui.modules and ui.modules.total or 0))
end

-- Throws on a missing piece, so the ns.Safe around it records the failure under Window and build() hides the row.
local function buildModulesPage(p, u)
  local m = { page = p, headers = {} }
  m.header = Kit.HeaderBar(p, "Modules", 1)
  if not m.header then error("Modules: no header bar") end
  m.header:SetPoint("TOPLEFT", 0, 0)
  m.sub = label(p, View.SUITE_SUBLINE, "GameFontHighlightSmall")
  m.sub:SetPoint("TOPLEFT", MOD.sub.x, -MOD.sub.y)
  m.sub:SetTextColor(MOD.grey, MOD.grey, MOD.grey)
  for i, text in ipairs(View.SUITE_COLUMNS) do
    m.headers[i] = Kit.ColumnHeader(p, text)
    if not m.headers[i] then error("Modules: no column header") end
  end
  withTooltip(m.headers[4], function() return View.SUITE_MATES_TIP end)
  m.list = Kit.List(p, MOD.rowH, modulesBuildRow, modulesInitRow)
  if not m.list then
    -- no ScrollBox templates on this client: the rows stacked on the page (six fit at the minimum size; kept for clients
    -- without the ScrollBox templates, as other hub pages keep theirs)
    local content = Compat.CreateFrame("Frame", nil, p)
    if not content then error("Modules: no list") end
    content:SetPoint("TOPLEFT", 0, -MOD.listY)
    content:SetPoint("TOPRIGHT", 0, -MOD.listY)
    content:SetHeight(1)
    local pool = {}
    m.list = { content = content }
    function m.list.SetRows(_, rows)
      for i, r in ipairs(rows) do
        local row = pool[i]
        if not row then
          row = Compat.CreateFrame("Button", nil, content)
          if not row then return end
          row:SetHeight(MOD.rowH)
          row:SetPoint("TOPLEFT", 0, -(i - 1) * MOD.rowH)
          row:SetPoint("TOPRIGHT", 0, -(i - 1) * MOD.rowH)
          modulesBuildRow(row)
          pool[i] = row
        end
        modulesInitRow(row, r)
        row:Show()
      end
      for i = #rows + 1, #pool do pool[i]:Hide() end
    end
  end
  u.modules = m
end

-- Sizes the header, column headers and list for the page box L (View.WindowLayout). Makes no frame.
local function placeModules(m, L)
  local S = View.SuiteLayout(L.contentW)
  m.header:SetWidth(L.contentW)
  m.sub:SetWidth(L.contentW - 2 * MOD.sub.x) -- follows the page width (f3403)
  for i, key in ipairs({ "name", "version", "state", "mates" }) do
    local h = m.headers[i]
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", S[key].x, -MOD.headerY)
    h:SetWidth(S[key].w)
  end
  if not m.list.box then return end -- the stacked fallback is anchored once, in buildModulesPage
  m.list.box:ClearAllPoints()
  m.list.box:SetPoint("TOPLEFT", 0, -MOD.listY)
  m.list.box:SetPoint("BOTTOMRIGHT", S.listW - L.contentW, 0)
  m.list.bar:ClearAllPoints()
  m.list.bar:SetPoint("TOPLEFT", m.list.box, "TOPRIGHT", S.barX - S.listW, 0)
  m.list.bar:SetPoint("BOTTOMLEFT", m.list.box, "BOTTOMRIGHT", S.barX - S.listW, 0)
end

-- The rows, from this client's addons; Guildmates from the adverts, or in demo only from DemoGuild.SUITE_HEARD (d408).
local function drawModules()
  local m = ui and ui.modules
  if not m then return end
  local heard
  if demoOn() then
    local guild = source()
    local total = type(guild) == "table" and tonumber(guild.count) or 0
    heard = { total = total }
    for id, n in pairs(ns.DemoGuild and ns.DemoGuild.SUITE_HEARD or {}) do heard[id] = math.min(n, total) end
  elseif ns.Comm and ns.Comm.Version and ns.Comm.Roster then
    heard = View.SuiteHeard(ns.Comm.Version.Versions(), (ns.Comm.Roster()), Compat.ServerTime())
  else
    heard = { total = 0 }
  end
  m.total = heard.total
  m.list:SetRows(View.SuiteRows(ns.SUITE, Compat.AddOn, ns.NeedsNewer, heard), true)
end

-- ---------- officer actions (0.9) ----------
-- The Roster side panel's Promote, Demote, Remove from guild and Edit notes. View decides who sees which button
-- (View.MemberActions); a button this character may not use is hidden. Each click makes at most one client call,
-- from its own click handler. Remove asks first in a small window. After a rank change
-- or a removal no other one can run until the roster shows it, or View.CONFIRM_SECONDS pass and a line says it did not.

local confirm, notes

local function rowByGuid(guid)
  if guid == nil then return nil end
  for _, r in ipairs(roster.all) do if r.guid == guid then return r end end
  return nil
end

local function movePending()
  for _, p in ipairs(acting.pending) do if p.kind ~= "public" and p.kind ~= "officer" then return true end end
  return false
end

-- For a member row: the line that stops every action now (or nil) and what this character may do.
-- forNotes: a pending rank change does not hold up a note.
local function actionsFor(r, forNotes)
  local guild = roster.guild
  local _, _, perms = source()
  local acts = View.MemberActions(perms, r, guild and type(guild.ranks) == "table" and #guild.ranks or nil)
  acts.notes = acts.editPublic or (acts.editOfficer and guild ~= nil and guild.canSeeOfficerNotes == true)
  local block = View.ActionBlock({ own = guild ~= nil and guild.by == ns.CharKey(), partial = guild ~= nil and guild.partial,
    combat = Compat.InCombat() or Compat.EncounterRestricted(), pending = not forNotes and movePending() })
  return block, acts
end

-- Read the roster now, and the next roster event at once (past the throttle).
local function rescan()
  if not ns.Roster then return end
  ns.Roster.ScanNow()
  ns.Roster.ExpectChange()
end

-- The member a click is for, looked up again, with what may be done now; nil after a line saying why not.
-- A rank change or removal also reads the member's rank in game now: when it is not the recorded one, or cannot be
-- read, no call is made and the roster is read again. With the two equal, every rule (this character's permission
-- and own rank, both read now in Compat.GuildPermissions; not at or above that rank; a promote stays below it) has
-- been checked against the live rank.
-- In demo every click on a member says the inert line and does nothing (no client call, no window).
local function demoInert()
  if not demoOn() then return false end
  ns.Say(ns.Demo.LINES.inert)
  return true
end

local GONE_LINE = "that member is not in the recorded roster any more."

local function clickTarget(guid, forNotes)
  if demoInert() then return nil end -- first: also stops a confirm or notes window opened before demo turned on
  local r = rowByGuid(guid)
  if not r then ns.Say(GONE_LINE) return nil end
  local block, acts = actionsFor(r, forNotes)
  if block then ns.Say(block) return nil end
  if not forNotes then
    local live = Compat.GuildRankIndex(r.guid)
    if live ~= r.rankOrder then
      ns.Say(live == nil and View.RankUnreadLine(r.name) or View.RankChangedLine(r.name))
      rescan()
      Window.Refresh()
      return nil
    end
  end
  return r, acts
end

-- After a call: remember it, ask for the roster, say what was done, and check in CONFIRM_SECONDS.
local function started(p, line)
  table.insert(acting.pending, p)
  if ns.Roster then ns.Roster.ExpectChange() end
  ns.Say(line)
  ns.After(View.CONFIRM_SECONDS, function()
    if ns.Roster then ns.Roster.ScanNow() end
    -- after a failure line the next roster event is read at once, so a late change still shows within seconds
    if checkPending(p) and ns.Roster then ns.Roster.ExpectChange() end
    Window.Refresh()
  end, "Window")
  Window.Refresh()
end

local function rankName(i)
  local ranks = roster.guild and roster.guild.ranks
  return type(ranks) == "table" and ranks[i + 1] or ("rank " .. (i + 1))
end

-- One Promote or Demote call for row r, to rank index newIndex. The call takes the name with realm as the client
-- gives it now; the recorded name (realm cut) is only for the lines.
local function moveRank(r, kind, newIndex)
  local called
  local who = Compat.FullName(r.guid) or r.name
  if kind == "promote" then called = Compat.GuildPromote(who) else called = Compat.GuildDemote(who) end
  if not called then ns.Say("this client did not take the " .. kind .. " call.") return end
  started({ kind = kind, guid = r.guid, name = r.name, rankOrder = newIndex }, View.ActionLine(kind, r.name, rankName(newIndex)))
end

-- Promote or Demote for the member guid (the panel's selection or the right-clicked row; never filled in).
local function onRankButton(kind, guid)
  local r, acts = clickTarget(guid)
  if not r then return end
  if not acts[kind] then ns.Say(View.NOT_YOURS) return end
  moveRank(r, kind, r.rankOrder + (kind == "promote" and -1 or 1))
end

local function buildConfirm()
  local f = Kit.Dialog("GuildSyncConfirm", 340, 120) -- Escape hides it: the same as Cancel
  if not f then return nil end
  f.title:SetText("GuildSync")
  f.question = label(f, "", "GameFontHighlight")
  f.question:SetPoint("TOPLEFT", 14, -34)
  f.question:SetWidth(312)
  f.remove = button(f, "Remove", -14, 12, safely(function()
    f:Hide()
    local r, acts = clickTarget(f.guid)
    if not r then return end
    if not acts.remove then ns.Say(View.NOT_YOURS) return end
    if not Compat.GuildRemove(r.guid) then ns.Say("this client did not take the remove call.") return end
    started({ kind = "remove", guid = r.guid, name = r.name }, View.ActionLine("remove", r.name))
  end), 100, "BOTTOMRIGHT")
  f.cancel = button(f, "Cancel", 14, 12, function() f:Hide() end, 100)
  f:Hide()
  return f
end

-- "Remove from guild" for the member guid: the confirm window only; its Remove button makes the call.
function Window.AskRemove(guid)
  if demoInert() then return end
  local r = rowByGuid(guid)
  if not r then ns.Say(GONE_LINE) return end
  local block, acts = actionsFor(r)
  if block then ns.Say(block) return end
  if not acts.remove then ns.Say(View.NOT_YOURS) return end
  if not confirm then confirm = buildConfirm() end
  if not confirm then ns.Say("could not open the confirm window on this client.") return end
  confirm.guid = r.guid
  confirm.question:SetText(View.RemoveQuestion(r.name))
  confirm:Show()
end

-- The boxes' notes (a typed "|" counts once), each only when its box is shown.
local function editedNotes(f)
  return { public = f.public:IsShown() and View.NoteFromBox(f.public:GetText()) or nil,
    officer = f.officer:IsShown() and View.NoteFromBox(f.officer:GetText()) or nil }
end

-- "Save public note" / "Save officer note": one SetNote call for that note only. The window stays open while the
-- other note still has an unsaved change.
local function saveNote(isPublic)
  local f = notes
  local key = isPublic and "public" or "officer"
  local r, acts = clickTarget(f.guid, true)
  if not r then return end
  local allowed
  if isPublic then allowed = f.can.editPublic and acts.editPublic else allowed = f.can.editOfficer and acts.editOfficer end
  if not allowed then ns.Say(View.NOT_YOURS) return end
  local edited = editedNotes(f)
  local changes, why = View.NoteChanges(f.saved, { [key] = edited[key] }, { editPublic = isPublic, editOfficer = not isPublic })
  if not changes then
    f.result:SetText(why)
    ns.Say(why)
    return
  end
  local c = changes[1]
  if not c then
    f.result:SetText("The " .. key .. " note did not change.")
    return
  end
  if not Compat.GuildSetNote(r.guid, c.note, c.isPublic) then ns.Say("this client did not take the note call.") return end
  f.saved[key] = c.note
  started({ kind = key, guid = r.guid, name = r.name, note = c.note }, View.ActionLine(key, r.name))
  local rest = View.NoteChanges(f.saved, edited, f.can)
  if rest == nil or #rest > 0 then -- the other note changed (or is too long): keep it on screen
    f.result:SetText((isPublic and "Public" or "Officer") .. " note saved. The other note is not saved yet.")
  else
    f:Hide()
  end
end

local function noteBox(f, text, y)
  local l = label(f, text, "GameFontNormalSmall")
  l:SetPoint("TOPLEFT", 16, y)
  local box = Kit.InputBox(f, 336, 300)
  if not box then return nil end
  box:SetPoint("TOPLEFT", 22, y - 14)
  box:SetAutoFocus(false)
  -- no SetMaxLetters: the box counts a typed "|" as two; Save checks View.NOTE_MAX letters (View.CleanNote)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  box.label = l
  return box
end

local function showBox(box, on)
  if on then box:Show() box.label:Show() else box:Hide() box.label:Hide() end
end

local function buildNotes()
  local f = Kit.Dialog("GuildSyncNotes", 380, 180)
  if not f then return nil end
  f.saved, f.can = {}, {}
  f.public = noteBox(f, "Public note", -32)
  f.officer = noteBox(f, "Officer note", -76)
  if not f.public or not f.officer then return nil end
  f.result = label(f, "", "GameFontHighlightSmall")
  f.result:SetPoint("BOTTOMLEFT", 14, 42)
  f.result:SetWidth(352)
  f.saveOfficer = button(f, "Save officer note", -14, 12, safely(function() saveNote(false) end), 130, "BOTTOMRIGHT")
  f.savePublic = button(f, "Save public note", -150, 12, safely(function() saveNote(true) end), 130, "BOTTOMRIGHT")
  f.cancel = button(f, "Cancel", 14, 12, function() f:Hide() end, 80)
  if not f.savePublic or not f.saveOfficer then return nil end
  f:Hide()
  return f
end

-- "Edit notes": the notes of the member guid in two boxes (each only when this character may edit it).
function Window.OpenNotes(guid)
  if demoInert() then return end
  local r = rowByGuid(guid)
  if not r then ns.Say(GONE_LINE) return end
  local block, acts = actionsFor(r, true)
  if block then ns.Say(block) return end
  if not acts.notes then ns.Say(View.NOT_YOURS) return end
  if not notes then notes = buildNotes() end
  if not notes then ns.Say("could not open the notes window on this client.") return end
  local f = notes
  f.guid = r.guid
  f.saved = { public = r.note or "", officer = r.officerNote or "" }
  f.can = { editPublic = acts.editPublic, editOfficer = acts.editOfficer and roster.guild.canSeeOfficerNotes == true }
  f.title:SetText("Notes for " .. r.name)
  f.public:SetText(View.NoteToBox(f.saved.public))
  f.officer:SetText(View.NoteToBox(f.saved.officer))
  showBox(f.public, f.can.editPublic)
  showBox(f.officer, f.can.editOfficer)
  if f.can.editPublic then f.savePublic:Show() else f.savePublic:Hide() end
  if f.can.editOfficer then f.saveOfficer:Show() else f.saveOfficer:Hide() end
  f.result:SetText("")
  f:Show()
end

local ACTIONS = { { key = "promote", text = "Promote" }, { key = "demote", text = "Demote" },
  { key = "remove", text = "Remove from guild" }, { key = "notes", text = "Edit notes" } }

-- What may be done to row sel now, in the panel's order (entries of ACTIONS), and the line when nothing may.
local function shownActions(sel)
  local block, acts = actionsFor(sel)
  if not (acts.promote or acts.demote or acts.remove or acts.notes) then return {}, View.NOT_YOURS end
  if block then return {}, block end
  local out = {}
  for _, a in ipairs(ACTIONS) do if acts[a.key] then table.insert(out, a) end end
  return out, ""
end

-- One action for the member guid, as its panel button does it (called from the button or the menu pick).
local function runAction(key, guid)
  if key == "remove" then Window.AskRemove(guid)
  elseif key == "notes" then Window.OpenNotes(guid)
  else onRankButton(key, guid) end
end

-- The side panel's buttons for the selected row: only those this character may use now, stacked bottom up;
-- else one line (Not yours to change, or why not now).
local function drawActions(d, sel)
  local shown, line = {}, ""
  if sel then
    local acts
    acts, line = shownActions(sel)
    for _, a in ipairs(acts) do
      if d.byAction[a.key] then table.insert(shown, d.byAction[a.key]) end
    end
  end
  for _, b in ipairs(d.actionButtons) do b:Hide() end
  for i, b in ipairs(shown) do
    b:ClearAllPoints()
    b:SetPoint("BOTTOMLEFT", 8, 8 + (#shown - i) * (BUTTON_H + 4))
    b:Show()
  end
  d.actionLine:SetText(line)
  return #shown
end

local function buildActions(d)
  local w = View.DETAIL_W - 16
  d.byAction, d.actionButtons = {}, {}
  for _, a in ipairs(ACTIONS) do
    -- the selection is read at click time and passed as the guid
    local b = button(d, a.text, 8, 8, safely(function() runAction(a.key, roster.selected) end), w)
    if b then
      b:Hide()
      d.byAction[a.key] = b
      table.insert(d.actionButtons, b)
    end
  end
  d.promote, d.demote, d.remove, d.notesButton = d.byAction.promote, d.byAction.demote, d.byAction.remove, d.byAction.notes
  d.actionLine = label(d, "", "GameFontDisableSmall")
  d.actionLine:SetPoint("BOTTOMLEFT", 8, 10)
  d.actionLine:SetWidth(w)
end

-- The officer action windows and what is waiting for the roster. For the tests.
function Window.ConfirmFrame() return confirm end
function Window.NotesFrame() return notes end
function Window.Acting() return acting end

-- ---------- Overview page ----------
-- Blocks from View.OverviewLayout: the counts strip, the class mix bar and its chips, two columns (Online now,
-- Professions covered) and the guild log, drawn with Forever's own pieces through the Kit. Every frame is made in
-- buildOverview (the chips on their first draw); a resize only re-places them (relayout).

local OL = View.OverviewLayout(0) -- the block tops and sizes (logShown is worked out per size in relayout)
local ROW_TOP = OL.rows - OL.cols -- a block's rows start this far below its top (under the 26-px header)
local MIX_SLOTS = 13 -- class mix segments built up front, one per class the client can have; more are not drawn
local PROF_SCALE = 0.65 -- the profession bars are the class mix bar at this scale
local PROF_BAR_X, PROF_BAR_RIGHT = 130, 40 -- the profession bar runs from x 130 to colW - 40 (page units)
local CHIP_GAP = 14
local AMBER, GREEN = { 0.8, 0.6, 0.2 }, { 0.25, 0.7, 0.25 }
local DIVIDER_BG = { 1, 1, 1, 0.15 }

-- Width of a profession bar in its own (scaled) units.
local function profBarW(L) return (L.colW - PROF_BAR_RIGHT - PROF_BAR_X) / PROF_SCALE end

local function mixLines(c)
  return { c.name, c.count .. (c.count == 1 and " member" or " members") .. " at " .. View.MAX_LEVEL }
end

-- Class mix segments in the bar's 15-px fill line (STAT_INSET in from each end), 1 px apart, widths over what the
-- gaps leave.
local function placeSegments(o)
  local mix = o.mix or {}
  local n = math.min(#mix, #o.segs)
  local fillW = ui.layout.contentW - OL.barX - 2 * Kit.STAT_INSET - math.max(n - 1, 0)
  local widths = View.SegmentWidths({ unpack(mix, 1, n) }, fillW)
  local x = 0
  for i = 1, n do
    local s, w = o.segs[i], widths[i] or 0
    s:ClearAllPoints()
    s:SetPoint("TOPLEFT", x, 0)
    s:SetSize(w, OL.fillH)
    if w > 0 then s:Show() else s:Hide() end
    x = x + w + 1
  end
  for i = n + 1, #o.segs do o.segs[i]:Hide() end
end

-- One chip per class below the bar, 14 px apart; chips past the page's right edge hide.
local function placeChips(o)
  local x = 0
  for i, chip in ipairs(o.chips) do
    if chip.used then
      chip:ClearAllPoints()
      chip:SetPoint("TOPLEFT", x, -OL.chips)
      chip:SetShown(x + chip.w <= ui.layout.contentW)
      x = x + chip.w + CHIP_GAP
    else
      chip:Hide()
    end
  end
end

local function chipFrame(o, i)
  local chip = o.chips[i]
  if chip then return chip end
  chip = Compat.CreateFrame("Frame", nil, o.panel)
  if not chip then return nil end
  chip:SetHeight(18)
  chip.icon = icon(chip, 18)
  chip.icon:SetPoint("LEFT", 0, 0)
  chip.iconClass = false
  chip.label = label(chip, "", "GameFontHighlightSmall")
  chip.label:SetPoint("LEFT", 22, 0)
  chip.lines = false
  chip.w = 0
  withTooltip(chip, function(self) return self.lines end)
  o.chips[i] = chip
  return chip
end

local function drawMix(o, rows)
  o.mix = View.ClassMix(rows)
  for i, c in ipairs(o.mix) do
    local s = o.segs[i]
    if s then
      local r, g, b = Compat.ClassColor(c.class)
      if not r then r, g, b = 0.5, 0.5, 0.5 end
      s.tex:SetVertexColor(r, g, b)
      s.lines = mixLines(c)
    end
    local chip = chipFrame(o, i)
    if chip then
      setClassIcon(chip, c.class, "groupfinder-icon-class-")
      chip.label:SetText(c.name .. " " .. c.count)
      local sw = chip.label:GetStringWidth()
      chip.w = 22 + ((type(sw) == "number" and sw > 0) and math.ceil(sw) or 7 * #chip.label:GetText())
      chip:SetWidth(chip.w)
      chip.lines = mixLines(c)
      chip.used = true
    end
  end
  for i = #o.mix + 1, #o.chips do o.chips[i].used = false end
  placeSegments(o)
  placeChips(o)
end

-- A row of a column or of the log block: 20 tall, from 30 below the block's top (under its 26-px header).
local function blockRow(kind, parent, i)
  local f = Compat.CreateFrame(kind, nil, parent)
  if not f then return nil end
  local y = -ROW_TOP - (i - 1) * OL.rowH
  f:SetHeight(OL.rowH)
  f:SetPoint("TOPLEFT", 0, y)
  f:SetPoint("TOPRIGHT", 0, y)
  f.icon = icon(f, 16)
  f.icon:SetPoint("LEFT", 4, 0)
  return f
end

local function onlineRow(parent, i)
  local f = blockRow("Button", parent, i)
  if not f then return nil end
  local hl = f:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(f)
  if not Kit.Atlas(hl, "common-list-hoverbg-mid", HIGHLIGHT) then hl:SetBlendMode("ADD") end
  f.iconClass = false
  f.nameText = label(f, "", "GameFontHighlightSmall")
  f.nameText:SetPoint("LEFT", 26, 0)
  f.nameText:SetWidth(120)
  f.nameText:SetWordWrap(false)
  f.rank = label(f, "", "GameFontHighlightSmall")
  f.rank:SetPoint("LEFT", 150, 0)
  f.rank:SetWidth(98)
  f.rank:SetWordWrap(false)
  f.zone = label(f, "", "GameFontDisableSmall")
  f.zone:SetPoint("LEFT", 252, 0)
  f.zone:SetPoint("RIGHT", -4, 0)
  f.zone:SetWordWrap(false)
  f.member = false
  f:SetScript("OnClick", safely(function(self) if self.member then Window.OpenMember(self.member) end end))
  return f
end

local function professionRow(parent, i)
  local f = blockRow("Frame", parent, i)
  if not f then return nil end
  f.nameText = label(f, "", "GameFontHighlightSmall")
  f.nameText:SetPoint("LEFT", 26, 0)
  f.nameText:SetWidth(100)
  f.nameText:SetWordWrap(false)
  f.count = label(f, "", "GameFontHighlightSmall")
  f.count:SetPoint("RIGHT", -4, 0)
  f.count:SetWidth(30)
  f.count:SetJustifyH("RIGHT")
  -- The class mix bar at 0.65: its offsets are in its own scaled units, so divided by the scale.
  local bar = Kit.StatBar(f, PROF_SCALE)
  if not bar then return nil end
  bar:SetPoint("LEFT", PROF_BAR_X / PROF_SCALE, 0)
  f.bar = bar
  f.fill = (bar.fill or bar):CreateTexture(nil, "ARTWORK")
  f.fill:SetPoint("TOPLEFT", 0, 0)
  f.fill:SetPoint("BOTTOMLEFT", 0, 0)
  Kit.Atlas(f.fill, "common-stat-bar-white", BAR_TEXTURE)
  Kit.Mask(bar, { f.fill }, "common-stat-bar-Mask")
  f.frac = 0
  -- The text at normal size: on a frame of the row above the bar, centred on the bar.
  local over = Compat.CreateFrame("Frame", nil, f)
  if over then
    over:SetAllPoints(f)
    local level = bar:GetFrameLevel()
    if type(level) == "number" then over:SetFrameLevel(level + 2) end
  end
  f.barText = label(over or f, "", "GameFontHighlightSmall")
  f.barText:SetPoint("CENTER", bar, "CENTER", 0, 0)
  f.lines = false
  withTooltip(f, function(self) return self.lines end)
  return f
end

local function placeFill(f, L)
  local w = (profBarW(L) - 2 * Kit.STAT_INSET) * f.frac -- the fill line, inside the track
  if w > 0 then
    f.fill:SetWidth(w)
    f.fill:Show()
  else
    f.fill:SetWidth(0)
    f.fill:Hide()
  end
end

local function logRow(parent, i)
  local f = blockRow("Frame", parent, i)
  if not f then return nil end
  f.text = label(f, "", "GameFontHighlightSmall")
  f.text:SetPoint("LEFT", 26, 0)
  f.text:SetPoint("RIGHT", -72, 0)
  f.text:SetWordWrap(false)
  f.age = label(f, "", "GameFontDisableSmall")
  f.age:SetPoint("RIGHT", -4, 0)
  f.age:SetWidth(66)
  f.age:SetJustifyH("RIGHT")
  return f
end

local function buildOverview(p, u)
  local o = { panel = p, cells = {}, dividers = {}, segs = {}, chips = {}, online = {}, profs = {}, log = {}, mix = {} }
  u.overview = o

  -- the counts strip: one stone texture, four cells, three dividers
  local strip = Compat.CreateFrame("Frame", nil, p)
  if not strip then return false end
  strip:SetPoint("TOPLEFT", 0, -OL.strip)
  strip:SetPoint("TOPRIGHT", 0, -OL.strip)
  strip:SetHeight(OL.stripH)
  local stone = strip:CreateTexture(nil, "BACKGROUND")
  stone:SetAllPoints(strip)
  Kit.Atlas(stone, "groupfinder-Stat-StoneBG", PANEL_BG)
  o.strip = strip
  for i = 1, 4 do
    local t = Compat.CreateFrame("Frame", nil, strip)
    if t then
      t:SetHeight(OL.stripH)
      t.value = label(t, "", "GameFontHighlightHuge")
      t.value:SetPoint("TOP", 0, -9)
      t.label = label(t, "", "GameFontNormalSmall")
      t.label:SetPoint("TOP", 0, -35)
      t.lines = false
      withTooltip(t, function(self) return self.lines end)
      o.cells[i] = t
    end
  end
  for k = 1, 3 do
    local d = strip:CreateTexture(nil, "ARTWORK")
    d:SetSize(11, 50)
    Kit.Atlas(d, "common-framedivider", DIVIDER_BG)
    o.dividers[k] = d
  end

  -- the class mix: the title left of the bar, the segments in its fill line under one mask
  o.bar = Kit.StatBar(p, 1)
  if not o.bar then return false end
  o.bar:SetPoint("TOPLEFT", OL.barX, -OL.mix)
  o.bar:SetPoint("TOPRIGHT", 0, -OL.mix)
  o.mixTitle = label(p, "Class mix at " .. View.MAX_LEVEL, "GameFontNormal")
  o.mixTitle:SetPoint("LEFT", o.bar, "LEFT", -OL.barX, 0)
  local textures = {}
  for i = 1, MIX_SLOTS do
    local s = Compat.CreateFrame("Frame", nil, o.bar.fill or o.bar)
    if not s then break end
    s.tex = s:CreateTexture(nil, "ARTWORK")
    s.tex:SetAllPoints(s)
    Kit.Atlas(s.tex, "common-stat-bar-white", BAR_TEXTURE)
    s.lines = false
    withTooltip(s, function(self) return self.lines end)
    s:Hide()
    o.segs[i] = s
    textures[i] = s.tex
  end
  Kit.Mask(o.bar, textures, "common-stat-bar-Mask")

  -- two columns under their header bars
  local left = Compat.CreateFrame("Frame", nil, p)
  local right = Compat.CreateFrame("Frame", nil, p)
  if not left or not right then return false end
  local colH = ROW_TOP + math.max(View.ONLINE_LIMIT, View.PROF_LIMIT) * OL.rowH + 16
  left:SetPoint("TOPLEFT", 0, -OL.cols)
  left:SetHeight(colH)
  right:SetPoint("TOPLEFT", left, "TOPRIGHT", GAP, 0)
  right:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -OL.cols)
  right:SetHeight(colH)
  o.left = left

  o.onlineHeader = Kit.HeaderBar(left, "Online now", 1)
  if not o.onlineHeader then return false end
  o.onlineHeader:SetPoint("TOPLEFT", 0, 0)
  for i = 1, View.ONLINE_LIMIT do o.online[i] = onlineRow(left, i) end
  o.onlineMore = label(left, "", "GameFontDisableSmall")
  o.onlineEmpty = label(left, "", "GameFontDisableSmall")
  o.onlineEmpty:SetPoint("TOPLEFT", 4, -ROW_TOP - 2)

  o.profHeader = Kit.HeaderBar(right, "Professions covered", 1)
  if not o.profHeader then return false end
  o.profHeader:SetPoint("TOPLEFT", 0, 0)
  for i = 1, View.PROF_LIMIT do o.profs[i] = professionRow(right, i) end
  o.profMore = label(right, "", "GameFontDisableSmall")
  o.profEmpty = label(right, "", "GameFontDisableSmall")
  o.profEmpty:SetPoint("TOPLEFT", 4, -ROW_TOP - 2)

  -- the guild log: hidden as a whole when the page is too short for it (relayout)
  local logBlock = Compat.CreateFrame("Frame", nil, p)
  if not logBlock then return false end
  logBlock:SetPoint("TOPLEFT", 0, -OL.logHeader)
  logBlock:SetPoint("TOPRIGHT", 0, -OL.logHeader)
  logBlock:SetHeight(OL.need - OL.logHeader)
  o.logBlock = logBlock
  o.logHeader = Kit.HeaderBar(logBlock, "Recent in the guild log", 1)
  if not o.logHeader then return false end
  o.logHeader:SetPoint("TOPLEFT", 0, 0)
  for i = 1, View.LOG_LIMIT do o.log[i] = logRow(logBlock, i) end
  o.logEmpty = label(logBlock, "", "GameFontDisableSmall")
  o.logEmpty:SetPoint("TOPLEFT", 4, -ROW_TOP - 2)
  return true
end

-- Redraws the Overview. Skipped when neither the roster nor the guild log changed since the last draw, unless the
-- page was just opened (o.stamp cleared).
function Window.DrawOverview()
  local o = ui and ui.overview
  if not o then return end
  local guild = syncRows()
  local _, log = source()
  if o.stamp == roster.stamp and o.logTable == log then return end
  o.stamp, o.logTable = roster.stamp, log
  local rows = roster.all

  for i, tile in ipairs(View.StatTiles(rows, guild and guild.ranks)) do
    local t = o.cells[i]
    if t then
      t.value:SetText(View.TileValue(tile))
      t.label:SetText(tile.label)
      t.lines = { tile.label, tile.hint }
    end
  end

  drawMix(o, rows)

  local online, more = View.OnlineList(rows, View.ONLINE_LIMIT)
  for i = 1, View.ONLINE_LIMIT do
    local f, r = o.online[i], online[i]
    if f and r then
      f.member = r.guid
      setClassIcon(f, r.class, "groupfinder-icon-class-")
      f.nameText:SetText(r.name)
      setNameColor(f.nameText, r.class)
      f.rank:SetText(r.rank or "?")
      local c = View.TIER_TEXT[View.RankTier(r.rankOrder, roster.raiderOrder)]
      f.rank:SetTextColor(c[1], c[2], c[3])
      f.zone:SetText(r.zone or "")
      f:Show()
    elseif f then
      f.member = false
      f.nameText:SetText("") -- a hidden row keeps no name from an earlier draw (a demo name after /gsync demo off)
      f.zone:SetText("")
      f:Hide()
    end
  end
  o.onlineMore:ClearAllPoints()
  o.onlineMore:SetPoint("TOPLEFT", 4, -ROW_TOP - #online * OL.rowH)
  o.onlineMore:SetText(View.MoreText(more))
  o.onlineEmpty:SetText(#online == 0 and View.NOBODY_ONLINE or "")

  local profs = View.ProfessionsCovered(rows)
  for i = 1, View.PROF_LIMIT do
    local f, p = o.profs[i], profs[i]
    if f and p then
      Compat.SetIcon(f.icon, p.icon, View.IsGameIcon(p.icon))
      f.nameText:SetText(p.name)
      f.count:SetText(tostring(p.count))
      f.barText:SetText(p.barText)
      f.frac = math.min(p.bar, View.PROF_TARGET) / View.PROF_TARGET
      local c = p.bar >= View.PROF_TARGET and GREEN or AMBER
      f.fill:SetVertexColor(c[1], c[2], c[3])
      placeFill(f, ui.layout)
      f.lines = View.ProfessionTooltip(p)
      f:Show()
    elseif f then
      f.lines = false
      f:Hide()
    end
  end
  local shownProfs = math.min(#profs, View.PROF_LIMIT)
  o.profMore:ClearAllPoints()
  o.profMore:SetPoint("TOPLEFT", 4, -ROW_TOP - shownProfs * OL.rowH)
  o.profMore:SetText(View.MoreText(#profs - shownProfs))
  o.profEmpty:SetText(#profs == 0 and View.NO_PROFESSIONS or "")

  local entries = View.RecentLog(log, time(), View.LOG_LIMIT)
  for i = 1, View.LOG_LIMIT do
    local f, e = o.log[i], entries[i]
    if f and e then
      Compat.SetIcon(f.icon, e.icon, View.IsGameIcon(e.icon))
      f.text:SetText(e.text)
      f.age:SetText(e.age)
      f:Show()
    elseif f then
      f.text:SetText("")
      f.age:SetText("")
      f:Hide()
    end
  end
  o.logEmpty:SetText(#entries == 0 and View.LOG_EMPTY or "")
end

-- Re-places the Overview's blocks for the layout L (a resize). Makes no frame.
local function placeOverview(o, L)
  for i = 1, 4 do
    local t = o.cells[i]
    if t then
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", (i - 1) * L.cellW, 0)
      t:SetWidth(L.cellW)
    end
  end
  for k, d in ipairs(o.dividers) do
    d:ClearAllPoints()
    d:SetPoint("TOPLEFT", L.cellW * k - 5.5, -(OL.stripH - 50) / 2)
  end
  o.left:SetWidth(L.colW)
  o.onlineHeader:SetWidth(L.colW)
  o.profHeader:SetWidth(L.colW)
  o.logHeader:SetWidth(L.contentW)
  for _, f in ipairs(o.profs) do
    f.bar:SetWidth(profBarW(L))
    placeFill(f, L)
  end
  placeSegments(o)
  placeChips(o)
  o.logBlock:SetShown(View.OverviewLayout(L.contentH).logShown)
end

-- What the Overview shows now (its frames). For the tests.
function Window.OverviewState() return ui and ui.overview end

-- ---------- Roster page ----------

-- Cells hang off the row's right edge, so a wider window only widens the name.
local function placeCells(row)
  local c = View.ROW_COLS
  local right = c.rank + c.level + c.last
  row.nameText:ClearAllPoints()
  row.nameText:SetPoint("LEFT", c.icon + 4, 0)
  row.nameText:SetPoint("RIGHT", row, "RIGHT", -right - 4, 0)
  row.badge.text:ClearAllPoints()
  row.badge.text:SetPoint("LEFT", row, "RIGHT", -right + 8, 0)
  row.level:ClearAllPoints()
  row.level:SetPoint("LEFT", row, "RIGHT", -(c.level + c.last) + 4, 0)
  row.last:ClearAllPoints()
  row.last:SetPoint("LEFT", row, "RIGHT", -c.last + 4, 0)
end

local rowClicked -- (guid, button), set after drawDetail

local function rowFrame(r, i)
  local row = r.pool[i]
  if row then return row end
  row = Compat.CreateFrame("Button", nil, r.content)
  if not row then return nil end
  local y = -(i - 1) * ROW_H
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", 0, y)
  row:SetPoint("TOPRIGHT", 0, y)
  row:SetHighlightTexture(HIGHLIGHT, "ADD")
  local c = View.ROW_COLS
  row.icon = icon(row, 16)
  row.icon:SetPoint("LEFT", 2, 0)
  row.iconClass = false
  row.nameText = label(row, "", "GameFontHighlightSmall")
  row.nameText:SetWordWrap(false)
  row.badge = makeBadge(row)
  row.level = label(row, "", "GameFontHighlightSmall")
  row.level:SetWidth(c.level - 8)
  row.last = label(row, "", "GameFontHighlightSmall")
  row.last:SetWidth(c.last - 8)
  row.last:SetWordWrap(false)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", safely(function(self, button) rowClicked(self.guid, button) end))
  placeCells(row)
  r.pool[i] = row
  return row
end

-- A ScrollBox row, built once per frame: icon, name, then rank, level and last online hung off the right edge (cells
-- at the headers' label x), the hover and the selected art.
local function buildRow(row)
  local c = View.ROW_COLS
  local right = c.rank + c.level + c.last
  row.iconClass = false
  row.icon = icon(row, 16)
  row.icon:SetPoint("LEFT", 4, 0)
  row.nameText = label(row, "", "GameFontHighlightSmall")
  row.nameText:SetWordWrap(false)
  row.nameText:SetPoint("LEFT", c.icon + 8, 0)
  row.nameText:SetPoint("RIGHT", row, "RIGHT", -right - 4, 0)
  row.rank = label(row, "", "GameFontHighlightSmall")
  row.rank:SetWordWrap(false)
  row.rank:SetWidth(c.rank - 12)
  row.rank:SetPoint("LEFT", row, "RIGHT", -right + 8, 0)
  row.level = label(row, "", "GameFontHighlightSmall")
  row.level:SetWidth(c.level - 12)
  row.level:SetPoint("LEFT", row, "RIGHT", -(c.level + c.last) + 8, 0)
  row.last = label(row, "", "GameFontHighlightSmall")
  row.last:SetWordWrap(false)
  row.last:SetWidth(c.last - 12)
  row.last:SetPoint("LEFT", row, "RIGHT", -c.last + 8, 0)
  row.hover = row:CreateTexture(nil, "HIGHLIGHT")
  row.hover:SetAllPoints()
  if not Kit.Atlas(row.hover, "common-list-hoverbg-mid", HIGHLIGHT) then row.hover:SetBlendMode("ADD") end
  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints()
  if Kit.Atlas(row.selected, "common-button-list-small-selected", HIGHLIGHT) then
    Kit.SliceMargins(row.selected, 141, 0, 14, 0)
  else
    row.selected:SetBlendMode("ADD")
  end
  row.selected:Hide()
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", safely(function(self, button) rowClicked(self.guid, button) end))
end

-- Fills a ScrollBox row for this member; every field is set each time (frames are recycled).
local function initRow(row, r)
  row.guid = r.guid
  setClassIcon(row, r.class, "groupfinder-icon-class-")
  row.nameText:SetText(r.name)
  setNameColor(row.nameText, r.class)
  row.rank:SetText(r.rank or "?")
  local tc = View.TIER_TEXT[View.RankTier(r.rankOrder, roster.raiderOrder)]
  row.rank:SetTextColor(tc[1], tc[2], tc[3])
  row.level:SetText(tostring(r.level or "?"))
  row.last:SetText(r.last or "")
  local g = r.online and View.ONLINE_GREEN or { 1, 1, 1 }
  row.last:SetTextColor(g[1], g[2], g[3])
  row.selected:SetShown(r.guid == roster.selected)
end

local function drawChips(r, chips)
  r.chipWidths = {}
  for i, chip in ipairs(chips) do
    local b = r.chips[i]
    if not b then
      b = flatButton(r.panel, 60, CHIP_H)
      if not b then break end
      b:SetScript("OnClick", safely(function(self)
        roster.chip = self.key
        Window.DrawRoster(true)
      end))
      r.chips[i] = b
    end
    local text = View.ChipText(chip)
    b.key = chip.key
    b:SetText(text)
    local fs = b:GetFontString()
    local w = fs and fs:GetStringWidth()
    r.chipWidths[i] = (type(w) == "number" and w > 0) and (math.ceil(w) + 16) or View.ChipWidth(text)
    b:SetWidth(r.chipWidths[i])
    markSelected(b, chip.key == roster.chip)
    b:Show()
  end
  for i = #chips + 1, #r.chips do r.chips[i]:Hide() end
end

-- Places the filter dropdown (else the wrapping chips), the search box, the headers, the list and the side panel for
-- the current window size.
local function placeRoster(r)
  local L = ui.layout
  local R = View.ROSTER
  local top, listTop
  if r.filter then
    r.filter:ClearAllPoints()
    r.filter:SetPoint("TOPLEFT", R.filter.x, -R.filter.y)
    top, listTop = -R.headerY, -R.rowY
  else
    local lines = 1
    for i, pos in ipairs(View.ChipLayout(r.chipWidths or {}, L.contentW - SEARCH_W - 70, 4)) do
      r.chips[i]:ClearAllPoints()
      r.chips[i]:SetPoint("TOPLEFT", 0 + pos.x, -pos.line * CHIP_LINE)
      if pos.line + 1 > lines then lines = pos.line + 1 end
    end
    top = -lines * CHIP_LINE - 4
    listTop = top - HEADER_H - 2
  end
  if r.modernSearch then
    -- the box's right edge on the list area's right edge
    r.search:ClearAllPoints()
    r.search:SetPoint("TOPRIGHT", -(L.contentW - L.rowW), -R.search.y)
  end
  local cols = View.RosterColumns(L.rowW)
  for i, h in pairs(r.headers) do
    if cols[i] then
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", cols[i].x, top)
      h:SetWidth(cols[i].w - 2)
      h:Show()
    else
      h:Hide()
    end
  end
  if r.list then
    r.list.box:ClearAllPoints()
    r.list.box:SetPoint("TOPLEFT", 0, listTop)
    r.list.box:SetPoint("BOTTOMRIGHT", -(L.contentW - L.rowW), 0)
  else
    if r.scroll then
      r.scroll:ClearAllPoints()
      r.scroll:SetPoint("TOPLEFT", 0, listTop)
      r.scroll:SetPoint("BOTTOMRIGHT", -(View.DETAIL_W + GAP + View.SCROLLBAR_W), 0)
    else
      r.content:ClearAllPoints()
      r.content:SetPoint("TOPLEFT", 0, listTop)
    end
    -- the fallback scroll frame keeps SCROLLBAR_W for its bar, so its rows are that much narrower than rowW
    r.content:SetWidth(L.listW - View.SCROLLBAR_W)
  end
  -- the empty / no-match line sits just under the headers, which move down when the chips wrap
  r.empty:ClearAllPoints()
  r.empty:SetPoint("TOPLEFT", 4, listTop - 8)
  r.empty:SetWidth(L.rowW - 8)
  r.detail:ClearAllPoints()
  -- full height beside the dropdown; under the chips when they wrap across the page
  r.detailTop = r.filter and 0 or top
  r.detail:SetPoint("TOPRIGHT", 0, r.detailTop)
  r.detail:SetPoint("BOTTOMRIGHT", 0, 0)
end

-- Module member sections (API 7, Api.lua's member field), in id order: { id, title, build, refresh }; once built,
-- frame, and broken (its build threw), last height and shown (for a single section's refresh).
local memberSections = {}

-- Stacks the member sections in the panel's scroll area for row sel (nil: all hidden). Each frame is re-anchored,
-- re-sized and shown, then refreshed (only = that id: only that section is refreshed, the others keep their height);
-- a frame the module hid, or a height not finite or under 1, is hidden for this draw; a taller one is cut to
-- View.MAX_SECTION_H.
local function drawSections(r, sel, buttons, only)
  local s = r.detail.sections
  if not s then return end
  local S = View.MEMBER_PANEL.sections
  local top, bottom
  if sel and ui and ui.layout then top, bottom = View.SectionArea(ui.layout.contentH + (r.detailTop or 0), buttons) end
  if not top then
    s.scroll:Hide()
    s.divider:Hide()
    for _, e in ipairs(memberSections) do if e.frame then e.frame:Hide() end end
    s.guid = nil
    return
  end
  local key = ns.Comm.Wire.Key(sel.name)
  local y, any = S.pad, false
  for _, e in ipairs(memberSections) do
    local f = e.frame
    if f and not e.broken then
      if not only or e.id == only then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", s.content, "TOPLEFT", S.contentX, -y)
        f:SetWidth(View.SECTION_W)
        f:Show()
        local h
        if ns.Safe(e.title, e.refresh, f, key) and f:IsShown() then h = tonumber(f:GetHeight()) end
        e.shown = h ~= nil and h == h and h < math.huge and h >= 1
        e.height = e.shown and math.min(h, View.MAX_SECTION_H) or 0
      end
      if e.shown then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", s.content, "TOPLEFT", S.contentX, -y)
        f:Show()
        y, any = y + e.height + S.gap, true
      else
        f:Hide()
      end
    elseif f then
      f:Hide()
    end
  end
  local contentH = any and (y - S.gap) or S.pad
  local areaH = bottom - top
  s.content:SetHeight(contentH)
  s.scroll:ClearAllPoints()
  s.scroll:SetPoint("TOPLEFT", r.detail, "TOPLEFT", 0, -top)
  s.scroll:SetPoint("BOTTOMLEFT", r.detail, "BOTTOMLEFT", 0, ui.layout.contentH + r.detailTop - bottom)
  if any then s.scroll:Show() s.divider:Show() else s.scroll:Hide() s.divider:Hide() end
  if s.bar then if contentH > areaH then s.bar:Show() else s.bar:Hide() end end
  -- back to the top on a new selection, not on a redraw
  local fresh = s.guid ~= sel.guid
  s.guid, s.range = sel.guid, math.max(0, contentH - areaH)
  if s.plain then
    s.offset = fresh and 0 or math.min(s.offset or 0, s.range)
    s.content:ClearAllPoints()
    s.content:SetPoint("TOPLEFT", s.scroll, "TOPLEFT", 0, s.offset)
  else
    s.scroll:UpdateScrollChildRect()
    if fresh then s.scroll:SetVerticalScroll(0) end
  end
end

-- The member sections under the notes (View.MEMBER_PANEL.sections): a second divider, a scroll area and one frame
-- per section, each built once under ns.Safe with its module title. The scroll area, by what the client has (as
-- GuildKOS/Page.lua, f4697):
-- * ScrollFrameTemplate: its bar is made in the template's OnLoad and owns OnMouseWheel, OnVerticalScroll and
--   OnScrollRangeChanged (setting one unhooks the bar), so none is set here; Forever draws the bar outside the frame
--   (f4931), so it is moved to barX, inside the panel.
-- * UIPanelScrollFrameTemplate: named, as the classic template looks up <name>ScrollBar.
-- * Neither: a plain frame that clips its children, with its own wheel.
local function buildSections(d)
  local S = View.MEMBER_PANEL.sections
  local s = {}
  local scroll
  if Kit.HasTemplate("ScrollFrameTemplate") then
    local made, f = pcall(Compat.CreateFrame, "ScrollFrame", nil, d, "ScrollFrameTemplate")
    if made and f then
      scroll = f
      scroll:SetWidth(S.scrollW)
      if type(scroll.ScrollBar) == "table" then
        s.bar = scroll.ScrollBar
        s.bar:ClearAllPoints()
        s.bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", S.barX - S.scrollW, 0)
        s.bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", S.barX - S.scrollW, 0)
      end
    end
  end
  if not scroll then
    scroll = Compat.CreateFrame("ScrollFrame", "GuildSyncMemberScroll", d, "UIPanelScrollFrameTemplate")
    if scroll then scroll:SetWidth(S.classicW) end
  end
  if not scroll then
    scroll = Compat.CreateFrame("Frame", nil, d)
    if not scroll then return end
    s.plain = true
    scroll:SetWidth(S.scrollW)
    if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", safely(function(_, delta)
      s.offset = math.min(s.range or 0, math.max(0, (s.offset or 0) - delta * ROW_H))
      s.content:ClearAllPoints()
      s.content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, s.offset)
    end))
  end
  scroll:Hide()
  local content = Compat.CreateFrame("Frame", nil, scroll)
  if not content then return end
  content:SetSize(S.contentX + View.SECTION_W, 1)
  if not s.plain then scroll:SetScrollChild(content) end
  s.divider = d:CreateTexture(nil, "ARTWORK")
  s.divider:SetSize(S.divider[3], S.divider[4])
  s.divider:SetPoint("TOPLEFT", S.divider[1], -S.divider[2])
  Kit.Atlas(s.divider, "Options_HorizontalDivider", DIVIDER_BG)
  s.divider:Hide()
  for _, e in ipairs(memberSections) do
    local f = Compat.CreateFrame("Frame", nil, content)
    if f then
      f:SetWidth(View.SECTION_W)
      f:Hide()
      e.frame = f
      e.broken = not ns.Safe(e.title, e.build, f)
      f:Hide()
    end
  end
  s.scroll, s.content = scroll, content
  d.sections = s
end

local function drawDetail(r, guild)
  local d, sel = r.detail, selectedRow()
  local m = View.MemberPanel(sel, guild and guild.canSeeOfficerNotes, roster.raiderOrder)
  for _, f in ipairs(d.memberParts) do if m then f:Show() else f:Hide() end end
  d.pick:SetText((not m and #roster.all > 0) and View.PICK_MEMBER or "")
  if m then
    setClassIcon(d, sel.class, "groupfinder-icon-class-")
    d.icon:Show()
    d.nameText:SetText(m.name)
    setNameColor(d.nameText, sel.class)
    d.sub:SetText(m.sub)
    d.rank:SetText(m.rank or "?")
    local tc = m.rankColor or { 1, 1, 1 }
    d.rank:SetTextColor(tc[1], tc[2], tc[3])
    d.publicNote:SetText(m.publicNote)
    d.officerNote:SetText(m.officerNote or m.officerHidden)
  else
    d.iconClass = false
    d.icon:Hide()
  end
  for i, row in ipairs(d.factRows) do
    local fact = m and m.facts[i]
    if fact then
      row.label:SetText(fact.label)
      row.value:SetText(fact.value or "")
      local g = fact.green and View.ONLINE_GREEN or { 1, 1, 1 }
      row.value:SetTextColor(g[1], g[2], g[3])
      row.label:Show()
      row.value:Show()
    else
      row.label:Hide()
      row.value:Hide()
    end
  end
  d.buttonCount = drawActions(d, sel)
  drawSections(r, sel, d.buttonCount)
end

-- Whisper from the row menu: a tell to the member (nothing sent); the /w line when the client has no chat helpers.
local function whisperMember(guid, name)
  if demoInert() then return end
  local who = Compat.FullName(guid) or name
  if Compat.OpenWhisper(who) ~= "tell" then ns.Say("Whisper " .. who .. ": /w " .. who) end
end

-- The right-click menu on the row showing guid: the name, Whisper, then the panel's actions for that member. Each
-- entry acts on this guid, called straight from the pick. Nothing opens without the client's menu system.
local function memberMenu(r, guid)
  local row = selectedRow()
  if not row or row.guid ~= guid then return end
  local owner
  if r.list then
    owner = r.list.box:FindFrame(row)
  else
    for _, f in ipairs(r.pool) do if f.guid == guid and f:IsShown() then owner = f end end
  end
  if not owner then return end
  Kit.ContextMenu(owner, function(_, root)
    root:CreateTitle(row.name)
    root:CreateButton("Whisper", safely(function() whisperMember(guid, row.name) end))
    local acts = shownActions(row)
    if #acts > 0 then root:CreateDivider() end
    for _, a in ipairs(acts) do
      root:CreateButton(a.text, safely(function() runAction(a.key, guid) end))
    end
  end)
end

-- A click on a Roster row selects that member (the ScrollBox redraws its shown rows, same provider and scroll).
-- Right: then the row's menu.
rowClicked = function(guid, button)
  local r = ui and ui.roster
  if not r then return end
  roster.selected = guid
  if r.list then
    r.list:Refresh()
    drawDetail(r, syncRows())
  else
    Window.DrawRoster(false)
  end
  if button == "RightButton" then memberMenu(r, guid) end
end

-- Redraws the Roster page. resetScroll: back to the top (a new chip, search or sort), not on a rescan.
function Window.DrawRoster(resetScroll)
  local r = ui and ui.roster
  if not r then return end
  local guild = syncRows()

  local chips = View.RosterChips(roster.all)
  local chosen
  for _, chip in ipairs(chips) do if chip.key == roster.chip then chosen = chip end end
  if not chosen then roster.chip, chosen = "all", chips[1] end
  if r.filter then
    if chosen then Kit.DropdownText(r.filter, View.ChipText(chosen)) end
  else
    drawChips(r, chips)
  end
  placeRoster(r)
  for i, col in ipairs(View.COLUMNS) do
    local h = r.headers[i]
    if h then
      local dir = roster.sort == col.key and (roster.desc and "desc" or "asc") or nil
      if Kit.SortArrow(h, dir) then h:SetText(col.label) else h:SetText(View.HeaderText(col.key, roster.sort, roster.desc)) end
    end
  end

  roster.shown = View.FilterRows(roster.all, roster.chip, roster.query)
  if not selectedRow() then roster.selected = nil end
  if r.list then
    r.list:SetRows(roster.shown, not resetScroll)
  else
    local badgeW = View.ROW_COLS.rank - 16
    for i, row in ipairs(roster.shown) do
      local f = rowFrame(r, i)
      if f then
        f.guid = row.guid
        setClassIcon(f, row.class)
        f.nameText:SetText(row.name)
        setNameColor(f.nameText, row.class)
        setBadge(f.badge, row.rank, row.rankOrder, roster.raiderOrder, badgeW)
        f.level:SetText(tostring(row.level or "?"))
        f.last:SetText(row.last)
        if row.guid == roster.selected then f:LockHighlight() else f:UnlockHighlight() end
        f:Show()
      end
    end
    for i = #roster.shown + 1, #r.pool do r.pool[i]:Hide() end
    r.content:SetHeight(math.max(1, #roster.shown * ROW_H))
    if r.scroll then
      r.scroll:UpdateScrollChildRect()
      if resetScroll then r.scroll:SetVerticalScroll(0) end
    end
  end

  if #roster.all == 0 then
    r.empty:SetText(View.ROSTER_EMPTY)
  elseif #roster.shown == 0 then
    r.empty:SetText(View.NO_MATCH)
  else
    r.empty:SetText("")
  end
  drawDetail(r, guild)
end

-- What the Roster page shows now: { sort, desc, chip, query, selected, shown = rows }. For the tests.
function Window.RosterState() return roster end

local function buildRosterPage(p, u)
  local r = { panel = p, chips = {}, headers = {}, pool = {} }
  u.roster = r

  -- the rank filter: a dropdown of the chips as radios (chip buttons when the client has no dropdown)
  r.filter = Kit.Dropdown(p, View.ROSTER.filter.w, function(_, root)
    for _, e in ipairs(View.RosterFilterEntries(View.RosterChips(roster.all))) do
      if e.divider then
        root:CreateDivider()
      else
        root:CreateRadio(e.text, function(key) return roster.chip == key end, function(key)
          roster.chip = key
          Window.DrawRoster(true)
        end, e.key)
      end
    end
  end)

  -- both search boxes redraw only when the text differs from the query (a SetText to the same text keeps the scroll)
  local function searchChanged(self)
    local text = self:GetText() or ""
    if text == roster.query then return end
    roster.query = text
    Window.DrawRoster(true)
  end
  local search = Kit.SearchBox(p, View.ROSTER.search.w, View.SEARCH_HINT)
  if search then
    search:HookScript("OnTextChanged", safely(searchChanged))
    r.search, r.modernSearch = search, true
  else
    search = Compat.CreateFrame("EditBox", "GuildSyncRosterSearch", p, "InputBoxTemplate")
    r.search = search or false
    if search then
      search:SetSize(SEARCH_W, 20)
      search:SetPoint("TOPRIGHT", -4, 0)
      search:SetAutoFocus(false)
      search:SetScript("OnTextChanged", safely(searchChanged))
      search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
      search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
      local hint = label(p, "Search:", "GameFontNormalSmall")
      hint:SetPoint("RIGHT", search, "LEFT", -8, 0)
    end
  end

  for i, col in ipairs(View.COLUMNS) do
    r.headers[i] = Kit.ColumnHeader(p, col.label, safely(function()
      roster.sort, roster.desc = View.NextSort(roster.sort, roster.desc, col.key)
      View.SortRows(roster.all, roster.sort, roster.desc)
      Window.DrawRoster(true)
    end))
  end

  r.list = Kit.List(p, View.ROSTER.rowH, buildRow, initRow)
  if not r.list then
    local scroll = Compat.CreateFrame("ScrollFrame", "GuildSyncRosterScroll", p, "UIPanelScrollFrameTemplate")
    r.scroll = false
    if scroll then
      local content = Compat.CreateFrame("Frame", nil, scroll)
      if content then
        content:SetSize(300, 1)
        scroll:SetScrollChild(content)
        r.scroll, r.content = scroll, content
      end
    end
    if not r.content then
      -- no scroll frame on this client: rows go straight on the page and the list is cut at the bottom
      r.content = Compat.CreateFrame("Frame", nil, p)
      if not r.content then return false end
      r.content:SetSize(300, 1)
    end
  end
  r.empty = label(p, "")

  -- member panel (View.MEMBER_PANEL): a dark card; the name on a header bar, class icon, class line, rank, three
  -- labelled facts (made once), a divider, the two notes; the officer buttons at the foot
  local M = View.MEMBER_PANEL
  local d = Kit.Inset(p)
  if not d then return false end
  d:SetWidth(View.DETAIL_W)
  local fill = d:CreateTexture(nil, "BACKGROUND", nil, 1)
  fill:SetAllPoints(d)
  fill:SetColorTexture(0, 0, 0, 0.42)
  local textW = View.DETAIL_W - 2 * M.notes.x
  local function text(font, x, y, w)
    local fs = label(d, "", font)
    fs:SetPoint("TOPLEFT", x, -y)
    fs:SetWidth(w)
    fs:SetWordWrap(false)
    return fs
  end
  d.header = Kit.HeaderBar(d, "", M.header.w)
  if not d.header then return false end
  d.header:SetPoint("TOPLEFT", M.header.x, -M.header.y)
  d.nameText = d.header.label
  d.nameText:SetWidth(M.header.w - 16)
  d.nameText:SetWordWrap(false)
  d.icon = icon(d, M.icon.size)
  d.icon:SetPoint("TOPLEFT", M.icon.x, -M.icon.y)
  d.iconClass = false
  d.icon:Hide()
  d.sub = text("GameFontHighlightSmall", M.sub.x, M.sub.y, View.DETAIL_W - M.sub.x - 8)
  d.rank = text("GameFontHighlightSmall", M.rank.x, M.rank.y, View.DETAIL_W - M.rank.x - 8)
  d.factRows = {}
  for i = 1, 3 do
    local y = M.facts.y + (i - 1) * M.facts.step
    d.factRows[i] = { label = text("GameFontNormalSmall", M.facts.labelX, y, M.facts.valueX - M.facts.labelX - 4),
      value = text("GameFontHighlightSmall", M.facts.valueX, y, View.DETAIL_W - M.facts.valueX - 8) }
  end
  d.divider = d:CreateTexture(nil, "ARTWORK")
  d.divider:SetSize(M.divider.w, M.divider.h)
  d.divider:SetPoint("TOPLEFT", M.divider.x, -M.divider.y)
  Kit.Atlas(d.divider, "Options_HorizontalDivider", DIVIDER_BG)
  d.publicLabel = text("GameFontNormalSmall", M.notes.x, M.notes.publicLabel, textW)
  d.publicLabel:SetText("Public note")
  d.publicNote = text("GameFontHighlightSmall", M.notes.x, M.notes.publicValue, textW)
  d.officerLabel = text("GameFontNormalSmall", M.notes.x, M.notes.officerLabel, textW)
  d.officerLabel:SetText("Officer note")
  d.officerNote = text("GameFontHighlightSmall", M.notes.x, M.notes.officerValue, textW)
  d.pick = text("GameFontHighlightSmall", M.pick.x, M.pick.y, textW)
  d.pick:SetWordWrap(true)
  d.memberParts = { d.header, d.sub, d.rank, d.divider, d.publicLabel, d.publicNote, d.officerLabel, d.officerNote }
  buildActions(d) -- officer actions (0.9), at the panel's foot
  r.detail = d
  d.sections = false -- set by buildSections when a module adds a member section and the area could be made
  if #memberSections > 0 then buildSections(d) end
  return true
end

-- Opens a member in the Roster (a click on an Overview row): every member shown, that one selected and in view.
function Window.OpenMember(guid)
  local r = ui and ui.roster
  if not r then return end
  roster.chip, roster.query, roster.selected = "all", "", guid
  if r.search then r.search:SetText("") end
  Window.ShowPage("roster") -- its Refresh redraws the list once
  if r.list then
    -- the row as it is in the current provider (ScrollToElementData finds it by identity)
    local row = selectedRow()
    if row then r.list:ScrollTo(row) end
    return
  end
  if not r.scroll then return end
  for i, row in ipairs(roster.shown) do
    if row.guid == guid then
      local target = math.max(0, (i - 3) * ROW_H)
      local range = r.scroll:GetVerticalScrollRange()
      if type(range) == "number" then target = math.min(target, range) end
      r.scroll:SetVerticalScroll(target)
    end
  end
end

-- ---------- size and place ----------

-- Lays every page out for a window of w x h. Cheap: rows stretch through their anchors, so only the headers, the
-- chips, the Overview's blocks and a few widths move. Runs while the corner is dragged; makes no frame.
local function relayout(w, h)
  if not ui or type(w) ~= "number" or type(h) ~= "number" then return end
  local L = View.WindowLayout(w, h)
  ui.layout = L
  ui.info:SetWidth(L.contentW - 40)
  if ui.char then placeChar(L) end
  if ui.modules then placeModules(ui.modules, L) end
  if ui.overview then placeOverview(ui.overview, L) end
  if ui.roster and ui.roster.detail then placeRoster(ui.roster) end
  if Window.OnRelayout then ns.Safe("Window", Window.OnRelayout, L) end
end

local function place(f, x, y)
  f:ClearAllPoints()
  if x and y then f:SetPoint("TOPLEFT", Compat.UIParent(), "BOTTOMLEFT", x, y) else f:SetPoint("CENTER") end
end

-- After a move or a resize: keep the size inside the bounds and save size and place.
local function savePlacement(f)
  local w, h, x, y = f:GetWidth(), f:GetHeight(), f:GetLeft(), f:GetTop()
  if type(w) ~= "number" or type(h) ~= "number" then return end
  local sw, sh = Compat.ScreenSize()
  local cw, ch = View.ClampSize(w, h, sw, sh)
  if cw ~= w or ch ~= h then f:SetSize(cw, ch) end
  local s = windowSettings()
  s.w, s.h = cw, ch
  if type(x) == "number" and type(y) == "number" then
    s.x, s.y = math.floor(x + 0.5), math.floor(y + 0.5)
    place(f, s.x, s.y)
  end
  relayout(cw, ch)
end

local function buildGrip(f, u)
  local sw, sh = Compat.ScreenSize()
  local maxW, maxH = View.ClampSize(1e6, 1e6, sw, sh)
  if not Compat.Resizable(f, View.WINDOW.minW, View.WINDOW.minH, maxW, maxH) then return end
  local grip = Compat.CreateFrame("Button", nil, u.chrome) -- on the title-bar holder: above the modern frame's border
  if not grip then return end
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture(GRIP_UP)
  grip:SetPushedTexture(GRIP_DOWN)
  grip:SetHighlightTexture(GRIP_HIGHLIGHT)
  local level = u.chrome:GetFrameLevel()
  if type(level) == "number" then grip:SetFrameLevel(level + 20) end
  grip:SetScript("OnMouseDown", function(_, button) if button == "LeftButton" then f:StartSizing("BOTTOMRIGHT", true) end end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    ns.Safe("Window", savePlacement, f)
  end)
  u.grip = grip
end

-- ---------- pages ----------

-- Module addons' pages (Api.lua), after View.PAGES in the sidebar: { key = "m:<id>", title, label, icon, build,
-- refresh }. Their frames and buttons sit in ui.pages and ui.side under that key once the window is built.
local modulePages = {}

local function showPage(key)
  currentPage = key
  if not ui then return end
  for _, list in ipairs({ View.PAGES, modulePages }) do
    for _, page in ipairs(list) do
      local p, b = ui.pages[page.key], ui.side[page.key]
      if p then if page.key == key then p:Show() else p:Hide() end end
      if b then Window.MarkChosen(b, page.key == key) end
    end
  end
end

-- true, or nil and why. Only before the window is built: a later page shows after /reload.
function Window.AddModulePage(entry)
  if frame then return nil, "page after window built" end
  if type(entry) ~= "table" or type(entry.key) ~= "string" or type(entry.build) ~= "function" then
    return nil, "bad page"
  end
  table.insert(modulePages, { key = entry.key, title = tostring(entry.title), label = tostring(entry.label or entry.title),
    icon = entry.icon, build = entry.build, refresh = type(entry.refresh) == "function" and entry.refresh or nil })
  return true
end

-- A module's member section on the Roster panel (API 7): { id, title, build = fn(frame), refresh = fn(frame, key) }.
-- true, or nil and why. Only before the window is built: a later section shows after /reload. Kept in id order.
function Window.AddMemberSection(entry)
  if frame then return nil, "section after window built" end
  if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.build) ~= "function"
    or type(entry.refresh) ~= "function" then
    return nil, "bad section"
  end
  table.insert(memberSections, { id = entry.id, title = tostring(entry.title), build = entry.build,
    refresh = entry.refresh })
  table.sort(memberSections, function(a, b) return a.id < b.id end)
  return true
end

-- Runs that member section's refresh for the selected member, only while the Roster page of the open window shows.
function Window.RefreshMemberSection(id)
  if not (frame and frame:IsShown() and ui and ui.roster and currentPage == "roster") then return end
  local p, sel = ui.pages.roster, selectedRow()
  if not (p and p:IsShown() and sel) then return end
  drawSections(ui.roster, sel, ui.roster.detail.buttonCount or 0, id)
end

-- Runs that module page's refresh(frame), only while it is the current page of the open window.
function Window.RefreshModulePage(key)
  if not (frame and frame:IsShown() and ui and currentPage == key) then return end
  local p = ui.pages[key]
  if not (p and p:IsShown()) then return end
  for _, page in ipairs(modulePages) do
    if page.key == key and page.refresh then ns.Safe(page.title, page.refresh, p) end
  end
end

-- Opens the window when closed, then shows that module page.
function Window.ShowModulePage(key)
  if not (frame and frame:IsShown()) then Window.Toggle() end
  if ui and ui.pages[key] then Window.ShowPage(key) end
end

-- Switches page (the sidebar). The page stays chosen until the game reloads.
function Window.ShowPage(key)
  showPage(key)
  if ui and ui.overview then ui.overview.stamp = nil end
  Window.Refresh()
end

function Window.CurrentPage() return currentPage end
function Window.UI() return ui end

-- The rows' x inside the sidebar inset (centred).
local ROW_X = (View.SHELL.side.w - View.SIDE.rowW) / 2

-- A row in the sidebar inset for each hub page but Settings (the gear in the title bar opens it); a page frame for each.
local function buildSidebar(f, u)
  local strip = u.sideStrip
  if not strip then return false end
  local n = 0
  for _, page in ipairs(View.PAGES) do
    if not page.gear then
      n = n + 1
      local b = Window.SideRow(strip, page.label, page.icon, function() ns.Safe("Window", Window.ShowPage, page.key) end)
      if b then
        b:SetPoint("TOPLEFT", ROW_X, View.SIDE.rows[n])
        u.side[page.key] = b
      end
    end
    if not page.gear or settingsPath == "window" then u.pages[page.key] = pageFrame(f) end -- Settings: Options paths have no page
  end
  return true
end

-- Each module page: a sidebar row below the hub's, and a page built now under the module's title. A build that
-- throws is recorded under that title and its row is hidden.
local function buildModulePages(f, u)
  local strip = u.sideStrip
  if not strip then return end
  for i, page in ipairs(modulePages) do
    local b = Window.SideRow(strip, page.label, page.icon, function() ns.Safe("Window", Window.ShowPage, page.key) end)
    local p = pageFrame(f)
    if b and p then
      b:SetPoint("TOPLEFT", ROW_X, View.SIDE.moduleY - (i - 1) * View.SIDE.step)
      p:Hide()
      if ns.Safe(page.title, page.build, p) then
        u.side[page.key], u.pages[page.key] = b, p
      else
        b:Hide()
      end
    end
  end
end

-- The title bar: GuildSync's title, counts, demo banner and the Settings gear. On the modern frame they go on one holder
-- above the frame's border (u.chrome); on the classic frame the holder is f.
local function buildTitleBar(f, u)
  local modern = frameKind == "modern"
  if modern then
    u.chrome = Compat.CreateFrame("Frame", nil, f)
    if not u.chrome then return false end
    u.chrome:SetAllPoints(f)
    local level = f.NineSlice:GetFrameLevel()
    if type(level) == "number" then u.chrome:SetFrameLevel(level + 10) end
    applyPortrait(f)
  else
    u.chrome = f
  end
  local text = modern and f.TitleContainer.TitleText
  if type(text) == "table" then
    u.title = text
    u.title:SetText("GuildSync")
  else
    u.title = label(f, "GuildSync", "GameFontNormal")
    u.title:SetPoint("TOPLEFT", 12, -6)
  end
  local S = View.SHELL
  u.counts = label(u.chrome, "", "GameFontHighlightSmall")
  u.counts:SetPoint("TOPRIGHT", S.counts.x, S.counts.y)
  u.counts:SetJustifyH("RIGHT")
  u.banner = label(u.chrome, ns.Demo and ns.Demo.LINES.banner or "", "GameFontNormalSmall") -- D7: on the window, so every page shows it
  u.banner:SetPoint("TOPLEFT", S.banner.x, S.banner.y) -- D7: under the title bar, above the page area
  u.banner:SetTextColor(1, 0.5, 0.1)
  u.banner:Hide()

  local gear = Compat.CreateFrame("Button", nil, u.chrome)
  if not gear then return false end
  gear:SetSize(S.gear.w, S.gear.h)
  gear:SetPoint("TOPRIGHT", S.gear.x, S.gear.y)
  local level = u.chrome:GetFrameLevel()
  if type(level) == "number" then gear:SetFrameLevel(level + 1) end
  local t = gear:CreateTexture(nil, "ARTWORK")
  t:SetAllPoints(gear)
  Kit.Atlas(t, "UI-Character-Info-Icon-Settings", GEAR_ICON)
  withTooltip(gear, function() return View.GearTooltip(settingsPath) end)
  gear:SetScript("OnClick", function()
    ns.Safe("Window", function()
      if settingsPath == "window" then return Window.ShowPage("settings") end
      if Compat.InCombat() then return ns.Say(View.COMBAT_LINE) end
      local opened, err = Compat.OpenOptions(optionsCategory)
      if opened then return end
      ns.Say(View.OPTIONS_FAILED_LINE)
      if type(err) == "string" then error(err, 0) end -- recorded under Window by the ns.Safe around this click
    end)
  end)
  u.side.settings = gear
  return true
end

-- The two dark insets: the sidebar (u.sideStrip) and the content panel the pages sit in.
local function buildInsets(f, u)
  local S = View.SHELL
  local side, content = Kit.Inset(f), Kit.Inset(f)
  if not side or not content then return false end
  side:SetPoint("TOPLEFT", S.side.x, S.side.top)
  side:SetPoint("BOTTOMLEFT", S.side.x, S.side.bottom)
  side:SetWidth(S.side.w)
  content:SetPoint("TOPLEFT", S.content.left, S.content.top)
  content:SetPoint("BOTTOMRIGHT", S.content.right, S.content.bottom)
  u.sideStrip = side
  return true
end

-- PortraitFrameTemplate when the client has it; BasicFrameTemplateWithInset when it has not or that CreateFrame
-- returned nil. A template frame that came back is the window, modern or not (never a second GuildSyncWindow).
local function createWindow()
  local f
  if Kit.HasTemplate("PortraitFrameTemplate") then
    f = Compat.CreateFrame("Frame", "GuildSyncWindow", nil, "PortraitFrameTemplate")
  end
  if not f then f = Compat.CreateFrame("Frame", "GuildSyncWindow", nil, "BasicFrameTemplateWithInset") end
  if not f then return nil end
  frameKind = (type(f.NineSlice) == "table" and type(f.TitleContainer) == "table") and "modern" or "classic"
  return f
end

local function build()
  local f = createWindow()
  if not f then return nil end
  f:Hide() -- shown only once fully built (Window.Toggle), so a build that gives up leaves no empty frame on screen
  local sw, sh = Compat.ScreenSize()
  local w, h, x, y = View.WindowPlacement(windowSettings(), sw, sh)
  f:SetSize(w, h)
  place(f, x, y)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.Safe("Window", savePlacement, self)
  end)
  Compat.EscapeCloses("GuildSyncWindow")

  local u = { pages = {}, side = {}, frame = f }
  if not buildTitleBar(f, u) then return nil end
  if not buildInsets(f, u) then return nil end
  if not buildSidebar(f, u) then return nil end
  local P = u.pages
  if not P.overview or not P.roster or not P.char then return nil end
  if settingsPath == "window" and not P.settings then return nil end
  if not buildOverview(P.overview, u) then return nil end
  if not buildRosterPage(P.roster, u) then return nil end
  if not buildCharPage(P.char, u) then return nil end
  if settingsPath == "window" then buildSettingsPage(P.settings, u) end
  if P.modules and not ns.Safe("Window", buildModulesPage, P.modules, u) then
    -- a build that throws is recorded under Window; its row and page are hidden, the rest of the window works
    u.modules = nil
    P.modules:Hide()
    P.modules = nil
    if u.side.modules then u.side.modules:Hide() end
  end
  buildModulePages(f, u)
  buildGrip(f, u)

  f:SetScript("OnShow", function()
    if ui and ui.overview then ui.overview.stamp = nil end
    ns.Safe("Window", Window.Refresh)
    ns.Fire("windowOpened") -- module addons hear it (M.On); a throwing listener is recorded under its module
  end)
  f:Hide()
  ui = u
  relayout(w, h)
  f:SetScript("OnSizeChanged", function(_, nw, nh) ns.Safe("Window", relayout, nw, nh) end)
  if Window.OnBuilt then ns.Safe("Window", Window.OnBuilt, f, u) end -- an extra-pages hook; an error is recorded
  showPage(currentPage)
  return f
end

local function drawBanner()
  if not ui or not ui.banner then return end
  if demoOn() then ui.banner:Show() else ui.banner:Hide() end
end

function Window.Refresh()
  drawBanner()
  if not frame or not ui or not frame:IsShown() then return end
  local c = ns.Char()
  ui.info:SetText(View.InfoText(c, ns.modules, ns.DB().errors))
  drawCharBlock()
  if ui.minimap then ui.minimap:SetChecked(not minimapSettings().hidden) end
  if ui.crest then ui.crest:SetChecked(crestOn()) end
  local guild = syncRows()
  ui.title:SetText(View.TitleText(guild))
  ui.counts:SetText(View.TitleCounts(roster.all))
  if currentPage == "roster" then
    Window.DrawRoster(false)
  elseif currentPage == "overview" then
    Window.DrawOverview()
  elseif currentPage == "char" then
    drawChar()
  elseif currentPage == "modules" then
    ns.Safe("Window", drawModules)
  else
    for _, page in ipairs(modulePages) do
      local p = ui.pages[page.key]
      if page.key == currentPage and page.refresh and p and p:IsShown() then ns.Safe(page.title, page.refresh, p) end
    end
  end
end

-- /gsync ui, the minimap button's left-click and the compartment entry.
function Window.Toggle()
  if not frame then
    windowBuild = "building"
    local errors = ns.SessionErrors("Window")
    frame = build()
    windowBuild = (frame and ns.SessionErrors("Window") == errors) and "built" or "failed"
  end
  if not frame then
    ns.Say("could not open a window on this client. /gsync still prints the status.")
    return
  end
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

ns.On("demo", function() drawBanner() Window.Refresh() end, "Window") -- the banner and pages follow the toggle at once

-- Core calls this after every event it hands to the modules and after every slash command: the window, when open,
-- redraws once a moment later instead of once per event.
function Window.Changed()
  if refreshQueued or not frame or not frame:IsShown() then return end
  refreshQueued = true
  ns.After(0.5, function()
    refreshQueued = false
    Window.Refresh()
  end, "Window")
end

-- ---------- Settings in the game's Options window (Esc > Options > AddOns > GuildSync) ----------
-- Window.OnOptions(kind, arg) --> boolean: an optional hook; nothing sets it since Crafting left the hub (f5452).
-- kind "vertical": arg = the GuildSync category; "canvas": arg = { pages = { settings = holder }, minimap = checkbox }.
-- false or a throw fails that path.
Window.OnOptions = nil

function Window.SettingsPath() return settingsPath end

-- Module settings sub-pages (API 3). entry = { title, add = function(category) }. Queued until Options are decided
-- (they run inside tryVertical); run at once on the vertical path; dropped on canvas and window. true when run or
-- queued, false when dropped.
local moduleSettings = {}
function Window.AddModuleSettings(entry)
  if type(entry) ~= "table" or type(entry.add) ~= "function" then return false end
  if not optionsRegistered then moduleSettings[#moduleSettings + 1] = entry return true end
  if settingsPath ~= "vertical" then return false end
  ns.Safe(entry.title, entry.add, optionsCategory)
  return true
end

-- A nil/false from a Compat wrapper is a silent fallback; a throw comes back as nil plus its error text and ns.Need
-- raises it, so the ns.Safe around the path records it. (A category call's second value on success is its layout.)
local need = ns.Need

local function minimapShown() return not minimapSettings().hidden end

local function addCrestSetting(cat)
  local setting = need(Compat.OptionsProxy(cat, "GUILDSYNC_WINDOW_ICON", "boolean", "Show faction crest", false,
    crestOn,
    function(v)
      if not verticalLive then return end
      Window.SetWindowIcon(v and "crest" or "bag")
    end))
  if setting then need(Compat.OptionsCheckbox(cat, setting)) end
end

local function tryVertical()
  local cat = need(Compat.OptionsCategory("GuildSync"))
  if not cat then return false end
  local setting = need(Compat.OptionsProxy(cat, "GUILDSYNC_SHOW_MINIMAP", "boolean", "Show minimap button", true,
    minimapShown,
    function(v)
      if not verticalLive then return end
      if v ~= minimapShown() then run(Window.ToggleMinimap) end
    end))
  if not setting then return false end
  if not need(Compat.OptionsCheckbox(cat, setting)) then return false end
  ns.Safe("Window", addCrestSetting, cat) -- its own Safe, result ignored: a failure never fails the vertical path
  if Window.OnOptions and not Window.OnOptions("vertical", cat) then return false end
  for _, entry in ipairs(moduleSettings) do ns.Safe(entry.title, entry.add, cat) end -- a throw stays the module's
  if not need(Compat.OptionsAddOn(cat)) then return false end
  verticalLive, optionsCategory, settingsPath = true, cat, "vertical"
  return true
end

-- Today's Settings controls on a frame the panel places itself (no anchors on it).
local function tryCanvas()
  local canvas = Compat.CreateFrame("Frame", "GuildSyncOptionsCanvas", nil)
  if not canvas then return false end
  canvas:Hide()
  local holder = Compat.CreateFrame("Frame", nil, canvas)
  if not holder then return false end
  holder:SetPoint("TOPLEFT", 16, -16)
  holder:SetPoint("RIGHT", -16, 0)
  local cu = { pages = { settings = holder } }
  buildSettingsPage(holder, cu)
  if not cu.minimap then return false end
  canvas.OnRefresh = function()
    cu.minimap:SetChecked(minimapShown())
    if cu.crest then cu.crest:SetChecked(crestOn()) end
  end
  if Window.OnOptions and not Window.OnOptions("canvas", cu) then return false end
  local cat = need(Compat.OptionsCanvas(canvas, "GuildSync"))
  if not cat then return false end
  if not need(Compat.OptionsAddOn(cat)) then return false end
  optionsCategory, settingsPath = cat, "canvas"
  return true
end

-- Once per session, from Window.Login: the vertical category, else the canvas one, else Settings stay in the window.
function Window.RegisterOptions()
  if optionsRegistered then return end
  optionsRegistered = true
  local _, done
  if Compat.SettingsHas("vertical") then _, done = ns.Safe("Window", tryVertical) end
  if not done and Compat.SettingsHas("canvas") then ns.Safe("Window", tryCanvas) end
  moduleSettings = {} -- queued module settings ran inside tryVertical or are dropped
end

-- Core calls this at PLAYER_LOGIN, once the saved settings are loaded.
function Window.Login()
  ns.Safe("Window", function()
    showButton()
    Compat.AddToCompartment({
      text = "GuildSync", icon = ICON, notCheckable = true,
      func = function() ns.Safe("Window", Window.Toggle) end,
    })
  end)
  ns.Safe("Window", Window.RegisterOptions) -- its own Safe: a throw above cannot skip it
end

-- A glow on the minimap button, held by modules through M.Glow (Crafting: a request this account can make). Made on
-- the first SetGlow(true) and reused; with no minimap button nothing happens.
local GLOW = "Interface\\Buttons\\CheckButtonGlow" -- the button flash of the profession and spell books
local glow

function Window.SetGlow(on)
  if not minimapButton then return end
  if not glow then
    if not on then return end
    glow = minimapButton:CreateTexture(nil, "OVERLAY")
    glow:SetSize(40, 40)
    glow:SetPoint("CENTER", minimapButton, "TOPLEFT", 15, -14)
    glow:SetTexture(GLOW)
    glow:SetBlendMode("ADD")
  end
  if on then glow:Show() else glow:Hide() end
end

-- A module's hold on the glow (M.Glow): shown while any module holds it. Answers true, also with no minimap button.
local glowHolds = {} -- title -> true
function Window.HoldGlow(title, on)
  glowHolds[tostring(title)] = on and true or nil
  Window.SetGlow(next(glowHolds) ~= nil)
  return true
end

-- /gsync selftest: read only. The hidden flag is read raw (minimapSettings and windowSettings write defaults), and
-- nothing is built here.
local function selftest()
  local fails = {}
  if windowBuild == "failed" or windowBuild == "building" then table.insert(fails, "window build failed") end
  if buttonBuild == "failed" or buttonBuild == "building" then table.insert(fails, "minimap button not built") end
  if #fails > 0 then return "fail", table.concat(fails, "; ") end
  local db = ns.SavedDB()
  local settings = db and type(db.settings) == "table" and db.settings or nil
  local hidden = settings and type(settings.minimap) == "table" and settings.minimap.hidden and true or false
  if not buttonBuild and not hidden then return "wait", "not logged in yet" end
  local kind = frameKind or (Kit.HasTemplate("PortraitFrameTemplate") and "modern" or "classic")
  return "pass", (hidden and "button hidden by setting" or "button shown") .. ", "
    .. (windowBuild == "built" and "window built" or "window not opened yet") .. ", " .. kind .. " frame"
end

ns.RegisterModule({ name = "Window", selftest = selftest })
