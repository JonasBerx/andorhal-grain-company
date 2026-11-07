-- GuildSyncGames Stables.lua (run r-20261107-games-more-to-buy-with-grain-escort-bone, Task 6): the Stables view on
-- the Kodo races page, ns.StablesView. Races.lua swaps it in for the race views through the title-row button. Left:
-- the twelve kodos (GC.ROSTER order) with icon, name and this hour's share price; a click picks a row, the held kodo's
-- name is gold. Right: the holding (shares, worth, dividends paid), the lock line, Buy 1, Buy 5, Sell all, Exchange
-- and the message line. ns.Stable, ns.StableBuy, ns.StableSell and ns.StableExchange are looked up at call time
-- (f7165: Demo.lua wraps them, tests replace them). The lock shows the time left from ns.Now(), never the clock
-- library (f6); no division by a variable (games_static).

local _, ns = ...

if not ns.M then return end
local M, GC, SC = ns.M, ns.GrainCore, ns.StablesCore

local LEFT, TOP, GAP = 8, 46, 12
local BIG = { rh = 22, rw = 240 }
local SMALL = { rh = 19, rw = 200 } -- below 420 tall, as Vendor.lua
local BTN_GAP = 8
local GOLD, WHITE = { 1, 0.82, 0 }, { 1, 1, 1 }
local REFUSE = {
  other = "You hold shares in another kodo. Sell or exchange first.",
  cap = "Twenty shares is the most.",
  same = "You hold this kodo already.",
  none = "You hold no shares.",
  running = "A race is running. Try again in a moment.",
  kodo = "Pick a kodo first.",
  count = "Buy 1 or 5 shares at a time.",
  short = "Not enough grain in the purse.",
  clock = "No server clock yet; try again in a moment.",
  demo = "Demo: nothing is saved.",
}

local OOPS = "That did not go through; try again in a moment."

local V = { rows = {} }

local label, button, fmt = ns.UI.label, ns.UI.button, ns.UI.fmt

-- "23 h 53 min" / "10 min" until ns.Now() value t, minutes rounded up (Harvest.lua's left helper): the lock is
-- 24 h, so a bare clock time would read as later today (review f3).
local function left(t)
  local now = ns.Now()
  local mins = math.ceil(math.max(0, t - (type(now) == "number" and now or t)) / 60)
  local hrs = math.floor(mins / 60)
  mins = mins - hrs * 60
  return hrs > 0 and (hrs .. " h " .. mins .. " min") or (mins .. " min")
end

local function refusal(why)
  if why == "locked" then
    local st = ns.Stable()
    local h = st and st.holding
    if h and type(h.opensAt) == "number" then return "You can change kodo in " .. left(h.opensAt) .. "." end
    return "You can change kodo later."
  end
  return REFUSE[why] or OOPS -- a refused credit answers no code (security re-check): never "nil" or a bare code
end

local function act(fn, ...)
  local ok, why = fn(...)
  V.text = (not ok) and refusal(why) or nil
  if V.holder then V.draw() end
end

function V.build(holder)
  V.holder = holder
  V.box = CreateFrame("Frame", nil, holder)
  V.box:SetAllPoints(holder)
  for k = 1, #GC.ROSTER do
    local f = CreateFrame("Button", nil, V.box)
    f.sel = f:CreateTexture(nil, "BACKGROUND")
    f.sel:SetAllPoints(f)
    M.Kit.Atlas(f.sel, "common-button-list-small-selected", { 1, 0.82, 0, 0.15 })
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.name = label(f, "GameFontHighlight")
    f.price = label(f, "GameFontHighlight")
    f.price:SetJustifyH("RIGHT")
    f.price:SetPoint("RIGHT", f, "RIGHT", -6, 0)
    M.Kit.ListHover(f)
    f:SetScript("OnClick", function()
      M.Safe(function()
        V.pick, V.text = k, nil
        V.draw()
      end)
    end)
    V.rows[k] = f
  end
  V.shares = label(V.box, "GameFontNormal")
  V.worth = label(V.box, "GameFontHighlight")
  V.paid = label(V.box)
  V.lock = label(V.box)
  V.fee = label(V.box)
  V.cost = label(V.box)
  V.buy1 = button(V.box, "Buy 1", 90)
  V.buy1:SetScript("OnClick", function() M.Safe(act, ns.StableBuy, V.pick, 1) end)
  V.buy5 = button(V.box, "Buy 5", 90)
  V.buy5:SetScript("OnClick", function() M.Safe(act, ns.StableBuy, V.pick, 5) end)
  V.sell = button(V.box, "Sell all", 90)
  V.sell:SetScript("OnClick", function() M.Safe(act, ns.StableSell) end)
  V.swap = button(V.box, "Exchange", 90)
  V.swap:SetScript("OnClick", function() M.Safe(act, ns.StableExchange, V.pick) end)
  V.msg = label(V.box)
  V.box:Hide() -- shown by the first Draw
end

function V.draw()
  local W, small = V.W or 726, V.small
  local S = small and SMALL or BIG
  local st = ns.Stable()
  local held = st and st.holding
  if V.pick == nil and held then V.pick = held.kodo end
  V.box:Show()
  local rx = W - S.rw - LEFT
  local colW = rx - GAP - LEFT
  for k, f in ipairs(V.rows) do
    local e = GC.ROSTER[k]
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", V.box, "TOPLEFT", LEFT, -(TOP + (k - 1) * S.rh))
    f:SetSize(colW, S.rh)
    f.icon:SetSize(S.rh - 4, S.rh - 4)
    f.icon:ClearAllPoints()
    f.icon:SetPoint("LEFT", f, "LEFT", 6, 0)
    f.icon:SetTexture(e.icon)
    f.name:ClearAllPoints()
    f.name:SetPoint("LEFT", f, "LEFT", S.rh + 8, 0)
    f.name:SetText(e.name)
    local c = (held and held.kodo == k) and GOLD or WHITE
    f.name:SetTextColor(c[1], c[2], c[3])
    local p = st and st.prices and st.prices[k]
    f.price:SetText(p and (fmt(p) .. " grain") or "")
    f.sel:SetShown(V.pick == k)
    f:Show()
  end

  V.paid:SetText(st and ("Dividends paid: " .. fmt(st.total or 0) .. " grain") or "")
  if not st then
    V.shares:SetText(REFUSE.clock)
    V.worth:SetText("")
    V.lock:SetText("")
  elseif held then
    V.shares:SetText(held.shares .. " shares in " .. tostring(held.name))
    V.worth:SetText("Worth " .. fmt(held.value) .. " grain if sold now")
    V.lock:SetText(held.locked and ("Sell or exchange in " .. left(held.opensAt)) or "Sell or exchange any time")
  else
    V.shares:SetText(REFUSE.none)
    V.worth:SetText("Pick a kodo and buy shares; each race it wins pays you.")
    V.lock:SetText("")
  end
  local prev
  -- the picked kodo's Buy 1 and Buy 5 cost with the fee (review f4)
  local pp = st and st.prices and V.pick and st.prices[V.pick]
  -- two short lines, each one line inside the 200 px column at the dearest price (fix round 2)
  V.fee:SetText("Prices plus a 10% fee.")
  V.cost:SetText(pp and ("Buy 1: " .. fmt(SC.BuyCost(1, pp)) .. ", Buy 5: " .. fmt(SC.BuyCost(5, pp))) or "")
  for _, fs in ipairs({ V.shares, V.worth, V.paid, V.lock, V.fee, V.cost }) do
    fs:ClearAllPoints()
    fs:SetWidth(S.rw)
    if prev then
      fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
    else
      fs:SetPoint("TOPLEFT", V.box, "TOPLEFT", rx, -TOP)
    end
    prev = fs
  end
  local bw = (S.rw - BTN_GAP) * 0.5
  for i, b in ipairs({ V.buy1, V.buy5, V.sell, V.swap }) do
    b:SetSize(bw, 22)
    b:ClearAllPoints()
    if i == 1 then
      b:SetPoint("TOPLEFT", V.cost, "BOTTOMLEFT", 0, -10)
    elseif i == 3 then
      b:SetPoint("TOPLEFT", V.buy1, "BOTTOMLEFT", 0, -6)
    else
      b:SetPoint("TOPLEFT", i == 2 and V.buy1 or V.sell, "TOPRIGHT", BTN_GAP, 0)
    end
  end
  V.msg:ClearAllPoints()
  V.msg:SetWidth(S.rw)
  V.msg:SetPoint("TOPLEFT", V.sell, "BOTTOMLEFT", 0, -8)
  V.msg:SetText(V.text or "")
end

ns.StablesView = {
  Build = function(holder) if not V.box then V.build(holder) end end,
  -- Draws the view into the holder at W x H (small: below 420 tall).
  Draw = function(holder, W, H, small)
    if not V.box then V.build(holder) end
    V.W, V.H, V.small = W, H, small
    V.draw()
  end,
  Hide = function()
    if V.box then V.box:Hide() end
    V.text = nil
  end,
}
