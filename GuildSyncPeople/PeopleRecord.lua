-- GuildSyncPeople: the body and message codecs and the receive caps (plan Task 2).
-- Pure: no guard, no client call, no global outside the Annals allow-list (check-rules/GuildSyncPeople.json).

local _, ns = ...
local Rec = {}
ns.Record = Rec

Rec.VERSION = 1
Rec.FUTURE = 300      -- editedAt may be at most now + 300 (now = GetServerTime, design review f6)
Rec.NOTE_BYTES = 560  -- receive cap of the note (140 four-byte letters)
Rec.TAG_BYTES = 24    -- receive cap of the tag field (12 codes)

-- Tag codes concatenated in module order, each once; unknown codes dropped.
local function tagField(tags)
  local has = {}
  for _, code in ipairs(tags or {}) do has[code] = true end
  local out = {}
  for _, t in ipairs(ns.Rules.TAGS) do if has[t.code] then out[#out + 1] = t.code end end
  return table.concat(out)
end

local function readTags(field)
  local has = {}
  for i = 1, #field - 1, 2 do has[field:sub(i, i + 1)] = true end
  local tags = {}
  for _, t in ipairs(ns.Rules.TAGS) do if has[t.code] then tags[#tags + 1] = t.code end end
  return tags
end

-- <version>^<editedAt>^<mask>^<tags>^<note>
function Rec.Pack(rec)
  return table.concat({ tostring(Rec.VERSION), string.format("%d", rec.editedAt or 0), rec.mask or "",
    tagField(rec.tags), rec.note or "" }, "^")
end

-- rec | nil, why. A format version above 1 answers nil, "newer" (the store keeps the body it held, f3);
-- every other refusal answers another why.
function Rec.Parse(body, now)
  if type(body) ~= "string" then return nil, "format" end
  local fields, pos = {}, 1
  for i = 1, 4 do
    local at = body:find("^", pos, true)
    if not at then
      fields[i] = body:sub(pos)
      break
    end
    fields[i] = body:sub(pos, at - 1)
    pos = at + 1
    if i == 4 then fields[5] = body:sub(pos) end
  end
  local version = tonumber(fields[1])
  if not version or version ~= version then return nil, "version" end
  if version > Rec.VERSION then return nil, "newer" end
  if version < Rec.VERSION then return nil, "version" end
  if not fields[5] then return nil, "format" end
  local editedAt = tonumber(fields[2])
  if not editedAt or editedAt ~= editedAt or editedAt < 0 or editedAt == math.huge
    or type(now) ~= "number" or editedAt > now + Rec.FUTURE then
    return nil, "editedAt"
  end
  local mask = fields[3]:lower()
  if not ns.Rules.ValidMask(mask) then mask = "" end
  return {
    version = Rec.VERSION,
    editedAt = editedAt,
    mask = mask,
    tags = readTags(fields[4]:sub(1, Rec.TAG_BYTES)),
    note = (ns.Rules.CutLetters(ns.Rules.CutBytes(ns.Rules.Strip(fields[5]), Rec.NOTE_BYTES), ns.Rules.NOTE_LETTERS)),
  }
end

-- Messages (Hello's codec shape without "by"): P~key~rev~hash~body, H~hash, D|R~key,rev,hash;...
local SEP = "~"

function Rec.PackMsg(m)
  if m.t == "P" then return table.concat({ "P", m.key, tostring(m.rev), m.hash or "", m.body or "" }, SEP) end
  if m.t == "H" then return "H" .. SEP .. (m.hash or "") end
  if m.t == "D" or m.t == "R" then
    local list = {}
    for _, e in ipairs(m.entries or {}) do list[#list + 1] = e.key .. "," .. tostring(e.rev or 0) .. "," .. (e.hash or "") end
    return m.t .. SEP .. table.concat(list, ";")
  end
  return nil
end

-- The P body is the rest of the line, kept whole even when it holds "~" (f5).
function Rec.UnpackMsg(text)
  if type(text) ~= "string" then return nil end
  local t = text:sub(1, 2)
  if t == "P~" then
    local key, rev, hash, body = text:match("^P~([^~]*)~([^~]*)~([^~]*)~(.*)$")
    rev = tonumber(rev)
    if not key or key == "" or not rev then return nil end
    return { t = "P", key = key, rev = rev, hash = hash, body = body }
  end
  if t == "H~" then return { t = "H", hash = text:sub(3) } end
  if t == "D~" or t == "R~" then
    local entries = {}
    for e in (text:sub(3) .. ";"):gmatch("([^;]*);") do
      local key, rev, hash = e:match("^([^,]*),([^,]*),(.*)$")
      if key then entries[#entries + 1] = { key = key, rev = tonumber(rev) or 0, hash = hash } end
    end
    return { t = text:sub(1, 1), entries = entries }
  end
  return nil
end
