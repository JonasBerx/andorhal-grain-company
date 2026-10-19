-- GuildSync Suite: the guild's addons, the hub first (R7, d403-d405). Data only, no code.
--
-- Read by the Modules page and the module advert in game, and by addon/tools/suite.js (luaparse) for the scaffolder
-- and addon:install. Every field is a literal string or boolean: suite.js refuses anything else.
-- Ids are d405's. The hub entry is exempt from the module id and title rules.
-- Icons: the TOC IconTexture where the addon has one, else a placeholder (q323). Lines: per the approved mock (q317).

local ADDON, ns = ...

ns.SUITE = {
  { folder = "GuildSync", id = "guildsync", name = "GuildSync",
    icon = "Interface\\Icons\\INV_Misc_Bag_10",
    line = "The hub: roster, guild log and this window.", hub = true },
  { folder = "GuildSyncPeople", id = "people", name = "People",
    icon = "Interface\\Icons\\Spell_Holy_PrayerOfSpirit",
    line = "Profile cards: what guildmates like and when they usually play." },
  { folder = "Annals", id = "annals", name = "Annals",
    icon = "Interface\\Icons\\INV_Misc_Book_09",
    line = "Level race, guild health and achievements." },
  { folder = "GuildKOS", id = "kos", name = "Kill on Sight",
    icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
    line = "Alerts when an enemy on the guild's list is near." },
  { folder = "GuildSyncRaids", id = "raids", name = "Raids",
    icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
    line = "The raid calendar from Raid-Helper, with soft reserves." },
  { folder = "GuildSyncBank", id = "bank", name = "Bank",
    icon = "Interface\\Icons\\INV_Ingot_02",
    line = "The guild bank: contents, requisitions and requests." },
  { folder = "GuildSyncNoticeBoard", id = "board", name = "Notice Board",
    icon = "Interface\\Icons\\INV_Misc_Note_01",
    line = "Guild events, officer notices and polls." },
  { folder = "GuildSyncCrafting", id = "crafting", name = "Crafting",
    icon = "Interface\\Icons\\Trade_BlackSmithing",
    line = "Crafting: a work board, a crafter finder and recipes." },
}
