-- Annals AnnalsAchievements: the Achievements tab on the Annals page in the GuildSync window (window plan Task 6, an-7)
-- in Forever's Legacy art (D10): the title, the points line and the reward track (d504, lg-1) on the head; the category
-- tree on the left (lg-4); Lately in the Company, the honesty note and Yours as Legacy challenge cards on the
-- right, in a scroll. Built from our own frames and textures with the atlases set through the kit, never from a
-- Blizzard_LegacySystem template (that addon is load on demand). Rows come from View.AchievementRows; names come
-- escaped from View. Widths come from A.Layout() (D17) on every refresh. Reaches only ns.AnnalsModule (the seam),
-- ns.AnnalsView, ns.AnnalsRules and ns.AnnalsFeats.
local _, ns = ...
if not (ns.AnnalsModule and ns.AnnalsModule.M) then ns.AnnalsAchievements = {} return end

local A, View, Rules, Feats = ns.AnnalsModule, ns.AnnalsView, ns.AnnalsRules, ns.AnnalsFeats
local Kit = A.Kit

local floor = math.floor

local BAR_H = 16
local FILL_H = 13            -- Forever's LegacyProgressBarTemplate: the bar sits in the background's top 13
local FRAME_X, FRAME_TOP, FRAME_BOTTOM = 8, 7, 10 -- the frame's overhang around that bar (the template's anchors)
local FRAME_SLICE = 33       -- left and right only: a top or bottom slice repeats the frame's rail under the bar
local FILL_MIN = 1
local LINE_H = 18            -- a header or a Lately row
local GAP = 6
local CARD_H = 122
local CARD_GAP = 8
local RIBBON_H = 44
local ICON_FRAME = 60
local ICON = 50
local CARD_SHIELD_W, CARD_SHIELD_H = 35, 51
local CARD_BAR_W = 200
local DATE_W, DATE_H = 150, 28
local CHECK = 20
local DATE_TEXT_W = 120      -- "Earned <day>" on the date plate
local RIGHT_W = 90           -- the day on a Lately row
local TEXT_X = 100           -- a card's text column, right of the plus (TEXT_X_PLUS, D7)
local SHIELD_ROOM = 60       -- kept free at a card's right for its points shield
local GREY = { 0.5, 0.5, 0.5 }
local CARD_FALLBACK = { 0.12, 0.1, 0.08, 0.9 }
local CARD_OFF_FALLBACK = { 0.08, 0.08, 0.08, 0.9 }
local BAR_BG_FALLBACK = { 0, 0, 0, 0.5 }
local BAR_FILL_FALLBACK = { 1, 0.82, 0, 1 }
local ICON_FILE = "Interface\\Icons\\INV_Misc_Book_09"

-- The tab's state; the category and the open parents are never saved. S.openKey: the row key of the one open card
-- (D7), nil when every card is closed.
local S = { category = "ALL", open = {}, treeRows = {}, labels = {}, lately = {}, cards = {}, track = {} }

-- One line, never wrapped; its width (set by the caller) ends it in an ellipsis in the client.
local function oneLine(fs)
  fs:SetWordWrap(false)
  fs:SetMaxLines(1)
end

local function place(f, x, y)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", x, y)
end

-- floor(w * a / b) for 0 <= a <= b, b > 0, found by halving: the divisor is never a variable (Forever errors on a
-- division by zero).
local function share(a, b, w)
  if b <= 0 or a <= 0 then return 0 end
  if a >= b then return w end
  local lo, hi = 0, w
  while lo < hi do
    local mid = floor((lo + hi + 1) / 2)
    if mid * b <= a * w then lo = mid else hi = mid - 1 end
  end
  return lo
end

-- A Legacy progress bar on parent: BG, Fill, Frame (the frame overhangs the BG as the Legacy template does).
local function newBar(parent)
  local bar = {}
  bar.bg = parent:CreateTexture(nil, "BACKGROUND")
  bar.fill = parent:CreateTexture(nil, "ARTWORK")
  bar.frame = parent:CreateTexture(nil, "OVERLAY")
  return bar
end

-- bgH and fillH default to the card bar's BAR_H and FILL_H (the track's bar is thinner, lg-1).
local function drawBar(bar, x, y, w, fillW, bgH, fillH)
  fillH = fillH or FILL_H
  bar.bg:ClearAllPoints()
  bar.bg:SetPoint("TOPLEFT", x, y)
  bar.bg:SetSize(w, bgH or BAR_H)
  Kit.Atlas(bar.bg, "Legacy-Progressbar-BG", BAR_BG_FALLBACK)
  bar.fill:ClearAllPoints()
  bar.fill:SetPoint("TOPLEFT", bar.bg, "TOPLEFT", 0, 0)
  -- At least FILL_MIN wide: a texture set to width 0 takes its natural size in the client. The frame's overhang
  -- covers that sliver, so an empty bar still reads empty.
  bar.fill:SetSize(fillW > FILL_MIN and fillW or FILL_MIN, fillH)
  Kit.Atlas(bar.fill, "Legacy-Progressbar-Fill", BAR_FILL_FALLBACK)
  bar.frame:ClearAllPoints()
  bar.frame:SetPoint("TOPLEFT", bar.bg, "TOPLEFT", -FRAME_X, FRAME_TOP)
  bar.frame:SetPoint("BOTTOMRIGHT", bar.bg, "TOPRIGHT", FRAME_X, -(fillH + FRAME_BOTTOM))
  if Kit.Atlas(bar.frame, "Legacy-Progressbar-Frame") and bar.frame.SetTextureSliceMargins then
    bar.frame:SetTextureSliceMargins(FRAME_SLICE, 0, FRAME_SLICE, 0)
  end
end

local function hideBar(bar)
  bar.bg:Hide()
  bar.fill:Hide()
  bar.frame:Hide()
end

-- ---------- the reward track (d504, lg-1; plan D5, D6) ----------
-- The head: the title and the points line, then one Legacy bar under five title cards. Geometry from
-- Rules.TrackLayout(page width - Rules.TRACK_INSET, #titles) on every refresh (d514); the fill from Rules.TrackFill with the head row's cur
-- and pct (the tab parses no View text). Sizes from NOTES-legacy lg-1. Card states come from the head row's track:
-- current (Cards-Green), earned (Cards), next ("N to go"), later; current and earned get the earned art and the check.

local TRACK_BAR_Y = -26
local TRACK_BAR_H, TRACK_FILL_H = 12, 9
local TRACK_CARD_Y = -41.5
local TRACK_CARD_H = 124
local TRACK_SLICE = 16
local DIAMOND, DIAMOND_UP = 48, 12
local TICON_FRAME, TICON, TICON_Y = 40, 32, -39
local TNAME_MAX, TNAME_PAD, TNAME_Y = 120, 24, -83
local TOGO_Y = -100
local TCHECK_W, TCHECK_H, TCHECK_X, TCHECK_Y = 27, 23, -13, -10
-- Placeholder icons, one per title in Rules.TITLES order (the mock's, legacy-part.html:414-415).
local TITLE_ICONS = { "INV_Shirt_White_01", "Trade_BlackSmithing", "Ability_Warrior_RallyingCry", "INV_Misc_Book_09",
  "INV_Letter_15" }

local function newTrackCard()
  local f = A.Frame(S.head)
  if not f then return nil end
  local x = { f = f }
  x.bg = f:CreateTexture(nil, "BACKGROUND")
  x.bg:SetAllPoints(f)
  x.diamond = f:CreateTexture(nil, "ARTWORK")
  x.diamond:SetSize(DIAMOND, DIAMOND)
  x.diamond:SetPoint("TOP", f, "TOP", 0, DIAMOND_UP)
  x.at = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  x.at:SetPoint("CENTER", x.diamond, "CENTER", 0, 0)
  x.iconFrame = f:CreateTexture(nil, "ARTWORK", nil, 2)
  x.iconFrame:SetSize(TICON_FRAME, TICON_FRAME)
  x.iconFrame:SetPoint("TOP", f, "TOP", 0, TICON_Y)
  x.icon = f:CreateTexture(nil, "ARTWORK", nil, 1)
  x.icon:SetSize(TICON, TICON)
  x.icon:SetPoint("CENTER", x.iconFrame, "CENTER", 0, 0)
  x.name = A.Label(f, "", "GameFontHighlightMedium")
  x.name:SetJustifyH("CENTER")
  x.name:SetPoint("TOP", f, "TOP", 0, TNAME_Y)
  x.toGo = A.Label(f, "", "GameFontNormalSmall")
  x.toGo:SetJustifyH("CENTER")
  x.toGo:SetPoint("TOP", f, "TOP", 0, TOGO_Y)
  x.check = f:CreateTexture(nil, "OVERLAY")
  x.check:SetSize(TCHECK_W, TCHECK_H)
  x.check:SetPoint("TOPRIGHT", f, "TOPRIGHT", TCHECK_X, TCHECK_Y)
  return x
end

local function drawTrackCard(i, t, T)
  local x = S.track[i] or newTrackCard()
  if not x then return end
  S.track[i] = x
  local current, earned = t.state == "current", t.state == "earned"
  local on = current or earned
  x.f:SetSize(T.cardW, TRACK_CARD_H)
  place(x.f, T.xs[i], TRACK_CARD_Y)
  if Kit.Atlas(x.bg, current and "Legacy-Rewards-Tracker-Cards-Green"
       or (earned and "Legacy-Rewards-Tracker-Cards" or "Legacy-Rewards-Tracker-Cards-Disable"),
       on and CARD_FALLBACK or CARD_OFF_FALLBACK) and x.bg.SetTextureSliceMargins then
    x.bg:SetTextureSliceMargins(TRACK_SLICE, TRACK_SLICE, TRACK_SLICE, TRACK_SLICE)
  end
  Kit.Atlas(x.diamond, on and "Legacy-Rewards-Tracker-Diamond" or "Legacy-Rewards-Tracker-Diamond-Disable")
  Kit.Atlas(x.iconFrame, on and "Legacy-Rewards-Tracker-Icons-Frame" or "Legacy-Rewards-Tracker-Icons-Frame-Disable")
  x.icon:SetTexture("Interface\\Icons\\" .. (TITLE_ICONS[i] or TITLE_ICONS[#TITLE_ICONS]))
  if x.icon.SetDesaturated then x.icon:SetDesaturated(not on) end
  x.at:SetText(tostring(t.at or ""))
  x.name:SetWidth(math.min(TNAME_MAX, T.cardW - TNAME_PAD))
  x.name:SetText(t.name or "")
  if on then
    x.at:SetTextColor(1, 1, 1)
    x.name:SetTextColor(1, 1, 1)
    Kit.Atlas(x.check, "worldquest-tracker-checkmark")
  else
    x.at:SetTextColor(GREY[1], GREY[2], GREY[3])
    x.name:SetTextColor(GREY[1], GREY[2], GREY[3])
    x.check:Hide()
  end
  if t.state == "next" and type(t.toGo) == "number" then
    x.toGo:SetText(t.toGo .. " to go")
    x.toGo:Show()
  else
    x.toGo:SetText("")
    x.toGo:Hide()
  end
  x.f:Show()
end

local function buildHead(holder)
  S.head = A.Frame(holder)
  place(S.head, 0, 0)
  S.title = A.Label(S.head, "", "GameFontNormalLarge")
  place(S.title, 4, -2)
  S.right = A.Label(S.head, "", "GameFontHighlightSmall")
  S.right:SetPoint("LEFT", S.title, "RIGHT", 8, 0)
  S.right:SetTextColor(GREY[1], GREY[2], GREY[3])
  S.bar = newBar(S.head)
end

local function drawHead(h, L)
  S.head:SetSize(L.inner, Rules.TRACK_H)
  S.title:SetText(h.text or "")
  S.right:SetText(h.right or "")
  local titles = type(h.track) == "table" and h.track or {}
  local T = Rules.TrackLayout(L.inner + Rules.SCROLL_W - Rules.TRACK_INSET, #titles)  -- page width - 18 (d514)
  local cur = type(h.cur) == "number" and h.cur or 1
  local pct = type(h.pct) == "number" and h.pct or 0
  local fill = #titles > 0 and Rules.TrackFill(T, cur, pct) or 0
  drawBar(S.bar, 0, TRACK_BAR_Y, T.span, fill, TRACK_BAR_H, TRACK_FILL_H)
  for i, t in ipairs(titles) do drawTrackCard(i, t, T) end
  for i = #titles + 1, #S.track do S.track[i].f:Hide() end
end

-- ---------- the category tree (lg-4; plan D2, D4, D13, D14) ----------
-- Feats.TREE in a UIPanelScrollFrameTemplate list under the track, as View.TreeRows gives it. One row per tree key,
-- built once; a refresh places the visible ones. Parents start closed and only open or close (a parent holds no
-- cards); a leaf click selects it; a soon row's click does nothing (d506). Open parents and the selected leaf live in
-- S, never saved.

local TREE_W = 156
local TREE_ROW_H, TREE_PITCH, TREE_PAD, TREE_INDENT = 25, 26, 5, 10
local TREE_TEXT_X = 8
local TREE_TEXT_RIGHT = 8        -- kept free at a leaf's right
local TOGGLE, TOGGLE_X = 20, -6
local TOGGLE_ROOM = 30           -- the collapse button and its gap, at a parent's right
local PLUS, MINUS_H = 13, 4
local SOON_X, SOON_GAP = -10, 6
local SOON_TEXT = "Coming soon"
local SOON_W = 66                -- "Coming soon" when the client cannot measure it
local GOLD = { 1, 0.82, 0 }
local DOT = 14                   -- the new-mark dot (D11)
local DOT_LEAF_X, DOT_LEAF_Y, DOT_PARENT_X, DOT_CARD_GAP = -10, 2, -4, 4

local function onTreeClick(x)
  if x.kind == "parent" then
    S.open[x.key] = not S.open[x.key]
  elseif x.kind == "leaf" then
    S.category = x.key
  else
    return
  end
  ns.AnnalsAchievements.refresh(S.holder)
end

local function newTreeRow(item, kind)
  local b = A.Frame(S.tree, "Button")
  if not b then return nil end
  local x = { b = b, key = item.key, kind = kind }
  local function click() if A.M then A.M.Safe(onTreeClick, x) end end
  x.art = b:CreateTexture(nil, "BACKGROUND")
  x.art:SetAllPoints(b)
  -- The name first: it is the row's label.
  x.name = A.Label(b, item.text, "Game15Font_Shadow")
  x.name:SetPoint("LEFT", TREE_TEXT_X, 0)
  if kind == "parent" then
    x.toggle = A.Frame(b, "Button")
    if x.toggle then
      x.toggle:SetSize(TOGGLE, TOGGLE)
      x.toggle:SetPoint("RIGHT", TOGGLE_X, 0)
      x.icon = x.toggle:CreateTexture(nil, "ARTWORK")
      x.icon:SetPoint("CENTER", x.toggle, "CENTER", 0, 0)
      x.toggle:SetScript("OnClick", click)
    end
  elseif kind == "soon" then
    x.soon = A.Label(b, SOON_TEXT, "GameFontDisableSmall")
    x.soon:SetPoint("RIGHT", SOON_X, 0)
  end
  -- The new-mark dot (D11): a leaf's at RIGHT -10, +2; a parent's left of its collapse button.
  if kind ~= "soon" then
    x.dot = b:CreateTexture(nil, "OVERLAY")
    x.dot:SetSize(DOT, DOT)
    if x.toggle then
      x.dot:SetPoint("RIGHT", x.toggle, "LEFT", DOT_PARENT_X, 0)
    else
      x.dot:SetPoint("RIGHT", DOT_LEAF_X, DOT_LEAF_Y)
    end
    x.dot:Hide()
  end
  b:SetScript("OnClick", click)
  return x
end

local function buildTree(holder)
  S.treeScroll, S.tree = A.Scroll(holder)
  if not S.treeScroll then return end
  S.treeScroll:ClearAllPoints()
  S.treeScroll:SetPoint("TOPLEFT", 0, -Rules.TRACK_H)
  S.treeScroll:SetPoint("BOTTOMLEFT", 0, 0)
  S.treeScroll:SetWidth(TREE_W)
  if not S.tree then return end
  S.tree:SetWidth(TREE_W)
  for _, item in ipairs(Feats.TREE) do
    local live = item.key == "ALL" or Feats.LeafLive(item.key)
    S.treeRows[item.key] = newTreeRow(item, item.leaves and "parent" or (live and "leaf" or "soon"))
    for _, leaf in ipairs(item.leaves or {}) do
      S.treeRows[leaf.key] = newTreeRow(leaf, Feats.LeafLive(leaf.key) and "leaf" or "soon")
    end
  end
end

local function drawTreeRow(x, r, i)
  local w = TREE_W - r.depth * TREE_INDENT
  x.b:SetSize(w, TREE_ROW_H)
  place(x.b, r.depth * TREE_INDENT, -(TREE_PAD + (i - 1) * TREE_PITCH))
  if x.kind == "parent" then
    if Kit.Atlas(x.art, "common-button-list-collapseExpand") and x.art.SetTextureSliceMargins then
      x.art:SetTextureSliceMargins(18, 0, 18, 0)
    end
    if x.icon then
      if r.open then
        x.icon:SetSize(PLUS, MINUS_H)
        Kit.Atlas(x.icon, "common-button-list-minus")
      else
        x.icon:SetSize(PLUS, PLUS)
        Kit.Atlas(x.icon, "common-button-list-plus")
      end
    end
    x.name:SetWidth(w - TREE_TEXT_X - TOGGLE_ROOM)
  else
    if Kit.Atlas(x.art, r.selected and "Legacy-Challenge-Left-Sub-Tab-selected" or "Legacy-Challenge-Left-Sub-Tab")
       and x.art.SetTextureSliceMargins then
      x.art:SetTextureSliceMargins(12, 12, 12, 12)
    end
    if x.soon then
      local m = x.soon.GetStringWidth and x.soon:GetStringWidth()
      x.name:SetWidth(w - TREE_TEXT_X - ((type(m) == "number" and m > 0) and m or SOON_W) - SOON_GAP)
    else
      x.name:SetWidth(w - TREE_TEXT_X - TREE_TEXT_RIGHT)
    end
  end
  if x.dot then
    if r.dot then
      Kit.Atlas(x.dot, "UI-HUD-MicroMenu-Communities-Icon-Notification")
    else
      x.dot:Hide()
    end
  end
  if x.kind == "soon" then
    x.name:SetTextColor(GREY[1], GREY[2], GREY[3])
  elseif r.selected then
    x.name:SetTextColor(1, 1, 1)
  else
    x.name:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  end
  x.b:Show()
end

local function drawTree()
  if not S.tree then return end
  local shown = {}
  local list = View.TreeRows(S.open, S.category, S.marks)
  for i, r in ipairs(list) do
    local x = S.treeRows[r.key]
    if x then
      drawTreeRow(x, r, i)
      shown[r.key] = true
    end
  end
  for key, x in pairs(S.treeRows) do if not shown[key] then x.b:Hide() end end
  S.tree:SetHeight(TREE_PAD + #list * TREE_PITCH - (TREE_PITCH - TREE_ROW_H) + TREE_PAD)
end

-- ---------- the rows in the scroll ----------

local function label(i, text, font, w, y, wrap)
  local fs = S.labels[i]
  if not fs then
    fs = S.content:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH("LEFT")
    S.labels[i] = fs
  end
  fs:SetFontObject(font)
  fs:SetWordWrap(wrap == true)
  fs:SetWidth(w)
  fs:SetText(text)
  place(fs, 0, y)
  fs:Show()
  local h = wrap and fs:GetStringHeight() or LINE_H
  return (type(h) == "number" and h > LINE_H) and h or LINE_H
end

-- One Lately row: a name button (its click opens that Journey) holding the line and the day.
local function latelyRow(i, row, w, y)
  local slot = S.lately[i]
  if not slot then
    local b = A.NameButton(S.content, row)
    if not b then return end
    slot = { b = b }
    slot.text = A.Label(b, "", "GameFontHighlightSmall")
    slot.text:SetPoint("LEFT", 4, 0)
    slot.right = A.Label(b, "", "GameFontHighlightSmall")
    slot.right:SetJustifyH("RIGHT")
    slot.right:SetWidth(RIGHT_W)
    slot.right:SetPoint("RIGHT", -4, 0)
    slot.right:SetTextColor(GREY[1], GREY[2], GREY[3])
    -- A cut line is whole in the tooltip (the row is read when the mouse enters).
    A.HoverTip(b, function() if slot.row then return slot.row.text or "" end end)
    S.lately[i] = slot
  end
  slot.b.guid = row.guid
  slot.b:SetSize(w, LINE_H)
  place(slot.b, 0, y)
  slot.text:SetWidth(w - 100)
  slot.text:SetText(row.text)
  slot.row = row
  slot.text:SetTextColor(A.ClassColour(row.class))
  slot.right:SetText(row.right or "")
  slot.b:Show()
end

-- ---------- a card's details (lg-2; plan D7, D12) ----------
-- Every card has the plus; a left mouse-up opens it in place (one open card, S.openKey) and a second closes it. The open
-- card hides its background for the tiled art under -selected and draws run-in blocks from the row's details: What
-- counts, How sure, and for vis guild "Also in the guild" (earned) / "In the guild". A mouse-up that follows a link
-- click on the same card does not toggle it (f3110).

local PM, PM_X, PM_Y = 20, 76, -49
local TILE_TOP_H, TILE_BOTTOM_H = 34, 83
-- The tiled middle runs from 10 under the card's top to 10 over its foot, under all of the top's and the bottom's
-- faded edges (the bottom fades in over its top 42), as Forever's LegacyChallengeTemplate BackgroundMiddle (t56, f5050).
local TILE_MID_INSET = 10
local SELECTED_SLICE = 12
local DETAILS_Y, BLOCK_GAP, END_PAD = 89, 6, 32
local STATUS_Y = 78          -- the bar on a card not yet earned
local STATUS_TEXT_Y = 75     -- "Not yet" or "Best so far" with no bar: its line ends by the first block at 89 (f3502)
local SHIELD_Y = -36         -- the shield's top: its bottom (-87) clears the first block at 89 (f3503)
local BLOCK_MAX, BLOCK_LESS = 400, 116
local DETAILS_FONT = "SystemFont_Shadow_Med1"
local HEAD_CODE, DAY_CODE = "|cffffd100", "|cff808080"
local ALSO_LINES, ALSO_SLACK = 2, 40

local function hex(v) return floor(math.max(0, math.min(1, v)) * 255 + 0.5) end

local function classCode(class)
  local r, g, b = A.ClassColour(class)
  return string.format("|cff%02x%02x%02x", hex(r), hex(g), hex(b))
end

-- One holder: the name (escaped by View) in class colour as an annals:<guid> link, then the day in grey.
local function alsoName(e)
  local text = "|Hannals:" .. tostring(e.guid) .. "|h" .. classCode(e.class) .. e.name
    .. (e.former and View.T_LEFT or "") .. "|r|h"
  if e.day and e.day ~= "" then text = text .. " " .. DAY_CODE .. e.day .. "|r" end
  return text
end

local function blockText(head, body) return HEAD_CODE .. head .. "|r " .. body end

-- The also block: as many whole names (1 to TIE_NAMES) as fit two lines of the width less 40, then "and N more"
-- (d501, as Race's tieText).
local function alsoText(fs, d, width)
  local also = d.also
  if #also == 0 then
    fs:SetText(blockText(d.alsoHead, View.T_NOBODY_ELSE))
    return
  end
  local k = math.min(#also, Rules.TIE_NAMES)
  while true do
    local shown = {}
    for i = 1, k do shown[i] = alsoName(also[i]) end
    local text = blockText(d.alsoHead, table.concat(shown, ", "))
    if k < #also then text = text .. string.format(View.T_MORE, #also - k) end
    fs:SetText(text)
    local w = type(fs.GetStringWidth) == "function" and fs:GetStringWidth() or nil
    if k <= 1 or type(w) ~= "number" or w <= ALSO_LINES * width - ALSO_SLACK then return end
    k = k - 1
  end
end

-- The plus/minus, the open art, the blocks and the card's link and mouse-up scripts, made once per card.
local function newDetails(card, x)
  x.pm = card:CreateTexture(nil, "OVERLAY")
  x.pm:SetSize(PM, PM)
  x.pm:SetPoint("TOPLEFT", PM_X, PM_Y)
  x.top = card:CreateTexture(nil, "BACKGROUND", nil, 1)
  x.top:SetPoint("TOPLEFT", 0, 0)
  x.top:SetPoint("TOPRIGHT", 0, 0)
  x.top:SetHeight(TILE_TOP_H)
  x.bottom = card:CreateTexture(nil, "BACKGROUND", nil, 1)
  x.bottom:SetPoint("BOTTOMLEFT", 0, 0)
  x.bottom:SetPoint("BOTTOMRIGHT", 0, 0)
  x.bottom:SetHeight(TILE_BOTTOM_H)
  x.mid = card:CreateTexture(nil, "BACKGROUND", nil, 0)
  x.mid:SetPoint("TOPLEFT", 0, -TILE_MID_INSET)
  x.mid:SetPoint("BOTTOMRIGHT", 0, TILE_MID_INSET)
  x.selected = card:CreateTexture(nil, "BORDER")
  x.selected:SetAllPoints(card)
  x.blocks = {}
  for i = 1, 3 do
    local fs = card:CreateFontString(nil, "OVERLAY", DETAILS_FONT)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    x.blocks[i] = fs
  end
  if card.SetHyperlinksEnabled then card:SetHyperlinksEnabled(true) end
  -- A.OpenJourney is looked up at click time, as A.NameButton does; only a guid of the page's G opens (f3109).
  -- The link flag lives for one click only: a mouse-down starts a click and clears it, a left link click sets it and
  -- the mouse-up reads and clears it, whatever the button or the order the client sends them in (f3510, f3532).
  card:SetScript("OnMouseDown", function() x.linked = nil end)
  card:SetScript("OnHyperlinkClick", function(_, link, _, button)
    if not A.M then return end
    A.M.Safe(function()
      if button ~= "LeftButton" then return end
      local guid = type(link) == "string" and link:match("^annals:(.+)$")
      if not guid then return end
      x.linked = true
      local G = A.PageG()
      if type(G) == "table" and ((type(G.chars) == "table" and G.chars[guid])
         or (type(G.former) == "table" and G.former[guid])) then
        A.M.Safe(A.OpenJourney, guid)
      end
    end)
  end)
  card:SetScript("OnMouseUp", function(_, button)
    if not A.M then return end
    A.M.Safe(function()
      local linked = x.linked
      x.linked = nil
      if button ~= "LeftButton" or linked then return end
      local key = x.row and x.row.key
      if key == nil then return end
      if S.openKey == key then S.openKey = nil else S.openKey, S.scrollTo = key, key end
      ns.AnnalsAchievements.refresh(S.holder)
    end)
  end)
end

-- Empties and hides the blocks from block `from` on.
local function hideBlocks(x, from)
  for i = from, #x.blocks do
    x.blocks[i]:SetText("")
    x.blocks[i]:Hide()
  end
end

local function hideDetails(x)
  x.top:Hide()
  x.mid:Hide()
  x.bottom:Hide()
  x.selected:Hide()
  hideBlocks(x, 1)
end

-- Draws the open card's art and blocks for row on a w-wide card; returns the card's height (the blocks' end + 32).
-- top: the first block's y, below the bar's frame or the "Not yet" line on a card not yet earned (f3502).
local function drawDetails(x, row, w, top)
  local d, done = row.details, row.state == "done"
  -- The closed background stays when the tiled art does not draw, so the card is never see-through (f3513).
  if Kit.Atlas(x.top, done and "Legacy-Challenge-Cards-tiled-top" or "Legacy-Challenge-Cards-tiled-top-Disable") then
    x.bg:Hide()
  end
  -- Tiled, not stretched; after the atlas, which resets the wrap (Forever's RefreshStateArt does the same).
  if Kit.Atlas(x.mid, done and "Legacy-Challenge-Cards-tiled-vertical" or "Legacy-Challenge-Cards-tiled-vertical-Disable")
     and x.mid.SetVertTile then
    x.mid:SetVertTile(true)
  end
  Kit.Atlas(x.bottom, done and "Legacy-Challenge-Cards-tiled-bottom" or "Legacy-Challenge-Cards-tiled-bottom-disable")
  if Kit.Atlas(x.selected, "Legacy-Challenge-Cards-selected") and x.selected.SetTextureSliceMargins then
    x.selected:SetTextureSliceMargins(SELECTED_SLICE, SELECTED_SLICE, SELECTED_SLICE, SELECTED_SLICE)
  end
  local bw = math.min(BLOCK_MAX, w - BLOCK_LESS)
  local y, n = top or DETAILS_Y, 0
  local function block(fill)
    n = n + 1
    local fs = x.blocks[n]
    if n > 1 then y = y + BLOCK_GAP end
    fs:SetWidth(bw)
    fill(fs)
    place(fs, TEXT_X, -y)
    fs:Show()
    local h = fs:GetStringHeight()
    y = y + ((type(h) == "number" and h > 0) and h or 0)
  end
  block(function(fs) fs:SetText(blockText("What counts", d.counts or "")) end)
  block(function(fs) fs:SetText(blockText("How sure", d.sure or "")) end)
  if type(d.also) == "table" then block(function(fs) alsoText(fs, d, bw) end) end
  hideBlocks(x, n + 1)
  return y + END_PAD
end

local function newCard()
  local card = Kit.Inset(S.content)
  if not card then return nil end
  local x = { f = card }
  x.bg = card:CreateTexture(nil, "BACKGROUND", nil, 1)
  x.bg:SetAllPoints(card)
  x.ribbon = card:CreateTexture(nil, "BORDER")
  x.ribbon:SetPoint("TOPLEFT", 5, -4)
  x.ribbon:SetPoint("TOPRIGHT", -80, -4)
  x.ribbon:SetHeight(RIBBON_H)
  x.iconFrame = card:CreateTexture(nil, "ARTWORK", nil, 2)
  x.iconFrame:SetSize(ICON_FRAME, ICON_FRAME)
  x.iconFrame:SetPoint("TOPLEFT", 12, -40)
  x.icon = card:CreateTexture(nil, "ARTWORK", nil, 1)
  x.icon:SetSize(ICON, ICON)
  x.icon:SetPoint("CENTER", x.iconFrame, "CENTER", 0, 0)
  x.icon:SetTexture(ICON_FILE)
  local mask = card.CreateMaskTexture and card:CreateMaskTexture()
  if mask then
    mask:SetAllPoints(x.icon)
    -- The mask only after its atlas was set (D10).
    if Kit.Atlas(mask, "UI-Frame-IconMask") and x.icon.AddMaskTexture then x.icon:AddMaskTexture(mask) end
  end
  x.name = A.Label(card, "", "GameFontHighlightLarge")
  x.name:SetPoint("TOPLEFT", 75, -22)
  x.desc = A.Label(card, "", "GameFontHighlight")
  x.desc:SetPoint("TOPLEFT", TEXT_X, -50)
  x.shield = card:CreateTexture(nil, "ARTWORK")
  x.shield:SetSize(CARD_SHIELD_W, CARD_SHIELD_H)
  -- By the title at a fixed top, so an open (taller) card keeps it there, clear of the details (f3503).
  x.shield:SetPoint("TOPRIGHT", -12, SHIELD_Y)
  x.points = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  x.points:SetPoint("CENTER", x.shield, "CENTER", 0, 2)
  x.date = card:CreateTexture(nil, "ARTWORK")
  x.date:SetSize(DATE_W, DATE_H)
  x.date:SetPoint("TOPRIGHT", 0, -1)
  x.check = card:CreateTexture(nil, "OVERLAY")
  x.check:SetSize(CHECK, CHECK)
  x.check:SetPoint("RIGHT", x.date, "LEFT", 4, 0)
  x.status = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  oneLine(x.status)
  x.dot = card:CreateTexture(nil, "OVERLAY")
  x.dot:SetSize(DOT, DOT)
  x.dot:Hide()
  x.bar = newBar(card)
  x.tag = A.Label(card, "", "GameFontHighlightSmall")
  x.tag:SetPoint("BOTTOMLEFT", TEXT_X, 8)
  x.tag:SetTextColor(GREY[1], GREY[2], GREY[3])
  newDetails(card, x)
  -- Name, description, status and tag are each one line; the tooltip holds them whole (x.row read on enter), and on
  -- an open card every name in "Also in the guild" (D12).
  if card.EnableMouse then card:EnableMouse(true) end
  A.HoverTip(card, function()
    local r = x.row
    if not r then return end
    local lines = { A.esc(r.desc) or "", r.status or "", r.tag or "" }
    local d = r.details
    if x.open and type(d.also) == "table" and #d.also > 0 then
      local names = {}
      for i, e in ipairs(d.also) do names[i] = e.name .. (e.former and View.T_LEFT or "") end
      lines[#lines + 1] = d.alsoHead .. ": " .. table.concat(names, ", ")
    end
    return r.text or "", lines
  end)
  return x
end

-- Draws card i for row at y; returns its height (CARD_H closed, from its blocks open).
local function drawCard(i, row, w, y)
  local x = S.cards[i] or newCard()
  if not x then return CARD_H end
  S.cards[i] = x
  local done = row.state == "done"
  x.open = row.key ~= nil and row.key == S.openKey and type(row.details) == "table"
  place(x.f, 0, y)
  Kit.Atlas(x.pm, x.open and "128-RedButton-Minus" or "128-RedButton-Plus")
  -- f3562: a card that never opens (an unearned secret has no details) draws no "+".
  if type(row.details) == "table" then x.pm:Show() else x.pm:Hide() end
  Kit.Atlas(x.bg, done and "Legacy-Challenge-Cards" or "Legacy-Challenge-Cards-Disable",
    done and CARD_FALLBACK or CARD_OFF_FALLBACK)
  Kit.Atlas(x.ribbon, done and "Legacy-Challenge-Cards-Ribbon-Brown" or "Legacy-Challenge-Cards-Ribbon-Brown-disable")
  Kit.Atlas(x.iconFrame, "Legacy-Tree-Frame-icon-frame")
  if x.icon.SetDesaturated then x.icon:SetDesaturated(not done) end
  x.name:SetWidth(w - 170)
  x.name:SetText(row.text)
  if done then x.name:SetTextColor(1, 1, 1) else x.name:SetTextColor(GREY[1], GREY[2], GREY[3]) end
  x.desc:SetWidth(w - TEXT_X - SHIELD_ROOM)
  x.desc:SetText(A.esc(row.desc) or "")
  Kit.Atlas(x.shield, "Legacy-Tree-Frame-Points-icon")
  x.points:SetText(row.points or "")
  x.tag:SetWidth(w - TEXT_X - SHIELD_ROOM)
  x.tag:SetText(row.tag or "")
  x.row = row
  x.status:ClearAllPoints()
  local a, b = string.match(row.status or "", "^(%d+) of (%d+)")
  local top = DETAILS_Y
  a, b = tonumber(a), tonumber(b)
  local hasBar = a and b and b > 0
  if done then
    Kit.Atlas(x.date, "Legacy-Challenge-Cards-Date-BG")
    Kit.Atlas(x.check, "worldquest-tracker-checkmark")
    x.status:SetPoint("CENTER", x.date, "CENTER", 8, 0)
    x.status:SetJustifyH("CENTER")
    x.status:SetWidth(DATE_TEXT_W)
    x.status:SetTextColor(1, 0.82, 0)
    hideBar(x.bar)
  else
    x.date:Hide()
    x.check:Hide()
    x.status:SetTextColor(GREY[1], GREY[2], GREY[3])
    if hasBar then
      drawBar(x.bar, TEXT_X, -STATUS_Y, CARD_BAR_W, share(a, b, CARD_BAR_W))
      top = math.max(DETAILS_Y, STATUS_Y + FILL_H + FRAME_BOTTOM + BLOCK_GAP)
      -- On the bar, as the Legacy bar carries its "a / b".
      x.status:SetPoint("CENTER", x.bar.bg, "CENTER", 0, 0)
      x.status:SetJustifyH("CENTER")
      x.status:SetWidth(CARD_BAR_W)
    else
      hideBar(x.bar)
      x.status:SetPoint("TOPLEFT", TEXT_X, -STATUS_TEXT_Y)
      x.status:SetJustifyH("LEFT")
      x.status:SetWidth(w - TEXT_X - SHIELD_ROOM)
    end
  end
  x.status:SetText(row.status or "")
  if not done and not hasBar then
    local sh = x.status:GetStringHeight()
    top = math.max(DETAILS_Y, STATUS_TEXT_Y + ((type(sh) == "number" and sh > 0) and sh or LINE_H) + BLOCK_GAP)
  end
  -- The new-mark dot (D9, D11): new, or new when this visit began; its RIGHT at the date text's drawn left edge -4.
  local v = S.visit
  if done and row.id ~= nil and ((S.marks and S.marks.ids[row.id]) or (v and v.snap[row.id])) then
    x.dot:ClearAllPoints()
    local sw = x.status:GetStringWidth()
    if type(sw) == "number" and sw > 0 then
      x.dot:SetPoint("RIGHT", x.status, "CENTER", -(sw * 0.5) - DOT_CARD_GAP, 0)
    else
      x.dot:SetPoint("RIGHT", x.status, "LEFT", -DOT_CARD_GAP, 0)
    end
    Kit.Atlas(x.dot, "UI-HUD-MicroMenu-Communities-Icon-Notification")
  else
    x.dot:Hide()
  end
  local h = CARD_H
  if x.open then h = drawDetails(x, row, w, top) else hideDetails(x) end
  x.f:SetSize(w, h)
  x.f:Show()
  return h
end

-- ---------- build and refresh ----------

local function build(holder)
  S.holder = holder
  -- The holder hiding ends the visit (D10); the next refresh begins a new one.
  holder:SetScript("OnHide", function() S.visit = nil end)
  S.note = A.Label(holder, "", "GameFontHighlight")
  S.note:SetPoint("TOPLEFT", 8, -8)
  buildHead(holder)
  buildTree(holder)
  S.scroll, S.content = A.Scroll(holder)
  if S.scroll then
    S.scroll:ClearAllPoints()
    S.scroll:SetPoint("TOPLEFT", Rules.CAT_W + Rules.COL_GAP, -Rules.TRACK_H)
    S.scroll:SetPoint("BOTTOMRIGHT", -Rules.SCROLL_W, 0)
  end
end

local function showHead(on)
  if on then S.head:Show() else S.head:Hide() end
  if S.treeScroll then if on then S.treeScroll:Show() else S.treeScroll:Hide() end end
  if S.scroll then if on then S.scroll:Show() else S.scroll:Hide() end end
end

local function refresh(holder)
  if not S.holder then build(holder) end
  local G = A.PageG()
  if A.NoGuild(G) then
    showHead(false)
    S.note:SetText(View.T_NO_GUILD)
    S.note:Show()
    return
  end
  S.note:Hide()
  showHead(true)
  local gen, me = A.DemoGen(), A.JourneySelf()
  -- D15: a demo G under a counter not seen yet opens as lg-5 (f3504, d509); demo off restores the defaults.
  if S.demoSeen ~= gen then
    S.demoSeen = gen
    if A.DrawsDemo(G) then
      S.open, S.category, S.openKey = { Company = true, Levelling = true }, "Together", "ns"
    else
      S.open, S.category, S.openKey = {}, "ALL", nil
    end
  end
  -- D10: a visit ends when the counter, the page G or the viewer differs from the ones it began with.
  local v = S.visit
  if v and (v.gen ~= gen or v.G ~= G or v.self ~= me) then v = nil end
  local fresh = not v
  if fresh then
    A.SeenStart()
    v = { gen = gen, G = G, self = me, snap = {} }
    S.visit = v
  end
  -- One NewMarks serves the snapshot and the leaf ids; a second follows MarkSeen under a leaf (f3516).
  S.marks = View.NewMarks(G, me)
  if fresh then for id in pairs(S.marks.ids) do v.snap[id] = true end end
  -- The selected leaf is marked seen on every refresh; its newly marked ids join the snapshot (f3111).
  if S.category ~= "ALL" then
    for _, id in ipairs(View.LeafIds(G, me, S.category)) do if S.marks.ids[id] then v.snap[id] = true end end
    A.MarkSeen(S.category)
    S.marks = View.NewMarks(G, me)
  end
  S.inRefresh = true
  A.PaintTabDot()
  S.inRefresh = nil
  local L = A.Layout()
  local rows = View.AchievementRows(G, me, A.Now(), S.category, { date = A.Date, open = S.openKey or false })
  drawTree()
  local scrollTo = S.scrollTo
  S.scrollTo = nil
  if not S.content then return end
  local w = L.cardW
  S.content:SetWidth(w)
  local y, nLabel, nLately, nCard = 0, 0, 0, 0
  local top, h = nil, nil
  for _, r in ipairs(rows) do
    if r.kind == "head" then
      drawHead(r, L)
    elseif r.kind == "header" and r.text == View.T_YOURS and S.category ~= "ALL" then
      -- d509 (lg-4, lg-5): under a selected leaf the cards start right under the track, with no "Yours".
    elseif r.kind == "header" then
      if y < 0 then y = y - GAP end
      nLabel = nLabel + 1
      y = y - label(nLabel, r.text, "GameFontNormal", w, y) - GAP
    elseif r.kind == "note" then
      nLabel = nLabel + 1
      y = y - label(nLabel, r.text, "GameFontHighlightSmall", w, y, true) - GAP
    elseif r.kind == "lately" then
      nLately = nLately + 1
      latelyRow(nLately, r, w, y)
      y = y - LINE_H
    elseif r.kind == "feat" then
      nCard = nCard + 1
      local ch = drawCard(nCard, r, w, y)
      if scrollTo ~= nil and r.key == scrollTo then top, h = -y, ch end
      y = y - ch - CARD_GAP
    end
  end
  for i = nLabel + 1, #S.labels do S.labels[i]:Hide() end
  for i = nLately + 1, #S.lately do S.lately[i].b:Hide() end
  for i = nCard + 1, #S.cards do S.cards[i].f:Hide() end
  S.content:SetHeight(-y + GAP)
  -- 19.below-fold: a card just opened whose opened bottom is below the view scrolls its top into view, once. The
  -- range is worked out here: the client's GetVerticalScrollRange lags SetHeight.
  local sh = S.scroll and S.scroll:GetHeight()
  if top and sh and sh > 0 and S.scroll.SetVerticalScroll then
    local cur = S.scroll.GetVerticalScroll and S.scroll:GetVerticalScroll() or 0
    if top + h > cur + sh then
      local range = math.max(0, -y + GAP - sh)
      S.scroll:SetVerticalScroll(math.min(math.max(top - GAP, 0), range))
    end
  end
end

ns.AnnalsAchievements = {
  key = "achievements",
  text = "Achievements",
  build = function(holder) build(holder) end,
  refresh = function(holder) refresh(holder) end,
  -- True while any leaf has a new mark (the tab dot, D9); A.PaintTabDot reads it.
  dot = function()
    local m = S.inRefresh and S.marks or View.NewMarks(A.PageG(), A.JourneySelf())
    return m.any == true
  end,
  -- The hub's window opened (f3103): the visit ends, and a shown tab draws the next one at once.
  windowOpened = function()
    S.visit = nil
    if S.holder and S.holder:IsShown() then refresh(S.holder) end
  end,
}
