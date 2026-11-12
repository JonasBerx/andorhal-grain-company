-- GuildSyncExpeditions CharacterTab.lua: the Followers tab, ns.CharacterTab and ns.ShowPortrait (0.19 plan, Seams 10; slice P).
--   ns.ShowPortrait(frame, fid) -> "portrait" | nil, "unknown"   fid is an id or a spec table; frame is a texture
--   CharacterTab.Build(f, bar), CharacterTab.Refresh(f, opts)    the state lives in f.char; bar holds the hire control;
--                                                                 opts { fid, storage } from ns.GoTo, a table or ignored
--   ns.PickedFollower() -> follower|nil   the Barracks' pick, else the first follower in use, else nil; reads only
-- ns.BagGrid, ns.GearCore, ns.GearData and ns.W are read at call time: they load after this file. So is every later
-- slice's call. ns.Follower(fid) is the saved row: this file reads it and never writes it.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local BIG_W, BIG_H = 700, 450
local BIG = { big = true, card = 142, pitch = 146, textX = 48, nameY = 8, stateY = 27, slot = 37, leftPitch = 57, rightX = 221,
  rightPitch = 41, pic = 168, face = 120, ring = 144, slotOut = 5, picX = 45, picY = 57, gap = 4, side = 272, width = 454, colW = 221,
  col2 = 505, bagX = 515, panelW = 580 }
local SMALL = { big = false, card = 114, pitch = 118, textX = 4, nameY = 5, stateY = 24, slot = 35, leftPitch = 51, rightX = 167,
  rightPitch = 37, pic = 120, face = 86, ring = 104, slotOut = 4, picX = 41, picY = 68, gap = 2, side = 216, width = 370, colW = 179,
  col2 = 407, bagX = 216, panelW = 566 }

local DOLL_X, DOLL_Y = 6, 58
local CARD_Y, CARD_H = 6, 44
local BAG_Y = 163
local SECTION_Y = 134
local STRIP_H, STRIP_STEP = 22, 26
local LINE_STEP = 18
local TRAIT_TEXT_Y, TRAIT_GAP = 14, 4
local XP_Y, XP_H = 104, 24
local XP_ART_W, XP_ART_PAD = 312, 14 -- the frame art is 312 wide and its bar starts 14 in, on every side
local BUTTON_H = 22
local TOGGLE_W, MOVE_W, DISMISS_W = 70, 118, 80
local BAR_BUTTON_Y, BAR_TEXT_Y = 450, 454
local SMALL_HELD_Y = 336
local SLOT_ICON_IN = 3
local COUNT_ROOM = 269
local PANEL_H = 262
local HIRE_COLS, HIRE_STEP, HIRE_COL_H = 3, 188, 130
local HIRE_HOLDER_W, HIRE_HOLDER_H, HIRE_HOLDER_Y = 552, 164, 38
local HIRE_BUTTON_W, HIRE_BUTTON_Y = 170, 142
local TRAIT_ROWS = 3
local EDGE_GAP = 6 -- the right column stops short of the page edge

local LEFT = { "head", "neck", "shoulder", "back", "chest", "wrist" }
local RIGHT = { "hands", "waist", "legs", "feet", "finger1", "finger2", "trinket1", "trinket2" }
local UNDER = { "mainhand", "offhand" }

local SHORT = { head = "Head", neck = "Neck", shoulder = "Shou", back = "Back", chest = "Chest", wrist = "Wrist", hands = "Hands",
  waist = "Waist", legs = "Legs", feet = "Feet", finger1 = "Finger", finger2 = "Finger", trinket1 = "Trinket", trinket2 = "Trinket",
  mainhand = "Main", offhand = "Off" }
local FULL = { head = "Head", neck = "Neck", shoulder = "Shoulder", back = "Back", chest = "Chest", wrist = "Wrist", hands = "Hands",
  waist = "Waist", legs = "Legs", feet = "Feet", finger = "Finger", trinket = "Trinket", mainhand = "Main Hand", offhand = "Off Hand" }

local RACE_ART = { Forsaken = { "undead", "Scourge" }, Orc = { "orc", "Orc" }, Tauren = { "tauren", "Tauren" }, Troll = { "troll", "Troll" } }
local ROAD = { Might = "assaults", Cunning = "scouting", Lore = "rituals" }

local RING = "Adventures-Ring-Gold"
local CARD_RING = "Map_Faction_Ring"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local READY, AWAY, RESTING, DEAD, RESERVE = "19ff19", "ffd100", "ff801a", "ff2020", "9d9d9d"
local GOLD, EDGE = "c9a24a", "3a3226"
local CARD_TINT_ALPHA = 0.25

local LINES = {
  taken = "That slot is taken.",
  max = "This piece is fully tempered.",
  short = "Not enough scrap.",
  level = "That follower is too low level for this piece.",
  busy = "That follower is away.",
  name = "Enter a name of 2 to 12 letters.",
  two = "That follower already carries two supplies.",
  same = "That follower already carries one of those.",
  none = "You have none of those.",
}
-- What a call that pays through ns.Grain answers before it gets there. Any other why came from ns.Grain, which has spoken.
local BEFORE_GRAIN = { unknown = true, name = true, race = true, class = true, pair = true, sex = true, full = true, state = true, clock = true }

local CharacterTab = {}
ns.CharacterTab = CharacterTab

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function commas(n)
  return (tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function sizeOf(f)
  return (f:GetWidth() >= BIG_W and f:GetHeight() >= BIG_H) and BIG or SMALL
end

local function anchorOf(f)
  return sizeOf(f).big and "ANCHOR_RIGHT" or "ANCHOR_LEFT"
end

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function ownedTip(owner, f)
  local tip = M.Compat.Tooltip()
  if tip then tip:SetOwner(owner, anchorOf(f)) end
  return tip
end

-- full is the line for "full" where the bag is not what is full; viaGrain marks a call that pays through ns.Grain.
local function refuse(why, full, viaGrain)
  if why == "demo" or (viaGrain and not BEFORE_GRAIN[why]) then return end
  if why == "full" then
    ns.Say(full or (ns.W.Name["Company bag"] .. " is full."))
  else
    ns.Say(LINES[why] or "You cannot do that now.")
  end
end

function ns.ShowPortrait(frame, fid)
  local row
  if type(fid) == "table" then row = fid else row = ns.Follower(fid) end
  local art = row and RACE_ART[row.race]
  if not art then return nil, "unknown" end
  local female = row.sex == "f"
  M.Kit.Atlas(frame, "raceicon128-" .. art[1] .. "-" .. (female and "female" or "male"),
    "Interface\\CharacterFrame\\TemporaryPortrait-" .. (female and "Female" or "Male") .. "-" .. art[2])
  return "portrait"
end

-- The round mask, where the client has one. The mask follows the texture, so it needs no placing of its own.
local function circle(owner, tex)
  if not owner.CreateMaskTexture or not tex.AddMaskTexture then return end
  pcall(function()
    local mask = owner:CreateMaskTexture()
    if not mask then return end
    mask:SetAllPoints(tex)
    mask:SetTexture(MASK)
    tex:AddMaskTexture(mask)
  end)
end

local function edge(frame, a, b, across)
  local t = frame:CreateTexture(nil, "BORDER")
  t:SetPoint(a, frame, a, 0, 0)
  t:SetPoint(b, frame, b, 0, 0)
  if across then t:SetHeight(1) else t:SetWidth(1) end
  return t
end

local function edges(frame)
  return { edge(frame, "TOPLEFT", "TOPRIGHT", true), edge(frame, "BOTTOMLEFT", "BOTTOMRIGHT", true),
    edge(frame, "TOPLEFT", "BOTTOMLEFT"), edge(frame, "TOPRIGHT", "BOTTOMRIGHT") }
end

local function paintEdges(list, hex)
  local r, g, b = rgb(hex)
  for _, t in ipairs(list) do t:SetColorTexture(r, g, b) end
end

local function isReserve(x)
  if ns.IsReserve then return ns.IsReserve(x.id) end
  return x.reserve == true
end

-- In use first, then in reserve, each by id. Answers the list and how many are in use.
local function ordered()
  local list, reserve = {}, {}
  for _, x in ipairs(ns.Followers()) do
    if isReserve(x) then reserve[#reserve + 1] = x else list[#list + 1] = x end
  end
  local inUse = #list
  for _, x in ipairs(reserve) do list[#list + 1] = x end
  return list, inUse
end

-- The Barracks' ui, kept at Build so ns.PickedFollower can read its pick; nil until the page is built.
local barracks

function ns.PickedFollower()
  local list, inUse = ordered()
  local fid = barracks and barracks.fid
  if fid then
    for _, x in ipairs(list) do
      if x.id == fid then return x end
    end
  end
  return inUse > 0 and list[1] or nil
end

-- The piece fid wears in the slot; a gear id whose piece is gone counts as empty, as in Gear.lua.
local function wornAt(fid, key)
  local row = fid and ns.Follower(fid)
  local id = row and row.gear[key]
  local piece = id and ns.Gear(id)
  if piece and piece.row and piece.cell == nil then return piece end
  return nil
end

local function stateWord(x)
  local W = ns.W
  if x.state == "dead" then return "Dead", DEAD end
  if x.state == "out" then return W.Name.out, AWAY end
  if x.state == "rest" then return W.Name.rest, RESTING end
  if isReserve(x) then return W.Name["in reserve"], RESERVE end
  return W.Name.idle, READY
end

-- ns.Now() is nil with no server time; W.Time reads nil as under a minute.
local function timeLeft(x)
  local now = ns.Now()
  return ns.W.Time(now and x.untilT and x.untilT - now)
end

local function stateLine(x)
  local W = ns.W
  if x.state == "dead" then return "Dead" end
  if x.state == "out" then return "On an expedition. Returns in " .. timeLeft(x) .. "." end
  if x.state == "rest" then return "Resting. Ready in " .. timeLeft(x) .. "." end
  if isReserve(x) then return "In reserve" end
  return W.Name.idle
end

local function levelLine(x)
  return "Level " .. x.level .. " " .. x.race .. " " .. x.class
end

local function showCardTip(owner, f, fid)
  local x = fid and ns.Follower(fid)
  local tip = x and ownedTip(owner, f)
  if not tip then return end
  tip:SetText(x.name, 1, 1, 1)
  tip:AddLine(levelLine(x), 1, 1, 1)
  tip:AddLine(stateLine(x), 1, 1, 1)
  tip:Show()
end

local function showSlotTip(owner, f, key)
  local ui = f.char
  local piece = wornAt(ui.fid, key)
  if piece then
    ns.BagGrid.Tip(owner, piece, ns.Follower(ui.fid).level, anchorOf(f))
    return
  end
  local tip = ownedTip(owner, f)
  if not tip then return end
  tip:SetText(FULL[ns.GearCore.KIND[key]], 1, 1, 1)
  tip:Show()
end

local function deathCut(fid)
  local pct = 100
  local function apply(mods)
    if type(mods) == "table" and type(mods.deathPct) == "number" then pct = pct * mods.deathPct / 100 end
  end
  apply(ns.RaceMods(fid))
  if ns.TraitMods then apply(ns.TraitMods(fid)) end
  if ns.SetMods then apply(ns.SetMods(fid)) end
  return 100 - math.floor(pct + 0.5)
end

-- The set the follower wears most of, and how many pieces of it; ties go to the name that sorts first.
local function bestSet(x)
  local counts = {}
  for _, id in pairs(x.gear) do
    local piece = ns.Gear(id)
    local row = piece and piece.row and ns.GearData.Row(piece.row)
    if row and row.set then counts[row.set] = (counts[row.set] or 0) + 1 end
  end
  local best, n
  for set, c in pairs(counts) do
    if not best or c > n or (c == n and set < best) then best, n = set, c end
  end
  return best, n
end

-- ---------- Drops ----------

local function salvageOn(ui, drag, target)
  if target.kind ~= "slot" then return nil, "target" end
  local piece = wornAt(ui.fid, target.key)
  if not piece then
    ns.Say("There is nothing there to temper.")
    return true
  end
  if ns.Follower(ui.fid).state == "out" then return nil, "busy" end
  local row = ns.GearData.Row(piece.row)
  if not row or row.tier ~= drag.key then
    ns.Say("That scrap does not fit this piece.")
    return true
  end
  if piece.broken then return ns.Repair(piece.id, "salvage") end
  return ns.Temper(piece.id)
end

local function supplyOn(drag, target)
  if target.kind == "slot" then
    ns.Say("Drop supplies on the follower.")
    return true
  end
  if not ns.PackSupply then
    ns.Say("Supplies cannot be packed yet.")
    return true
  end
  return ns.PackSupply(target.key, drag.key)
end

-- Answers true when nothing more needs saying.
local function dropOn(ui, drag, target)
  if target.kind == "cell" then
    if drag.worn then return ns.Unequip(drag.fid, drag.worn) end
    if drag.kind ~= "piece" then return true end
    return ns.MovePiece(drag.id, target.key)
  end
  if drag.worn then
    ns.Say("Take that piece off first.")
    return true
  end
  if drag.kind == "relic" then
    ns.Say("Relics belong in the Book of Relics.")
    return true
  end
  if drag.kind == "salvage" then return salvageOn(ui, drag, target) end
  if drag.kind == "supply" then return supplyOn(drag, target) end
  local fid = target.kind == "slot" and ui.fid or target.key
  return ns.Equip(fid, drag.id)
end

local function drop(f, drag, target)
  if target.frame == drag.from or (target.kind == "card" and target.key == nil) then return end
  local done, why = dropOn(f.char, drag, target)
  if not done then refuse(why) end
  CharacterTab.Refresh(f)
end

-- ---------- Small makers ----------

local function font(parent, template)
  return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
end

local function leftText(parent, template)
  local fs = font(parent, template)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function panelButton(parent, w, h, text, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h)
  if text then b:SetText(text) end
  b:SetScript("OnClick", function() M.Safe(onClick) end)
  return b
end

-- The frame art is stretched to the column, so its margin scales with it.
local function xpPad(size)
  return XP_ART_PAD * size.colW / XP_ART_W
end

local function atlasTexture(parent, layer, atlas, fallback)
  local t = parent:CreateTexture(nil, layer)
  M.Kit.Atlas(t, atlas, fallback)
  return t
end

-- ---------- The screen's parts ----------

local function newSlot(f, ui, key)
  local b = CreateFrame("Button", nil, f)
  local art = atlasTexture(b, "BACKGROUND", "UI-Character-Info-GearSlot", { 0, 0, 0, 0.45 })
  local view = { button = b, art = art, icon = b:CreateTexture(nil, "ARTWORK"), edges = edges(b), label = font(b, "GameFontHighlightSmall") }
  view.icon:SetPoint("TOPLEFT", b, "TOPLEFT", SLOT_ICON_IN, -SLOT_ICON_IN)
  view.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -SLOT_ICON_IN, SLOT_ICON_IN)
  view.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  view.label:SetText(SHORT[key])
  ns.BagGrid.Hook(b, ui, function()
    local piece = wornAt(ui.fid, key)
    if not piece then return nil end
    return { id = piece.id, kind = "piece", row = ns.GearData.Row(piece.row), worn = key, fid = ui.fid }
  end)
  b:SetScript("OnClick", function(self, which)
    if which ~= "RightButton" then return end
    local piece = wornAt(ui.fid, key)
    if piece then M.Safe(ns.BagGrid.Menu, self, piece, ui, key) end
  end)
  b:SetScript("OnEnter", function(self) M.Safe(showSlotTip, self, f, key) end)
  b:SetScript("OnLeave", function() M.Safe(hideTip) end)
  ui.slots[key] = b
  ui.slotViews[key] = view
  ui.targets[#ui.targets + 1] = { frame = b, kind = "slot", key = key }
end

local function raiseClick(f, view)
  if not (ns.Raise and view.fid) then return end
  local done, why = ns.Raise(view.fid)
  if not done then refuse(why, nil, true) end
  CharacterTab.Refresh(f)
end

local function sendClick(f)
  if not ns.GoTo then return end
  ns.GoTo("map", { fid = f.char.fid }) -- the card Send shows only on the picked card
  CharacterTab.Refresh(f)
end

local function dismissClick(f, fid)
  local x = fid and ns.Follower(fid)
  if not x then return end
  M.Kit.Confirm("expeditions_dismiss", "Dismiss " .. x.name .. "? Their gear goes to " .. ns.W.Name["Company bag"] .. ".", "Dismiss", function()
    local done, why = ns.Dismiss(fid)
    if not done then refuse(why) end
    CharacterTab.Refresh(f)
  end)
end

local function newCard(f, ui, i)
  local card = CreateFrame("Button", nil, f)
  local bg = card:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(card)
  bg:SetColorTexture(0, 0, 0, 0.45)
  local sel = card:CreateTexture(nil, "BORDER")
  sel:SetAllPoints(card)
  sel:SetColorTexture(0.24, 0.18, 0.04, 0.55)
  local view = { card = card, bg = bg, sel = sel, edges = edges(card), target = { frame = card, kind = "card" } }

  view.face = card:CreateTexture(nil, "ARTWORK")
  view.face:SetSize(34, 34)
  view.face:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -5)
  circle(card, view.face)
  view.ring = atlasTexture(card, "OVERLAY", CARD_RING, nil)
  view.ring:SetSize(42, 42)
  view.ring:SetPoint("TOPLEFT", card, "TOPLEFT", 2, -1)
  view.disc = card:CreateTexture(nil, "OVERLAY", nil, 1)
  view.disc:SetSize(15, 15)
  view.disc:SetPoint("TOPLEFT", card, "TOPLEFT", 28, -27)
  view.disc:SetColorTexture(0.07, 0.07, 0.07)
  circle(card, view.disc)
  view.level = font(card, "NumberFontNormalSmall")
  view.level:SetPoint("CENTER", view.disc, "CENTER", 0, 0)

  view.name = leftText(card)
  view.state = leftText(card, "GameFontHighlightSmall")

  view.send = panelButton(card, 44, 18, "Send", function() sendClick(f) end)
  view.send:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -22)
  view.dismiss = panelButton(card, 60, 18, "Dismiss", function() dismissClick(f, view.fid) end)
  view.dismiss:SetPoint("TOPLEFT", card, "TOPLEFT", 50, -22)
  view.raise = panelButton(card, 64, 18, nil, function() raiseClick(f, view) end)
  view.raise:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -24)

  card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  card:SetScript("OnClick", function(_, which)
    if which == "RightButton" or not view.fid then return end
    M.Safe(function()
      ui.fid = view.fid
      CharacterTab.Refresh(f)
    end)
  end)
  card:SetScript("OnEnter", function(self) M.Safe(showCardTip, self, f, view.fid) end)
  card:SetScript("OnLeave", function() M.Safe(hideTip) end)

  ui.cards[i] = card
  ui.cardViews[i] = view
  ui.targets[#ui.targets + 1] = view.target
end

local function newStrip(f, text)
  local bg = atlasTexture(f, "BACKGROUND", "UI-Character-Info-Stat-StoneBG", { 0.15, 0.12, 0.08, 0.7 })
  local label = font(f, "GameFontNormal")
  label:SetPoint("LEFT", bg, "LEFT", 10, 0)
  label:SetText(text)
  return { bg = bg, label = label }
end

local function newLine(f)
  return { label = font(f, "GameFontNormal"), value = font(f, "GameFontHighlight") }
end

local function newTrait(f)
  local view = { name = leftText(f, "GameFontNormal"), text = leftText(f, "GameFontHighlightSmall"), fade = leftText(f, "GameFontDisableSmall") }
  view.text:SetWordWrap(true)
  return view
end

local function moveTo(frame, f, x, y)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
end

local function showStrip(f, strip, x, y, w)
  moveTo(strip.bg, f, x, y)
  strip.bg:SetSize(w, STRIP_H)
  strip.bg:Show()
  strip.label:Show()
end

local function hideStrip(strip)
  strip.bg:Hide()
  strip.label:Hide()
end

local function showLine(f, view, x, y, w, label, value, hex)
  moveTo(view.label, f, x, y)
  view.label:SetText(label)
  view.label:Show()
  view.value:ClearAllPoints()
  view.value:SetPoint("TOPRIGHT", f, "TOPLEFT", x + w, -y)
  view.value:SetText(value)
  if hex then view.value:SetTextColor(rgb(hex)) else view.value:SetTextColor(1, 1, 1) end
  view.value:Show()
end

local function hideLine(view)
  view.label:Hide()
  view.value:Hide()
end

-- Answers the y under the row; the row is as tall as its text wraps. left is the successes until it fades, or nil.
local function showTrait(f, view, x, y, w, info, left)
  moveTo(view.name, f, x, y)
  view.name:SetWidth(w)
  view.name:SetText(info.name)
  view.name:Show()
  local below = y + TRAIT_TEXT_Y
  moveTo(view.text, f, x, below)
  view.text:SetWidth(w)
  view.text:SetText(info.text or "")
  view.text:Show()
  below = below + view.text:GetStringHeight()
  if type(left) == "number" then
    moveTo(view.fade, f, x, below)
    view.fade:SetWidth(w)
    view.fade:SetText("Fades after " .. left .. (left == 1 and " more success" or " more successes"))
    view.fade:Show()
    below = below + view.fade:GetStringHeight()
  end
  return below + TRAIT_GAP
end

local function hideTrait(view)
  view.name:Hide()
  view.text:Hide()
  view.fade:Hide()
end

-- ---------- The hire panel ----------

local function fillPanel(f)
  local ui = f.char
  if not ui.panel:IsShown() then return end
  local price = ns.HirePrice()
  local line, short
  if price and not M.Demo() then
    local have = M.Purse() or 0
    short = have < price
    line = "You have " .. commas(have)
    if short then line = line .. ": " .. commas(price - have) .. " more to go" end
  end
  ui.shortText:SetText(line or "")
  if short then ui.shortText:SetTextColor(1, 0.125, 0.125) else ui.shortText:SetTextColor(1, 1, 1) end
  ui.shortText:SetShown(line ~= nil)

  ui.offer = ns.HireOffer()
  local on = M.Demo() or (price ~= nil and not short)
  for i, view in ipairs(ui.hireCols) do
    local who = ui.offer[i]
    if who then
      ns.RecruitColumn.Fill(view, "", who, nil, who.name)
      view.button:SetText(price and ("Hire · " .. commas(price)) or "Hire")
      view.button:SetEnabled(on)
    else
      view.frame:Hide()
      view.button:Hide()
    end
  end
end

-- The three can change while the panel is open (a new day): a click on one no longer offered hires nobody.
local function hireNow(f, i)
  local ui = f.char
  local seen, who = ui.offer[i], ns.HireOffer()[i]
  if not (seen and who and seen.name == who.name and seen.race == who.race and seen.class == who.class and seen.sex == who.sex) then return end
  local id, why = ns.Hire(who.name, who.race, who.class, who.sex)
  if id then
    ui.fid = id
    ui.panel:Hide()
  else
    refuse(why, "You cannot hire more followers.", true)
  end
end

local function hireClick(f, i)
  local ui = f.char
  if ui.busy or not ui.panel:IsShown() then return end
  ui.busy = true
  ui.hireCols[i].button:SetEnabled(false)
  M.Safe(hireNow, f, i)
  M.Safe(CharacterTab.Refresh, f) -- clears busy, also after an error in ns.Hire
end

local function newPanel(f, ui)
  local panel = CreateFrame("Frame", nil, f)
  panel:SetAllPoints(f)
  panel:EnableMouse(true)
  local dim = panel:CreateTexture(nil, "BACKGROUND")
  dim:SetAllPoints(panel)
  dim:SetColorTexture(0, 0, 0, 0.6)
  panel:Hide()
  ui.panel = panel

  local card = M.Kit.Card(panel, BIG.panelW, PANEL_H)
  ui.panelCard = card
  local title = font(card, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", card, "TOPLEFT", 16, -14)
  title:SetText("Hire a Follower")

  local holder = CreateFrame("Frame", nil, card)
  holder:SetPoint("TOP", card, "TOP", 0, -HIRE_HOLDER_Y)
  holder:SetSize(HIRE_HOLDER_W, HIRE_HOLDER_H)
  ui.hireCols = {}
  for i = 1, HIRE_COLS do
    local x = (i - 1) * HIRE_STEP
    local view = ns.RecruitColumn.New(holder, x, 0, HIRE_COL_H, false)
    view.button = panelButton(holder, HIRE_BUTTON_W, BUTTON_H, nil, function() hireClick(f, i) end)
    view.button:SetPoint("TOPLEFT", holder, "TOPLEFT", x, -HIRE_BUTTON_Y)
    ui.hireCols[i] = view
  end

  ui.shortText = font(card, "GameFontRed")
  ui.shortText:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 16, 18)

  local cancel = panelButton(card, 100, BUTTON_H, "Cancel", function()
    panel:Hide()
  end)
  cancel:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -16, 14)
end

local function openPanel(f)
  local ui = f.char
  ui.panel:SetFrameLevel(f:GetFrameLevel() + 20)
  ui.panel:Show()
  CharacterTab.Refresh(f)
end

local function showHireTip(owner, f)
  if ns.HirePrice() then return end
  local tip = ownedTip(owner, f)
  if not tip then return end
  tip:SetText("Hire Follower", 1, 1, 1)
  tip:AddLine("Your roster is full.", 1, 0.13, 0.13)
  tip:Show()
end

-- ---------- Build ----------

function CharacterTab.Build(f, bar)
  local BG = ns.BagGrid
  local ui = { root = f, bar = bar, targets = {}, slots = {}, slotViews = {}, cards = {}, cardViews = {}, open = false, offer = {} }
  f.char = ui
  barracks = ui
  function ui.drop(drag, target) drop(f, drag, target) end

  for i = 1, 5 do newCard(f, ui, i) end
  for _, group in ipairs({ LEFT, RIGHT, UNDER }) do
    for _, key in ipairs(group) do newSlot(f, ui, key) end
  end

  -- The picture: the frame is the drop target, the textures sit on it.
  ui.picture = CreateFrame("Frame", nil, f)
  ui.classBg = f:CreateTexture(nil, "BACKGROUND")
  ui.portrait = ui.picture:CreateTexture(nil, "ARTWORK")
  circle(ui.picture, ui.portrait)
  ui.ring = atlasTexture(ui.picture, "OVERLAY", RING, nil)
  ui.portraitTarget = { frame = ui.picture, kind = "portrait" }
  ui.targets[#ui.targets + 1] = ui.portraitTarget

  ui.title = leftText(f, "GameFontNormalLarge")
  ui.sub = leftText(f)

  ui.xp = CreateFrame("Frame", nil, f)
  ui.xpBg = atlasTexture(ui.xp, "BACKGROUND", "Legacy-Progressbar-BG", { 0, 0, 0, 0.6 })
  ui.xpFill = atlasTexture(ui.xp, "ARTWORK", "Legacy-Progressbar-Fill", { 0.58, 0, 0.55, 1 })
  local xpFrame = atlasTexture(ui.xp, "OVERLAY", "Legacy-Progressbar-Frame", nil)
  xpFrame:SetPoint("TOPLEFT", ui.xp, "TOPLEFT", 0, XP_ART_PAD)
  xpFrame:SetPoint("BOTTOMRIGHT", ui.xp, "BOTTOMRIGHT", 0, -XP_ART_PAD)
  ui.xpText = font(ui.xp, "GameFontHighlightSmall")
  ui.xpText:SetPoint("CENTER", ui.xp, "CENTER", 0, 0)

  ui.statsStrip = newStrip(f, "Stats")
  ui.statLines = {}
  for i = 1, 12 do ui.statLines[i] = newLine(f) end
  ui.traitStrip = newStrip(f, "Traits")
  ui.traitViews = {}
  for i = 1, TRAIT_ROWS do ui.traitViews[i] = newTrait(f) end
  ui.recordStrip = newStrip(f, "Record")
  ui.recordLines = { newLine(f), newLine(f) }

  ui.toggle = panelButton(f, TOGGLE_W, BUTTON_H, ns.W.Name["Company bag"], function()
    ui.open = not ui.open
    CharacterTab.Refresh(f)
  end)
  ui.hint = font(f, "GameFontHighlight")
  ui.hint:SetText("Drag gear from " .. ns.W.Name["Company bag"] .. " onto a follower.")
  ui.held = font(f, "GameFontRed")
  ui.held:SetText(ns.W.Name["Company bag"] .. " is full. Free a slot.")

  ui.move = panelButton(f, MOVE_W, BUTTON_H, nil, function()
    local fid = ui.fid
    local x = fid and ns.Follower(fid)
    if not x then return end
    local done, why
    if isReserve(x) then
      done, why = ns.ToUse(fid)
      if not done then refuse(why, "Your roster is full.") end
    else
      done, why = ns.ToReserve(fid)
      if not done then refuse(why, "Your reserve is full.") end
    end
    CharacterTab.Refresh(f)
  end)
  ui.dismiss = panelButton(f, DISMISS_W, BUTTON_H, "Dismiss", function() dismissClick(f, ui.fid) end)
  ui.send = panelButton(f, 156, BUTTON_H, nil, function() sendClick(f) end)

  ui.grids = { big = BG.New(f, 5, 6, 37, 4, ui), small = BG.New(f, 10, 3, 35, 1, ui) }
  ui.bag = ui.grids.big

  ui.hire = panelButton(bar, 110, BUTTON_H, nil, function() openPanel(f) end)
  ui.hire:SetPoint("RIGHT", bar, "RIGHT", -8, 0)
  ui.hire:SetMotionScriptsWhileDisabled(true)
  ui.hire:SetScript("OnEnter", function(self) M.Safe(showHireTip, self, f) end)
  ui.hire:SetScript("OnLeave", function() M.Safe(hideTip) end)
  ui.count = font(bar, "GameFontHighlight")
  ui.count:SetPoint("RIGHT", ui.hire, "LEFT", -8, 0)

  newPanel(f, ui)
  f:SetScript("OnSizeChanged", function(self) M.Safe(CharacterTab.Refresh, self) end)
end

-- ---------- Refresh ----------

local function place(f, size)
  local ui = f.char
  local function slot(key, x, y)
    local b = ui.slots[key]
    moveTo(b, f, x, y)
    b:SetSize(size.slot, size.slot)
    local art = ui.slotViews[key].art
    art:ClearAllPoints()
    art:SetPoint("TOPLEFT", b, "TOPLEFT", -size.slotOut, size.slotOut)
    art:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", size.slotOut, -size.slotOut)
  end
  for i, key in ipairs(LEFT) do slot(key, DOLL_X, DOLL_Y + (i - 1) * size.leftPitch) end
  for i, key in ipairs(RIGHT) do slot(key, DOLL_X + size.rightX, DOLL_Y + (i - 1) * size.rightPitch) end
  local picX, picY = DOLL_X + size.picX, DOLL_Y + size.picY
  local underW = 2 * size.slot + size.gap
  local underX = picX + (size.pic - underW) / 2
  for i, key in ipairs(UNDER) do slot(key, underX + (i - 1) * (size.slot + size.gap), picY + size.pic + size.gap) end

  moveTo(ui.picture, f, picX, picY)
  ui.picture:SetSize(size.pic, size.pic)
  ui.classBg:ClearAllPoints()
  ui.classBg:SetPoint("TOPLEFT", f, "TOPLEFT", picX, -DOLL_Y)
  ui.classBg:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", picX + size.pic, -(DOLL_Y + (#LEFT - 1) * size.leftPitch + size.slot))
  ui.portrait:ClearAllPoints()
  ui.portrait:SetPoint("CENTER", ui.picture, "CENTER", 0, 0)
  ui.portrait:SetSize(size.face, size.face)
  ui.ring:ClearAllPoints()
  ui.ring:SetPoint("CENTER", ui.picture, "CENTER", 0, 0)
  ui.ring:SetSize(size.ring, size.ring)

  for i, view in ipairs(ui.cardViews) do
    moveTo(view.card, f, (i - 1) * size.pitch, CARD_Y)
    view.card:SetSize(size.card, CARD_H)
    view.name:ClearAllPoints()
    view.name:SetPoint("TOPLEFT", view.card, "TOPLEFT", size.textX, -size.nameY)
    view.name:SetWidth(size.card - size.textX - 4)
    view.state:ClearAllPoints()
    view.state:SetPoint("TOPLEFT", view.card, "TOPLEFT", size.textX, -size.stateY)
  end

  local right = size.side + size.width
  moveTo(ui.title, f, size.side, DOLL_Y + 2)
  ui.title:SetWidth(size.width - TOGGLE_W - 4 - 4 - MOVE_W - 4) -- stops short of the header row's Move button at SMALL
  moveTo(ui.sub, f, size.side, DOLL_Y + 24)
  ui.sub:SetWidth(size.width - 4)
  moveTo(ui.xp, f, size.side, XP_Y)
  ui.xp:SetSize(size.colW, XP_H)
  local pad = xpPad(size)
  ui.xpBg:SetPoint("TOPLEFT", ui.xp, "TOPLEFT", pad, 0)
  ui.xpBg:SetPoint("BOTTOMRIGHT", ui.xp, "BOTTOMRIGHT", -pad, 0)
  ui.xpFill:SetPoint("TOPLEFT", ui.xp, "TOPLEFT", pad, 0)
  ui.xpFill:SetHeight(XP_H)
  moveTo(ui.toggle, f, right - TOGGLE_W - 4, 56)

  moveTo(ui.hint, f, 8, BAR_TEXT_Y)
  if size.big then
    moveTo(ui.held, f, 8, BAR_TEXT_Y)
    moveTo(ui.move, f, 346, BAR_BUTTON_Y)
    moveTo(ui.dismiss, f, 470, BAR_BUTTON_Y)
    moveTo(ui.send, f, 556, BAR_BUTTON_Y)
  else
    moveTo(ui.held, f, size.side, SMALL_HELD_Y)
    moveTo(ui.move, f, right - TOGGLE_W - 4 - 4 - MOVE_W, 56)
    moveTo(ui.dismiss, f, right - TOGGLE_W - 4 - 4 - DISMISS_W, 56)
  end

  ui.panelCard:SetSize(size.panelW, PANEL_H)
  ui.panelCard:ClearAllPoints()
  ui.panelCard:SetPoint("CENTER", f, "CENTER", 0, 0)
end

local function fillGrid(f, size)
  local ui = f.char
  local grid, other = size.big and ui.grids.big or ui.grids.small, size.big and ui.grids.small or ui.grids.big
  other.frame:Hide()
  other.Fill(other)
  grid.frame:SetShown(ui.open)
  grid.frame:ClearAllPoints()
  grid.frame:SetPoint("TOPLEFT", f, "TOPLEFT", size.bagX, -BAG_Y)
  grid.Fill(grid)
  ui.bag = grid
end

-- That follower's flair colour, or nil: on a card or the header ring, never the picture.
local function tintOf(x)
  if x and ns.LookTint then return ns.LookTint(x.look) end
  return nil
end

local function fillCard(f, size, view, x)
  local ui = f.char
  view.fid = x and x.id or nil
  view.target.key = view.fid
  local r, g, b = tintOf(x)
  if r then
    view.ring:SetVertexColor(r, g, b)
    view.bg:SetColorTexture(r, g, b, CARD_TINT_ALPHA)
  else
    view.ring:SetVertexColor(1, 1, 1)
    view.bg:SetColorTexture(0, 0, 0, 0.45)
  end
  local selected = x ~= nil and x.id == ui.fid
  view.sel:SetShown(selected)
  paintEdges(view.edges, selected and GOLD or EDGE)
  local showFace = x ~= nil and size.big
  view.face:SetShown(showFace)
  view.ring:SetShown(showFace)
  view.disc:SetShown(showFace)
  view.level:SetShown(showFace)
  view.level:SetText(x and tostring(x.level) or "")
  if showFace then ns.ShowPortrait(view.face, x.id) end
  view.name:SetText(x and x.name or "")

  local word, hex = "", READY
  if x then word, hex = stateWord(x) end
  view.state:SetText(word)
  view.state:SetTextColor(rgb(hex))

  local dead = x ~= nil and x.state == "dead"
  local actions = selected and not size.big and not dead
  view.state:SetShown(x ~= nil and not actions)
  view.send:SetShown(actions)
  view.dismiss:SetShown(actions)
  if actions then
    view.send:SetText(x.state == "idle" and "Send" or word)
    view.send:SetEnabled(x.state == "idle" and not isReserve(x) and ns.GoTo ~= nil)
    view.dismiss:SetEnabled(x.state ~= "out")
  end

  local price = dead and ns.Raise and ns.RaisePrice and ns.RaisePrice(x.id)
  view.raise:SetShown(price and true or false)
  if price then view.raise:SetText("Raise " .. commas(price)) end
end

local function fillSlots(ui, x)
  local GC, GD = ns.GearCore, ns.GearData
  for key, view in pairs(ui.slotViews) do
    local piece = x and wornAt(x.id, key)
    view.label:SetShown(not piece)
    view.icon:SetShown(piece ~= nil)
    for _, t in ipairs(view.edges) do t:SetShown(piece ~= nil) end
    if piece then
      local row = GD.Row(piece.row)
      view.icon:SetTexture(row and row.icon or UNKNOWN_ICON)
      paintEdges(view.edges, row and GC.QUALITY_COLOUR[row.q] or "ffffff")
    end
  end
end

local function fillHeader(ui, size, x)
  ui.picture:SetShown(x ~= nil)
  ui.portraitTarget.key = x and x.id or nil
  ui.xp:SetShown(x ~= nil)
  if not x then
    ui.classBg:Hide()
    ui.title:SetText("No follower yet")
    ui.sub:SetText("")
    return
  end
  ui.title:SetText(x.name)
  ui.sub:SetText(levelLine(x))
  ns.ShowPortrait(ui.portrait, x.id)
  local r, g, b = tintOf(x)
  if r then ui.ring:SetVertexColor(r, g, b) else ui.ring:SetVertexColor(1, 1, 1) end
  ui.classBg:Show()
  M.Kit.ClassBackground(ui.classBg, x.class:upper())
  local need = ns.FollowerCore.ToNext(x.level)
  local ratio = need and math.min(1, x.xp / need) or 1
  ui.xpText:SetText(need and (x.xp .. " / " .. need .. " XP") or "Max Level")
  ui.xpFill:SetWidth(math.max(1, (size.colW - 2 * xpPad(size)) * ratio))
end

local function fillStats(f, size, x, show)
  local ui, W, D = f.char, ns.W, ns.FollowerData
  local lines = ui.statLines
  for _, view in ipairs(lines) do hideLine(view) end
  if not show then
    hideStrip(ui.statsStrip)
    return
  end
  local col, w = size.side, size.colW
  showStrip(f, ui.statsStrip, col, SECTION_Y, w)
  local rows = {}
  local function add(label, value, hex)
    rows[#rows + 1] = { label = label, value = value, hex = hex }
  end
  add("Power", tostring(ns.PowerOf(x.id)))
  add(W.Name["kit score"], tostring(ns.KitScore(x.id)))
  local kind = D.KIND[x.class]
  if kind then add(kind, "+" .. D.AFFINITY .. " Power on " .. ROAD[kind]) end
  local cut = deathCut(x.id)
  if cut > 0 then add(W.Name["death share"], "-" .. cut .. "%", READY) end
  local set, count = bestSet(x)
  if set then add(set, count .. "/6", "0070dd") end
  local GC = ns.GearCore
  local pieces = {}
  for key in pairs(ui.slots) do pieces[key] = wornAt(x.id, key) end
  local totals = GC.StatTotals(pieces)
  if totals.armor > 0 then add("Armor", tostring(totals.armor)) end
  if totals.low then add("Damage", totals.low .. " - " .. totals.high) end
  for _, name in ipairs(GC.STATS) do
    local stat = totals.stats[name]
    if stat and stat > 0 then add(name, "+" .. stat, READY) end
  end
  -- One step for every row: the full step when they fit, tighter when they would reach the bar or the held line.
  local ROW_H = 14
  local first = SECTION_Y + STRIP_STEP
  local limit = size.big and BAR_BUTTON_Y or SMALL_HELD_Y
  local step = math.min(LINE_STEP, math.floor((limit - ROW_H - first) / (#rows - 1)))
  for i, row in ipairs(rows) do
    showLine(f, lines[i], col, first + (i - 1) * step, w, row.label, row.value, row.hex)
  end
end

local function fillRight(f, size, x, show)
  local ui = f.char
  for _, view in ipairs(ui.traitViews) do hideTrait(view) end
  hideStrip(ui.traitStrip)
  for _, view in ipairs(ui.recordLines) do hideLine(view) end
  if not show then
    hideStrip(ui.recordStrip)
    return
  end
  local col, w, y = size.col2, size.colW - EDGE_GAP, SECTION_Y
  local n = 0
  if ns.TraitInfo then
    for _, id in ipairs(x.traits) do
      local info = ns.TraitInfo(id)
      if info and n < TRAIT_ROWS then
        if n == 0 then
          showStrip(f, ui.traitStrip, col, y, w)
          y = y + STRIP_STEP
        end
        n = n + 1
        y = showTrait(f, ui.traitViews[n], col, y, w, info, ns.TraitFade and ns.TraitFade(x.id, id))
      end
    end
  end
  showStrip(f, ui.recordStrip, col, y, w)
  y = y + STRIP_STEP
  local stats = x.stats
  showLine(f, ui.recordLines[1], col, y, w, "Successes", stats.wins .. " of " .. stats.runs)
  local killed = stats.raised + (x.state == "dead" and 1 or 0)
  showLine(f, ui.recordLines[2], col, y + LINE_STEP, w, "Times killed", tostring(killed))
end

local function fillActions(f, size, x)
  local ui = f.char
  local big = size.big
  local dead = x ~= nil and x.state == "dead"
  local reserve = x ~= nil and isReserve(x)
  local canMove = x ~= nil and ((reserve and ns.ToUse ~= nil) or (not reserve and ns.ToReserve ~= nil))
  ui.move:SetShown(canMove and (big or not dead))
  if canMove then
    ui.move:SetText(reserve and "Move to Use" or "Move to Reserve")
    ui.move:SetEnabled(x.state == "idle")
  end
  ui.dismiss:SetShown(x ~= nil and (big or dead))
  if x then ui.dismiss:SetEnabled(x.state ~= "out") end
  ui.send:SetShown(big and x ~= nil)
  if big and x then
    local idle = x.state == "idle"
    ui.send:SetText(idle and "Send on Expedition" or (stateWord(x)))
    ui.send:SetEnabled(idle and not reserve and ns.GoTo ~= nil)
  end
end

-- opts (ns.GoTo's arrival) counts only as a table: fid picks that follower and closes the hire panel, storage opens
-- Storage. It is read here and never kept.
function CharacterTab.Refresh(f, opts)
  local ui = f.char
  if type(opts) == "table" then
    if opts.fid then
      ui.fid = opts.fid
      ui.panel:Hide()
    end
    if opts.storage then ui.open = true end
  end
  local size = sizeOf(f)
  ui.busy = false
  place(f, size)

  local list, inUse = ordered()
  local x
  for _, row in ipairs(list) do
    if row.id == ui.fid then x = row end
  end
  x = x or list[1]
  ui.fid = x and x.id or nil
  ui.name = x and x.name or nil

  for i, view in ipairs(ui.cardViews) do fillCard(f, size, view, list[i]) end
  fillSlots(ui, x)
  fillHeader(ui, size, x)
  fillStats(f, size, x, x ~= nil and (size.big or not ui.open))
  fillRight(f, size, x, x ~= nil and not ui.open)
  fillGrid(f, size)
  fillActions(f, size, x)

  local heldRows = ns.HeldEpics and ns.HeldEpics()
  local held = heldRows and #heldRows > 0 or false
  ui.held:SetShown(held)
  ui.hint:SetShown(size.big and not held)

  ui.count:SetText(inUse .. "/" .. ns.FollowerData.CAP_USE .. " Followers")
  ui.count:SetShown(ui.bar:GetWidth() >= COUNT_ROOM)
  local price = ns.HirePrice()
  ui.hire:SetText(price and ("Hire · " .. commas(price)) or "Hire")
  ui.hire:SetEnabled(price ~= nil)
  fillPanel(f)
end
