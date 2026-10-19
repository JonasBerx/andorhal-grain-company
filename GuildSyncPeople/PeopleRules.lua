-- GuildSyncPeople: the tag table, the week mask, the UTF-8 cut and the note cleaner (plan Task 2).
-- Pure: no guard, no client call, no global outside the Annals allow-list (check-rules/GuildSyncPeople.json).

local _, ns = ...
local R = {}
ns.Rules = R

-- The 12 tag codes (d388), module order. On the wire the codes are concatenated, each at most once, in this order.
R.TAGS = {
  { code = "pv", label = "PvP" }, { code = "wp", label = "World PvP" }, { code = "pe", label = "PvE" },
  { code = "ra", label = "Raids" }, { code = "du", label = "Dungeons" }, { code = "lv", label = "Levelling" },
  { code = "pr", label = "Professions" }, { code = "gm", label = "Gold making" }, { code = "co", label = "Collecting" },
  { code = "rp", label = "Role-play" }, { code = "so", label = "Social" }, { code = "sh", label = "Sherpa" },
}
R.LABEL = {}
for _, t in ipairs(R.TAGS) do R.LABEL[t.code] = t.label end

-- Display order Monday first, as calendar weekdays (default calendar: 1 = Sunday). If B8 says otherwise only this changes.
R.DAYS = { 2, 3, 4, 5, 6, 7, 1 }
R.DAY_NAME = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" } -- by calendar weekday

R.MASK_DIGITS = 42
local ZERO = string.rep("0", R.MASK_DIGITS)

-- A mask is exactly 42 lowercase hex digits; anything else reads as no hours.
function R.ValidMask(mask)
  return type(mask) == "string" and #mask == R.MASK_DIGITS and not mask:find("[^0-9a-f]")
end

-- Bit (weekday - 1) * 24 + hour; hex digit k holds bits 4(k-1)..4(k-1)+3, lowest bit worth 1 (arithmetic only).
local function locate(weekday, hour)
  if type(weekday) ~= "number" or type(hour) ~= "number" then return nil end
  if weekday < 1 or weekday > 7 or hour < 0 or hour > 23 then return nil end
  local index = (weekday - 1) * 24 + hour
  return math.floor(index / 4) + 1, 2 ^ (index % 4)
end

function R.Has(mask, weekday, hour)
  if not R.ValidMask(mask) then return false end
  local k, worth = locate(weekday, hour)
  if not k then return false end
  return math.floor(tonumber(mask:sub(k, k), 16) / worth) % 2 == 1
end

function R.Set(mask, weekday, hour, on)
  if not R.ValidMask(mask) then mask = ZERO end
  local k, worth = locate(weekday, hour)
  if not k then return mask end
  local v = tonumber(mask:sub(k, k), 16)
  local has = math.floor(v / worth) % 2 == 1
  if on and not has then v = v + worth elseif not on and has then v = v - worth end
  return mask:sub(1, k - 1) .. string.format("%x", v) .. mask:sub(k + 1)
end

-- One day's runs of set hours as "from-to" (to = last set hour + 1), joined with " and "; "" when none.
local function dayRuns(mask, weekday)
  local out, h = {}, 0
  while h < 24 do
    if R.Has(mask, weekday, h) then
      local from = h
      while h < 24 and R.Has(mask, weekday, h) do h = h + 1 end
      out[#out + 1] = from .. "-" .. h
    else
      h = h + 1
    end
  end
  return table.concat(out, " and ")
end

-- Days of one group (display positions, ascending): two or more in a row as "Mon-Fri", the rest listed; no wrap.
local function dayList(positions)
  local items, i = {}, 1
  while i <= #positions do
    local j = i
    while j < #positions and positions[j + 1] == positions[j] + 1 do j = j + 1 end
    local first = R.DAY_NAME[R.DAYS[positions[i]]]
    items[#items + 1] = j > i and (first .. "-" .. R.DAY_NAME[R.DAYS[positions[j]]]) or first
    i = j + 1
  end
  return table.concat(items, ", ")
end

-- "Mon-Fri 19-23, Sat-Sun 14-24 (server time), around now"; maxGroups (tooltip) adds " +<n> more"; nil with no hours.
function R.WhenText(mask, weekday, hour, maxGroups)
  if not R.ValidMask(mask) then return nil end
  local groups, byRuns = {}, {}
  for pos, day in ipairs(R.DAYS) do
    local runs = dayRuns(mask, day)
    if runs ~= "" then
      local g = byRuns[runs]
      if not g then
        g = { runs = runs, days = {} }
        byRuns[runs] = g
        groups[#groups + 1] = g
      end
      g.days[#g.days + 1] = pos
    end
  end
  if #groups == 0 then return nil end
  local shown = #groups
  if maxGroups and shown > maxGroups then shown = maxGroups end
  local parts = {}
  for i = 1, shown do parts[i] = dayList(groups[i].days) .. " " .. groups[i].runs end
  local text = table.concat(parts, ", ")
  if shown < #groups then text = text .. " +" .. (#groups - shown) .. " more" end
  text = text .. " (server time)"
  if R.Has(mask, weekday, hour) then text = text .. ", around now" end
  return text
end

-- UTF-8 letters: every byte that is not a continuation byte starts one.
function R.Letters(text)
  if type(text) ~= "string" then return 0 end
  local n = 0
  for _ in text:gmatch("[^\128-\191]") do n = n + 1 end
  return n
end

-- The first n letters, never splitting one; the second answer says whether anything was cut.
function R.CutLetters(text, n)
  if type(text) ~= "string" then return "", false end
  local count, i = 0, 1
  while i <= #text do
    local c = text:byte(i)
    if c < 0x80 or c >= 0xC0 then
      count = count + 1
      if count > n then return text:sub(1, i - 1), true end
    end
    i = i + 1
  end
  return text, false
end

-- At most max bytes, cut back to a letter boundary.
function R.CutBytes(text, max)
  if #text <= max then return text end
  local cut = max
  while cut > 0 do
    local c = text:byte(cut + 1)
    if c < 0x80 or c >= 0xC0 then break end
    cut = cut - 1
  end
  return text:sub(1, cut)
end

-- Remove | ~ ^ and control characters (bytes below 0x20 and 0x7F).
function R.Strip(text)
  if type(text) ~= "string" then return "" end
  return (text:gsub("[%z\1-\31\127|~^]", ""))
end

R.NOTE_LETTERS = 140

-- The note as saved and sent: stripped, then cut to 140 letters.
function R.CleanNote(text)
  return (R.CutLetters(R.Strip(text), R.NOTE_LETTERS))
end

-- The editor's letter counter: "110 / 140".
function R.Counter(note)
  return R.Letters(note or "") .. " / " .. R.NOTE_LETTERS
end
