-- GuildSyncGames Home.lua (o2650 Task 2): the Games home, one card per game in two rows (d1963). Row 1: "Grain" over
-- Harvest and Kodo races, "Company" over one wide Company card; row 2: "Daily puzzles" over WoWdle, Vendor price,
-- Flights and Who said it? (Who only while its ns.GAMES entry is shown). Copy from the approved mock (mock-copy.md, d1964
-- the Harvest standing bar, d1965 the small forms, d1966 no "The caravan is back" line).
-- ns.Home.Build(frame, shownKeys) makes every region; ns.Home.Draw(frame) only sets text, values, places and visibility
-- (f12). Small is the frame's height under SMALL_BELOW. ns.HomeCard(id, small) answers one card's today data.
-- Task 9 (d2049): Harvest's pill reads "Bonemeal" (gold) while it runs on a field that is not full; line 3: Kodo races
-- "Stables: <n> shares in <name>" while held, a daily "<n> grain won today · lucky charm" with the day's charm on.
-- Seam rule (R3, as Vendor.lua and Races.lua): every ns.* reader is looked up when called, never cached at load, so
-- Demo.lua's wrappers reach the home. WoWdle shows counts only: never a letter or the word. Who shows no dialogue text.
-- No division by a variable (games_static).

local _, ns = ...

if not ns.M then return end
local M = ns.M

local SMALL_BELOW = 420
local BIG = { margin = 11, gap = 8, header = 26, rowGap = 10, cardH = 186, pad = 10, icon = 36, play = 64 }
local SMALL = { margin = 8, gap = 6, header = 24, rowGap = 6, pad = 6, icon = 28, play = 40 }
local BAR_BIG, BAR_SMALL = 0.62, 0.55 -- d1967: Kit.StatBar's scale on a card
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GOLD = { 1, 0.769, 0.251 }
local GREY = 0.6
local LINES = 3 -- today lines per card, at most
local PUZZLE = "Ten a day \194\183 up to 75 grain"
local DOT = " \194\183 "

-- id -> row, column, columns wide, name, kind line, icon, the line count the bar follows (nil: no bar)
local CARDS = {
  { id = "harvest", row = 1, col = 1, span = 1, name = "Harvest", kind = "Your field, the caravan", icon = 134058, bar = 0 },
  { id = "races", row = 1, col = 2, span = 1, name = "Kodo races", kind = "A race every hour", icon = 132245 },
  { id = "company", row = 1, col = 3, span = 2, name = "Company", icon = "Interface\\Icons\\INV_Crate_04", bar = 1,
    kind = "Spend grain on looks, the guild granary and the weekly lottery." },
  { id = "wowdle", row = 2, col = 1, span = 1, name = "WoWdle", kind = "A word a day", icon = "Interface\\Icons\\INV_Misc_Dice_01" },
  { id = "vendor", row = 2, col = 2, span = 1, name = "Vendor price", kind = PUZZLE, icon = 133784 },
  { id = "flights", row = 2, col = 3, span = 1, name = "Flights", kind = PUZZLE, icon = 132268 },
  { id = "who", row = 2, col = 4, span = 1, name = "Who said it?", kind = PUZZLE, icon = 132333 },
}
local HEADERS = { { text = "Grain", row = 1, col = 1, span = 2 }, { text = "Company", row = 1, col = 3, span = 2 },
  { text = "Daily puzzles", row = 2, col = 1, span = 4 } }

local built = setmetatable({}, { __mode = "k" }) -- home frame -> { cards, headers }

local function fmt(n)
  if ns.UI and ns.UI.fmt then return ns.UI.fmt(n) end
  return tostring(n)
end

local function count(t) return type(t) == "table" and #t or 0 end

-- "2 h 10 min" / "10 min" for seconds left, minutes rounded up (Harvest.lua's left).
local function left(secs)
  local mins = math.ceil(secs / 60)
  local hrs = math.floor(mins / 60)
  mins = mins - hrs * 60
  return hrs > 0 and (hrs .. " h " .. mins .. " min") or (mins .. " min")
end

-- ---------- one card's today data ----------

local function wowdle()
  local today = ns.Today and ns.Today()
  local out = { lines = {} }
  local L = out.lines
  if type(today) ~= "table" then
    L[1] = "No word today yet."
    out.status, out.tone = "Not ready", "grey"
  elseif today.done then
    L[1] = tostring(today.label) .. " is done."
    if today.won then out.status, out.tone = "Solved", "green" else out.status, out.tone = "Done", "grey" end
  else
    L[1] = tostring(today.label) .. DOT .. "try " .. (count(today.rows) + 1) .. " of 6" .. DOT .. tostring(today.len)
      .. " letters"
    out.status, out.tone = count(today.rows) > 0 and "Started" or "Waiting", "gold"
  end
  local gt = ns.GuildToday and ns.GuildToday()
  L[#L + 1] = "Today in the guild: " .. count(gt) .. " played"
  local st = ns.Stats and ns.Stats()
  if type(st) == "table" then L[#L + 1] = "Streak " .. tostring(st.cur or 0) .. DOT .. "best " .. tostring(st.best or 0) end
  return out
end

-- Vendor price, Flights (pool "flights") and Who said it? (verb "heard").
local function daily(today, guild, verb, small)
  local out = { lines = {} }
  if type(today) ~= "table" then
    out.status, out.tone = "Not ready", "grey"
    return out
  end
  local L = out.lines
  local picks = type(today.picks) == "string" and #today.picks or 0
  if today.done then
    L[1] = tostring(today.label) .. " done, " .. tostring(today.score or 0) .. "/10."
    out.status, out.tone = small and "Done" or "Done today", "green"
  else
    L[1] = tostring(today.label) .. ": " .. picks .. " of 10 " .. verb
    out.status, out.tone = picks == 0 and "Waiting" or "Started", "gold"
  end
  L[2] = "Today in the guild: " .. count(guild) .. " done"
  L[3] = tostring(today.earned or 0) .. " grain won today" .. (today.charm == true and (DOT .. "lucky charm") or "")
  return out
end

local function harvest(small)
  local out = { lines = {}, status = "Growing", tone = "gold" } -- o2660: a growing field is the normal state
  local farm = ns.Farm and ns.Farm()
  if type(farm) ~= "table" then return out end
  local standing, cap = tonumber(farm.standing) or 0, tonumber(farm.cap) or 0
  if cap > 0 then
    out.bar = { value = standing, max = cap, text = standing .. " / " .. cap .. " grain" } -- o2659, as the Company bar
    if standing >= cap then out.status, out.tone = small and "Full" or "Field full", "gold" end
  end
  local cur = ns.Caravan and ns.Caravan()
  local now = ns.Now and ns.Now()
  local rest = type(cur) == "table" and type(now) == "number" and (cur.start or 0) + (cur.hours or 0) * 3600 - now or 0
  out.lines[1] = rest > 0 and ("Caravan back in " .. left(rest)) or "No caravan on the road"
  out.lines[2] = tostring(farm.rate or 0) .. " grain a minute"
  local bone = ns.Bonemeal and ns.Bonemeal()
  if out.status == "Growing" and type(bone) == "table" and bone.running then out.status = "Bonemeal" end
  return out
end

local function races(small)
  local out = { lines = {}, status = "Not ready", tone = "grey" }
  local GC = ns.GrainCore
  local t = ns.RaceClock and ns.RaceClock()
  if type(t) ~= "number" or type(GC) ~= "table" then return out end
  local phase, h = GC.Phase(t)
  local label = tostring(ns.RaceLabel and ns.RaceLabel(h) or h)
  local L = out.lines
  if phase == "running" then
    L[1] = "The " .. label .. " race is running"
    out.status, out.tone = small and "Running" or "Running now", "green"
  elseif phase == "finished" then
    local race = GC.Race(h)
    local w = type(race) == "table" and race.field and race.field[race.winner]
    local name = type(w) == "table" and tostring(w.name) or "?"
    L[1] = small and (label .. ": " .. name .. " won") or ("The " .. label .. " race: " .. name .. " won")
    out.status, out.tone = "Finished", "grey"
  else
    L[1] = "The " .. label .. " race takes bets"
    out.status, out.tone = "Bets open", "gold"
  end
  local bet = ns.MyBet and ns.MyBet()
  local kodo
  if type(bet) == "table" and bet.hour == h then
    local race = GC.Race(h)
    kodo = type(race) == "table" and race.field and race.field[bet.lane]
  end
  if type(kodo) == "table" then
    L[2] = small and ("Bet " .. tostring(bet.stake) .. " on " .. tostring(kodo.name))
      or ("Your bet: " .. tostring(bet.stake) .. " grain on " .. tostring(kodo.name))
  else
    local most = 0
    for _, p in ipairs(GC.PAYS or {}) do if p > most then most = p end end
    L[2] = "Bet " .. tostring(GC.BET_MIN) .. " to " .. tostring(GC.BET_MAX) .. " grain, win up to x" .. most
  end
  local st = ns.Stable and ns.Stable()
  local hold = type(st) == "table" and st.holding or nil
  if type(hold) == "table" then L[3] = "Stables: " .. tostring(hold.shares) .. " shares in " .. tostring(hold.name) end
  return out
end

local function company()
  local out = { lines = {}, status = "Sales closed", tone = "grey" }
  local L = out.lines
  local CC = ns.CompanyCore
  local cp = ns.CompanyProjects and ns.CompanyProjects()
  local cur = type(cp) == "table" and cp.current or nil
  local p = cur and type(CC) == "table" and CC.PROJECTS and CC.PROJECTS[cur]
  if type(p) == "table" then
    L[1] = "Granary goal: " .. tostring(p.name)
    local goal = tonumber(cp.goals and cp.goals[cur]) or 0
    local total = tonumber(cp.totals and cp.totals[cur]) or 0
    if goal > 0 then out.bar = { value = total, max = goal, text = fmt(total) .. " / " .. fmt(goal) .. " grain" } end
  end
  local lot = ns.Lottery and ns.Lottery()
  if type(lot) == "table" then
    L[#L + 1] = "Lottery: your tickets " .. count(lot.mine) .. " of 10" .. DOT .. "pot " .. fmt(lot.pot or 0) .. " grain"
    L[#L + 1] = lot.utc and "Draw Sunday 20:00 UTC, sales close 19:00 UTC."
      or "Draw Sunday 20:00 realm time, sales close 19:00."
    if lot.open then out.status, out.tone = "Tickets on sale", "gold" end
  end
  return out
end

function ns.HomeCard(id, small)
  if id == "wowdle" then return wowdle() end
  if id == "harvest" then return harvest(small) end
  if id == "races" then return races(small) end
  if id == "company" then return company() end
  if id == "vendor" or id == "flights" then
    local pool = id == "flights" and "flights" or nil
    return daily(ns.VendorToday and ns.VendorToday(pool), ns.VendorGuild and ns.VendorGuild(pool), "picked", small)
  end
  if id == "who" then
    return daily(ns.WhoToday and ns.WhoToday(), ns.WhoGuild and ns.WhoGuild(), "heard", small)
  end
  return { lines = {}, status = "Not ready", tone = "grey" }
end

-- ---------- Play ----------

local function play(id)
  if id == "vendor" or id == "flights" then
    local pool = id == "flights" and "flights" or nil
    local tab = ns.VendorTab
    if type(tab) == "table" and tab.SetPool then tab.SetPool(pool or "items") end
    local today = ns.VendorToday and ns.VendorToday(pool)
    -- Endless once today's run is done; in demo the daily view (demo starts no run, f7273: VendorMode refuses endless)
    local demo = M.Demo and M.Demo()
    local endless = type(today) == "table" and today.done and not demo
    if ns.VendorMode then ns.VendorMode(endless and "endless" or "daily", pool) end
    if ns.OpenGame then ns.OpenGame("vendor") end
    return
  end
  if ns.OpenGame then ns.OpenGame(id) end
end

-- ---------- build ----------

local function kit(name)
  local K = M.Kit
  return type(K) == "table" and K[name] or nil
end

local function text(parent, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  return fs
end

local function header(frame, h)
  local mk = kit("SectionHeader")
  local f = mk and mk(frame, 100, h.text)
  if not f then
    f = CreateFrame("Frame", nil, frame)
    f.label = text(f, "GameFontNormal")
    f.label:SetPoint("LEFT", f, "LEFT", 4, 0)
    f.label:SetText(h.text)
  end
  return { f = f, h = h }
end

local function buildBar(card, c)
  local mk = kit("StatBar")
  local bar = mk and mk(card, BAR_BIG)
  if not bar then
    bar = CreateFrame("Frame", nil, card)
    bar:SetHeight(29)
    bar:SetScale(BAR_BIG)
  end
  local fill = type(bar.fill) == "table" and bar.fill or bar
  local grow = CreateFrame("StatusBar", nil, fill)
  grow:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
  grow:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
  grow:SetStatusBarTexture(BAR_TEXTURE)
  grow:SetStatusBarColor(GOLD[1], GOLD[2], GOLD[3])
  grow:SetFrameLevel(fill:GetFrameLevel() + 1)
  -- the text on the card (unscaled, readable), one level above the fill
  local top = CreateFrame("Frame", nil, card)
  top:SetAllPoints(bar)
  top:SetFrameLevel(grow:GetFrameLevel() + 1)
  local barText = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  barText:SetPoint("CENTER", top, "CENTER", 0, 0)
  -- outlined, so white stays readable on the gold fill (A#f3, as Harvest.lua's bar)
  local file, size = barText:GetFont()
  if file then barText:SetFont(file, size, "OUTLINE") end
  c.bar, c.grow, c.barTop, c.barText = bar, grow, top, barText
end

local function buildCard(frame, def)
  local mk = kit("Card")
  local card = mk and mk(frame, 100, 100)
  if not card then card = CreateFrame("Frame", nil, frame) end
  local c = { def = def, card = card, lines = {} }
  c.icon = card:CreateTexture(nil, "ARTWORK")
  c.icon:SetTexture(def.icon)
  c.name = text(card, "GameFontNormal")
  c.name:SetText(def.name)
  c.name:SetWordWrap(false)
  c.kind = text(card)
  c.kind:SetTextColor(GREY, GREY, GREY)
  c.kind:SetWordWrap(true)
  c.kind:SetMaxLines(2)
  c.kind:SetText(def.kind)
  for i = 1, LINES do
    local fs = text(card)
    fs:SetWordWrap(true)
    fs:SetMaxLines(2)
    c.lines[i] = fs
  end
  if def.bar then buildBar(card, c) end
  local pill = kit("Pill")
  c.pill = pill and pill(card, "", "grey")
  if not c.pill then
    c.pill = CreateFrame("Frame", nil, card)
    c.pill:SetHeight(21)
    c.pill:SetWidth(70)
    c.pill.text = c.pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    c.pill.text:SetPoint("CENTER", 0, 1)
  end
  c.play = ns.UI.button(card, "Play", BIG.play)
  c.play:SetScript("OnClick", function() M.Safe(play, def.id) end)
  -- the hover: the whole card opens the game (A#f1). An ordinary layer shown by OnEnter: a Frame draws no HIGHLIGHT
  local hover = card:CreateTexture(nil, "ARTWORK")
  hover:SetAllPoints(card)
  local atlas = kit("Atlas")
  if not (atlas and atlas(hover, "Options_List_Hover", { 1, 1, 1, 0.08 })) then hover:SetColorTexture(1, 1, 1, 0.08) end
  hover:Hide()
  card:SetScript("OnEnter", function() M.Safe(hover.Show, hover) end)
  card:SetScript("OnLeave", function() M.Safe(hover.Hide, hover) end)
  card:EnableMouse(true)
  card:SetScript("OnMouseUp", function(_, button) if button == "LeftButton" then M.Safe(play, def.id) end end)
  return c
end

-- ---------- draw ----------

local function setPill(pill, status, tone)
  local set = kit("SetPill")
  if set then set(pill, status, tone) elseif pill.text then pill.text:SetText(status) end
end

local function unscale(v, small) if small then return v / BAR_SMALL end return v / BAR_BIG end

local function drawCard(c, L, small, x, y, w, h)
  local card, def, pad = c.card, c.def, L.pad
  card:ClearAllPoints()
  card:SetPoint("TOPLEFT", c.home, "TOPLEFT", x, y)
  card:SetSize(w, h)
  local inner = w - 2 * pad
  c.icon:ClearAllPoints()
  c.icon:SetSize(L.icon, L.icon)
  c.icon:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -pad)
  c.name:ClearAllPoints()
  c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", pad, 0)
  c.name:SetWidth(inner - L.icon - pad)
  local wide = def.span > 1
  c.kind:ClearAllPoints()
  local top -- the first today line's place: { relative frame, y } or nil for under the kind line
  if wide then
    c.kind:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -2)
    c.kind:SetWidth(inner - L.icon - pad)
    c.kind:Show()
    -- small: the kind line keeps to one row (cut with "...", as the approved mock) and the lines start under it (R#f1)
    c.kind:SetMaxLines(small and 1 or 2)
    top = pad + math.max(L.icon, small and 28 or 42) + 2
  elseif small then
    c.kind:Hide()
    top = pad + L.icon + 4
  else
    c.kind:SetPoint("TOPLEFT", card, "TOPLEFT", pad, -(pad + L.icon + 4))
    c.kind:SetWidth(inner)
    c.kind:Show()
  end
  local d = ns.HomeCard(def.id, small)
  local lines = type(d) == "table" and type(d.lines) == "table" and d.lines or {}
  local shown = small and math.min(#lines, 2) or #lines
  local prev = (not top) and c.kind or nil
  local function place(r, scaled)
    r:ClearAllPoints()
    local x0, y0, rel, rp = 0, -2, prev, "BOTTOMLEFT"
    if not prev then x0, y0, rel, rp = pad, -top, card, "TOPLEFT" end
    if scaled then x0, y0 = unscale(x0, small), unscale(y0, small) end
    r:SetPoint("TOPLEFT", rel, rp, x0, y0)
    prev = r
  end
  local function drawBar()
    if not c.bar then return end
    local b = type(d) == "table" and d.bar or nil
    if b and b.max > 0 then
      c.bar:SetScale(small and BAR_SMALL or BAR_BIG)
      c.bar:SetWidth(unscale(inner, small))
      place(c.bar, true)
      c.grow:SetMinMaxValues(0, b.max)
      c.grow:SetValue(b.value)
      c.barText:SetText(b.text)
      c.bar:Show()
      c.barTop:Show()
    else
      c.barText:SetText("")
      c.bar:Hide()
      c.barTop:Hide()
    end
  end
  if def.bar == 0 then drawBar() end
  for i, fs in ipairs(c.lines) do
    if i <= shown then
      fs:SetWidth(inner)
      fs:SetText(lines[i])
      place(fs)
      fs:Show()
    else
      fs:SetText("")
      fs:Hide()
    end
    if def.bar == i then drawBar() end
  end
  if def.bar and def.bar > #c.lines then drawBar() end
  c.pill:ClearAllPoints()
  c.pill:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", pad, pad)
  setPill(c.pill, type(d) == "table" and d.status or "", type(d) == "table" and d.tone or "grey")
  c.play:ClearAllPoints()
  c.play:SetWidth(L.play)
  c.play:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -pad, pad)
end

local function draw(frame)
  local B = built[frame]
  if not B or (frame.IsShown and not frame:IsShown()) then return end -- a shown game: the home reads nothing
  local w, h = frame:GetWidth(), frame:GetHeight()
  if type(w) ~= "number" or w <= 0 then w = 726 end
  if type(h) ~= "number" or h <= 0 then h = 460 end
  local small = h < SMALL_BELOW
  local L = small and SMALL or BIG
  local cardH = math.floor((h - 2 * L.margin - 2 * L.header - L.rowGap) / 2)
  if L.cardH and cardH > L.cardH then cardH = L.cardH end
  local colW = (w - 2 * L.margin - 3 * L.gap) / 4
  local function x(col) return L.margin + (col - 1) * (colW + L.gap) end
  local function width(span) return span * colW + (span - 1) * L.gap end
  local function y(row) return -L.margin - (row - 1) * (L.header + cardH + L.rowGap) end
  for _, hd in ipairs(B.headers) do
    hd.f:ClearAllPoints()
    hd.f:SetPoint("TOPLEFT", frame, "TOPLEFT", x(hd.h.col), y(hd.h.row))
    hd.f:SetSize(width(hd.h.span), L.header)
  end
  for _, c in ipairs(B.cards) do
    local def = c.def
    M.Safe(drawCard, c, L, small, x(def.col), y(def.row) - L.header, width(def.span), cardH)
  end
end

local function build(frame, shownKeys)
  if built[frame] then return end
  shownKeys = type(shownKeys) == "table" and shownKeys or {}
  local B = { cards = {}, headers = {} }
  for _, h in ipairs(HEADERS) do B.headers[#B.headers + 1] = header(frame, h) end
  for _, def in ipairs(CARDS) do
    if shownKeys[def.id] then
      local c = buildCard(frame, def)
      c.home = frame
      B.cards[#B.cards + 1] = c
    end
  end
  built[frame] = B
  local on = function() M.Safe(draw, frame) end
  if frame.HookScript then frame:HookScript("OnSizeChanged", on) else frame:SetScript("OnSizeChanged", on) end
end

ns.Home = { Build = build, Draw = draw }
