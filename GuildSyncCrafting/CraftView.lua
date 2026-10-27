-- GuildSync CraftView: the words and rows of the Crafters, Recipes and Work board pages, the id index and search,
-- the alert lines, the settings labels and the status line.
-- Pure: no client calls and no globals, so addon/test/craft_view_test.lua runs it outside the game. Names, icons and
-- quality come in through the names table ({ items = { [id] = name }, spells = { [id] = name }, version }) and
-- arguments; the index holds ids only.

local _, ns = ...

local CraftView = {}
ns.CraftView = CraftView

CraftView.UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
CraftView.CLEAR_RECIPES = "Clear recipes on this character"
CraftView.CLEAR_BOARD = "Clear work board and favourites (all your characters)"
CraftView.NO_REAGENTS = "The game does not give the reagents for this recipe."

local PROF_NAMES = {
  [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy", [182] = "Herbalism", [186] = "Mining",
  [197] = "Tailoring", [202] = "Engineering", [333] = "Enchanting", [393] = "Skinning", [755] = "Jewelcrafting",
  [773] = "Inscription", [185] = "Cooking", [129] = "First Aid", [356] = "Fishing",
}

-- Item quality colours (0 poor .. 7 heirloom), as the client draws them.
local QUALITY_COLORS = {
  [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000",
  [6] = "ffe6cc80", [7] = "ff00ccff",
}

local function lower(s) return type(s) == "string" and string.lower(s) or "" end

local function contains(s, q) return s ~= "" and string.find(lower(s), q, 1, true) ~= nil end

function CraftView.ProfessionName(id)
  return PROF_NAMES[id] or ("profession " .. tostring(id))
end

-- Every | doubled, so a note never opens a colour code or a link.
function CraftView.SafeText(s)
  if type(s) ~= "string" then return "" end
  return (string.gsub(s, "|", "||"))
end

-- A person's name: the roster's name for key when the roster row carries one, else the given (wire) text made safe.
-- Wire name atoms are never drawn as they came (f1062).
local function personName(roster, key, fallback)
  local row = type(roster) == "table" and key ~= nil and roster[key] or nil
  if type(row) == "table" and type(row.name) == "string" and row.name ~= "" then return row.name end
  return CraftView.SafeText(fallback ~= nil and tostring(fallback) or tostring(key))
end

-- ---------- names ----------

function CraftView.RecipeLabel(spellID, names, windowName)
  local spells = names and names.spells
  local name = spells and spells[spellID]
  if type(name) == "string" and name ~= "" then return name end
  if type(windowName) == "string" and windowName ~= "" then return windowName end
  return "recipe " .. tostring(spellID)
end

local function itemName(itemID, names)
  local items = names and names.items
  local name = items and items[itemID]
  if type(name) == "string" and name ~= "" then return name end
  return "item " .. tostring(itemID)
end

-- Arguments in CraftCompat.ItemInfo's return order. Uncached: "item <id>" with the unknown icon.
function CraftView.ItemCell(itemID, name, quality, icon)
  local cached = type(name) == "string" and name ~= ""
  return {
    text = cached and name or ("item " .. tostring(itemID)),
    icon = cached and icon or CraftView.UNKNOWN_ICON,
    color = QUALITY_COLORS[quality] or QUALITY_COLORS[1],
  }
end

-- ---------- index ----------

local function unpackRecipes(packed)
  local out = {}
  if type(packed) ~= "string" then return out end
  for spell, item in string.gmatch(packed, "(%d+)=(%d+)") do
    local itemID = tonumber(item)
    out[#out + 1] = { spell = tonumber(spell), item = itemID ~= 0 and itemID or nil }
  end
  return out
end

-- One entry per (character, profession): directory records, plus roster members whose profession has no record.
local function build(crafters, own, rosterRows)
  local entries = {}
  own, rosterRows = own or {}, rosterRows or {}
  for key, c in pairs(crafters or {}) do
    local r = rosterRows[key]
    for prof, p in pairs(c.profs or {}) do
      entries[#entries + 1] = {
        key = key, name = (r and r.name) or c.name or key, prof = prof, profName = CraftView.ProfessionName(prof),
        rank = p.rank or 0, max = p.max, online = (r and r.online) == true, seen = c.seen,
        own = own[key] == true, shared = true, recipes = unpackRecipes(p.packed),
      }
    end
  end
  for key, r in pairs(rosterRows) do
    local c = crafters and crafters[key]
    for _, p in ipairs({ r.prof1 or false, r.prof2 or false }) do
      if p and p.id and not (c and c.profs and c.profs[p.id]) then
        entries[#entries + 1] = {
          key = key, name = r.name or key, prof = p.id, profName = PROF_NAMES[p.id] or p.name or CraftView.ProfessionName(p.id),
          rank = p.rank or 0, online = r.online == true, seen = c and c.seen, own = own[key] == true, shared = false,
          recipes = {},
        }
      end
    end
  end
  return { entries = entries }
end

local lastIndex = { version = nil, index = nil }

-- Rebuilt only when the directory version changes (one directory per client).
function CraftView.Index(crafters, own, rosterRows, version)
  if lastIndex.index and version ~= nil and lastIndex.version == version then return lastIndex.index end
  local index = build(crafters, own, rosterRows)
  lastIndex.version, lastIndex.index = version, index
  return index
end

-- ---------- search ----------

local searchCache = setmetatable({}, { __mode = "k" }) -- [index] = { [query] = { nv, chips, rows, counts } }

local function sortRows(a, b)
  if a.fav ~= b.fav then return a.fav end
  if a.online ~= b.online then return a.online end
  if a.rank ~= b.rank then return a.rank > b.rank end
  if a.name ~= b.name then return a.name < b.name end
  return a.prof < b.prof
end

-- rows (one per character and profession) and counts { all, online, profs }, taken before the prof and online chips.
function CraftView.Search(index, names, query, chips)
  chips = chips or {}
  local q = lower(query):gsub("^%s+", ""):gsub("%s+$", "")
  local nv = names and names.version
  local perIndex = searchCache[index]
  if not perIndex then perIndex = {}; searchCache[index] = perIndex end
  local hit = perIndex[q]
  if hit and hit.nv == nv and hit.chips == chips then return hit.rows, hit.counts end

  local items, spells = names and names.items or {}, names and names.spells or {}
  local favs = chips.favourites or {}
  local rows, counts = {}, { all = 0, online = 0, profs = {} }
  for _, e in ipairs(index and index.entries or {}) do
    local hits = {}
    if q ~= "" then
      for _, rc in ipairs(e.recipes) do
        if contains(rc.item and items[rc.item] or "", q) or contains(spells[rc.spell] or "", q) then
          hits[#hits + 1] = { spell = rc.spell, item = rc.item }
        end
      end
    end
    if q == "" or #hits > 0 or contains(e.name, q) or contains(e.profName, q) then
      counts.all = counts.all + 1
      if e.online then counts.online = counts.online + 1 end
      counts.profs[e.prof] = (counts.profs[e.prof] or 0) + 1
      if (chips.prof == nil or chips.prof == e.prof) and (not chips.online or e.online) then
        rows[#rows + 1] = {
          key = e.key, name = e.name, prof = e.prof, rank = e.rank, max = e.max, online = e.online, seen = e.seen,
          own = e.own, fav = favs[e.key] == true, shared = e.shared, hits = hits,
        }
      end
    end
  end
  table.sort(rows, sortRows)
  perIndex[q] = { nv = nv, chips = chips, rows = rows, counts = counts }
  return rows, counts
end

-- ---------- crafter rows ----------

function CraftView.LastSeen(seen, now, online)
  if online then return "online" end
  if type(seen) ~= "number" or type(now) ~= "number" then return "unknown" end
  local d = now - seen
  if d < 3600 then return math.max(1, math.floor(d / 60)) .. " min ago" end
  if d < 86400 then return math.floor(d / 3600) .. " h ago" end
  local days = math.floor(d / 86400)
  return days .. (days == 1 and " day ago" or " days ago")
end

function CraftView.CrafterText(row, now)
  local prof = CraftView.ProfessionName(row.prof)
  if not row.shared then
    return row.name .. ", " .. prof .. " " .. tostring(row.rank) .. ", recipes not shared"
  end
  local rank = tostring(row.rank) .. (row.max and ("/" .. tostring(row.max)) or "")
  return row.name .. ", " .. prof .. " " .. rank .. ", " .. CraftView.LastSeen(row.seen, now, row.online)
end

-- ---------- recipe book ----------

-- Flat rows in draw order: profession, then its recipes, each followed by who knows it. Shared records only.
function CraftView.Book(index, names)
  local profs = {}
  for _, e in ipairs(index and index.entries or {}) do
    if e.shared then
      local p = profs[e.prof]
      if not p then p = { prof = e.prof, text = CraftView.ProfessionName(e.prof), recipes = {} }; profs[e.prof] = p end
      for _, rc in ipairs(e.recipes) do
        local r = p.recipes[rc.spell]
        if not r then
          r = { spell = rc.spell, item = rc.item, text = CraftView.RecipeLabel(rc.spell, names), crafters = {} }
          p.recipes[rc.spell] = r
        end
        r.crafters[#r.crafters + 1] = { key = e.key, text = e.name }
      end
    end
  end
  local byText = function(a, b) return a.text < b.text end
  local plist = {}
  for _, p in pairs(profs) do plist[#plist + 1] = p end
  table.sort(plist, byText)
  local out = {}
  for _, p in ipairs(plist) do
    out[#out + 1] = { kind = "prof", prof = p.prof, text = p.text }
    local rlist = {}
    for _, r in pairs(p.recipes) do rlist[#rlist + 1] = r end
    table.sort(rlist, byText)
    for _, r in ipairs(rlist) do
      out[#out + 1] = { kind = "recipe", spell = r.spell, item = r.item, text = r.text }
      table.sort(r.crafters, byText)
      for _, c in ipairs(r.crafters) do out[#out + 1] = { kind = "crafter", key = c.key, text = c.text } end
    end
  end
  return out
end

function CraftView.ReagentLines(reagents, names)
  if type(reagents) ~= "table" or #reagents == 0 then return { CraftView.NO_REAGENTS } end
  local out = {}
  for _, r in ipairs(reagents) do
    out[#out + 1] = itemName(r.itemID, names) .. " x" .. tostring(r.count or 1)
  end
  return out
end

-- ---------- work board ----------

function CraftView.TimeLeft(expiresAt, now)
  local d = (expiresAt or 0) - (now or 0)
  if d <= 0 then return "expired" end
  if d >= 3600 then return math.floor(d / 3600) .. " h" end
  return math.max(1, math.floor(d / 60)) .. " min"
end

-- "i<id>" reads the item name, "s<id>" the recipe name.
local function requestItem(what, names)
  local kind, id = string.match(tostring(what or ""), "^([is])(%d+)$")
  id = tonumber(id)
  if kind == "s" then return CraftView.RecipeLabel(id, names) end
  if kind == "i" then return itemName(id, names) end
  return tostring(what or "")
end

-- opts = { names, claim = { key, name, at } or nil, roster = { [key] = row } }. Names come from the roster row's name;
-- a row that is not a table (or has no name) falls back to the wire text, made safe. mark is "" or the unconfirmed
-- or reported text.
function CraftView.BoardRow(req, now, opts)
  opts = opts or {}
  local claim = ""
  if opts.claim then
    local gone = opts.roster and not opts.roster[opts.claim.key]
    claim = "working on it: " .. (gone and "(left the guild)" or personName(opts.roster, opts.claim.key, opts.claim.name))
  end
  local who = personName(opts.roster, req.by, req.byName or req.by)
  -- d207: a copy relayed by someone else, not yet confirmed by the requester; a done or cancel someone else reported
  local mark = ""
  if req.provisional then
    mark = "unconfirmed, not yet heard from " .. who
  elseif type(req.reported) == "table" then
    mark = "reported " .. (req.reported.state == "cancel" and "cancelled" or "done") .. " by "
      .. personName(opts.roster, req.reported.by, req.reported.by) .. ", awaiting " .. who
  end
  return {
    who = who,
    mark = mark,
    item = requestItem(req.what, opts.names),
    qty = "x" .. tostring(req.qty or 1),
    mats = req.mats and "brings mats" or "needs mats",
    tip = (type(req.tip) == "number" and req.tip > 0) and (req.tip .. " g") or "",
    left = CraftView.TimeLeft(req.expiresAt, now),
    note = CraftView.SafeText(req.note),
    claim = claim,
  }
end

-- opts = { me, myKeys, claim, canMake, roster } -> actions (claim | drop | release | done | cancel | keep), line
function CraftView.Actions(req, now, opts)
  opts = opts or {}
  local actions, claim = {}, opts.claim
  if req.provisional then
    -- d211: unconfirmed and in my name: Keep or Cancel, from that character only; anyone else's takes no action
    if not (opts.myKeys and opts.myKeys[req.by]) or req.final then return actions, nil end
    -- d216: who passed it on, and the quantity and tip that Keep would make mine
    local tip = (type(req.tip) == "number" and req.tip > 0) and ("tip " .. req.tip .. " g") or "no tip"
    local line = "In your name, not posted from this computer. " .. personName(opts.roster, req.provisional, req.provisional)
      .. " passed it on, quantity " .. tostring(req.qty or 1) .. ", " .. tip .. "."
    if opts.me == req.by then return { "keep", "cancel" }, line end
    return actions, line .. " Log in on " .. personName(opts.roster, req.by, req.byName or req.by) .. " to keep or cancel it."
  end
  if opts.me == req.by then
    -- d215: an expired request of mine can still be marked done or cancelled, not released
    if claim and (req.expiresAt or 0) > (now or 0) then actions[#actions + 1] = "release" end
    actions[#actions + 1] = "done"
    actions[#actions + 1] = "cancel"
    return actions, nil
  end
  if opts.myKeys and opts.myKeys[req.by] then
    return actions, "Log in on " .. personName(opts.roster, req.by, req.byName or req.by) .. " to change it."
  end
  if claim and claim.key == opts.me then
    actions[#actions + 1] = "drop"
  elseif opts.canMake and (req.expiresAt or 0) > (now or 0) then
    actions[#actions + 1] = "claim"
  end
  return actions, nil
end

-- ---------- board layout and request cards ----------

local CARD_W, CARD_H, CARD_GAP = 349, 76, 10
local FORM_H, FORM_SHIFT = 108, 130
local TAB_ROW_H = 32 -- the board area starts under the tab row (PanelTopTabButtonTemplate is 32 tall)
local NEW_W = 120 -- New request / Post request column at the area's right
local DOT = " \194\183 " -- U+00B7 between the by-line's parts

-- The Crafting page's board area for a page pageW x pageH: two card columns when two cards and the gap fit, else one;
-- cards from y 30 under the top tabs (48 under today's flat list buttons); the New request form areaW x 108 at the
-- cards' top pushes them 130 down. Pure: the caller places its frames from these numbers.
function CraftView.BoardLayout(pageW, pageH, flatTabs)
  local areaW = pageW - 18
  return {
    areaX = 0, areaTop = TAB_ROW_H, areaW = areaW, areaH = pageH - TAB_ROW_H,
    cols = (areaW >= 2 * CARD_W + CARD_GAP) and 2 or 1,
    colStep = CARD_W + CARD_GAP, cardW = CARD_W, cardH = CARD_H, rowStep = CARD_H + CARD_GAP,
    cardsTop = flatTabs and 48 or 30,
    formW = areaW, formH = FORM_H, formShift = FORM_SHIFT,
    noteW = areaW - NEW_W - 12 - 280, postX = areaW - NEW_W,
  }
end

-- ---------- Crafters and Recipes layout ----------

-- The Crafters tab inside the area box areaW wide: filter row (search, profession dropdown, Online now), status line,
-- list. The list box is areaW - 16 (Kit.List keeps 16 px for the scroll bar), so rows are that wide; Whisper anchors
-- RIGHT -4 of the row, never at an absolute x. Pure.
function CraftView.CraftersLayout(areaW)
  local rowW = areaW - 16
  local seenX = math.min(400, rowW - 180)
  return {
    searchX = 5, searchY = 1, searchW = 220, dropX = 237, dropW = 190, checkX = 439,
    statusX = 4, statusY = 34, listTop = 52, rowH = 40, rowW = rowW,
    starX = 4, starY = 5, classX = 30, classY = 6, nameX = 54, nameY = 6,
    profX = math.min(232, seenX - 168), seenX = seenX,
    whisperW = 80, whisperH = 22, whisperRight = -4, line2Y = 22,
  }
end

-- The Recipes tab: the book card 220 x areaH at the area's top left, the detail card beside it to the area's right.
-- rankRight / seenRight are offsets from the detail card's right edge. Pure.
function CraftView.RecipesLayout(areaW, areaH)
  return {
    bookX = 0, bookY = 0, bookW = 220, bookH = areaH, bookRowH = 22,
    detailX = 230, detailW = areaW - 230, detailH = areaH,
    rankRight = -130, seenRight = -12,
  }
end

local DETAIL_TOP, MAKES_H = 60, 52 -- content under the divider; Makes = label 16 + icon row 28 + gap 8
local LABEL_H, KNOWN_LINE, REAGENT_LINE, DETAIL_GAP, DETAIL_PAD = 18, 18, 26, 8, 12
local KNOWN_FIRST = 3 -- Known by keeps at least this many lines when the card is short

-- n items in `slots` lines: all, or slots - 1 named and a "(+N more)" line.
local function cut(n, slots)
  if n <= slots then return n, 0 end
  local named = math.max(slots - 1, 0)
  return named, n - named
end

-- The recipe detail card's lines for a card cardH tall: Known by (lines 18) and Reagents (lines 26) each cut with a
-- "(+N more)" line when they do not fit or pass their pool size (maxKnown / maxReagents count that line). Known by
-- first gets min(n, 3), the reagents what then fits, Known by the rest. Pure.
function CraftView.DetailFit(cardH, hasMakes, nKnown, nReagents, maxKnown, maxReagents)
  local knownY = hasMakes and (DETAIL_TOP + MAKES_H) or DETAIL_TOP
  local avail = cardH - DETAIL_PAD - knownY - LABEL_H - DETAIL_GAP - LABEL_H
  local kTotal, rTotal = math.min(nKnown, maxKnown), math.min(nReagents, maxReagents)
  if kTotal * KNOWN_LINE + rTotal * REAGENT_LINE > avail then
    local kFirst = math.min(nKnown, KNOWN_FIRST, maxKnown)
    rTotal = math.max(0, math.min(rTotal, math.floor((avail - kFirst * KNOWN_LINE) / REAGENT_LINE)))
    kTotal = math.max(0, math.min(kTotal, math.floor((avail - rTotal * REAGENT_LINE) / KNOWN_LINE)))
  end
  local knownLines, knownMore = cut(nKnown, kTotal)
  local reagentLines, reagentsMore = cut(nReagents, rTotal)
  local knownShown = knownLines + (knownMore > 0 and 1 or 0)
  return {
    makesY = DETAIL_TOP, knownY = knownY, knownLines = knownLines, knownMore = knownMore,
    reagentsY = knownY + LABEL_H + knownShown * KNOWN_LINE + DETAIL_GAP,
    reagentLines = reagentLines, reagentsMore = reagentsMore,
  }
end

-- A card's lines from BoardRow's row and CraftBoard.State's word: right = time left or the end state, by = who, mats
-- and tip, tail = claim and mark (open or claimed only) and the quoted note. The row's strings are already escaped.
function CraftView.CardLines(row, st)
  local right
  if st == "done" then right = "done"
  elseif st == "cancel" then right = "cancelled"
  elseif st == "expired" then right = "expired"
  else right = row.left .. " left" end
  local by = row.who .. DOT .. row.mats
  if row.tip ~= "" then by = by .. DOT .. "tip " .. row.tip end
  local live = st == "open" or st == "claimed"
  local tail = {}
  if live and row.claim ~= "" then tail[#tail + 1] = row.claim end
  if live and row.mark and row.mark ~= "" then tail[#tail + 1] = row.mark end
  if row.note ~= "" then tail[#tail + 1] = "\"" .. row.note .. "\"" end
  return { right = right, by = by, tail = table.concat(tail, ", ") }
end

-- roster (optional): the requester is named by the roster row's name.
function CraftView.AlertLine(req, names, roster)
  return personName(roster, req.by, req.byName or req.by) .. " wants " .. requestItem(req.what, names) .. " x" .. tostring(req.qty or 1)
    .. " on the Work board."
end

function CraftView.CatchUpLine(n)
  if n == 1 then return "1 request you can make is open on the Work board." end
  return tostring(n) .. " requests you can make are open on the Work board."
end

-- ---------- settings ----------

local RETENTION = { 14, 30, 60, 90, 0 } -- 0 = forever

function CraftView.NextRetention(days)
  for i, d in ipairs(RETENTION) do
    if d == days then return RETENTION[i % #RETENTION + 1] end
  end
  return RETENTION[1]
end

function CraftView.RetentionLabel(days)
  if days == 0 then return "forever" end
  return tostring(days) .. " days"
end

-- ---------- status line ----------

local function thousands(n)
  local s = tostring(n or 0)
  local sign, int, rest = string.match(s, "^(-?)(%d+)(.*)$")
  if not int then return s end
  int = string.reverse((string.gsub(string.reverse(int), "(%d%d%d)", "%1,")))
  if string.sub(int, 1, 1) == "," then int = string.sub(int, 2) end
  return sign .. int .. rest
end

-- stats = { crafters, lastDigest (text), sent (chunks that went), attempts (every send, optional), received,
-- lastResult, queue, gate (nil = open, else CanSend's why) }
function CraftView.StatusLine(stats)
  stats = stats or {}
  return "crafters " .. thousands(stats.crafters)
    .. ", last digest " .. tostring(stats.lastDigest or "never")
    .. ", sent " .. thousands(stats.sent) .. " chunks"
    .. (stats.attempts ~= nil and (" (" .. thousands(stats.attempts) .. " attempts)") or "")
    .. ", received " .. thousands(stats.received) .. " chunks"
    .. ", last send result " .. tostring(stats.lastResult == nil and "none" or stats.lastResult)
    .. ", queue " .. thousands(stats.queue)
    .. ", sending: " .. (stats.gate and ("no (" .. tostring(stats.gate) .. ")") or "yes")
end

-- ---------- cooldowns ----------
-- The Cooldowns tab's groups, rows and texts. The cooldown list itself is CraftStore.COOLDOWNS, read at call time.
-- Dates come from fmt (the client's date, passed in), but day and month names from the fixed English tables below.

local MIN, HOUR, DAY = 60, 3600, 86400
local NO_TIME = "\226\128\147" -- U+2013, the At column's "no time"
local CD_ICONS = {
  tr = "Interface\\Icons\\INV_Misc_StoneTablet_05", mc = "Interface\\Icons\\INV_Fabric_MoonRag_01",
  ss = "Interface\\Icons\\INV_Egg_05",
}
local STATE_ORDER = { ready = 1, wait = 2, unknown = 3 }

CraftView.CD_EMPTY = "No cooldowns in the guild yet."
CraftView.CD_EMPTY_HINT = "Transmutes, Mooncloth and the Salt Shaker show here once a guildmate who has one logs in"
  .. " with Crafting. Yours show after you open your profession or use the cooldown."

-- Fixed English, never the locale's day or month names. WEEKDAYS is a copy of GuildSync/View.lua:1219.
CraftView.WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
CraftView.MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local HEARD_NOW = 600 -- seconds that read "now" (GuildSync/View.lua:1220)

-- -> text, grey. A line-for-line copy of the hub's View.HeardText (GuildSync/View.lua:1226-1235), with the client's
-- date passed in as fmt: the hub's function is not on the API (R2, D21), so a hub change there is not followed here.
function CraftView.HeardText(seen, now, fmt)
  seen, now = tonumber(seen), tonumber(now) or 0
  if not seen then return "" end
  if now - seen < HEARD_NOW then return "now" end
  if fmt("%Y-%m-%d", seen) == fmt("%Y-%m-%d", now) then return fmt("%H:%M", seen) end
  local n = math.floor((now - seen) / 86400)
  if n < 7 then return CraftView.WEEKDAYS[fmt("*t", seen).wday] end
  if n <= 13 then return n .. " days", true end
  return math.floor(n / 7) .. " weeks", true
end

-- "Ready" (0 or passed), "in 5 h 20 min" under a day, "in 1 day 14 h" from a day, a zero part left out; at least
-- "in 1 min"; "unknown" for no readyAt.
function CraftView.CooldownWhen(readyAt, now)
  if type(readyAt) ~= "number" then return "unknown" end
  local d = readyAt - (now or 0)
  if d <= 0 then return "Ready" end
  if d >= DAY then
    local days, h = math.floor(d / DAY), math.floor((d % DAY) / HOUR)
    return "in " .. days .. (days == 1 and " day" or " days") .. (h > 0 and (" " .. h .. " h") or "")
  end
  local h, m = math.floor(d / HOUR), math.floor((d % HOUR) / MIN)
  if h == 0 then return "in " .. math.max(1, m) .. " min" end
  return "in " .. h .. " h" .. (m > 0 and (" " .. m .. " min") or "")
end

-- The At column: the ready time's weekday and HH:MM, or a dash (also when the date gives no table, s4).
function CraftView.CooldownAt(readyAt, fmt)
  if type(readyAt) ~= "number" then return NO_TIME end
  local d = fmt("*t", readyAt)
  if type(d) ~= "table" then return NO_TIME end
  return CraftView.WEEKDAYS[d.wday] .. " " .. fmt("%H:%M", readyAt)
end

-- "Sat 25 Oct", or a dash when the date gives no table (s4)
local function dayText(t, fmt)
  local d = fmt("*t", t)
  if type(d) ~= "table" then return NO_TIME end
  return CraftView.WEEKDAYS[d.wday] .. " " .. d.day .. " " .. CraftView.MONTHS[d.month]
end

-- "Transmute: Arcanite" -> "Arcanite"
local function shortName(name)
  return string.match(name, "^[^:]+:%s*(.+)$") or name
end

local function sortCdRows(a, b)
  if a.state ~= b.state then return STATE_ORDER[a.state] < STATE_ORDER[b.state] end
  if a.state == "wait" and a.readyAt ~= b.readyAt then return a.readyAt < b.readyAt end
  return a.name < b.name
end

-- input = { mine = CraftHost.MyChars(), crafters, roster, cooldowns = CraftSync.Cooldowns(), me = key, names,
-- fmt = date, own = GuildSyncCraftDB.cooldowns }. One group per cooldown in CraftStore's order, left out when empty. A
-- row is a character who knows a recipe of the group (own or the directory) or whose record carries the group: ready
-- (0 or passed), wait, unknown. A key in own (an alt off the roster too, f6642) is one of yours.
function CraftView.CooldownRows(input, now)
  local Store = ns.CraftStore
  local fmt, roster, records = input.fmt, input.roster or {}, input.cooldowns or {}
  local spells = input.names and input.names.spells or {}
  local groupOf, entryName = {}, {}
  for _, e in ipairs(Store.COOLDOWNS) do
    if e.kind == "spell" then groupOf[e.spell], entryName[e.spell] = e.group, e.name end
  end

  local chars, own = {}, {} -- [key] = { name, class, seen, knows = { [group] = { [spell] = true } } }
  local function char(key, name, class, seen)
    local c = chars[key]
    if not c then c = { knows = {} }; chars[key] = c end
    c.name, c.class = c.name or name, c.class or class
    if type(seen) == "number" and seen > (c.seen or 0) then c.seen = seen end
    return c
  end
  local function knows(c, spell)
    local g = groupOf[spell]
    if not g then return end
    c.knows[g] = c.knows[g] or {}
    c.knows[g][spell] = true
  end
  for key in pairs(input.own or {}) do own[key] = true end
  for _, m in ipairs(input.mine or {}) do
    own[m.key] = true
    local c = char(m.key, m.name, m.class)
    for _, p in pairs(m.profs or {}) do
      for spell in pairs(p.recipes or {}) do knows(c, spell) end
    end
  end
  for key, cr in pairs(input.crafters or {}) do
    local c = char(key, cr.name, cr.class, cr.seen)
    for _, p in pairs(cr.profs or {}) do
      for _, rc in ipairs(unpackRecipes(p.packed)) do knows(c, rc.spell) end
    end
  end
  for key, rec in pairs(records) do char(key, rec.name, rec.class, rec.seen) end

  local groups = {}
  for _, g in ipairs(Store.CooldownGroups()) do
    local id = g.group
    local rows, ready = {}, 0
    for key, c in pairs(chars) do
      local rec = records[key]
      local readyAt = rec and type(rec.cds) == "table" and rec.cds[id] or nil
      if c.knows[id] or readyAt ~= nil then
        local r = roster[key]
        local online = type(r) == "table" and r.online == true
        local seen = online and now or c.seen
        local state = readyAt == nil and "unknown" or (readyAt <= now and "ready" or "wait")
        local known = {}
        for spell in pairs(c.knows[id] or {}) do
          known[#known + 1] = shortName(spells[spell] or entryName[spell] or ("spell " .. spell))
        end
        table.sort(known)
        local heard, grey = CraftView.HeardText(seen, now, fmt)
        rows[#rows + 1] = {
          key = key, name = personName(roster, key, c.name), class = (type(r) == "table" and r.class) or c.class,
          tag = key == input.me and "(you)" or (own[key] and "(your alt)" or nil),
          state = state, when = CraftView.CooldownWhen(readyAt, now),
          at = state == "wait" and CraftView.CooldownAt(readyAt, fmt) or NO_TIME,
          heard = heard, heardGrey = grey == true, online = online, own = own[key] == true, knows = known,
          readyAt = readyAt, seen = seen, cdName = g.name, groupSize = #g.entries,
        }
        if state == "ready" then ready = ready + 1 end
      end
    end
    if #rows > 0 then
      table.sort(rows, sortCdRows)
      groups[#groups + 1] = {
        group = id, label = g.name .. DOT .. CraftView.ProfessionName(g.prof), prof = g.prof,
        icon = CD_ICONS[id] or CraftView.UNKNOWN_ICON, ready = ready, total = #rows, rows = rows,
      }
    end
  end
  return groups
end

-- -> "9 cooldowns · 4 ready now", the Ready now count, the Online now count.
function CraftView.CooldownSummary(groups)
  local n, ready, online = 0, 0, 0
  for _, g in ipairs(groups or {}) do
    for _, r in ipairs(g.rows) do
      n = n + 1
      if r.state == "ready" then ready = ready + 1 end
      if r.online then online = online + 1 end
    end
  end
  return n .. " cooldowns" .. DOT .. ready .. " ready now", ready, online
end

-- A CooldownRows row's tooltip lines: when it is ready, the spells known for a group of more than one, when heard.
function CraftView.CooldownTip(row, fmt)
  local lines = {}
  if row.state == "wait" then
    lines[1] = row.cdName .. " ready on " .. dayText(row.readyAt, fmt) .. " at " .. fmt("%H:%M", row.readyAt) .. "."
  elseif row.state == "ready" then
    lines[1] = row.cdName .. " is ready."
  else
    lines[1] = row.cdName .. ": not heard yet."
  end
  if row.groupSize > 1 and #row.knows > 0 then lines[#lines + 1] = "Knows: " .. table.concat(row.knows, ", ") .. "." end
  if type(row.seen) == "number" then
    local fresh = row.heard ~= "" and not row.heardGrey
    lines[#lines + 1] = "Heard " .. (fresh and CraftView.CooldownAt(row.seen, fmt) or dayText(row.seen, fmt)) .. "."
  end
  return lines
end

-- ---------- the hub's search (API 8) ----------
-- One row per crafter (name and professions) and per named recipe, each with one lower-cased haystack whose fields
-- are joined with "\n", so a query never matches across two fields (S6 f6557). Cooldown states are kept as readyAt
-- per key and group; "ready" is counted at query time, so passing time needs no rebuild (f6620).

local SEARCH_ROWS, SEARCH_BYTES = 25, 80 -- the hub's caps (API.md, "What API 8 adds")

-- Control bytes stripped, then cut to SEARCH_BYTES at a character boundary (the hub's text rule).
local function fit(s)
  s = string.gsub(s, "%c", "")
  if #s <= SEARCH_BYTES then return s end
  local n = SEARCH_BYTES
  while n > 0 and string.byte(s, n + 1) >= 128 and string.byte(s, n + 1) < 192 do n = n - 1 end
  return string.sub(s, 1, n)
end

local function byText(a, b)
  if a.text ~= b.text then return a.text < b.text end
  return (a.key or a.spell) < (b.key or b.spell)
end

-- sidx = { crafters, recipes, ready = { [key] = { [group] = readyAt } } }, from CraftView.Index's index, the names
-- table and CraftSync.Cooldowns(). Unnamed spells are left out (a late name rebuilds through spellVersion).
function CraftView.SearchIndex(index, names, cooldowns)
  local spells = names and names.spells or {}
  local groupOf = {}
  for _, e in ipairs(ns.CraftStore.COOLDOWNS) do
    if e.kind == "spell" then groupOf[e.spell] = e.group end
  end
  local crafters, recipes, byKey, bySpell = {}, {}, {}, {}
  for _, e in ipairs(index and index.entries or {}) do
    local c = byKey[e.key]
    if not c then
      c = { key = e.key, text = e.name, first = string.match(e.name, "^(%S+)") or e.name, profs = {} }
      byKey[e.key] = c
      crafters[#crafters + 1] = c
    end
    c.profs[#c.profs + 1] = { text = e.profName, rank = tostring(e.rank) .. (e.max and ("/" .. tostring(e.max)) or "") }
    if e.shared then
      for _, rc in ipairs(e.recipes) do
        local name = spells[rc.spell]
        if type(name) == "string" and name ~= "" then
          local r = bySpell[rc.spell]
          if not r then
            r = { text = name, low = lower(name), spell = rc.spell, item = rc.item, prof = e.prof,
                  group = groupOf[rc.spell], who = {} }
            bySpell[rc.spell] = r
            recipes[#recipes + 1] = r
          end
          r.who[#r.who + 1] = c
        end
      end
    end
  end
  for _, c in ipairs(crafters) do
    table.sort(c.profs, function(a, b) return a.text < b.text end)
    local low, parts = { lower(c.text) }, {}
    for i, p in ipairs(c.profs) do
      low[#low + 1] = lower(p.text)
      parts[i] = p.text .. " " .. p.rank
    end
    c.low, c.profText = table.concat(low, "\n"), table.concat(parts, DOT)
  end
  table.sort(crafters, byText)
  table.sort(recipes, byText)
  local ready = {}
  for key, rec in pairs(cooldowns or {}) do
    if type(rec) == "table" and type(rec.cds) == "table" then
      local t = {}
      for g, at in pairs(rec.cds) do if type(at) == "number" then t[g] = at end end
      ready[key] = t
    end
  end
  return { crafters = crafters, recipes = recipes, ready = ready }
end

-- "ready", "wait" or "unknown" for key's group at now (no now: never ready)
local function cdState(sidx, key, group, now)
  local at = sidx.ready[key] and sidx.ready[key][group]
  if type(at) ~= "number" then return "unknown" end
  return (type(now) == "number" and at <= now) and "ready" or "wait"
end

-- "Alchemy 168/300 · Tailoring 300/300 · Transmute ready": a tail per ready cooldown, in CraftStore's order.
local function crafterDetail(sidx, c, now)
  local parts = { c.profText }
  for _, g in ipairs(ns.CraftStore.CooldownGroups()) do
    if cdState(sidx, c.key, g.group, now) == "ready" then parts[#parts + 1] = g.name .. " ready" end
  end
  return fit(table.concat(parts, DOT))
end

-- "4 crafters · 2 ready now", "2 crafters: Morwen, Ysolde · 2 ready now", "1 crafter: Morwen · ready now": first
-- names for up to 3 crafters (ready first) while they fit in 80 bytes, then the tail; no tail for none ready or no
-- cooldown.
local function recipeDetail(sidx, r, now)
  local n = #r.who
  local head = n .. (n == 1 and " crafter" or " crafters")
  local tail, list = nil, {}
  if r.group then
    local k = 0
    for _, c in ipairs(r.who) do
      local st = cdState(sidx, c.key, r.group, now)
      if st == "ready" then k = k + 1 end
      list[#list + 1] = { text = c.first, key = c.key, order = STATE_ORDER[st] }
    end
    if k > 0 then tail = n == 1 and "ready now" or (k .. " ready now") end
  else
    for _, c in ipairs(r.who) do list[#list + 1] = { text = c.first, key = c.key, order = 0 } end
  end
  tail = tail and (DOT .. tail) or ""
  if n <= 3 then
    table.sort(list, function(a, b) if a.order ~= b.order then return a.order < b.order end return byText(a, b) end)
    for i, x in ipairs(list) do list[i] = x.text end
    local full = head .. ": " .. table.concat(list, ", ") .. tail
    if #full <= SEARCH_BYTES then return fit(full) end
  end
  return fit(head .. tail)
end

-- The rows for text (already lower-cased by the hub): crafters first, then recipes, each by text; at most 25.
-- Crafter rows carry key and name, recipe rows spell, prof and item (the caller adds icon and open).
function CraftView.SearchRows(sidx, text, now)
  local rows = {}
  if type(sidx) ~= "table" or type(text) ~= "string" or text == "" then return rows end
  for _, c in ipairs(sidx.crafters) do
    if #rows >= SEARCH_ROWS then return rows end
    if string.find(c.low, text, 1, true) then
      rows[#rows + 1] = { text = fit(c.text), detail = crafterDetail(sidx, c, now), key = c.key, name = c.text }
    end
  end
  for _, r in ipairs(sidx.recipes) do
    if #rows >= SEARCH_ROWS then return rows end
    if string.find(r.low, text, 1, true) then
      rows[#rows + 1] = { text = fit(r.text), detail = recipeDetail(sidx, r, now), spell = r.spell, prof = r.prof,
                          item = r.item }
    end
  end
  return rows
end

-- ---------- /gsync demo ----------

-- Recipes the made-up crafters know, per profession id, in the directory's packed form (spell=item, 0: no item).
-- Alchemy and Tailoring carry the Arcanite transmute and Mooncloth, so the demo has cooldown rows.
local DEMO_RECIPES = {
  [171] = "2330=118,3170=3382,17187=12360", [164] = "2660=2862,2663=2853", [202] = "3922=4359,3918=4357",
  [165] = "2152=2304,2149=2302", [197] = "2387=2570,2393=2576,18560=14342", [333] = "7418=0,7420=0",
}
-- Cooldown records: member position in GUID order, group, seconds after now it is ready (0: ready). The other
-- alchemists and tailors have none, so they read unknown. 21 is a leatherworker with a ready Salt Shaker (f6608).
local DEMO_COOLDOWNS = {
  { 9, "tr", 0 }, { 25, "tr", 0 }, { 1, "tr", 5 * HOUR + 20 * MIN }, { 22, "tr", DAY + 14 * HOUR },
  { 11, "mc", 0 }, { 8, "mc", 18 * HOUR }, { 18, "mc", 3 * DAY + 2 * HOUR }, { 21, "ss", 0 },
}
-- Work board requests: requester, claimer (member positions in GUID order), item, qty, tip, hours ago, state.
local DEMO_REQUESTS = {
  { 2, nil, "i118", 5, 2, 2, "open" }, { 5, nil, "i2862", 10, 0, 5, "open" },
  { 3, 7, "i4359", 20, 5, 3, "claimed" }, { 4, 9, "i2570", 1, 1, 8, "done" },
}

-- The Crafting module's demo state (Demo.lua calls it with a copy of the made-up guild): { board, crafters, roster,
-- cooldowns }, in CraftBoard's, CraftStore's, Comm.Roster's and CraftSync.Cooldowns' shapes, built from now. Pure:
-- same guild and now, equal tables; guild is not changed.
-- Each request also carries its state ("open", "claimed", "done") as a plain field.
function CraftView.DemoState(guild, now)
  local guids = {}
  for guid in pairs(type(guild) == "table" and type(guild.members) == "table" and guild.members or {}) do
    guids[#guids + 1] = guid
  end
  table.sort(guids)
  local roster, crafters, list = {}, {}, {}
  for _, guid in ipairs(guids) do
    local m = guild.members[guid]
    local k = lower(m.name)
    list[#list + 1] = { key = k, name = m.name }
    roster[k] = { name = m.name, class = m.class, online = m.online == true, rankIndex = m.rankIndex,
      prof1 = m.prof1 and { id = m.prof1.id, name = m.prof1.name, rank = m.prof1.rank } or nil,
      prof2 = m.prof2 and { id = m.prof2.id, name = m.prof2.name, rank = m.prof2.rank } or nil }
    for _, p in ipairs({ m.prof1 or false, m.prof2 or false }) do
      if p and DEMO_RECIPES[p.id] then
        local c = crafters[k] or { name = m.name, seen = now - (m.lastOnlineDays or 0) * 86400, profs = {} }
        c.profs[p.id] = { rank = p.rank, max = 300, packed = DEMO_RECIPES[p.id] }
        crafters[k] = c
      end
    end
  end
  local board = {}
  for _, r in ipairs(DEMO_REQUESTS) do
    local by, claimer = list[r[1]], r[2] and list[r[2]]
    if by then
      local posted = now - r[6] * 3600
      local req = { id = string.format("%d-%s", posted, by.key), by = by.key, byName = by.name, what = r[3], qty = r[4],
        mats = true, tip = r[5], note = "", postedAt = posted, expiresAt = posted + 24 * 3600, claims = {}, drops = {},
        releasedAt = 0, state = r[7] }
      if claimer then req.claims[claimer.key] = { name = claimer.name, at = posted + 600 } end
      if r[7] == "done" then req.final = { kind = "done", at = posted + 3600 } end
      board[req.id] = req
    end
  end
  local cooldowns = {}
  for _, c in ipairs(DEMO_COOLDOWNS) do
    local who = list[c[1]]
    local crafter = who and crafters[who.key]
    if crafter then
      local rec = cooldowns[who.key] or { name = who.name, class = roster[who.key].class, seen = crafter.seen, cds = {} }
      rec.cds[c[2]] = c[3] > 0 and now + c[3] or 0
      cooldowns[who.key] = rec
    end
  end
  return { board = board, crafters = crafters, roster = roster, cooldowns = cooldowns }
end
