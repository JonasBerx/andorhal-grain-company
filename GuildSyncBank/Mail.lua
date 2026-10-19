-- GuildSyncBank mail: mailbox matches (brief H18). The inbox readers are undocumented (f1499) and optional (A1):
-- without all three, or when any read is nil or secret, nothing is read and confirmation stays manual.
--   ns.Mail.Readable() -> bool, why          why = "mail: not readable" when a reader is missing
--   ns.Mail.Current() -> mails | nil         the inbox read at the last MAIL_SHOW / MAIL_INBOX_UPDATE, nil once closed
--   ns.Mail.Read(reads) -> mails | nil       pure: reads as the readers gave them; nil when any read is nil or secret
--   ns.Mail.Match(mails, pending, roster, keyOf) -> matches, partials   pure
-- mails = { { sender = s, items = { { id = n, count = n } } } }

local _, ns = ...
if not ns.M then return end

local Mail = {}
ns.Mail = Mail

local READERS = { "GetInboxHeaderInfo", "GetInboxItem", "GetInboxItemLink" }
local MAX_MAILS, MAX_ITEMS = 100, 16
local current

function Mail.Readable()
  local Has = GuildSync.Compat.Has
  for _, name in ipairs(READERS) do
    if not Has(name) then return false, "mail: not readable" end
  end
  return true
end

function Mail.Current() return current end

-- A plain non-empty string, or nil (a secret becomes nil before anything else touches it).
local function str(v)
  v = GuildSync.Compat.Plain(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function num(v)
  v = GuildSync.Compat.Plain(v)
  if type(v) == "number" then return v end
  return nil
end

function Mail.Read(reads)
  if type(reads) ~= "table" then return nil end
  local out = {}
  for i, r in ipairs(reads) do
    if type(r) ~= "table" then return nil end
    local sender = str(r.sender)
    if not sender then return nil end
    local items = {}
    for j, it in ipairs(type(r.items) == "table" and r.items or {}) do
      if type(it) ~= "table" then return nil end
      local id, count = num(it.id), num(it.count)
      if not id or not count then return nil end
      items[j] = { id = id, count = count }
    end
    out[i] = { sender = sender, items = items }
  end
  return out
end

-- The roster key a sender names: its own key when that is a row, else the one row whose first word it is.
local function rowOf(sender, roster, keyOf)
  local key = type(sender) == "string" and keyOf(sender)
  if not key then return nil end
  if roster[key] then return key end
  if key:find(" ", 1, true) then return nil end
  local found
  for k in pairs(roster) do
    if type(k) == "string" and k:match("^([^ ]+)") == key then
      if found then return nil end
      found = k
    end
  end
  return found
end

function Mail.Match(mails, pending, roster, keyOf)
  local matches, partials = {}, {}
  if type(mails) ~= "table" or type(pending) ~= "table" or type(roster) ~= "table" then return matches, partials end
  -- A send can arrive split over stacks and mails (f1): sum per roster row and item id across every mail first.
  local sums, senders = {}, {}
  for _, m in ipairs(mails) do
    local member = rowOf(m.sender, roster, keyOf)
    if member then
      sums[member] = sums[member] or {}
      senders[member] = senders[member] or m.sender
      for _, it in ipairs(m.items or {}) do
        sums[member][it.id] = (sums[member][it.id] or 0) + it.count
      end
    end
  end
  -- One entry per pending send. The summed count is shared out over that member's sends of the item, oldest `at`
  -- first, so one mail never covers two sends: each send takes its amount from what is left, and a send the rest
  -- cannot cover in full is a partial carrying that rest. The last send of a member and item keeps any surplus.
  local order = {}
  for i, p in ipairs(pending) do order[i] = { p = p, i = i } end
  table.sort(order, function(a, b)
    local x, y = tonumber(a.p.at) or 0, tonumber(b.p.at) or 0
    if x ~= y then return x < y end
    return a.i < b.i
  end)
  local last = {}
  for n, o in ipairs(order) do last[tostring(o.p.member) .. "\0" .. tostring(o.p.item)] = n end
  for n, o in ipairs(order) do
    local p = o.p
    local left = sums[p.member] and sums[p.member][p.item]
    if left and left > 0 then -- a send nothing is left for gets no entry: no "0 of 40" partial
      local count = left
      if left >= p.amount and last[tostring(p.member) .. "\0" .. tostring(p.item)] ~= n then count = p.amount end
      sums[p.member][p.item] = left - math.min(left, p.amount)
      local entry = { req = p.req, member = p.member, item = p.item, count = count, amount = p.amount,
        sender = senders[p.member] }
      if left >= p.amount then matches[#matches + 1] = entry else partials[#partials + 1] = entry end
    end
  end
  return matches, partials
end

-- ---------- live glue: read the inbox when the mailbox shows or changes ----------

local function itemId(i, a, id)
  if id then return id end
  local link = ns.M.Compat.call("GetInboxItemLink", i, a)
  return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function readInbox()
  local call = ns.M.Compat.call
  local reads = {}
  local slots = GuildSync.Compat.Plain(ATTACHMENTS_MAX_RECEIVE)
  if type(slots) ~= "number" or slots < 1 then slots = MAX_ITEMS end
  for i = 1, MAX_MAILS do
    local ok, icon, _, sender, subject, _, _, daysLeft, hasItem = ns.M.Compat.Try("GetInboxHeaderInfo", i)
    if not ok then return nil end
    if icon == nil and sender == nil and subject == nil and daysLeft == nil then break end -- past the last mail
    local items = {}
    -- Slots are not contiguous once an attachment was taken (f6): read every slot, skip the empty ones.
    -- A half-filled slot (a count or an id with no name) fails the whole read; a secret reads as nil here.
    if type(hasItem) == "number" and hasItem > 0 then
      for a = 1, slots do
        local name, id, _, count = call("GetInboxItem", i, a)
        if name == nil and id == nil then
          if count ~= nil then return nil end
        else
          if name == nil then return nil end
          items[#items + 1] = { id = itemId(i, a, id), count = count }
        end
      end
    end
    reads[#reads + 1] = { sender = sender, items = items }
  end
  return Mail.Read(reads)
end

local function refresh()
  if not Mail.Readable() then current = nil return end
  current = readInbox()
end

if ns.Listen then
  ns.Listen("MAIL_SHOW", refresh)
  ns.Listen("MAIL_INBOX_UPDATE", refresh)
  ns.Listen("MAIL_CLOSED", function() current = nil end)
end
