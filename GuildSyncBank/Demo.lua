-- GuildSyncBank demo: the made-up bank behind /gsync demo, over the hub's made-up guild (GuildSync/DemoGuild.lua).
-- Pure: Build reads only the guild, the `now` and the keyOf it is given, so the same `now` gives equal tables.
--   ns.Demo.Build(guild, now, keyOf) -> { records, bankChars = { [key] = true }, roster = { [key] = row }, me = key }
-- records are in the store's shape: records[domain][key] = { rev, by, at, body }. The first two members by sorted guid
-- are the bank characters; the first of them is me (with a roster row and a bank_m record). Every item id comes from
-- DEMO_ITEMS, a fixed list of real classic item ids (demo data only, not reagent data).

local _, ns = ...
if not ns.M then return end

local Demo = {}
ns.Demo = Demo

local DEMO_ITEMS = {
  2589,  -- Linen Cloth
  2592,  -- Wool Cloth
  4306,  -- Silk Cloth
  14047, -- Runecloth
  2840,  -- Copper Bar
  3575,  -- Iron Bar
  12359, -- Thorium Bar
  13463, -- Dreamfoil
  8831,  -- Purple Lotus
  4304,  -- Thick Leather
  8170,  -- Rugged Leather
  13444, -- Major Mana Potion
  13446, -- Major Healing Potion
  14530, -- Heavy Runecloth Bandage
}

local HOUR, DAY = 3600, 86400

function Demo.Build(guild, now, keyOf)
  local I = DEMO_ITEMS
  local guids = {}
  for guid in pairs(type(guild) == "table" and type(guild.members) == "table" and guild.members or {}) do
    guids[#guids + 1] = guid
  end
  table.sort(guids)

  local roster, names, keys = {}, {}, {}
  for i, guid in ipairs(guids) do
    local m = guild.members[guid]
    local key = keyOf(m.name)
    names[i], keys[i] = m.name, key
    roster[key] = { name = m.name, class = m.class, online = m.online and true or false, rankIndex = m.rankIndex }
  end
  local bankChars = {}
  if keys[1] then bankChars[keys[1]] = true end
  if keys[2] then bankChars[keys[2]] = true end
  local me = keys[1]

  local records = {}
  local function put(family, n, i, at, body)
    local key = ns.Key(family, n, keys[i])
    local domain = ns.DOMAIN[family]
    records[domain] = records[domain] or {}
    records[domain][key] = { rev = 1, by = names[i], at = at, body = body }
    return key
  end
  if #keys < 6 then return { records = records, bankChars = bankChars, roster = roster, me = me } end

  -- contents: bags and bank of both bank characters, one guild bank tab on me
  put("b", 1, 1, now - 10 * 60, { scanned = now - 10 * 60, money = 1234567,
    items = { [I[1]] = 120, [I[2]] = 60, [I[5]] = 40, [I[13]] = 5 } })
  put("k", 1, 1, now - 10 * 60, { scanned = now - 10 * 60, items = { [I[3]] = 80, [I[6]] = 20, [I[10]] = 15 } })
  put("g", 1, 1, now - 2 * HOUR, { scanned = now - 2 * HOUR, items = { [I[4]] = 200, [I[12]] = 10 } })
  put("b", 1, 2, now - 3 * HOUR, { scanned = now - 3 * HOUR, money = 345678,
    items = { [I[1]] = 40, [I[8]] = 30, [I[9]] = 4, [I[11]] = 12 } })

  -- requisitions: two open (one with a pledge and a pending send), one filled
  local q1Posted, q2Posted, q3Posted = now - 3 * DAY, now - 2 * DAY, now - 5 * DAY
  local q1 = put("q", 1, 1, q1Posted, { posted = q1Posted, item = I[4], wanted = 400, why = "Runecloth bags" })
  local q2 = put("q", 2, 2, q2Posted, { posted = q2Posted, item = I[13], wanted = 40, why = "Molten Core flasks" })
  local q3 = put("q", 3, 1, q3Posted, { posted = q3Posted, item = I[7], wanted = 20, why = "Thorium arrows" })
  local id1, id2, id3 = q1 .. "@" .. q1Posted, q2 .. "@" .. q2Posted, q3 .. "@" .. q3Posted

  -- members: pledges, sends and requests
  local ask3, ask4 = now - 4 * DAY, now - 1 * DAY
  put("m", nil, 1, now - DAY, { pledges = {}, sends = {}, requests = {} })
  put("m", nil, 3, now - 6 * HOUR, {
    pledges = { [id1] = { amount = 100, at = now - 2 * DAY } },
    sends = { [id1] = { amount = 60, at = now - 6 * HOUR } },
    requests = { { item = I[14], count = 20, note = "for raid", at = ask3 } } })
  put("m", nil, 4, now - DAY, {
    pledges = { [id2] = { amount = 10, at = now - DAY } },
    sends = { [id3] = { amount = 20, at = now - 4 * DAY } },
    requests = { { item = I[12], count = 5, note = "", at = ask4 } } })
  put("m", nil, 5, now - 2 * DAY, { pledges = {}, sends = {},
    requests = { { item = I[2], count = 40, note = "first aid", at = now - 2 * DAY } } })

  -- ledger and answers on me: the filled requisition's receipt, one answered request
  put("l", 1, 1, now - 3 * DAY, { receipts = {
    { req = id3, member = keys[4], amount = 20, sent = now - 4 * DAY, at = now - 3 * DAY } },
    unpledges = {}, unsends = {} })
  put("a", 1, 1, now - 3 * DAY, { { member = keys[3], at = ask3, verdict = "fulfilled", when = now - 3 * DAY } })

  -- contributions
  local month = ns.Month(now)
  put("t", 1, 1, now - 3 * DAY, {
    [keys[4]] = { all = 20, month = month, inMonth = 20 },
    [keys[3]] = { all = 340, month = month, inMonth = 60 },
    [keys[6]] = { all = 120 },
  })

  -- gold ledger on both bank characters, oldest first; guild gold on me (money as their bag scans above)
  put("j", 1, 1, now - 10 * 60, { scanned = now - 10 * 60, money = 1234567,
    guild = 8765432, guildAt = now - 2 * HOUR, e = {
      { t = now - 3 * DAY, d = 500000, k = "m", w = names[3] },
      { t = now - 2 * DAY, d = -200000, k = "g" },
      { t = now - DAY, d = 35000, k = "v" },
      { t = now - 6 * HOUR, d = -12000, k = "s" },
      { t = now - HOUR, d = -150000, k = "m", w = names[4] },
    } })
  put("j", 1, 2, now - 3 * HOUR, { scanned = now - 3 * HOUR, money = 345678, e = {
    { t = now - 2 * DAY, d = 100000, k = "g" },
    { t = now - DAY, d = -5000, k = "o" },
    { t = now - 4 * HOUR, d = 20000, k = "m", w = names[5] },
  } })

  -- minimums: 13444, 13446 and 8831 run low; 13444 on both, me's newer entry wins; Dreamfoil (30 held) is a raid
  -- item above its minimum, so Raid night shows low first and then one that is not (f6392)
  put("n", 1, 1, now - DAY, { [I[12]] = { m = 40, r = 1, t = now - DAY }, [I[13]] = { m = 20, r = 1, t = now - DAY },
    [I[4]] = { m = 100, t = now - DAY }, [I[8]] = { m = 20, r = 1, t = now - DAY } })
  put("n", 1, 2, now - 2 * DAY, { [I[9]] = { m = 10, t = now - 2 * DAY }, [I[12]] = { m = 30, t = now - 2 * DAY } })

  return { records = records, bankChars = bankChars, roster = roster, me = me }
end
