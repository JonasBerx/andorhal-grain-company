-- GuildSync Search: the hub's search (API 8). ns.Search.Run(text) runs the hub sources (View's pure Search* functions
-- over the current source: the demo guild while demo is on) and every module's search.find (Api.lua copies it onto
-- the record as rec.search), all at call time. Hub-only: never on the GuildSync global or a handle.
-- Rows stay raw (control bytes stripped and capped for module rows); View.SearchList escapes them once.

local ADDON, ns = ...

local Search = {}
ns.Search = Search

local function trim(s) return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")) end

-- The query every source gets: control bytes gone, trimmed, cut to SEARCH_MAX bytes at a character boundary and
-- trimmed again (f6217), ASCII letters lower-cased (f6211); nil when under SEARCH_MIN bytes.
local function clean(text)
  local View = ns.View
  if type(text) ~= "string" then return nil end
  local q = trim(ns.PlainLine(trim(ns.PlainLine(text, #text)), View.SEARCH_MAX))
  if #q < View.SEARCH_MIN then return nil end
  return (string.gsub(q, "[A-Z]", string.lower))
end

-- A provider's answer -> rows: indexes 1..SEARCH_CAP read raw, each field read raw once; a row without a string text
-- is skipped. open is wrapped under the module's title and wins over key; a key on the source roster gives the class
-- colour, and the roster go when there is no open.
local function providerRows(rec, rows, roster)
  local View = ns.View
  local out = {}
  for i = 1, View.SEARCH_CAP do
    local r = rawget(rows, i)
    if r == nil then break end
    local text = type(r) == "table" and rawget(r, "text")
    if type(text) == "string" then
      local detail, icon, key, open = rawget(r, "detail"), rawget(r, "icon"), rawget(r, "key"), rawget(r, "open")
      local row = { text = ns.PlainLine(text, View.SEARCH_CUT) }
      if type(detail) == "string" then row.detail = ns.PlainLine(detail, View.SEARCH_CUT) end
      if type(icon) == "string" or type(icon) == "number" then row.icon = icon end
      local m = type(key) == "string" and roster[key] or nil
      if m then row.class = m.class end
      if type(open) == "function" then
        local wrapped = ns.Attributed(rec.name, open)
        row.open = function() return wrapped() end -- no arguments reach the module
      elseif m then
        row.go = { page = "roster", guid = m.guid }
      end
      out[#out + 1] = row
    end
  end
  return out
end

-- -> groups { { key, label, rows, total } } in the order members, alts, log, professions, modules, then m:<id> by
-- module id (empty groups left out, each at most SEARCH_CAP rows), or nil, "short".
function Search.Run(text)
  local View = ns.View
  local q = clean(text)
  if not q then return nil, "short" end
  local Key = ns.Comm.Wire.Key
  local guild, log = ns.Demo.Source()
  local roster = {} -- key -> { guid, class } on the current source's roster
  local members = type(guild) == "table" and type(guild.members) == "table" and guild.members or {}
  for guid, m in pairs(members) do
    local k = type(m) == "table" and Key(m.name)
    if k then roster[k] = { guid = tostring(guid), class = type(m.class) == "string" and m.class or nil } end
  end

  local groups = {}
  local function add(key, label, rows)
    local kept = {}
    for i = 1, math.min(#rows, View.SEARCH_CAP) do kept[i] = rows[i] end
    if #kept > 0 then groups[#groups + 1] = { key = key, label = label, rows = kept, total = #kept } end
  end

  local found = View.SearchMembers(guild, q)
  add("members", "Members", found)
  if not ns.Demo.On() then -- Links persons are real records only (c4)
    -- only members whose name matched (f6218), at most SEARCH_CAP (f6243); the store read once for all (f6242)
    local named, keyList = {}, {}
    for _, r in ipairs(found) do
      if #keyList >= View.SEARCH_CAP then break end
      local k = string.find(string.lower(r.text), q, 1, true) and Key(r.text)
      if k then named[#named + 1], keyList[#keyList + 1] = r, k end
    end
    local people = ns.PeopleOf(keyList)
    local alts = View.SearchAlts(named, function(k) return people[k] end, Key)
    for _, r in ipairs(alts) do
      local m = not r.go and roster[Key(r.text)]
      if m then r.go = { page = "roster", guid = m.guid } end
    end
    add("alts", "Alt links", alts)
  end
  add("log", "Guild log", View.SearchLog(log, q))
  -- this account's saved characters, read only (real data in demo too); not ns.ProfessionsCopy, which lives in
  -- Professions.lua and copies every table where only names are read
  local db, chars = ns.SavedDB(), {}
  for _, c in pairs(db and type(db.chars) == "table" and db.chars or {}) do chars[#chars + 1] = c end
  add("professions", "Your professions", View.SearchProfessions(chars, q))
  local pages, providers = {}, {}
  for _, rec in ipairs(ns.modules) do
    if rec.page then pages[rec.page] = true end
    if rec.search then providers[#providers + 1] = rec end
  end
  add("modules", "Modules", View.SearchModules(ns.SUITE, q, pages))
  table.sort(providers, function(a, b) return a.id < b.id end)
  for _, rec in ipairs(providers) do
    local ok, rows = ns.Safe(rec.name, rec.search, q)
    if ok and type(rows) == "table" then add("m:" .. rec.id, rec.name, providerRows(rec, rows, roster)) end
  end
  return groups
end
