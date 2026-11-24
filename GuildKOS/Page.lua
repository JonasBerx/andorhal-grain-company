-- GuildKOS Page: the Kill on Sight page inside the GuildSync window (Hub.lua calls Build and Refresh).
-- What ships (ns.Probe.kills false, 0.6, d1821): a tab strip (M.Kit.Tabs: List, Waiting, Mine) over one scroll frame
-- whose scroll child is swapped per tab, and no kill count anywhere. List: the header (count, alerts line), the fixed
-- Mark as bounty card (labelled Name and Why boxes; Add by name runs ns.Mark.FromName, Mark my target
-- ns.Mark.FromTarget, off with its refusal as the tooltip while ns.Mark.Available says no; the answer line under the
-- boxes for 10 s; issue 44 s3), the kill grain strip under it (RulesKills.Strip over Kill.Week, from the local ledger;
-- a card whose target is paid out this week wears "paid this week"; neither under /gsync demo; issue 44 s5), then
-- the open targets as a grid of compact M.Kit.Card cards, always 2 a row (issue 44 d79, d80: portrait, the red name
-- and level line or "Added by name" beside it, the pills at the top right; then the seen line, why and "Last killed by
-- <name>, <ago>" from ns.Kill.Recent (d78; ns.RulesKills.Recent over the demo's members under /gsync demo)), filtered
-- by the header row's search box and ordered by its sort dropdown (List.Filter, List.Sort, Core.Sort), each wearing
-- List.SeenPill's "Seen just now" or "Seen today" left of any paid pill (issue 44 s4); a refresh never moves the
-- scroll offset. Right of the grid the details panel always keeps its place (290 wide, narrower on a small page, never
-- under 220; full height), saying "Click a target to see its details." until a card is clicked; a click selects the
-- card and fills it: start-zone painting, portrait, name, level line, Last seen, Why, Marked, Kills (up to 5, or "No
-- kills yet"); Edit why and Remove for officers, Close for all; Edit why opens an input box with Save and Cancel, d791.
-- Clicking the selected card again or Close empties it. Waiting: ns.Mark.Waiting()'s
-- marks, Approve and Reject for officers (kos-3), read-only for a member (kos-3b). Mine: "Your marks", each with
-- ns.RulesMarks.State as its pill and Withdraw while it waits (kos-6), then ns.Mark.Decided's marks of the last 7
-- days with an "Approved" or "Rejected" pill (issue 44 s7).
-- What ns.Probe.kills true adds (batch 4): the Kills and Hunters tabs (Hunters: the board, RulesBoard.Rows, and the
-- line for me) and the card's confirmed-kill count. Kills and Mine's claims wait
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
local CARD_HEIGHT, CARD_GAP = 84, 8      -- the Waiting and Mine mark cards
local PAINT_W, PAINT_H, PORTRAIT = 112, 68, 30
local TEXT_X = 130
local TEXT_RIGHT = -8   -- the card text's right inset: each line ends 8 px inside the card
-- issue 44 d77/d79/d80/d81: the List's open targets as a grid of cards, always 2 a row GRID_GAP apart, each GRID_H
-- tall: the 48 portrait at (8,-8) in a class-coloured frame over a dimmed strip of the race's start-zone painting
-- (BACK_H tall), the red name, the level line and the seen line beside it; Why (left out with none) and Last killed by
-- (left out with none; it stops short of the pills) across the card under it; the pills at the bottom right; a
-- class-coloured 1 px ring round the card (none with no class: the Kit card's own border stays).
-- The details panel always keeps its place right of the scroll box on List (opening it never reflows the grid):
-- PANEL_W where that leaves both cards CARD_MIN_W, else narrower, never under PANEL_MIN_W.
local GRID_H, GRID_GAP, GRID_TEXT_X, GRID_PORTRAIT = 100, 8, 64, 48
local WHY_Y, KILLED_Y = 62, 78          -- the full-width lines under the portrait
local BACK_H, BACK_A = 58, 0.35         -- the backdrop strip: 2 px inside the card's top, its alpha
local SELECT_TINT = { 1, 0.82, 0, 0.18 } -- the selected card's gold wash over the whole card
local CARD_MIN_W = 160
local PANEL_W, PANEL_MIN_W, PANEL_PAINT_H, PANEL_PORTRAIT = 290, 220, 46, 32
local PANEL_HINT = "Click a target to see its details."
local PANEL_X, PANEL_VALUE_X = 10, 76   -- a panel row's label and value
local PANEL_KILLS, KILL_STEP = 5, 12    -- the Kills section's lines, from y -128
local PANEL_BTN_Y = 190                 -- Close, Remove and Edit why (Save and Cancel), 22 tall: fits a 216-tall panel
local NO_KILLS = "No kills yet"
local PAGE_W = 726      -- the page width until the page frame reports its own (View.SHELL.page)
local BOX_RIGHT = 16    -- the scroll box ends 16 px inside the page; its bar sits 4 px right of it (as M.Kit.List)
local CLASSIC_RIGHT = 24 -- UIPanelScrollFrameTemplate's wider classic bar, kept inside the page (R-n2)
local TOP = 40          -- the 32-tall tab row and 8 px (o859)
-- the fixed Mark as bounty card (o851): 82 tall since issue 44 s3 (labels over the boxes, the answer line under them)
local MARK_Y, MARK_H = 66, 82
local NAME_BOX_W = 150                   -- the Name box, left of the Why box with 8 px between (add by name)
local MARK_BTN_W = 110                   -- Add by name and Mark my target, 8 px apart, the second 16 px from the right
-- the Why box: 420, or less so it ends 8 px before Add by name (f8600), right of the Name box
local MARK_BOX_W, MARK_BOX_LESS = 420, 14 + 16 + MARK_BTN_W + 8 + MARK_BTN_W + 8 + NAME_BOX_W + 8
local NAME_LABEL, WHY_LABEL = "Name (first and surname)", "Why (optional)"
local ANSWER_Y, ANSWER_S = -64, 10       -- the answer line under the boxes, shown for 10 s
-- issue 44 s5: the kill grain strip (RulesKills.Strip over Kill.Week) 6 px under the Mark card, 18 tall
local GRAIN_Y, GRAIN_H = MARK_Y + MARK_H + 6, 18
local PAID_PILL = "paid this week"       -- a List card whose target reached the per-target cap this week
local LIST_TOP = GRAIN_Y + GRAIN_H       -- the List tab's scroll frame
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
-- The header row (issue 44 step s2): an Alerts checkbox in place of the sentence above (kept for a client with no
-- checkbox template), and the count line's "N seen in the last 10 min" from lastSeen.
local ALERTS_LABEL, ALERTS_LABEL_W = "Alerts", 44   -- the box sits this far left of the scroll box's edge for its label
local RECENT = 600                                  -- "in the last 10 min"
-- issue 44 s4: the header row's search box and sort dropdown, right to left from the Alerts box, 8 px apart
local SEARCH_W, SORT_W, SEARCH_HINT = 120, 110, "Search"
local SORT_TEXTS = { seen = "Recently seen", name = "Name", added = "Added" }
local SEEN_TONES = { ["Seen just now"] = "gold", ["Seen today"] = "grey" }
local HUNTERS_INTRO = "Top 10 by confirmed kills. A kill counts once an officer confirms it. Streak: weeks in a row "
  .. "with a confirmed kill."
local MARK_H2, STRIP_Y = 116, 89       -- a mark card with buttons: the 84 block, a divider at 84, the strip at y 89
local WAIT_TOP, MINE_TOP = 30, 34        -- the first mark card under Waiting's header and under "Your marks"
local OFFICER_NOTE = "Members see only their own marks here."
local MEMBER_NOTE = "Only your own marks show here."
-- The empty and not-ready lines (issue 44 step s1): each tab says what an empty view means.
local EMPTY_LIST = "No one is on the list yet. Target an enemy player and click Mark my target, or type a name and "
  .. "click Add by name."
local WAIT_EMPTY = { officer = "No marks wait. When a member marks a player, it shows here.",
  member = "You have no marks waiting for an officer." }
local MINE_EMPTY = { officer = "Your marks go straight on the list, so none wait here.",
  member = "You have no marks. A mark you make shows here until an officer decides." }
local NOTE_H = 28                        -- an empty or not-ready line and the gap under it
local TONES = { waiting = "gold", approved = "green", rejected = "red", removed = "grey",
  Approved = "green", Rejected = "red" }
local DECIDED_TAGS = { approved = "Approved", rejected = "Rejected" } -- s7: Mine's decided marks (ns.Mark.Decided)
local TABS = { { key = "list", text = "List" }, { key = "waiting", text = "Waiting" }, { key = "kills", text = "Kills" },
  { key = "hunters", text = "Hunters" }, { key = "mine", text = "Mine" } }
local TABS_OFF = { TABS[1], TABS[2], TABS[5] }

-- ns.Probe.kills (RulesMarks, d1821), read at call time: false = no Kills or Hunters tab and no confirmed-kill texts
-- (the shared kills of d78, "Last killed by" and the panel's Kills section, show either way).
local function killsOn() return type(ns.Probe) == "table" and ns.Probe.kills == true end

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

-- The portrait atlases to try in order, then the file to fall back to. The male icon, unless sex is 3 (a female face
-- seen by ns.Seen, d81): then the female icon first. The records keep no sex.
function Page.Portrait(race, class, sex)
  local out = { file = SKULL }
  local r, c = Page.RaceKey(race), atlasKey(class)
  if r and sex == 3 then out[#out + 1] = "raceicon128-" .. r .. "-female" end   -- d81: a seen female face first
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

-- The classic class colours, for a client with no RAID_CLASS_COLORS (d81).
local CLASS_FALLBACK = {
  WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 },
  ROGUE = { 1, 0.96, 0.41 }, PRIEST = { 1, 1, 1 }, SHAMAN = { 0, 0.44, 0.87 }, MAGE = { 0.41, 0.8, 0.94 },
  WARLOCK = { 0.58, 0.51, 0.79 }, DRUID = { 1, 0.49, 0.04 }, DEATHKNIGHT = { 0.77, 0.12, 0.23 },
}

-- A class name's colour as r, g, b: RAID_CLASS_COLORS, else CLASS_FALLBACK; nil for none or an unknown class.
local function classColour(class)
  local token = type(class) == "string" and class:upper():gsub("[%s']", "") or nil
  if not token or token == "" then return nil end
  local all = RAID_CLASS_COLORS
  local col = type(all) == "table" and all[token] or nil
  if type(col) == "table" then
    local r, g, b = tonumber(col.r), tonumber(col.g), tonumber(col.b)
    if r and g and b then return r, g, b end
  end
  local f = CLASS_FALLBACK[token]
  if f then return f[1], f[2], f[3] end
  return nil
end

local function hexCode(r, g, b)
  local function byte(x) return math.max(0, math.min(255, math.floor(x * 255 + 0.5))) end
  return string.format("|cff%02x%02x%02x", byte(r), byte(g), byte(b))
end

-- "|cffRRGGBB" for a class name in its class colour, or nil.
local function classCode(class)
  local r, g, b = classColour(class)
  if not r then return nil end
  return hexCode(r, g, b)
end

-- d81: a level's danger colour against mine, as the game colours a mob's level (the classic rule; the client has no
-- GetQuestDifficultyColor in the dataset): red 5 and more above, orange 3 to 4, yellow within 2, green, grey at or
-- under the grey level (the classic table: none to 5, then me - floor(me / 10) - 5 to 39, me - floor(me / 5) - 1 to
-- 59, me - 9 after).
local DANGER = { red = { 1, 0.1, 0.1 }, orange = { 1, 0.5, 0.25 }, yellow = { 1, 1, 0 }, green = { 0.25, 0.75, 0.25 },
  grey = { 0.5, 0.5, 0.5 } }
local SKULL_ICON = "|TInterface\\TargetingFrame\\UI-TargetingFrame-Skull:0|t"
local SKULL_OVER = 10   -- more than this many levels above me: the skull in place of the number
function Page.Danger(level, me)
  if type(level) ~= "number" or type(me) ~= "number" or me < 1 then return nil end
  local diff = level - me
  if diff >= 5 then return "red" end
  if diff >= 3 then return "orange" end
  if diff >= -2 then return "yellow" end
  local grey = 0
  if me > 59 then grey = me - 9
  elseif me > 39 then grey = me - math.floor(me / 5) - 1
  elseif me > 5 then grey = me - math.floor(me / 10) - 5 end
  if level <= grey then return "grey" end
  return "green"
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

-- A muted line that wraps, anchored to both sides of parent at y, hidden until set (issue 44 s1: the empty and
-- not-ready lines).
local function noteLine(parent, y)
  local fs = textLine(parent, "GameFontHighlightSmall", 4, y, -4)
  fs:SetWordWrap(true)
  fs:SetTextColor(DIM[1], DIM[2], DIM[3])
  fs:Hide()
  return fs
end

-- Shows text on a note line, or hides it for nil; answers the height it takes (NOTE_H or 0).
local function setNote(fs, text)
  fs:SetText(text or "")
  fs:SetShown(text ~= nil)
  return text and NOTE_H or 0
end

-- The content height of the active tab and the plain frame's clamp; w, the child's width, defaults to the full box.
local function setContentHeight(page, child, h, w)
  child:SetSize(w or ((page.width or PAGE_W) - page.boxRight), math.max(1, h))
  if child ~= page.children[page.tab] then return end
  page.contentHeight = h
  if page.plain then
    local view = tonumber(page.scroll:GetHeight()) or 0
    local cur = tonumber(page.scroll:GetVerticalScroll()) or 0
    page.scroll:SetVerticalScroll(math.min(cur, math.max(0, h - view)))
  end
end

-- ---------- List: the grid and the details panel (issue 44 d77, d79, d80) ----------

-- The panel's width (d79): PANEL_W where the box then still holds two CARD_MIN_W cards, else what leaves them that,
-- never under PANEL_MIN_W. 290 at page width 726, 226 at 586 (the 760x480 window).
local function panelWidth(page)
  local free = (page.width or PAGE_W) - page.boxRight - BOX_RIGHT - (2 * CARD_MIN_W + GRID_GAP)
  return math.max(PANEL_MIN_W, math.min(PANEL_W, free))
end

-- The scroll box's width: the page less the bar's room; on List also less the panel and the 16 px between the panel's
-- right edge and the page's (the panel ends where the Mark card ends; the bar keeps its room between box and panel).
local function boxWidth(page)
  local w = (page.width or PAGE_W) - page.boxRight
  if page.tab == "list" then w = w - panelWidth(page) - BOX_RIGHT end
  return w
end

-- The scroll frame's place for the shown tab (under the List's fixed parts, else under the tab row); on List its right
-- edge is left of the panel, which shows there only. Moving the box leaves its scroll offset as it is.
local function placeScroll(page)
  local list = page.tab == "list"
  local scroll = page.scroll
  scroll:ClearAllPoints()
  scroll:SetPoint("TOPLEFT", 0, list and -LIST_TOP or -TOP)
  scroll:SetPoint("BOTTOMRIGHT", -(page.boxRight + (list and (panelWidth(page) + BOX_RIGHT) or 0)), 0)
  if page.panel then page.panel.frame:SetShown(list) end
end

-- The drawn card whose target the panel shows, or nil.
local function openCard(page)
  if page.open == nil then return nil end
  for i = 1, page.n do
    local cd = page.cards[i]
    if cd.key == page.open then return cd end
  end
  return nil
end

-- The grid (always 2 a row, d79), the selected card, the panel's width, its details or hint, its buttons for
-- page.editing; the content height. No data read.
local function layout(page)
  local markW = (page.width or PAGE_W) - BOX_RIGHT
  if page.mark then page.mark:SetWidth(markW) end
  if page.markBox then page.markBox:SetWidth(math.min(MARK_BOX_W, markW - MARK_BOX_LESS)) end
  placeScroll(page)
  local w = boxWidth(page)
  local cw = math.floor((w - GRID_GAP) / 2)
  local top = page.noteH or 0   -- the empty or not-ready line above the cards (s1)
  for i = 1, page.n do
    local cd = page.cards[i]
    local f = cd.frame
    local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
    f:SetSize(cw, GRID_H)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", page.content, "TOPLEFT", col * (cw + GRID_GAP), -(top + row * (GRID_H + GRID_GAP)))
    cd.selected:SetShown(page.open ~= nil and cd.key == page.open)
    -- d81: the backdrop strip across the card's top, cropped to its size (the panel's painting rule)
    cd.painting:SetSize(cw - 4, BACK_H)
    if cd.zone then
      local l, r, t, b = Page.Crop(atlasInfo(cd.zone), cw - 4, BACK_H)
      if l then cd.painting:SetTexCoord(l, r, t, b) end
    end
    -- f4698: the catcher above the card (the sim and InsetFrameTemplate share levels)
    cd.catcher:SetFrameLevel((tonumber(f:GetFrameLevel()) or 1) + 1)
  end
  local rows = math.floor((page.n + 1) / 2)
  setContentHeight(page, page.content, top + rows * (GRID_H + GRID_GAP), w)

  local p = page.panel
  if not p then return end
  local pw = panelWidth(page)
  p.frame:SetWidth(pw)
  p.painting:SetSize(pw - 6, PANEL_PAINT_H)
  p.paintBorder:SetSize(pw - 4, PANEL_PAINT_H + 2)
  if p.zone then
    local l, r, t, b = Page.Crop(atlasInfo(p.zone), pw - 6, PANEL_PAINT_H)
    if l then p.painting:SetTexCoord(l, r, t, b) end
  end
  if p.box then p.box:SetWidth(pw - PANEL_VALUE_X - 8) end
  local open = page.open ~= nil
  p.body:SetShown(open)
  p.hint:SetShown(not open)
  local editing = open and page.canWrite == true and p.box ~= nil and page.editing == page.open
  p.whyValue:SetShown(not editing)   -- the box takes the Why value's place while editing (d791)
  p.edit:SetShown(page.canWrite == true and not editing)
  p.remove:SetShown(page.canWrite == true and not editing)
  if p.box then p.box:SetShown(editing) end
  p.save:SetShown(editing)
  p.cancel:SetShown(editing)
  local base = tonumber(p.frame:GetFrameLevel()) or 1
  for _, b in ipairs({ p.close, p.edit, p.remove, p.save, p.cancel }) do b:SetFrameLevel(base + 2) end
end

-- Opens the panel on key (nil closes it), then redraws: the panel's contents are drawn by refreshList.
local function setOpen(page, key)
  page.open = key
  page.editing = nil
  Page.Refresh(page.frame, page.src)
end

-- Edit why (d791): the panel's box holds the stored why; Save writes it through ns.List.EditWhy, Cancel writes
-- nothing.
local function editWhy(page)
  local cd, box = openCard(page), page.panel.box
  if not (cd and box) then return end
  page.editing = cd.key
  box:SetText(cd.rawWhy or "")
  layout(page)
end

local function saveWhy(page)
  local cd, box = openCard(page), page.panel.box
  if demoRefused() or not (cd and box) then return end
  local done, why = ns.List.EditWhy(cd.guid, box:GetText() or "", ns.Core.Now())
  if done then page.editing = nil else refused(why) end
  Page.Refresh(page.frame, page.src)
end

local function cancelWhy(page)
  page.editing = nil
  layout(page)
end

-- Remove the open target (after the kit's confirm when there is one), then redraw.
local function removeTarget(page)
  local cd = openCard(page)
  if not cd then return end
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

-- A panel row: its label at PANEL_X, its value from PANEL_VALUE_X to 8 px inside the panel's right edge.
local function panelRow(f, label, y)
  local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  l:SetPoint("TOPLEFT", PANEL_X, y)
  l:SetText(label)
  return l, textLine(f, "GameFontHighlightSmall", PANEL_VALUE_X, y)
end

-- The details panel (d77, d79), on the page frame right of the scroll box, as tall as the scroll area (216 at the
-- 760x480 window) and panelWidth wide; shown on List whether or not a card is selected. With none, one centred line
-- (PANEL_HINT). With one, its body: the start-zone painting with its shade, the portrait, the name (gold) and level
-- line over it; Last seen, Why (two lines), Marked; Kills (up to PANEL_KILLS lines); Edit why and Remove for officers
-- and Close for all on one row (216 px with the gaps, so it fits PANEL_MIN_W); Edit why's box over the Why value,
-- Save and Cancel in Edit why's and Remove's place.
local function buildPanel(page, frame)
  local kit = page.src.kit
  local f = makeCard(kit, frame, PANEL_W, 216)
  f:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -BOX_RIGHT, -LIST_TOP)
  f:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -BOX_RIGHT, 0)
  local p = { frame = f, killLines = {} }
  p.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.hint:SetPoint("LEFT", 12, 0)
  p.hint:SetPoint("RIGHT", -12, 0)
  p.hint:SetJustifyH("CENTER")
  p.hint:SetTextColor(DIM[1], DIM[2], DIM[3])
  p.hint:SetText(PANEL_HINT)
  local body = CreateFrame("Frame", nil, f)
  body:SetAllPoints(f)
  body:Hide()
  p.body = body
  p.painting, p.paintBorder = framed(body, PANEL_W - 6, PANEL_PAINT_H)
  p.painting:SetDrawLayer("ARTWORK", 0)
  p.paintBorder:SetPoint("TOPLEFT", 2, -2)
  p.shade = colourTexture(body, "ARTWORK", { 0, 0, 0, 1 })
  p.shade:SetDrawLayer("ARTWORK", 1)
  p.shade:SetPoint("BOTTOMLEFT", p.painting, "BOTTOMLEFT", 0, 0)   -- the painting's lower half
  p.shade:SetPoint("BOTTOMRIGHT", p.painting, "BOTTOMRIGHT", 0, 0)
  p.shade:SetHeight(PANEL_PAINT_H * 0.5)
  shadeFade(p.shade)
  p.portrait, p.portraitBorder = framed(body, PANEL_PORTRAIT, PANEL_PORTRAIT)
  p.portraitBorder:SetDrawLayer("ARTWORK", 2)   -- the portrait sits over the painting's left
  p.portrait:SetDrawLayer("ARTWORK", 3)
  p.portraitBorder:SetPoint("TOPLEFT", 8, -14)
  p.name = textLine(body, "GameFontNormalLarge", 48, -16)   -- the font's own gold (kos-2, f8561)
  p.who = textLine(body, "GameFontHighlightSmall", 48, -36)
  local _
  _, p.seen = panelRow(body, "Last seen", -56)
  _, p.whyValue = panelRow(body, "Why", -70)
  p.whyValue:SetWordWrap(true)
  p.whyValue:SetHeight(24)
  _, p.marked = panelRow(body, "Marked", -96)
  local kills = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  kills:SetPoint("TOPLEFT", PANEL_X, -114)
  kills:SetText("Kills")
  for k = 1, PANEL_KILLS do
    p.killLines[k] = textLine(body, "GameFontHighlightSmall", PANEL_X + 8, -128 - (k - 1) * KILL_STEP)
  end

  p.close = button(body, "Close", 56)
  p.close:SetPoint("TOPRIGHT", -8, -PANEL_BTN_Y)
  p.close:SetScript("OnClick", function() safe(page.src, setOpen, page, nil) end)
  p.remove = button(body, "Remove", 64)
  p.remove:SetPoint("RIGHT", p.close, "LEFT", -4, 0)
  p.remove:SetScript("OnClick", function() safe(page.src, removeTarget, page) end)
  p.edit = button(body, "Edit why", 80)
  p.edit:SetPoint("RIGHT", p.remove, "LEFT", -4, 0)
  p.edit:SetScript("OnClick", function() safe(page.src, editWhy, page) end)
  p.box = kitCall(kit, "InputBox", body, PANEL_W - PANEL_VALUE_X - 8, 200)
  if p.box then
    p.box:SetPoint("TOPLEFT", PANEL_VALUE_X, -66)
    p.box:Hide()
  end
  p.cancel = button(body, "Cancel", 64)
  p.cancel:SetPoint("RIGHT", p.close, "LEFT", -4, 0)
  p.cancel:SetScript("OnClick", function() safe(page.src, cancelWhy, page) end)
  p.save = button(body, "Save", 56)
  p.save:SetPoint("RIGHT", p.cancel, "LEFT", -4, 0)
  p.save:SetScript("OnClick", function() safe(page.src, saveWhy, page) end)
  page.panel = p
end

-- One grid card (d80, d81): M.Kit.Card (or a plain frame when it answers nil), then its regions on the layers of f4699
-- (no Page.lua region on BACKGROUND on a Kit card): the selected wash (ARTWORK -8), the backdrop strip (0) and its
-- shade (1), the portrait's frame (2) and face (3), the class ring (OVERLAY); the click catcher (f4698). A click opens
-- the panel on the card's target, or closes it when the card is the selected one.
local function card(page, i)
  local cd = page.cards[i]
  if cd then return cd end
  local kit = page.src.kit
  local f = makeCard(kit, page.content, 100, GRID_H)

  cd = { frame = f }
  cd.selected = colourTexture(f, "ARTWORK", SELECT_TINT)   -- the selected card's gold wash
  cd.selected:SetDrawLayer("ARTWORK", -8)
  cd.selected:SetAllPoints(f)
  cd.selected:Hide()
  cd.painting = f:CreateTexture(nil, "ARTWORK")             -- d81: the race's start-zone strip, sized in layout()
  cd.painting:SetDrawLayer("ARTWORK", 0)
  cd.painting:SetPoint("TOPLEFT", 2, -2)
  cd.painting:SetAlpha(BACK_A)
  cd.shade = colourTexture(f, "ARTWORK", { 0, 0, 0, 1 })
  cd.shade:SetDrawLayer("ARTWORK", 1)
  cd.shade:SetPoint("BOTTOMLEFT", cd.painting, "BOTTOMLEFT", 0, 0)   -- the strip's lower half fades into the card
  cd.shade:SetPoint("BOTTOMRIGHT", cd.painting, "BOTTOMRIGHT", 0, 0)
  cd.shade:SetHeight(BACK_H * 0.5)
  shadeFade(cd.shade)
  cd.portrait, cd.portraitBorder = framed(f, GRID_PORTRAIT, GRID_PORTRAIT)
  cd.portraitBorder:SetDrawLayer("ARTWORK", 2)
  cd.portrait:SetDrawLayer("ARTWORK", 3)
  cd.portraitBorder:SetPoint("TOPLEFT", 7, -7)
  -- d81: the class ring, 1 px inside the card's edge on every side
  cd.ring = {}
  for k, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" },
      { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local edge = colourTexture(f, "OVERLAY", BORDER)
    edge:SetPoint(pts[1], 0, 0)
    edge:SetPoint(pts[2], 0, 0)
    if k <= 2 then edge:SetHeight(1) else edge:SetWidth(1) end
    edge:Hide()
    cd.ring[k] = edge
  end

  cd.name = textLine(f, "GameFontHighlight", GRID_TEXT_X, -9)   -- the whole width beside the portrait
  cd.name:SetTextColor(RED[1], RED[2], RED[3])
  cd.who = textLine(f, "GameFontHighlightSmall", GRID_TEXT_X, -27)
  cd.status = textLine(f, "GameFontHighlightSmall", GRID_TEXT_X, -43)
  cd.status:SetTextColor(DIM[1], DIM[2], DIM[3])
  cd.why = textLine(f, "GameFontHighlightSmall", 8, -WHY_Y)
  cd.killed = textLine(f, "GameFontHighlightSmall", 8, -KILLED_Y)   -- d78: "Last killed by <name>, <ago>"
  if killsOn() then
    cd.kills = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cd.kills:SetJustifyH("RIGHT")
    cd.kills:SetPoint("BOTTOMRIGHT", -8, 9)
  end
  cd.paid = kitCall(kit, "Pill", f, PAID_PILL, "grey")   -- s5, placed in drawCard
  cd.seenPill = kitCall(kit, "Pill", f, "", "grey")      -- s4: "Seen just now" or "Seen today", placed in drawCard

  cd.catcher = CreateFrame("Button", nil, f)
  cd.catcher:SetAllPoints(f)
  cd.catcher:RegisterForClicks("LeftButtonUp")
  cd.catcher:SetScript("OnClick", function()
    safe(page.src, setOpen, page, page.open ~= cd.key and cd.key or nil)
  end)
  page.cards[i] = cd
  return cd
end

-- The portrait (race, then class atlas, else the skull file; sex 3 tries the female face first, d81) and the start-zone
-- painting (the panel's, and the card's backdrop strip, d81): holder.zone is the painting's atlas, or nil.
local function setArt(holder, rec, kit, sex)
  if holder.painting then
    local race = Page.RaceKey(rec.race)
    local zone = race and "charactercreate-startingzone-" .. race
    holder.zone = (zone and atlas(kit, holder.painting, zone, nil)) and zone or nil
  end

  local tries = Page.Portrait(rec.race, rec.class, sex)
  local drawn = false
  for _, name in ipairs(tries) do
    if atlas(kit, holder.portrait, name, nil) then drawn = true break end
  end
  if not drawn then atlas(kit, holder.portrait, nil, tries.file) end
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
-- d81: level (Seen's when there is one, else the record's) in its danger colour against me (Page.Danger), the skull
-- icon in place of the number when it is more than SKULL_OVER above me or unknown (while the race or class is known).
-- With me nil (the Waiting and Mine cards) the record's level shows plain, and none shows nothing, as before.
local function whoText(src, rec, guid, level, me)
  local parts = {}
  if level == nil then level = rec.level end
  level = type(level) == "number" and level > 0 and math.floor(level) or nil
  local mine = type(me) == "number" and me > 0
  if level and mine and level - me > SKULL_OVER then level = nil end
  if level then
    local d = DANGER[Page.Danger(level, me) or ""]
    parts[#parts + 1] = d and (hexCode(d[1], d[2], d[3]) .. "Level " .. level .. "|r") or ("Level " .. level)
  elseif mine and (nonEmpty(rec.race) or nonEmpty(rec.class)) then
    parts[#parts + 1] = "Level " .. SKULL_ICON
  end
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

-- The shared kills of target guid (d78), newest first: ns.Kill.Recent over the store, or under /gsync demo
-- ns.RulesKills.Recent over the demo's members; {} when the function is not there, throws (recorded through src.safe)
-- or answers no list.
local function recentKills(src, guid)
  if type(guid) ~= "string" then return {} end
  local demo = demoOf(src)
  local good, list
  if demo then
    local rules = ns.RulesKills
    if type(rules) ~= "table" or type(rules.Recent) ~= "function" then return {} end
    good, list = safe(src, rules.Recent, type(demo.kos_m) == "table" and demo.kos_m or {}, guid, ns.Core.Now())
  else
    if type(ns.Kill) ~= "table" or type(ns.Kill.Recent) ~= "function" then return {} end
    good, list = safe(src, ns.Kill.Recent, guid)
  end
  if not good or type(list) ~= "table" then return {} end
  local out = {}
  for _, k in ipairs(list) do
    if type(k) == "table" and type(k.at) == "number" then out[#out + 1] = k end
  end
  return out
end

-- The "Marked" text: "by <marker> <ago>[ · approved by <officer>]".
local function markedText(src, rec, roster, now)
  local marked = "by " .. memberName(src, roster, rec.markedBy)
  if type(rec.markedAt) == "number" then marked = marked .. " " .. ago(now - rec.markedAt) end
  if nonEmpty(rec.decidedBy) then marked = marked .. DOT .. "approved by " .. memberName(src, roster, rec.decidedBy) end
  return marked
end

-- d81: what ns.Seen last saw of guid ({ sex, level, at }), or nil: guarded (another file, written alongside) and
-- through src.safe.
local function seenFace(src, guid)
  local sightings = ns.Seen
  if type(guid) ~= "string" or type(sightings) ~= "table" or type(sightings.Get) ~= "function" then return nil end
  local good, v = safe(src, sightings.Get, guid)
  if good and type(v) == "table" then return v end
  return nil
end

-- d81: my level through the hub (UnitLevel("player")), or nil.
local function myLevel()
  if not (ns.Hub and type(ns.Hub.Call) == "function") then return nil end
  local lv = tonumber((ns.Hub.Call("UnitLevel", "player")))
  return lv and lv > 0 and lv or nil
end

-- The level to draw: Seen's when it has one, else the record's.
local function levelOf(rec, face)
  local lv = face and tonumber(face.level)
  if lv and lv > 0 then return lv end
  return rec.level
end

-- d81: the class colour on the card's ring and the portrait's frame; with no class colour the ring hides (the Kit
-- card's own border shows) and the portrait frame keeps its gold.
local function classFrame(cd, class)
  local r, g, b = classColour(class)
  for _, edge in ipairs(cd.ring) do
    if r then edge:SetColorTexture(r, g, b, 1) end
    edge:SetShown(r ~= nil)
  end
  if r then cd.portraitBorder:SetColorTexture(r, g, b, 1)
  else cd.portraitBorder:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], BORDER[4]) end
end

local function drawCard(page, cd, rec, seen, roster, now, kills, face, me)
  local src = page.src
  local name = shown(src, rec.name)
  cd.shownName = name
  cd.name:SetText(name)
  local who = whoText(src, rec, cd.guid, levelOf(rec, face), me)
  cd.who:SetText(who)
  cd.who:SetShown(who ~= "")
  local seenLine = seenText(src, seen, now)
  cd.status:SetText(seenLine and ("Seen " .. seenLine) or "Never seen")
  classFrame(cd, rec.class)

  -- the full-width lines under the portrait: Why, then Last killed by (each left out with none, closing up)
  cd.rawWhy = type(rec.why) == "string" and rec.why or ""
  local why = shown(src, rec.why)
  cd.why:SetText(GOLD .. "Why:|r " .. why)
  cd.why:SetShown(why ~= "")
  local last = kills[1]
  cd.killed:SetText(last and ("Last killed by " .. memberName(src, roster, last.hunter) .. ", " .. ago(now - last.at)) or "")
  cd.killed:SetShown(last ~= nil)

  -- the confirmed-kill count (ns.Probe.kills true only) at the bottom right
  if cd.kills then
    local n = 0
    for _, k in ipairs(type(rec.kills) == "table" and rec.kills or {}) do
      if type(k) == "table" and type(k.time) == "number" then n = n + 1 end
    end
    cd.kills:SetText(plural(n, "kill"))
  end
  -- the pills right to left at the bottom right: paid this week (s5), then the seen pill (s4), each left of the last
  -- one shown (or of the kill count)
  local right = cd.kills
  for _, pill in ipairs({ cd.paid or false, cd.seenPill or false }) do
    if pill then
      local on = pill == cd.paid and cd.isPaid == true or pill == cd.seenPill and cd.seenText ~= nil
      pill:ClearAllPoints()
      if right then pill:SetPoint("RIGHT", right, "LEFT", -6, 0) else pill:SetPoint("BOTTOMRIGHT", -6, 5) end
      pill:SetShown(on)
      if on then right = pill end
    end
  end
  -- Last killed by takes the Why line's place with no why; under a why it shares the pills' row and stops 6 px short
  cd.killed:ClearAllPoints()
  local y = why ~= "" and -KILLED_Y or -WHY_Y
  cd.killed:SetPoint("TOPLEFT", 8, y)
  if right and why ~= "" then cd.killed:SetPoint("RIGHT", right, "LEFT", -6, 0)
  else cd.killed:SetPoint("TOPRIGHT", TEXT_RIGHT, y) end
end

-- The panel's contents for the open card cd: art (the female face first when Seen saw one, d81), name, level line,
-- Last seen, Why, Marked and up to PANEL_KILLS kills ("<name> <ago>"), or "No kills yet". The painting's crop follows
-- the panel's width in layout().
local function drawPanel(page, cd, rec, seen, roster, now, kills, face, me)
  local src, p = page.src, page.panel
  setArt(p, rec, src.kit, face and face.sex)
  p.painting:SetShown(p.zone ~= nil)
  p.paintBorder:SetShown(p.zone ~= nil)
  p.shade:SetShown(p.zone ~= nil)
  p.name:SetText(cd.shownName)
  local who = whoText(src, rec, cd.guid, levelOf(rec, face), me)
  p.who:SetText(who)
  p.who:SetShown(who ~= "")
  local seenLine = seenText(src, seen, now)
  p.seen:SetText(seenLine and capital(seenLine) or "Never")
  local why = shown(src, rec.why)
  p.whyValue:SetText(why ~= "" and why or "-")
  p.marked:SetText(markedText(src, rec, roster, now))
  for k = 1, PANEL_KILLS do
    local line, kill = p.killLines[k], kills[k]
    if kill then line:SetText(memberName(src, roster, kill.hunter) .. " " .. ago(now - kill.at))
    elseif k == 1 then line:SetText(NO_KILLS) end
    line:SetShown(kill ~= nil or k == 1)
  end
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
  local total = #targets
  local recent = 0
  for _, t in ipairs(targets) do
    local seen = lastSeen[Rules.Key(t.rec.name) or ""]
    t.seen = type(seen) == "table" and seen or nil
    local at = t.seen and tonumber(t.seen.at) or nil
    if at and type(now) == "number" and now - at < RECENT then recent = recent + 1 end
  end
  page.count:SetText(Page.Targets(total) .. (recent > 0 and (DOT .. recent .. " seen in the last 10 min") or ""))
  -- s4: the search, then the remembered sort (ns.Core.Sort); the scroll offset is left as it is
  targets = ns.List.Sort(ns.List.Filter(targets, page.query), ns.Core.Sort())
  local n = #targets
  local muted = ns.Core.DB().muted == true
  if page.alertsBox then page.alertsBox:SetChecked(not muted) else page.alerts:SetText(muted and ALERTS_OFF or ALERTS_ON) end
  page.canWrite = ns.List.CanWrite() == true
  -- s1: while the stores are not ready (roster or guild name unread) the List says so, else an empty List says what
  -- to do; the demo draws made-up targets and needs neither
  local ready, why = true, nil
  if not demoOf(src) then ready, why = ns.Store.Ready() end
  local note
  if not ready then note = ns.List.RefusalLine(why) elseif total == 0 then note = EMPTY_LIST end
  page.noteH = setNote(page.note, note)
  -- s5: this week's kill grain from the local ledger; under the demo neither the strip nor a pill (demo data only)
  local sum, cfg
  if not demoOf(src) and ns.Kill and type(ns.Kill.Week) == "function" then sum, cfg = ns.Kill.Week() end
  page.grain:SetText(sum and ns.RulesKills.Strip(sum, cfg) or "")
  page.grain:SetShown(sum ~= nil and page.tab == "list")

  local openFound = false
  local me = myLevel()   -- d81: the level lines' danger colour
  for i, t in ipairs(targets) do
    local cd = card(page, i)
    cd.guid = t.guid
    cd.key = t.guid or ("#" .. i)
    cd.isPaid = sum ~= nil and t.guid ~= nil and sum.capped[t.guid] == true
    cd.seenText = ns.List.SeenPill(t.seen and tonumber(t.seen.at), now)
    if cd.seenPill and cd.seenText then kitCall(src.kit, "SetPill", cd.seenPill, cd.seenText, SEEN_TONES[cd.seenText]) end
    local kills = recentKills(src, t.guid)
    local face = seenFace(src, t.guid)   -- d81: the seen sex and level (ns.Seen), or nil
    drawCard(page, cd, t.rec, t.seen, roster, now, kills, face, me)
    setArt(cd, t.rec, src.kit, face and face.sex)
    cd.painting:SetShown(cd.zone ~= nil)
    cd.shade:SetShown(cd.zone ~= nil)
    if cd.key == page.open then
      openFound = true
      drawPanel(page, cd, t.rec, t.seen, roster, now, kills, face, me)
    end
    cd.frame:Show()
  end
  for i = n + 1, #page.cards do page.cards[i].frame:Hide() end
  if not openFound then page.open, page.editing = nil, nil end
  page.n = n
  layout(page)
end

-- ---------- List: the Mark as bounty card (o851) ----------

-- The answer line under the form (issue 44 s3, p9): line (nil hides it), cleared ANSWER_S seconds later unless a newer
-- answer took its place.
local function showAnswer(page, line)
  page.answerToken = (page.answerToken or 0) + 1
  local mine = page.answerToken
  page.answer:SetText(line or "")
  page.answer:SetShown(line ~= nil)
  if line and ns.Hub then
    ns.Hub.After(ANSWER_S, function()
      if page.answerToken == mine then page.answer:SetText("") page.answer:Hide() end
    end)
  end
end

-- Mark my target on or off by ns.Mark.Available(fighting); off keeps the refusal for the tooltip.
local function recheck(page, fighting)
  local b = page.markTarget
  if not b or type(ns.Mark) ~= "table" or type(ns.Mark.Available) ~= "function" then return end
  local on, line = ns.Mark.Available(fighting)
  page.markRefusal = on ~= true and line or nil
  if on == true then b:Enable() else b:Disable() end
end

-- A form button MARK_BTN_W wide: M.Kit.Button from API 10, else the page's own button (an API 9 hub).
local function markButton(page, parent, text, onClick)
  local b = kitCall(page.src.kit, "Button", parent, text, MARK_BTN_W, onClick)
  if b then return b end
  b = button(parent, text, MARK_BTN_W)
  b:SetScript("OnClick", onClick)
  return b
end

local function buildMark(page, frame)
  local kit = page.src.kit
  local w = (page.width or PAGE_W) - BOX_RIGHT
  local f = makeCard(kit, frame, w, MARK_H)
  f:SetPoint("TOPLEFT", 0, -MARK_Y)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -8)
  title:SetText("Mark as bounty")
  -- issue 44 s3 (a8): a label over each box in place of the old hint line
  textLine(f, "GameFontHighlightSmall", 14, -24):SetText(NAME_LABEL)
  textLine(f, "GameFontHighlightSmall", 14 + NAME_BOX_W + 8, -24):SetText(WHY_LABEL)
  local nameBox = kitCall(kit, "InputBox", f, NAME_BOX_W, NAME_BOX_W)
  if nameBox then nameBox:SetPoint("TOPLEFT", 14, -40) end
  local whyW = math.min(MARK_BOX_W, w - MARK_BOX_LESS)
  local box = kitCall(kit, "InputBox", f, whyW, math.min(400, whyW))
  if box then box:SetPoint("TOPLEFT", 14 + NAME_BOX_W + 8, -40) end
  page.markBox, page.nameBox = box, nameBox
  page.answer = textLine(f, "GameFontHighlightSmall", 12, ANSWER_Y)
  page.answer:Hide()

  -- One action (p7, p9, a10): FromName or FromTarget; its line shows under the form, and a good mark clears both boxes.
  local function run(byName)
    safe(page.src, function()
      if demoRefused() then return showAnswer(page, ns.List.RefusalLine("demo")) end
      local mark = ns.Mark
      if type(mark) ~= "table" then return end
      local name = nameBox and nameBox:GetText() or ""
      local why = box and box:GetText() or ""
      local done, a, b
      if byName then
        if type(mark.FromName) ~= "function" then return end
        done, a, b = mark.FromName(name, why)
      else
        if type(mark.FromTarget) ~= "function" then return end
        done, a, b = mark.FromTarget(why)
      end
      if done == true then
        if nameBox then nameBox:SetText("") end
        if box then box:SetText("") end
        showAnswer(page, a)
      else
        showAnswer(page, b)
      end
      recheck(page)
    end)
  end
  local function hasName() return nameBox ~= nil and (nameBox:GetText() or ""):find("%S") ~= nil end
  -- Enter (p7): in the Name box Add by name; in the Why box Add by name with a name typed, else Mark my target
  if nameBox then
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() run(true) end)
  end
  if box then
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() run(hasName()) end)
  end
  page.markTarget = markButton(page, f, "Mark my target", function() run(false) end)
  page.markTarget:SetPoint("TOPRIGHT", -16, -39)
  local byName = markButton(page, f, "Add by name", function() run(true) end)
  byName:SetPoint("TOPRIGHT", -16 - MARK_BTN_W - 8, -39)
  -- a disabled Mark my target says why (Mark.Available's line) on hover
  local target = page.markTarget
  if type(target.SetMotionScriptsWhileDisabled) == "function" then target:SetMotionScriptsWhileDisabled(true) end
  target:SetScript("OnEnter", function(self)
    safe(page.src, function()
      local tip = type(compat) == "table" and type(compat.Tooltip) == "function" and compat.Tooltip() or nil
      if not tip or not page.markRefusal then return end
      tip:SetOwner(self, "ANCHOR_TOP")
      tip:SetText(page.markRefusal)
      tip:Show()
    end)
  end)
  target:SetScript("OnLeave", function()
    local tip = type(compat) == "table" and type(compat.Tooltip) == "function" and compat.Tooltip() or nil
    if tip then tip:Hide() end
  end)
  page.mark = f
end

-- Page.Recheck(fighting): Mark my target's state on every shown page (PLAYER_TARGET_CHANGED, PLAYER_REGEN_DISABLED
-- with fighting true, PLAYER_REGEN_ENABLED; Core.OnEvent).
function Page.Recheck(fighting)
  for frame, page in pairs(pages) do
    if frame:IsVisible() then safe(page.src, recheck, page, fighting) end
  end
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
  local y = WAIT_TOP + setNote(set.empty, n == 0 and (officer and WAIT_EMPTY.officer or WAIT_EMPTY.member) or nil)
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
  set.empty = noteLine(child, -WAIT_TOP)
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
  local demo = demoOf(src)
  local list = mineEntries(demo)
  -- s7: under the own marks, the decided ones of the last 7 days (ns.Mark.Decided), each once
  local decided = {}
  if not demo then
    local held = {}
    for _, e in ipairs(list) do held[tostring(e.mark.guid) .. "/" .. tostring(e.mark.time)] = true end
    local got = ns.Mark.Decided(now)
    for _, d in ipairs(type(got) == "table" and got or {}) do
      if type(d) == "table" and type(d.guid) == "string" and DECIDED_TAGS[d.outcome]
        and not held[d.guid .. "/" .. tostring(d.marked)] then decided[#decided + 1] = d end
    end
  end
  -- s1: an officer's marks go straight on the list, so the officer line says why Mine stays empty
  local empty = #list + #decided == 0
    and (ns.List.CanWrite() == true and MINE_EMPTY.officer or MINE_EMPTY.member) or nil
  local y = MINE_TOP + setNote(set.empty, empty)
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
  for i, d in ipairs(decided) do
    local tag = DECIDED_TAGS[d.outcome]
    local cd = markCard(page, set, #list + i)
    cd.entry = nil
    y = y + drawMark(page, set, cd, d, tag .. " " .. ago(now - d.at), tag, false, y) + CARD_GAP
  end
  hideFrom(set, #list + #decided)
  setContentHeight(page, set.child, y)
end

local function buildMine(page)
  local child = CreateFrame("Frame", nil, page.scroll)
  local set = { child = child, cards = {}, buttons = { { text = "Withdraw", w = 90, click = decide("Withdraw") } } }
  page.mine = set
  set.head = kitCall(page.src.kit, "SectionHeader", child, (page.width or PAGE_W) - page.boxRight, "Your marks")
  if set.head then set.head:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0) end
  set.empty = noteLine(child, -MINE_TOP)
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
  page.alerts:SetShown(onList and not page.alertsBox)
  if page.alertsBox then page.alertsBox:SetShown(onList) end
  if page.mark then page.mark:SetShown(onList) end
  if page.sort then page.sort:SetShown(onList) end
  if page.search then page.search:SetShown(onList) end
  for k, child in pairs(page.children) do child:SetShown(k == key) end
  local scroll = page.scroll
  placeScroll(page)   -- the panel shows on List only (d77)
  scroll:SetScrollChild(page.children[key])
  scroll:SetVerticalScroll(0)
  page.contentHeight = 0
  Page.Refresh(page.frame, page.src)
end

-- Issue 44 s6 (q2): Waiting shows only in the officer view (an officer, or anyone under /gsync demo), labelled
-- "Waiting (N)"; for a member it is hidden and the tabs after it close up (each LEFT on the previous shown tab's
-- RIGHT +2, as Kit.Tabs places them). k4: the template sizes a tab on SetText only at build, so a new label is set
-- while the tab is hidden and its Show re-runs the template's resize (its OnShow). Answers true when the page left
-- a Waiting tab it may no longer show (the caller then shows List).
local function layoutTabs(page, demo)
  local tabs = page.tabs
  if not tabs or not tabs.waiting then return false end
  local list, officer = waitingEntries(demo)
  officer = officer or demo ~= nil
  local tab = tabs.waiting
  local label = "Waiting (" .. #list .. ")"
  if officer and page.waitingLabel ~= label then
    page.waitingLabel = label
    tab:Hide()
    tab:SetText(label)
  end
  tab:SetShown(officer)
  local prev
  for _, k in ipairs(tabs.keys) do
    local b = tabs[k]
    if b:IsShown() then
      if prev then
        b:ClearAllPoints()
        b:SetPoint("LEFT", prev, "RIGHT", 2, 0)
      end
      prev = b
    end
  end
  return not officer and page.tab == "waiting"
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
  -- s2: the Alerts box does what /kos on and /kos off do (Core.SetMuted: the same chat line, the Options box follows);
  -- with no checkbox template the sentence above stays
  local box = kitCall(src.kit, "Checkbox", frame, ALERTS_LABEL)
  if box then
    box:SetPoint("RIGHT", frame, "TOPRIGHT", -BOX_RIGHT - ALERTS_LABEL_W, -(TOP + 12))
    box:SetScript("OnClick", function(self)
      safe(page.src, function() ns.Core.SetMuted(not self:GetChecked()) end)
    end)
    page.alertsBox = box
    page.alerts:Hide()
  end
  -- s4: the sort dropdown left of the Alerts box (or sentence), the search box left of it; each refreshes the List
  local left = page.alertsBox or page.alerts
  local leftGap = page.alertsBox and -8 or -12
  page.sort = kitCall(src.kit, "Dropdown", frame, SORT_W, function(_, root)
    for _, by in ipairs(ns.List.SORTS) do
      root:CreateRadio(SORT_TEXTS[by], function(d) return ns.Core.Sort() == d end,
        function(d) safe(page.src, function() ns.Core.SetSort(d) Page.Refresh(page.frame, page.src) end) end, by)
    end
  end)
  if page.sort then
    page.sort:SetPoint("RIGHT", left, "LEFT", leftGap, 0)
    left, leftGap = page.sort, -8
  end
  page.search = kitCall(src.kit, "SearchBox", frame, SEARCH_W, SEARCH_HINT)
    or kitCall(src.kit, "InputBox", frame, SEARCH_W, SEARCH_W)
  if page.search then
    page.search:SetPoint("RIGHT", left, "LEFT", leftGap, 0)
    -- HookScript: SearchBoxTemplate owns OnTextChanged (its hint and clear button)
    page.search:HookScript("OnTextChanged", function(self)
      safe(page.src, function()
        page.query = self:GetText() or ""
        Page.Refresh(page.frame, page.src)
      end)
    end)
  end

  buildMark(page, frame)
  page.grain = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  page.grain:SetPoint("TOPLEFT", 4, -GRAIN_Y)
  page.grain:SetJustifyH("LEFT")
  page.grain:SetTextColor(ALERTS_GREY[1], ALERTS_GREY[2], ALERTS_GREY[3])

  local scroll, plain, right = scrollFrame(frame)
  page.boxRight = right
  page.scroll, page.plain = scroll, plain
  -- each tab's child is created with the scroll as parent, then set as its scroll child when the tab shows
  page.content = emptyChild(page)
  page.note = noteLine(page.content, -4)   -- s1: the List's empty or not-ready line
  page.children.list = page.content
  page.children.waiting = buildWaiting(page)
  if kills then
    page.children.kills = emptyChild(page)
    page.children.hunters = buildHunters(page)
  end
  page.children.mine = buildMine(page)
  buildPanel(page, frame)   -- d77: the open target's details, right of the scroll box

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
  if layoutTabs(page, demo) then return showTab(page, "list") end
  local now = ns.Core.Now()
  recheck(page)
  refreshList(page, roster, now)
  if page.tab == "hunters" and page.hunters then refreshHunters(page, roster, now)
  elseif page.tab == "waiting" then refreshWaiting(page, roster, now)
  elseif page.tab == "mine" then refreshMine(page, roster, now) end
end

return Page
