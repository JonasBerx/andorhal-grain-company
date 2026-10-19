-- GuildSyncPeople: the member section under the Roster's member panel (API 7 `member` field; look A, d831, the
-- approved mock NOTES-o696 rp-1 and rp-5). The lines and the height come from the pure ns.Card.Section; this file only
-- puts them on FontStrings. Frame contract (R3): GuildSync anchors, sizes the width of, shows and hides frame; this file
-- draws into it and sets only its height. One frame serves every selection: each refresh hides every string it made,
-- then draws the selected member's lines. Every ns.* function is looked up at call time (f10).

local _, ns = ...
if not ns.M then return end

local GREY = 0.5
local pools = {} -- frame -> { [font .. tint] = { FontString, ... } }

function ns.BuildSection(frame) pools[frame] = pools[frame] or {} end

-- The profile reader: the demo state's views while demo is on, else People's records.
local function recReader()
  local on, state = ns.M.Demo()
  if not on then return ns.RecOf end
  local views = type(state) == "table" and type(state.views) == "table" and state.views or {}
  return function(k)
    local v = views[k]
    return type(v) == "table" and v.rec or nil
  end
end

function ns.RefreshSection(frame, key)
  local pool = pools[frame] or {}
  pools[frame] = pool
  for _, list in pairs(pool) do
    for _, fs in ipairs(list) do fs:Hide() end
  end
  local person, recOf = ns.PersonOf(key), recReader()
  local rec
  if person then rec = ns.Card.ProfileOf(person, recOf) elseif type(key) == "string" then rec = recOf(key) end
  local width = tonumber(frame:GetWidth()) or 0
  if width <= 0 then width = 166 end
  local items, height = ns.Card.Section({ key = key, rec = rec }, person, ns.Now(), width)
  -- shift: how far the client's real wrapping (measured) has pushed the blocks below past the letter model's place
  local used, shift, bottom = {}, 0, height
  for _, it in ipairs(items) do
    local kind = it.font .. (it.colour and ":grey" or "")
    local list = pool[kind] or {}
    pool[kind] = list
    used[kind] = (used[kind] or 0) + 1
    local fs = list[used[kind]]
    if not fs then
      fs = frame:CreateFontString(nil, "OVERLAY", it.font)
      fs:SetJustifyH("LEFT")
      fs:SetJustifyV("TOP")
      fs:SetWordWrap(true)
      if it.colour then fs:SetTextColor(GREY, GREY, GREY) end
      list[#list + 1] = fs
    end
    fs:ClearAllPoints()
    local top = it.y + shift
    fs:SetPoint("TOPLEFT", frame, "TOPLEFT", it.x, -top)
    fs:SetWidth(width)
    fs:SetMaxLines(it.wrap or it.lines)
    fs:SetText(it.text)
    fs:Show()
    -- a wrapping block is the larger of the model's height and the measured one, so real wrapping is never cut (f5552)
    local model, measured = it.lines * ns.Card.LINE, it.wrap and tonumber(fs:GetStringHeight()) or nil
    local h = math.max(model, measured or 0)
    bottom = top + h -- the frame ends under the last item
    shift = shift + ns.Card.NextTop(it.y, h) - ns.Card.NextTop(it.y, model)
  end
  frame:SetHeight(bottom)
end

-- A person may have changed (a record merged or pruned, a setting, a roster read): redraw the selected member.
ns.M.On("links", function() ns.M.RefreshMember() end)
