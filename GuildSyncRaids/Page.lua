local _, ns = ...
if not ns.M then return end

-- The Raids page (0.3, t53): a header (the age line, the fixed Discord line, Load raid data for officers) over two
-- M.Kit.Card columns: the raid list on the left, the chosen raid or Load raid data on the right. Each card draws into
-- its card.body. The cards' contents come from RaidList.lua, RaidView.lua and Paste.lua, looked up at call time.
-- Every cell from the string or another player goes through ns.Escape before SetText (API.md GuildSync.Escape).

local M, Rules = ns.M, ns.Rules
local K = M.Kit
local DISCORD = "Sign up on Discord (Raid-Helper). This list is read-only."
local WAITING = "Load raid data: waiting for the guild roster"
-- The page's colours, one table each for every card file (set with SetTextColor, never as an inline code).
ns.WHITE, ns.ORANGE, ns.GREY = { 1, 1, 1 }, { 1, 0.5, 0.1 }, { 0.7, 0.7, 0.7 }
-- The website's team palette (website/src/styles/global.css --team-1 .. --team-4, dark theme), by slot: the list
-- rows' team bars and names and the chosen raid's square.
ns.SLOT = { { 0.612, 0.486, 0.757 }, { 0.867, 0.682, 0.341 }, { 0.431, 0.651, 0.871 }, { 0.890, 0.518, 0.624 } }

-- ---------- raid art (d377) ----------
-- The game's own picture of each raid, picked from the Raid-Helper title and loaded by fileDataID at run time (the
-- path is in the comment; nothing is committed as art). Drawn as the Notice Board draws its banners
-- (GuildSyncNoticeBoard/Banners.lua on board-2col): SetTexture(<fileDataID>), the 4-argument SetTexCoord(l, r, t, b)
-- cut to the box's aspect so the picture is never stretched, SetSize. Raids keeps its own table: no Notice Board needed.

-- [key] = { file (fileDataID), w, h (texture size in pixels), crop = { l, r, t, b }? (the part worth showing) }
ns.RaidArt = {
  mc = { file = 340678, w = 256, h = 128 },   -- interface/lfgframe/ui-lfg-background-moltencore
  ony = { file = 1396463, w = 512, h = 512,   -- interface/encounterjournal/ui-ej-background-onyxiaslair
    -- the painting fills the top left (about 395 x 425) inside a smoky white edge; the crop keeps the band with the
    -- figures on the ledge
    crop = { l = 0.08, r = 0.68, t = 0.14, b = 0.48 } },
  bwl = { file = 340659, w = 256, h = 128 },  -- interface/lfgframe/ui-lfg-background-blackwinglair
  zg = { file = 340705, w = 256, h = 128 },   -- interface/lfgframe/ui-lfg-background-zulgurub
  aq20 = { file = 340649, w = 256, h = 128 }, -- interface/lfgframe/ui-lfg-background-aqruins
  aq40 = { file = 340650, w = 256, h = 128 }, -- interface/lfgframe/ui-lfg-background-aqtemple
  naxx = { file = 340679, w = 256, h = 128 }, -- interface/lfgframe/ui-lfg-background-naxxramas
}

-- The words that name each raid, matched as whole words in a title cut to lower-case letters and digits (so
-- "Zul'Gurub" reads "zul gurub" and "Onyxia's Lair" holds "onyxia"). The first raid named wins.
local ART_NAMES = {
  { "mc", { "molten core", "mc" } },
  { "ony", { "onyxia", "ony" } },
  { "bwl", { "blackwing lair", "bwl" } },
  { "zg", { "zul gurub", "zg" } },
  { "aq20", { "ruins of ahn qiraj", "aq20" } },
  { "aq40", { "temple of ahn qiraj", "aq40" } },
  { "naxx", { "naxxramas", "naxx" } },
}

-- -> the RaidArt key a title names, or nil (nothing named, or not a string).
function ns.ArtFor(title)
  if type(title) ~= "string" then return nil end
  local words = " " .. title:lower():gsub("[^%w]", " "):gsub("%s+", " ") .. " "
  for _, entry in ipairs(ART_NAMES) do
    for _, name in ipairs(entry[2]) do
      if words:find(" " .. name .. " ", 1, true) then return entry[1] end
    end
  end
  return nil
end

local function positive(n) return type(n) == "number" and n > 0 end

-- -> l, r, t, b: the art's own crop, then its centre cut to the w x h box's aspect (every division guarded).
local function artCrop(a, w, h)
  local c = a.crop or { l = 0, r = 1, t = 0, b = 1 }
  local l, r, t, bot = c.l, c.r, c.t, c.b
  local cw, ch = (r - l) * a.w, (bot - t) * a.h
  if not (positive(w) and positive(h) and positive(cw) and positive(ch)) then return l, r, t, bot end
  local A, S = w / h, cw / ch
  if S > A then
    local half = (r - l) * A / S / 2
    local mid = (l + r) / 2
    return mid - half, mid + half, t, bot
  end
  local half = (bot - t) * S / A / 2
  local mid = (t + bot) / 2
  return l, r, mid - half, mid + half
end

-- Draws the art of key into tex as a w x h box and shows it; -> true. No art for key, or a texture the client could
-- not load (SetTexture answers false): tex is hidden and the answer is false, so the caller lays out as without art.
function ns.DrawArt(tex, key, w, h)
  local a = key and ns.RaidArt[key]
  if not a or tex:SetTexture(a.file) == false then
    tex:Hide()
    return false
  end
  tex:SetTexCoord(artCrop(a, w, h))
  tex:SetSize(w, h)
  tex:Show()
  return true
end

local ui

local function now() return M.Compat.call("GetServerTime") or 0 end
local function esc(s) return ns.Escape(tostring(s or "")) end
local ago = Rules.Duration

-- ---------- helpers every card file calls (at call time) ----------

-- A clock text, or "?" when date() answers nil or throws (a time past what the client can show, f1490).
function ns.When(fmt, t)
  local okDate, s = pcall(date, fmt, t)
  return (okDate and s) or "?"
end

-- The roster name of a key (escaped), else the key itself.
function ns.Who(rows, key)
  local r = key and rows[key]
  return esc((r and r.name) or key or "?")
end

-- A FontString on parent, justified LEFT unless justify says otherwise.
function ns.Label(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- ---------- pure pieces ----------

-- The page's layout at w x h (nil = the default window), clamped to the minimum 586 x 388 (plan section 2).
function ns.Layout(w, h)
  local W = math.max(586, tonumber(w) or 726)
  local H = math.max(388, tonumber(h) or 508)
  local listW = math.min(280, math.max(220, 220 + math.floor((W - 586) * 60 / 140)))
  return { listW = listW, viewW = W - listW - 10, gap = 10, cardH = H - 38, banner = (H >= 508) and 100 or 64,
    thumbs = listW >= 280 }
end

-- The status pill's words (escaped) and tone for meKey on ev; short for the list rows.
function ns.StatusPill(ev, meKey, short)
  local st = Rules.Status(ev, meKey)
  if st.state == "arriving" then return short and "arriving" or "sign-ups arriving", "gold" end
  if st.state ~= "signed" then return "not signed up", "grey" end
  local s = st.signup
  local text = esc((s.role or "") ~= "" and s.role or "?")
  if s.kind ~= "primary" then text = text .. " (" .. tostring(s.kind) .. ")" end
  return short and text or ("signed up \194\183 " .. text), "green"
end

-- A ScrollFrame on parent and its scroll child: ScrollFrameTemplate (the minimal bar), else UIPanelScrollFrameTemplate
-- when CreateFrame throws or answers nil. Only OnSizeChanged is set (the child's width follows); the caller anchors
-- the frame and leaves 22 px on its right for the bar.
function ns.ScrollArea(parent)
  local good, scroll = pcall(CreateFrame, "ScrollFrame", nil, parent, "ScrollFrameTemplate")
  if not good or not scroll then scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate") end
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(400, 10)
  scroll:SetScrollChild(child)
  scroll:SetScript("OnSizeChanged", function(_, w) if w then child:SetWidth(w) end end)
  return scroll, child
end

-- ---------- page state ----------

ns.PageState = { pasting = false }

function ns.Select(key)
  ns.PageState.chosen, ns.PageState.pasting = key, false
  if ui then ns.RefreshPage(ui.page) end
end

-- Officers only; anyone else: no-op.
function ns.StartPaste()
  if not ns.IsOfficer(ns.MyKey()) then return end
  ns.PageState.pasting = true
  if ui then ns.RefreshPage(ui.page) end
end

function ns.EndPaste()
  ns.PageState.pasting = false
  if ui then ns.RefreshPage(ui.page) end
end

-- The test seam: the page's ui table (page, listCard, viewCard, pasteCard, layout).
function ns.UI() return ui end

-- ---------- build ----------

-- A K.Card on the page with card.body, the child every module piece draws into (above the card's art).
local function card(page)
  local c = K.Card(page, 100, 100) or CreateFrame("Frame", nil, page)
  c.body = CreateFrame("Frame", nil, c)
  c.body:SetAllPoints(c)
  return c
end

local function applyLayout(w, h)
  if not ui then return end
  local L = ns.Layout(w, h)
  ui.layout = L
  ui.listCard:SetSize(L.listW, L.cardH)
  ui.listCard:ClearAllPoints()
  ui.listCard:SetPoint("TOPLEFT", 0, -38)
  for _, c in ipairs({ ui.viewCard, ui.pasteCard }) do
    c:SetSize(L.viewW, L.cardH)
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", L.listW + L.gap, -38)
  end
  ns.RefreshPage(ui.page)
end

function ns.BuildPage(page)
  ui = { page = page }
  ui.age = ns.Label(page)
  ui.discord = ns.Label(page, "GameFontHighlightSmall")
  ui.discord:SetPoint("TOPLEFT", 2, -18)
  ui.discord:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3])
  ui.discord:SetText(DISCORD)
  ui.load = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  ui.load:SetSize(130, 22)
  ui.load:SetPoint("TOPRIGHT", -2, 0)
  ui.load:SetText("Load raid data")
  ui.load:SetScript("OnClick", function() M.Safe(ns.StartPaste) end)
  ui.waiting = ns.Label(page, "GameFontDisable")
  ui.waiting:SetPoint("TOPRIGHT", -2, -4)
  ui.waiting:SetText(WAITING)
  ui.listCard, ui.viewCard, ui.pasteCard = card(page), card(page), card(page)
  if ns.BuildList then ns.BuildList(ui.listCard) end
  if ns.BuildView then ns.BuildView(ui.viewCard) end
  if ns.BuildPaste then ns.BuildPaste(ui.pasteCard) end
  page:SetScript("OnSizeChanged", function(_, w, h) M.Safe(applyLayout, w, h) end)
  applyLayout(nil, nil)
end

-- ---------- draw ----------

local function drawAge(view, rows, t)
  local held = view.held
  local text
  if not held then
    text = "No raid data yet."
  elseif tonumber(held.at) then
    text = "Data from " .. ns.When("%H:%M", held.at) .. " (" .. ns.Who(rows, held.by) .. "), " .. ago(t - held.at)
      .. " ago"
  else
    text = "Data from " .. ns.Who(rows, held.by) .. ": Raid-Helper time unknown, copied " .. ago(t - held.gen) .. " ago"
  end
  if view.incomplete > 0 then
    text = text .. "; " .. view.incomplete .. (view.incomplete == 1 and " raid" or " raids") .. " incomplete"
  end
  local _, warn = Rules.Age(held, t)
  local col = (held and warn) and ns.ORANGE or ns.WHITE
  ui.age:SetText(text)
  ui.age:SetTextColor(col[1], col[2], col[3])
end

function ns.RefreshPage(page)
  if not ui then return end
  local t = now()
  local view = ns.View()
  local rows, partial, _, known = ns.Roster()
  local me = ns.MyKey()
  local S = ns.PageState
  if S.pasting and not ns.IsOfficer(me) then S.pasting = false end
  local chosen
  for _, x in ipairs(view.events) do if x.key == S.chosen then chosen = x end end
  if not chosen then S.chosen = nil end
  local ready = known and not partial
  ui.waiting:SetShown(not ready)
  -- The age line ends before the waiting line while it shows (f4773), else before the Load button's room.
  ui.age:ClearAllPoints()
  ui.age:SetPoint("TOPLEFT", 2, 0)
  if ready then
    ui.age:SetPoint("TOPRIGHT", page, "TOPRIGHT", -140, 0)
  else
    ui.age:SetPoint("TOPRIGHT", ui.waiting, "TOPLEFT", -8, 4)
  end
  ui.load:SetShown(ready and ns.IsOfficer(me) and true or false)
  drawAge(view, rows, t)
  -- The cards' contents, each looked up at call time (nil: the card stays empty).
  if ns.DrawList then ns.DrawList(ui.listCard, view, rows, t, ui.layout) end
  ui.viewCard:SetShown(not S.pasting)
  ui.pasteCard:SetShown(S.pasting)
  if S.pasting then
    if ns.DrawPaste then ns.DrawPaste(ui.pasteCard, view, rows, t, ui.layout) end
  elseif ns.DrawView then
    ns.DrawView(ui.viewCard, chosen, view, rows, t, ui.layout)
  end
end

-- The Load button, the online markers and the end of the waiting line need the roster.
M.On("rosterRead", function() M.RefreshPage() end)
