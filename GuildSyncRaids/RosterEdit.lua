local _, ns = ...
if not ns.M then return end
-- RosterEdit.lua: ticket 56 stage C. The "roster" owner card, registered in ns.Cards at load (end of file):
-- a held roster (read only, for everyone), the New roster form and the draft editor (officers only). Drafts live in
-- GuildSyncRaidsDB.drafts, made at the first saved change only; in demo they live in a table in memory. Nothing here
-- shares or sends: Publish stays disabled until the next version.

local M = ns.M
local K = M.Kit
local R = ns.RosterRules
local T = K.Tokens.text -- a text role is read in a function only (made on the first read)

local HINT = "Click a seat, then another, to swap them. Right-click a seat for more."
local FORM_HINT = "Name the roster, pick its size and raid, then press Make draft."
local NOTE = "sharing starts in the next version"
local GONE = "This roster is gone."
local ARRIVING = "This roster is still arriving."
local UNREADABLE = "This draft cannot be read."
local SAFE_WHY = "That did not work; see /gsync errors."
local ROLES = { { "T", "Tank" }, { "H", "Healer" }, { "D", "DPS" }, { "", "Not set" } }

local open           -- { kind = "held"|"draft"|"new", id } or nil (D1)
local sel            -- the chosen place { g, s } in the editor, or nil
local form = { size = 40 } -- the New roster form's size and raid ({ id, finish } or nil)
local E = {}         -- the card's pieces, made by build
local memory = {}    -- the demo store (D9): never ns.DB()

local function esc(s) return ns.Escape(tostring(s or "")) end
local function now()
  local t = M.Compat.call("GetServerTime")
  return tonumber(t) or 0
end
local function color(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end
local function demo() return type(ns.DemoData) == "function" and ns.DemoData() ~= nil end
local function officer() return ns.IsOfficer(ns.MyKey()) and true or false end

-- ---------- the store (D7) ----------

-- Read only: never creates the key.
local function drafts()
  if demo() then return memory end
  local db = ns.DB()
  local t = db and db.drafts
  return type(t) == "table" and t or {}
end

-- The first committed change makes the key.
local function writable()
  if demo() then return memory end
  local db = ns.DB()
  if type(db.drafts) ~= "table" then db.drafts = {} end
  return db.drafts
end

-- { key, id, name, size } per draft, sorted by name then key, the first R.MAX_DRAFTS; key is the table key (opened
-- and discarded by it, whatever the draft's own id field holds).
function ns.RosterDrafts()
  local out = {}
  if not officer() then return out end
  for k, d in pairs(drafts()) do
    if type(d) == "table" then out[#out + 1] = { key = k, id = d.id, name = d.name, size = d.size } end
  end
  table.sort(out, function(a, b)
    local an, bn = tostring(a.name or ""), tostring(b.name or "")
    if an ~= bn then return an < bn end
    return tostring(a.key) < tostring(b.key)
  end)
  for i = #out, R.MAX_DRAFTS + 1, -1 do out[i] = nil end
  return out
end

-- The open draft, or nil (not open, gone, or no longer an officer).
local function current()
  if not (open and open.kind == "draft" and officer()) then return nil end
  local d = drafts()[open.id]
  return type(d) == "table" and d or nil
end

local function redraw() ns.RefreshPage() end

local commitName -- the name box's text into the open draft (below)

function ns.OpenRoster(kind, id)
  if kind ~= "held" and kind ~= "draft" and kind ~= "new" then return nil, "kind" end
  if kind ~= "held" and not officer() then return nil, "officer" end
  -- Typed, unsaved text goes to the draft it was typed into before another roster opens (review f1).
  if E.name then M.Safe(commitName) end
  open, sel, E.err = { kind = kind, id = id }, nil, nil
  if kind == "new" then form = { size = 40 } end
  if E.name then
    local d = current()
    E.name:SetText(d and tostring(d.name or "") or "")
  end
  if E.add then E.add:SetText("") end
  if ns.PageState.card == "roster" then redraw() return true end
  return ns.ShowCard("roster")
end

-- D18: every editor callback runs only for an officer with a draft still open (or the New roster form); fn(d, ...)
-- answers true or nil, reason; the reason shows on the error line, then the card redraws.
-- With key, the callback runs only while that draft is still the open one (a menu made for one draft does nothing
-- once another roster is open). A throw is recorded by M.Safe and shows SAFE_WHY. A callback that closed the card
-- (Discard) has redrawn already.
local function edit(fn, key)
  return function(...)
    if not officer() then return end
    if key ~= nil and not (open and open.kind == "draft" and open.id == key) then return end
    local d = current()
    if not d and not (open and open.kind == "new") then return end
    local n, args = select("#", ...), { ... }
    local ran = false
    M.Safe(function()
      local good, why = fn(d, unpack(args, 1, n))
      E.err = (not good) and why or nil
      ran = true
    end)
    if not ran then E.err = SAFE_WHY end
    if open then redraw() end
  end
end

-- ---------- context for the rules ----------

local function linked(view, id)
  if id == nil then return nil end
  for _, ev in ipairs(view.events or {}) do if ev.id == id then return ev end end
  return nil
end

local function ctxFor(d)
  local view = ns.View()
  local ev = linked(view, d and d.event)
  local lineups = {}
  for _, l in pairs(view.lineupOf or {}) do lineups[#lineups + 1] = l end
  return { keyFn = ns.Key, signups = ev and ev.signups or nil, lineups = lineups, rows = ns.Roster() }
end

local function heldKeys(view)
  local out = {}
  for _, l in ipairs(view.lineups or {}) do out[l.key] = true end
  return out
end

-- ---------- menus ----------

local function curSize()
  local d = current()
  return d and d.size or form.size
end

local function curEvent()
  local d = current()
  if d then return d.event end
  return form.event and form.event.id
end

local function sizeMenu(owner)
  K.Menu(owner, function(_, root)
    for _, n in ipairs({ 10, 20, 40 }) do
      root:CreateRadio(n .. " players", function(v) return curSize() == v end, edit(function(d, v)
        if d then
          sel = nil
          return R.Resize(d, v)
        end
        form.size = v
        return true
      end), n)
    end
  end)
end

local function raidMenu(owner)
  local view = ns.View()
  K.Menu(owner, function(_, root)
    root:CreateRadio("No raid", function(v) return (curEvent() or "") == v end, edit(function(d)
      if d then return R.Link(d, nil, drafts()) end
      form.event = nil
      return true
    end), "")
    for _, ev in ipairs(view.events or {}) do
      local text = esc(ev.title) .. " " .. ns.When("%a %d %b", ev.start)
      root:CreateRadio(text, function(v) return curEvent() == v end, edit(function(d)
        local link = { id = ev.id, finish = ev.finish }
        if d then return R.Link(d, link, drafts()) end
        form.event = link
        return true
      end), ev.id)
    end
  end)
end

local function paintStatus()
  local text, col = E.err, ns.ORANGE
  if text then
    text = esc(text)
  else
    text, col = (open and open.kind == "new") and FORM_HINT or HINT, ns.GREY
  end
  E.hint:SetText(text)
  color(E.hint, col)
end

-- The Add box's matches (D12): one button per match, "No match" when there is none.
local function matchMenu(owner)
  if not officer() then return end
  local d = current()
  if not d then return end
  local key = open.id
  local ctx = ctxFor(d)
  local list, why = R.Matches(E.add:GetText(), d, ctx)
  E.err = why
  paintStatus()
  K.Menu(owner, function(_, root)
    for _, entry in ipairs(list) do
      root:CreateButton(entry.text, edit(function(dd, person)
        local place
        if sel and sel.g > 0 and dd.groups[sel.g] and dd.groups[sel.g][sel.s] == false then place = sel end
        local p, whyAdd = R.Add(dd, person, place, ctxFor(dd))
        if not p then return nil, whyAdd end
        sel = nil
        E.add:SetText("")
        return true
      end, key), entry.value)
    end
    if #list == 0 then root:CreateTitle("No match") end
  end)
end

local function seatMenu(owner, d, place)
  local seat = (place.g == 0) and d.reserve[place.s] or (d.groups[place.g] or {})[place.s]
  if type(seat) ~= "table" then return end
  local key = open.id
  K.Menu(owner, function(_, root)
    root:CreateTitle(esc(seat.name))
    for _, field in ipairs({ { "role", "Main role" }, { "off", "Off-spec" } }) do
      root:CreateTitle(field[2])
      for _, r in ipairs(ROLES) do
        root:CreateRadio(r[2], function(v) return (seat[field[1]] or "") == v end, edit(function(dd, v)
          return R.Set(dd, place, field[1], v ~= "" and v or nil)
        end, key), r[1])
      end
    end
    if seat.out then
      root:CreateTitle("Class")
      for _, w in ipairs(R.CLASS_WORDS) do
        root:CreateRadio(w, function(v) return seat.class == v end, edit(function(dd, v)
          return R.Set(dd, place, "class", v)
        end, key), w)
      end
    end
    root:CreateDivider()
    if place.g > 0 then
      root:CreateButton("Move to reserve", edit(function(dd)
        sel = nil
        return R.ToReserve(dd, place)
      end, key))
    end
    root:CreateButton("Remove", edit(function(dd)
      sel = nil
      return R.Remove(dd, place)
    end, key))
  end)
end

local function same(a, b) return a and b and a.g == b.g and a.s == b.s end

local function onSeat(place, button, mouseButton)
  if not officer() then return end
  local d = current()
  if not d then return end
  if mouseButton == "RightButton" then
    seatMenu(button, d, place)
    return
  end
  if sel == nil then
    sel = place
    redraw()
  elseif same(sel, place) then
    sel = nil
    redraw()
  else
    local a = sel
    sel = nil
    edit(function(dd) return R.Swap(dd, a, place) end)()
  end
end

local function confirmDiscard(owner)
  local d = current()
  if not d then return end
  K.Menu(owner, function(_, root)
    root:CreateTitle("Discard " .. esc(d.name) .. "?")
    root:CreateButton("Discard draft", edit(function()
      local good, why = R.Discard(writable(), open.id)
      if not good then return nil, why end
      open, sel = nil, nil
      ns.ShowCard(nil)
      return true
    end))
  end)
end

-- ---------- the card ----------

local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", x, -y)
end

function commitName()
  local d = current()
  if d and E.name:GetText() ~= d.name then
    edit(function(dd) return R.Rename(dd, E.name:GetText()) end)()
  end
end

local function makeDraft()
  edit(function()
    if not (open and open.kind == "new") then return nil end
    local ev = form.event
    local d, why = R.New(drafts(), { name = E.name:GetText(), size = form.size, event = ev and ev.id,
      finish = ev and ev.finish }, now(), heldKeys(ns.View()))
    if not d then return nil, why end
    writable()[d.id] = d
    open, sel = { kind = "draft", id = d.id }, nil
    return true
  end)()
end

local function build(card)
  local body = card.body
  E.title = ns.Label(body, T.highlight)
  E.title:SetWordWrap(false)
  at(E.title, 12, 12)
  E.detail = ns.Label(body, T.highlightSmall)
  E.detail:SetWordWrap(false)
  at(E.detail, 12, 32)
  color(E.detail, ns.GREY)
  E.name = K.InputBox(body, 140, 140)
  E.name:SetText("")
  at(E.name, 12, 12)
  E.name:SetScript("OnEnterPressed", function(self)
    M.Safe(commitName)
    self:ClearFocus()
  end)
  E.name:SetScript("OnEditFocusLost", function() M.Safe(commitName) end)
  E.name:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  E.size = K.Button(body, "40 players", 70, function(self) sizeMenu(self) end)
  at(E.size, 158, 11)
  E.raid = K.Button(body, "No raid", 110, function(self) raidMenu(self) end)
  at(E.raid, 234, 11)
  E.add = K.InputBox(body, 180, 180)
  at(E.add, 12, 40)
  E.add:SetScript("OnEnterPressed", function(self) M.Safe(matchMenu, self) end)
  E.add:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  E.addButton = K.Button(body, "Add", 60, function() matchMenu(E.add) end)
  at(E.addButton, 198, 39)
  E.discard = K.Button(body, "Discard", 80, function(self) confirmDiscard(self) end)
  at(E.discard, 264, 39)
  E.make = K.Button(body, "Make draft", 100, function() makeDraft() end)
  at(E.make, 12, 39)
  E.hint = ns.Label(body, T.highlightSmall)
  E.hint:SetWordWrap(false)
  at(E.hint, 12, 66)
  E.publish = K.Button(body, "Publish", 80, nil, false)
  E.publish:ClearAllPoints()
  E.publish:SetPoint("BOTTOMLEFT", 12, 6)
  E.note = ns.Label(body, T.disable)
  E.note:SetPoint("LEFT", E.publish, "RIGHT", 8, 0)
  E.note:SetText(NOTE)
end

local PARTS = { "title", "detail", "name", "size", "raid", "add", "addButton", "discard", "make", "hint", "publish",
  "note" }

local function showOnly(card, list)
  local on = {}
  for _, k in ipairs(list) do on[k] = true end
  for _, k in ipairs(PARTS) do E[k]:SetShown(on[k] or false) end
  ns.DrawLineup(card, nil)
end

local function gone(card)
  showOnly(card, { "title" })
  E.title:SetText(GONE)
end

local function drawHeld(card, view, rows, L)
  local held
  for _, l in ipairs(view.lineups or {}) do if l.key == open.id then held = l end end
  if not held then return gone(card) end
  showOnly(card, { "title", "detail" })
  E.title:SetText(esc(held.name))
  local ev = linked(view, held.event)
  local detail = tostring(held.size or "?") .. " players"
  if ev then detail = detail .. " \194\183 " .. esc(ev.title) end
  local lineup = view.lineupOf and view.lineupOf[held.key]
  if not lineup then detail = detail .. "\n" .. ARRIVING end
  E.detail:SetText(detail)
  if lineup then ns.DrawLineup(card, lineup, L, 52, { rows = rows }) end
end

local function drawControls(view)
  E.size:SetText(tostring(tonumber(curSize()) or "?") .. " players")
  local id = curEvent()
  local ev = linked(view, id)
  E.raid:SetText(ev and esc(ev.title) or (id and "Linked raid" or "No raid"))
  paintStatus()
end

-- A cheap shape check of a saved draft (security f2): groups a table of at most 8 tables, reserve a table, every
-- seat false or a table with a string name.
local function readable(d)
  if type(d.groups) ~= "table" or type(d.reserve) ~= "table" then return false end
  local n = 0
  for _, grp in pairs(d.groups) do
    n = n + 1
    if n > 8 or type(grp) ~= "table" then return false end
    for s = 1, 5 do
      local x = grp[s]
      if x and not (type(x) == "table" and type(x.name) == "string") then return false end
    end
  end
  for _, x in pairs(d.reserve) do
    if not (type(x) == "table" and type(x.name) == "string") then return false end
  end
  return true
end

local function draw(card, view, rows, t, L)
  L = L or ns.Layout()
  local IW = L.viewW - 24
  for _, k in ipairs({ "title", "detail", "hint" }) do E[k]:SetWidth(IW) end
  if not open then return gone(card) end
  if open.kind == "held" then return drawHeld(card, view, rows, L) end
  if not officer() then
    open = nil
    return gone(card)
  end
  if open.kind == "new" then
    showOnly(card, { "name", "size", "raid", "make", "hint" })
    drawControls(view)
    return
  end
  local d = current()
  if not d then
    open = nil
    return gone(card)
  end
  if not readable(d) then
    showOnly(card, { "title", "discard" })
    E.title:SetText(UNREADABLE)
    return
  end
  showOnly(card, { "name", "size", "raid", "add", "addButton", "discard", "hint", "publish", "note" })
  local focused = E.name.HasFocus and E.name:HasFocus()
  if not focused then E.name:SetText(d.name or "") end
  drawControls(view)
  ns.DrawLineup(card, d, L, 82, { rows = rows, edit = true, selected = sel,
    onSeat = function(place, button, mouseButton) M.Safe(onSeat, place, button, mouseButton) end })
end

-- No officers field (D2): a held roster opens for everyone; draw keeps drafts to officers.
ns.Cards.roster = { build = build, draw = draw }
