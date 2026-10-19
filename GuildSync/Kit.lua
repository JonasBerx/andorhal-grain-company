-- GuildSync Kit: the window's building blocks in Forever's own look (templates and atlases), each with a fallback.
-- A client without a template or an atlas gets a plain frame, a file or a colour instead, never an error.
-- The only file that sets an atlas; it reaches the client's template and atlas lists through Compat.
--
-- Frozen API 3 (module addons reach these through M.Kit, Api.lua; API.md documents each): Atlas, ClassIcon, Inset,
-- HeaderBar, StatBar, Card, Divider, ListHover, ColumnHeader, SortArrow, List, Dropdown, DropdownText, SearchBox,
-- InputBox, Checkbox, Tabs, ContextMenu, Confirm, Ask, Pill, SetPill, SectionHeader; and a module's settings(S) gets
-- S.Checkbox and S.Dropdown. A change of signature or meaning goes to a new name. Every other Kit name is hub-private.
-- Frozen API 6 (M.Kit on needs >= 6 handles only), same rule: ItemButton, SetItem, SetCardProfession, ClassBackground.
-- GUILDSYNC_M_ belongs to modules (their popup and setting names): no hub popup or setting name starts with it.

local ADDON, ns = ...

local Compat = ns.Compat
local View = ns.View

local Kit = {}
ns.Kit = Kit

Kit.PANEL_BG = { 0, 0, 0, 0.3 }
local HOVER_BG = { 1, 1, 1, 0.08 }
local ACTIVE_BG = { 1, 1, 1, 0.12 }

local function hasMethod(obj, name) return type(obj) == "table" and type(obj[name]) == "function" end

-- True when the client has this frame template.
function Kit.HasTemplate(name)
  return type(Compat.TemplateInfo(name)) == "table"
end

-- Sets the atlas when the client knows it. True only when the atlas was set.
local function setAtlas(tex, name)
  if not hasMethod(tex, "SetAtlas") or type(Compat.AtlasInfo(name)) ~= "table" then return false end
  if not pcall(tex.SetAtlas, tex, name) then return false end
  tex:Show()
  return true
end

-- The atlas when the client has it, else the fallback: a file path (texcoords reset), { r, g, b, a } (a colour),
-- or nil (the texture hides). True only when the atlas was set.
function Kit.Atlas(tex, name, fallback)
  if type(tex) ~= "table" then return false end
  if setAtlas(tex, name) then return true end
  if type(fallback) == "table" then
    if hasMethod(tex, "SetColorTexture") then
      pcall(tex.SetColorTexture, tex, fallback[1], fallback[2], fallback[3], fallback[4])
      tex:Show()
    end
  elseif fallback ~= nil then
    Compat.SetIcon(tex, fallback)
  elseif hasMethod(tex, "Hide") then
    tex:Hide()
  end
  return false
end

-- A class icon: the atlas prefix..class (when a prefix is given), then classicon-<class>, then the ClassIcon file.
function Kit.ClassIcon(tex, token, prefix)
  if type(tex) ~= "table" then return false end
  if type(token) == "string" and token ~= "" then
    local lower = string.lower(token)
    if prefix and setAtlas(tex, prefix .. lower) then return true end
    if setAtlas(tex, "classicon-" .. lower) then return true end
  end
  return Compat.SetClassIcon(tex, token)
end

-- Rounds a bar's ends: a mask over the whole bar on each texture. Nil when the client makes no mask textures or has
-- no such atlas; the textures stay unmasked then.
function Kit.Mask(bar, textures, atlas)
  if not hasMethod(bar, "CreateMaskTexture") then return nil end
  local ok, mask = pcall(bar.CreateMaskTexture, bar)
  if not ok or type(mask) ~= "table" then return nil end
  if not Kit.Atlas(mask, atlas) then return nil end
  if hasMethod(mask, "SetAllPoints") then mask:SetAllPoints(bar) end
  for _, t in ipairs(textures or {}) do
    if hasMethod(t, "AddMaskTexture") then pcall(t.AddMaskTexture, t, mask) end
  end
  return mask
end

-- Nine-slice margins on a texture. Call only after Kit.Atlas returned true for it.
function Kit.SliceMargins(tex, l, t, r, b)
  if not hasMethod(tex, "SetTextureSliceMargins") then return false end
  return pcall(tex.SetTextureSliceMargins, tex, l, t, r, b) and true or false
end

-- A dark inset panel: InsetFrameTemplate when the client has it, else a plain frame with PANEL_BG at the parent's level.
function Kit.Inset(parent)
  local f
  if Kit.HasTemplate("InsetFrameTemplate") then f = Compat.CreateFrame("Frame", nil, parent, "InsetFrameTemplate") end
  if f then return f end
  f = Compat.CreateFrame("Frame", nil, parent)
  if not f then return nil end
  if hasMethod(parent, "GetFrameLevel") then f:SetFrameLevel(parent:GetFrameLevel()) end
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  bg:SetColorTexture(Kit.PANEL_BG[1], Kit.PANEL_BG[2], Kit.PANEL_BG[3], Kit.PANEL_BG[4])
  return f
end

-- A block header: width x 26, the UI-Character-Info-Title bar, the text centred 1 px above the middle. Caps 32: the end
-- curl runs 27 px into the 2x art, so 32 covers it whether the client counts 1x or 2x pixels.
function Kit.HeaderBar(parent, text, width)
  local f = Compat.CreateFrame("Frame", nil, parent)
  if not f then return nil end
  f:SetSize(width, 26)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints(f)
  if Kit.Atlas(f.bg, "UI-Character-Info-Title", Kit.PANEL_BG) then Kit.SliceMargins(f.bg, 32, 0, 32, 0) end
  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.label:SetPoint("CENTER", 0, 1)
  f.label:SetText(text)
  return f
end

-- The stat bar's track inset: common-stat-bar-BG's bevel ends 5.5 px in, Blizzard's mask track starts at 6.5.
Kit.STAT_INSET = 6

-- A stat bar 29 tall (width is the caller's): the common-stat-bar-BG background and .fill, the 15-px line the
-- segments go in, at y -7 and STAT_INSET in from each end (the bar's inner track). No slice margins on .bg: the atlas
-- carries its own (29/0/14/0), and ours would override them. scale ~= 1 scales the whole bar (the caller divides its
-- offsets by it).
function Kit.StatBar(parent, scale)
  local f = Compat.CreateFrame("Frame", nil, parent)
  if not f then return nil end
  f:SetHeight(29)
  if scale and scale ~= 1 then f:SetScale(scale) end
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints(f)
  Kit.Atlas(f.bg, "common-stat-bar-BG", Kit.PANEL_BG)
  f.fill = Compat.CreateFrame("Frame", nil, f)
  if f.fill then
    f.fill:SetHeight(15)
    f.fill:SetPoint("TOPLEFT", Kit.STAT_INSET, -7)
    f.fill:SetPoint("TOPRIGHT", -Kit.STAT_INSET, -7)
  end
  return f
end

-- A sidebar row in the Settings list style (View.SIDE: 124x26, icon 18 at x 6, label at x 30), hover and chosen
-- backgrounds.
function Kit.SideRow(parent, text, icon, onClick)
  local S = View.SIDE
  local b = Compat.CreateFrame("Button", nil, parent)
  if not b then return nil end
  b.isRow = true
  b:SetSize(S.rowW, S.rowH)
  b.active = b:CreateTexture(nil, "BACKGROUND")
  b.active:SetAllPoints(b)
  Kit.Atlas(b.active, "Options_List_Active", ACTIVE_BG)
  b.active:Hide()
  local hover = b:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints(b)
  Kit.Atlas(hover, "Options_List_Hover", HOVER_BG)
  b.hover = hover
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(S.icon, S.icon)
  b.icon:SetPoint("LEFT", S.iconX, 0)
  if icon then Compat.SetIcon(b.icon, icon, View.IsGameIcon(icon)) end
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.label:SetPoint("LEFT", S.labelX, 0)
  b.label:SetText(text)
  b:SetScript("OnClick", function(self) if onClick then onClick(self) end end)
  return b
end

-- Marks a sidebar row as the chosen one (Options_List_Active, white label, no hover) or not (gold label, hover back).
-- Anything that is not a Kit.SideRow (the Settings gear) is left alone.
function Kit.SetChosen(b, on)
  if type(b) ~= "table" or rawget(b, "isRow") ~= true then return end
  if b.active then b.active:SetShown(on and true or false) end
  local hover = rawget(b, "hover")
  if type(hover) == "table" then hover:SetShown(not on) end
  if b.label then b.label:SetFontObject(on and "GameFontHighlight" or "GameFontNormal") end
end

-- ---------- the Roster's pieces. Nil or false = the caller keeps its fallback. ----------

-- A WowStyle1DropdownTemplate button (width x 25) whose menu generate(dd, rootDescription) builds. Nil when the
-- client lacks the template or the menu system, or when the build fails (the partial frame is hidden).
function Kit.Dropdown(parent, width, generate)
  if not Kit.HasTemplate("WowStyle1DropdownTemplate") or not Compat.MenuUtil() then return nil end
  local dd = Compat.CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if not dd then return nil end
  local good = pcall(function()
    dd:SetSize(width, 25)
    dd:SetupMenu(generate)
  end)
  if not good then
    if hasMethod(dd, "Hide") then dd:Hide() end
    return nil
  end
  return dd
end

-- The dropdown's button text: OverrideText when the button has it, SetText otherwise.
function Kit.DropdownText(dd, text)
  if hasMethod(dd, "OverrideText") then dd:OverrideText(text) elseif hasMethod(dd, "SetText") then dd:SetText(text) end
end

-- A SearchBoxTemplate box (width x 22) with the hint as its instructions. Sets no scripts: the template owns them.
function Kit.SearchBox(parent, width, hint)
  if not Kit.HasTemplate("SearchBoxTemplate") then return nil end
  local box = Compat.CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
  if not box then return nil end
  box:SetSize(width, 22)
  if type(box.Instructions) == "table" and hasMethod(box.Instructions, "SetText") then box.Instructions:SetText(hint) end
  return box
end

local TABS = "Interface\\FriendsFrame\\WhoFrame-ColumnTabs"

-- A column header in the ColumnDisplayButtonShortTemplate look: 19 tall, the WhoFrame column tab in three parts,
-- the label at LEFT +8 bound as the button's font string (h:SetText sets it), the tab highlight added on hover.
function Kit.ColumnHeader(parent, text, onClick)
  local h = Compat.CreateFrame("Button", nil, parent)
  if not h then return nil end
  h:SetHeight(19)
  h.left = h:CreateTexture(nil, "BACKGROUND")
  h.left:SetTexture(TABS)
  h.left:SetSize(5, 19)
  h.left:SetPoint("TOPLEFT")
  h.left:SetTexCoord(0, 0.078125, 0, 0.59375)
  h.right = h:CreateTexture(nil, "BACKGROUND")
  h.right:SetTexture(TABS)
  h.right:SetSize(4, 19)
  h.right:SetPoint("TOPRIGHT")
  h.right:SetTexCoord(0.90625, 0.96875, 0, 0.59375)
  h.middle = h:CreateTexture(nil, "BACKGROUND")
  h.middle:SetTexture(TABS)
  h.middle:SetPoint("LEFT", h.left, "RIGHT")
  h.middle:SetPoint("RIGHT", h.right, "LEFT")
  h.middle:SetHeight(19)
  h.middle:SetTexCoord(0.078125, 0.90625, 0, 0.59375)
  h.label = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  h.label:SetPoint("LEFT", 8, 0)
  h:SetFontString(h.label)
  h:SetText(text)
  h:SetHighlightTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight", "ADD")
  h:SetScript("OnClick", function(self) if onClick then onClick(self) end end)
  return h
end

-- The header's sort arrow (9x9 at the label's RIGHT +3): "asc" points up, "desc" down, nil hides it.
-- True while the arrow atlas is in use; false (arrow hidden) when the client lacks it.
function Kit.SortArrow(header, dir)
  if type(header) ~= "table" then return false end
  local a = rawget(header, "arrow")
  if not a then
    a = header:CreateTexture(nil, "ARTWORK")
    a:SetSize(9, 9)
    a:SetPoint("LEFT", header.label, "RIGHT", 3, 0)
    header.arrow = a
  end
  if dir == nil then a:Hide() return false end
  if not Kit.Atlas(a, "auctionhouse-ui-sortarrow") then return false end
  if dir == "asc" then a:SetTexCoord(0, 1, 1, 0) else a:SetTexCoord(0, 1, 0, 1) end
  a:Show()
  return true
end

-- A recycling list: a WowScrollBoxList box and a MinimalScrollBar bar under a linear view, rows rowH tall.
-- Each row frame runs build(frame) once, then init(frame, row) every time it shows a row. Nil when any piece is
-- missing or the build fails part-way (the partial frames are hidden).
function Kit.List(parent, rowH, build, init)
  local s = Compat.ScrollList()
  if not s or not Kit.HasTemplate("WowScrollBoxList") or not Kit.HasTemplate("MinimalScrollBar") then return nil end
  local function initializer(frame, row)
    if not rawget(frame, "created") then
      frame.created = true
      build(frame)
    end
    init(frame, row)
  end
  local list = {}
  local good = pcall(function()
    list.box = Compat.CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    list.bar = Compat.CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    if not list.box or not list.bar then error("no scroll frames") end
    list.box:SetPoint("TOPLEFT")
    list.box:SetPoint("BOTTOMRIGHT", -16, 0)
    list.bar:SetPoint("TOPLEFT", list.box, "TOPRIGHT", 4, 0)
    list.bar:SetPoint("BOTTOMLEFT", list.box, "BOTTOMRIGHT", 4, 0)
    local view = s.linearView()
    view:SetElementExtent(rowH)
    view:SetElementInitializer("Button", initializer)
    s.initWithBar(list.box, list.bar, view)
  end)
  if not good then
    if hasMethod(list.box, "Hide") then list.box:Hide() end
    if hasMethod(list.bar, "Hide") then list.bar:Hide() end
    return nil
  end
  -- A new provider with these rows; keepScroll keeps the scroll position.
  function list.SetRows(self, rows, keepScroll)
    self.box:SetDataProvider(s.dataProvider(rows or {}), keepScroll and true or false)
  end
  -- Runs init again on the shown frames, same provider.
  function list.Refresh(self) self.box:ForEachFrame(initializer) end
  -- Scrolls to this row table (centred). False when it is not in the provider.
  function list.ScrollTo(self, row) return self.box:ScrollToElementData(row) ~= nil end
  return list
end

-- A right-click menu on owner, built by generate(owner, rootDescription). False when the client has no menu system.
function Kit.ContextMenu(owner, generate)
  local menu = Compat.MenuUtil()
  if not menu then return false end
  return pcall(menu.CreateContextMenu, owner, generate) and true or false
end

-- A dialog on UIParent (DefaultPanelTemplate, else BasicFrameTemplateWithInset), centred, strata DIALOG, Escape
-- closes it. f.title is the label to set; f.modern says which template it got.
function Kit.Dialog(name, width, height)
  local modern = Kit.HasTemplate("DefaultPanelTemplate")
  local f = modern and Compat.CreateFrame("Frame", name, nil, "DefaultPanelTemplate") or nil
  if not f then
    modern = false
    f = Compat.CreateFrame("Frame", name, nil, "BasicFrameTemplateWithInset")
  end
  if not f then return nil end
  f.modern = modern
  f:SetSize(width, height)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  Compat.EscapeCloses(name)
  if modern then
    -- DefaultPanelTemplate has no close button of its own; it must sit above the NineSlice border.
    local anchored = Kit.HasTemplate("UIPanelCloseButtonDefaultAnchors")
    local close = Compat.CreateFrame("Button", nil, f, anchored and "UIPanelCloseButtonDefaultAnchors" or "UIPanelCloseButton")
    if close and not anchored then close:SetPoint("TOPRIGHT") end
    local nine = rawget(f, "NineSlice")
    if close and hasMethod(nine, "GetFrameLevel") and close:GetFrameLevel() <= nine:GetFrameLevel() then
      close:SetFrameLevel(nine:GetFrameLevel() + 1)
    end
  end
  local tc = rawget(f, "TitleContainer")
  if modern and type(tc) == "table" and type(tc.TitleText) == "table" then
    f.title = tc.TitleText
  else
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", 0, -6)
  end
  return f
end

-- An edit box: InputBoxInstructionsTemplate width x 20 when the client has it, InputBoxTemplate fallbackWidth x 20
-- otherwise. Sets no scripts.
function Kit.InputBox(parent, width, fallbackWidth)
  local box
  if Kit.HasTemplate("InputBoxInstructionsTemplate") then
    box = Compat.CreateFrame("EditBox", nil, parent, "InputBoxInstructionsTemplate")
  end
  if box then box:SetSize(width, 20) return box end
  box = Compat.CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  if not box then return nil end
  box:SetSize(fallbackWidth, 20)
  return box
end

-- ---------- This character's pieces. Kit reads no View here: the caller passes View's values in. ----------

local COINS = { { "g", "coin-gold" }, { "s", "coin-silver" }, { "c", "coin-copper" } }
local ROW_HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

local function atlasKnown(name) return type(Compat.AtlasInfo(name)) == "table" end

-- A money line (look of SmallMoneyFrameTemplate): each part's digits (NumberFontNormal) then its coin 13x13.
-- Kit.SetMoney fills it.
function Kit.MoneyLine(parent)
  local f = Compat.CreateFrame("Frame", nil, parent)
  if not f then return nil end
  f:SetSize(160, 14)
  f.pieces = {}
  for _, coin in ipairs(COINS) do
    local digits = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetSize(13, 13)
    digits:Hide()
    tex:Hide()
    f.pieces[coin[1]] = { digits = digits, coin = tex }
  end
  f.fallback = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.fallback:SetPoint("LEFT", f, "LEFT", 0, 0)
  f.fallback:Hide()
  return f
end

-- Draws parts ({ g, s, c }, each a number or nil; a nil part is left out) as digits and coins chained from the
-- line's left; the shown pieces close up. When the client lacks any coin atlas: fallbackText alone.
function Kit.SetMoney(line, parts, fallbackText)
  if type(line) ~= "table" or type(rawget(line, "pieces")) ~= "table" then return end
  parts = type(parts) == "table" and parts or {}
  local coins = true
  for _, coin in ipairs(COINS) do if not atlasKnown(coin[2]) then coins = false end end
  local prev
  for _, coin in ipairs(COINS) do
    local p = line.pieces[coin[1]]
    local v = parts[coin[1]]
    if coins and v ~= nil then
      p.digits:ClearAllPoints()
      if prev then p.digits:SetPoint("LEFT", prev, "RIGHT", 4, 0) else p.digits:SetPoint("LEFT", line, "LEFT", 0, 0) end
      p.digits:SetText(tostring(v))
      p.digits:Show()
      p.coin:ClearAllPoints()
      p.coin:SetPoint("LEFT", p.digits, "RIGHT", 2, 0)
      if not Kit.Atlas(p.coin, coin[2]) then coins = false end
      prev = p.coin
    else
      p.digits:Hide()
      p.coin:Hide()
    end
  end
  if coins then
    line.fallback:Hide()
    return
  end
  for _, coin in ipairs(COINS) do
    line.pieces[coin[1]].digits:Hide()
    line.pieces[coin[1]].coin:Hide()
  end
  line.fallback:SetText(fallbackText or "")
  line.fallback:Show()
end

local STATE_MARK = {
  pass = { "UI-Character-Info-Icon-Tick", 25, 23 },
  wait = { "services-icon-warning", 18, 16 },
  fail = { "Profession-button-red-crossmark", 16, 16 },
}

-- A state mark centred on the 16x16 slot at (6,-3) of the parent; mark.word is the text shown instead when the
-- client lacks the state's atlas. Kit.SetState sets it.
function Kit.StateMark(parent)
  if not hasMethod(parent, "CreateTexture") then return nil end
  local mark = parent:CreateTexture(nil, "ARTWORK")
  mark:SetPoint("CENTER", parent, "TOPLEFT", 14, -11)
  mark:Hide()
  local word = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  word:SetPoint("LEFT", parent, "TOPLEFT", 6, -11)
  word:Hide()
  mark.word = word
  return mark
end

-- state "pass" | "wait" | "fail" draws its atlas at its size; without the atlas, word ({ text, r, g, b }, positional
-- or named) in its colour. nil hides both.
function Kit.SetState(mark, state, word)
  if type(mark) ~= "table" then return end
  local w = rawget(mark, "word")
  if type(w) == "table" then w:Hide() end
  local s = STATE_MARK[state]
  if not s then mark:Hide() return end
  if Kit.Atlas(mark, s[1]) then
    mark:SetSize(s[2], s[3])
    return
  end
  mark:Hide()
  if type(w) ~= "table" or type(word) ~= "table" then return end
  w:SetText(word.text or word[1] or "")
  w:SetTextColor(word.r or word[2] or 1, word.g or word[3] or 1, word.b or word[4] or 1)
  w:Show()
end

-- A module row: a Button 22 tall with the list hover, the state mark (slot at (6,-3)), the name (GameFontNormal, gold)
-- at x 28 and the status (GameFontHighlightSmall, one line) at x 132; hover shows the name and the full status.
-- Kit.PlaceModuleRow sets the widths.
function Kit.ModuleRow(parent)
  local row = Compat.CreateFrame("Button", nil, parent)
  if not row then return nil end
  row:SetHeight(22)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(row)
  if not Kit.Atlas(hl, "common-list-hoverbg-mid", ROW_HIGHLIGHT) and hasMethod(hl, "SetBlendMode") then hl:SetBlendMode("ADD") end
  row.highlightTex = hl
  row.mark = Kit.StateMark(row)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name:SetPoint("LEFT", row, "LEFT", 28, 0)
  row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.status:SetPoint("LEFT", row, "LEFT", 132, 0)
  row.status:SetJustifyH("LEFT")
  row.status:SetWordWrap(false)
  row:SetScript("OnEnter", function(self)
    local tip = Compat.Tooltip()
    if not tip then return end
    tip:SetOwner(self, "ANCHOR_RIGHT")
    tip:SetText(self.name:GetText() or "")
    tip:AddLine(self.status:GetText() or "", 1, 0.82, 0, true)
    tip:Show()
  end)
  row:SetScript("OnLeave", function()
    local tip = Compat.Tooltip()
    if tip then tip:Hide() end
  end)
  return row
end

-- The row's status column width (page width - 132); the row spans name and status.
function Kit.PlaceModuleRow(row, statusW)
  if type(row) ~= "table" or type(rawget(row, "status")) ~= "table" then return end
  row.status:SetWidth(statusW)
  row:SetWidth(132 + statusW)
end

local confirmWindow

local function buildConfirmWindow()
  local f = Kit.Dialog("GuildSyncKitConfirm", 340, 120) -- Escape hides it: the same as Cancel
  if not f then return nil end
  f.title:SetText("GuildSync")
  f.question = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.question:SetPoint("TOPLEFT", 14, -34)
  f.question:SetWidth(312)
  f.ok = Compat.CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.ok:SetSize(100, 22)
  f.ok:SetPoint("BOTTOMRIGHT", -14, 12)
  f.ok:SetScript("OnClick", function()
    f:Hide()
    local run = f.onOk
    if type(run) == "function" then run() end
  end)
  f.cancel = Compat.CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.cancel:SetSize(100, 22)
  f.cancel:SetPoint("BOTTOMLEFT", 14, 12)
  f.cancel:SetText("Cancel")
  f.cancel:SetScript("OnClick", function() f:Hide() end)
  f:Hide()
  return f
end

-- Asks text with okText and Cancel: the game's StaticPopup (which) when the client shows it, else one Kit.Dialog
-- window. onOk runs once on okText, never on Cancel or Escape. True when a popup or the window opened.
-- Every % is doubled in the StaticPopup def only (StaticPopup_Show formats def.text, as Kit.Ask notes); the window
-- shows text as passed. || is left as passed. The window takes text and okText as strings (nil as "") and gets onOk
-- last, so a bad call never pairs another caller's question with its onOk.
function Kit.Confirm(which, text, okText, onOk)
  local safe = string.gsub(tostring(text or ""), "%%", "%%%%")
  local def = { text = safe, button1 = okText, button2 = "Cancel", timeout = 0, whileDead = true, hideOnEscape = true,
    OnAccept = function() onOk() end } -- returns nothing, so the popup hides
  if Compat.Popup(which, def) then return true end
  if not confirmWindow then confirmWindow = buildConfirmWindow() end
  local f = confirmWindow
  if not f then return false end
  f.question:SetText(tostring(text or ""))
  f.ok:SetText(tostring(okText or ""))
  f.onOk = onOk
  f:Show()
  return true
end

-- ---------- the Crafting work board's pieces. Nil or false = the caller keeps its fallback. ----------

local TAB_PADDING = 0 -- Kit.Tabs: PanelTemplates_TabResize's padding; min and max width stay the template's (nil)

-- One PanelTopTabButtonTemplate tab per entry ({ key, text }) on Kit's own holder frame (32 tall, at the parent's
-- top), so the template's OnShow resize reads the holder's tabPadding / minTabWidth / maxTabWidth, which are exactly
-- what Kit hands to PanelTemplates_TabResize. The first tab at the holder's TOPLEFT +4, each next one LEFT on the
-- previous tab's RIGHT +2. A click on an unselected tab runs onSelect(key); the selected tab runs nothing.
-- tabs[key] = the tab, tabs.holder, tabs:Select(key). Nil when the client lacks the template or the tab functions,
-- or when the build fails part-way (the holder is hidden).
function Kit.Tabs(parent, entries, onSelect)
  if not Kit.HasTemplate("PanelTopTabButtonTemplate") then return nil end
  local holder = Compat.CreateFrame("Frame", nil, parent)
  if not holder then return nil end
  local tabs = { holder = holder, keys = {} }
  local padding, minWidth, maxWidth = TAB_PADDING, nil, nil
  -- Only Compat names the tab functions: a missing one shows as a false return from its wrapper, which fails the build.
  local good = pcall(function()
    holder:SetHeight(32)
    holder:SetPoint("TOPLEFT")
    holder:SetPoint("TOPRIGHT")
    holder.tabPadding, holder.minTabWidth, holder.maxTabWidth = padding, minWidth, maxWidth
    local prev
    for _, e in ipairs(entries or {}) do
      local key = e.key
      local tab = Compat.CreateFrame("Button", nil, holder, "PanelTopTabButtonTemplate")
      if not tab then error("no tab") end
      tab:SetText(e.text)
      if prev then tab:SetPoint("LEFT", prev, "RIGHT", 2, 0) else tab:SetPoint("TOPLEFT", holder, "TOPLEFT", 4, 0) end
      if not Compat.TabResize(tab, padding, minWidth, maxWidth) then error("no tab resize") end
      if not Compat.SelectTab(tab, false) then error("no tab deselect") end -- the starting state: unselected
      tab:SetScript("OnClick", function()
        if tabs.selected == key then return end
        if type(onSelect) == "function" then onSelect(key) end
      end)
      tabs[key] = tab
      tabs.keys[#tabs.keys + 1] = key
      prev = tab
    end
    -- the select function too: select the first tab and deselect it again, so every tab starts unselected
    local first = tabs[tabs.keys[1]]
    if first then
      if not Compat.SelectTab(first, true) then error("no tab select") end
      Compat.SelectTab(first, false)
    end
  end)
  if not good then
    if hasMethod(holder, "Hide") then holder:Hide() end
    return nil
  end
  -- Selects (and disables) that tab and deselects every other. Runs no onSelect.
  function tabs.Select(self, key)
    self.selected = key
    for _, k in ipairs(self.keys) do Compat.SelectTab(self[k], k == key) end
  end
  return tabs
end

local CARD_FILL = { 0, 0, 0, 0.42 }
local CARD_ACCENT = { 1, 0.82, 0, 0.55 } -- the Bank card's open accent (gold .55)

local CARD_ART = "Profession-overview-Card"
local cardArts = setmetatable({}, { __mode = "k" }) -- card -> its private art texture (Kit.Card only)

-- The card's art on atlas name: shown with the accent hidden; a missing atlas hides the art and shows the accent.
-- Slice 22 after every atlas: the art's frame line keeps its own size, not drifting inward with the card's height.
local function setCardArt(card, name)
  local on = setAtlas(cardArts[card], name)
  if on then Kit.SliceMargins(cardArts[card], 22, 22, 22, 22) else cardArts[card]:Hide() end
  if hasMethod(card.accent, "SetShown") then card.accent:SetShown(not on) end
  return on
end

-- A request card w x h: Kit.Inset (InsetFrameTemplate or the plain inset) with .fill (black .42 over the card), the
-- plain profession card art above the fill when the client has it (private, on the whole card, its frame kept at its
-- own size), and .accent (2 px gold down the left edge, hidden while the art shows), as the Bank's request card.
function Kit.Card(parent, w, h)
  local card = Kit.Inset(parent)
  if not card then return nil end
  card:SetSize(w, h)
  card.fill = card:CreateTexture(nil, "BACKGROUND")
  card.fill:SetAllPoints(card)
  card.fill:SetColorTexture(CARD_FILL[1], CARD_FILL[2], CARD_FILL[3], CARD_FILL[4])
  card.accent = card:CreateTexture(nil, "BORDER")
  card.accent:SetColorTexture(CARD_ACCENT[1], CARD_ACCENT[2], CARD_ACCENT[3], CARD_ACCENT[4])
  card.accent:SetWidth(2)
  card.accent:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
  card.accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
  local art = card:CreateTexture(nil, "BACKGROUND", nil, 1)
  art:SetAllPoints(card)
  cardArts[card] = art
  setCardArt(card, CARD_ART)
  return card
end

-- Skill line id -> the profession banner's name (Profession-overview-Card-<Name>). 633 and 40 not verified (q-D).
local BANNERS = {
  [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering", [182] = "Herbalism",
  [165] = "Leatherworking", [186] = "Mining", [393] = "Skinning", [197] = "Tailoring",
  [633] = "Lockpicking", [40] = "Poisons",
}

-- A Kit.Card's art on the banner of skill line skillLineID; any other value, or a missing banner, gets the plain card.
-- True only when a banner was set. A frame not made by Kit.Card: false, nothing changed.
function Kit.SetCardProfession(card, skillLineID)
  if not cardArts[card] then return false end
  local name = type(skillLineID) == "number" and BANNERS[skillLineID] or nil
  if name and setCardArt(card, CARD_ART .. "-" .. name) then return true end
  setCardArt(card, CARD_ART)
  return false
end

-- Class token -> UI-Character-Info-<Class>-BG (the nine classes proven in game).
local CLASS_BG = {
  WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
  SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}

-- The class's UI-Character-Info-<Class>-BG atlas name; nil for an unknown token. Hub-private (Window's class band).
function Kit.ClassBackgroundAtlas(classFile)
  local name = type(classFile) == "string" and CLASS_BG[classFile] or nil
  return name and "UI-Character-Info-" .. name .. "-BG" or nil
end

-- The class's character-info background on texture. An unknown token or a missing atlas hides it and answers false.
function Kit.ClassBackground(texture, classFile)
  local atlas = Kit.ClassBackgroundAtlas(classFile)
  if not atlas then
    if hasMethod(texture, "Hide") then texture:Hide() end
    return false
  end
  return Kit.Atlas(texture, atlas, nil)
end

local plainItemButtons = setmetatable({}, { __mode = "k" }) -- Kit.ItemButton's fallback buttons
local gameItemButtons = setmetatable({}, { __mode = "k" }) -- Kit.ItemButton's game ItemButtons (f4420)

-- The game's ItemButton 37x37; without the type a plain Button 37x37 with .icon (all points) and .count
-- (NumberFontNormal, bottom right). Nil when no frame could be made.
function Kit.ItemButton(parent)
  local b = Compat.CreateFrame("ItemButton", nil, parent)
  if b then
    b:SetSize(37, 37)
    gameItemButtons[b] = true
    return b
  end
  b = Compat.CreateFrame("Button", nil, parent)
  if not b then return nil end
  b:SetSize(37, 37)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints(b)
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
  b.count:Hide()
  plainItemButtons[b] = true
  return b
end

-- Shows an item on a Kit.ItemButton: the game's SetItemButtonTexture, SetItemButtonQuality (nil for a non-number)
-- and SetItemButtonCount, each run on its own. True only when all three ran. On the fallback: the icon file and the
-- count (shown above 1), false. Any frame Kit.ItemButton did not make: untouched, false (f4420).
function Kit.SetItem(button, icon, quality, count)
  if type(button) ~= "table" then return false end
  if plainItemButtons[button] then
    Compat.SetIcon(button.icon, icon)
    if type(count) == "number" and count > 1 then
      button.count:SetText(tostring(count))
      button.count:Show()
    else
      button.count:Hide()
    end
    return false
  end
  if not gameItemButtons[button] then return false end
  local textured = Compat.SetItemButton("Texture", button, icon)
  local qualified = Compat.SetItemButton("Quality", button, type(quality) == "number" and quality or nil)
  local counted = Compat.SetItemButton("Count", button, count)
  return textured and qualified and counted
end

-- A MinimalCheckboxTemplate CheckButton 30x29 with .label (GameFontHighlight) at its RIGHT. Nil without the template.
function Kit.Checkbox(parent, text)
  if not Kit.HasTemplate("MinimalCheckboxTemplate") then return nil end
  local cb = Compat.CreateFrame("CheckButton", nil, parent, "MinimalCheckboxTemplate")
  if not cb then return nil end
  local good = pcall(function()
    cb:SetSize(30, 29)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText(text)
  end)
  if not good then
    if hasMethod(cb, "Hide") then cb:Hide() end
    return nil
  end
  return cb
end

-- The entry's 16x16 icon at the menu button's left, the text moved beside it. A failing attach leaves the text.
local function matchIcon(button, icon)
  pcall(function()
    local tex = button:AttachTexture()
    tex:SetSize(16, 16)
    tex:SetPoint("LEFT")
    Compat.SetIcon(tex, icon)
    local fs = rawget(button, "fontString")
    if type(fs) == "table" and hasMethod(fs, "SetPoint") then fs:SetPoint("LEFT", tex, "RIGHT", 3, 0) end
  end)
end

-- A menu under owner (TOPLEFT on its BOTTOMLEFT, 0, -2) with one button per entry ({ text, icon, value }), each
-- with its icon; a pick runs onPick(entry). No entries: one title, emptyText. Nil without the menu system.
function Kit.MatchMenu(owner, entries, onPick, emptyText)
  local function generate(_, root)
    if type(entries) ~= "table" or #entries == 0 then
      root:CreateTitle(emptyText)
      return
    end
    for _, entry in ipairs(entries) do
      local b = root:CreateButton(entry.text, function() if type(onPick) == "function" then onPick(entry) end end)
      if entry.icon ~= nil and type(b) == "table" and type(b.AddInitializer) == "function" then
        b:AddInitializer(function(button) matchIcon(button, entry.icon) end)
      end
    end
  end
  local menu = Compat.OpenMenu(owner, generate, "TOPLEFT", "BOTTOMLEFT", 0, -2)
  return menu
end

-- Closes a menu Kit.MatchMenu returned. Safe with nil or a closed menu.
-- (A WowStyle1 dropdown's menu, Kit.Dropdown, closes through Kit.CloseDropdown.)
function Kit.CloseMenu(menu)
  Compat.CloseMenu(menu)
end

-- Asks text with okText and cancelText through the game's StaticPopup (which) only: no window of Kit's own. onOk runs
-- once on okText, never on cancelText or Escape. True when the popup showed, false otherwise (the caller keeps its own).
-- Every % in text is doubled, because StaticPopup_Show formats def.text (StaticPopup.lua:521); || is left as passed.
-- Kit.Confirm doubles % the same way in its def. A second Ask with the same which replaces the first
-- popup (the def is set again, the game shows one popup per which).
function Kit.Ask(which, text, okText, cancelText, onOk)
  local safe = string.gsub(tostring(text or ""), "%%", "%%%%")
  local def = { text = safe, button1 = okText, button2 = cancelText, timeout = 0, whileDead = true, hideOnEscape = true,
    OnAccept = function() if type(onOk) == "function" then onOk() end end } -- returns nothing, so the popup hides
  return Compat.Popup(which, def)
end

-- ---------- the Crafters and Recipes pages' pieces. Kit reads no View or Craft code; no callbacks taken. ----------

local STAR_ON, STAR_OFF = "auctionhouse-icon-favorite", "auctionhouse-icon-favorite-off"
local DIVIDER_BG = { 1, 1, 1, 0.15 }

-- A favourite star: Kit's own Button 20x18, normal and HIGHLIGHT (ADD) textures on the star atlas, off at first.
-- Nil (no frame left shown) when the client lacks either star atlas: the caller keeps its own star.
function Kit.FavouriteStar(parent)
  if not atlasKnown(STAR_ON) or not atlasKnown(STAR_OFF) then return nil end
  local star = Compat.CreateFrame("Button", nil, parent)
  if not star then return nil end
  star:SetSize(20, 18)
  star.normalTex = star:CreateTexture(nil, "ARTWORK")
  star.normalTex:SetAllPoints(star)
  star.highlightTex = star:CreateTexture(nil, "HIGHLIGHT")
  star.highlightTex:SetAllPoints(star)
  star.highlightTex:SetBlendMode("ADD")
  star.isStar = true
  Kit.SetFavourite(star, false)
  return star
end

-- Puts a Kit.FavouriteStar on (auctionhouse-icon-favorite, highlight alpha 0.2) or off (-off, alpha 0.4), as the
-- auction house's favourite button. Anything that is not a Kit.FavouriteStar is left alone.
function Kit.SetFavourite(star, on)
  if type(star) ~= "table" or rawget(star, "isStar") ~= true then return end
  local name = on and STAR_ON or STAR_OFF
  Kit.Atlas(star.normalTex, name)
  Kit.Atlas(star.highlightTex, name)
  star.highlightTex:SetAlpha(on and 0.2 or 0.4)
end

-- A list row's hover: one HIGHLIGHT texture over frame on common-list-hoverbg-mid, else the fallback file in ADD.
function Kit.ListHover(frame, fallback)
  if not hasMethod(frame, "CreateTexture") then return nil end
  local hl = frame:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(frame)
  if not Kit.Atlas(hl, "common-list-hoverbg-mid", fallback) and hasMethod(hl, "SetBlendMode") then hl:SetBlendMode("ADD") end
  return hl
end

-- A recipe book row: Kit's own Button w x h with .toggle (14x14), .icon (16x16), .label, .active (Options_List_Active,
-- hidden) and a HIGHLIGHT hover (Options_List_Hover), as Kit.SideRow. Kit.SetBookRow fills and lays it out.
function Kit.BookRow(parent, w, h)
  local b = Compat.CreateFrame("Button", nil, parent)
  if not b then return nil end
  b.isBookRow = true
  b:SetSize(w, h)
  b.active = b:CreateTexture(nil, "BACKGROUND")
  b.active:SetAllPoints(b)
  Kit.Atlas(b.active, "Options_List_Active", ACTIVE_BG)
  b.active:Hide()
  b.hover = b:CreateTexture(nil, "HIGHLIGHT")
  b.hover:SetAllPoints(b)
  Kit.Atlas(b.hover, "Options_List_Hover", HOVER_BG)
  b.toggle = b:CreateTexture(nil, "ARTWORK")
  b.toggle:SetSize(14, 14)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(16, 16)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  b.label:SetJustifyH("LEFT")
  b.label:SetWordWrap(false)
  return b
end

local function placeLeft(region, row, x)
  region:ClearAllPoints()
  region:SetPoint("LEFT", row, "LEFT", x, 0)
end

-- spec = { kind = "prof" | "recipe", text, icon, open, chosen }. A profession row: the open or closed toggle at x 4
-- (UI-MinusButton / UI-PlusButton without the atlas), icon at 24, label at 44 in GameFontNormal. A recipe row: no
-- toggle, icon at 28, label at 48 in GameFontHighlightSmall, or GameFontHighlight with .active and no hover when
-- chosen. Every call sets all of it again. Anything that is not a Kit.BookRow is left alone.
function Kit.SetBookRow(row, spec)
  if type(row) ~= "table" or rawget(row, "isBookRow") ~= true then return end
  spec = type(spec) == "table" and spec or {}
  local chosen = false
  if spec.kind == "prof" then
    if spec.open then
      Kit.Atlas(row.toggle, "common-button-dropdown-open", "Interface\\Buttons\\UI-MinusButton-Up")
    else
      Kit.Atlas(row.toggle, "common-button-dropdown-closed", "Interface\\Buttons\\UI-PlusButton-Up")
    end
    row.toggle:Show()
    placeLeft(row.toggle, row, 4)
    placeLeft(row.icon, row, 24)
    placeLeft(row.label, row, 44)
    row.label:SetFontObject("GameFontNormal")
  else
    chosen = spec.chosen and true or false
    row.toggle:Hide()
    placeLeft(row.icon, row, 28)
    placeLeft(row.label, row, 48)
    row.label:SetFontObject(chosen and "GameFontHighlight" or "GameFontHighlightSmall")
  end
  Compat.SetIcon(row.icon, spec.icon)
  row.label:SetText(spec.text or "")
  row.active:SetShown(chosen)
  row.hover:SetShown(not chosen)
end

-- A horizontal divider texture on parent: Options_HorizontalDivider 2 tall (the professions recipe list's size), else
-- a 1-px colour line. The caller anchors it and sets its width.
function Kit.Divider(parent)
  if not hasMethod(parent, "CreateTexture") then return nil end
  local d = parent:CreateTexture(nil, "ARTWORK")
  d:SetHeight(Kit.Atlas(d, "Options_HorizontalDivider", DIVIDER_BG) and 2 or 1)
  return d
end

-- ---------- the module mocks' pieces (API 3, d384). No hub caller. ----------

local PILL_TONES = { gold = { 1, 0.82, 0 }, green = { 0.1, 1, 0.1 }, red = { 1, 0.13, 0.13 }, grey = { 0.6, 0.6, 0.6 } }
local PILL_BG = { 0, 0, 0, 0.5 }

-- Sets a Kit.Pill's text and tone ("gold" | "green" | "red" | "grey"; nil or any other tone draws gold). The width is
-- the measured text + 10, up to 140; 70 when the client does not measure.
function Kit.SetPill(pill, text, tone)
  if type(pill) ~= "table" or type(rawget(pill, "text")) ~= "table" then return end
  pill.text:SetText(text or "")
  local c = PILL_TONES[tone] or PILL_TONES.gold
  pill.text:SetTextColor(c[1], c[2], c[3])
  local w = pill.text:GetStringWidth()
  pill:SetWidth((type(w) == "number" and w > 0) and math.min(math.ceil(w) + 10, 140) or 70)
end

-- A status pill 21 tall: common-stat-bar-heavy-BG (.bg; a dark colour plate without the atlas) and .text
-- (GameFontNormalSmall, centred). Kit.SetPill sets its text, tone and width.
function Kit.Pill(parent, text, tone)
  local f = Compat.CreateFrame("Frame", nil, parent)
  if not f then return nil end
  f:SetHeight(21)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints(f)
  if Kit.Atlas(f.bg, "common-stat-bar-heavy-BG", PILL_BG) then Kit.SliceMargins(f.bg, 9, 9, 9, 9) end
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.text:SetPoint("CENTER", 0, 1)
  Kit.SetPill(f, text, tone)
  return f
end

local EXPAND_L, EXPAND_M = "Options_ListExpand_Left", "_Options_ListExpand_Middle"

-- The left cap mirrored as the right end (d393): its file with left/right tex coords swapped. False (texture hidden)
-- when the atlas info lacks the file or a coord.
local function mirrorLeftCap(tex)
  local info = Compat.AtlasInfo(EXPAND_L)
  local l, r, t, b = info and info.leftTexCoord, info and info.rightTexCoord, info and info.topTexCoord,
    info and info.bottomTexCoord
  if not (info and info.file ~= nil and type(l) == "number" and type(r) == "number" and type(t) == "number"
    and type(b) == "number" and hasMethod(tex, "SetTexture") and hasMethod(tex, "SetTexCoord")) then
    tex:Hide()
    return false
  end
  if not pcall(tex.SetTexture, tex, info.file) then tex:Hide() return false end
  tex:SetTexCoord(r, l, t, b)
  tex:Show()
  return true
end

-- A section header width x 26: the plain Options_ListExpand bar (the left cap 12, the middle stretched between, and
-- the left cap mirrored as the right end, 12; no Right atlas, whose fold glyph suggests a header that folds; d393)
-- and .label (GameFontNormal, gold) at (21,8). Without a file or tex coords for the mirror the middle runs to the
-- right edge. Without the left and middle atlases: the label over a Kit.Divider below (2 tall with its atlas, else
-- a 1-px rule).
function Kit.SectionHeader(parent, width, text)
  local f = Compat.CreateFrame("Frame", nil, parent)
  if not f then return nil end
  f:SetSize(width, 26)
  if atlasKnown(EXPAND_L) and atlasKnown(EXPAND_M) then
    local l = f:CreateTexture(nil, "BACKGROUND")
    local m = f:CreateTexture(nil, "BACKGROUND")
    local r = f:CreateTexture(nil, "BACKGROUND")
    Kit.Atlas(l, EXPAND_L)
    Kit.Atlas(m, EXPAND_M)
    l:SetSize(12, 26)
    l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    m:SetPoint("TOPLEFT", l, "TOPRIGHT", 0, 0)
    if mirrorLeftCap(r) then
      r:SetSize(12, 26)
      r:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
      m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", 0, 0)
    else
      m:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    end
  else
    local rule = Kit.Divider(f)
    if rule then
      rule:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
      rule:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    end
  end
  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.label:SetPoint("TOPLEFT", 21, -8)
  f.label:SetText(text)
  return f
end

-- Closes a Kit.Dropdown's open menu (DropdownButton:CloseMenu). Safe with nil, a closed dropdown or any other frame.
function Kit.CloseDropdown(dd)
  if hasMethod(dd, "CloseMenu") then pcall(dd.CloseMenu, dd) end
end
