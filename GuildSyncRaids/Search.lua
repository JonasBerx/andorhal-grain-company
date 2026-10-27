local _, ns = ...
if not ns.M then return end

-- The hub search's Raids group (API 8, Raids.lua's search.find): the upcoming raids whose title, team, date words
-- ("tuesday", "tue", "06", "october", "oct", and "today", "tonight", "tomorrow") or a signed-up character's name hold
-- the query. Read-only and cheap: one ns.View() per query (the demo calendar in demo), no sends, timers, saved writes
-- or frame work. A click opens the Raids page on that raid.

local M = ns.M
local MAX = 25
local DOT = " \194\183 " -- " · "

local function low(s) return string.lower(tostring(s or "")) end

-- The raid's own words, one field per line, so a query never matches across two fields (f6557).
local function haystack(ev, t, tomorrow)
  local fields = { low(ev.title), low(ev.team), low(ns.When("%A %a %d %B %b", ev.start)) }
  if ns.Tonight(ev, t, date) then fields[#fields + 1] = "today\ntonight" end
  if ns.When("%Y-%m-%d", ev.start) == tomorrow then fields[#fields + 1] = "tomorrow" end
  return table.concat(fields, "\n")
end

-- The next local date after t: the calendar day plus one, normalised by time() (month ends, DST days; never
-- t + 86400). Noon keeps a DST change from moving the day.
local function nextDay(t)
  local d = date("*t", t)
  d.day, d.hour, d.min, d.sec, d.isdst = d.day + 1, 12, 0, 0, nil
  return ns.When("%Y-%m-%d", time(d))
end

function ns.SearchFind(text)
  local t = M.Compat.call("GetServerTime") or 0
  local tomorrow = nextDay(t)
  local hits = {}
  for _, ev in ipairs(ns.View().events) do
    if ev.start and (ev.finish or ev.start) > t then
      if string.find(haystack(ev, t, tomorrow), text, 1, true) then
        hits[#hits + 1] = { ev = ev }
      else
        -- Sign-ups apart, so the detail can name the one that matched.
        for _, s in ipairs(ev.signups or {}) do
          if string.find(low(s.character), text, 1, true) then
            hits[#hits + 1] = { ev = ev, who = tostring(s.character) }
            break
          end
        end
      end
    end
  end
  table.sort(hits, function(a, b)
    if a.ev.start ~= b.ev.start then return a.ev.start < b.ev.start end
    return a.ev.key < b.ev.key
  end)
  local rows = {}
  for i = 1, math.min(#hits, MAX) do
    local ev, who = hits[i].ev, hits[i].who
    local detail = ns.When("%a %d %b %H:%M", ev.start)
    if ev.team then detail = detail .. DOT .. ev.team end
    if who then detail = detail .. DOT .. who .. " signed up" end
    local key = ev.key
    -- The page first (it is shown and drawn), then the choice: ns.Select sets it and redraws the shown page.
    rows[i] = { text = ev.title, detail = detail, open = function() M.OpenPage(); ns.Select(key) end }
  end
  return rows
end
