-- GuildSyncPeople: the My profile view, the whole People page (plan Task 5, narrowed by run r-20261018-o696 Task 7 to
-- NOTES-o696.md "My profile (rp-6)"). Drawn with M.Kit (HeaderBar, InputBox, SectionHeader x2, Checkbox x13), the large
-- week grid (PeopleGrid.lua), plain FontStrings and a UIPanelButtonTemplate Save. Page coordinates are the mock's, from
-- the page's top-left (726 x 508). ns.BuildCharacters draws the "Your characters" card at its right (Kit.Inset
-- with the Roster member panel's black .42 fill, HeaderBar, Dropdown, Checkbox): the Main pick and a Hide box per character from M.MyCharacters (the demo state's mine
-- while demo is on). The one Save sends the profile (ns.Save) and then the card's pick and full hidden set (M.SetLinks).
-- view:Refresh() reads the clock once (ns.Now) for the hint and the grid's outline, and loads the saved profile and the
-- characters into the editors only when they changed, so a page refresh from incoming records does not wipe an edit in
-- progress. Every ns.* function is looked up at call time (f10, crosscheck G4).

local _, ns = ...
if not ns.M then return end

local GREY = 0.72
local COLUMNS, ROWS = { 6, 176, 346 }, { 112, 140, 168, 196 } -- the checkboxes, column-first
local AUTO = "Automatic: highest level"
local SAVE_LINE = "Guildmates see a change the next time they meet one of your characters online."
local TAG_LABEL = 'Show "(Main: Name)" before an alt\'s line in guild chat'
local TAG_LINE = "Only on your screen; it changes at once, without Save."
local ROSTER_LINE = "Profile saved; your characters wait for the guild roster."
local ROW_Y, ROW_GAP = 108, 30 -- the card's character rows

local function text(parent, font, x, y, grey)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  if grey then fs:SetTextColor(GREY, GREY, GREY) end
  return fs
end

local function headerText()
  local key = ns.MyKey()
  local view = key and ns.ViewOf(key)
  if type(view) == "table" and type(view.name) == "string" then return "My profile: " .. view.name end
  return "My profile"
end

-- this account's characters and the pick: the demo state's mine while demo is on, else M.MyCharacters (needs 7)
local function myCharacters()
  local on, state = ns.M.Demo()
  if on then
    local mine = type(state) == "table" and state.mine or nil
    if type(mine) ~= "table" then return {}, nil end
    return type(mine.chars) == "table" and mine.chars or {}, mine.pick
  end
  if type(ns.M.MyCharacters) ~= "function" then return {}, nil end
  local chars, pick = ns.M.MyCharacters()
  return type(chars) == "table" and chars or {}, pick
end

-- "Ayanna Dawnguard 60": the menu's entry for a character
local function charLabel(ch)
  local s = ns.Escape(tostring(ch.name))
  if type(ch.level) == "number" then s = s .. " " .. ch.level end
  return s
end

-- The "Your characters" card (rp-6), beside My profile on the page (PeoplePage.lua builds both).
-- -> { Refresh, Links } or nil without the kit's inset.
function ns.BuildCharacters(parent)
  local K = ns.M.Kit
  local card = K.Inset(parent) -- an inset with the Roster member panel's fill, not a Kit.Card (f5621)
  if not card then return nil end
  card:SetSize(200, 474)
  card:SetPoint("TOPLEFT", parent, "TOPLEFT", 526, -34)
  local fill = card:CreateTexture(nil, "BACKGROUND", nil, 1)
  fill:SetAllPoints(card)
  fill:SetColorTexture(0, 0, 0, 0.42)
  local cv = { chars = {}, hidden = {}, rows = {} }

  local bar = K.HeaderBar(card, "Your characters", 188)
  if bar then bar:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -8) end
  text(card, "GameFontNormalSmall", 10, 44):SetText("Main")

  local dd
  local function pickText()
    for _, ch in ipairs(cv.chars) do if ch.key == cv.pick then return charLabel(ch) end end
    return AUTO
  end
  local function setPick(key)
    cv.pick = key
    if dd then K.DropdownText(dd, pickText()) end
  end
  dd = K.Dropdown(card, 176, function(_, root)
    root:CreateRadio(AUTO, function() return cv.pick == nil end, function() ns.M.Safe(function() setPick(nil) end) end)
    root:CreateDivider()
    for _, ch in ipairs(cv.chars) do
      local key = ch.key
      local e = root:CreateRadio(charLabel(ch), function() return cv.pick == key end,
        function() ns.M.Safe(function() setPick(key) end) end)
      if cv.hidden[key] and type(e) == "table" and type(e.SetEnabled) == "function" then e:SetEnabled(false) end
    end
  end)
  if dd then
    dd:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -58)
    K.DropdownText(dd, AUTO)
  end

  text(card, "GameFontNormalSmall", 10, 96):SetText("Characters")
  text(card, "GameFontNormalSmall", 166, 96):SetText("Hide")
  local foot = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  foot:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 8)
  foot:SetWidth(180)
  foot:SetJustifyH("LEFT")
  foot:SetWordWrap(true)
  foot:SetTextColor(GREY, GREY, GREY)
  foot:SetText("Hidden characters are left out of what your characters tell the guild.")

  -- a row: icon (10, y+7), name in class colour (30, y+10), level right-aligned at 152, Hide box (162, y)
  local function rowAt(i)
    local r = cv.rows[i]
    if r then return r end
    local y = ROW_Y + (i - 1) * ROW_GAP
    r = {}
    r.icon = card:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(16, 16)
    r.icon:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -(y + 7))
    r.name = text(card, "GameFontHighlightSmall", 30, y + 10)
    r.name:SetWidth(104)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.level = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.level:SetPoint("TOPRIGHT", card, "TOPLEFT", 152, -(y + 10))
    r.hide = K.Checkbox(card, "")
    if r.hide then
      r.hide:SetPoint("TOPLEFT", card, "TOPLEFT", 162, -y)
      r.hide:SetScript("OnClick", function(self)
        ns.M.Safe(function()
          local on = self:GetChecked() == true
          cv.hidden[r.key] = on or nil
          if on and cv.pick == r.key then setPick(nil) end -- a hidden character cannot be the main
        end)
      end)
    end
    cv.rows[i] = r
    return r
  end

  local loaded -- the last answer put into the card, as a string
  function cv.Refresh()
    local chars, pick = myCharacters()
    local parts = { tostring(pick) }
    for _, ch in ipairs(chars) do
      parts[#parts + 1] = table.concat({ tostring(ch.key), tostring(ch.name), tostring(ch.level), tostring(ch.class),
        tostring(ch.hidden) }, ":")
    end
    local stamp = table.concat(parts, "|")
    if stamp == loaded then return end
    loaded = stamp
    cv.chars, cv.hidden = {}, {}
    for _, ch in ipairs(chars) do
      if type(ch) == "table" and type(ch.key) == "string" then
        cv.chars[#cv.chars + 1] = ch
        if ch.hidden == true then cv.hidden[ch.key] = true end
      end
    end
    for i, r in ipairs(cv.rows) do
      if not cv.chars[i] then
        r.icon:Hide()
        r.name:Hide()
        r.level:Hide()
        if r.hide then r.hide:Hide() end
      end
    end
    for i, ch in ipairs(cv.chars) do
      local r = rowAt(i)
      r.key = ch.key
      if r.class ~= ch.class then
        r.class = ch.class
        r.shown = K.ClassIcon(r.icon, ch.class, "groupfinder-icon-class-")
      end
      r.icon:SetShown(r.shown and true or false)
      r.name:SetText(ns.Escape(tostring(ch.name)))
      local col = ns.Card.CLASS_COLOUR[ch.class] or { 1, 1, 1 }
      r.name:SetTextColor(col[1], col[2], col[3])
      r.name:Show()
      r.level:SetText(type(ch.level) == "number" and tostring(ch.level) or "")
      r.level:Show()
      if r.hide then
        r.hide:SetChecked(cv.hidden[ch.key] == true)
        r.hide:Show()
      end
    end
    setPick(type(pick) == "string" and not cv.hidden[pick] and pick or nil)
  end

  -- what Save sends: the pick (nil for automatic, never a hidden one) and the full hidden set { [key] = true }
  function cv.Links()
    local hidden = {}
    for key in pairs(cv.hidden) do hidden[key] = true end
    local pick = cv.pick
    if pick and hidden[pick] then pick = nil end
    return pick, hidden
  end

  return cv
end

function ns.BuildProfile(parent)
  local K = ns.M.Kit
  local view = {}

  local bar = K.HeaderBar(parent, headerText(), 726)
  if bar then bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0) end
  text(parent, "GameFontHighlightSmall", 6, 32, true):SetText("Your profile is shared by all your characters in this guild.")

  text(parent, "GameFontNormalSmall", 6, 57):SetText("Note")
  local count = text(parent, "GameFontHighlightSmall", 468, 57, true)
  count:SetText(ns.Rules.Counter(""))
  local box = K.InputBox(parent, 416, 416)
  if box then
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 44, -51)
    box:SetAutoFocus(false)
    box:SetMaxLetters(ns.Rules.NOTE_LETTERS)
    box:HookScript("OnTextChanged", function(self)
      ns.M.Safe(function() count:SetText(ns.Rules.Counter(self:GetText())) end)
    end)
  end

  local likes = K.SectionHeader(parent, 516, "What I like")
  if likes then likes:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -82) end
  local boxes = {}
  for i, tag in ipairs(ns.Rules.TAGS) do
    local cb = K.Checkbox(parent, tag.label)
    if cb then
      cb:SetPoint("TOPLEFT", parent, "TOPLEFT", COLUMNS[math.floor((i - 1) / 4) + 1], -ROWS[(i - 1) % 4 + 1])
      boxes[tag.code] = cb
    end
  end

  local online = K.SectionHeader(parent, 516, "Usually online (server time)")
  if online then online:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -230) end
  local grid = ns.Grid.Build(parent, "large", true)
  grid:SetPoint("TOPLEFT", parent, "TOPLEFT", 40, -274)
  local hint = text(parent, "GameFontHighlightSmall", 6, 406, true)

  -- the chat tag switch (ns.Tag): set at once, outside Save
  local tagBox = K.Checkbox(parent, TAG_LABEL)
  if tagBox then
    tagBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, -432)
    tagBox:SetScript("OnClick", function(self)
      ns.M.Safe(function() ns.SetTag(self:GetChecked() == true) end)
    end)
    text(parent, "GameFontHighlightSmall", 38, 457, true):SetText(TAG_LINE)
  end

  local save = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  save:SetSize(80, 22)
  save:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -486)
  save:SetText("Save")
  local saveLine = text(parent, "GameFontHighlightSmall", 92, 492, true)
  saveLine:SetText(SAVE_LINE)
  save:SetScript("OnClick", function()
    ns.M.Safe(function()
      local tags = {}
      for _, tag in ipairs(ns.Rules.TAGS) do
        local cb = boxes[tag.code]
        if cb and cb:GetChecked() == true then tags[#tags + 1] = tag.code end
      end
      local chars = view.characters -- the page's "Your characters" card, set by ns.BuildPage
      local pick, hidden
      if chars then pick, hidden = chars.Links() end -- read before ns.Save, whose page refresh reloads the card
      local saved, why = ns.Save(box and box:GetText() or "", tags, grid:GetMask())
      -- in demo ns.Save has said the inert line; M.SetLinks would say it again
      if not chars or why == "demo" or type(ns.M.SetLinks) ~= "function" then return end
      -- the profile and the links are separate stores: the links are sent even when ns.Save refused
      local linksOk, linksWhy = ns.M.SetLinks(pick, hidden)
      if not linksOk and linksWhy ~= nil and linksWhy ~= "roster" and linksWhy ~= "demo" then
        saveLine:SetText("Your characters were not saved: " .. ns.Escape(tostring(linksWhy)) .. ".") -- f5553
      else
        saveLine:SetText(saved and linksWhy == "roster" and ROSTER_LINE or SAVE_LINE) -- "Profile saved" only when it was
      end
    end)
  end)

  local loaded -- the saved profile's editedAt last put into the editors ("none" for no profile)
  function view.Refresh()
    local now = ns.Now()
    if bar and bar.label then bar.label:SetText(headerText()) end
    local profile = ns.Profile()
    local stamp = profile and tostring(profile.editedAt) or "none"
    -- the first saved profile seen after "none" (the guild key resolved) does not wipe what was typed meanwhile (R-f4b)
    local typed = false
    if loaded == "none" and stamp ~= loaded then
      local empty = ns.Card.Editor(nil)
      typed = (box and box:GetText() or "") ~= "" or grid:GetMask() ~= empty.mask
      for _, cb in pairs(boxes) do if cb:GetChecked() == true then typed = true end end
    end
    if stamp ~= loaded and typed then
      loaded = stamp
      grid:SetMask(grid:GetMask(), now)
    elseif stamp ~= loaded then
      loaded = stamp
      local ed = ns.Card.Editor(profile)
      if box then box:SetText(profile and profile.note or "") end
      count:SetText(ed.counter)
      for code, cb in pairs(boxes) do cb:SetChecked(ed.checks[code] == true) end
      grid:SetMask(ed.mask, now)
    else
      grid:SetMask(grid:GetMask(), now)
    end
    if tagBox then tagBox:SetChecked(ns.Tag()) end
    hint:SetText(string.format("Click or drag to mark hours. Server time now: %s %02d:%02d",
      ns.Rules.DAY_NAME[now.weekday] or "?", now.hour, now.minute))
  end

  return view
end
