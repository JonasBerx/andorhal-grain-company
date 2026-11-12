-- GuildSyncExpeditions Store.lua: the saved store (0.19 plan, Seams 2). GuildSyncExpeditionsDB is account-wide and
-- holds one part per name (GuildSyncExpeditionsDB[name]); each part's rows live in part.rows, keyed by id.
--   ns.Part(name, fresh, soundRow) -> table   the first call per name per session checks the part and its rows; a
--                                              later call answers the same saved table with no walk. In demo: a fresh
--                                              checked copy of the demo state's part, or of fresh(); nothing saved.
--   ns.Inert() -> bool                        true after one chat line while demo is on, else false
--   ns.Now() -> n | nil                       server seconds through M.Compat.call, nil when unknown
--   ns.Grain(call, n) -> true | nil, why      "spend" | "credit" through the hub purse; one line on a refusal, none
--                                              for "demo"; another call answers "call" and a bad amount "amount",
--                                              and neither reaches the purse
--   ns.GrainLine(why) -> text                 the chat line for a grain refusal
--   ns.WellFormed(code) -> bool               two letters or digits (an R-code)
-- Module.lua loads first, so ns.M exists here unless the hub refused the module.

local _, ns = ...

if not ns.M then return end
local M = ns.M

local INERT = "Demo: nothing is done to made-up members." -- the hub's own demo line (GuildSync/Demo.lua)
local DEPTH = 4 -- a row and three table levels under it; a table deeper than that is removed

local function db()
  if type(GuildSyncExpeditionsDB) ~= "table" then GuildSyncExpeditionsDB = {} end
  return GuildSyncExpeditionsDB
end

-- The saved table is made at login and on first use.
function ns.OnLogin() db() end

local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end

-- Removes every non-finite number in t, and every table below level DEPTH (t is at `level`).
local function sweep(t, level)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "number" and not finite(v) then
      t[k] = nil
    elseif type(v) == "table" then
      if level >= DEPTH then t[k] = nil else sweep(v, level + 1) end
    end
  end
end

-- Checks part in place against fresh and soundRow; answers the checked part.
local function check(part, fresh, soundRow)
  if type(part) ~= "table" then return fresh() end
  local base = fresh()
  local keys = {}
  for k in pairs(part) do keys[#keys + 1] = k end
  for _, k in ipairs(keys) do
    local v = part[k]
    if type(v) == "number" and not finite(v) then
      part[k] = type(base) == "table" and base[k] or nil
    elseif type(v) == "table" and k ~= "rows" then
      sweep(v, 2)
    end
    -- security f3: a field whose type differs from fresh()'s is reset from fresh()
    if k ~= "rows" and type(base) == "table" and base[k] ~= nil and part[k] ~= nil and type(part[k]) ~= type(base[k]) then
      part[k] = base[k]
    end
  end
  if part.rows ~= nil and type(part.rows) ~= "table" then part.rows = nil end
  if part.rows == nil and type(base) == "table" and type(base.rows) == "table" then part.rows = base.rows end
  local rows = part.rows
  if type(rows) == "table" then
    local ids = {}
    for id in pairs(rows) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
      local row = rows[id]
      local keep = nil
      if type(row) == "table" then
        sweep(row, 1)
        if type(soundRow) == "function" then
          local good, r = pcall(soundRow, id, row)
          if good and type(r) == "table" then keep = r end
        else
          keep = row
        end
      end
      rows[id] = keep
    end
  end
  return part
end

local function copy(t, level)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      if level < DEPTH + 2 then out[k] = copy(v, level + 1) end
    else
      out[k] = v
    end
  end
  return out
end

local checked = {} -- name -> the saved part checked this session

function ns.Part(name, fresh, soundRow)
  local on, state = M.Demo()
  if on then
    local src = type(state) == "table" and state[name] or nil
    if type(src) == "table" then return check(copy(src, 1), fresh, soundRow) end
    return check(fresh(), fresh, soundRow)
  end
  local d = db()
  local part = d[name]
  if checked[name] ~= nil and rawequal(checked[name], part) then return part end
  part = check(part, fresh, soundRow)
  d[name] = part
  checked[name] = part
  return part
end

function ns.Inert()
  if not M.Demo() then return false end
  GuildSync.Say(INERT)
  return true
end

function ns.Now()
  local t = M.Compat.call("GetServerTime")
  if type(t) ~= "number" or not finite(t) then return nil end
  return t
end

function ns.WellFormed(code)
  return type(code) == "string" and string.match(code, "^[0-9A-Za-z][0-9A-Za-z]$") ~= nil
end

local GRAIN_LINE = { short = "Not enough grain.", ["no purse"] = "Grain needs the Games addon." }

function ns.GrainLine(why)
  return GRAIN_LINE[why] or "Grain cannot be moved right now."
end

function ns.Grain(call, n)
  local f = (call == "spend" and M.Spend) or (call == "credit" and M.Credit) or nil
  if not f then
    ns.Say(ns.GrainLine("call"))
    return nil, "call"
  end
  if type(n) ~= "number" or not finite(n) or n < 1 or n ~= math.floor(n) then
    ns.Say(ns.GrainLine("amount"))
    return nil, "amount"
  end
  local good, why = f(n)
  if good then return true end
  if why ~= "demo" then ns.Say(ns.GrainLine(why)) end
  return nil, why
end
