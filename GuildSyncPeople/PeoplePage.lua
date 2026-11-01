-- GuildSyncPeople: the People page (run r-20261018-o696, plan Task 7; NOTES-o696.md "My profile (rp-6)").
-- The page is My profile only (PeopleProfile.lua: the profile and the "Your characters" card): no tabs, list, filter
-- or search; the guild's people are on the hub's Roster, whose member panel carries People's section.
-- Both are drawn in a scroll child (f8613, run r-20261030-s27 Task 10): at the page's full 726 x 508 (900x600) they
-- sit as the mock has them and nothing scrolls; on a smaller page (760x480 gives 586 x 388) the card moves under Save
-- and the content scrolls. The scroll frame, chosen by what the client makes: ScrollFrameTemplate when its bar comes
-- with it, else the named UIPanelScrollFrameTemplate, else a plain frame that clips its children and scrolls
-- on its own wheel. The scroll frame and the child each end on one TOPLEFT/TOPLEFT point, sized with SetSize.
-- Every ns.* function is looked up at call time (f10, crosscheck G4).

local _, ns = ...
if not ns.M then return end

local S = {}
local SCROLL_NAME = "GuildSyncPeopleProfileScroll"
local PAGE_W, PAGE_H = 726, 508 -- the mock's page; the layout is today's at this size and above
local GUTTER = 22 -- the bar's column right of the scroll frame on a smaller page (UIPanelScrollFrameTemplate: +6, 16 wide)
local CARD_GAP, CARD_H = 12, 474 -- the card under Save on a smaller page
local WHEEL_STEP = 30

-- -> scroll frame, bar (nil for the plain frame), plain (true for the plain frame)
local function makeScroll(page)
  -- ScrollFrameTemplate's OnLoad makes and joins its bar (as the hub's member panel, Window.lua:2152-2171), so it is
  -- kept only when the bar came with it
  local good, scroll = pcall(CreateFrame, "ScrollFrame", nil, page, "ScrollFrameTemplate")
  if good and scroll then
    local bar = scroll.ScrollBar
    if type(bar) == "table" then
      bar:ClearAllPoints()
      bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 8, 0)
      bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 8, 0)
      if type(bar.SetHideIfUnscrollable) == "function" then bar:SetHideIfUnscrollable(true) end
      return scroll, bar
    end
    scroll:Hide()
  end
  good, scroll = pcall(CreateFrame, "ScrollFrame", SCROLL_NAME, page, "UIPanelScrollFrameTemplate")
  if good and scroll then
    local bar = _G[SCROLL_NAME .. "ScrollBar"]
    if bar then
      scroll.scrollBarHideable = true -- the template hides the bar while nothing scrolls
      return scroll, bar
    end
    scroll:Hide()
  end
  local box = CreateFrame("Frame", nil, page)
  if box.SetClipsChildren then box:SetClipsChildren(true) end
  return box, nil, true
end

function ns.BuildPage(frame)
  local scroll, bar, plain = makeScroll(frame)
  local child = CreateFrame("Frame", nil, scroll)
  local offset = 0 -- the plain frame's scroll, in px down
  local function placeChild()
    child:ClearAllPoints()
    child:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, offset)
  end
  if plain then
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
      ns.M.Safe(function()
        local most = math.max(0, (child:GetHeight() or 0) - (scroll:GetHeight() or 0))
        offset = math.min(most, math.max(0, offset - (tonumber(delta) or 0) * WHEEL_STEP))
        placeChild()
      end)
    end)
  else
    scroll:SetScrollChild(child)
  end

  S.profile = ns.BuildProfile(child)
  S.characters = ns.BuildCharacters(child)
  S.profile.characters = S.characters -- the one Save sends the card's pick and hidden set too

  local function layout(w, h)
    w = (type(w) == "number" and w > 0) and w or PAGE_W
    h = (type(h) == "number" and h > 0) and h or PAGE_H
    local roomy = w >= PAGE_W and h >= PAGE_H
    local cw = roomy and PAGE_W or (w - GUTTER)
    local ch = roomy and PAGE_H or (PAGE_H + CARD_GAP + CARD_H)
    scroll:ClearAllPoints()
    scroll:SetSize(roomy and w or cw, h)
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    child:SetSize(cw, ch)
    offset = math.min(offset, math.max(0, ch - h))
    placeChild()
    if S.profile.header then S.profile.header:SetWidth(cw) end
    local card = S.characters and S.characters.card
    if card then
      card:ClearAllPoints()
      if roomy then
        card:SetPoint("TOPLEFT", child, "TOPLEFT", 526, -34)
      else
        card:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(PAGE_H + CARD_GAP))
      end
    end
    if bar then bar:SetShown(not roomy) end
  end
  layout(frame:GetWidth(), frame:GetHeight())
  frame:SetScript("OnSizeChanged", function(_, w, h) ns.M.Safe(layout, w, h) end)
  -- the hub runs refresh right after build
end

function ns.RefreshPage()
  if S.profile then S.profile:Refresh() end
  if S.characters then S.characters.Refresh() end
end
