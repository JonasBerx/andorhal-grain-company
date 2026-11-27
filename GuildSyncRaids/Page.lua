local _, ns = ...
if not ns.M then return end

-- The Raids page (0.3, t53): a header (the age line, the fixed Discord line, Load raid data for officers) over two
-- M.Kit.Card columns: the raid list on the left, the chosen raid or Load raid data on the right. Each card draws into
-- its card.body. The cards' contents come from RaidList.lua, RaidView.lua and Paste.lua, looked up at call time.
-- Every cell from the string or another player goes through ns.Escape before SetText (API.md GuildSync.Escape).
-- Owner cards (raid suite F1, plan Task 4): a file later in the TOC sets ns.Cards[name] = { build, draw, officers };
-- ns.ShowCard(name) puts that card's own K.Card host in the right column (made on its first show), and the header's
-- "My wish list" (wish) and "All notes" (notes, officers) buttons toggle it. build and draw each run under M.Safe.

local M, Rules = ns.M, ns.Rules
local K = M.Kit
-- The kit's colours and text roles (API 10). A text role is read only inside a function, never here: the kit makes
-- its font object on the first read.
local C, T = K.Tokens.colour, K.Tokens.text
local DISCORD = "Sign up on Discord (Raid-Helper). This list is read-only."
local WAITING = "Load raid data: waiting for the guild roster"
-- The page's colours, one table each for every card file, read by index [1..3] only (set with SetTextColor, never as
-- an inline code). White is module data (the kit's white is hub-only); orange is the kit's "data is old" colour
-- (trackerOld, the age line); grey is the kit's grey.
ns.WHITE, ns.ORANGE, ns.GREY = { 1, 1, 1 }, C.trackerOld, C.grey
-- The empty state's dark tint over the next raid's art (d634).
ns.ART_DIM = { 0.45, 0.45, 0.45 }
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

-- A FontString on parent, justified LEFT unless justify says otherwise: the one place a Raids FontString gets its
-- font. font is a K.Tokens.text role (default highlight) or a font name: a string goes in as CreateFontString's
-- template, anything else (a font object) is set with SetFontObject on a plain FontString.
function ns.Label(parent, font, justify)
  font = font or T.highlight
  local fs
  if type(font) == "string" then
    fs = parent:CreateFontString(nil, "OVERLAY", font)
  else
    fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(font)
  end
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

-- card: the shown owner card's name, nil at first (and while none shows).
ns.PageState = { pasting = false }
-- The owner cards by name ("wish", "notes", "roster"), reset at load: owner files come later in the TOC.
ns.Cards = {}

-- -> the ns.Cards entry of name when this player may see it, else nil (no entry; officers only and not an officer).
local function cardFor(name)
  local entry = name ~= nil and ns.Cards[name]
  if not entry then return nil end
  if entry.officers and not ns.IsOfficer(ns.MyKey()) then return nil end
  return entry
end

-- nil closes the shown card; a name this player may see shows it (and ends a paste) -> true; else nothing -> nil.
function ns.ShowCard(name)
  if name == nil then
    ns.PageState.card = nil
    if ui then ns.RefreshPage(ui.page) end
    return nil
  end
  if not cardFor(name) then return nil end
  ns.PageState.card, ns.PageState.pasting = name, false
  if ui then ns.RefreshPage(ui.page) end
  return true
end

function ns.Select(key)
  ns.PageState.chosen, ns.PageState.pasting, ns.PageState.card = key, false, nil
  if ui then ns.RefreshPage(ui.page) end
end

-- Officers only; anyone else: no-op.
function ns.StartPaste()
  if not ns.IsOfficer(ns.MyKey()) then return end
  ns.PageState.pasting, ns.PageState.card = true, nil
  if ui then ns.RefreshPage(ui.page) end
end

function ns.EndPaste()
  ns.PageState.pasting = false
  if ui then ns.RefreshPage(ui.page) end
end

-- The test seam: the page's ui table (page, listCard, viewCard, pasteCard, cards (the owner hosts by name), layout).
function ns.UI() return ui end

-- ---------- build ----------

-- A K.Card on the page with card.body, the child every module piece draws into (above the card's art).
local function card(page)
  local c = K.Card(page, 100, 100) or CreateFrame("Frame", nil, page)
  c.body = CreateFrame("Frame", nil, c)
  c.body:SetAllPoints(c)
  return c
end

-- A right-column card (the view, the paste card, an owner host) at layout L.
local function placeRight(c, L)
  c:SetSize(L.viewW, L.cardH)
  c:ClearAllPoints()
  c:SetPoint("TOPLEFT", L.listW + L.gap, -38)
end

local function applyLayout(w, h)
  if not ui then return end
  local L = ns.Layout(w, h)
  ui.layout = L
  ui.listCard:SetSize(L.listW, L.cardH)
  ui.listCard:ClearAllPoints()
  ui.listCard:SetPoint("TOPLEFT", 0, -38)
  for _, c in ipairs({ ui.viewCard, ui.pasteCard }) do placeRight(c, L) end
  for _, c in pairs(ui.cards) do placeRight(c, L) end
  ns.RefreshPage(ui.page)
end

-- The host card of name, made on its first show; the owner's build(c) runs once, under M.Safe. A build that fails is
-- not tried again this session: the card stays empty and its draw is skipped (broken[c]; a plain table, since a frame
-- may answer any unset key).
local broken = {}
local function hostFor(name, entry)
  local c = ui.cards[name]
  if c then return c end
  c = card(ui.page)
  ui.cards[name] = c
  placeRight(c, ui.layout)
  if type(entry.build) == "function" and not M.Safe(entry.build, c) then broken[c] = true end
  return c
end

-- The header buttons' click: an explicit if/else, so a second click closes the card.
local function toggle(name)
  if ns.PageState.card == name then
    ns.ShowCard(nil)
  else
    ns.ShowCard(name)
  end
end

function ns.BuildPage(page)
  ui = { page = page }
  ui.age = ns.Label(page)
  ui.discord = ns.Label(page, T.highlightSmall)
  ui.discord:SetPoint("TOPLEFT", 2, -18)
  ui.discord:SetTextColor(ns.GREY[1], ns.GREY[2], ns.GREY[3])
  ui.discord:SetText(DISCORD)
  ui.load = K.Button(page, "Load raid data", 130)
  ui.load:SetPoint("TOPRIGHT", -2, 0)
  ui.load:SetScript("OnClick", function() M.Safe(ns.StartPaste) end)
  -- The owner cards' buttons, shown by RefreshPage only while their ns.Cards entry exists.
  ui.cards = {}
  ui.wish = K.Button(page, "My wish list", 110)
  ui.wish:SetScript("OnClick", function() M.Safe(toggle, "wish") end)
  ui.notes = K.Button(page, "All notes", 110)
  ui.notes:SetScript("OnClick", function() M.Safe(toggle, "notes") end)
  ui.waiting = ns.Label(page, T.disable)
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
  local officer = ns.IsOfficer(me)
  -- A stale card name (its entry gone, or an officers card for a non-officer) is dropped. While the roster is not
  -- ready ns.IsOfficer cannot be trusted, so an officers card is held (hidden, its name kept) instead (o75).
  local named = S.card ~= nil and ns.Cards[S.card]
  local hold = (named and named.officers and not ready) and true or false
  local entry
  if not hold then entry = cardFor(S.card) end
  if not entry and not hold then S.card = nil end
  -- The header buttons from the right: Load raid data (fixed at TOPRIGHT -2, 0), All notes, My wish list, 6 px apart.
  local loadOn = (ready and officer) and true or false
  local prev = loadOn and ui.load or nil
  local left
  for _, b in ipairs({ { ui.notes, ready and officer and ns.Cards.notes }, { ui.wish, ready and ns.Cards.wish } }) do
    local on = b[2] and true or false
    b[1]:SetShown(on)
    if on then
      b[1]:ClearAllPoints()
      if prev then b[1]:SetPoint("TOPRIGHT", prev, "TOPLEFT", -6, 0) else b[1]:SetPoint("TOPRIGHT", -2, 0) end
      prev, left = b[1], b[1]
    end
  end
  ui.waiting:SetShown(not ready)
  -- The age line ends before the leftmost card button while one shows; else before the waiting line while it shows
  -- (f4773), else before the Load button's room.
  ui.age:ClearAllPoints()
  ui.age:SetPoint("TOPLEFT", 2, 0)
  if left then
    ui.age:SetPoint("TOPRIGHT", left, "TOPLEFT", -8, 0)
  elseif ready then
    ui.age:SetPoint("TOPRIGHT", page, "TOPRIGHT", -140, 0)
  else
    ui.age:SetPoint("TOPRIGHT", ui.waiting, "TOPLEFT", -8, 4)
  end
  ui.load:SetShown(loadOn)
  drawAge(view, rows, t)
  -- The cards' contents, each looked up at call time (nil: the card stays empty).
  if ns.DrawList then ns.DrawList(ui.listCard, view, rows, t, ui.layout) end
  -- A shown owner card hides the view, the paste card and every other host card.
  local host = entry and hostFor(S.card, entry)
  for name, c in pairs(ui.cards) do c:SetShown(entry ~= nil and name == S.card) end
  ui.viewCard:SetShown(not S.pasting and not entry)
  ui.pasteCard:SetShown(S.pasting and not entry)
  if entry then
    if not broken[host] then M.Safe(entry.draw, host, view, rows, t, ui.layout) end
  elseif S.pasting then
    if ns.DrawPaste then ns.DrawPaste(ui.pasteCard, view, rows, t, ui.layout) end
  elseif ns.DrawView then
    ns.DrawView(ui.viewCard, chosen, view, rows, t, ui.layout)
  end
end

-- The Load button, the online markers and the end of the waiting line need the roster.
M.On("rosterRead", function() M.RefreshPage() end)
