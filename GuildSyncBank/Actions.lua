-- GuildSyncBank actions: the glue between the page and the rules.
--   ns.Data(now, live) -> { view, who, ctx, isDemo, now, wait }   live == true reads the live state even under demo
--   ns.Do(verb, args) -> true | nil, message                       refuses while /gsync demo is on; SaveMine's
--                                                                  refusals answer V3, V3t and V6 (plan section 9)
-- Under demo the view, ctx and who come from the demo state (me, roster, bankChars); who may do everything there.
-- Compact (g1) runs once per session, on the first Ranks.OnChange where this character is a bank character and its
-- own key is settled (MyKey has a roster row: Store.IsOwn is not roster-gated, f5328); before the roster read
-- Store.Put refuses anyway (R3), so there is no login hook.

local _, ns = ...
if not ns.M then return end

local M = ns.M

-- SaveMine's refusals (plan section 9, exact texts).
local REFUSED = {
  full = "The bank's records are full: old requisitions must close first.",
  tfull = "The contributions list is full: an officer must clear members who left.",
  held = "Your bank records are held by other officers: type /gsbank adopt to take them back, or /gsbank fresh to start new ones.",
  catchup = "Bank: catching up with the other officers, try again in a minute.",
  fullroster = "Bank: waiting for the full guild roster, try again in a minute.",
}

-- The own key is settled: MyKey has a roster row, so Store.Put writes (R3).
local function settled(key) return key ~= nil and GuildSync.Comm.Member(key) ~= nil end

local function serverNow() return GuildSync.Compat.Plain(M.Compat.call("GetServerTime")) end

local function demoCtx(state, now)
  local bank, roster = state.bankChars or {}, state.roster or {}
  return {
    now = now, me = state.me, roster = roster,
    isBankChar = function(key) return bank[key] == true end,
    isOfficer = function(key) return bank[key] == true or (roster[key] and roster[key].officer == true) or false end,
    keyOf = GuildSync.Comm.Key,
    limits = ns.LIMITS,
  }
end

function ns.Data(now, live)
  local state, isDemo
  if live then
    state, isDemo = { records = ns.Store.All() }, false
  else
    state, isDemo = ns.Source()
  end
  if isDemo then
    state = state or {}
    local ctx = demoCtx(state, now)
    return { view = ns.Derive.State(state.records or {}, ctx), who = { key = state.me, bank = true, officer = true },
      ctx = ctx, isDemo = true, now = now, wait = nil }
  end
  local ctx = ns.Ranks.Ctx(now)
  return { view = ns.Derive.State(state.records, ctx), who = ns.Ranks.Who(GuildSync.Comm.MyKey()), ctx = ctx,
    isDemo = false, now = now, wait = ns.Ranks.RanksLine() }
end

function ns.Do(verb, args)
  if M.Demo() then return nil, "Demo: nothing is done." end
  local rule = ns.Rules[verb]
  if type(rule) ~= "function" then return nil, "That cannot be done here." end
  local now = serverNow()
  local data = ns.Data(now, true)
  if not settled(data.who.key) then return nil, "Waiting for the guild roster." end
  args = args or {}
  if verb == "post" then
    local copy = {}
    for k, v in pairs(args) do copy[k] = v end
    copy.slot = ns.Store.FreeSlot(data.view, now)
    args = copy
  end
  local own = ns.Store.Mine()
  local result, _, message = rule(data.view, data.who, args, now, own)
  if result == nil then return nil, message end
  local changed, why = ns.Store.SaveMine(own, now)
  if not changed then return nil, REFUSED[why] or "That cannot be done here." end
  return true
end

local compacted = false
ns.Ranks.OnChange(function()
  if compacted or M.Demo() then return end
  local me = GuildSync.Comm.MyKey()
  if not (settled(me) and ns.Ranks.IsBankChar(me)) then return end
  compacted = true
  local now = serverNow()
  local data = ns.Data(now, true)
  local own = ns.Store.Mine()
  -- a refused SaveMine (catch-up, held) leaves compact for a later OnChange (f5311)
  if ns.Rules.compact(data.view, data.who, {}, now, own) and not ns.Store.SaveMine(own, now) then compacted = false end
end)
