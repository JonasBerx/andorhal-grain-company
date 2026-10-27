-- GuildSyncBank: the guild bank as a GuildSync module (bank/brief.md; UI slice o314, sync run t42).
-- This first file registers the module and holds the seams every later file uses:
--   ns.DB()              GuildSyncBankDB, read at call time (never at file load: the client sets saved variables
--                        after the files ran), created when nil; a file below v2 loses its records (d778)
--   ns.Listen(event, fn) fn(event, ...) under M.Safe on each client event below, and on the pseudo-event "login"
--   ns.Source()          state, isDemo: the live records, or what ns.Demo.Build returned while /gsync demo is on
-- Later files (Store, Derive, Rules, Ranks, ... Page) fill in ns; selftest, status, the page and demo reach them lazily,
-- so this file works while they are missing. /gsbank adopt and /gsbank fresh reach ns.Sync (d784); any other
-- /gsbank opens the page.

local _, ns = ...

local EVENTS = { "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "BANK_TABS_CHANGED", "BANKFRAME_OPENED",
  "BANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "PLAYER_MONEY",
  "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "GUILDBANKBAGSLOTS_CHANGED", "GUILDBANK_UPDATE_MONEY", "MAIL_SHOW",
  "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "ITEM_DATA_LOAD_RESULT", "MERCHANT_SHOW", "MERCHANT_CLOSED", "MAIL_SEND_SUCCESS",
  "MAIL_FAILED", "SECURE_TRANSFER_CANCEL", "PLAYER_LOGOUT" }

local listeners = {} -- event (or "login") -> { fn, ... }
local M, Key         -- set right after the guard

-- Every listener of event under M.Safe: a throw is recorded under Bank and the next one still runs.
local function dispatch(event, ...)
  local list = listeners[event]
  if not list then return end
  for i = 1, #list do M.Safe(list[i], event, ...) end
end

-- /gsbank adopt and /gsbank fresh (d784, section 9 V6); anything else opens the page.
local function slash(msg)
  local word = type(msg) == "string" and msg:match("^%s*(%S*)"):lower() or ""
  if word == "adopt" and ns.Sync then
    local n, names, conflicts = ns.Sync.Adopt(M.Compat and M.Compat.call("GetServerTime"))
    if n > 0 then GuildSync.Say("Bank: took back " .. n .. " records from " .. table.concat(names, ", ") .. ".") end
    if conflicts > 0 then
      GuildSync.Say("Bank: " .. conflicts .. " keys had different copies from different officers; the newest was taken.")
    end
  elseif word == "fresh" and ns.Sync then
    ns.Sync.Fresh()
    GuildSync.Say("Bank: starting new records.")
  else
    M.OpenPage()
  end
end

M = GuildSync and GuildSync.RegisterModule({
  id = "bank",
  title = "Bank",
  version = "0.5",
  needs = 8, -- API 8 for the search provider (s6); API 6 for M.Kit.ItemButton/SetItem
  apis = {
    "GetServerTime", "GetMoney",
    "C_Container.GetContainerNumSlots", "C_Container.GetContainerItemInfo",
    "C_Bank.CanViewBank", "C_Bank.FetchPurchasedBankTabIDs",
    "C_Item.GetItemInfo", "C_Item.GetItemIconByID", "C_Item.IsItemDataCachedByID",
    "C_Club.GetGuildClubId", "C_Club.GetClubMembers", "C_Club.GetMemberInfo", "C_Club.GetMemberInfoForSelf",
    optional = {
      "C_Item.RequestLoadItemDataByID", -- missing on the Forever client (build 70245); C_Item.GetItemInfo stands in
      "C_Item.DoesItemExistByID",
      "C_GuildBank.IsGuildBankEnabled",
      "GuildControlGetRankName", -- documented (R8 probe, check-stubs.js:79)
      "QueryGuildBankTab", -- undocumented, beta check
      "GetNumGuildBankTabs", -- undocumented, beta check
      "GetGuildBankTabInfo", -- undocumented, beta check
      "GetGuildBankItemInfo", -- undocumented, beta check
      "GetGuildBankItemLink", -- undocumented, beta check
      "GetGuildBankMoney", -- undocumented, beta check
      "GetCurrentGuildBankTab", -- undocumented, beta check
      "GetInboxHeaderInfo", -- undocumented, beta check
      "GetInboxItem", -- undocumented, beta check
      "GetInboxItemLink", -- undocumented, beta check
      "ChatFrameUtil.InsertLink", -- undocumented, beta check
      "ChatEdit_InsertLink", -- undocumented, beta check
      "SendMail", -- undocumented, beta check
      "GetSendMailMoney", -- undocumented, beta check
      "C_Item.GetItemInfoInstant", -- documented
    },
  },
  events = EVENTS,
  onEvent = function(event, ...) dispatch(event, ...) end,
  onLogin = function() dispatch("login") end,
  page = {
    title = "Bank",
    icon = "Interface\\Icons\\INV_Misc_Bag_10",
    build = function(frame) if ns.Page then ns.Page.Build(frame) end end,
    refresh = function(frame) if ns.Page then ns.Page.Refresh(frame) end end,
  },
  slash = slash,
  search = { find = function(text) return ns.SearchFind and ns.SearchFind(text) end },
  selftest = function()
    if ns.Health then return ns.Health.SelfTest() end
    return "wait", "loading"
  end,
  status = function()
    if ns.Health then return ns.Health.Status() end
    return ""
  end,
  demo = function(guild, now)
    if ns.Demo then return ns.Demo.Build(guild, now, Key) end
  end,
})
if not M then return end
ns.M = M -- M stays in this addon: never hand it to other code

Key = GuildSync.Comm.Key

local KNOWN = { login = true }
for _, e in ipairs(EVENTS) do KNOWN[e] = true end

function ns.DB()
  local db = GuildSyncBankDB
  if type(db) ~= "table" then
    db = { v = 2 }
    GuildSyncBankDB = db
  end
  -- d778: a file older than v2 (no wire text or hash) loses its records; ranks, settings and hidden stay
  if type(db.v) ~= "number" or db.v < 2 then
    db.records = {}
    db.v = 2
  end
  for _, f in ipairs({ "records", "ranks", "settings" }) do
    if type(db[f]) ~= "table" then db[f] = {} end
  end
  return db
end

function ns.Listen(event, fn)
  if not KNOWN[event] then error("ns.Listen: " .. tostring(event) .. " is not one of Bank's events", 2) end
  if type(fn) ~= "function" then error("ns.Listen: the listener is not a function", 2) end
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

function ns.Source()
  local on, state = M.Demo()
  if on then return state, true end
  return { records = ns.Store and ns.Store.All() or {} }, false
end

-- /gsbank and /gsync bank: the Bank page.
SLASH_GSBANK1 = "/gsbank"
SlashCmdList.GSBANK = function(msg) M.Safe(slash, msg) end
