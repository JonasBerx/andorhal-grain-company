-- GuildSyncNoticeBoard: the demo builder (brief AC43). Build(guild, now) is pure: it reads only the made-up guild and the
-- `now` it is handed (no client call, no roster, no clock) and returns made-up events in Calendar.lua's row shape and
-- notices, polls and votes in Store.lua's record shape. While demo is on, Calendar.lua and Store.lua read this state
-- and every write says the inert line; nothing here is saved.

local _, ns = ...
if not ns.M then return end

local C, Rules = ns.C, ns.Rules
local Demo = {}
ns.Demo = Demo

local DAY, HOUR = 86400, 3600

-- { title, board type, calendar type, hours from now (rounded to the hour), my invite status, banner (B6: from the
-- kind's set in Banners.lua) }
local EVENTS = {
  { "Deadmines run", "dungeon", "GUILD_EVENT", 26, 6, "dm" },
  { "Arathi Basin premade", "pvp", "GUILD_EVENT", 50, 8, "ab" },
  { "Fishing contest", "social", "GUILD_EVENT", 74, 7, "fishing" },
  { "Tavern night", "rp", "GUILD_EVENT", 122, 7, "tavern" },
  { "Bank day: bring your spare herbs", "announcement", "GUILD_ANNOUNCEMENT", 170, nil, "notice" },
}

-- { title, body, pinned, days ago posted, days live, officers only }
local NOTICES = {
  { "Raid nights are Tuesday and Thursday", "Invites go out at 19:45. Be on time.", true, 3, 30 },
  { "Guild bank open on Sundays", "Ask the banker for mats you need.", false, 1, 14, true },
}

-- { question, options, hours ago posted, hours open }
local POLLS = {
  { "Which dungeon next weekend?", { "Scholomance", "Stratholme", "Blackrock Depths" }, 20, 72 },
  { "Second raid night?", { "Wednesday", "Sunday" }, 100, 72 },
}

-- names: key -> the made-up member's display name (f1510: they are not in the real roster).
local function memberKeys(guild)
  local ids, names = {}, {}
  for id in pairs(guild.members or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local officers, others = {}, {}
  for _, id in ipairs(ids) do
    local m = guild.members[id]
    local key = GuildSync.Comm.Key(m.name)
    if key then
      names[key] = m.name
      -- made-up guild only: the hub's DemoGuild has no officer flag, so its rank 0-1 members (Guild Master,
      -- Overseer) author the made-up notices and polls. Not an officer rule: outside demo the hub decides (AC34).
      if (m.rankIndex or 99) <= 1 then officers[#officers + 1] = key else others[#others + 1] = key end
    end
  end
  return officers, others, names
end

function Demo.Build(guild, now)
  now = math.floor(now)
  local officers, others, names = memberKeys(guild)
  if #officers == 0 then officers = others end -- Forever raises on % 0: never divide by an empty list
  local state = { events = {}, notices = {}, polls = {}, members = {}, names = names }

  local hourMin = math.floor(now / HOUR) * 60
  for i, e in ipairs(EVENTS) do
    local time = Rules.FromMinutes(hourMin + e[4] * 60)
    state.events[i] = { index = i, eventID = 9000 + i, title = GuildSync.Escape(e[1]), rawTitle = e[1], kind = e[2],
      calendarType = e[3], time = time, minutes = Rules.Minutes(time), status = e[5], readable = true, banner = e[6] }
  end
  if #officers == 0 then return state end

  for i, n in ipairs(NOTICES) do
    local author = officers[(i - 1) % #officers + 1]
    local t = now - n[4] * DAY
    local expiresAt = t + n[5] * DAY
    state.notices[i] = { key = Rules.NoticeKey(t, author), rev = t, by = author, author = author, title = n[1],
      body = n[2], pinned = n[3], expiresAt = expiresAt, keepUntil = expiresAt, officers = n[6] }
  end

  for i, q in ipairs(POLLS) do
    local author = officers[(i - 1) % #officers + 1]
    local t = now - q[3] * HOUR
    local closeAt = t + q[4] * HOUR
    local options = {}
    for j, o in ipairs(q[2]) do options[j] = o end
    local key = Rules.PollKey(t, author)
    state.polls[i] = { key = key, rev = t, by = author, author = author, question = q[1], options = options,
      closeAt = closeAt, firstCloseAt = closeAt, keepUntil = closeAt + C.POLL_KEEP_DAYS * DAY }
    -- a handful of made-up votes, spread over the options
    for v = 1, math.min(#others, 4 + i) do
      local voter = others[v]
      local rec = state.members[voter]
      if not rec then
        rec = { rev = t, by = voter, votes = {} }
        state.members[voter] = rec
      end
      local at = t + v * 600
      rec.votes[key] = { option = (v + i) % #options + 1, at = at }
      if at > rec.rev then rec.rev = at end
    end
  end

  return state
end
