-- GuildSyncBank search: the hub's search provider (API 8, run s6; d1152, d1153).
--   ns.SearchFind(text) -> rows { { text, detail, icon?, open } }   Bank.lua's search.find
-- Read-only and cheap: ns.Data once per call (the demo/real split lives there), names only from the client's cache
-- (ns.Items.Cached: an uncached item is not found and no load starts), no send, timer, saved write or frame call.
-- Rows: open requisitions newest posted first (matched on item name, why or poster), then stock by total desc, then
-- name (matched on item name); at most CAP rows. A click opens the page: Contents filtered to the item, or the
-- Requisitions tab.

local _, ns = ...
if not ns.M then return end

local M = ns.M
local CAP = 25
local DOT = " \194\183 " -- " · "

local function low(s) return type(s) == "string" and string.lower(s) or "" end

local function nameOf(data, key)
  local r = data.ctx.roster and data.ctx.roster[key]
  return r and r.name or tostring(key)
end

-- Open order (f6556): show the page first (it builds with the window), then set the filter, then choose the tab,
-- whose redraw reads the filter.
local function openStock(name)
  return function()
    M.OpenPage()
    ns.Page.Filter(name)
    ns.Page.Open("contents")
  end
end

local function openReqs()
  M.OpenPage()
  ns.Page.Open("requisitions")
end

function ns.SearchFind(text)
  if type(text) ~= "string" or text == "" then return nil end
  local data = ns.Data(GuildSync.Compat.Plain(M.Compat.call("GetServerTime")))
  local view = data.view
  local rows = {}

  local reqs = {}
  for _, req in ipairs(view.reqs or {}) do
    if req.status == "open" then reqs[#reqs + 1] = req end
  end
  table.sort(reqs, function(a, b) if a.posted ~= b.posted then return a.posted > b.posted end return a.id < b.id end)
  for _, req in ipairs(reqs) do
    if #rows >= CAP then return rows end
    local name, icon = ns.Items.Cached(req.item)
    local poster = nameOf(data, req.poster)
    local hay = low(name) .. "\n" .. low(req.why) .. "\n" .. low(poster)
    if string.find(hay, text, 1, true) then
      rows[#rows + 1] = { text = name or ("item #" .. tostring(req.item)), icon = icon, open = openReqs,
        detail = "Requisition" .. DOT .. req.wanted .. " wanted" .. DOT .. poster }
    end
  end

  local stock = {}
  for id, it in pairs(view.items or {}) do
    local name, icon = ns.Items.Cached(id)
    if name and string.find(string.lower(name), text, 1, true) then
      stock[#stock + 1] = { id = id, name = name, icon = icon, it = it }
    end
  end
  table.sort(stock, function(a, b)
    if a.it.total ~= b.it.total then return a.it.total > b.it.total end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  for _, s in ipairs(stock) do
    if #rows >= CAP then break end
    -- holders by amount desc, then name, as the Contents tile's line
    local hl = {}
    for h, n in pairs(s.it.by) do
      hl[#hl + 1] = { name = h == ns.Derive.GUILD and "Guild bank" or nameOf(data, h), n = n }
    end
    table.sort(hl, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    local parts = { s.it.total .. " in stock" }
    for _, x in ipairs(hl) do parts[#parts + 1] = x.name .. " " .. x.n end
    rows[#rows + 1] = { text = s.name, icon = s.icon, detail = table.concat(parts, DOT), open = openStock(s.name) }
  end
  return rows
end
