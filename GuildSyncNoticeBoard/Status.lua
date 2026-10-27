-- GuildSyncNoticeBoard: the selftest, the status line and the /gsboard slash (brief AC18, AC29, AC31, AC42 as sliced by
-- ui-slice.md; AC21: the selftest FAILs naming every domain whose Store.Attached() value is not true). Everything
-- here reads; the only write is the lead
-- setting. No slash word makes a calendar call: `status` prints values recorded earlier.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local Status = {}
ns.Status = Status

local rosterSeen = false
M.On("rosterRead", function() rosterSeen = true end)

local function say(text) GuildSync.Say(text) end

local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

function Status.Selftest()
  if not rosterSeen then return "wait", "waiting for the guild roster" end
  local down = {}
  for _, id in ipairs({ "board", "board_m", "board_o" }) do
    local v = ns.Store.Attached()[id]
    if v ~= true then down[#down + 1] = id .. " (" .. tostring(v or "not attached") .. ")" end
  end
  if #down > 0 then return "fail", "domain not attached: " .. table.concat(down, ", ") end
  local rows = ns.Cal.Rows() or {}
  local notices, polls = ns.Store.Counts()
  local text = plural(#rows, "event") .. ", " .. plural(notices, "notice") .. ", " .. plural(polls, "open poll")
  if ns.Cal.Closed() then text = text .. ", calendar: closed" end
  return "pass", text
end

function Status.Line()
  local _, text = Status.Selftest()
  return text
end

local function yesNo(v)
  if v == nil then return "not read yet" end
  return v and "true" or "false"
end

local USAGE = "/gsboard opens the board; /gsboard status; /gsboard lead <minutes> (0 turns the before-start line off; also under Options > GuildSync > Notice Board);"
  .. " /gsboard banners shows every banner."

-- ---------- /gsboard banners (spec banners.md B7) ----------
-- Every banner of every kind's set as a 120 x 60 tile with "<id>  <label>" under it, grouped by kind, so the beta can
-- see which ones load on Forever. Reads only Banners.lua; never decides whether a texture loaded (SetTexture's return
-- on Forever is unknown, so it is not read). Built once, toggled on repeat.

local TILE_W, TILE_H, LABEL_H, GAP, PER_ROW, PAD = 120, 60, 16, 8, 6, 12
local GRID_W = PER_ROW * (TILE_W + GAP) - GAP
local grid

local function buildGrid()
  local B = ns.Banners
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetSize(GRID_W + 2 * PAD + 24, 520)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  local back = f:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints(f)
  back:SetColorTexture(0, 0, 0, 0.85) -- as GuildSync/CraftUI.lua:1135
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
  title:SetText("Notice Board banners")
  local close = ns.Look.Button(f, "Close", function() f:Hide() end)
  close:SetSize(80, 22)
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -8)
  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -40)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD - 24, PAD)
  local content = CreateFrame("Frame", nil, scroll)
  scroll:SetScrollChild(content)

  local y = 0
  for _, kind in ipairs(B.KINDS) do
    local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    header:SetText(ns.Rules.TypeLabel(kind))
    y = y + 20
    for i, id in ipairs(B.Set(kind)) do
      local col, row = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
      local x, top = col * (TILE_W + GAP), y + row * (TILE_H + LABEL_H + GAP)
      local tex = content:CreateTexture(nil, "ARTWORK")
      tex:SetSize(TILE_W, TILE_H)
      tex:SetPoint("TOPLEFT", content, "TOPLEFT", x, -top)
      local emblem = content:CreateTexture(nil, "OVERLAY")
      B.Draw(tex, id, TILE_W, TILE_H, emblem)
      local label = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      label:SetPoint("TOPLEFT", tex, "BOTTOMLEFT", 0, -2)
      label:SetWidth(TILE_W)
      label:SetJustifyH("LEFT")
      label:SetText(id .. "  " .. B.LIST[id].label)
    end
    local rows = math.floor((#B.Set(kind) + PER_ROW - 1) / PER_ROW)
    y = y + rows * (TILE_H + LABEL_H + GAP) + GAP
  end
  content:SetSize(GRID_W, y)
  return f
end

local function toggleGrid()
  if not grid then
    grid = buildGrid()
    grid:Show()
  elseif grid:IsShown() then
    grid:Hide()
  else
    grid:Show()
  end
end

function Status.Slash(rest)
  local word, arg = string.match(string.lower(tostring(rest or "")), "^%s*(%S*)%s*(.-)%s*$")
  if word == "" then
    ns.M.OpenPage()
  elseif word == "status" then
    say("Notice Board: " .. Status.Line())
    local Ev = ns.Event
    say("Index field of the last event open: " .. tostring(Ev and Ev.IndexField() or "none yet"))
    say("Guild events enabled (AreGuildEventsEnabled): " .. yesNo(ns.Cal.GuildEventsEnabled()))
  elseif word == "lead" and tonumber(arg) then
    if ns.InDemo() then ns.Inert() return end -- C4: nothing from demo reaches the saved lead
    if not ns.Remind.SetLead(arg) then
      say("Lead refused: give minutes from 0 to 1440 (0 turns the before-start line off).")
      return
    end
    local n = ns.DB().lead
    say(n == 0 and "Before-start line: off." or ("Before-start line: " .. n .. " minutes before the start."))
  elseif word == "banners" then
    toggleGrid()
  else
    say(USAGE)
  end
end

SLASH_GSBOARD1 = "/gsboard"
SlashCmdList.GSBOARD = function(msg) ns.M.Safe(Status.Slash, msg) end
