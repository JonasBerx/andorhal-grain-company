-- GuildSyncExpeditions MapTab.lua: the map of Northern Lordaeron, ns.MapTab (0.19 plan, slice C2, Seams 5, 13, 15, 17, 18).
--   MapTab.Build(f, bar)   builds the map and its quest page inside f; bar takes the History button (History.lua)
--   MapTab.Refresh(f, opts) lays out for f's size and redraws; keeps the open zone and quest page over a hide.
--     opts (optional, never stored): fid picks that follower; region + ring shows that zone and rings that row's pin;
--     history opens the History list. A right-click on the zone, a pin or the camp pin goes back to the world map.
--   A row sent today reads Away while its run is out (RunOut), then Done; its quest page's gate line says which.
-- ns.W, ns.Regions, ns.BoardCore, ns.Followers, ns.TodayRows, ns.ChancesFor, ns.PowerOf and ns.Send are read at call
-- time, and so are the optional seams (CheckPack, SupplyChoices, IsReserve, StoryStep, StoryHeld, StoryData, CampStage,
-- ShowAnya, ShowPortrait, KitScore, GoTo, RunOut, LootCore, BookData, GearData): several load after this file.

local _, ns = ...
if not ns.M then return end
local M = ns.M

local BOX_W, BOX_H = 726, 508
local LAYER_W, LAYER_H, TILE = 1002, 668, 256
local CANVAS_W, CANVAS_H, CANVAS_X, CANVAS_Y = 786, 524, -30, -8
local CROP_X, CROP_Y, CROP_W, CROP_H = 630, 110, 270, 180
local K = CANVAS_W / CROP_W
local WORLD_MAP = 947
local MARK_PX, PIN_PX, CAMP_PX, LOCK_W, LOCK_H = 22, 30, 34, 12, 16
local MAX_TILES = 64
local PRELOAD_AFTER = 5 -- seconds after login
local TITLE_X, TITLE_Y, LINE2_Y, LINE3_Y, BACK_Y = 12, 42, 62, 76, 94
local PAGE_W, PAGE_H, PAGE_LEFT, PAGE_TOP, PAGE_PAD = 300, 456, 10, 42, 16
local ZOOM_S = 0.8
local INK, SUB_INK, LABEL_INK = "2b1a0a", "3b2610", "45200a"
local RED = "|cffff2020"
local INK_RED = "|cff9a1010" -- RED on parchment
local INK_GREEN, INK_BLUE = "|cff143c00", "|cff00306a" -- Uncommon and Rare on parchment
local WIN_BAND = "succ"
local SCRAP = { "Rusted salvage", "Iron salvage" } -- by tier
local BAR_W, BAR_H = 268, 12
local GEAR_Y, LINE_STEP = -298, 16 -- the page's Gear damaged row; a Deadly row's Killed for good pushes it down one line
local FINDS_Y = -70 -- the page's finds line, below Gear damaged
local DOT = " \194\183 "

local PARCHMENT = { 0.80, 0.70, 0.52, 1 }
local MARK_FILL = { 0.85, 0.72, 0.25, 1 }

local DANGER = { "Safe", "Risky", "Dangerous", "Deadly" }
local DANGER_RGB = { { 0.12, 1, 0.12 }, { 1, 0.82, 0 }, { 1, 0.5, 0.1 }, { 1, 0.13, 0.13 } }

-- Locked zones first. An open zone's hover area has the higher frame level (Build), so it wins where they overlap.
local ORDER = { "hillsbrad", "arathi", "westpl", "eastpl", "tirisfal", "silverpine" }

-- wr: the zone sheet's rectangle on the 1002 x 668 layer of map 947, by eye. land and lock: fractions of the sheet.
local REG = {
  hillsbrad = { map = 1424, wr = { 708.6, 213.2, 73, 48.6 }, land = { 0.08, 0.12, 0.9, 0.62 }, lock = { 0.5, 0.4 } },
  arathi = { map = 1417, wr = { 752.7, 225.3, 82.1, 54.7 }, land = { 0.08, 0.08, 0.95, 0.85 }, lock = { 0.5, 0.47 } },
  westpl = { map = 1422, wr = { 723.4, 145.5, 98, 65.4 }, land = { 0.1, 0.15, 0.9, 0.9 }, lock = { 0.55, 0.35 } },
  eastpl = { map = 1423, wr = { 785.1, 137.8, 91.9, 61.3 }, land = { 0.08, 0.15, 0.9, 0.85 }, lock = { 0.49, 0.5 } },
  tirisfal = { map = 1420, wr = { 663.7, 134.8, 103, 68.7 }, land = { 0.15, 0.2, 0.75, 0.8 },
    tiles = { 7958250, 7958254, 7958255, 7958256, 7958257, 7958258, 7958259, 7958260, 7958261, 7958251, 7958252, 7958253 } },
  silverpine = { map = 1421, wr = { 654.2, 184.3, 95.8, 63.8 }, land = { 0.38, 0.1, 0.68, 0.95 },
    tiles = { 8064925, 8064931, 8064933, 8064935, 8064936, 8064937, 8064939, 8064940, 8064942, 8064926, 8064929, 8064930 } },
}

local WORLD_TILES = { 8025428, 8025432, 8025433, 8025434, 8025435, 8025436, 8025437, 8025438, 8025439, 8025429, 8025430,
  8025431 }

local CAMP = { 0.611, 0.516 } -- Brill on the Tirisfal sheet

-- Fractions of the zone sheet. The mock's values, the rest by eye on the sheets.
local PLACES = {
  tirisfal = {
    ["Solliden Farmstead"] = { 0.299, 0.494 },
    ["Garren's Haunt"] = { 0.584, 0.359 },
    ["Deathknell"] = { 0.329, 0.659 },
    ["Crusader Outpost"] = { 0.75, 0.52 },
    ["Agamand Mills"] = { 0.469, 0.344 },
    ["Tirisfal Glades"] = { 0.616, 0.722 },
    ["Scarlet Watch Post"] = { 0.795, 0.255 },
    ["Stillwater Pond"] = { 0.496, 0.52 },
    ["The Bulwark"] = { 0.85, 0.7 },
    ["Cold Hearth Manor"] = { 0.534, 0.572 },
    ["Brightwater Lake"] = { 0.637, 0.46 },
    ["Balnir Farmstead"] = { 0.757, 0.606 },
    ["Nightmare Vale"] = { 0.513, 0.665 },
    ["Brill"] = { 0.535, 0.505 }, -- west of CAMP, which stands on the town: clear of the banner on both canvases
    ["Ruins of Lordaeron"] = { 0.615, 0.66 }, -- inside the gate; "Tirisfal Glades" is the capstone's own spot below it
  },
  silverpine = {
    ["Ambermill"] = { 0.667, 0.793 },
    ["Fenris Isle"] = { 0.659, 0.272 },
    ["Silverpine Forest"] = { 0.429, 0.677 },
    ["Olsen's Farthing"] = { 0.461, 0.546 },
    ["The Dead Field"] = { 0.447, 0.217 },
    ["South Tide's Run"] = { 0.4, 0.6 },
    ["Deep Elem Mine"] = { 0.571, 0.453 },
    ["Pyrewood Village"] = { 0.46, 0.72 },
    ["The Greymane Wall"] = { 0.454, 0.865 },
    ["The Skittering Dark"] = { 0.37, 0.15 },
    ["The Shining Strand"] = { 0.39, 0.33 },
    ["Malden's Orchard"] = { 0.575, 0.105 },
    ["The Decrepit Ferry"] = { 0.56, 0.29 },
    ["Beren's Peril"] = { 0.6, 0.72 },
    ["The Sepulcher"] = { 0.43, 0.41 },
    ["North Tide's Hollow"] = { 0.505, 0.135 },
    ["Shadowfang Keep"] = { 0.45, 0.68 },
  },
}

local LEGEND = { { "questnormal", "Expedition" }, { "quest-important-available", "Dangerous expedition" },
  { "dungeonskull", "Dungeon" }, { "questlegendary", "Story" }, { "hordewarfrontmapbanner", "Company Camp" },
  { "worldquest-tracker-lock", "Coming later" } }

local BANDS = { { "succ", 0.25, 0.56, 0.18 }, { "succw", 0.66, 0.70, 0.23 }, { "fail", 0.44, 0.44, 0.44 },
  { "failw", 0.79, 0.47, 0.17 }, { "dead", 0.69, 0.16, 0.13 }, { "perma", 0.29, 0.04, 0.04 } }

local STATE_COLOUR = { idle = "1e5b00", out = "6b4a00", rest = "7a3300" } -- the Barracks' state colours, darkened for parchment

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

local function regionInfo(id)
  for _, info in ipairs(ns.Regions.LIST) do
    if info.id == id then return info end
  end
  return {}
end

-- ---------- art ----------

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function positive(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if not finite(v) or v <= 0 then return false end
  end
  return true
end

local function numbers(list, least)
  if type(list) ~= "table" or #list < least then return nil end
  for _, v in ipairs(list) do
    if type(v) ~= "number" then return nil end
  end
  return list
end

local function layerOf(map)
  local answer = M.Compat.call("C_Map.GetMapArtLayers", map)
  local l = type(answer) == "table" and answer[1]
  if type(l) == "table" and positive(l.layerWidth, l.layerHeight, l.tileWidth, l.tileHeight)
    and math.ceil(l.layerWidth / l.tileWidth) * math.ceil(l.layerHeight / l.tileHeight) <= MAX_TILES then
    return l.layerWidth, l.layerHeight, l.tileWidth, l.tileHeight
  end
  return LAYER_W, LAYER_H, TILE, TILE
end

local function filesOf(map, count, fallback)
  return numbers(M.Compat.call("C_Map.GetMapArtLayerTextures", map, 1), count) or fallback
end

-- The zone's rectangle in layer px of the 1002 x 668 layer: the client's answer, else the by-eye one.
local function rectOf(ui, id)
  if ui.rects[id] then return ui.rects[id] end
  local minX, maxX, minY, maxY = M.Compat.call("C_Map.GetMapRectOnMap", REG[id].map, WORLD_MAP)
  local r = REG[id].wr
  if type(minX) == "number" and type(maxX) == "number" and type(minY) == "number" and type(maxY) == "number"
    and 0 <= minX and minX < maxX and maxX <= 1 and 0 <= minY and minY < maxY and maxY <= 1 then
    r = { minX * LAYER_W, minY * LAYER_H, (maxX - minX) * LAYER_W, (maxY - minY) * LAYER_H }
  end
  ui.rects[id] = r
  return r
end

-- One image, cut to the part of the layer the box shows. x, y, w, h: its used part in layer px; fileW, fileH: the file.
local function layTile(set, canvas, view, file, x, y, w, h, fileW, fileH)
  local x0, y0 = math.max(x, view.x0), math.max(y, view.y0)
  local x1, y1 = math.min(x + w, view.x1), math.min(y + h, view.y1)
  if x0 >= x1 or y0 >= y1 then return end
  set.n = set.n + 1
  local t = set[set.n]
  if not t then
    t = canvas:CreateTexture(nil, set.layer)
    set[set.n] = t
  end
  t:ClearAllPoints()
  t:SetPoint("TOPLEFT", canvas, "TOPLEFT", (x0 - view.ox) * view.k, -(y0 - view.oy) * view.k)
  t:SetSize((x1 - x0) * view.k, (y1 - y0) * view.k)
  t:SetTexture(file)
  t:SetTexCoord((x0 - x) / fileW, (x1 - x) / fileW, (y0 - y) / fileH, (y1 - y) / fileH)
  t:Show()
end

local function endTiles(set)
  for i = set.n + 1, #set do set[i]:Hide() end
end

local function layBase(set, canvas, view, files, lw, lh, tw, th, cols, rows)
  for r = 0, rows - 1 do
    for c = 0, cols - 1 do
      local file = files[r * cols + c + 1]
      if file then
        layTile(set, canvas, view, file, c * tw, r * th, math.min(tw, lw - c * tw), math.min(th, lh - r * th), tw, th)
      end
    end
  end
end

local function viewOf(k, ox, oy)
  return { k = k, ox = ox, oy = oy, x0 = ox - CANVAS_X / k, y0 = oy - CANVAS_Y / k,
    x1 = ox + (BOX_W - CANVAS_X) / k, y1 = oy + (BOX_H - CANVAS_Y) / k }
end

local function drawWorldArt(ui)
  local lw, lh, tw, th = layerOf(WORLD_MAP)
  local cols, rows = math.ceil(lw / tw), math.ceil(lh / th)
  local sx, sy = lw / LAYER_W, lh / LAYER_H
  local view = viewOf(CANVAS_W / (CROP_W * sx), CROP_X * sx, CROP_Y * sy)
  local set = ui.worldTiles
  set.n = 0
  layBase(set, ui.world, view, filesOf(WORLD_MAP, cols * rows, WORLD_TILES), lw, lh, tw, th, cols, rows)
  endTiles(set)
end

-- A list of { textureWidth, textureHeight, offsetX, offsetY, fileDataIDs }, or nil when any entry is not of that shape.
local function overlaysOf(map)
  local answer = M.Compat.call("C_MapExplorationInfo.GetExploredMapTextures", map)
  if type(answer) ~= "table" then return nil end
  for _, o in ipairs(answer) do
    if type(o) ~= "table" or not positive(o.textureWidth, o.textureHeight)
      or not finite(o.offsetX) or not finite(o.offsetY) or not numbers(o.fileDataIDs, 1) then
      return nil
    end
  end
  return answer
end

-- An overlay's last column and row are smaller files, drawn 1:1 from their top left: the used size up to a power of two.
local function fileSize(used)
  local size = 16
  while size < used do size = size * 2 end
  return size
end

local function layOverlay(set, canvas, view, o, tw, th)
  local cols = math.ceil(o.textureWidth / tw)
  for i, file in ipairs(o.fileDataIDs) do
    local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
    local w, h = math.min(tw, o.textureWidth - c * tw), math.min(th, o.textureHeight - r * th)
    layTile(set, canvas, view, file, o.offsetX + c * tw, o.offsetY + r * th, w, h, fileSize(w), fileSize(h))
  end
end

local function drawZoneArt(ui, id)
  local reg = REG[id]
  local lw, lh, tw, th = layerOf(reg.map)
  local cols, rows = math.ceil(lw / tw), math.ceil(lh / th)
  local view = viewOf(CANVAS_W / lw, 0, 0)
  local base, over = ui.zoneTiles, ui.overTiles
  base.n, over.n = 0, 0
  layBase(base, ui.zone, view, filesOf(reg.map, cols * rows, reg.tiles), lw, lh, tw, th, cols, rows)
  for _, o in ipairs(overlaysOf(reg.map) or {}) do layOverlay(over, ui.zone, view, o, tw, th) end
  endTiles(base)
  endTiles(over)
  ui.zoneArt = id
end

-- ---------- who and what ----------

local function isReady(f)
  if f.state == "idle" then return true end
  return f.state == "rest" and not (f.untilT and f.untilT > (ns.Now() or 0))
end

local function chipsNow()
  local out = {}
  local cap = ns.FollowerData and ns.FollowerData.CAP_ALL
  for _, f in ipairs(ns.Followers()) do
    local reserve = f.reserve == true
    if ns.IsReserve then reserve = ns.IsReserve(f.id) end
    if not reserve and f.state ~= "dead" then out[#out + 1] = f end
    if cap and #out >= cap then break end
  end
  return out
end

-- The member's choice while it is still a chip, else the first ready follower, else the first chip.
local function refreshWho(ui)
  ui.chips = chipsNow()
  ui.person = nil
  for _, f in ipairs(ui.chips) do
    if f.id == ui.pick then ui.person = f end
  end
  if not ui.person then
    for _, f in ipairs(ui.chips) do
      if isReady(f) then
        ui.person = f
        break
      end
    end
  end
  ui.person = ui.person or ui.chips[1]
end

local function kitOf(fid)
  return ns.KitScore and ns.KitScore(fid) or 0
end

local function gatedFor(who, row)
  if not who then return false end
  return not ns.BoardCore.CanSend(who.level, kitOf(who.id), row)
end

local function needLevel(row)
  if row.gate then return math.max(row.gate.level, row.level - 2) end
  return math.max(1, row.level - 2)
end

-- The open story step when it is the capstone step of this capstone row's region, else nil.
local function capstoneStep(row)
  local s = row.capstone and ns.StoryData and ns.StoryStep and ns.StoryStep()
  if type(s) ~= "table" then return nil end
  for _, ch in ipairs(ns.StoryData) do
    if ch.name == s.chapter then
      local open = ch.region == row.region and ch.steps[s.step]
      return open and open.capstone and s or nil
    end
  end
  return nil
end

-- Title, text, place, chapter and step of a row: StoryStep's for a story row and for a capstone row at its capstone
-- step, RowText's for a field it leaves out. Chapter and step come as a pair or not at all.
local function textOf(row)
  local title, text, place = ns.W.RowText(row)
  local s = row.story and ns.StoryStep and ns.StoryStep() or capstoneStep(row)
  if type(s) ~= "table" then return title, text, place end
  local chapter, step = s.chapter, s.step
  if chapter == nil or step == nil then chapter, step = nil, nil end
  return s.title or title, s.text or text, s.place or place, chapter, step
end

local function kindLine(row)
  local W = ns.W
  return "Level " .. row.level .. " " .. ((row.capstone and W.Name.capstone or W.Name[row.kind]) or "")
end

local function findsLine(row)
  local W = ns.W
  if row.capstone then return "May also find " .. W.Quality(2) .. " or " .. W.Quality(3) .. " gear." end
  return "May also find " .. W.Quality(1) .. " or " .. W.Quality(2) .. " gear."
end

-- The quest page's fuller line; findsLine stays the tooltip's.
local function pageFindsLine(row)
  local W = ns.W
  local green = INK_GREEN .. W.Quality(2) .. "|r"
  if not row.capstone then
    return "May also find " .. W.Quality(1) .. " or " .. green .. " gear, supplies, a relic, a new recruit."
  end
  local pieces = ""
  for _, set in ipairs(ns.BookData and ns.BookData.sets or {}) do
    if set.region == row.region then pieces = "pieces of " .. set.name .. ", " end
  end
  return "May also find " .. green .. " or " .. INK_BLUE .. W.Quality(3) .. "|r gear, " .. pieces .. "supplies, a relic."
end

local function isGreedy(who)
  for _, id in ipairs(who and who.traits or {}) do
    if id == "greedy" then return true end
  end
  return false
end

-- The names of the pieces a story row's step grants, from the static data (ns.StoryStep carries no gear).
local function stepPieces(row)
  local c, s = string.match(row.story or "", "^(%d+)%.(%d+)$")
  local ch = c and ns.StoryData and ns.StoryData[tonumber(c)]
  local step = ch and ch.steps and ch.steps[tonumber(s)]
  local names = {}
  for _, code in ipairs(step and step.gear or {}) do
    local piece = ns.GearData and ns.GearData.Row(code)
    if piece then names[#names + 1] = piece.name end
  end
  return names
end

-- What a win pays, read the way ns.ApplyRewards reads it; nil when LootCore is absent. The second answer is true when
-- the line names gear, which makes it run to two lines.
local function rewardsLine(who, row)
  local LC = ns.LootCore
  if not LC then return nil end
  local parts = {}
  if who and who.level < ns.FollowerData.MAX_LEVEL then
    local xp = LC.XP(row.hours, row.danger, WIN_BAND, who.level, row.level)
    if xp > 0 then parts[1] = xp .. " XP" end
  end
  parts[#parts + 1] = LC.Grain(row.hours, row.danger, isGreedy(who)) .. " grain"
  parts[#parts + 1] = LC.Salvage(row.hours, WIN_BAND) .. " " .. ns.W.Name[SCRAP[LC.Tier(row.level)]]
  local pieces = stepPieces(row)
  for _, name in ipairs(pieces) do parts[#parts + 1] = name end
  return table.concat(parts, ", "), #pieces > 0
end

local function gateLines(who, row)
  local W = ns.W
  local need = needLevel(row)
  local lines = { W.Requires(need, who.level >= need) }
  if row.gate then
    local line = W.Name["kit score"] .. " " .. row.gate.kit
    if kitOf(who.id) < row.gate.kit then line = RED .. line .. "|r" end
    lines[2] = line
  end
  return lines
end

-- A row sent today (row.taken) is out while ns.RunOut says so; without that seam it counts as out.
local function isOut(row)
  return not ns.RunOut or ns.RunOut(row.id) == true
end

local function atlasOf(row)
  if row.story then return "questlegendary" end
  if row.capstone then return "dungeonskull" end
  if row.danger <= 2 then return "questnormal" end
  return "quest-important-available"
end

local function refuse(why, row)
  if why == "demo" then return end -- ns.Inert has said its line
  local W = ns.W
  if why == "level" then
    ns.Say(W.Requires(needLevel(row), true) .. ".")
  elseif why == "kit" and row.gate then
    ns.Say("Requires " .. W.Name["kit score"] .. " " .. row.gate.kit .. ".")
  else
    ns.Say("Cannot send this expedition now.")
  end
end

-- ---------- tooltips ----------

local function hideTip()
  local tip = M.Compat.Tooltip()
  if tip then tip:Hide() end
end

local function showRowTip(ui, owner, row, hint)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  local W = ns.W
  local who = ui.person
  local title, _, place, chapter, step = textOf(row)
  local d = DANGER_RGB[row.danger]
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(title)
  tip:AddLine(place, 1, 1, 1)
  tip:AddDoubleLine(kindLine(row), W.Time(row.hours * 3600), 1, 1, 1, 1, 1, 1)
  tip:AddLine(DANGER[row.danger], d[1], d[2], d[3])
  if chapter then tip:AddLine(chapter .. " (" .. step .. "/4)", 1, 0.82, 0) end
  if gatedFor(who, row) then
    for _, line in ipairs(gateLines(who, row)) do tip:AddLine(line, 1, 1, 1) end
  elseif who and not row.taken then
    local c = ns.ChancesFor(who.id, row)
    if c then tip:AddLine(who.name .. ": " .. c.success .. "% chance of success", 1, 0.82, 0) end
  end
  if row.taken then tip:AddLine(isOut(row) and W.Name.out or W.Taken.tip, 1, 0.82, 0) end
  tip:AddLine(findsLine(row), 1, 1, 1)
  if hint then tip:AddLine("Click to zoom in", 0.1, 1, 0.1) end
  tip:Show()
end

local function showZoneTip(ui, owner, id)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  local info = regionInfo(id)
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText(info.name)
  if REG[id].lock then
    tip:AddLine("Coming later", 0.62, 0.62, 0.62)
  else
    local n = 0
    for _, row in ipairs(ui.rows) do
      if row.region == id then n = n + 1 end
    end
    tip:AddLine("Level " .. info.lo .. "-" .. info.hi, 1, 1, 1)
    tip:AddLine(n .. (n == 1 and " expedition" or " expeditions"), 1, 0.82, 0)
    tip:AddLine("Click to zoom in", 0.1, 1, 0.1)
  end
  tip:Show()
end

local function showCampTip(owner)
  local tip = M.Compat.Tooltip()
  if not tip then return end
  tip:SetOwner(owner, "ANCHOR_RIGHT")
  tip:SetText("Company Camp")
  tip:AddLine("Brill, Tirisfal Glades", 1, 1, 1)
  tip:Show()
end

-- ---------- drawing ----------

local function worldPoint(ui, id, fx, fy)
  local r = rectOf(ui, id)
  return (r[1] + r[3] * fx - CROP_X) * K, (r[2] + r[4] * fy - CROP_Y) * K
end

-- An outline for light text that stands straight on the map art; the font keeps its face and size.
local function outline(fs)
  local file, size = fs:GetFont()
  if file then fs:SetFont(file, size, "OUTLINE") end
end

local function putCentre(frame, canvas, x, y)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
end

local function newMark(parent, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  b:SetFrameLevel(parent:GetFrameLevel() + 3)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints(b)
  b.lock = b:CreateTexture(nil, "OVERLAY")
  b.lock:SetSize(LOCK_W, LOCK_H)
  b.lock:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
  M.Kit.Atlas(b.lock, "worldquest-tracker-lock", MARK_FILL)
  b.lock:Hide()
  b:SetScript("OnLeave", hideTip)
  return b
end

local function fillMark(mark, row, who)
  M.Kit.Atlas(mark.icon, atlasOf(row), MARK_FILL)
  mark.lock:SetShown(gatedFor(who, row))
  mark.row = row
end

-- Boxes are { left, top, right, bottom } in sheet px (y down). A pin with its label hanging below takes x -BOX_SIDE..
-- BOX_SIDE and y -BOX_SIDE..BOX_BELOW px around its centre, with the gap it keeps as a fifth field. One rule: a spot clashes
-- with a taken box when its row box comes closer to it than that box's gap; row boxes keep GAP px
-- (6 px, so neighbouring pins stay apart for an unsteady pointer and at the small window scale); SPOT_X/SPOT_Y are the
-- steps that just clear a row box. Answers (as fractions) the asked spot itself when that is free, else the first free
-- spot in a fixed order of steps outward, at most RINGS rings and NEAR px (100) from the asked spot, inside the sheet,
-- and with its centre on the zone's land when the asked spot is on the land (a place off the land, like Scarlet Watch
-- Post, only stays inside the sheet). With no free spot in that bound the pin stays on the asked spot and may overlap.
local BOX_SIDE, BOX_BELOW, GAP = PIN_PX / 2, 27, 6
local SPOT_X, SPOT_Y = 2 * BOX_SIDE + GAP, BOX_SIDE + BOX_BELOW + GAP
local RINGS, NEAR = 2, 100
local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }
-- The Company Camp pin and its "Company Camp" label under it (12 characters at 7 px, the width the sim measures and
-- wider than the game font draws it), reserved on the Tirisfal sheet before any row with no gap, so Brill and Cold Hearth
-- Manor, which stand just west of it by design (PLACES), keep their spots.
local CAMP_LABEL_W, CAMP_LABEL_H = 84, 14
local function rowBox(x, y) return { x - BOX_SIDE, y - BOX_SIDE, x + BOX_SIDE, y + BOX_BELOW, GAP } end
local function campBox()
  local x, y, half = CANVAS_W * CAMP[1], CANVAS_H * CAMP[2], math.max(CAMP_PX, CAMP_LABEL_W) / 2
  return { x - half, y - CAMP_PX / 2, x + half, y + CAMP_PX / 2 + CAMP_LABEL_H, 0 }
end
local function clearSpot(fx, fy, taken, land)
  local x0, y0 = CANVAS_W * fx, CANVAS_H * fy
  local keepLand = fx >= land[1] and fx <= land[3] and fy >= land[2] and fy <= land[4]
  local function free(x, y)
    if x < BOX_SIDE or x > CANVAS_W - BOX_SIDE or y < BOX_SIDE or y > CANVAS_H - BOX_BELOW then return false end
    if keepLand and (x < CANVAS_W * land[1] or x > CANVAS_W * land[3] or y < CANVAS_H * land[2] or y > CANVAS_H * land[4]) then
      return false
    end
    local b = rowBox(x, y)
    for _, t in ipairs(taken) do
      local g = t[5]
      if b[1] < t[3] + g and t[1] < b[3] + g and b[2] < t[4] + g and t[2] < b[4] + g then return false end
    end
    return true
  end
  local function try(i, j)
    local dx, dy = i * SPOT_X, j * SPOT_Y
    if dx * dx + dy * dy <= NEAR * NEAR and free(x0 + dx, y0 + dy) then return (x0 + dx) / CANVAS_W, (y0 + dy) / CANVAS_H end
  end
  if free(x0, y0) then return fx, fy end
  for k = 1, RINGS do
    -- a ring's eight straight and diagonal steps first, then the steps between them (from ring 2 on)
    for _, s in ipairs(STEPS) do
      local x, y = try(s[1] * k, s[2] * k)
      if x then return x, y end
    end
    for j = -k, k do
      for i = -k, k do
        local ai, aj = math.abs(i), math.abs(j)
        if math.max(ai, aj) == k and ai ~= aj and ai ~= 0 and aj ~= 0 then
          local x, y = try(i, j)
          if x then return x, y end
        end
      end
    end
  end
  return fx, fy
end

-- Where each row sits on its sheet: its known place, or an unknown place spread over the land. The camp's box is taken
-- first on Tirisfal (the banner at Agamand Mills is not reserved: it marks the Mills, and a Mills pin stands on it by
-- design), then each zone's capstone, so the dungeon pin always stands on its own spot, then the other rows in their
-- order; a pin whose spot clashes with an earlier box steps aside (clearSpot), so the same rows always give the same spots.
local function spotsOf(rows)
  local out, taken, unknown, base = {}, { tirisfal = { campBox() } }, {}, {}
  for _, row in ipairs(rows) do
    local _, _, place = textOf(row)
    local at = PLACES[row.region] and PLACES[row.region][place]
    if at then
      base[row] = { at[1], at[2] }
    else
      local land = REG[row.region].land
      unknown[row.region] = (unknown[row.region] or 0) + 1
      local n = unknown[row.region]
      base[row] = { land[1] + (land[3] - land[1]) * ((n * 0.618) % 1), land[2] + (land[4] - land[2]) * ((n * 0.382) % 1) }
    end
  end
  for pass = 1, 2 do
    for _, row in ipairs(rows) do
      if (pass == 1) == (row.capstone and true or false) then
        taken[row.region] = taken[row.region] or {}
        local fx, fy = clearSpot(base[row][1], base[row][2], taken[row.region], REG[row.region].land)
        table.insert(taken[row.region], rowBox(CANVAS_W * fx, CANVAS_H * fy))
        out[row.id] = { fx, fy }
      end
    end
  end
  return out
end

local function drawMarks(ui, spots)
  local marks = {}
  for id, lock in pairs(ui.locks) do marks[id] = lock end
  marks.camp = ui.camp
  local n = 0
  for _, row in ipairs(ui.rows) do
    n = n + 1
    local m = ui.markPool[n]
    if not m then
      m = newMark(ui.world, MARK_PX)
      m:SetScript("OnEnter", function(self) M.Safe(showRowTip, ui, self, self.row, true) end)
      m:SetScript("OnClick", function(self) M.Safe(ui.zoomTo, self.row.region) end)
      ui.markPool[n] = m
    end
    fillMark(m, row, ui.person)
    local spot = spots[row.id]
    putCentre(m, ui.world, worldPoint(ui, row.region, spot[1], spot[2]))
    m:Show()
    marks[row.id] = m
  end
  for i = n + 1, #ui.markPool do ui.markPool[i]:Hide() end
  ui.marks = marks
  for id, lock in pairs(ui.locks) do
    local at = REG[id].lock
    putCentre(lock, ui.world, worldPoint(ui, id, at[1], at[2]))
  end
  putCentre(ui.camp, ui.world, worldPoint(ui, "tirisfal", CAMP[1], CAMP[2]))
  for id, hit in pairs(ui.hits) do
    local land = REG[id].land
    local x0, y0 = worldPoint(ui, id, land[1], land[2])
    local x1, y1 = worldPoint(ui, id, land[3], land[4])
    hit:ClearAllPoints()
    hit:SetPoint("TOPLEFT", ui.world, "TOPLEFT", x0, -y0)
    hit:SetSize(x1 - x0, y1 - y0)
  end
end

local function pinLabel(row, who)
  if row.taken then return isOut(row) and ns.W.Name.out or ns.W.Taken.pin end
  if not who or gatedFor(who, row) then return "" end
  local c = ns.ChancesFor(who.id, row)
  return c and (c.success .. "%") or ""
end

local function drawPins(ui, spots)
  local pins = {}
  local n = 0
  for _, row in ipairs(ui.rows) do
    if row.region == ui.current then
      n = n + 1
      local p = ui.pinPool[n]
      if not p then
        p = newMark(ui.zone, PIN_PX)
        p.ring = p:CreateTexture(nil, "BORDER")
        p.ring:SetPoint("CENTER", p, "CENTER", 0, 0)
        p.ring:SetSize(PIN_PX + 14, PIN_PX + 14)
        M.Kit.Atlas(p.ring, "map_faction_ring")
        p.label = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        outline(p.label)
        p.label:SetPoint("TOP", p, "BOTTOM", 0, 2)
        p:SetScript("OnEnter", function(self) M.Safe(showRowTip, ui, self, self.row, false) end)
        p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        p:SetScript("OnClick", function(self, button)
          if button == "RightButton" then M.Safe(ui.zoomOut) else M.Safe(ui.openPage, self.row) end
        end)
        ui.pinPool[n] = p
      end
      fillMark(p, row, ui.person)
      p.label:SetText(pinLabel(row, ui.person))
      p.ring:SetShown(ui.open ~= nil and ui.open.row.id == row.id or ui.ring == row.id)
      local spot = spots[row.id]
      putCentre(p, ui.zone, CANVAS_W * spot[1], CANVAS_H * spot[2])
      p:Show()
      pins[row.id] = p
    end
  end
  for i = n + 1, #ui.pinPool do ui.pinPool[i]:Hide() end
  ui.pins = pins
end

local function drawTitle(ui)
  local W = ns.W
  ui.level:Hide()
  ui.who:Hide()
  ui.timer:Hide()
  ui.held:Hide()
  if not ui.current then
    ui.title:SetText("Northern Lordaeron")
    if ns.StoryHeld and ns.StoryHeld() then ui.held:Show() end
    local left = ns.NextRefresh()
    if left then
      ui.timer:SetText("New expeditions in " .. W.Time(left))
      ui.timer:Show()
    end
    return
  end
  local info = regionInfo(ui.current)
  ui.title:SetText(info.name)
  ui.level:SetText("Level " .. info.lo .. "-" .. info.hi)
  ui.level:Show()
  if ui.person then
    ui.who:SetText("Chances shown for " .. ui.person.name)
    ui.who:Show()
  end
end

local function statLine(who, row)
  return "Level " .. who.level .. " " .. who.race .. " " .. who.class .. ", Power " .. ns.PowerOf(who.id, row)
end

local function packedLine(fid)
  if not ns.SupplyChoices then return nil end
  local names = {}
  for _, s in ipairs(ns.SupplyChoices(fid) or {}) do
    if s.packed then names[#names + 1] = s.name end
  end
  if #names == 0 then return nil end
  return "Supplies: " .. table.concat(names, ", ")
end

local function statusOf(f)
  local W = ns.W
  if isReady(f) then return W.Name.idle, STATE_COLOUR.idle end
  return W.Name[f.state] or "", STATE_COLOUR[f.state] or SUB_INK
end

local function drawChips(ui)
  local page = ui.page
  local n = #ui.chips
  local w = math.min(86, math.floor((BAR_W - (n - 1) * 4) / math.max(n, 1)))
  for i, f in ipairs(ui.chips) do
    local chip = page.chips[i]
    if not chip then
      chip = CreateFrame("Button", nil, page)
      chip:SetHeight(44)
      chip.sel = chip:CreateTexture(nil, "BACKGROUND")
      chip.sel:SetAllPoints(chip)
      chip.sel:SetColorTexture(1, 0.82, 0, 0.3)
      chip.face = chip:CreateTexture(nil, "ARTWORK")
      chip.face:SetSize(28, 28)
      chip.face:SetPoint("LEFT", chip, "LEFT", 2, 0)
      if chip.CreateMaskTexture and chip.face.AddMaskTexture then
        pcall(function()
          local mask = chip:CreateMaskTexture()
          mask:SetAllPoints(chip.face)
          mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
          chip.face:AddMaskTexture(mask)
        end)
      end
      chip.nameText = chip:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
      chip.nameText:SetPoint("TOPLEFT", chip, "TOPLEFT", 32, -6)
      chip.nameText:SetJustifyH("LEFT")
      chip.nameText:SetTextColor(rgb(INK))
      chip.status = chip:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
      chip.status:SetPoint("TOPLEFT", chip, "TOPLEFT", 32, -22)
      chip.status:SetJustifyH("LEFT")
      chip:SetScript("OnClick", function(self) M.Safe(ui.chooseWho, self.fid) end)
      page.chips[i] = chip
    end
    chip.fid = f.id
    chip:ClearAllPoints()
    chip:SetPoint("TOPLEFT", page, "TOPLEFT", PAGE_PAD + (i - 1) * (w + 4), -164)
    chip:SetWidth(w)
    chip.nameText:SetWidth(w - 34)
    chip.status:SetWidth(w - 34)
    chip.nameText:SetText(f.name)
    local text, colour = statusOf(f)
    chip.status:SetText(text)
    chip.status:SetTextColor(rgb(colour))
    chip.sel:SetShown(f.id == ui.person.id)
    if ns.ShowPortrait then ns.ShowPortrait(chip.face, f.id) end
    chip:Show()
  end
  for i = n + 1, #page.chips do page.chips[i]:Hide() end
end

local function drawBars(page, chance)
  local x = 0
  for i, band in ipairs(BANDS) do
    local share = chance.bands and chance.bands[band[1]] or 0
    local t = page.bands[i]
    if share > 0 then
      local w = BAR_W * share / 100
      t:ClearAllPoints()
      t:SetPoint("LEFT", page.bar, "LEFT", x, 0)
      t:SetSize(w, BAR_H)
      t:Show()
      x = x + w
    else
      t:Hide()
    end
  end
  page.bar:Show()
end

local function anchorAt(fs, target, x, y)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", target, "TOPLEFT", x, y)
end

local function fillChance(page, row, chance)
  page.chance:SetText(chance.success .. "% chance of success")
  page.chance:Show()
  drawBars(page, chance)
  page.wounded:SetText("Wounded " .. chance.wound .. "%")
  page.killed:SetText("Killed " .. chance.death .. "%")
  page.damaged:SetText("Gear damaged " .. chance.broken .. "%")
  page.lost:SetText("Gear lost " .. chance.lost .. "%")
  for _, fs in ipairs(page.outcomes) do fs:Show() end
  local deadly = row.danger == 4
  if deadly then page.perma:SetText("Killed for good " .. chance.perma .. "%") end
  page.perma:SetShown(deadly)
  anchorAt(page.damaged, page, PAGE_PAD, deadly and GEAR_Y - LINE_STEP or GEAR_Y)
end

local function hideChance(page)
  page.chance:Hide()
  page.bar:Hide()
  for _, fs in ipairs(page.outcomes) do fs:Hide() end
  page.perma:Hide()
  anchorAt(page.damaged, page, PAGE_PAD, GEAR_Y)
end

local function fillPage(ui)
  local W = ns.W
  local page, row, who = ui.page, ui.open.row, ui.person
  local title, text, place, chapter, step = textOf(row)
  page.title:SetText(title)
  page.text:SetText(text)
  page.place:SetText(chapter and (place .. ", " .. chapter .. " (" .. step .. "/4)") or place)
  page.detail:SetText(kindLine(row) .. DOT .. DANGER[row.danger] .. DOT .. W.Time(row.hours * 3600))
  if ns.ShowAnya then ns.ShowAnya(page.anya) end
  drawChips(ui)

  page.stat:SetText(who and statLine(who, row) or "")
  local supplies = who and packedLine(who.id)
  page.supplies:SetText(supplies or "")
  page.supplies:SetShown(supplies ~= nil)

  local gated = gatedFor(who, row)
  if gated or row.taken then
    local lines = gated and gateLines(who, row) or {}
    if row.taken then lines[#lines + 1] = isOut(row) and W.Taken.out or W.Taken.done end
    page.gate:SetText((table.concat(lines, "\n"):gsub(RED, INK_RED)))
    page.gate:Show()
  else
    page.gate:Hide()
  end
  local chance = who and not gated and not row.taken and ns.ChancesFor(who.id, row)
  if chance then fillChance(page, row, chance) else hideChance(page) end

  page.dropped:SetText("A packed supply is no longer in " .. W.Name["Company bag"] .. ".")
  page.dropped:SetShown(who ~= nil and ui.open.checked[who.id] == true)
  local rewards, tall = rewardsLine(who, row)
  page.rewards:SetText(rewards or "")
  page.rewards:SetShown(rewards ~= nil)
  page.rewardsLabel:SetShown(rewards ~= nil)
  page.finds:SetText(pageFindsLine(row))
  anchorAt(page.finds, page.damaged, 0, tall and FINDS_Y - LINE_STEP or FINDS_Y)
  page.send:SetEnabled(who ~= nil and isReady(who) and not row.taken and not gated)
  page.barracks:SetShown(who ~= nil and ns.GoTo ~= nil)
end

-- The title block and World map stand beside an open page, which covers their usual place.
local function placeHud(ui)
  local x = ui.open and PAGE_LEFT + PAGE_W + 12 or TITLE_X
  ui.hud:ClearAllPoints()
  ui.hud:SetPoint("TOPLEFT", ui.box, "TOPLEFT", x, 0)
  ui.back:ClearAllPoints()
  ui.back:SetPoint("TOPLEFT", ui.box, "TOPLEFT", x, -BACK_Y)
end

local function closePage(ui)
  ui.open = nil
  ui.page:Hide()
  placeHud(ui)
end

local function findRow(rows, id)
  for _, row in ipairs(rows) do
    if row.id == id then return row end
  end
  return nil
end

local function checkPack(ui, fid)
  if fid == nil or ui.open.checked[fid] ~= nil then return end
  local gone = ns.CheckPack and ns.CheckPack(fid)
  ui.open.checked[fid] = type(gone) == "table" and next(gone) ~= nil
end

-- One bad row must not abort a redraw: it never reaches layout.
local function soundRows(rows)
  local out = {}
  for _, row in ipairs(rows) do
    local gate = row.gate
    if type(row.id) == "string" and type(row.hours) == "number"
      and (gate == nil or (type(gate) == "table" and type(gate.level) == "number" and type(gate.kit) == "number")) then
      out[#out + 1] = row
    end
  end
  return out
end

-- The History list takes the map's place while it is open: nothing of the map stays behind its text.
local function showLayers(ui)
  local map = not ui.covered
  ui.world:SetShown(map and ui.current == nil)
  ui.zone:SetShown(map and ui.current ~= nil)
  ui.back:SetShown(map and ui.current ~= nil)
  ui.hud:SetShown(map)
  ui.legend:SetShown(map)
  ui.page:SetShown(map and ui.open ~= nil)
end

local function draw(ui)
  ui.rows = soundRows(ns.TodayRows())
  refreshWho(ui)
  -- An arrival ring lasts while a run from its row is out (ns.RunOut); without that seam, until a zoom or a page opens.
  if ui.ring and ns.RunOut and not ns.RunOut(ui.ring) then ui.ring = nil end
  if ui.open then
    local row = findRow(ui.rows, ui.open.row.id)
    local fid = ui.person and ui.person.id
    if row and fid == ui.open.fid then ui.open.row = row else closePage(ui) end
  end
  showLayers(ui)
  if not ui.worldDrawn then
    drawWorldArt(ui)
    ui.worldDrawn = true
  end
  if ui.current and ui.zoneArt ~= ui.current then drawZoneArt(ui, ui.current) end
  local spots = spotsOf(ui.rows)
  drawMarks(ui, spots)
  drawPins(ui, spots)
  ui.banner:SetShown(ui.current == "tirisfal" and ns.CampStage ~= nil and (ns.CampStage() or 0) >= 2)
  ui.campPin:SetShown(ui.current == "tirisfal")
  drawTitle(ui)
  if ui.open then fillPage(ui) end
end

-- Decoration only: the end state is already set and this may be missing on a client.
local function zoomFx(ui, id)
  if ui.fx == nil then
    ui.fx = ui.zone:CreateAnimationGroup() or false
    if ui.fx then
      local fade = ui.fx:CreateAnimation("Alpha")
      fade:SetFromAlpha(0)
      fade:SetToAlpha(1)
      fade:SetDuration(ZOOM_S)
      ui.fxScale = ui.fx:CreateAnimation("Scale")
      ui.fxScale:SetDuration(ZOOM_S)
      ui.fxScale:SetScaleTo(1, 1)
    end
  end
  if not ui.fx then return end
  local r = rectOf(ui, id)
  local x, y, w, h = (r[1] - CROP_X) * K, (r[2] - CROP_Y) * K, r[3] * K, r[4] * K
  local sx, sy = w / CANVAS_W, h / CANVAS_H
  ui.fxScale:SetScaleFrom(sx, sy)
  ui.fxScale:SetOrigin("TOPLEFT", x / (1 - sx), -y / (1 - sy))
  ui.fx:Play()
end

local function zoomTo(ui, id)
  ui.current = id
  ui.ring = nil
  closePage(ui)
  draw(ui)
  M.Safe(zoomFx, ui, id)
end

local function zoomOut(ui)
  ui.current = nil
  ui.ring = nil
  closePage(ui)
  draw(ui)
  if ns.FadeIn then M.Safe(ns.FadeIn, ui.world) end
end

local function openPage(ui, row)
  refreshWho(ui)
  local fid = ui.person and ui.person.id
  ui.pick = fid
  ui.ring = nil
  ui.open = { row = row, fid = fid, checked = {} }
  ui.page:Show()
  if ns.FadeIn then M.Safe(ns.FadeIn, ui.page) end
  placeHud(ui)
  checkPack(ui, fid)
  draw(ui)
end

local function chooseWho(ui, fid)
  ui.pick = fid
  if ui.open then
    ui.open.fid = fid
    checkPack(ui, fid)
  end
  draw(ui)
end

local function place(f)
  local ui = f.map
  local width, height = f:GetWidth(), f:GetHeight()
  if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then return end
  ui.box:SetScale(math.min(width / BOX_W, height / BOX_H, 1))
end

local MapTab = {}
ns.MapTab = MapTab

-- Holds every sheet the map can show on small textures, so the client keeps them loaded and opening a zone does not
-- wait on the disk. Once per session; nothing a player can see.
local preloaded
function MapTab.Preload()
  if preloaded then return preloaded end
  local holder = CreateFrame("Frame", nil, UIParent)
  holder:SetSize(1, 1)
  holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
  holder:SetAlpha(0.01)
  local seen = {}
  local function hold(file)
    if seen[file] then return end
    seen[file] = true
    local t = holder:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(holder)
    t:SetTexture(file)
  end
  local function holdLayer(map, fallback)
    local lw, lh, tw, th = layerOf(map)
    for _, file in ipairs(filesOf(map, math.ceil(lw / tw) * math.ceil(lh / th), fallback)) do hold(file) end
  end
  holdLayer(WORLD_MAP, WORLD_TILES)
  for _, reg in pairs(REG) do
    if reg.tiles then
      holdLayer(reg.map, reg.tiles)
      for _, o in ipairs(overlaysOf(reg.map) or {}) do
        for _, file in ipairs(o.fileDataIDs) do hold(file) end
      end
    end
  end
  preloaded = holder
  return holder
end

ns.LoginHooks[#ns.LoginHooks + 1] = function()
  M.After(PRELOAD_AFTER, function() M.Safe(MapTab.Preload) end)
end

-- An arrival from another place: chooseWho and zoomTo without their draw. Chips are made fresh before a fid is checked.
local function arrive(ui, opts)
  if opts.fid ~= nil then
    refreshWho(ui)
    for _, f in ipairs(ui.chips) do
      if f.id == opts.fid then
        ui.pick = f.id
        if ui.open then
          ui.open.fid = f.id
          checkPack(ui, f.id)
        end
      end
    end
  end
  local reg = opts.region ~= nil and REG[opts.region]
  if reg and not reg.lock then
    ui.current = opts.region
    closePage(ui)
    ui.ring = opts.ring
    return opts.region
  end
end

function MapTab.Refresh(f, opts)
  if type(opts) ~= "table" then opts = nil end
  local ui = f.map
  place(f)
  local region = opts and arrive(ui, opts)
  draw(ui)
  if ns.History then M.Safe(ns.History.Refresh) end
  if region then M.Safe(zoomFx, ui, region) end
  if opts and opts.history and ns.History then M.Safe(ns.History.Open) end
end

local function buildLegend(box)
  local legend = CreateFrame("Frame", nil, box)
  legend:SetSize(150, 16 * #LEGEND + 12)
  legend:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 10, 10)
  legend:SetFrameLevel(box:GetFrameLevel() + 6)
  local bg = legend:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(legend)
  bg:SetColorTexture(0, 0, 0, 0.6)
  for i, entry in ipairs(LEGEND) do
    local y = -6 - (i - 1) * 16
    local icon = legend:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetPoint("TOPLEFT", legend, "TOPLEFT", 8, y)
    M.Kit.Atlas(icon, entry[1], MARK_FILL)
    local label = legend:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    label:SetText(entry[2])
  end
  return legend
end

local INK_FONT = { GameFontNormal = "GameFontBlack", GameFontHighlight = "GameFontBlack", GameFontNormalSmall = "GameFontBlackSmall",
  GameFontHighlightSmall = "GameFontBlackSmall" } -- the same sizes without the drop shadow

local function pageText(page, font, x, y, width, colour)
  local fs = page:CreateFontString(nil, "OVERLAY", INK_FONT[font] or font)
  fs:SetPoint("TOPLEFT", page, "TOPLEFT", x, y)
  fs:SetWidth(width)
  fs:SetJustifyH("LEFT")
  fs:SetTextColor(rgb(colour or SUB_INK))
  return fs
end

local function buildPage(ui, box)
  local page = CreateFrame("Frame", nil, box)
  page:SetFrameLevel(box:GetFrameLevel() + 10)
  page:SetSize(PAGE_W, PAGE_H)
  page:SetPoint("TOPLEFT", box, "TOPLEFT", PAGE_LEFT, -PAGE_TOP)
  page:EnableMouse(true)
  local bg = page:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(page)
  M.Kit.Atlas(bg, "QuestBG-Horde", PARCHMENT)

  page.close = CreateFrame("Button", nil, page, "UIPanelCloseButton")
  page.close:SetPoint("TOPRIGHT", page, "TOPRIGHT", -2, -2)
  page.close:SetScript("OnClick", function() M.Safe(function()
    closePage(ui)
    draw(ui)
  end) end)

  page.anya = CreateFrame("Frame", nil, page)
  page.anya:SetSize(44, 44)
  page.anya:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -14)

  local textW = PAGE_W - 2 * PAGE_PAD
  page.title = pageText(page, "GameFontNormal", 66, -16, 206, INK)
  page.title:SetWordWrap(false)
  page.place = pageText(page, "GameFontHighlightSmall", 66, -36, 216)
  page.detail = pageText(page, "GameFontHighlightSmall", 66, -50, 212)
  page.text = pageText(page, "GameFontHighlightSmall", PAGE_PAD, -66, textW, INK)
  page.text:SetJustifyV("TOP")
  page.text:SetHeight(78) -- six lines, the longest story text

  local label = pageText(page, "GameFontNormalSmall", PAGE_PAD, -148, textW - 90, LABEL_INK)
  label:SetText("Follower")
  page.barracks = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  page.barracks:SetSize(80, 22)
  page.barracks:SetPoint("TOPRIGHT", page, "TOPRIGHT", -PAGE_PAD, -142) -- its bottom on the chip row's top
  page.barracks:SetText("Barracks")
  page.barracks:SetScript("OnClick", function() M.Safe(function()
    if ui.person and ns.GoTo then ns.GoTo("barracks", { fid = ui.person.id }) end
  end) end)
  page.chips = {}
  page.stat = pageText(page, "GameFontHighlightSmall", PAGE_PAD, -212, textW)
  page.supplies = pageText(page, "GameFontHighlightSmall", PAGE_PAD, -228, textW)

  page.gate = pageText(page, "GameFontHighlight", PAGE_PAD, -246, textW, INK)
  page.chance = pageText(page, "GameFontNormal", PAGE_PAD, -246, textW, INK)

  page.bar = CreateFrame("Frame", nil, page)
  page.bar:SetSize(BAR_W, BAR_H)
  page.bar:SetPoint("TOPLEFT", page, "TOPLEFT", PAGE_PAD, -264)
  page.bands = {}
  for i, band in ipairs(BANDS) do
    local t = page.bar:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(band[2], band[3], band[4], 1)
    page.bands[i] = t
  end

  local half = math.floor(textW / 2)
  page.wounded = pageText(page, "GameFontHighlightSmall", PAGE_PAD, -282, half)
  page.killed = pageText(page, "GameFontHighlightSmall", PAGE_PAD + half, -282, half)
  page.perma = pageText(page, "GameFontHighlightSmall", PAGE_PAD, GEAR_Y, textW)
  page.perma:Hide()
  page.damaged = pageText(page, "GameFontHighlightSmall", PAGE_PAD, GEAR_Y, half)
  page.lost = pageText(page, "GameFontHighlightSmall", PAGE_PAD + half, GEAR_Y, half)
  anchorAt(page.lost, page.damaged, half, 0)
  page.outcomes = { page.wounded, page.killed, page.damaged, page.lost }

  page.dropped = pageText(page, "GameFontHighlightSmall", PAGE_PAD, GEAR_Y - 22, textW, "9a1010")
  anchorAt(page.dropped, page.damaged, 0, -22)
  page.rewardsLabel = pageText(page, "GameFontNormalSmall", PAGE_PAD, GEAR_Y - 40, textW, LABEL_INK)
  page.rewardsLabel:SetText("Rewards")
  anchorAt(page.rewardsLabel, page.damaged, 0, -40)
  page.rewards = pageText(page, "GameFontHighlightSmall", PAGE_PAD, GEAR_Y - 54, textW, INK)
  anchorAt(page.rewards, page.damaged, 0, -54)
  page.finds = pageText(page, "GameFontHighlightSmall", PAGE_PAD, GEAR_Y - 70, textW, INK)
  anchorAt(page.finds, page.damaged, 0, FINDS_Y)

  page.send = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  page.send:SetSize(126, 24)
  page.send:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -18, 18)
  page.send:SetText("Start Expedition")
  page.send:SetScript("OnClick", function() M.Safe(function()
    if not (ui.open and ui.person) then return end
    local row = ui.open.row
    local sent, why = ns.Send(ui.person.id, row.id)
    if sent then
      closePage(ui)
      draw(ui)
    else
      refuse(why, row)
      draw(ui)
    end
  end) end)

  page:Hide()
  return page
end

function MapTab.Build(f, bar)
  local ui = { rects = {}, locks = {}, hits = {}, markPool = {}, pinPool = {}, rows = {},
    worldTiles = { n = 0, layer = "BACKGROUND" }, zoneTiles = { n = 0, layer = "BACKGROUND" },
    overTiles = { n = 0, layer = "BORDER" } }
  f.map = ui

  local box = CreateFrame("Frame", nil, f)
  box:SetSize(BOX_W, BOX_H)
  box:SetPoint("CENTER", f, "CENTER", 0, 0)
  if box.SetClipsChildren then box:SetClipsChildren(true) end
  ui.box = box

  local function canvas()
    local c = CreateFrame("Frame", nil, box)
    c:SetSize(CANVAS_W, CANVAS_H)
    c:SetPoint("TOPLEFT", box, "TOPLEFT", CANVAS_X, -CANVAS_Y)
    return c
  end
  ui.world, ui.zone = canvas(), canvas()
  ui.zone:Hide()
  -- The zone takes the mouse for its right-click, so the window no longer drags from the zone map (plan Task 3).
  ui.zone:EnableMouse(true)
  ui.zone:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" and ui.current and not ui.covered then M.Safe(zoomOut, ui) end
  end)

  ui.cover = function(on)
    ui.covered = on
    showLayers(ui)
  end
  ui.zoomTo = function(id) zoomTo(ui, id) end
  ui.openPage = function(row) openPage(ui, row) end
  ui.zoomOut = function() zoomOut(ui) end
  ui.chooseWho = function(fid) chooseWho(ui, fid) end

  for _, id in ipairs(ORDER) do
    local hit = CreateFrame("Button", nil, ui.world)
    local function enter(self) M.Safe(showZoneTip, ui, self, id) end
    hit:SetFrameLevel(ui.world:GetFrameLevel() + (REG[id].lock and 1 or 2))
    hit:SetScript("OnEnter", enter)
    hit:SetScript("OnLeave", hideTip)
    ui.hits[id] = hit
    if REG[id].lock then
      local lock = newMark(ui.world, MARK_PX)
      M.Kit.Atlas(lock.icon, "worldquest-tracker-lock", MARK_FILL)
      local name = lock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      outline(name)
      name:SetPoint("TOP", lock, "BOTTOM", 0, 0)
      name:SetText(regionInfo(id).name)
      lock:SetScript("OnEnter", enter)
      ui.locks[id] = lock
    else
      hit:SetScript("OnClick", function() M.Safe(zoomTo, ui, id) end)
    end
  end

  local function goCamp()
    M.Safe(function() if ns.GoTo then ns.GoTo("camp") end end)
  end

  ui.camp = newMark(ui.world, MARK_PX)
  M.Kit.Atlas(ui.camp.icon, "hordewarfrontmapbanner", MARK_FILL)
  ui.camp:SetScript("OnEnter", function(self) M.Safe(showCampTip, self) end)
  ui.camp:SetScript("OnClick", goCamp)

  ui.banner = ui.zone:CreateTexture(nil, "ARTWORK")
  ui.banner:SetSize(PIN_PX, PIN_PX)
  local mills = PLACES.tirisfal["Agamand Mills"]
  ui.banner:SetPoint("CENTER", ui.zone, "TOPLEFT", CANVAS_W * mills[1], -CANVAS_H * mills[2])
  M.Kit.Atlas(ui.banner, "hordewarfrontmapbanner", MARK_FILL)
  ui.banner:Hide()

  ui.campPin = newMark(ui.zone, CAMP_PX)
  M.Kit.Atlas(ui.campPin.icon, "hordewarfrontmapbanner", MARK_FILL)
  putCentre(ui.campPin, ui.zone, CANVAS_W * CAMP[1], CANVAS_H * CAMP[2])
  local campName = ui.campPin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  outline(campName)
  campName:SetPoint("TOP", ui.campPin, "BOTTOM", 0, 0)
  campName:SetText("Company Camp")
  ui.campPin:SetScript("OnEnter", function(self) M.Safe(showCampTip, self) end)
  ui.campPin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  ui.campPin:SetScript("OnClick", function(_, button)
    if button == "RightButton" then M.Safe(zoomOut, ui) else goCamp() end
  end)
  ui.campPin:Hide()

  -- Above the canvases: a child frame's art draws over its parent's text.
  local hud = CreateFrame("Frame", nil, box)
  hud:SetSize(BOX_W, BOX_H)
  hud:SetFrameLevel(box:GetFrameLevel() + 6)
  ui.hud = hud
  ui.title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  outline(ui.title)
  ui.title:SetPoint("TOPLEFT", hud, "TOPLEFT", 0, -TITLE_Y)
  local function line(y)
    local fs = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    outline(fs)
    fs:SetPoint("TOPLEFT", hud, "TOPLEFT", 0, -y)
    return fs
  end
  ui.timer = line(LINE2_Y)
  ui.level = line(LINE2_Y)
  ui.who = line(LINE3_Y)
  ui.held = line(LINE3_Y)
  ui.held:SetText("Anya has nothing more for us today.")

  ui.back = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
  ui.back:SetSize(100, 22)
  placeHud(ui)
  ui.back:SetText("World map")
  ui.back:SetFrameLevel(box:GetFrameLevel() + 6)
  ui.back:SetScript("OnClick", function() M.Safe(zoomOut, ui) end)
  ui.back:Hide()

  ui.legend = buildLegend(box)
  ui.page = buildPage(ui, box)

  f:SetScript("OnSizeChanged", function(self) M.Safe(place, self) end)
  -- The page stays open over a trip away; its pack may have changed there, so it is checked again on return only.
  f:HookScript("OnShow", function() M.Safe(function()
    if not ui.open then return end
    ui.open.checked = {}
    checkPack(ui, ui.open.fid)
  end) end)
  place(f)
  if ns.History then M.Safe(ns.History.Build, f, box, bar, ui.cover) end
end
