-- GuildSyncGames Races.lua (Task 6): the Kodo races tab, ns.Races (mock kr-1 to kr-4). Three views over one holder:
-- the race (the six-lane list, the clock bar and your bet or the result in the left column, the whole Barrens map
-- beside it, and under both the last race's winners and the biggest wins where rows fit), betting (the field to pick
-- from, the stake, Earlier races with Watch, the biggest wins), and a replay of an earlier race in the race view.
-- Below 420 tall (the 760x480 window, kr-4) the boards are left out and the lanes are 24 tall. All UI state lives in U.
-- S19 (plan rev 4 "Shared geometry", gate A d1721): the map is Forever's own fully explored Barrens art (UiMapArt 2181,
-- 12 base tiles and 25 overlays) at one scale k = w / 1002. The six kodos run the Gold Road (ROAD, ns.Races.PathAt)
-- from the south end to the north end, each offset along x only by its lane (o2059, gap = icon), with its list number
-- at the icon's top-left. The boards sit under the map and the column, shown only where fits() gives rows (o2050).
-- Clock rule (f7154): drawing reads ns.RaceClock(); a bet goes through ns.Bet, which checks the open race by ns.Now().
-- Seam rule (f7165): ns.Purse, ns.MyBet, ns.RaceHist, ns.GuildBoards, ns.RaceClock, ns.RaceLabel and ns.Bet are read
-- through ns when called (Grain.lua, Boards.lua and Demo.lua own them; tests replace them).
-- The track's OnUpdate draws only (the kodos, the clock bar, the sub line), every 0.1 s and only while the track is
-- shown; crossing the 45 s line redraws the page. The kodos are icons: a kodo model is a BETA-CHECK probe (o1606).

local _, ns = ...

if not ns.M then return end
local M, GC = ns.M, ns.GrainCore

local HOUR, RUN = 3600, 45      -- GrainCore's HOUR and GC.RUN (a race runs the first 45 s of its hour)
local NORMAL_W, NORMAL_H = 726, 486
local SMALL_BELOW = 420
local LEFT, TOP = 8, 46
local GAP, FOOT = 12, 30        -- the column to the map; the room under the map for the purse line
-- lane: a list row's height; labelW: the column left of the map (the clock bar, bet and result lines are as wide);
-- field and col: the betting view's field rows and column. The kodo icon size comes from the map's width (drawRace).
local BIG = { lane = 30, labelW = 170, field = 30, col = 400 }
local SMALL = { lane = 24, labelW = 150, field = 24, col = 300 } -- below 420 tall (kr-4)
local ROW_H, EARLIER = 36, 4    -- Earlier races: four rows of 36 (kr-2)
local BOARD_ROW, BOARD_ROWS = 22, 5
local THROTTLE = 0.1
local STAKES = { 10, 25, 50 }
local DEFAULT_STAKE = "25"
-- The Barrens map as Forever's world map draws it, fully explored: UiMap 1413 -> UiMapArt 2181 (UiMapXMapArt row 2411),
-- build 1.60.1.70532, from the wago.tools DB2 tables UiMapXMapArt, UiMapArt, UiMapArtStyleLayer (layer 1002 x 668,
-- tiles 256), UiMapArtTile (base, row-major, four to a row) and WorldMapOverlay 5463-5487 + WorldMapOverlayTile (over:
-- { fileDataID, offX, offY, texW, texH }); context-mapfit. Loaded by fileDataID: the listfile has no names for them.
local MAP_W, MAP_H, TILE = 1002, 668, 256
local MAP = {
  base = { -- (row, col) row-major, four to a row: r0 c0..c3, r1 c0..c3, r2 c0..c3
    8095987, 8095991, 8095992, 8095993,
    8095994, 8095995, 8095996, 8095997,
    8095998, 8095988, 8095989, 8095990,
  },
  over = {
    { 8095985, 340, 234, 256, 256 }, -- 5463
    { 8095986, 431, 479, 128, 128 }, -- 5464
    { 8095999, 335, 462, 256, 128 }, -- 5465
    { 8096000, 555, 0, 128, 128 },   -- 5466
    { 8096001, 442, 298, 128, 256 }, -- 5467
    { 8096002, 365, 350, 256, 128 }, -- 5468 Camp Taurajo
    { 8096003, 419, 63, 128, 128 },  -- 5469
    { 8096004, 564, 52, 128, 256 },  -- 5470
    { 8096005, 355, 402, 256, 256 }, -- 5471
    { 8096006, 492, 63, 128, 128 },  -- 5472
    { 8096007, 306, 130, 128, 128 }, -- 5473
    { 8096008, 365, 177, 256, 256 }, -- 5474
    { 8096009, 527, 307, 256, 128 }, -- 5475
    { 8096010, 507, 294, 128, 128 }, -- 5476
    { 8096011, 556, 189, 128, 128 }, -- 5477
    { 8096012, 407, 553, 256, 115 }, -- 5478 (file 256 x 128)
    { 8096013, 341, 537, 128, 128 }, -- 5479
    { 8096014, 481, 211, 256, 128 }, -- 5480
    { 8096015, 431, 118, 256, 256 }, -- 5481 The Crossroads
    { 8096016, 317, 29, 256, 256 },  -- 5482
    { 8096017, 384, 115, 128, 128 }, -- 5483
    { 8096018, 581, 247, 128, 128 }, -- 5484
    { 8096019, 412, 0, 128, 128 },   -- 5485 The Mor'shan Rampart
    { 8096020, 456, 0, 256, 128 },   -- 5486
    { 8096021, 498, 119, 256, 128 }, -- 5487
  },
}
-- Each tile's layer rect clipped to 1002 x 668, with its texcoords by the client's rule (MapExplorationDataProvider.lua
-- :118-157, Forever UI 1.60.1.70205: 0..pixels/file, the file the next power of two): { id, x0, y0, tw, th, u1, v1, sub }.
-- perPow2(n) is 1 / (the next power of two of n), halved up in the loop: no division (games_static's rule).
local function perPow2(n) local p, r = 1, 1 while p < n do p, r = p * 2, r * 0.5 end return r end
local function tileRect(id, x0, y0, w, h, sub)
  local tw, th = math.min(w, MAP_W - x0), math.min(h, MAP_H - y0)
  return { id, x0, y0, tw, th, tw * perPow2(w), th * perPow2(h), sub }
end
MAP.tiles = {}
for i, id in ipairs(MAP.base) do
  MAP.tiles[#MAP.tiles + 1] = tileRect(id, ((i - 1) % 4) * TILE, math.floor((i - 1) / 4) * TILE, TILE, TILE, 1)
end
for _, o in ipairs(MAP.over) do MAP.tiles[#MAP.tiles + 1] = tileRect(o[1], o[2], o[3], o[4], o[5], 2) end
local GRAIN_ICON, FLAG_ICON = 134058, 1100022
local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local YOU = " |cff999999(you)|r" -- the "(you)" suffix grey, not in the class colour (f7223)
local GREEN = { 0.25, 1, 0.25 }
local REFUSE = { closed = "Bets on this race are closed.", stake = "A bet is 5 to 200 grain.",
  short = "Not enough grain in your purse.", lane = "Pick a kodo first." } -- demo: ns.Inert said the line

local U = { lanes = {}, field = {}, rows = {}, tiles = {}, acc = 0 }

local grey, label, button, fmt = ns.UI.grey, ns.UI.label, ns.UI.button, ns.UI.fmt -- Page.lua's helpers
local function colour(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

local function place(f, rel, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", rel, "TOPLEFT", x, y)
end

-- A disabled button's reason in a tooltip on hover (btn.reason; nil shows none).
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

-- The kit's section header with a right-hand note, or a plain one when it answers nil (API.md:1199).
local function header(parent, text)
  local h = M.Kit.SectionHeader(parent, 300, text)
  if not h then
    h = CreateFrame("Frame", nil, parent)
    h:SetSize(300, 26)
    h.label = label(h, "GameFontNormal")
    h.label:SetPoint("LEFT", h, "LEFT", 8, 0)
    h.label:SetText(text)
  end
  h.note = label(h)
  h.note:SetPoint("TOPRIGHT", h, "TOPRIGHT", -21, -8)
  return h
end

-- ---------- the clock ----------

-- What to draw: a replay of an earlier race, else the race RaceClock is in (running, finished) or the one open for
-- betting. nil without a readable clock.
local function view()
  local t = ns.RaceClock()
  if type(t) ~= "number" then return nil end
  if U.replay then
    local secs = math.max(0, t - U.replay.t0)
    return { mode = secs < RUN and "running" or "finished", hour = U.replay.hour, secs = secs, t = t, replay = true }
  end
  local mode, h = GC.Phase(t)
  local _, secs = GC.RaceAt(t)
  return { mode = mode, hour = h, secs = secs, t = t }
end

-- The own bet on hour h: the pending one, else the settled one in the history (it carries pay).
local function betFor(h)
  local b = ns.MyBet()
  if b and b.hour == h then return b end
  for _, r in ipairs(ns.RaceHist() or {}) do
    if r.hour == h then return r end
  end
  return nil
end

local ORD = { "1st", "2nd", "3rd", "4th", "5th", "6th" }
local function ordinal(i) return ORD[i] or tostring(i) end

local function clockText(secs) return string.format("0:%02d of 0:45", math.min(RUN, math.floor(secs))) end

-- ---------- the Earlier races row layout (pinned by the director's mock review) ----------

-- One row: the winner's name on line 1, the own result on line 2 at the name's left, Watch at the right, centred.
local function rowLayout(listW)
  local watch = { x = listW - 70, w = 64 }
  local w = watch.x - 52 - 6
  return { rowH = ROW_H, name = { x = 52, w = w }, result = { x = 52, w = w, y = -21 }, watch = watch }
end

-- ---------- the boards ----------

local function buildBoard(parent, title)
  local b = { head = header(parent, title), rows = {} }
  for i = 1, BOARD_ROWS do
    local r = { icon = parent:CreateTexture(nil, "ARTWORK"), name = label(parent, "GameFontHighlightSmall"),
      value = label(parent, "GameFontHighlight"), pays = label(parent) }
    r.icon:SetSize(16, 16)
    r.value:SetJustifyH("RIGHT")
    r.value:SetWidth(70)
    grey(r.pays)
    b.rows[i] = r
  end
  return b
end

-- rows: { name, value, class, you, pays }; n rows at most fit; shown = false hides it all. A row with pays gets "xN"
-- right of its value (the winners board, kr-1; f7219).
local function drawBoard(b, shown, x, y, w, rows, n, note, title)
  b.head:SetShown(shown)
  for i, r in ipairs(b.rows) do
    local e = shown and i <= n and rows[i]
    r.icon:SetShown(e and e.class ~= nil or false)
    r.name:SetShown(e and true or false)
    r.value:SetShown(e and true or false)
    r.pays:SetShown(e and e.pays ~= nil or false)
    if e then
      local top = y - 26 - (i - 1) * BOARD_ROW
      if e.class then
        M.Kit.ClassIcon(r.icon, e.class)
        place(r.icon, b.parent, x + 4, top - 3)
      end
      place(r.name, b.parent, x + 26, top - 5)
      place(r.value, b.parent, x + w - (e.pays and 140 or 78), top - 4)
      r.name:SetText(ns.Escape(tostring(e.name)) .. (e.you and YOU or ""))
      ns.UI.classColour(r.name, e.class)
      r.value:SetText(fmt(e.value))
      if e.pays then
        place(r.pays, b.parent, x + w - 64, top - 5)
        r.pays:SetText("x" .. tostring(e.pays))
      end
    end
  end
  if not shown then return end
  b.head:SetWidth(w)
  place(b.head, b.parent, x, y)
  b.head.note:SetText(note or "")
  if title and b.head.label then b.head.label:SetText(title) end
end

local function boardRows(list, field)
  local out = {}
  for i, e in ipairs(type(list) == "table" and list or {}) do
    out[i] = { name = e.name, value = e[field], class = e.class, you = e.you, pays = e.pays }
  end
  return out
end

local function fits(top, h) return math.max(0, math.min(BOARD_ROWS, math.floor((h - 30 - top - 26) / BOARD_ROW))) end

-- ---------- the road ----------

-- The Gold Road south to north, in layer px on the 1002x668 Barrens layer (y down), traced on art 2181, build
-- 1.60.1.70532 (context-mapfit "The Gold Road"). The trace's last two points {483,35},{481,18} are one {483,38} here,
-- so a finishing icon stays inside the map. y strictly decreases from 614 to 38.
local ROAD = {
  {444,614},{442,602},{443,590},{447,579},{454,568},{463,557},      -- south end, the Thousand Needles side
  {461,530},{465,500},{462,480},{465,457},{472,437},
  {476,413},{470,397},                                              -- past Camp Taurajo
  {481,365},{507,337},{513,323},{502,300},{502,280},{503,255},
  {507,233},{512,213},{517,186},                                    -- the Crossroads
  {521,168},{522,152},{521,136},{519,120},{511,102},{500,95},
  {485,75},{484,55},{483,38},                                       -- north end, the Mor'shan side
}
-- Cumulative length at each waypoint, once at load; ROAD_LEN is the whole road (about 616 layer px).
local ROAD_AT, ROAD_LEN = { 0 }, 0
for i = 2, #ROAD do
  local a, b = ROAD[i - 1], ROAD[i]
  ROAD_LEN = ROAD_LEN + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
  ROAD_AT[i] = ROAD_LEN
end

-- The point at progress p (0..1, clamped) along the road by arc length. Pure: reads no client state.
-- Exempt from games_static's division rule (d1722): guard any new division here by hand, as seg > 0 below.
local function pathAt(p)
  p = math.max(0, math.min(1, tonumber(p) or 0))
  local s = p * ROAD_LEN
  for i = 2, #ROAD do
    if s <= ROAD_AT[i] or i == #ROAD then
      local a, b, seg = ROAD[i - 1], ROAD[i], ROAD_AT[i] - ROAD_AT[i - 1]
      local f = seg > 0 and math.min(1, (s - ROAD_AT[i - 1]) / seg) or 0 -- no division by a 0-long segment
      return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
    end
  end
end

-- ---------- the track ----------

-- The whole map in the w-wide track at k = w / 1002: every tile at its layer rect * k, cropped by its texcoords.
local function layoutMap(w)
  local k = w / MAP_W
  for i, d in ipairs(MAP.tiles) do
    local t = U.tiles[i]
    t:SetTexCoord(0, d[6], 0, d[7])
    t:SetSize(d[4] * k, d[5] * k)
    place(t, U.track, d[2] * k, -d[3] * k)
  end
end

-- A region of size w x h centred on (cx, cy) in the map box: centreAt only moves it (its size is set at draw time),
-- centreOn sizes it too.
local function centreAt(t, cx, cy, w, h) place(t, U.track, cx - w * 0.5, -(cy - h * 0.5)) end
local function centreOn(t, cx, cy, w, h)
  t:SetSize(w, h)
  centreAt(t, cx, cy, w, h)
end

-- The kodos on the road at secs: p is Pos() while running; at the end in finishing order, a step apart (kr-3). Each
-- centre is the road point at p, offset along x only by its lane (o2059: lane 1 west, 6 east, gap = icon apart). The
-- number follows its icon's top-left anchor; the own bet's kodo (U.order[i] == U.mineLane, a lane value) moves its
-- dark backing and gold frame. Only what moves is set here, on every tick; the sizes, the numbers' text and colour,
-- the mark's shown state and the finish are set once per draw in drawRace.
local function drawRunners(v)
  local r, k, icon, gap = U.race, U.k, U.icon, U.gap
  for i, lane in ipairs(U.order) do
    local p = v.mode == "running" and GC.Pos(r, lane, v.secs) or (1 - (i - 1) * 0.035)
    local x, y = pathAt(p)
    local cx, cy = x * k + (lane - 3.5) * gap, y * k
    centreAt(U.lanes[i].runner, cx, cy, icon, icon)
    if lane == U.mineLane then
      local b = icon + 4
      local e = (b - 2) * 0.5 -- each 2 px edge's centre from the kodo's
      centreAt(U.back, cx, cy, icon + 6, icon + 6)
      centreAt(U.frame[1], cx, cy - e, b, 2) -- top
      centreAt(U.frame[2], cx, cy + e, b, 2) -- bottom
      centreAt(U.frame[3], cx - e, cy, 2, b) -- left
      centreAt(U.frame[4], cx + e, cy, 2, b) -- right
    end
  end
  if v.mode ~= "running" then return end
  local text = clockText(v.secs)
  U.barText:SetText(text)
  U.barFill:SetWidth(math.max(1, math.floor((U.barW - 12) * math.min(RUN, v.secs) / RUN)))
  U.sub:SetText("The " .. ns.RaceLabel(v.hour) .. " race · " .. (v.replay and "replay" or "running") .. " · " .. text)
end

-- ---------- drawing ----------

local function size()
  local w, h = U.holder:GetWidth(), U.holder:GetHeight()
  w = (type(w) == "number" and w > 0) and w or NORMAL_W
  h = (type(h) == "number" and h > 0) and h or NORMAL_H
  return w, h, h < SMALL_BELOW
end

-- The purse line (the grain icon and "<n> grain") at x, y, and the grey note beside it.
local function purseAt(x, y, note)
  place(U.grain, U.holder, x, y)
  place(U.purse, U.holder, x + 22, y - 2)
  U.purse:SetText(fmt(ns.Purse()) .. " grain")
  place(U.note, U.holder, x + 130, y - 2)
  U.note:SetText(note or "")
end

-- At the next race's start the page redraws once, if the races tab is on screen then (the minute tick may be late).
local function armStart(h, t)
  if U.armed == h then return end
  U.armed = h
  M.After(math.max(1, h * HOUR - t), function()
    if ns.ShownGame and ns.ShownGame() == "races" then U.Draw() end
  end)
end

local function drawRace(v, W, H, small)
  local S, r = U.S, GC.Race(v.hour)
  U.race, U.order = r, {}
  for i = 1, 6 do U.order[i] = v.mode == "running" and i or r.order[i] end
  -- The map box right of the column: as wide as fits, 3:2 like the layer, h exact (never rounded: f7188's zero slack).
  local mw = math.max(0, math.floor(math.min(W - 2 * LEFT - GAP - S.labelW, (H - TOP - FOOT) * 1.5)))
  local mh = mw / 1.5
  -- The seam for drawRunners (plan Seams): the map's scale, the kodo icon and the lane gap (gap = icon, o2059).
  U.k = mw / MAP_W
  U.icon = math.max(14, math.min(18, math.floor(mw * 0.034)))
  U.gap = U.icon
  place(U.raceBox, U.holder, LEFT, -TOP)
  U.raceBox:SetSize(S.labelW + GAP + mw, math.max(6 * S.lane, mh))
  place(U.track, U.raceBox, S.labelW + GAP, 0)
  U.track:SetSize(mw, mh)
  layoutMap(mw)
  local bet = betFor(v.hour)
  U.mineLane = bet and bet.lane or nil -- a lane value: compared with U.order[i], never an index
  for i, lane in ipairs(U.order) do
    local L, e = U.lanes[i], r.field[lane]
    local mine = bet and bet.lane == lane or false
    place(L.row, U.raceBox, 0, -(i - 1) * S.lane)
    L.row:SetSize(S.labelW, S.lane)
    -- finished: places 1st..6th, the name moved right to x 26 and kept to one line before the pays box (a3)
    local done = v.mode ~= "running"
    L.num:SetText(done and ordinal(i) or tostring(i))
    L.name:ClearAllPoints()
    L.name:SetPoint("LEFT", L.row, "LEFT", done and 26 or 18, 0)
    L.name:SetWidth(done and S.labelW - 60 or 0)
    if done then L.name:SetWordWrap(false) end
    L.name:SetText(e.name)
    colour(L.name, mine and GOLD or { 1, 1, 1 })
    L.pays:SetText("x" .. e.pays)
    L.lit:SetShown(mine)
    L.runner:SetTexture(e.icon) -- drawRunners sizes and places it on the road
  end
  -- What stays put through a race, set once per draw (drawRunners only moves things): each icon's size, its number
  -- (the row's i, gold for the own bet), the own mark's sizes and shown state, and the finish at the road's north end.
  local icon, mine = U.icon, false
  for i, lane in ipairs(U.order) do
    local L = U.lanes[i]
    L.runner:SetSize(icon, icon)
    L.mark:SetText(tostring(i))
    colour(L.mark, lane == U.mineLane and GOLD or WHITE)
    if lane == U.mineLane then mine = true end
  end
  U.back:SetSize(icon + 6, icon + 6)
  U.back:SetShown(mine)
  for j, t in ipairs(U.frame) do
    if j <= 2 then t:SetSize(icon + 4, 2) else t:SetSize(2, icon + 4) end
    t:SetShown(mine)
  end
  local fx, fy = pathAt(1)
  local lw = 5 * U.gap + icon + 8
  centreOn(U.finish, fx * U.k, fy * U.k, lw, 2)
  place(U.flag, U.track, fx * U.k + lw * 0.5 + 2, -(fy * U.k - 9))

  -- The column under the list, labelW wide, one line under another (plan "Left column"; the buttons stacked, as
  -- 110 + 130 + 8 is wider than the column). colBottom: where the column ends, for the boards.
  local winner = r.field[r.winner].name
  local CW, ly = S.labelW, TOP + 6 * S.lane + 10 -- the line under the lanes
  local running = v.mode == "running"
  local dy, ay = small and 20 or 40, small and 52 or 74 -- the detail and Watch again under the result
  local colBottom = running and ly + 79 or ly + ay + 48
  U.bar:SetShown(running)
  U.betHead:SetShown(running)
  U.betLine:SetShown(running)
  U.result:SetShown(not running)
  U.detail:SetShown(not running)
  U.again:SetShown(not running)
  U.betOn:SetShown(not running)
  U.skip:SetShown(running and v.replay or false)
  if running then
    if v.replay then place(U.skip, U.holder, W - LEFT - 6 - 120, -20) end
    U.barW = CW
    U.bar:SetWidth(CW)
    place(U.bar, U.holder, LEFT, -ly)
    place(U.betHead, U.holder, LEFT, -(ly + 35))
    U.betLine:SetWidth(CW) -- wraps to two lines
    place(U.betLine, U.holder, LEFT, -(ly + 51))
    if bet then
      local pays = r.field[bet.lane].pays
      U.betLine:SetText(fmt(bet.stake) .. " grain on |cffffd100" .. r.field[bet.lane].name .. "|r · pays "
        .. fmt(GC.Payout(bet.stake, pays, true)))
    else
      U.betLine:SetText("No bet on this race.")
    end
  else
    U.sub:SetText("The " .. ns.RaceLabel(v.hour) .. " race · " .. (v.replay and "replay" or "finished") .. " · "
      .. winner .. " won")
    -- the result one line in GameFontNormal when small (o2052), else up to two in GameFontNormalLarge
    U.result:SetFontObject(small and "GameFontNormal" or "GameFontNormalLarge")
    U.result:SetWidth(CW)
    place(U.result, U.holder, LEFT, -ly)
    U.detail:SetWidth(CW)
    place(U.detail, U.holder, LEFT, -(ly + dy))
    if bet then
      local e = r.field[bet.lane]
      local won = bet.lane == r.winner
      local pay = bet.pay or GC.Payout(bet.stake, e.pays, won)
      U.result:SetText(won and ("You won " .. fmt(pay) .. " grain!") or ("You lost " .. fmt(bet.stake) .. " grain."))
      if won then colour(U.result, GREEN) else grey(U.result) end
      U.detail:SetText(fmt(bet.stake) .. " on " .. e.name .. " at x" .. e.pays .. ".")
    else
      U.result:SetText(winner .. " won.")
      colour(U.result, GOLD)
      U.detail:SetText("")
    end
    place(U.again, U.holder, LEFT, -(ly + ay))
    place(U.betOn, U.holder, LEFT, -(ly + ay + 26))
    local mode, open = GC.Phase(v.t)
    if mode ~= "betting" then open = GC.RaceAt(v.t) + 1 end
    U.betOn:SetText("Bet on " .. ns.RaceLabel(open))
    U.betOn:SetEnabled(mode == "betting")
    U.betOn.reason = mode ~= "betting" and ("Bets for the " .. ns.RaceLabel(open) .. " race open at "
      .. (string.gsub(ns.RaceLabel(open - 1), "^(%d%d):00", "%1:05")) .. ".") or nil
  end
  drawRunners(v)

  -- the boards under the map and the column, only where rows fit (left out below 420 tall; o2050), then the purse
  local by = math.max(TOP + mh + 10, colBottom + 10)
  local bw = math.floor((W - 2 * LEFT - 6 - 16) * 0.5)
  local n = fits(by, H)
  local shown = not small and n > 0
  local boards = ns.GuildBoards and ns.GuildBoards() or {}
  -- The winners board names the race its rows are from (GuildBoards' lastHour), none without one (f7188).
  local last = type(boards.lastHour) == "number" and boards.lastHour or nil
  local lr = last and GC.Race(last)
  drawBoard(U.last, shown and last ~= nil, LEFT, -by, bw, boardRows(boards.winners, "pay"), n,
    lr and (lr.field[lr.winner].name .. " won"), last and ("Last race · " .. ns.RaceLabel(last)))
  drawBoard(U.big, shown, LEFT + bw + 16, -by, bw, boardRows(boards.biggest, "big"), n)
  local note = ""
  if running and not v.replay then
    local nextRace, at = ns.RaceLabel(v.hour + 1), (string.gsub(ns.RaceLabel(v.hour), "^(%d%d):00", "%1:05"))
    note = small and ("Bets for " .. nextRace .. " open at " .. at .. ".")
      or ("Bets for the " .. nextRace .. " race open at " .. at .. ".")
  end
  purseAt(LEFT, -(H - 26), note)
end

local function stake() return tonumber(U.box:GetText()) end

local function drawBetting(v, W, H, small)
  local S, r = U.S, GC.Race(v.hour)
  U.race = r
  local mine = ns.MyBet()
  if mine and mine.hour ~= v.hour then mine = nil end
  if U.fieldHour ~= v.hour then
    U.fieldHour, U.lane, U.text = v.hour, mine and mine.lane or nil, nil
  end
  armStart(v.hour, v.t)
  local mins = math.max(1, math.floor((v.hour * HOUR - v.t + 59) / 60))
  U.sub:SetText("The " .. ns.RaceLabel(v.hour) .. " race · starts in " .. mins .. " min · bets close at the start")
  local col, rx = S.col, S.col + 22
  local listW = W - rx - 14
  place(U.betBox, U.holder, LEFT, -TOP)
  U.betBox:SetSize(col, H - TOP)
  U.fieldHead:SetWidth(col)
  for i, f in ipairs(U.field) do
    local e = r.field[i]
    place(f, U.betBox, 0, -(26 + (i - 1) * S.field))
    f:SetSize(col, S.field)
    f.icon:SetTexture(e.icon)
    f.icon:SetSize(S.field - 6, S.field - 6)
    f.name:SetText(e.name)
    colour(f.name, U.lane == i and GOLD or { 1, 1, 1 })
    f.pays:SetText("x" .. e.pays)
    f.sel:SetShown(U.lane == i)
  end
  local sy = 26 + 6 * S.field + 12
  place(U.stakeHead, U.betBox, 0, -sy)
  place(U.box, U.betBox, 6, -(sy + 18))
  for i, b in ipairs(U.stakes) do place(b, U.betBox, 92 + (i - 1) * 48, -(sy + 19)) end
  local n, name = stake(), U.lane and r.field[U.lane].name
  U.betBtn:SetText(name and (n and ("Bet " .. n .. " on " .. name) or ("Bet on " .. name)) or "Pick a kodo")
  U.betBtn:SetWidth(small and 200 or 156)
  -- below 420 tall the field column is 300 wide: the bet button takes its own line under the stake
  local y = small and sy + 45 or sy + 19
  place(U.betBtn, U.betBox, small and 0 or 244, -y)
  local hint
  if mine then
    hint = "Your bet: " .. fmt(mine.stake) .. " grain on " .. r.field[mine.lane].name .. " · pays "
      .. fmt(GC.Payout(mine.stake, r.field[mine.lane].pays, true)) .. "."
  elseif name and n then
    hint = "Pays " .. fmt(GC.Payout(n, r.field[U.lane].pays, true)) .. " if " .. name .. " wins. 5 to 200 grain, one bet a race."
  else
    hint = "5 to 200 grain, one bet a race."
  end
  U.hint:SetText(hint)
  place(U.hint, U.betBox, 0, -(y + 29))
  U.msg:SetText(U.text or "")
  place(U.msg, U.betBox, 0, -(y + 45))
  U.cancel:SetShown(mine ~= nil)
  place(U.cancel, U.betBox, col - 110, -(y + 64))
  purseAt(LEFT, -(TOP + y + 67), "")

  -- right: Earlier races, then the biggest wins (left out below 420 tall)
  local L = rowLayout(listW)
  place(U.list, U.holder, rx, -TOP)
  U.list:SetSize(listW, 26 + EARLIER * L.rowH)
  U.listHead:SetWidth(listW)
  local hist = ns.RaceHist() or {}
  for i, row in ipairs(U.rows) do
    local h = v.hour - i
    local rr = GC.Race(h)
    place(row, U.list, 0, -(26 + (i - 1) * L.rowH))
    row:SetSize(listW, L.rowH)
    row.hour = h
    row.time:SetText(ns.RaceLabel(h))
    row.name:SetText(rr.field[rr.winner].name)
    place(row.name, row, L.name.x, -5)
    row.name:SetWidth(L.name.w)
    place(row.result, row, L.result.x, L.result.y)
    row.result:SetWidth(L.result.w)
    local res
    for _, b in ipairs(hist) do
      if b.hour == h then res = b end
    end
    row.result:SetShown(res ~= nil)
    if res then
      local won = (res.pay or 0) > 0
      row.result:SetText(won and ("you won " .. fmt(res.pay)) or ("you lost " .. fmt(res.stake)))
      if won then colour(row.result, GREEN) else grey(row.result) end
    end
    row.watch:SetWidth(L.watch.w)
    row.watch:ClearAllPoints()
    row.watch:SetPoint("RIGHT", row, "RIGHT", -(listW - L.watch.x - L.watch.w), 0)
  end
  local boards = ns.GuildBoards and ns.GuildBoards() or {}
  local by = TOP + 26 + EARLIER * ROW_H + 10
  drawBoard(U.big, not small, rx, -by, listW, boardRows(boards.biggest, "big"), fits(by, H))
end

function U.Draw()
  local W, H, small = size()
  U.S = small and SMALL or BIG
  U.acc = 0
  local v = view()
  U.v = v
  local mode = v and v.mode
  U.raceBox:SetShown(mode == "running" or mode == "finished")
  U.betBox:SetShown(mode == "betting")
  U.list:SetShown(mode == "betting")
  for _, f in ipairs({ U.bar, U.betHead, U.betLine, U.result, U.detail, U.again, U.betOn, U.skip }) do
    f:SetShown(false)
  end
  if not v then
    U.sub:SetText("The race clock cannot be read on this client.")
    drawBoard(U.last, false)
    drawBoard(U.big, false)
    purseAt(LEFT, -(H - 26), "")
    return
  end
  if mode == "betting" then
    drawBoard(U.last, false)
    drawBetting(v, W, H, small)
  else
    drawRace(v, W, H, small)
  end
  U.mode, U.hour, U.replaying = v.mode, v.hour, v.replay
end

-- The track's tick: a phase or race change redraws the page, otherwise only the kodos and the clock move.
local function tick()
  local v = view()
  if not v or v.mode ~= U.mode or v.hour ~= U.hour or v.replay ~= U.replaying then return U.Draw() end
  if v.mode == "running" then drawRunners(v) end
end

-- ---------- actions ----------

local function pick(lane)
  U.lane, U.text = lane, nil
  U.Draw()
end

local function setStake(n)
  U.box:SetText(tostring(n))
  U.text = nil
  U.Draw()
end

local function bet()
  local v = U.v
  if not (v and v.mode == "betting") then return end
  U.text = nil
  if not U.lane then
    U.text = REFUSE.lane
  else
    local ok, why = ns.Bet(v.hour, U.lane, stake())
    if not ok then U.text = REFUSE[why] end
  end
  U.Draw()
end

local function cancel()
  local ok, why = ns.CancelBet()
  U.text = not ok and REFUSE[why] or nil
  U.Draw()
end

local function watch(h)
  U.replay = { hour = h, t0 = ns.RaceClock() }
  U.Draw()
end

-- ---------- build ----------

local function buildRace(holder)
  U.raceBox = CreateFrame("Frame", nil, holder)
  -- The track first: the one frame under the holder with an OnUpdate.
  U.track = CreateFrame("Frame", nil, U.raceBox)
  ns.UI.inset(U.track) -- the fallback behind the map, and its rim
  -- The 37 map tiles, each set once: the base on BACKGROUND 1, the explored overlays over it on BACKGROUND 2.
  for i, d in ipairs(MAP.tiles) do
    U.tiles[i] = U.track:CreateTexture(nil, "BACKGROUND", nil, d[8])
    -- the client's own filter for map art (Forever UI 1.60.1.70205: Blizzard_MapCanvas/Blizzard_MapCanvasDetailLayer
    -- .lua:68, Blizzard_SharedMapDataProviders/MapExplorationDataProvider.lua:160)
    U.tiles[i]:SetTexture(d[1], nil, nil, "TRILINEAR")
  end
  -- The kodos' numbers go on U.marks, a plain child of the track (no OnUpdate): it draws over the track's regions.
  U.marks = CreateFrame("Frame", nil, U.track)
  U.marks:SetAllPoints(U.track)
  U.marks:SetFrameLevel(U.track:GetFrameLevel() + 1)
  -- The finish at the road's north end, placed by drawRunners: a short gold 2 px line across the six lanes and the
  -- flag beside it (kr-1; f7228). OVERLAY sublevels: the own backing and the flag 0, the kodos 1, the own frame 2.
  U.flag = U.track:CreateTexture(nil, "OVERLAY", nil, 0)
  U.flag:SetTexture(FLAG_ICON)
  U.flag:SetSize(18, 18)
  U.finish = U.track:CreateTexture(nil, "ARTWORK")
  U.finish:SetColorTexture(1, 0.82, 0, 0.7)
  -- the own bet's mark (R7, f11): a dark backing under the kodo and a 2 px gold frame over it, a 1 px dark rim outside
  U.back = U.track:CreateTexture(nil, "OVERLAY", nil, 0)
  U.back:SetColorTexture(0, 0, 0, 0.6)
  U.back:Hide()
  U.frame = {}
  for j = 1, 4 do
    U.frame[j] = U.track:CreateTexture(nil, "OVERLAY", nil, 2)
    U.frame[j]:SetColorTexture(1, 0.82, 0, 1)
    U.frame[j]:Hide()
  end
  for i = 1, 6 do
    local L = { row = CreateFrame("Frame", nil, U.raceBox) }
    L.lit = L.row:CreateTexture(nil, "BACKGROUND")
    L.lit:SetAllPoints(L.row)
    M.Kit.Atlas(L.lit, "common-list-hoverbg-mid", { 1, 1, 1, 0.08 })
    L.num = label(L.row)
    grey(L.num)
    L.num:SetPoint("LEFT", L.row, "LEFT", 4, 0)
    L.name = label(L.row, "GameFontHighlight")
    L.name:SetPoint("LEFT", L.row, "LEFT", 18, 0)
    L.pays = label(L.row)
    L.pays:SetJustifyH("RIGHT")
    L.pays:SetWidth(28)
    L.pays:SetPoint("RIGHT", L.row, "RIGHT", -6, 0)
    L.runner = U.track:CreateTexture(nil, "OVERLAY", nil, 1)
    -- its number on U.marks (over the track's regions), at the icon's top-left + (1, -1), outlined to read on the map
    L.mark = label(U.marks, "GameFontNormalSmall")
    L.mark:SetPoint("TOPLEFT", L.runner, "TOPLEFT", 1, -1)
    local file, height = L.mark:GetFont()
    if file then L.mark:SetFont(file, height, "OUTLINE") end
    U.lanes[i] = L
  end
  U.track:SetScript("OnUpdate", function(self, elapsed)
    if not self:IsShown() then return end
    U.acc = U.acc + (elapsed or 0)
    if U.acc < THROTTLE then return end
    U.acc = 0
    M.Safe(tick)
  end)

  -- under the lanes: the clock bar and your bet (running), or the result and its buttons (finished)
  U.bar = M.Kit.StatBar(holder) or CreateFrame("Frame", nil, holder)
  U.bar:SetHeight(29)
  local inner = U.bar.fill or U.bar
  U.barFill = inner:CreateTexture(nil, "ARTWORK")
  U.barFill:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, 0)
  U.barFill:SetPoint("BOTTOMLEFT", inner, "BOTTOMLEFT", 0, 0)
  M.Kit.Atlas(U.barFill, "common-stat-bar-green", { 0.12, 0.55, 0.12, 1 })
  -- The clock text on a frame one level above the fill's frame (a child frame draws over its parent's regions), with
  -- an outline so it reads on the green (a4).
  local over = CreateFrame("Frame", nil, U.bar)
  over:SetAllPoints(U.bar)
  over:SetFrameLevel(inner:GetFrameLevel() + 1)
  U.barText = label(over)
  U.barText:SetPoint("CENTER", U.bar, "CENTER", 0, 0)
  local file, height = U.barText:GetFont()
  if file then U.barText:SetFont(file, height, "OUTLINE") end
  U.betHead = label(holder, "GameFontNormal")
  U.betHead:SetText("Your bet")
  U.betLine = label(holder, "GameFontHighlight")
  U.result = label(holder, "GameFontNormalLarge")
  U.detail = label(holder)
  grey(U.detail)
  U.again = button(holder, "Watch again", 110)
  U.again:SetScript("OnClick", function() M.Safe(watch, U.race and U.race.hour) end)
  U.betOn = button(holder, "Bet on", 130) -- holds "Bet on 22:00 UTC" (f7220)
  U.betOn:SetScript("OnClick", function()
    U.replay = nil
    M.Safe(U.Draw)
  end)
  reasonTip(U.betOn)
  -- a replay only: jump to its finished view (f7215)
  U.skip = button(holder, "Skip to result", 120)
  U.skip:SetScript("OnClick", function()
    M.Safe(function()
      local t = ns.RaceClock()
      if U.replay and type(t) == "number" then U.replay.t0 = t - RUN end
      U.Draw()
    end)
  end)
end

local function buildBetting(holder)
  U.betBox = CreateFrame("Frame", nil, holder)
  U.fieldHead = header(U.betBox, "The field")
  U.fieldHead:SetPoint("TOPLEFT", U.betBox, "TOPLEFT", 0, 0)
  U.fieldHead.note:SetText("pays")
  for i = 1, 6 do
    local f = CreateFrame("Button", nil, U.betBox)
    f.sel = f:CreateTexture(nil, "BACKGROUND")
    f.sel:SetAllPoints(f)
    M.Kit.Atlas(f.sel, "common-button-list-small-selected", { 1, 0.82, 0, 0.15 })
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetPoint("LEFT", f, "LEFT", 6, 0)
    f.name = label(f, "GameFontHighlight")
    f.name:SetPoint("LEFT", f, "LEFT", 38, 0)
    f.pays = label(f, "GameFontHighlight")
    f.pays:SetJustifyH("RIGHT")
    f.pays:SetWidth(50)
    f.pays:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    M.Kit.ListHover(f)
    f:SetScript("OnClick", function() M.Safe(pick, i) end)
    U.field[i] = f
  end
  U.stakeHead = label(U.betBox, "GameFontNormal")
  U.stakeHead:SetText("Your stake")
  U.box = M.Kit.InputBox(U.betBox, 74, 74) or CreateFrame("EditBox", nil, U.betBox)
  U.box:SetAutoFocus(false)
  U.box:SetNumeric(true)
  U.box:SetText(DEFAULT_STAKE)
  U.box:SetScript("OnTextChanged", function(_, user)
    if user then
      U.text = nil
      M.Safe(U.Draw)
    end
  end)
  U.box:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    M.Safe(bet)
  end)
  U.box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  U.stakes = {}
  for i, n in ipairs(STAKES) do
    U.stakes[i] = button(U.betBox, tostring(n), 44)
    U.stakes[i]:SetScript("OnClick", function() M.Safe(setStake, n) end)
  end
  U.betBtn = button(U.betBox, "Pick a kodo", 156)
  U.betBtn:SetScript("OnClick", function() M.Safe(bet) end)
  U.hint = label(U.betBox)
  grey(U.hint)
  U.msg = label(U.betBox)
  U.msg:SetTextColor(1, 0.282, 0.282)
  U.cancel = button(U.betBox, "Cancel bet", 110)
  U.cancel:SetScript("OnClick", function() M.Safe(cancel) end)

  -- Earlier races: plain rows (built after the field, so a field name is found first)
  U.list = CreateFrame("Frame", nil, holder)
  U.listHead = header(U.list, "Earlier races")
  U.listHead:SetPoint("TOPLEFT", U.list, "TOPLEFT", 0, 0)
  for i = 1, EARLIER do
    local row = CreateFrame("Frame", nil, U.list)
    row.time = label(row, "GameFontHighlight")
    row.time:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -5)
    row.time:SetWidth(44) -- "21:00 UTC" stays left of the name at 52 (f7220)
    row.time:SetWordWrap(false)
    row.name = label(row, "GameFontHighlight")
    row.name:SetWordWrap(false)
    row.result = label(row)
    row.result:SetWordWrap(false)
    row.watch = button(row, "Watch", 64)
    row.watch:SetScript("OnClick", function() M.Safe(watch, row.hour) end)
    U.rows[i] = row
  end
end

local function build(holder)
  U.holder = holder
  local title = label(holder, "GameFontHighlightLarge") -- white, as Harvest and the mock (v1)
  title:SetPoint("TOPLEFT", holder, "TOPLEFT", LEFT, -4)
  title:SetText("Kodo races")
  U.sub = label(holder)
  grey(U.sub)
  U.sub:SetPoint("TOPLEFT", holder, "TOPLEFT", LEFT, -26)
  buildRace(holder)
  buildBetting(holder)
  U.last = buildBoard(holder, "Last race")
  U.last.parent = holder
  U.big = buildBoard(holder, "Biggest wins")
  U.big.parent = holder
  U.grain = holder:CreateTexture(nil, "ARTWORK")
  U.grain:SetTexture(GRAIN_ICON)
  U.grain:SetSize(16, 16)
  U.purse = label(holder, "GameFontHighlight")
  U.note = label(holder)
  grey(U.note)
  holder:HookScript("OnHide", function()
    U.replay = nil
    U.box:ClearFocus()
  end)
  holder:HookScript("OnSizeChanged", function() M.Safe(U.Draw) end)
end

ns.Races = {
  Build = build,
  Refresh = function()
    if U.holder then U.Draw() end
  end,
  RowLayout = rowLayout,
  PathAt = pathAt,
}
