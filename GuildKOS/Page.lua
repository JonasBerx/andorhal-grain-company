-- GuildKOS Page: the Kill on Sight page inside the GuildSync window (Hub.lua calls Build and Refresh).
-- A header (count, alerts line, Import), then one card per target on M.Kit.Card (start-zone painting, portrait, name,
-- race and class, last seen) in the page's own scroll frame. Clicking a card opens it in its row's place (the rows below
-- move down); Close shuts it. Creates nothing at load; every atlas and template goes through ns.Compat. Every
-- handler runs through src.safe (M.Safe), so a throw is recorded under the module and never escapes a click.
-- ns.Core and ns.Rules are looked up when used, so a test can replace their functions.
local _, ns = ...
local Page = {}
ns.Page = Page

local SKULL = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"
local RED = { 1, 0.125, 0.125 }          -- the enemy red (RED_FONT_COLOR)
local WARN = { 1, 0.5, 0.1 }             -- 0.3's orange for a one-word name
local DIM = { 0.7, 0.7, 0.7 }
local BORDER = { 0x8a / 255, 0x6d / 255, 0x1f / 255, 1 }
local CARD_BG = { 0, 0, 0, 0.3 }         -- only on a plain card (M.Kit.Card answered nil)
local SHADE_A = 0.78                     -- the opened painting's shade: 0 at its middle to .78 at its bottom
local ALERTS_GREY = { 0xb8 / 255, 0xb8 / 255, 0xb8 / 255 }
local CARD_HEIGHT, OPEN_HEIGHT, CARD_GAP = 72, 212, 8
local PAINT_W, PAINT_H, PORTRAIT = 112, 56, 30
local OPEN_PAINT_H, OPEN_PORTRAIT = 140, 56
local TEXT_X, OPEN_TEXT_X = 130, 80
local TEXT_RIGHT = -8   -- the card text's right inset: each line ends 8 px inside the card
local PAGE_W = 726      -- the page width until the page frame reports its own (View.SHELL.page)
local BOX_RIGHT = 16    -- the scroll box ends 16 px inside the page; its bar sits 4 px right of it (as M.Kit.List)
local CLASSIC_RIGHT = 24 -- UIPanelScrollFrameTemplate's wider classic bar, kept inside the page (R-n2)
local HEADER_H = 30
local WHEEL_STEP = 40
local ALERTS_ON = "Alerts on \194\183 /kos off turns them off"
local ALERTS_OFF = "Alerts off \194\183 /kos on turns them on"

local pages = setmetatable({}, { __mode = "k" })   -- frame -> the page's parts

-- ---------- pure helpers ----------

local RACE_ALIAS = { forsaken = "undead", scourge = "undead" }

-- The atlas key of a race or class name: lower case, spaces and apostrophes dropped; nil for none.
local function atlasKey(s)
  if type(s) ~= "string" then return nil end
  local key = s:lower():gsub("[%s']", "")
  if key == "" then return nil end
  return key
end

function Page.RaceKey(race)
  local key = atlasKey(race)
  return key and (RACE_ALIAS[key] or key)
end

-- The portrait atlases to try in order, then the file to fall back to. Every face is the male icon: 0.3 keeps no sex.
function Page.Portrait(race, class)
  local out = { file = SKULL }
  local r, c = Page.RaceKey(race), atlasKey(class)
  if r then out[#out + 1] = "raceicon128-" .. r .. "-male" end
  if c then out[#out + 1] = "classicon-" .. c end
  return out
end

-- Texcoords that cut the atlas to the box's aspect around its centre, inside the atlas's own texcoords.
-- nil on a missing or zero size (Forever raises on 0/0).
function Page.Crop(info, boxW, boxH)
  if type(info) ~= "table" then return nil end
  local w, h = info.width, info.height
  if type(w) ~= "number" or type(h) ~= "number" or type(boxW) ~= "number" or type(boxH) ~= "number" then return nil end
  if w <= 0 or h <= 0 or boxW <= 0 or boxH <= 0 then return nil end
  local l, r = info.leftTexCoord or 0, info.rightTexCoord or 1
  local t, b = info.topTexCoord or 0, info.bottomTexCoord or 1
  local u0, u1, v0, v1 = 0, 1, 0, 1
  if w / h > boxW / boxH then
    local keep = (h * boxW / boxH) / w
    u0, u1 = (1 - keep) / 2, (1 + keep) / 2
  else
    local keep = (w * boxH / boxW) / h
    v0, v1 = (1 - keep) / 2, (1 + keep) / 2
  end
  return l + (r - l) * u0, l + (r - l) * u1, t + (b - t) * v0, t + (b - t) * v1
end

-- The count text, also the selftest's (Hub.lua).
function Page.Targets(n)
  if n == 1 then return "1 target" end
  return n .. " targets"
end

-- fn(...) through src.safe (M.Safe: a throw is recorded under the module, the answer false), else pcall.
local function safe(src, fn, ...)
  if type(src.safe) == "function" then return src.safe(fn, ...) end
  return pcall(fn, ...)
end

-- The opened painting's shade: black, alpha SHADE_A at the bottom to 0 at the top (VERTICAL: minColor is the bottom).
-- SetGradient with CreateColor colours, else the older SetGradientAlpha, else a flat half alpha.
local function shadeFade(tex)
  local makeColor = CreateColor
  if type(makeColor) == "function" and type(tex.SetGradient) == "function"
    and pcall(tex.SetGradient, tex, "VERTICAL", makeColor(0, 0, 0, SHADE_A), makeColor(0, 0, 0, 0)) then return end
  if type(tex.SetGradientAlpha) == "function"
    and pcall(tex.SetGradientAlpha, tex, "VERTICAL", 0, 0, 0, SHADE_A, 0, 0, 0, 0) then return end
  tex:SetColorTexture(0, 0, 0, 0.4)
end

local function capital(s)
  return (s:gsub("^%l", string.upper))
end

-- "|cffRRGGBB" for a class name in its class colour (RAID_CLASS_COLORS), or nil.
local function classCode(class)
  local all = RAID_CLASS_COLORS
  local token = type(class) == "string" and class:upper():gsub("[%s']", "") or nil
  local col = type(all) == "table" and token and all[token] or nil
  if type(col) ~= "table" then return nil end
  local r, g, b = tonumber(col.r), tonumber(col.g), tonumber(col.b)
  if not (r and g and b) then return nil end
  local function byte(x) return math.max(0, math.min(255, math.floor(x * 255 + 0.5))) end
  return string.format("|cff%02x%02x%02x", byte(r), byte(g), byte(b))
end

-- ---------- building ----------

local function colourTexture(parent, layer, colour)
  local t = parent:CreateTexture(nil, layer)
  t:SetColorTexture(colour[1], colour[2], colour[3], colour[4])
  return t
end

-- A texture in a 1 px border; returns the texture and the border behind it.
local function framed(parent, w, h)
  local border = colourTexture(parent, "BORDER", BORDER)
  border:SetSize(w + 2, h + 2)
  local tex = parent:CreateTexture(nil, "ARTWORK")
  tex:SetSize(w, h)
  tex:SetPoint("CENTER", border, "CENTER", 0, 0)
  return tex, border
end

local function button(parent, text, w)
  local b
  if ns.Compat.HasTemplate("UIPanelButtonTemplate") then
    b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetText(text)
  else
    b = CreateFrame("Button", nil, parent)
    local bg = colourTexture(b, "BACKGROUND", { 0.25, 0.05, 0.05, 0.9 })
    bg:SetAllPoints(b)
    local label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(text)
  end
  b:SetSize(w, 22)
  return b
end

-- The list's scroll frame (f4697), by what the client has:
-- * ScrollFrameTemplate: its MinimalScrollBar is made in the template's OnLoad and owns OnMouseWheel, OnVerticalScroll
--   and OnScrollRangeChanged (setting one unhooks the bar), so none is set here; the bar moves 4 px right of the box.
--   The template clamps itself.
-- * UIPanelScrollFrameTemplate: named, as the classic template looks up <name>ScrollBar; it clamps itself.
-- * Neither: a plain frame with the page's own wheel; layout() clamps it after every pass.
local function scrollFrame(parent)
  local scroll, plain, right = nil, nil, BOX_RIGHT
  if ns.Compat.HasTemplate("ScrollFrameTemplate") then
    scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
    local bar = scroll.ScrollBar
    if type(bar) == "table" then
      bar:ClearAllPoints()
      bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
      bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    end
  elseif ns.Compat.HasTemplate("UIPanelScrollFrameTemplate") then
    scroll = CreateFrame("ScrollFrame", "GuildKOSPageScroll", parent, "UIPanelScrollFrameTemplate")
    right = CLASSIC_RIGHT
  else
    plain = true
    scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
      local page = pages[parent]
      local range = math.max(0, (page and page.contentHeight or 0) - (tonumber(self:GetHeight()) or 0))
      local at = (tonumber(self:GetVerticalScroll()) or 0) - delta * WHEEL_STEP
      self:SetVerticalScroll(math.min(range, math.max(0, at)))
    end)
    scroll:SetVerticalScroll(0)
  end
  return scroll, plain, right
end

-- Places a card text line: anchored to both sides of the card, so a long text is cut, never spills (S-f2).
local function place(fs, x, y)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetPoint("TOPRIGHT", TEXT_RIGHT, y)
end

local function textLine(f, font, x, y)
  local fs = f:CreateFontString(nil, "OVERLAY", font)
  place(fs, x, y)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  return fs
end

-- Card heights, places and open parts from page.open; the content height; the plain frame's clamp. No data read.
local function layout(page)
  local w = (page.width or PAGE_W) - page.boxRight
  local y = 0
  for i = 1, page.n do
    local cd = page.cards[i]
    local f = cd.frame
    local open = page.open ~= nil and cd.key == page.open
    local h = open and OPEN_HEIGHT or CARD_HEIGHT
    f:SetSize(w, h)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", page.content, "TOPLEFT", 0, -y)
    y = y + h + CARD_GAP

    local pw, ph = PAINT_W, PAINT_H
    if open then pw, ph = w - 6, OPEN_PAINT_H end
    cd.paintBorder:ClearAllPoints()
    if open then cd.paintBorder:SetPoint("TOPLEFT", 2, -2) else cd.paintBorder:SetPoint("TOPLEFT", 7, -7) end
    cd.paintBorder:SetSize(pw + 2, ph + 2)
    cd.painting:SetSize(pw, ph)
    if cd.zone then
      local l, r, t, b = Page.Crop(ns.Compat.AtlasInfo(cd.zone), pw, ph)
      if l then cd.painting:SetTexCoord(l, r, t, b) end
      cd.painting:Show()
      cd.paintBorder:Show()
    else
      cd.painting:Hide()
      cd.paintBorder:Hide()
    end
    cd.shade:SetShown(open and cd.zone ~= nil)

    local size = open and OPEN_PORTRAIT or PORTRAIT
    cd.portraitBorder:ClearAllPoints()
    if open then cd.portraitBorder:SetPoint("TOPLEFT", 13, -76) else cd.portraitBorder:SetPoint("TOPLEFT", 7, -33) end
    cd.portraitBorder:SetSize(size + 2, size + 2)
    cd.portrait:SetSize(size, size)

    cd.who:SetShown(not open and cd.hasWho)
    cd.bigWho:SetShown(open and cd.hasWho)
    cd.name:SetShown(not open)
    cd.status:SetShown(not open)
    cd.bigName:SetShown(open)
    cd.seenLabel:SetShown(open)
    cd.seen:SetShown(open)
    if cd.divider then cd.divider:SetShown(open) end
    cd.close:SetShown(open)
    cd.catcher:SetShown(not open)
    -- f4698: the catcher above the card, Close above the catcher (the sim and InsetFrameTemplate share levels)
    local base = tonumber(f:GetFrameLevel()) or 1
    cd.catcher:SetFrameLevel(base + 1)
    cd.close:SetFrameLevel(base + 2)
  end

  page.contentHeight = y
  page.content:SetSize(w, math.max(1, y))
  if page.plain then
    local view = tonumber(page.scroll:GetHeight()) or 0
    local cur = tonumber(page.scroll:GetVerticalScroll()) or 0
    page.scroll:SetVerticalScroll(math.min(cur, math.max(0, y - view)))
  end
end

local function setOpen(page, key)
  page.open = key
  safe(page.src, layout, page)
end

function Page.Build(frame, src)
  local page = { cards = {}, n = 0, contentHeight = 0, src = src }
  pages[frame] = page

  page.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  page.count:SetPoint("TOPLEFT", 4, -5)
  page.count:SetJustifyH("LEFT")

  local import = button(frame, "Import", 90)
  import:SetPoint("TOPRIGHT", -BOX_RIGHT, -4)
  import:SetScript("OnClick", function() safe(page.src, page.src.openImport) end)

  page.alerts = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  page.alerts:SetPoint("RIGHT", import, "LEFT", -12, 0)
  page.alerts:SetJustifyH("RIGHT")
  page.alerts:SetTextColor(ALERTS_GREY[1], ALERTS_GREY[2], ALERTS_GREY[3])

  local scroll, plain, right = scrollFrame(frame)
  page.boxRight = right
  scroll:SetPoint("TOPLEFT", 0, -HEADER_H)
  scroll:SetPoint("BOTTOMRIGHT", -right, 0)
  -- created with the scroll as parent, then set as its scroll child
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  page.scroll, page.content, page.plain = scroll, content, plain

  page.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  page.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 12, -4)
  page.empty:SetJustifyH("LEFT")

  frame:SetScript("OnSizeChanged", function(_, w)
    if type(w) == "number" and w > 0 then
      page.width = w
      safe(page.src, layout, page)
    end
  end)
end

-- One card: M.Kit.Card (or a plain frame when it answers nil), then its regions on the layers of f4699 (no Page.lua
-- region on BACKGROUND on a Kit card), the click catcher, then Close (f4698).
local function card(page, i)
  local cd = page.cards[i]
  if cd then return cd end
  local kit = page.src.kit
  local w = (page.width or PAGE_W) - page.boxRight
  local f = kit and kit.Card and kit.Card(page.content, w, CARD_HEIGHT) or nil
  if not f then
    f = CreateFrame("Frame", nil, page.content)
    f:SetSize(w, CARD_HEIGHT)
    local bg = colourTexture(f, "BACKGROUND", CARD_BG)
    bg:SetAllPoints(f)
  end

  cd = { frame = f }
  cd.painting, cd.paintBorder = framed(f, PAINT_W, PAINT_H)
  cd.painting:SetDrawLayer("ARTWORK", 0)
  cd.shade = colourTexture(f, "ARTWORK", { 0, 0, 0, 1 })
  cd.shade:SetDrawLayer("ARTWORK", 1)
  cd.shade:SetPoint("BOTTOMLEFT", cd.painting, "BOTTOMLEFT", 0, 0)   -- the painting's lower half
  cd.shade:SetPoint("BOTTOMRIGHT", cd.painting, "BOTTOMRIGHT", 0, 0)
  cd.shade:SetHeight(OPEN_PAINT_H * 0.5)
  shadeFade(cd.shade)
  cd.shade:Hide()
  cd.portrait, cd.portraitBorder = framed(f, PORTRAIT, PORTRAIT)
  cd.portraitBorder:SetDrawLayer("ARTWORK", 2)   -- the portrait sits over the painting's lower left
  cd.portrait:SetDrawLayer("ARTWORK", 3)

  cd.name = textLine(f, "GameFontHighlight", TEXT_X, -10)
  cd.name:SetTextColor(RED[1], RED[2], RED[3])
  cd.who = textLine(f, "GameFontHighlightSmall", TEXT_X, -28)
  cd.status = textLine(f, "GameFontHighlightSmall", TEXT_X, -46)

  -- the opened card's parts (DIFF.md 2a): name over the painting, one "Last seen" row, a divider, Close
  cd.bigName = textLine(f, "GameFontNormalLarge", OPEN_TEXT_X, -96)
  cd.bigWho = textLine(f, "GameFontHighlight", OPEN_TEXT_X, -118)
  cd.seenLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  cd.seenLabel:SetPoint("TOPLEFT", 12, -152)
  cd.seenLabel:SetText("Last seen")
  cd.seen = textLine(f, "GameFontHighlight", 92, -150)
  cd.divider = kit and kit.Divider and kit.Divider(f) or nil
  if cd.divider then
    cd.divider:SetPoint("TOPLEFT", 3, -176)
    cd.divider:SetPoint("TOPRIGHT", -3, -176)
  end

  cd.catcher = CreateFrame("Button", nil, f)
  cd.catcher:SetAllPoints(f)
  cd.catcher:RegisterForClicks("LeftButtonUp")
  cd.catcher:SetScript("OnClick", function() setOpen(page, cd.key) end)
  cd.close = button(f, "Close", 64)
  cd.close:SetPoint("BOTTOMRIGHT", -16, 8)
  cd.close:SetScript("OnClick", function() setOpen(page, nil) end)
  page.cards[i] = cd
  return cd
end

local function setArt(cd, entry)
  local race = Page.RaceKey(entry.race)
  local zone = race and "charactercreate-startingzone-" .. race
  cd.zone = (zone and ns.Compat.Atlas(cd.painting, zone, nil)) and zone or nil

  local tries = Page.Portrait(entry.race, entry.class)
  local drawn = false
  for _, atlas in ipairs(tries) do
    if ns.Compat.Atlas(cd.portrait, atlas, nil) then drawn = true break end
  end
  if not drawn then ns.Compat.Atlas(cd.portrait, nil, tries.file) end
end

local function nonEmpty(s) return type(s) == "string" and s ~= "" end

-- A list field drawn as text: control bytes (newline, NUL, ...) become a space, Rules.Strip drops the direction and
-- invisible code points, then "|" is escaped (S-f1).
local function shown(src, s)
  return src.escape(ns.Rules.Strip((s:gsub("[%z\1-\31\127]", " "))))
end

function Page.Refresh(frame, src)
  local page = pages[frame]
  if not page then return end
  page.src = src
  local Rules, Core = ns.Rules, ns.Core
  local db = Core.DB()
  local list, lastSeen = src.data()
  local entries = (list and list.targets) or {}
  local n = #entries

  page.count:SetText(Page.Targets(n))
  page.alerts:SetText(db.muted and ALERTS_OFF or ALERTS_ON)
  if list == nil then
    page.empty:SetText(Rules.HeaderLine(nil))
    page.empty:Show()
  else
    page.empty:Hide()
  end

  local rows = Rules.ListRows(list, lastSeen, Core.Now())
  local openFound = false
  for i, entry in ipairs(entries) do
    local cd = card(page, i)
    local row = rows[i] or {}
    cd.key = nonEmpty(entry.target) and entry.target:lower() or ("#" .. i)
    if cd.key == page.open then openFound = true end
    local name = nonEmpty(entry.target) and shown(src, entry.target) or ""
    cd.name:SetText(name)
    cd.bigName:SetText(name)
    local parts = {}
    if nonEmpty(entry.race) then parts[#parts + 1] = shown(src, entry.race) end
    if nonEmpty(entry.class) then
      local class = shown(src, entry.class)
      local code = classCode(entry.class)
      parts[#parts + 1] = code and (code .. class .. "|r") or class
    end
    cd.who:SetText(table.concat(parts, " "))
    cd.bigWho:SetText(table.concat(parts, " "))
    cd.hasWho = #parts > 0
    -- Drawn as Rules.ListRows gives it, not escaped again: Rules.Clean already doubles "|" and drops control bytes in
    -- zone, subzone and by, a superset of GuildSync.Escape. A second escape would show "||||".
    local status = row.status or ""
    local colour = row.warn and WARN or DIM
    cd.status:SetText(capital(status))
    cd.status:SetTextColor(colour[1], colour[2], colour[3])
    cd.seen:SetText(status == "never seen" and "Never" or capital((status:gsub("^seen ", ""))))
    local seenColour = row.warn and WARN or { 1, 1, 1 }
    cd.seen:SetTextColor(seenColour[1], seenColour[2], seenColour[3])
    setArt(cd, entry)
    cd.frame:Show()
  end
  for i = n + 1, #page.cards do page.cards[i].frame:Hide() end
  if not openFound then page.open = nil end
  page.n = n

  local w = tonumber(frame:GetWidth())
  if not page.width and w and w > 0 then page.width = w end
  layout(page)
end

return Page
