-- GuildSync BugReport: the text of /gsync bug (run r-20261106-s30b). Facts() reads what the report holds, Build()
-- lays it out as one block to paste in a bug report post, Clean() is the text rule. No frames (Window.lua builds
-- the dialog), nothing sent, nothing saved: reads go through ns.Compat, ns.View, ns.Comm and ns.SavedDB() only.
-- Names in error messages (the roster's, the player's own and the realm) become <name> in memory, never in the save.

local ADDON, ns = ...

local MAX_REPORT = 1800 -- bytes, below a 2000-character post limit
local TYPED_MAX = 300
local MODULES_MAX = 320
local PLACE_MAX = 60
local COMMS_MAX = 120
local ERROR_MODULE_MAX = 24
local ERROR_MAX = 160
local ERRORS_SHOWN = 3
local NAME_MIN = 4
local NAME = "<name>"

local BugReport = {}
ns.BugReport = BugReport

-- The text rule: typed || to |, colour codes off, links to their text, textures and atlases off, any | left to /,
-- backticks to ', then ns.PlainLine (control bytes off, cut to cap bytes).
function BugReport.Clean(s, cap, typed)
  s = tostring(s or "")
  if typed then s = string.gsub(s, "||", "|") end
  s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
  s = string.gsub(s, "|r", "")
  s = string.gsub(s, "|H.-|h(.-)|h", "%1")
  s = string.gsub(s, "|T.-|t", "")
  s = string.gsub(s, "|A.-|a", "")
  s = string.gsub(s, "|", "/")
  s = string.gsub(s, "`", "'")
  return ns.PlainLine(s, cap)
end

local function alnum(b)
  return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- msg with every whole name in names (longest first) replaced by <name>; plain finds, no pattern built from a name.
local function hideNames(msg, names)
  for _, n in ipairs(names) do
    local init = 1
    while true do
      local s, e = string.find(msg, n, init, true)
      if not s then break end
      if not alnum(string.byte(msg, s - 1)) and not alnum(string.byte(msg, e + 1)) then
        msg = string.sub(msg, 1, s - 1) .. NAME .. string.sub(msg, e + 1)
        init = s + #NAME
      else
        init = s + 1
      end
    end
  end
  return msg
end

-- A saved time: a finite number from 0 to 2^31, else nil (shown as ?).
local function stamp(v)
  v = tonumber(v)
  if v and v == v and v >= 0 and v <= 2 ^ 31 then return v end
  return nil
end

local function nameList(db, player)
  local seen, list = {}, {}
  local function add(n)
    if type(n) == "string" and n ~= "?" and #n >= NAME_MIN and not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  for _, r in ipairs(ns.View.RosterRows(db and db.guild)) do add(r.name) end
  add(player.name)
  add(player.realm)
  table.sort(list, function(a, b) return #a > #b end)
  return list
end

function BugReport.Facts()
  local Compat, View = ns.Compat, ns.View
  local f = { time = Compat.ServerTime(), version = ns.VERSION, api = ns.API }
  f.client = {}
  f.client.version, f.client.build, f.client.date, f.client.interface = Compat.BuildInfo()
  f.locale = Compat.Locale()
  local player = Compat.Player()
  f.level, f.class, f.race = player.level, player.class, Compat.Race()
  local place = Compat.Place()
  f.zone, f.subzone, f.inInstance, f.instanceType = place.zone, place.subzone, place.inInstance, place.instanceType

  local function loaded(folder)
    local a = Compat.AddOn(folder)
    if not a then return nil end
    return a.loaded == true
  end
  f.bugSack = loaded("BugSack")
  local grabber, plainGrabber = loaded("!BugGrabber"), loaded("BugGrabber")
  if grabber ~= nil or plainGrabber ~= nil then f.bugGrabber = grabber or plainGrabber or false end

  f.addonsKnown = Compat.Has("C_AddOns.DoesAddOnExist")
  f.modules = {}
  if f.addonsKnown then
    local reasons = {}
    local function read(folder)
      local a = Compat.AddOn(folder)
      if a then reasons[folder] = a.reason end
      return a
    end
    for _, r in ipairs(View.SuiteRows(ns.SUITE, read, ns.NeedsNewer)) do
      if r.state ~= "hub" then
        f.modules[#f.modules + 1] = { name = r.name, version = r.version, state = r.state,
          reason = reasons[r.folder], needs = r.needs }
      end
    end
  end

  local Q = ns.Comm and ns.Comm.Queue
  local fn = type(Q) == "table" and Q.StatusLine or nil
  if type(fn) == "function" then
    local good, line = pcall(fn)
    if good and type(line) == "string" then f.comms = line end
  end
  local V = ns.Comm and ns.Comm.Version
  if type(V) == "table" and type(V.Versions) == "function" then
    for _, e in pairs(V.Versions()) do
      local seen = type(e) == "table" and tonumber(e.seen) or nil
      if seen and (not f.heard or seen > f.heard) then f.heard = seen end
    end
  end

  local db = ns.SavedDB()
  local names = nameList(db, player)
  local all = {}
  f.errors, f.errorTotal, f.sessionErrors = {}, 0, ns.SessionErrors()
  for _, e in ipairs(db and type(db.errors) == "table" and db.errors or {}) do
    if type(e) == "table" then
      f.errorTotal = f.errorTotal + 1
      all[#all + 1] = { module = e.module, message = e.message, count = e.count,
        last = stamp(e.lastSeen) or stamp(e.firstSeen) }
    end
  end
  table.sort(all, function(a, b) return (a.last or -1) > (b.last or -1) end)
  -- only the rows Build can show; the escapes go before the <name> rule, so a name in a colour code is found too
  for i = 1, math.min(ERRORS_SHOWN, #all) do
    local e, msg = all[i], tostring(all[i].message or "?")
    msg = string.gsub(string.gsub(msg, "|n", " "), "[%z\1-\31\127]", " ") -- a line break or tab still ends a word
    e.message = hideNames(BugReport.Clean(msg, #msg, false), names)
    f.errors[i] = e
  end
  return f
end

local function text(v) if v == nil then return "?" end return tostring(v) end

local function utc(t)
  if type(t) ~= "number" then return "?" end
  return date("!%Y-%m-%d %H:%M", t) or "?"
end

local MODULE_STATES = { on = "on", off = "off", missing = "not installed" }

local function modulesLine(f)
  if not f.addonsKnown then return "Modules: unknown on this client" end
  local parts, missing = {}, {}
  for _, m in ipairs(f.modules or {}) do
    if m.state == "missing" then
      missing[#missing + 1] = text(m.name)
    else
      local s = text(m.name) .. " " .. text(m.version) .. " "
      if m.state == "error" then s = s .. "error (" .. text(m.reason) .. ")"
      elseif m.state == "needsNewer" then s = s .. "needs API " .. text(m.needs)
      else s = s .. (MODULE_STATES[m.state] or text(m.state)) end
      parts[#parts + 1] = s
    end
  end
  if #missing > 0 then parts[#parts + 1] = "not installed: " .. table.concat(missing, ", ") end
  return "Modules: " .. BugReport.Clean(table.concat(parts, "; "), MODULES_MAX, false)
end

-- The status line cut to COMMS_MAX from its prefix part, so the ", refused N" end is kept.
local function comms(s)
  local head, tail = string.match(s, "^(.*)(, refused %d+)$")
  if not head or #tail > COMMS_MAX then return BugReport.Clean(s, COMMS_MAX, false) end
  return BugReport.Clean(head, COMMS_MAX - #tail, false) .. tail
end

function BugReport.Build(f, typed)
  local Clean = BugReport.Clean
  typed = type(typed) == "string" and Clean(typed, TYPED_MAX, true) or ""
  local c = f.client or {}
  local place = Clean(text(f.zone), PLACE_MAX, false) .. " / " .. Clean(text(f.subzone), PLACE_MAX, false) .. ", "
    .. (f.inInstance and ("in an instance (" .. Clean(text(f.instanceType), PLACE_MAX, false) .. ")") or "not in an instance")
  local function yes(v) if v == nil then return "?" end return v and "yes" or "no" end
  local L = {
    "What happened: " .. (typed ~= "" and typed or "(not written)"),
    "```text",
    "GuildSync bug report, " .. utc(f.time) .. " UTC",
    Clean("GuildSync " .. text(f.version) .. ", API " .. text(f.api), 80, false),
    modulesLine(f),
    Clean("Client: " .. text(c.version) .. " build " .. text(c.build) .. " (" .. text(c.date) .. "), interface "
      .. text(c.interface) .. ", " .. text(f.locale), 120, false),
    Clean("Character: level " .. text(f.level) .. " " .. text(f.class) .. " " .. text(f.race), 80, false),
    "Place: " .. place,
    "Error tools: BugSack " .. yes(f.bugSack) .. ", BugGrabber " .. yes(f.bugGrabber),
    "Comms: " .. (f.comms and comms(f.comms) or "unknown")
      .. "; last addon message heard (any session) " .. (f.heard and (utc(f.heard) .. " UTC") or "never"),
  }
  local errors, total = f.errors or {}, tonumber(f.errorTotal) or 0
  if total == 0 then
    L[#L + 1] = "Errors: none recorded"
    L[#L + 1] = "```"
    return table.concat(L, "\n")
  end
  local head = #L + 1
  L[head] = "" -- the errors line, once the shown count is known
  local rows, size = {}, #table.concat(L, "\n") + #"Errors: " + 64 -- 64: room for the counts in the errors line
  for i = 1, math.min(ERRORS_SHOWN, #errors) do
    local e = errors[i]
    local line = i .. ". " .. Clean(text(e.module), ERROR_MODULE_MAX, false) .. " x" .. text(tonumber(e.count))
      .. ", last " .. utc(e.last) .. ": " .. Clean(text(e.message), ERROR_MAX, false)
    local tail = (total > i and #("\n(" .. (total - i) .. " more not shown)") or 0) + #"\n```"
    if size + 1 + #line + tail > MAX_REPORT then break end
    rows[#rows + 1] = line
    size = size + 1 + #line
  end
  L[head] = "Errors: " .. total .. " recorded, " .. text(f.sessionErrors) .. " this session; newest " .. #rows .. ":"
  for _, line in ipairs(rows) do L[#L + 1] = line end
  if total > #rows then L[#L + 1] = "(" .. (total - #rows) .. " more not shown)" end
  L[#L + 1] = "```"
  return table.concat(L, "\n")
end
