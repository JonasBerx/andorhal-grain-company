-- GuildSyncGames Harvest.lua (Task 5): the Harvest tab body, ns.HarvestTab (mock hv-1). Left: the title, the sub line,
-- the field (24 wheat plots over a cut of the Western Plaguelands map, lit as grown), the standing bar, Harvest, the
-- purse and the lifetime line. Right: Upgrades (icon, name, what a rank gives, pips, rank, Buy) and Guild harvest
-- (M.Kit.List). All UI state lives in H.
-- S13 Task 6 (mock hv-2..hv-4, plan V5-V6): the caravan block under the lifetime line (at the small size the purse sits
-- beside Harvest and the purse label and lifetime line go, hv-4), the owned decorations in fixed slots along the
-- field's bottom edge, and the Company look ("Name, Title" cut to the row, worn colour, badge) on the board rows.
-- The tab is ns.HarvestTab; ns.Harvest is Grain.lua's action (f7201, d1546). ns.Farm, ns.Purse, ns.Harvest, ns.Buy,
-- ns.GuildBoards, ns.ShownGame, ns.Caravan, ns.LastCaravan, ns.SendCaravan, ns.CompanyState and ns.CompanyLook are
-- looked up at call time (f7165: Demo.lua wraps them, tests replace them).
-- No division by a variable (games_static): the bar is a StatusBar the client fills, the rest is counted up.

local _, ns = ...

if not ns.M then return end
local M, GC = ns.M, ns.GrainCore

local PLOTS, PLOT_COLS = 24, 8
local LEFT, COL_W, FIELD_Y, RX = 8, 330, 46, 352
local BIG = { fieldH = 150, plot = 32, dx = 39, dy = 42 }
local SMALL = { fieldH = 110, plot = 26, dx = 39, dy = 32 } -- below 420 tall (the 760x480 window)
local SMALL_BELOW = 420
local ROW_H, ROW_Y = 56, 34 -- the upgrade rows
local ROW_H_NARROW = 76     -- a narrow right column: Buy on its own line under the pips (f7218)
local NARROW_BELOW = 330    -- the right column's width under which Buy moves (the 760x480 window gives 220)
local WHEAT = 134058        -- INV_Misc_Food_Wheat_01
-- The field's backdrop: the painted world map, 4x3 tiles of 256 (1002x668 shown), cut at map 300,240 (NOTES-hk).
local TILE, TILE_COLS, TILE_ROWS = 256, 4, 3
local CROP_X, CROP_Y = 300, 240
local TILE_PATH = "Interface\\WorldMap\\WesternPlaguelands\\WesternPlaguelands"
local INSET = 3 -- the tiles sit inside the inset's rim
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GOLD = { 1, 0.769, 0.251 }
local DIM = 0.45 -- a plot not grown yet
local DECOR_SLOTS = 6 -- CC decor items carry slot 1..6, slot 6 at the field's bottom-right corner
local TRIPS, STAKES = ns.CompanyCore.TRIPS, ns.CompanyCore.STAKES -- the buttons, from the list SendCaravan checks
local CARAVAN_REFUSE = {
  short = "Not enough grain in the purse.",
  busy = "A caravan is already on the road.",
  choice = "Pick a trip and a stake.",
  clock = "No server clock yet; try again in a moment.",
  demo = "Demo: nothing is saved.",
}

local H = { plots = {}, tiles = {}, rows = {}, decor = {}, trips = {}, stakes = {} }

local grey, label, button, fmt = ns.UI.grey, ns.UI.label, ns.UI.button, ns.UI.fmt -- Page.lua's helpers

-- The kit's section header, or a plain one when it answers nil (API.md:1199).
local function header(parent, text)
  local h = M.Kit.SectionHeader(parent, 360, text)
  if h then return h end
  h = CreateFrame("Frame", nil, parent)
  h:SetSize(360, 26)
  local fs = label(h, "GameFontNormal")
  fs:SetPoint("LEFT", h, "LEFT", 8, 0)
  fs:SetText(text)
  return h
end

-- ---------- layout (the field's height and plot size follow the body's height) ----------

-- The map tiles that cover a w x h cut at CROP_X, CROP_Y, each placed and cut with texcoords; up to 4 are used.
local function placeTiles(w, h)
  local used = 0
  for r = 0, TILE_ROWS - 1 do
    for c = 0, TILE_COLS - 1 do
      local x0, y0 = math.max(CROP_X, c * TILE), math.max(CROP_Y, r * TILE)
      local x1, y1 = math.min(CROP_X + w, (c + 1) * TILE), math.min(CROP_Y + h, (r + 1) * TILE)
      if x1 > x0 and y1 > y0 and used < #H.tiles then
        used = used + 1
        local t = H.tiles[used]
        t:SetTexture(TILE_PATH .. (r * TILE_COLS + c + 1))
        t:SetTexCoord((x0 - c * TILE) / TILE, (x1 - c * TILE) / TILE, (y0 - r * TILE) / TILE, (y1 - r * TILE) / TILE)
        t:SetSize(x1 - x0, y1 - y0)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", H.field, "TOPLEFT", INSET + x0 - CROP_X, -(INSET + y0 - CROP_Y))
        t:Show()
      end
    end
  end
  for i = used + 1, #H.tiles do H.tiles[i]:Hide() end
end

-- The upgrade rows and Guild harvest under them. Wide: Buy at the row's right (hv-1). Narrow: Buy under the pips, so
-- the name and the line never run under it (f7218).
local function placeRight(narrow)
  local rowH = narrow and ROW_H_NARROW or ROW_H
  for i, row in ipairs(H.rows) do
    local y = ROW_Y + (i - 1) * rowH
    row.f:ClearAllPoints()
    row.f:SetPoint("TOPLEFT", H.right, "TOPLEFT", 0, -y)
    row.f:SetPoint("TOPRIGHT", H.right, "TOPRIGHT", 0, -y)
    row.f:SetHeight(rowH)
    row.buy:ClearAllPoints()
    if narrow then
      row.buy:SetPoint("TOPLEFT", row.f, "TOPLEFT", 50, -50)
    else
      row.buy:SetPoint("TOPRIGHT", row.f, "TOPRIGHT", -6, -12)
    end
  end
  local gy = ROW_Y + #H.rows * rowH + 8
  H.guild:ClearAllPoints()
  H.guild:SetPoint("TOPLEFT", H.right, "TOPLEFT", 0, -gy)
  H.guild:SetPoint("TOPRIGHT", H.right, "TOPRIGHT", 0, -gy)
  H.guildBox:ClearAllPoints()
  H.guildBox:SetPoint("TOPLEFT", H.right, "TOPLEFT", 0, -(gy + 26))
  H.guildBox:SetPoint("BOTTOMRIGHT", H.right, "BOTTOMRIGHT", 0, 0)
end

-- The owned decorations' icons by slot (ns.CompanyState().owned, CC.Item); an owned id with no item (23..28, earned
-- badges) or of another kind is skipped.
local function decorBySlot()
  local out, CC = {}, ns.CompanyCore
  local st = ns.CompanyState and ns.CompanyState()
  if type(CC) ~= "table" or type(st) ~= "table" or type(st.owned) ~= "table" then return out end
  for id, on in pairs(st.owned) do
    local it = on and CC.Item(id)
    if type(it) == "table" and it.kind == "decor" and type(it.slot) == "number" and it.slot >= 1
      and it.slot <= DECOR_SLOTS then
      out[it.slot] = it.icon
    end
  end
  return out
end

-- Decorations in fixed slots along the field's bottom edge, slot 6 in the bottom-right corner (hv-2).
local function placeDecor(slots, size)
  for i, t in ipairs(H.decor) do
    if slots[i] ~= nil then
      t:SetTexture(slots[i])
      t:SetSize(size, size)
      t:ClearAllPoints()
      t:SetPoint("BOTTOMRIGHT", H.field, "BOTTOMRIGHT", -(INSET + 2 + (DECOR_SLOTS - i) * (size + 2)), INSET + 2)
      t:Show()
    else
      t:Hide()
    end
  end
end

-- The caravan block (V5): header, one state line, the Trip and Stake rows with Send at the right.
local function placeCaravan(y)
  local C = H.car
  local function at(f, x, dy)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", H.body, "TOPLEFT", x, -(y + dy))
  end
  at(C.head, LEFT, 0)
  C.head:SetWidth(COL_W)
  at(C.line, LEFT, 30)
  at(C.tripL, LEFT, 52)
  at(C.stakeL, LEFT, 78)
  for k, b in ipairs(H.trips) do at(b, LEFT + 48 + (k - 1) * 44, 48) end
  for k, b in ipairs(H.stakes) do at(b, LEFT + 48 + (k - 1) * 44, 74) end
  at(C.send, LEFT + COL_W - 90, 74)
end

function H.Layout()
  local h, w = H.body:GetHeight(), H.body:GetWidth()
  local small = type(h) == "number" and h > 0 and h < SMALL_BELOW
  local narrow = type(w) == "number" and w > 0 and w - RX - 14 < NARROW_BELOW
  local slots = decorBySlot()
  local sig = tostring(small) .. ":" .. tostring(narrow)
  for i = 1, DECOR_SLOTS do sig = sig .. ":" .. tostring(slots[i]) end -- the owned set (f12)
  if H.laid == sig then return end
  H.laid = sig
  placeRight(narrow)
  placeDecor(slots, small and 20 or 24)
  local B = small and SMALL or BIG
  H.field:SetSize(COL_W, B.fieldH)
  placeTiles(COL_W - 2 * INSET, B.fieldH - 2 * INSET)
  local x0 = math.floor((COL_W - ((PLOT_COLS - 1) * B.dx + B.plot)) * 0.5)
  local y0 = math.floor((B.fieldH - (2 * B.dy + B.plot)) * 0.5)
  for i, p in ipairs(H.plots) do
    local col, row = (i - 1) % PLOT_COLS, math.floor((i - 1) / PLOT_COLS)
    p:SetSize(B.plot, B.plot)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", H.field, "TOPLEFT", x0 + col * B.dx, -(y0 + row * B.dy))
  end
  -- everything under the field moves with its height (hv-1: label 206, bar 222, button 260, purse 300 at 150 tall)
  local y = FIELD_Y + B.fieldH + 10
  local function at(f, x, dy)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", H.body, "TOPLEFT", x, -(y + dy))
  end
  at(H.standLabel, LEFT, 0)
  at(H.rate, LEFT + COL_W - 160, 1)
  at(H.bar, LEFT, small and 12 or 16)
  if small then -- hv-4: the purse beside Harvest, no purse label or lifetime line, the caravan under them
    at(H.harvest, LEFT, 54)
    at(H.purseIcon, LEFT + 196, 57)
    at(H.purse, LEFT + 218, 59)
    H.purseLabel:Hide()
    H.lifetime:Hide()
    placeCaravan(y + 80)
  else
    at(H.harvest, LEFT + math.floor((COL_W - 180) * 0.5), 54)
    at(H.purseLabel, LEFT, 94)
    at(H.purseIcon, LEFT, 112)
    at(H.purse, LEFT + 22, 114)
    at(H.lifetime, LEFT, 136)
    H.purseLabel:Show()
    H.lifetime:Show()
    placeCaravan(y + 156)
  end
end

-- ---------- drawing ----------

local function drawField(farm)
  local standing, cap, rate = farm.standing, farm.cap, farm.rate
  local lit = 0 -- plots lit: the largest k with k * cap <= standing * 24, counted up (no division by cap)
  while lit < PLOTS and (lit + 1) * cap <= standing * PLOTS do lit = lit + 1 end
  for i, p in ipairs(H.plots) do
    local grown = i <= lit
    p:SetDesaturated(not grown)
    p:SetVertexColor(1, 1, 1, grown and 1 or DIM)
  end
  local full = " · full"
  if standing < cap and rate > 0 then
    local mins, s = 0, standing -- the minutes until full, one growth at a time (GC.Grow's rule)
    while s < cap and mins < 100000 do
      s = s + rate
      mins = mins + 1
    end
    full = " · full in " .. mins .. " min"
  end
  H.rate:SetText(rate .. " a minute" .. full)
  if H.grow then
    H.grow:SetMinMaxValues(0, cap)
    H.grow:SetValue(standing)
  end
  H.barText:SetText(standing .. " / " .. cap)
  H.harvest:SetText("Harvest " .. standing .. " grain")
  H.harvest:SetEnabled(standing > 0)
  H.purse:SetText(fmt(ns.Purse()) .. " grain")
  H.lifetime:SetText("Harvested in all: " .. fmt(farm.harvested) .. " grain")
end

local function drawUpgrades(farm)
  local purse = ns.Purse()
  for _, row in ipairs(H.rows) do
    local u = row.u
    local rank = farm.ranks[u.id] or 0
    for k, check in ipairs(row.checks) do check:SetShown(k <= rank) end
    row.rank:SetText("rank " .. rank .. " of " .. #u.prices)
    local price = GC.NextPrice(farm.ranks, u.id)
    if price then
      row.buy:SetText("Buy rank " .. (rank + 1) .. " · " .. price)
      row.buy:SetEnabled(price <= purse)
      row.buy.reason = price > purse
        and ("Not enough grain: rank " .. (rank + 1) .. " costs " .. fmt(price) .. " grain, you have " .. fmt(purse)
          .. " grain.") or nil
      row.buy:Show()
    else -- the top rank: the pips and "rank 3 of 3" say it (f7202)
      row.buy:SetEnabled(false)
      row.buy.reason = nil
      row.buy:Hide()
    end
  end
end

-- "HH:MM" realm time for a ns.Now() value (no date(): the clock rule, games_static).
local function clock(t)
  local off = ns.RealmOffset and ns.RealmOffset() or 0
  local s = math.floor(t + off * 3600) % 86400
  return string.format("%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60))
end

-- "2 h 10 min" / "10 min" for seconds left, minutes rounded up.
local function left(secs)
  local mins = math.ceil(secs / 60)
  local hrs = math.floor(mins / 60)
  mins = mins - hrs * 60
  return hrs > 0 and (hrs .. " h " .. mins .. " min") or (mins .. " min")
end

-- The caravan's state as a key: a refusal line shows until the state moves on.
local function caravanState()
  local cur = ns.Caravan and ns.Caravan()
  local last = ns.LastCaravan and ns.LastCaravan()
  if type(cur) ~= "table" then cur = nil end
  if type(last) ~= "table" then last = nil end
  local key = cur and ("road" .. tostring(cur.start)) or last and ("back" .. tostring(last.start)) or "idle"
  return cur, last, key
end

-- One row of choice buttons: shown while idle, the picked value's button lit.
local function choiceRow(buttons, values, picked, idle)
  for k, b in ipairs(buttons) do
    b:SetShown(idle)
    if b.LockHighlight then if picked == values[k] then b:LockHighlight() else b:UnlockHighlight() end end
  end
end

local function drawCaravan()
  local C = H.car
  local cur, last, key = caravanState()
  if H.carMsg and H.carMsg.key ~= key then H.carMsg = nil end
  local text
  if cur then
    local back = (cur.start or 0) + (cur.hours or 0) * 3600
    local rest = back - (ns.Now() or back)
    text = "On the road: " .. fmt(cur.stake or 0) .. " grain, back at " .. clock(back)
      .. (rest > 0 and (" (" .. left(rest) .. ")") or "")
  elseif H.carMsg then
    text = H.carMsg.text
  elseif last and last.kind == "bandits" then
    text = "Defias bandits took " .. fmt((last.stake or 0) - (last.back or 0)) .. " of your " .. fmt(last.stake or 0)
      .. " grain."
  elseif last then
    text = "Back from the road: " .. fmt(last.stake or 0) .. " grain came back as " .. fmt(last.back or 0) .. "."
  else
    text = "Send grain on the road. Defias bandits may take part of it."
  end
  C.line:SetText(text)
  local idle = cur == nil
  C.tripL:SetShown(idle)
  C.stakeL:SetShown(idle)
  C.send:SetShown(idle)
  choiceRow(H.trips, TRIPS, H.trip, idle)
  choiceRow(H.stakes, STAKES, H.stake, idle)
end

function H.Draw()
  H.Layout()
  local farm = ns.Farm()
  drawField(farm)
  drawUpgrades(farm)
  drawCaravan()
  local boards = ns.GuildBoards and ns.GuildBoards()
  local list = type(boards) == "table" and type(boards.harvest) == "table" and boards.harvest or {}
  H.farms:SetText(#list .. " farms")
  if H.list then H.list:SetRows(list) end
end

local function act(fn, ...)
  fn(...)
  H.Draw()
end

-- Send: what was picked goes to ns.SendCaravan; a refusal shows its line until the caravan's state moves on.
local function send()
  local done, why = ns.SendCaravan(H.trip, H.stake)
  local text = not done and CARAVAN_REFUSE[why]
  if text then
    local _, _, key = caravanState()
    H.carMsg = { text = text, key = key }
  else
    H.carMsg = nil
  end
end

-- ---------- the guild harvest list's rows ----------

local NAME_X, VALUE_W = 42, 70

local function buildRow(f)
  f.badge = f:CreateTexture(nil, "ARTWORK") -- the worn Company badge (V6: badge, class icon, name)
  f.badge:SetSize(16, 16)
  f.badge:SetPoint("LEFT", f, "LEFT", 4, 0)
  f.badge:Hide()
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(16, 16)
  f.icon:SetPoint("LEFT", f, "LEFT", 22, 0)
  f.name = label(f)
  f.name:SetPoint("LEFT", f, "LEFT", NAME_X, 0)
  f.name:SetWidth(120)
  f.name:SetWordWrap(false) -- "Name, Title" is cut with an ellipsis before the value (hv-4)
  f.value = label(f, "GameFontHighlight")
  f.value:SetJustifyH("RIGHT")
  f.value:SetPoint("RIGHT", f, "RIGHT", -8, 0)
  f.value:SetWidth(VALUE_W)
  M.Kit.ListHover(f)
end

local function initRow(f, e)
  M.Kit.ClassIcon(f.icon, e.class)
  local look = ns.CompanyLook and ns.CompanyLook(e.key)
  if type(look) ~= "table" then look = nil end
  local name = ns.Escape(e.name)
  if look and type(look.title) == "string" and look.title ~= "" then name = name .. ", " .. look.title end
  if look and type(look.hex) == "string" and look.hex:match("^%x%x%x%x%x%x$") then
    name = "|cff" .. look.hex .. name .. "|r" -- the worn colour over the class colour (d1589)
  end
  f.name:SetText(name .. (e.you and " |cff999999(you)|r" or "")) -- "(you)" grey, the name in its class colour (f7223)
  ns.UI.classColour(f.name, e.class)
  local w = f:GetWidth()
  if type(w) == "number" and w > NAME_X + VALUE_W + 16 then f.name:SetWidth(w - NAME_X - VALUE_W - 12) end
  if look and look.badge ~= nil then
    f.badge:SetTexture(look.badge)
    f.badge:Show()
  else
    f.badge:Hide()
  end
  f.value:SetText(fmt(e.harvested or 0))
end

-- ---------- build ----------

-- A disabled button still runs OnEnter (guarded), and the hover shows btn.reason when drawUpgrades set one (26.a2).
local function reasonTip(btn)
  if btn.SetMotionScriptsWhileDisabled then btn:SetMotionScriptsWhileDisabled(true) end
  btn:SetScript("OnEnter", function(self)
    M.Safe(function()
      local tip = M.Compat.Tooltip()
      if not (self.reason and tip) then return end
      tip:SetOwner(self, "ANCHOR_RIGHT")
      tip:SetText(self.reason, 1, 1, 1, 1, true)
      tip:Show()
    end)
  end)
  btn:SetScript("OnLeave", function()
    M.Safe(function()
      local tip = M.Compat.Tooltip()
      if tip then tip:Hide() end
    end)
  end)
end

-- One upgrade row on its own frame (placeRight anchors the frame and the Buy button).
local function buildUpgrade(R, u, i)
  local parent = CreateFrame("Frame", nil, R)
  local y = 0 -- the offsets below are inside the row frame
  local row = { u = u, checks = {}, f = parent }
  local icon = parent:CreateTexture(nil, "ARTWORK")
  icon:SetSize(36, 36)
  icon:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, -(y + 4))
  icon:SetTexture(u.icon)
  local name = label(parent, "GameFontNormal")
  name:SetPoint("TOPLEFT", parent, "TOPLEFT", 50, -y)
  name:SetText(u.name)
  local what = label(parent)
  grey(what)
  what:SetPoint("TOPLEFT", parent, "TOPLEFT", 50, -(y + 16))
  what:SetText(u.cap > 0 and ("+" .. u.cap .. " grain held a rank.") or ("+" .. u.rate .. " grain a minute a rank."))
  for k = 1, #u.prices do
    local box = parent:CreateTexture(nil, "ARTWORK")
    box:SetSize(14, 14)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 50 + (k - 1) * 16, -(y + 32))
    M.Kit.Atlas(box, "checkbox-minimal")
    local check = parent:CreateTexture(nil, "OVERLAY")
    check:SetAllPoints(box)
    M.Kit.Atlas(check, "checkmark-minimal")
    row.checks[k] = check
  end
  row.rank = label(parent)
  grey(row.rank)
  row.rank:SetPoint("TOPLEFT", parent, "TOPLEFT", 102, -(y + 33))
  row.buy = button(parent, "", 130)
  row.buy:SetScript("OnClick", function() M.Safe(act, ns.Buy, u.id) end)
  reasonTip(row.buy)
  H.rows[i] = row
end

local function buildRight(body)
  local R = CreateFrame("Frame", nil, body)
  R:SetPoint("TOPLEFT", body, "TOPLEFT", RX, 0)
  R:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -14, 0)
  H.right = R
  local head = header(R, "Upgrades")
  head:SetPoint("TOPLEFT", R, "TOPLEFT", 0, 0)
  head:SetPoint("TOPRIGHT", R, "TOPRIGHT", 0, 0)
  for i, u in ipairs(GC.UPGRADES) do buildUpgrade(R, u, i) end
  H.guild = header(R, "Guild harvest")
  H.farms = label(H.guild)
  H.farms:SetPoint("TOPRIGHT", H.guild, "TOPRIGHT", -21, -8)
  H.guildBox = CreateFrame("Frame", nil, R)
  H.list = M.Kit.List(H.guildBox, 22, buildRow, initRow)
end

-- The field: the kit's inset one frame level below (its rim shows; with no map art it is the backdrop), the map tiles
-- inside the rim, the 24 wheat plots over them.
local function buildField(body)
  H.field = CreateFrame("Frame", nil, body)
  H.field:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -FIELD_Y)
  ns.UI.inset(H.field)
  for i = 1, 4 do H.tiles[i] = H.field:CreateTexture(nil, "BACKGROUND") end
  for i = 1, PLOTS do
    local p = H.field:CreateTexture(nil, "ARTWORK")
    p:SetTexture(WHEAT)
    H.plots[i] = p
  end
  for i = 1, DECOR_SLOTS do
    H.decor[i] = H.field:CreateTexture(nil, "OVERLAY")
    H.decor[i]:Hide()
  end
end

-- The caravan block (V5, hv-2, hv-3); placeCaravan anchors it, drawCaravan fills it.
local function buildCaravan(body)
  local C = {}
  H.car = C
  C.head = header(body, "Caravan")
  local where = label(C.head)
  where:SetPoint("TOPRIGHT", C.head, "TOPRIGHT", -21, -8)
  where:SetText("to Hillsbrad")
  C.line = label(body)
  C.line:SetWidth(COL_W)
  C.line:SetWordWrap(false)
  C.tripL = label(body)
  grey(C.tripL)
  C.tripL:SetText("Trip")
  C.stakeL = label(body)
  grey(C.stakeL)
  C.stakeL:SetText("Stake")
  for k, hrs in ipairs(TRIPS) do
    local b = button(body, hrs .. " h", 40)
    b:SetScript("OnClick", function() M.Safe(act, function() H.trip, H.carMsg = hrs, nil end) end)
    H.trips[k] = b
  end
  for k, n in ipairs(STAKES) do
    local b = button(body, tostring(n), 40)
    b:SetScript("OnClick", function() M.Safe(act, function() H.stake, H.carMsg = n, nil end) end)
    H.stakes[k] = b
  end
  C.send = button(body, "Send", 90)
  C.send:SetScript("OnClick", function() M.Safe(act, send) end)
end

-- The standing bar: an M.Kit.StatBar with a gold StatusBar in its fill, the text one level above it.
local function buildBar(body)
  H.bar = M.Kit.StatBar(body) or CreateFrame("Frame", nil, body)
  H.bar:SetSize(COL_W, 29)
  local fill = type(H.bar.fill) == "table" and H.bar.fill or H.bar
  H.grow = CreateFrame("StatusBar", nil, fill)
  H.grow:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
  H.grow:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
  H.grow:SetStatusBarTexture(BAR_TEXTURE)
  H.grow:SetStatusBarColor(GOLD[1], GOLD[2], GOLD[3])
  H.grow:SetFrameLevel(fill:GetFrameLevel() + 1)
  local top = CreateFrame("Frame", nil, H.grow)
  top:SetAllPoints(H.bar)
  top:SetFrameLevel(H.grow:GetFrameLevel() + 1)
  H.barText = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  H.barText:SetPoint("CENTER", H.bar, "CENTER", 0, 0)
  -- outlined, so white stays readable on the gold fill (f7213)
  local file, size = H.barText:GetFont()
  if file then H.barText:SetFont(file, size, "OUTLINE") end
end

local function build(body)
  H.body = body
  local title = label(body, "GameFontHighlightLarge")
  title:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -4)
  title:SetText("Harvest")
  local sub = label(body)
  grey(sub)
  sub:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT, -26)
  sub:SetText("Your field grows while you are logged in, AFK too.")
  buildField(body)
  H.standLabel = label(body, "GameFontNormal")
  H.standLabel:SetText("Standing grain")
  H.rate = label(body)
  grey(H.rate)
  H.rate:SetWidth(160)
  H.rate:SetJustifyH("RIGHT")
  buildBar(body)
  H.harvest = button(body, "", 180)
  H.harvest:SetScript("OnClick", function() M.Safe(act, ns.Harvest) end)
  H.purseLabel = label(body, "GameFontNormal")
  H.purseLabel:SetText("Your purse")
  H.purseIcon = body:CreateTexture(nil, "ARTWORK")
  H.purseIcon:SetSize(16, 16)
  H.purseIcon:SetTexture(WHEAT)
  H.purse = label(body, "GameFontHighlight")
  H.lifetime = label(body)
  grey(H.lifetime)
  buildCaravan(body)
  local note = label(body)
  grey(note)
  note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", LEFT, 8)
  note:SetText("Grain is play money for Harvest and Kodo races: never gold, never traded.")
  buildRight(body)
  body:HookScript("OnSizeChanged", function() M.Safe(H.Layout) end)
  H.Layout()
end

ns.HarvestTab = {
  Build = build,
  -- Nothing is drawn unless the Harvest tab is on screen (the tick and RefreshPage call this while hidden too).
  Refresh = function()
    if H.body and ns.ShownGame and ns.ShownGame() == "harvest" then H.Draw() end
  end,
}
