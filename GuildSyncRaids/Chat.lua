local _, ns = ...
if not ns.M then return end
-- Chat.lua: F (shared piece F), wave 1 (F, second PR). Contract F (plan Task 4): the chat listeners, their counts,
-- line packing and the one chat line a click may say. No UI here.
-- A chat payload can be a protected secret value. Every value is read through the hub's Plain first; a secret is never
-- compared, concatenated, indexed, measured or passed on: the line is counted hidden and dropped.
-- ns.SayLine is called from a button OnClick only, never from an event path. It sends only when the saved setting
-- session.send is true and every chat check is open; otherwise it fills the chat box. In demo it does nothing.

local M = ns.M
local Plain = GuildSync.Compat.Plain

local KIND = { CHAT_MSG_LOOT = "loot", CHAT_MSG_SYSTEM = "system", CHAT_MSG_RAID = "raid",
  CHAT_MSG_RAID_LEADER = "raid", CHAT_MSG_RAID_WARNING = "raid", CHAT_MSG_PARTY = "party",
  CHAT_MSG_PARTY_LEADER = "party" }
local KINDS = { "loot", "system", "raid", "party" }
local PREFIX = { RAID = "/raid ", RAID_WARNING = "/rw ", PARTY = "/p " }
local CHAT_MAX = 255

local listeners, counts = {}, {}
for _, kind in ipairs(KINDS) do
  listeners[kind] = {}
  counts[kind] = { seen = 0, hidden = 0 }
end

-- A string only when plain; anything else (a secret included) is nil.
local function plainString(v)
  v = Plain(v)
  if type(v) == "string" then return v end
  return nil
end

-- fn(text, name, guid) for every plain line of that kind, each under M.Safe on its own.
function ns.OnChat(kind, fn)
  if type(kind) ~= "string" or not listeners[kind] then return nil, "kind" end
  if type(fn) ~= "function" then return nil, "fn" end
  local list = listeners[kind]
  list[#list + 1] = fn
  return true
end

-- Routed by Raids.lua for each CHAT_MSG_* event: text is the 1st value, the name the 2nd, the guid the 12th.
function ns.OnChatEvent(event, ...)
  local kind = KIND[event]
  if not kind then return end
  local row = counts[kind]
  row.seen = row.seen + 1
  local text = plainString((select(1, ...)))
  if not text then
    row.hidden = row.hidden + 1
    return
  end
  local name = plainString((select(2, ...)))
  local guid = plainString((select(12, ...)))
  for _, fn in ipairs(listeners[kind]) do M.Safe(fn, text, name, guid) end
end

-- A copy: { [kind] = { seen = n, hidden = n } } with a row for every kind.
function ns.ChatCounts()
  local out = {}
  for kind, row in pairs(counts) do out[kind] = { seen = row.seen, hidden = row.hidden } end
  return out
end

-- The longest prefix of s at most n bytes that does not end inside a UTF-8 character.
local function cutAt(s, n)
  local cut = n
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b > 0xBF then break end
    cut = cut - 1
  end
  if cut == 0 then cut = n end -- no boundary in reach (room under one character, or not UTF-8): cut at n, loop ends
  return s:sub(1, cut), s:sub(cut + 1)
end

-- head on every line, entries joined with ", ", cut only between entries. A plain entry too long for a line is cut at
-- a character boundary; an entry holding | (a link or an escape) is never cut.
function ns.PackLines(head, names, max)
  head = plainString(head)
  max = Plain(max)
  if not head or type(max) ~= "number" or type(names) ~= "table" then return nil, "head" end
  if max ~= max or max <= 0 or max % 1 ~= 0 or #head >= max then return nil, "head" end -- NaN, fraction, inf, <= 0
  local room = max - #head
  local lines, cur = {}, nil
  local function flush()
    if cur then lines[#lines + 1] = head .. cur end
    cur = nil
  end
  local function add(entry)
    if cur and #cur + 2 + #entry <= room then
      cur = cur .. ", " .. entry
    else
      flush()
      cur = entry
    end
  end
  for _, raw in ipairs(names) do
    local entry = plainString(raw)
    if entry and entry ~= "" then
      if entry:find("|", 1, true) then
        if #entry > room then return nil, "too long" end
        add(entry)
      elseif #entry <= room then
        add(entry)
      else
        flush()
        local piece = entry
        while #piece > room do
          local first
          first, piece = cutAt(piece, room)
          lines[#lines + 1] = head .. first
        end
        if piece ~= "" then cur = piece end
      end
    end
  end
  flush()
  return lines
end

-- ---------- SayLine ----------

-- The saved table only when it is a v1 table (the guards of Raids.lua:115-122); never made or replaced here.
local function saved()
  local db = GuildSyncRaidsDB
  if type(db) == "table" and db.v == 1 then return db end
  return nil
end

local function demo()
  if (M.Demo()) == true then return true end
  local db = saved()
  return db ~= nil and db.demo == true
end

-- session.send, read with the settings' guards: anything but a v1 table with a session table and send == true is off.
local function sendOn()
  local db = saved()
  return db ~= nil and type(db.session) == "table" and db.session.send == true
end

-- The Encounter restriction, as the hub reads it (Compat.lua:286-289). A missing kind is closed first, so "no function
-- = open" only matters with the kind but no function; with neither it never sends. Secret, nil, non-false: closed.
local function encounterOpen()
  local kind
  if type(Enum) == "table" and type(Enum.AddOnRestrictionType) == "table" then
    kind = Enum.AddOnRestrictionType.Encounter
  end
  -- no restriction kind to ask about: counts as closed, so the box is filled
  if kind == nil then return false end
  if not GuildSync.Compat.Has("C_RestrictedActions.IsAddOnRestrictionActive") then return true end
  return M.Compat.call("C_RestrictedActions.IsAddOnRestrictionActive", kind) == false
end

local function lockdownOpen()
  if not GuildSync.Compat.Has("C_ChatInfo.InChatMessagingLockdown") then return true end
  return M.Compat.call("C_ChatInfo.InChatMessagingLockdown") == false
end

-- ns.GroupKind and ns.Leads (Group.lua), looked up at call time; a missing or failing one counts as nil / false.
local function groupKind()
  local f = ns.GroupKind
  if type(f) ~= "function" then return nil end
  local ok, kind = M.Safe(f)
  if ok then return kind end
  return nil
end

local function leads()
  local f = ns.Leads
  if type(f) ~= "function" then return false end
  local ok, yes = M.Safe(f, "player")
  return ok and yes == true
end

-- From a click only. true, "sent" | true, "filled" | nil, why.
function ns.SayLine(channel, text)
  if demo() then return nil, "demo" end
  channel = plainString(channel)
  if not channel or not PREFIX[channel] then return nil, "channel" end
  text = plainString(text)
  if not text or text == "" then return nil, "text" end
  local kind = groupKind()
  if channel == "PARTY" then
    if kind == nil then return nil, "not grouped" end
  else
    if kind ~= "raid" then return nil, "not in a raid" end
    if channel == "RAID_WARNING" and not leads() then return nil, "not leader" end
  end
  if sendOn() and lockdownOpen() and M.Compat.call("InCombatLockdown") == false and encounterOpen()
    and #text <= CHAT_MAX and not text:find("[\r\n]")
    and M.Compat.Try("C_ChatInfo.SendChatMessage", text, channel) then
    return true, "sent"
  end
  local open = ns.OpenChat
  if type(open) == "function" and open(PREFIX[channel] .. text) then return true, "filled" end
  return nil, "no chat box"
end
