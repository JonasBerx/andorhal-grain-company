-- GuildKOS Page: the Kill on Sight page inside the GuildSync window (Hub.lua calls Build and Refresh).
-- What ships (ns.Probe.kills false, 0.6, d1821): a tab strip (M.Kit.Tabs: List, Waiting, Mine) over one scroll frame
-- whose scroll child is swapped per tab, and no kill count anywhere. List: the header (count, alerts line), the fixed
-- Mark as bounty card (Name and Why boxes: a typed name goes to ns.Mark.FromName, else ns.Mark.FromTarget), then
-- one card per open target on M.Kit.Card (start-zone painting, portrait, name, level line or "Added by name", last
-- seen, why). Clicking a card opens it in its row's place, 252 tall (Last seen, Why, Marked; Edit why and Remove
-- for officers, Close for all; Edit why opens an input box with Save and Cancel, d791). Waiting: ns.Mark.Waiting()'s
-- marks, Approve and Reject for officers (kos-3), read-only for a member (kos-3b). Mine: "Your marks", each with
-- ns.RulesMarks.State as its pill and Withdraw while it waits (kos-6).
-- What ns.Probe.kills true adds (batch 4): the Kills and Hunters tabs (Hunters: the board, RulesBoard.Rows, and the
-- line for me), the closed card's kill count and the opened card's Kills row (272 tall). Kills and Mine's claims wait
-- (d794).
-- Under /gsync demo (d793 c) every tab draws the hub's demo state (src.demo) and no button writes.
-- Creates nothing at load; atlases go through M.Kit.Atlas (src.kit), template and atlas reads through the local info()
-- below. Every handler runs through src.safe (M.Safe), so a throw is recorded under the module and never escapes a
-- click. ns.Core, ns.List, ns.Mark and ns.Store are looked up when used, so a test can replace their functions.
local _, ns = ...
local Page = {}
ns.Page = Page

local SKULL = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"
local RED = { 1, 0.125, 0.125 }          -- the enemy red (RED_FONT_COLOR)
local DIM = { 0.7, 0.7, 0.7 }
local BORDER = { 0x8a / 255, 0x6d / 255, 0x1f / 255, 1 }
local CARD_BG = { 0, 0, 0, 0.3 }         -- only on a plain card (M.Kit.Card answered nil)
local SHADE_A = 0.78                     -- the opened painting's shade: 0 at its middle to .78 at its bottom
local ALERTS_GREY = { 0xb8 / 255, 0xb8 / 255, 0xb8 / 255 }
local GOLD = "|cffffd100"
local CARD_HEIGHT, OPEN_HEIGHT, CARD_GAP = 84, 272, 8
local PAINT_W, PAINT_H, PORTRAIT = 112, 68, 30
local OPEN_PAINT_H, OPEN_PORTRAIT = 140, 56
local TEXT_X, OPEN_TEXT_X = 130, 80
local TEXT_RIGHT = -8   -- the card text's right inset: each line ends 8 px inside the card
local NAME_RIGHT = -70  -- the name line stops short of the kill count
local PAGE_W = 726      -- the page width until the page frame reports its own (View.SHELL.page)
local BOX_RIGHT = 16    -- the scroll box ends 16 px inside the page; its bar sits 4 px right of it (as M.Kit.List)
local CLASSIC_RIGHT = 24 -- UIPanelScrollFrameTemplate's wider classic bar, kept inside the page (R-n2)
local TOP = 40          -- the 32-tall tab row and 8 px (o859)
local MARK_Y, MARK_H = 66, 66            -- the fixed Mark as bounty card (o851)
local NAME_BOX_W = 150                   -- the Name box, left of the Why box with 8 px between (add by name)
-- the Why box: 420, or less so it ends 8 px before the button (f8600), right of the Name box
local MARK_BOX_W, MARK_BOX_LESS = 420, 14 + 16 + 120 + 8 + NAME_BOX_W + 8
local LIST_TOP = MARK_Y + MARK_H + 8     -- the List tab's scroll frame
local ROW_H, ROW_STEP, ROWS_Y = 34, 38, 50  -- the Hunters board rows
local COLS = { { "", 42 }, { "Hunter", 180 }, { "Confirmed kills", 252 }, { "Streak", 80 }, { "Best", 70 },
  { "Last kill", 86 } }
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"   -- the Hunters bar fill (as Harvest.lua)
local BAR_GOLD = { 1, 0.769, 0.251 }
local WHEEL_STEP = 40
local DAY = 86400
local DOT = " \194\183 "
local DASH = "\226\128\147"
local ALERTS_ON = "Alerts on \194\183 /kos off turns them off"
local ALERTS_OFF = "Alerts off \194\183 /kos on turns them on"
local MARK_HINT = "Type a name (first and surname) in the first box, or target an enemy. An officer approves a "
  .. "member's mark."
local HUNTERS_INTRO = "Top 10 by confirmed kills. A kill counts once an officer confirms it. Streak: weeks in a row "
  .. "with a confirmed kill."
local MARK_H2, STRIP_Y = 116, 89       -- a mark card with buttons: the 84 block, a divider at 84, the strip at y 89
local WAIT_TOP, MINE_TOP = 30, 34        -- the first mark card under Waiting's header and under "Your marks"
local OFFICER_NOTE = "Members see only their own marks here."
local MEMBER_NOTE = "Only your own marks show here."
local TONES = { waiting = "gold", approved = "green", rejected = "red", removed = "grey" }
local TABS = { { key = "list", text = "List" }, { key = "waiting", text = "Waiting" }, { key = "kills", text = "Kills" },
  { key = "hunters", text = "Hunters" }, { key = "mine", text = "Mine" } }
local TABS_OFF = { TABS[1], TABS[2], TABS[5] }
local OPEN_HEIGHT_OFF = OPEN_HEIGHT - 20  -- the opened card with no Kills row (gate A correction 3)

-- ns.Probe.kills (RulesMarks, d1821), read at call time: false = no Kills or Hunters tab and no kill texts.
local function killsOn() return type(ns.Probe) == "table" and ns.Probe.kills == true end
local function openHeight() return killsOn() and OPEN_HEIGHT or OPEN_HEIGHT_OFF end

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

local function plural(n, one)
  if n == 1 then return "1 " .. one end
  return n .. " " .. one .. "s"
end

-- "just now", "N min ago", "N h ago", "N days ago" for a time diff in seconds (constant divisors only).
local function ago(diff)
  diff = math.max(0, tonumber(diff) or 0)
  if diff < 60 then return "just now" end
  if diff < 3600 then return math.floor(diff / 60) .. " min ago" end
  if diff < DAY then return math.floor(diff / 3600) .. " h ago" end
  return plural(math.floor(diff / 86400), "day") .. " ago"
end

-- fn(...) through src.safe (M.Safe: a throw is recorded under the module, the answer false), else pcall.
local function safe(src, fn, ...)
  if type(src.safe) == "function" then return src.safe(fn, ...) end
  return pcall(fn, ...)
end

-- The client's template and atlas reads, through the handle's M.Compat (src.compat, set at Build; d761, d793): what
-- the call answers as a table, or nil (no handle, not listed, missing, or an error).
local compat
local function info(fn, name)
  if type(name) ~= "string" or type(compat) ~= "table" or type(compat.Try) ~= "function" then return nil end
  local ok, v = compat.Try(fn, name)
  if ok and type(v) == "table" then return v end
  return nil
end
local function hasTemplate(name) return info("C_XMLUtil.GetTemplateInfo", name) ~= nil end
local function atlasInfo(name) return info("C_Texture.GetAtlasInfo", name) end

-- kit.Atlas(tex, name, fallback) when the hub's kit is there, else false.
local function atlas(kit, tex, name, fallback)
  if type(kit) ~= "table" or type(kit.Atlas) ~= "function" then return false end
  return kit.Atlas(tex, name, fallback) == true
end

-- kit[piece](...) when the hub's kit has it, else nil.
local function kitCall(kit, piece, ...)
  if type(kit) ~= "table" or type(kit[piece]) ~= "function" then return nil end
  return kit[piece](...)
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

local function nonEmpty(s) return type(s) == "string" and s ~= "" end

-- An other player's text drawn as text: control bytes (newline, NUL, ...) become a space, then "|" is escaped (S-f1).
local function shown(src, s)
  if type(s) ~= "string" then return "" end
  return src.escape((s:gsub("[%z\1-\31\127]", " ")))
end

-- The hub demo's state while /gsync demo is on (Hub.lua's src.demo), else nil.
local function demoOf(src)
  if type(src.demo) ~= "function" then return nil end
  local state = src.demo()
  return type(state) == "table" and state or nil
end

-- Every write button asks first (d793 c): under /gsync demo it prints one line and writes nothing. The sim's Click runs
-- a disabled button's OnClick too (f5406), so the handler holds, not the button state.
local function demoRefused()
  if not (ns.Hub and ns.Hub.InDemo()) then return false end
  print("KOS: " .. ns.List.RefusalLine("demo"))
  return true
end

local function refused(why) print("KOS: " .. ns.List.RefusalLine(why)) end

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

-- A 22-tall button with its text in its own font string (the button's, through SetFontString).
local function button(parent, text, w)
  local b
  if hasTemplate("UIPanelButtonTemplate") then
    b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  else
    b = CreateFrame("Button", nil, parent)
    local bg = colourTexture(b, "BORDER", { 0.25, 0.05, 0.05, 0.9 })
    bg:SetAllPoints(b)
  end
  local label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetPoint("CENTER", 0, 0)
  label:SetText(text)
  if type(b.SetFontString) == "function" then b:SetFontString(label) end
  b:SetSize(w, 22)
  return b
end

-- A card w x h: M.Kit.Card, or a plain frame when it answers nil.
local function makeCard(kit, parent, w, h)
  local f = kitCall(kit, "Card", parent, w, h)
  if not f then
    f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    local bg = colourTexture(f, "BACKGROUND", CARD_BG)
    bg:SetAllPoints(f)
  end
  return f
end

-- The page's scroll frame (f4697), by what the client has:
-- * ScrollFrameTemplate: its MinimalScrollBar is made in the template's OnLoad and owns OnMouseWheel, OnVerticalScroll
--   and OnScrollRangeChanged (setting one unhooks the bar), so none is set here; the bar moves 4 px right of the box.
--   The template clamps itself.
-- * UIPanelScrollFrameTemplate: named, as the classic template looks up <name>ScrollBar; it clamps itself.
-- * Neither: a plain frame with the page's own wheel; layout() clamps it after every pass.
local function scrollFrame(parent)
  local scroll, plain, right = nil, nil, BOX_RIGHT
  if hasTemplate("ScrollFrameTemplate") then
    scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
    local bar = scroll.ScrollBar
    if type(bar) == "table" then
      bar:ClearAllPoints()
      bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
      bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
    end
  elseif hasTemplate("UIPanelScrollFrameTemplate") then
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
local function place(fs, x, y, right)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetPoint("TOPRIGHT", right or TEXT_RIGHT, y)
end

local function textLine(f, font, x, y, right)
  local fs = f:CreateFontString(nil, "OVERLAY", font)
  place(fs, x, y, right)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  return fs
end

-- The content height of the active tab and the plain frame's clamp.
local function setContentHeight(page, child, h)
  child:SetSize((page.width or PAGE_W) - page.boxRight, math.max(1, h))
  if child ~= page.children[page.tab] then return end
  page.contentHeight = h
  if page.plain then
    local view = tonumber(page.scroll:GetHeight()) or 0
    local cur = tonumber(page.scroll:GetVerticalScroll()) or 0
    page.scroll:SetVerticalScroll(math.min(cur, math.max(0, h - view)))
  end
end

-- ---------- List: the cards ----------

-- Card heights, places and open parts from page.open; the content height. No data read.
local function layout(page)
  local w = (page.width or PAGE_W) - page.boxRight
  local markW = (page.width or PAGE_W) - BOX_RIGHT
  if page.mark then page.mark:SetWidth(markW) end
  if page.markBox then page.markBox:SetWidth(math.min(MARK_BOX_W, markW - MARK_BOX_LESS)) end
  local y = 0
  for i = 1, page.n do
    local cd = page.cards[i]
    local f = cd.frame
    local open = page.open ~= nil and cd.key == page.open
    local h = open and openHeight() or CARD_HEIGHT
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
      local l, r, t, b = Page.Crop(atlasInfo(cd.zone), pw, ph)
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
    if open then cd.portraitBorder:SetPoint("TOPLEFT", 13, -76) else cd.portraitBorder:SetPoint("TOPLEFT", 7, -45) end
    cd.portraitBorder:SetSize(size + 2, size + 2)
    cd.portrait:SetSize(size, size)

    if cd.kills then
      cd.kills:ClearAllPoints()
      if open then cd.kills:SetPoint("TOPRIGHT", -12, -124) else cd.kills:SetPoint("TOPRIGHT", -10, -11) end
    end

    cd.who:SetShown(not open and cd.hasWho)
    cd.bigWho:SetShown(open and cd.hasWho)
    cd.name:SetShown(not open)
    cd.status:SetShown(not open)
    cd.why:SetShown(not open and cd.hasWhy)
    cd.bigName:SetShown(open)
    local editing = open and page.canWrite and cd.box ~= nil and page.editing == cd.key
    for _, fs in ipairs(cd.rows) do fs:SetShown(open) end
    cd.whyValue:SetShown(open and not editing)   -- the box takes the Why row's place while editing (d791)
    if cd.divider then cd.divider:SetShown(open) end
    cd.close:SetShown(open)
    cd.edit:SetShown(open and page.canWrite and not editing)
    cd.remove:SetShown(open and page.canWrite and not editing)
    if cd.box then cd.box:SetShown(editing) end
    cd.save:SetShown(editing)
    cd.cancel:SetShown(editing)
    cd.catcher:SetShown(not open)
    -- f4698: the catcher above the card, the buttons above the catcher (the sim and InsetFrameTemplate share levels)
    local base = tonumber(f:GetFrameLevel()) or 1
    cd.catcher:SetFrameLevel(base + 1)
    for _, b in ipairs({ cd.close, cd.edit, cd.remove, cd.save, cd.cancel }) do b:SetFrameLevel(base + 2) end
  end
  setContentHeight(page, page.content, y)
end

local function setOpen(page, key)
  page.open = key
  page.editing = nil
  safe(page.src, layout, page)
end

-- Edit why (d791): the box on the opened card holds the stored why; Save writes it through ns.List.EditWhy, Cancel
-- writes nothing.
local function editWhy(page, cd)
  if not cd.box then return end
  page.editing = cd.key
  cd.box:SetText(cd.rawWhy or "")
  layout(page)
end

local function saveWhy(page, cd)
  if demoRefused() or not cd.box then return end
  local done, why = ns.List.EditWhy(cd.guid, cd.box:GetText() or "", ns.Core.Now())
  if done then page.editing = nil else refused(why) end
  Page.Refresh(page.frame, page.src)
end

local function cancelWhy(page)
  page.editing = nil
  layout(page)
end

-- Remove the opened target (after the kit's confirm when there is one), then redraw.
local function removeTarget(page, cd)
  local guid, frame = cd.guid, page.frame
  local function go()
    if demoRefused() then return end
    local done, why = ns.List.Remove(guid, ns.Core.Now())
    if done then page.open = nil else refused(why) end
    Page.Refresh(frame, page.src)
  end
  local kit = page.src.kit
  if type(kit) == "table" and type(kit.Confirm) == "function" then
    kit.Confirm("remove", "Remove " .. cd.shownName .. " from the list?", "Remove", go)
  else
    go()
  end
end

-- An opened card's row: a label and its value.
local function openRow(cd, f, label, y)
  local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  l:SetPoint("TOPLEFT", 14, y)
  l:SetText(label)
  local v = textLine(f, "GameFontHighlight", 96, y + 2)
  cd.rows[#cd.rows + 1] = l
  cd.rows[#cd.rows + 1] = v
  return l, v
end

-- One card: M.Kit.Card (or a plain frame when it answers nil), then its regions on the layers of f4699 (no Page.lua
-- region on BACKGROUND on a Kit card), the click catcher, then Edit why, Remove and Close (f4698).
local function card(page, i)
  local cd = page.cards[i]
  if cd then return cd end
  local kit = page.src.kit
  local w = (page.width or PAGE_W) - page.boxRight
  local f = makeCard(kit, page.content, w, CARD_HEIGHT)

  cd = { frame = f, rows = {} }
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

  -- the closed card (o850): name, level line, seen line, Why line, the kill count at the top right (kills on)
  cd.name = textLine(f, "GameFontHighlight", TEXT_X, -10, NAME_RIGHT)
  cd.name:SetTextColor(RED[1], RED[2], RED[3])
  cd.who = textLine(f, "GameFontHighlight", TEXT_X, -28)
  cd.status = textLine(f, "GameFontHighlightSmall", TEXT_X, -46)
  cd.status:SetTextColor(DIM[1], DIM[2], DIM[3])
  cd.why = textLine(f, "GameFontHighlightSmall", TEXT_X, -64)
  local kills = killsOn()
  if kills then
    cd.kills = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cd.kills:SetJustifyH("RIGHT")
  end

  -- the opened card (kos-2): name and level line over the painting, four rows (no Kills row with kills off), a
  -- divider, the buttons
  cd.bigName = textLine(f, "GameFontNormalLarge", OPEN_TEXT_X, -96)   -- the font's own gold (kos-2, f8561)
  cd.bigWho = textLine(f, "GameFontHighlight", OPEN_TEXT_X, -118)
  local _
  _, cd.seen = openRow(cd, f, "Last seen", -154)
  _, cd.whyValue = openRow(cd, f, "Why", -174)
  _, cd.marked = openRow(cd, f, "Marked", -194)
  if kills then cd.killsLabel, cd.killList = openRow(cd, f, "Kills", -214) end
  local dy = kills and -236 or -216
  cd.divider = kitCall(kit, "Divider", f)
  if cd.divider then
    cd.divider:SetPoint("TOPLEFT", 3, dy)
    cd.divider:SetPoint("TOPRIGHT", -3, dy)
  end

  cd.catcher = CreateFrame("Button", nil, f)
  cd.catcher:SetAllPoints(f)
  cd.catcher:RegisterForClicks("LeftButtonUp")
  cd.catcher:SetScript("OnClick", function() safe(page.src, setOpen, page, cd.key) end)
  cd.edit = button(f, "Edit why", 90)
  cd.edit:SetScript("OnClick", function() safe(page.src, editWhy, page, cd) end)
  cd.remove = button(f, "Remove", 74)
  cd.remove:SetScript("OnClick", function() safe(page.src, removeTarget, page, cd) end)
  cd.close = button(f, "Close", 64)
  cd.close:SetPoint("BOTTOMRIGHT", -16, 6)
  cd.close:SetScript("OnClick", function() safe(page.src, setOpen, page, nil) end)
  cd.remove:SetPoint("RIGHT", cd.close, "LEFT", -6, 0)
  cd.edit:SetPoint("RIGHT", cd.remove, "LEFT", -6, 0)
  -- Edit why's box over the Why row, Save and Cancel in Edit why's and Remove's place (d791; DIFF.md draws none)
  cd.box = kitCall(kit, "InputBox", f, 420, 400)
  if cd.box then
    cd.box:SetPoint("TOPLEFT", 100, -170)
    cd.box:Hide()
  end
  cd.cancel = button(f, "Cancel", 74)
  cd.cancel:SetPoint("RIGHT", cd.close, "LEFT", -6, 0)
  cd.cancel:SetScript("OnClick", function() safe(page.src, cancelWhy, page) end)
  cd.save = button(f, "Save", 64)
  cd.save:SetPoint("RIGHT", cd.cancel, "LEFT", -6, 0)
  cd.save:SetScript("OnClick", function() safe(page.src, saveWhy, page, cd) end)
  page.cards[i] = cd
  return cd
end

local function setArt(cd, rec, kit)
  local race = Page.RaceKey(rec.race)
  local zone = race and "charactercreate-startingzone-" .. race
  cd.zone = (zone and atlas(kit, cd.painting, zone, nil)) and zone or nil

  local tries = Page.Portrait(rec.race, rec.class)
  local drawn = false
  for _, name in ipairs(tries) do
    if atlas(kit, cd.portrait, name, nil) then drawn = true break end
  end
  if not drawn then atlas(kit, cd.portrait, nil, tries.file) end
end

-- A member key drawn as the roster's display name, else the key itself, else "?"; each through RulesRecords.Safe
-- (f8503, f8535/d1831), escaped either way.
local function memberName(src, roster, key)
  local row = type(key) == "string" and roster[key] or nil
  local name = type(row) == "table" and type(row.name) == "string" and ns.RulesRecords.Safe(row.name) or ""
  if name == "" and type(key) == "string" then name = ns.RulesRecords.Safe(key) end
  if name == "" then name = "?" end
  return shown(src, name)
end

-- The seen line from this guild's lastSeen: "Never seen", or "Seen <ago> at <place>[ by <who>]".
local function seenText(src, seen, now)
  if type(seen) ~= "table" or type(seen.at) ~= "number" then return nil end
  local zone, sub = shown(src, seen.zone), shown(src, seen.subzone)
  local at = (sub ~= "" and sub ~= zone) and (sub .. ", " .. zone) or zone
  local line = ago(now - seen.at) .. " at " .. at
  if nonEmpty(seen.by) then line = line .. " by " .. shown(src, seen.by) end
  return line
end

-- True for a name entry's synthetic key (RulesMarks.IsNameKey); false with no RulesMarks.
local function isNameKey(guid)
  local marks = ns.RulesMarks
  return type(marks) == "table" and type(marks.IsNameKey) == "function" and marks.IsNameKey(guid) == true
end

-- "Level 60 Human Rogue" (the class in its class colour). When the record holds none of them: RulesMarks.NAME_WHO
-- under a name key guid, else "".
local function whoText(src, rec, guid)
  local parts = {}
  if type(rec.level) == "number" and rec.level > 0 then parts[#parts + 1] = "Level " .. math.floor(rec.level) end
  if nonEmpty(rec.race) then parts[#parts + 1] = shown(src, rec.race) end
  if nonEmpty(rec.class) then
    local class = shown(src, rec.class)
    local code = classCode(rec.class)
    parts[#parts + 1] = code and (code .. class .. "|r") or class
  end
  local who = table.concat(parts, " ")
  if who == "" and isNameKey(guid) then return ns.RulesMarks.NAME_WHO end
  return who
end

-- " at <subzone>, <zone>" (or " at <zone>") from a record's zone fields, "" with none.
local function placeText(src, rec)
  local zone, sub = shown(src, rec.zone), shown(src, rec.subzone)
  local at = (sub ~= "" and sub ~= zone) and (zone ~= "" and (sub .. ", " .. zone) or sub) or zone
  return at ~= "" and (" at " .. at) or ""
end

local function drawCard(page, cd, rec, seen, roster, now)
  local src = page.src
  local name = shown(src, rec.name)
  cd.shownName = name
  cd.name:SetText(name)
  cd.bigName:SetText(name)
  local who = whoText(src, rec, cd.guid)
  cd.who:SetText(who)
  cd.bigWho:SetText(who)
  cd.hasWho = who ~= ""

  local seenLine = seenText(src, seen, now)
  cd.status:SetText(seenLine and ("Seen " .. seenLine) or "Never seen")
  cd.seen:SetText(seenLine and capital(seenLine) or "Never")

  cd.rawWhy = type(rec.why) == "string" and rec.why or ""
  local why = shown(src, rec.why)
  cd.hasWhy = why ~= ""
  cd.why:SetText(GOLD .. "Why:|r " .. why)
  cd.whyValue:SetText(why ~= "" and why or "-")

  local marked = "by " .. memberName(src, roster, rec.markedBy)
  if type(rec.markedAt) == "number" then marked = marked .. " " .. ago(now - rec.markedAt) end
  if nonEmpty(rec.decidedBy) then marked = marked .. DOT .. "approved by " .. memberName(src, roster, rec.decidedBy) end
  cd.marked:SetText(marked)

  if not cd.kills then return end
  local kills = {}
  for _, k in ipairs(type(rec.kills) == "table" and rec.kills or {}) do
    if type(k) == "table" and type(k.time) == "number" then kills[#kills + 1] = k end
  end
  table.sort(kills, function(a, b) return a.time > b.time end)
  cd.kills:SetText(plural(#kills, "kill"))
  cd.killsLabel:SetText("Kills (" .. #kills .. ")")
  local list = {}
  for _, k in ipairs(kills) do list[#list + 1] = memberName(src, roster, k.hunter) .. " " .. ago(now - k.time) end
  cd.killList:SetText(#list > 0 and table.concat(list, DOT) or "None yet")
end

-- The open targets to draw: src.data()'s entries (the real list or the hub demo's), each with its stored record
-- when there is one (List.Open's, or the demo's under /gsync demo), else the entry's own fields.
local function targetsOf(src)
  local list, lastSeen = src.data()
  local demo = demoOf(src)
  local out = {}
  for _, entry in ipairs(type(list) == "table" and list.targets or {}) do
    local rec
    if type(entry.guid) == "string" then
      if demo then rec = type(demo.kos) == "table" and demo.kos["t" .. entry.guid] or nil
      else rec = ns.Store.Target(entry.guid) end
    end
    if type(rec) ~= "table" then rec = { name = entry.target, race = entry.race, class = entry.class } end
    out[#out + 1] = { guid = entry.guid, rec = rec }
  end
  return out, type(lastSeen) == "table" and lastSeen or {}
end

local function refreshList(page, roster, now)
  local src = page.src
  local Rules = ns.Rules
  local targets, lastSeen = targetsOf(src)
  local n = #targets
  page.count:SetText(Page.Targets(n))
  page.alerts:SetText(ns.Core.DB().muted and ALERTS_OFF or ALERTS_ON)
  page.canWrite = ns.List.CanWrite() == true

  local openFound = false
  for i, t in ipairs(targets) do
    local cd = card(page, i)
    cd.guid = t.guid
    cd.key = t.guid or ("#" .. i)
    if cd.key == page.open then openFound = true end
    local key = Rules.Key(t.rec.name)
    drawCard(page, cd, t.rec, key and lastSeen[key] or nil, roster, now)
    setArt(cd, t.rec, src.kit)
    cd.frame:Show()
  end
  for i = n + 1, #page.cards do page.cards[i].frame:Hide() end
  if not openFound then page.open, page.editing = nil, nil end
  page.n = n
  layout(page)
end

-- ---------- List: the Mark as bounty card (o851) ----------

local function buildMark(page, frame)
  local kit = page.src.kit
  local w = (page.width or PAGE_W) - BOX_RIGHT
  local f = makeCard(kit, frame, w, MARK_H)
  f:SetPoint("TOPLEFT", 0, -MARK_Y)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -8)
  title:SetText("Mark as bounty")
  local hint = textLine(f, "GameFontHighlightSmall", 12, -24)
  hint:SetText(MARK_HINT)
  local nameBox = kitCall(kit, "InputBox", f, NAME_BOX_W, NAME_BOX_W)
  if nameBox then nameBox:SetPoint("TOPLEFT", 14, -40) end
  local whyW = math.min(MARK_BOX_W, w - MARK_BOX_LESS)
  local box = kitCall(kit, "InputBox", f, whyW, math.min(400, whyW))
  if box then box:SetPoint("TOPLEFT", 14 + NAME_BOX_W + 8, -40) end
  page.markBox = box
  local b = button(f, "Mark as bounty", 120)
  b:SetPoint("TOPRIGHT", -16, -39)
  b:SetScript("OnClick", function()
    safe(page.src, function()
      if demoRefused() then return end
      local mark = ns.Mark
      local name = nameBox and nameBox:GetText() or ""
      local why = box and box:GetText() or ""
      if type(mark) ~= "table" then return end
      if type(name) == "string" and name:find("%S") then
        -- a marked name clears the Name box, so the next click marks the target again (review f7)
        if type(mark.FromName) == "function" and mark.FromName(name, why) == true then nameBox:SetText("") end
      elseif type(mark.FromTarget) == "function" then
        mark.FromTarget(why)
      end
    end)
  end)
  page.mark = f
end

-- ---------- Hunters (kos-5) ----------

local function hunterRow(page, i)
  local h = page.hunters
  local r = h.rows[i]
  if r then return r end
  local kit = page.src.kit
  local f = makeCard(kit, h.child, (page.width or PAGE_W) - page.boxRight, ROW_H)
  r = { frame = f }
  local function cell(col, font, justify)
    local x = 0
    for c = 1, col - 1 do x = x + COLS[c][2] end
    local fs = f:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("LEFT", f, "LEFT", x + 8, 0)
    fs:SetWidth(COLS[col][2] - 16)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
  end
  r.rank = cell(1, "GameFontNormal", "CENTER")
  r.name = cell(2, "GameFontHighlight")
  r.bar = kitCall(kit, "StatBar", f)
  if r.bar then
    r.bar:SetPoint("LEFT", f, "LEFT", COLS[1][2] + COLS[2][2] + 4, 0)
    r.bar:SetWidth(COLS[3][2] - 8)
    -- the fill (o2304, the Harvest.lua/Cards.lua pattern): a StatusBar in the StatBar's fill, so the client divides
    local fill = type(r.bar.fill) == "table" and r.bar.fill or r.bar
    r.grow = CreateFrame("StatusBar", nil, fill)
    r.grow:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
    r.grow:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
    r.grow:SetStatusBarTexture(BAR_TEXTURE)
    r.grow:SetStatusBarColor(BAR_GOLD[1], BAR_GOLD[2], BAR_GOLD[3])
    r.grow:SetFrameLevel((tonumber(fill:GetFrameLevel()) or 1) + 1)
  end
  r.total = cell(3, "GameFontHighlight")
  r.streak = cell(4, "GameFontHighlightSmall")
  r.best = cell(5, "GameFontHighlightSmall")
  r.last = cell(6, "GameFontHighlightSmall")
  h.rows[i] = r
  return r
end

local function weeks(n)
  if type(n) ~= "number" or n <= 0 then return DASH end
  return plural(n, "week")
end

local function drawHunter(page, r, y, rank, name, total, streak, best, last, now, top)
  if r.grow then
    r.grow:SetMinMaxValues(0, math.max(top, 1))
    r.grow:SetValue(total)
  end
  r.frame:ClearAllPoints()
  r.frame:SetPoint("TOPLEFT", page.hunters.child, "TOPLEFT", 0, -y)
  r.frame:SetWidth((page.width or PAGE_W) - page.boxRight)
  r.rank:SetText(rank)
  r.name:SetText(name)
  r.total:SetText(tostring(total))
  r.streak:SetText(weeks(streak))
  r.best:SetText(weeks(best))
  r.last:SetText(type(last) == "number" and ago(now - last) or "never")
  r.frame:Show()
end

-- The hunters held (kos_h), { key, rec } each; under /gsync demo the demo's.
local function huntersHeld(demo)
  local out = {}
  local held = demo and demo.kos_h
  if not demo then
    local g = ns.Core.Guild()
    held = g and g.kos_h
  end
  for key, drec in pairs(type(held) == "table" and held or {}) do
    local member = type(key) == "string" and key:sub(2) or nil
    local rec
    if demo then rec = drec else rec = member and ns.Store.Hunter(member) end
    if type(rec) == "table" then out[#out + 1] = { key = member, rec = rec } end
  end
  return out
end

local function refreshHunters(page, roster, now)
  local src, h = page.src, page.hunters
  local comm = GuildSync.Comm
  local me
  if comm then me = comm.MyKey() end
  -- the demo's hunters are demo members, which the real roster (Comm.Roster stays real under the demo) does not hold
  local demo = demoOf(src)
  local onRoster = function(key) return roster[key] ~= nil end
  if demo then
    onRoster = function() return true end
    me = demo.me   -- the demo viewer (f5449)
  end
  local rows, mine = ns.RulesBoard.Rows(huntersHeld(demo), onRoster, me, now)
  local top = 0
  for _, row in ipairs(rows) do top = math.max(top, tonumber(row.total) or 0) end
  local used, onBoard = 0, false
  for i, row in ipairs(rows) do
    used = i
    if row.key == me then onBoard = true end
    drawHunter(page, hunterRow(page, i), ROWS_Y + ROW_STEP * (i - 1), tostring(row.rank),
      memberName(src, roster, row.key) .. (row.key == me and " (you)" or ""), row.total, row.streak, row.best, row.last,
      now, top)
  end
  local height = ROWS_Y + ROW_STEP * used
  if me and not onBoard then
    used = used + 1
    local y = height + 8
    local you = memberName(src, roster, me) .. " (you)"
    if mine then
      drawHunter(page, hunterRow(page, used), y, tostring(mine.rank), you, mine.total, mine.streak, mine.best,
        mine.last, now, top)
    else
      drawHunter(page, hunterRow(page, used), y, DASH, you, 0, 0, 0, nil, now, top)
    end
    height = y + ROW_STEP
  end
  for i = used + 1, #h.rows do h.rows[i].frame:Hide() end
  setContentHeight(page, h.child, height)
end

local function buildHunters(page)
  local kit = page.src.kit
  local child = CreateFrame("Frame", nil, page.scroll)
  local h = { child = child, rows = {} }
  page.hunters = h
  local intro = textLine(child, "GameFontHighlightSmall", 4, -4)
  intro:SetText(HUNTERS_INTRO)
  local x = 0
  for i, col in ipairs(COLS) do
    local head = kitCall(kit, "ColumnHeader", child, col[1], nil)
    if head then
      head:SetPoint("TOPLEFT", child, "TOPLEFT", x, -26)
      head:SetWidth(col[2])
      if i == 3 then kitCall(kit, "SortArrow", head, "desc") end
    end
    x = x + col[2]
  end
  return child
end

-- ---------- Waiting and Mine: the mark cards (kos-3, kos-3b, kos-6) ----------

-- Card i of a mark tab (set: { child, cards, buttons = { { text, w, click } ... } }): M.Kit.Card, the painting and
-- portrait as on the List (no Page.lua region on BACKGROUND, f5212), the name with its M.Kit.Pill 6 px after it
-- (o852), three lines, a divider at y -84 and the buttons right to left on the strip, the last ending 16 px from the
-- right. No catcher: nothing opens on these cards.
local function markCard(page, set, i)
  local cd = set.cards[i]
  if cd then return cd end
  local kit = page.src.kit
  local f = makeCard(kit, set.child, (page.width or PAGE_W) - page.boxRight, CARD_HEIGHT)
  cd = { frame = f, buttons = {} }
  cd.painting, cd.paintBorder = framed(f, PAINT_W, PAINT_H)
  cd.paintBorder:SetPoint("TOPLEFT", 7, -7)
  cd.portrait, cd.portraitBorder = framed(f, PORTRAIT, PORTRAIT)
  cd.portraitBorder:SetDrawLayer("ARTWORK", 2)
  cd.portrait:SetDrawLayer("ARTWORK", 3)
  cd.portraitBorder:SetPoint("TOPLEFT", 7, -45)
  -- one point only: the name is as wide as its text, so the pill follows it (names are capped at storage)
  cd.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cd.name:SetPoint("TOPLEFT", TEXT_X, -10)
  cd.name:SetJustifyH("LEFT")
  cd.name:SetWordWrap(false)
  cd.name:SetTextColor(RED[1], RED[2], RED[3])
  cd.pill = kitCall(kit, "Pill", f, "", "gold")
  if cd.pill then cd.pill:SetPoint("LEFT", cd.name, "RIGHT", 6, 0) end
  cd.who = textLine(f, "GameFontHighlight", TEXT_X, -28)
  cd.line = textLine(f, "GameFontHighlightSmall", TEXT_X, -46)
  cd.line:SetTextColor(DIM[1], DIM[2], DIM[3])
  cd.why = textLine(f, "GameFontHighlightSmall", TEXT_X, -64)
  cd.divider = kitCall(kit, "Divider", f)
  if cd.divider then
    cd.divider:SetPoint("TOPLEFT", 3, -CARD_HEIGHT)
    cd.divider:SetPoint("TOPRIGHT", -3, -CARD_HEIGHT)
  end
  local right
  for k = #set.buttons, 1, -1 do
    local spec = set.buttons[k]
    local b = button(f, spec.text, spec.w)
    if right then b:SetPoint("RIGHT", right, "LEFT", -6, 0) else b:SetPoint("TOPRIGHT", -16, -STRIP_Y) end
    b:SetScript("OnClick", function() safe(page.src, spec.click, page, cd) end)
    cd.buttons[k] = b
    right = b
  end
  set.cards[i] = cd
  return cd
end

-- Draws mark m on cd at y: line under the level line, state as the pill, the strip (divider, buttons) when strip.
-- Answers the card's height.
local function drawMark(page, set, cd, m, line, state, strip, y)
  local src, f = page.src, cd.frame
  local kit = page.src.kit
  local h = strip and MARK_H2 or CARD_HEIGHT
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", set.child, "TOPLEFT", 0, -y)
  f:SetSize((page.width or PAGE_W) - page.boxRight, h)
  cd.name:SetText(shown(src, m.name))
  if cd.pill then
    kitCall(kit, "SetPill", cd.pill, state or "", TONES[state] or "grey")
    cd.pill:SetShown(state ~= nil)
  end
  cd.who:SetText(whoText(src, m, m.guid))
  cd.line:SetText(line)
  local why = shown(src, m.why)
  cd.why:SetText(GOLD .. "Why:|r " .. why)
  cd.why:SetShown(why ~= "")

  setArt(cd, m, kit)
  if cd.zone then
    local l, r, t, b = Page.Crop(atlasInfo(cd.zone), PAINT_W, PAINT_H)
    if l then cd.painting:SetTexCoord(l, r, t, b) end
  end
  cd.painting:SetShown(cd.zone ~= nil)
  cd.paintBorder:SetShown(cd.zone ~= nil)

  if cd.divider then cd.divider:SetShown(strip) end
  local base = tonumber(f:GetFrameLevel()) or 1
  for _, b in ipairs(cd.buttons) do
    b:SetShown(strip)
    b:SetFrameLevel(base + 2)   -- f4698: above the card (the sim and InsetFrameTemplate share levels)
  end
  f:Show()
  return h
end

local function hideFrom(set, n)
  for i = n + 1, #set.cards do set.cards[i].frame:Hide() end
end

local function markTime(m) return tonumber(m.time) or 0 end

-- Approve, Reject and Withdraw: looked up at click time, after the demo check (d793 c).
local function decide(verb)
  return function(page, cd)
    if demoRefused() then return end
    local e = cd.entry
    if type(e) ~= "table" or type(e.mark) ~= "table" then return end
    local done, why
    if verb == "Withdraw" then
      done, why = ns.Mark.Withdraw(e.mark.guid, ns.Core.Now())
    else
      done, why = ns.Mark[verb](e.key, e.mark.guid, ns.Core.Now())
    end
    if not done then refused(why) end
    Page.Refresh(page.frame, page.src)
  end
end

-- Waiting's marks, { key, mark } each, and whether the officer view (Approve, Reject) shows. Under /gsync demo every
-- demo mark that still waits, in the officer view (kos-3 is drawn under the demo banner, f5404); else
-- ns.Mark.Waiting() (AC20's filter), the officer view for List.CanWrite().
local function waitingEntries(demo)
  local out = {}
  if demo then
    local kos = type(demo.kos) == "table" and demo.kos or {}
    for key, rec in pairs(type(demo.kos_m) == "table" and demo.kos_m or {}) do
      for _, m in ipairs(type(rec) == "table" and type(rec.marks) == "table" and rec.marks or {}) do
        if type(m) == "table" and type(m.guid) == "string"
          and ns.RulesMarks.State(m, kos["t" .. m.guid]) == "waiting" then
          out[#out + 1] = { key = key, mark = m }
        end
      end
    end
    table.sort(out, function(a, b)
      if markTime(a.mark) ~= markTime(b.mark) then return markTime(a.mark) < markTime(b.mark) end
      if a.key ~= b.key then return tostring(a.key) < tostring(b.key) end
      return a.mark.guid < b.mark.guid
    end)
    return out, true
  end
  local list = ns.Mark.Waiting()
  for _, e in ipairs(type(list) == "table" and list or {}) do
    if type(e) == "table" and type(e.mark) == "table" then out[#out + 1] = e end
  end
  return out, ns.List.CanWrite() == true
end

local function refreshWaiting(page, roster, now)
  local src, set = page.src, page.waiting
  local list, officer = waitingEntries(demoOf(src))
  local n = #list
  set.count:SetText(n == 1 and "1 mark waits for an officer" or (n .. " marks wait for an officer"))
  set.note:SetText(officer and OFFICER_NOTE or MEMBER_NOTE)
  local y = WAIT_TOP
  for i, e in ipairs(list) do
    local m = e.mark
    local cd = markCard(page, set, i)
    cd.entry = e
    local line = "Marked by " .. memberName(src, roster, e.key) .. " " .. ago(now - markTime(m)) .. placeText(src, m)
    y = y + drawMark(page, set, cd, m, line, "waiting", officer, y) + CARD_GAP
  end
  hideFrom(set, n)
  setContentHeight(page, set.child, y)
end

local function buildWaiting(page)
  local child = CreateFrame("Frame", nil, page.scroll)
  local set = { child = child, cards = {}, buttons = {
    { text = "Approve", w = 90, click = decide("Approve") }, { text = "Reject", w = 70, click = decide("Reject") } } }
  page.waiting = set
  set.count = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  set.count:SetPoint("TOPLEFT", 4, -5)
  set.count:SetJustifyH("LEFT")
  set.note = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  set.note:SetPoint("TOPRIGHT", -4, -7)
  set.note:SetJustifyH("RIGHT")
  set.note:SetTextColor(ALERTS_GREY[1], ALERTS_GREY[2], ALERTS_GREY[3])
  return child
end

-- Mine's marks, { mark, target } each: this client's own kos_m record (Store.Member(MyKey).marks), each with the
-- target record it is judged against. Under /gsync demo the demo viewer's own (demo.me's kos_m record, f5432).
local function mineEntries(demo)
  local out = {}
  if demo then
    local kos = type(demo.kos) == "table" and demo.kos or {}
    local rec = type(demo.kos_m) == "table" and type(demo.me) == "string" and demo.kos_m[demo.me] or nil
    for _, m in ipairs(type(rec) == "table" and type(rec.marks) == "table" and rec.marks or {}) do
      if type(m) == "table" and type(m.guid) == "string" then
        out[#out + 1] = { mark = m, target = kos["t" .. m.guid] }
      end
    end
    return out
  end
  local comm = GuildSync.Comm
  local me
  if comm then me = comm.MyKey() end
  local rec = type(me) == "string" and ns.Store.Member(me) or nil
  for _, m in ipairs(type(rec) == "table" and type(rec.marks) == "table" and rec.marks or {}) do
    if type(m) == "table" and type(m.guid) == "string" then
      out[#out + 1] = { mark = m, target = ns.Mark.TargetFor(m) }
    end
  end
  return out
end

local function refreshMine(page, roster, now)
  local src, set = page.src, page.mine
  if set.head then set.head:SetWidth((page.width or PAGE_W) - page.boxRight) end
  local list = mineEntries(demoOf(src))
  local y = MINE_TOP
  for i, e in ipairs(list) do
    local m = e.mark
    local state = ns.RulesMarks.State(m, e.target)
    if type(state) ~= "string" then state = nil end
    local waiting = state == "waiting"
    local cd = markCard(page, set, i)
    cd.entry = e
    local line = "Marked " .. ago(now - markTime(m)) .. placeText(src, m)
    if waiting then line = line .. DOT .. "waits for an officer" end
    y = y + drawMark(page, set, cd, m, line, state, waiting, y) + CARD_GAP
  end
  hideFrom(set, #list)
  setContentHeight(page, set.child, y)
end

local function buildMine(page)
  local child = CreateFrame("Frame", nil, page.scroll)
  local set = { child = child, cards = {}, buttons = { { text = "Withdraw", w = 90, click = decide("Withdraw") } } }
  page.mine = set
  set.head = kitCall(page.src.kit, "SectionHeader", child, (page.width or PAGE_W) - page.boxRight, "Your marks")
  if set.head then set.head:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0) end
  return child
end

-- ---------- the tabs (o859, o868) ----------

local function emptyChild(page)
  local child = CreateFrame("Frame", nil, page.scroll)
  child:SetSize(1, 1)
  return child
end

-- Shows tab key: the scroll's child swapped and scrolled to the top, the List's fixed parts only on List.
local function showTab(page, key)
  page.tab = key
  if page.tabs then page.tabs:Select(key) end
  local onList = key == "list"
  page.count:SetShown(onList)
  page.alerts:SetShown(onList)
  if page.mark then page.mark:SetShown(onList) end
  for k, child in pairs(page.children) do child:SetShown(k == key) end
  local scroll = page.scroll
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", 0, onList and -LIST_TOP or -TOP)
  scroll:SetPoint("BOTTOMRIGHT", -page.boxRight, 0)
  scroll:SetScrollChild(page.children[key])
  scroll:SetVerticalScroll(0)
  page.contentHeight = 0
  Page.Refresh(page.frame, page.src)
end

function Page.Build(frame, src)
  compat = src.compat
  local page = { cards = {}, n = 0, contentHeight = 0, src = src, frame = frame, children = {}, tab = "list" }
  pages[frame] = page
  local kills = killsOn()

  page.tabs = kitCall(src.kit, "Tabs", frame, kills and TABS or TABS_OFF,
    function(key) safe(page.src, showTab, page, key) end)

  page.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  page.count:SetPoint("TOPLEFT", 4, -(TOP + 5))
  page.count:SetJustifyH("LEFT")

  page.alerts = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  page.alerts:SetPoint("RIGHT", frame, "TOPRIGHT", -BOX_RIGHT, -(TOP + 12))  -- the vertical centre of the header row
  page.alerts:SetJustifyH("RIGHT")
  page.alerts:SetTextColor(ALERTS_GREY[1], ALERTS_GREY[2], ALERTS_GREY[3])

  buildMark(page, frame)

  local scroll, plain, right = scrollFrame(frame)
  page.boxRight = right
  page.scroll, page.plain = scroll, plain
  -- each tab's child is created with the scroll as parent, then set as its scroll child when the tab shows
  page.content = emptyChild(page)
  page.children.list = page.content
  page.children.waiting = buildWaiting(page)
  if kills then
    page.children.kills = emptyChild(page)
    page.children.hunters = buildHunters(page)
  end
  page.children.mine = buildMine(page)

  frame:SetScript("OnSizeChanged", function(_, w)
    if type(w) == "number" and w > 0 then
      page.width = w
      safe(page.src, layout, page)
    end
  end)

  page.tab = "list"
  if page.tabs then page.tabs:Select("list") end
  page.count:Show()
  for k, child in pairs(page.children) do child:SetShown(k == "list") end
  scroll:SetPoint("TOPLEFT", 0, -LIST_TOP)
  scroll:SetPoint("BOTTOMRIGHT", -right, 0)
  scroll:SetScrollChild(page.content)
end

function Page.Refresh(frame, src)
  local page = pages[frame]
  if not page then return end
  page.src = src
  local w = tonumber(frame:GetWidth())
  if not page.width and w and w > 0 then page.width = w end
  local comm = GuildSync.Comm
  local roster
  if comm then roster = comm.Roster() end
  if type(roster) ~= "table" then roster = {} end
  -- under /gsync demo the demo members are drawn by their demo names (f5432)
  local demo = demoOf(src)
  if demo and type(demo.names) == "table" then
    roster = {}
    for k, name in pairs(demo.names) do roster[k] = { name = name } end
  end
  local now = ns.Core.Now()
  refreshList(page, roster, now)
  if page.tab == "hunters" and page.hunters then refreshHunters(page, roster, now)
  elseif page.tab == "waiting" then refreshWaiting(page, roster, now)
  elseif page.tab == "mine" then refreshMine(page, roster, now) end
end

return Page
