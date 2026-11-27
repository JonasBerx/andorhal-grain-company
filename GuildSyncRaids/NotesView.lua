local _, ns = ...
if not ns.M then return end

-- The Notes tab of the chosen raid, the "You tonight" jobs cell and the officers' read-only "notes" card (ticket 61,
-- N1 and N2; plan Task 4). Exports ns.ShowNotes, ns.YouJobs, ns.DrawNotes and ns.Cards.notes. ns.ShowNotes and
-- ns.DrawNotes(card, ev, layout, top, view) are called by
-- RaidView.lua (the ns.DrawPulls shape: built once on the card, everything hidden, then laid out in one scroll child);
-- ns.YouJobs answers plain text that RaidView escapes. Every text from another player goes through ns.Escape here.
-- This file sends nothing and calls no game function. ns.PinBoss (JobCard.lua) is looked up at call time.

local M = ns.M
local K = M.Kit
local C, T = K.Tokens.colour, K.Tokens.text -- a text role is read in a function only
local NR = ns.NotesRules
local SB = 22 -- the scrollbar's room on the right (ns.ScrollArea)
local BTN_H, GAP = 24, 4

local function esc(s) return ns.Escape(tostring(s or "")) end
local function grey(fs) fs:SetTextColor(C.grey[1], C.grey[2], C.grey[3]) end
local function white(fs) fs:SetTextColor(ns.WHITE[1], ns.WHITE[2], ns.WHITE[3]) end

local function at(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", x, y)
end

local function calledBoss(ev)
  local f = ns.NotesCalled
  if type(f) ~= "function" then return nil end
  local id = f(ev.id)
  return id ~= nil and tostring(id) or nil
end

-- -> true only for a raid whose notes raid holds at least one boss.
function ns.ShowNotes(ev)
  local r = ev and ns.NotesFor(ev)
  return type(r) == "table" and #r.bosses > 0
end

-- The "You tonight" cell: the job names on the called boss, else "n jobs", else nil (plain text).
function ns.YouJobs(ev)
  local raid = ev and ns.NotesFor(ev)
  if type(raid) ~= "table" then return nil end
  return NR.YouLine(NR.YourJobs(raid, ev.team, ns.NotesMyKeys(), ns.Key), calledBoss(ev))
end

-- ---------- the Notes tab ----------

local function build(card)
  local V = { lines = { n = 0 }, bosses = {}, chosen = {} }
  card.notesView = V
  V.pane = CreateFrame("Frame", nil, card.body)
  V.scroll, V.child = ns.ScrollArea(V.pane)
  V.scroll:SetPoint("TOPLEFT", V.pane, "TOPLEFT", 0, 0)
  V.scroll:SetPoint("BOTTOMRIGHT", V.pane, "BOTTOMRIGHT", -SB, 4)
  -- the read-only copy box (RaidView's urlBox): focus selects all, Escape lets go, typing puts self.url back
  V.copy = K.InputBox(V.child, 340, 340)
  if V.copy then
    V.copy:SetAutoFocus(false)
    V.copy:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    V.copy:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    V.copy:SetScript("OnTextChanged", function(self, user) if user and self.url then self:SetText(self.url) end end)
  end
  V.pin = K.Button(V.child, "Pin", 60, function()
    local f = ns.PinBoss
    if type(f) == "function" and V.ev and V.boss then f(V.ev, V.boss) end
  end)
  V.note = ns.Label(V.child, T.highlight)
  V.note:SetWordWrap(true)
  V.note:SetNonSpaceWrap(true)
  return V
end

local function hideAll(V)
  for i = 1, #V.lines do V.lines[i]:Hide() end
  V.lines.n = 0
  for _, b in ipairs(V.bosses) do b:Hide() end
  if V.copy then V.copy:Hide() end
  if V.pin then V.pin:Hide() end
  V.note:Hide()
end

-- The next pooled FontString at (x, -y), width w; answers y below it.
local function line(V, font, text, x, y, w, dim)
  V.lines.n = V.lines.n + 1
  local fs = V.lines[V.lines.n]
  if not fs then
    fs = ns.Label(V.child, font)
    fs:SetWordWrap(true)
    V.lines[V.lines.n] = fs
  end
  fs:SetFontObject(font)
  at(fs, x, -y)
  fs:SetWidth(w)
  fs:SetText(text)
  if dim then grey(fs) else white(fs) end
  fs:Show()
  return y + (tonumber(fs:GetStringHeight()) or 14) + 3
end

-- The i-th boss button (made on first use); a click chooses its boss for this raid and redraws.
local function bossButton(V, card, i)
  local b = V.bosses[i]
  if b then return b end
  b = K.Button(V.child, "", 130, function(self)
    if not V.ev then return end
    V.chosen[V.ev.key] = self.bossId
    ns.DrawNotes(card, V.ev, V.L, V.top, V.view)
  end)
  V.bosses[i] = b
  return b
end

local function draw(V, card, ev, raid, PW)
  local y = 6
  -- 1. Your jobs
  y = line(V, T.normal, "Your jobs", 4, y, PW - 8)
  local mine = NR.YourJobs(raid, ev.team, ns.NotesMyKeys(), ns.Key)
  if #mine == 0 then y = line(V, T.highlightSmall, "No job for you in this raid.", 12, y, PW - 16, true) end
  for _, e in ipairs(mine) do y = line(V, T.highlightSmall, esc(e.boss.name) .. ": " .. esc(e.job.name), 12, y, PW - 16) end
  y = y + 6
  -- 2. The sketches line and its copy box
  if (raid.sketches or "") ~= "" then
    y = line(V, T.highlightSmall, esc(raid.sketches), 4, y, PW - 8, true)
    local url = NR.Url(raid.sketches)
    if url and V.copy then
      at(V.copy, 10, -y)
      V.copy:SetWidth(math.min(340, PW - 16))
      V.copy.url = url
      V.copy:SetText(url)
      V.copy:Show()
      y = y + 24
    end
    y = y + 6
  end
  -- 3. One button per boss; the choice is kept per raid, the default is the called boss, else the first
  local called = calledBoss(ev)
  local chosen = V.chosen[ev.key]
  local boss
  for _, b in ipairs(raid.bosses) do if b.id == chosen then boss = b end end
  if not boss then for _, b in ipairs(raid.bosses) do if b.id == called then boss = b end end end
  boss = boss or raid.bosses[1]
  local x = 4
  for i, b in ipairs(raid.bosses) do
    local btn = bossButton(V, card, i)
    if btn then
      if x > 4 and x + 130 > PW then x, y = 4, y + BTN_H + GAP end
      btn.bossId = b.id
      btn:SetText(esc(b.name) .. (b.id == called and " (called)" or ""))
      at(btn, x, -y)
      btn:Show()
      x = x + 130 + GAP
    end
  end
  y = y + BTN_H + GAP + 6
  -- 4. The chosen boss and Pin
  V.boss = boss.id
  local nameY = y
  y = line(V, T.normal, esc(boss.name), 4, y, PW - 80)
  if V.pin and type(ns.PinBoss) == "function" then
    at(V.pin, PW - 68, -(nameY - 2))
    V.pin:Show()
    y = math.max(y, nameY + BTN_H)
  end
  -- 5. Its jobs and their holders for the raid's team, each hint under it
  for _, job in ipairs(boss.jobs or {}) do
    local names = {}
    for _, n in ipairs(NR.Holders(job, ev.team)) do names[#names + 1] = esc(n) end
    y = line(V, T.highlightSmall, esc(job.name) .. ": " .. (#names > 0 and table.concat(names, ", ") or "open"), 12, y,
      PW - 16)
    if (job.hint or "") ~= "" then y = line(V, T.small, esc(job.hint), 20, y, PW - 24, true) end
  end
  -- 6. The note, wrapping
  if (boss.text or "") ~= "" then
    y = y + 4
    at(V.note, 4, -y)
    V.note:SetWidth(PW - 8)
    V.note:SetText(esc(boss.text))
    V.note:Show()
    y = y + (tonumber(V.note:GetStringHeight()) or 14) + 3
  end
  return y + 6
end

-- ev nil hides the pane.
function ns.DrawNotes(card, ev, layout, top, view)
  local V = rawget(card, "notesView") or build(card)
  hideAll(V)
  local raid = ev and ns.NotesFor(ev)
  if type(raid) ~= "table" or #raid.bosses == 0 then
    V.ev = nil
    V.pane:Hide()
    return
  end
  local L = layout or ns.Layout()
  top = top or 0
  V.ev, V.L, V.top, V.view = ev, L, top, view
  local IW = L.viewW - 24
  at(V.pane, 12, -top)
  V.pane:SetSize(IW, math.max(1, L.cardH - 12 - top))
  V.pane:Show()
  if V.key ~= ev.key then
    V.key = ev.key
    V.scroll:SetVerticalScroll(0)
  end
  V.child:SetWidth(IW - SB)
  V.child:SetHeight(math.max(10, draw(V, card, ev, raid, IW - SB)))
end

-- ---------- the officers' "notes" card (read only) ----------

local function cardText()
  local raids = ns.NotesView().raids or {}
  if #raids == 0 then return "No notes held yet." end
  local out = {}
  for _, r in ipairs(raids) do
    out[#out + 1] = esc(r.name) .. ((r.words or "") ~= "" and (" (" .. esc(r.words) .. ")") or "")
    if (r.sketches or "") ~= "" then out[#out + 1] = "  " .. esc(r.sketches) end
    for _, b in ipairs(r.bosses or {}) do
      local n = #(b.jobs or {})
      out[#out + 1] = "  " .. esc(b.name) .. ": " .. n .. (n == 1 and " job" or " jobs")
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

ns.Cards.notes = {
  officers = true,
  build = function(c)
    local V = {}
    c.notesCard = V
    V.scroll, V.child = ns.ScrollArea(c.body)
    V.scroll:SetPoint("TOPLEFT", c.body, "TOPLEFT", 12, -12)
    V.scroll:SetPoint("BOTTOMRIGHT", c.body, "BOTTOMRIGHT", -SB - 12, 12)
    V.text = ns.Label(V.child, T.highlightSmall)
    V.text:SetWordWrap(true)
    V.text:SetNonSpaceWrap(true)
    at(V.text, 4, -4)
  end,
  draw = function(c, view, rows, t, L)
    local V = c.notesCard
    L = L or ns.Layout()
    local W = L.viewW - 24 - SB
    V.child:SetWidth(W)
    V.text:SetWidth(W - 8)
    V.text:SetText(cardText())
    V.child:SetHeight(math.max(10, (tonumber(V.text:GetStringHeight()) or 14) + 8))
  end,
}
