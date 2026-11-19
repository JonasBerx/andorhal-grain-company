-- GuildSync Menu.lua: ns.Kit.Menu, the hub's own menu (no Blizzard menu system), and the hub-private Kit.MenuOpen.
-- Kit.Menu(owner, generate, anchor, title) runs generate(owner, root) once, then shows one reusable frame,
-- GuildSyncMenu, with one row per entry. It answers a read-only handle { Close, IsOpen }, or nil when generate throws,
-- adds no entry, or the frame could not be made; then nothing opens and a menu already open stays as it was. When
-- the anchor or the draw fails instead, the menu already open has been closed first and Kit.Menu answers nil.
-- One menu at a time. It closes on a button or radio pick, Esc (UISpecialFrames), a click outside both the menu and
-- the owner, and the owner or one of its parents hiding. Callbacks run under ns.Safe(title or the hub's).
-- Every IsShown / IsMouseOver answer is read inside a pcall and through Compat.Plain: only a plain false counts.

local _, ns = ...

local Compat = ns.Compat
local Kit = ns.Kit

local MODULE = "Core" -- errors with no title are recorded as the hub's own
local ROW_H = 20 -- PageBoard's 15 * 20 extent assumes this
local MARK_W = 18 -- room left of the text for a radio or checkbox mark
local MIN_W = 140
local MARK = "Interface\\Buttons\\UI-CheckBox-Check"
local DEFAULT_ANCHOR = { "TOPLEFT", "BOTTOMLEFT", 0, -2 }
local MAX_DEPTH = 64 -- the owner walk's guard

local TOKENS = Kit.Tokens
local PAD = TOKENS.space.pad

local function fill(tex, c) tex:SetColorTexture(c[1], c[2], c[3], c[4]) end

local function readOnly(t)
  return setmetatable({}, { __index = t, __metatable = false,
    __newindex = function() error("GuildSync is read-only", 2) end })
end

local frame = Compat.CreateFrame("Frame", "GuildSyncMenu", Compat.UIParent())
local rows = {} -- the row pool, reused; a row drawing an entry holds it as row.entry
local state -- the open menu: { owner, entries, title, offset, visible }, or nil

local function close()
  if not state then return end
  state = nil
  local motion = Kit.Motion
  if motion and motion.Hide then motion.Hide(frame) else frame:Hide() end
end

-- title is the menu's own, read before any callback ran (a callback may open another module's menu).
local function readMark(e, title)
  local good, v = ns.Safe(title, e.isSelected, e.data)
  e.selected = good and v and true or false
end

local function activate(entry)
  if not state or entry.kind == "title" or entry.kind == "divider" or entry.disabled then return end
  local title = state.title
  if entry.kind == "checkbox" then
    ns.Safe(title, entry.setSelected, entry.data)
    if state then
      readMark(entry, title)
      if entry.row and rawget(entry.row, "entry") == entry then entry.row.mark:SetShown(entry.selected) end
    end
    return
  end
  close()
  if entry.kind == "button" then ns.Safe(title, entry.fn, entry.data) else ns.Safe(title, entry.setSelected, entry.data) end
end

local function newRow()
  local row = Compat.CreateFrame("Button", nil, frame)
  row:SetHeight(ROW_H)
  row.hl = row:CreateTexture(nil, "HIGHLIGHT")
  row.hl:SetAllPoints()
  fill(row.hl, TOKENS.colour.hover)
  row.line = row:CreateTexture(nil, "ARTWORK")
  row.line:SetHeight(1)
  row.line:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.line:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  fill(row.line, TOKENS.colour.divider)
  row.mark = row:CreateTexture(nil, "OVERLAY")
  row.mark:SetSize(16, 16)
  row.mark:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.mark:SetTexture(MARK)
  row.icon = row:CreateTexture(nil, "OVERLAY") -- a button's hub-private element.icon (Kit.MatchMenu)
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
  row.label = row:CreateFontString(nil, "OVERLAY", Kit.Text("highlight"))
  row.label:SetPoint("LEFT", row, "LEFT", MARK_W, 0)
  rows[#rows + 1] = row
  return row
end

local function textWidth(fs)
  local good, w = pcall(fs.GetStringWidth, fs)
  return good and tonumber(Compat.Plain(w)) or 0
end

local function draw()
  local entries, width = state.entries, MIN_W
  local shownCount = math.min(#entries, state.visible)
  for i = 1, math.max(#rows, shownCount) do
    local row = rows[i] or newRow()
    local e = i <= shownCount and entries[state.offset + i] or nil
    row.entry = e
    if e then
      e.row = row
      local kind = e.kind
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)
      row:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
      if kind == "radio" or kind == "checkbox" then readMark(e, state.title) end
      row.mark:SetShown(e.selected == true)
      if e.icon == nil or not Compat.SetIcon(row.icon, e.icon) then row.icon:Hide() end
      row.line:SetShown(kind == "divider")
      row.hl:SetShown(kind ~= "title" and kind ~= "divider" and not e.disabled)
      row.label:SetFontObject(kind == "title" and Kit.Text("normal") or e.disabled and Kit.Text("disable")
        or Kit.Text("highlight"))
      row.label:SetText(e.text or "")
      width = math.max(width, textWidth(row.label) + MARK_W + 2 * PAD)
      row:SetScript("OnClick", function() ns.Safe(MODULE, activate, e) end)
      row:Show()
    else
      row:Hide()
    end
  end
  frame:SetSize(width, shownCount * ROW_H + 2 * PAD)
end

-- Root: Blizzard's method names, so every caller's generate stays as written. Neither metatable is reachable through
-- getmetatable (__metatable), and the method tables sit only behind __index (root.__index answers nil), so a module
-- cannot rewrite a method for every menu.
local RootMethods = {}
local Root = { __metatable = false, __index = RootMethods }
-- An entry: element:SetEnabled(false) draws it in the disable style, with no hover, and its click runs nothing.
local Entry = { __metatable = false, __index = { SetEnabled = function(self, on) self.disabled = not on end } }
local function add(root, e) root.entries[#root.entries + 1] = setmetatable(e, Entry) return e end
function RootMethods:CreateTitle(text) return add(self, { kind = "title", text = text }) end
function RootMethods:CreateButton(text, fn, data) return add(self, { kind = "button", text = text, fn = fn, data = data }) end
function RootMethods:CreateRadio(text, isSelected, setSelected, data)
  return add(self, { kind = "radio", text = text, isSelected = isSelected, setSelected = setSelected, data = data })
end
function RootMethods:CreateCheckbox(text, isSelected, setSelected, data)
  return add(self, { kind = "checkbox", text = text, isSelected = isSelected, setSelected = setSelected, data = data })
end
function RootMethods:CreateDivider() return add(self, { kind = "divider" }) end
function RootMethods:SetScrollMode(extent) self.extent = tonumber(extent) end

-- The owner is under the mouse: a missing owner or one with no IsMouseOver is not; a throw or a secret answer is.
local function ownerOver(o)
  if type(o) ~= "table" or type(o.IsMouseOver) ~= "function" then return false end
  local good, v = pcall(o.IsMouseOver, o)
  if not good then return true end
  return Compat.Plain(v) ~= false
end

-- An IsShown or IsMouseOver answer: the plain value, or nil for a missing method, a throw or a secret.
local function ask(obj, method)
  if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
  local good, v = pcall(obj[method], obj)
  if not good then return nil end
  return Compat.Plain(v)
end

-- The owner or one of its parents answers a plain false from IsShown.
local function ownerHidden(o)
  local depth = 0
  while type(o) == "table" and depth < MAX_DEPTH do
    if ask(o, "IsShown") == false then return true end
    if type(o.GetParent) ~= "function" then return false end
    local good, p = pcall(o.GetParent, o)
    o = good and p or nil
    depth = depth + 1
  end
  return false
end

if frame then
  frame:Hide()
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:EnableMouseWheel(true)
  -- colour.panel alone (30% black) is an inset's fill and reads see-through over the game (Jonas, in game, 2026-11-18):
  -- an opaque base sits under it and a 1-px colour.cardAccent edge around it.
  frame.base = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  frame.base:SetAllPoints()
  fill(frame.base, TOKENS.colour.menuBase)
  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  fill(frame.bg, TOKENS.colour.panel)
  frame.edges = {}
  for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT", true },
      { "TOPRIGHT", "BOTTOMRIGHT", true } }) do
    local edge = frame:CreateTexture(nil, "BORDER")
    edge:SetPoint(side[1], frame, side[1], 0, 0)
    edge:SetPoint(side[2], frame, side[2], 0, 0)
    if side[3] then edge:SetWidth(1) else edge:SetHeight(1) end
    fill(edge, TOKENS.colour.cardAccent)
    frame.edges[#frame.edges + 1] = edge
  end
  -- Any hide (Esc mid-fade, a parent) ends any motion hidden at alpha 1, whatever order a stopped FadeIn fires in (R3,
  -- as the window's OnHide in Window.lua).
  frame:SetScript("OnHide", function()
    state = nil
    if Kit.Motion and Kit.Motion.Hide then Kit.Motion.Hide(frame) end
  end)
  frame:SetScript("OnMouseWheel", function(_, delta)
    if not state then return end
    local most = math.max(0, #state.entries - state.visible)
    local offset = math.min(most, math.max(0, state.offset - (tonumber(delta) or 0)))
    if offset ~= state.offset then
      state.offset = offset
      ns.Safe(state.title, draw)
    end
  end)
  frame:SetScript("OnUpdate", function()
    ns.Safe(MODULE, function() if state and ownerHidden(state.owner) then close() end end)
  end)
  frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
  frame:SetScript("OnEvent", function()
    ns.Safe(MODULE, function()
      if state and ask(frame, "IsMouseOver") == false and not ownerOver(state.owner) then close() end
    end)
  end)
  Compat.EscapeCloses("GuildSyncMenu")
end

function Kit.Menu(owner, generate, anchor, title)
  if not frame or type(generate) ~= "function" then return nil end
  title = title or MODULE
  local root = Kit.MenuRoot()
  if not ns.Safe(title, generate, owner, root) or #root.entries == 0 then return nil end
  close()
  local entries = root.entries
  -- The anchor and the owner are the caller's: read and placed under its title. A failure opens nothing.
  frame:ClearAllPoints()
  local placed = ns.Safe(title, function()
    local a = type(anchor) == "table" and anchor or DEFAULT_ANCHOR
    frame:SetPoint(a[1], owner, a[2], a[3], a[4])
  end)
  if not placed then return nil end
  state = { owner = owner, entries = entries, title = title, offset = 0,
    visible = root.extent and math.max(1, math.floor(root.extent / ROW_H)) or #entries }
  local mine = state
  -- Entry texts and icons are the caller's too: a draw the game refuses is recorded under its title and opens nothing.
  if not ns.Safe(title, draw) then
    close()
    return nil
  end
  if Kit.Motion and Kit.Motion.FadeIn then Kit.Motion.FadeIn(frame) end
  frame:Show() -- Motion leaves a frame it cannot read as unprotected hidden in combat; this one is never protected
  return readOnly({
    Close = function() if state == mine then close() end end,
    IsOpen = function() return state == mine end,
  })
end

-- Hub-private (Kit.Dropdown's GenerateMenu): a fresh root with the six methods; its entries are root.entries.
function Kit.MenuRoot() return setmetatable({ entries = {} }, Root) end

-- Hub-private (tests read the open menu through it): a read-only { owner, frame, entries, rows }, or nil.
function Kit.MenuOpen()
  if not state then return nil end
  return readOnly({ owner = state.owner, frame = frame, entries = state.entries, rows = rows })
end
