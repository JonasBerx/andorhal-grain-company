-- GuildSyncNoticeBoard: event banners (spec noticeboard/banners.md B1, B2, B5, B6a). One table of banners from the
-- game's own art (loaded by fileDataID; the path is in the comment), the sets per event kind (the first is the kind's
-- default), the description tag " [b:<id>]" that saves a choice, the Dungeon banner a calendar texture title names,
-- the crop maths and the one draw call pages use.
-- No client call but the texture methods in Banners.Draw: SetTexture(<fileDataID>), the 4-argument
-- SetTexCoord(left, right, top, bottom) (as LFGFrame.lua:697 in the 1.60.1 source), SetSize, ClearAllPoints,
-- SetPoint, Show, Hide.

local _, ns = ...
if not ns.M then return end

local C = ns.C
local Banners = {}
ns.Banners = Banners

local PARCHMENT = { l = 0.03, r = 0.60, t = 0.05, b = 0.95 }
local EMBLEM_SHARE = 0.9 -- the emblem's side, as a share of the box's short side (mock.js: .emb height 90%)

-- [id] = { label, file (fileDataID), w, h (texture size in pixels), crop = { l, r, t, b }?, emblem = { file, w, h }? }
-- Sizes from the research (q3); the four raid textures were not decoded and are entered as 256 x 128 (q-raid-size).
Banners.LIST = {
  mc = { label = "Molten Core", file = 340678, w = 256, h = 128 },          -- interface/lfgframe/ui-lfg-background-moltencore
  bwl = { label = "Blackwing Lair", file = 340659, w = 256, h = 128 },      -- interface/lfgframe/ui-lfg-background-blackwinglair
  zg = { label = "Zul'Gurub", file = 340705, w = 256, h = 128 },            -- interface/lfgframe/ui-lfg-background-zulgurub
  naxx = { label = "Naxxramas", file = 340679, w = 256, h = 128 },          -- interface/lfgframe/ui-lfg-background-naxxramas
  dm = { label = "The Deadmines", file = 337488, w = 256, h = 128 },        -- interface/lfgframe/ui-lfg-background-deadmines
  wc = { label = "Wailing Caverns", file = 340702, w = 256, h = 128 },      -- interface/lfgframe/ui-lfg-background-wailingcaverns
  sfk = { label = "Shadowfang Keep", file = 340687, w = 256, h = 128 },     -- interface/lfgframe/ui-lfg-background-shadowfangkeep
  sm = { label = "Scarlet Monastery", file = 340685, w = 256, h = 128 },    -- interface/lfgframe/ui-lfg-background-scarletmonastery
  strat = { label = "Stratholme", file = 340689, w = 256, h = 128 },        -- interface/lfgframe/ui-lfg-background-stratholme
  scholo = { label = "Scholomance", file = 340686, w = 256, h = 128 },      -- interface/lfgframe/ui-lfg-background-scholomance
  brd = { label = "Blackrock Depths", file = 340656, w = 256, h = 128 },    -- interface/lfgframe/ui-lfg-background-blackrockdepths
  dire = { label = "Dire Maul", file = 340663, w = 256, h = 128 },          -- interface/lfgframe/ui-lfg-background-diremaul
  ab = { label = "Arathi Basin", file = 460622, w = 256, h = 128 },         -- interface/pvpframe/pvpbg-arathibasin-toastbg
  wsg = { label = "Warsong Gulch", file = 460633, w = 256, h = 128 },       -- interface/pvpframe/pvpbg-warsonggulch-toastbg
  av = { label = "Alterac Valley", file = 460621, w = 256, h = 128 },       -- interface/pvpframe/pvpbg-alteracvalley-toastbg
  lord = { label = "Ruins of Lordaeron", file = 460629, w = 256, h = 128 }, -- interface/pvpframe/pvpbg-ruinsoflordaeron-toastbg
  tavern = { label = "Tavern (Brewfest)", file = 368570, w = 256, h = 128 },        -- interface/lfgframe/ui-lfg-holiday-background-brew
  bonfire = { label = "Bonfire (Midsummer)", file = 368573, w = 256, h = 128 },     -- interface/lfgframe/ui-lfg-holiday-background-summer
  forsaken = { label = "Forsaken (Hallow's End)", file = 368571, w = 256, h = 128 }, -- interface/lfgframe/ui-lfg-holiday-background-halloween
  -- interface/lfgframe/ui-lfg-background-questpaper (cropped) + interface/lootframe/fishingloot-icon centred on it
  fishing = { label = "Fishing", file = 337492, w = 512, h = 256, crop = PARCHMENT,
    emblem = { file = 136372, w = 128, h = 128 } },
  notice = { label = "Notice parchment", file = 337492, w = 512, h = 256, crop = PARCHMENT }, -- questpaper (cropped)
}

Banners.ORDER = { "mc", "bwl", "zg", "naxx", "dm", "wc", "sfk", "sm", "strat", "scholo", "brd", "dire", "ab", "wsg",
  "av", "lord", "tavern", "bonfire", "forsaken", "fishing", "notice" }

-- The sets per kind; the first id is the kind's default. A kind not listed uses other.
Banners.SETS = {
  raid = { "mc", "bwl", "zg", "naxx" }, -- the director's addition, q285
  dungeon = { "dm", "wc", "sfk", "sm", "strat", "scholo", "brd", "dire" },
  pvp = { "ab", "wsg", "av" },
  social = { "tavern", "bonfire", "fishing" },
  rp = { "lord", "forsaken", "tavern" },
  other = { "notice", "bonfire" },
  announcement = { "notice" },
}
Banners.KINDS = { "raid", "dungeon", "pvp", "social", "rp", "other", "announcement" }

function Banners.Known(id) return id ~= nil and Banners.LIST[id] ~= nil end

function Banners.Set(kind) return Banners.SETS[kind] or Banners.SETS.other end

function Banners.Default(kind) return Banners.Set(kind)[1] end

-- ---------- the tag ----------

function Banners.Tag(id) return " [b:" .. id .. "]" end

-- description with the tag of a known id at its end; an unknown id adds nothing.
function Banners.WithTag(description, id)
  if not Banners.Known(id) then return description end
  return description .. Banners.Tag(id)
end

-- -> id, shown description (the tag and one optional space before it removed), tagged. Only a known tag at the very
-- end counts, with or without that space; anything else is the kind's default with the description unchanged.
function Banners.Read(description, kind)
  local desc = type(description) == "string" and description or ""
  local start, _, id = desc:find(" ?%[b:(%w+)%]$")
  if id and Banners.Known(id) then return id, desc:sub(1, start - 1), true end
  return Banners.Default(kind), desc, false
end

local tagMax = 0
for _, id in ipairs(Banners.ORDER) do tagMax = math.max(tagMax, #Banners.Tag(id)) end
Banners.TAG_MAX = tagMax
Banners.DESC_LETTERS = C.EVENT_DESC - tagMax

-- ---------- the dungeon a texture names ----------

-- Lower case, a leading "the " dropped, letters only: "The Deadmines" and "Deadmines" read the same.
local function nameKey(s) return (s:lower():gsub("^the ", ""):gsub("[^%a]", "")) end

-- The Dungeon banner whose label names the same place as a calendar texture title (C_Calendar.EventGetTextures);
-- nil when none does. Only the Dungeon set is searched.
function Banners.FromTextureTitle(title)
  if type(title) ~= "string" then return nil end
  local k = nameKey(title)
  if k == "" then return nil end
  for _, id in ipairs(Banners.SETS.dungeon) do
    if nameKey(Banners.LIST[id].label) == k then return id end
  end
  return nil
end

-- ---------- crop and draw ----------

local function num(n) return type(n) == "number" and n > 0 end

-- -> l, r, t, b: the banner's own crop, then its centre cut to the box's aspect so the picture is never stretched.
-- With no usable box (nil, zero or negative) the banner's own crop. Every division is guarded (Forever raises on /0).
function Banners.Crop(id, w, h)
  local b = Banners.LIST[id] or Banners.LIST.notice
  local c = b.crop or { l = 0, r = 1, t = 0, b = 1 }
  local l, r, t, bot = c.l, c.r, c.t, c.b
  if not (num(w) and num(h)) then return l, r, t, bot end
  local cw, ch = (r - l) * b.w, (bot - t) * b.h
  if not (num(cw) and num(ch)) then return l, r, t, bot end
  local A, S = w / h, cw / ch
  if S > A then
    local half = (r - l) * A / S / 2
    local mid = (l + r) / 2
    return mid - half, mid + half, t, bot
  end
  local half = (bot - t) * S / A / 2
  local mid = (t + bot) / 2
  return l, r, mid - half, mid + half
end

-- Draws banner id (unknown -> notice) into tex, a box of w x h; with an emblem texture, shows the banner's emblem
-- centred on tex, or hides it when the banner has none.
function Banners.Draw(tex, id, w, h, emblem)
  if not Banners.Known(id) then id = "notice" end
  local b = Banners.LIST[id]
  tex:SetTexture(b.file)
  tex:SetTexCoord(Banners.Crop(id, w, h))
  if not emblem then return end
  if b.emblem then
    local side = math.floor(math.min(num(w) and w or 0, num(h) and h or 0) * EMBLEM_SHARE)
    emblem:SetTexture(b.emblem.file)
    emblem:SetTexCoord(0, 1, 0, 1)
    emblem:SetSize(side, side)
    emblem:ClearAllPoints()
    emblem:SetPoint("CENTER", tex, "CENTER", 0, 0)
    emblem:Show()
  else
    emblem:Hide()
  end
end
