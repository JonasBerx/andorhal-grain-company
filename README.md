# Andorhal Grain Company addons

The guild addons of the Andorhal Grain Company, for World of Warcraft: Forever. One download holds GuildSync and every
guild module, so the whole guild runs matching versions.

| Folder | Module | What it does |
|---|---|---|
| GuildSync | GuildSync | The hub: roster, guild log and the suite window (`/gsync ui`). It must stay on. |
| GuildSyncPeople | People | Profile cards: what guildmates like and when they usually play. |
| Annals | Annals | Level race, guild health and achievements. |
| GuildKOS | Kill on Sight | Alerts when an enemy on the guild's list is near. |
| GuildSyncRaids | Raids | The raid calendar from Raid-Helper, with soft reserves. |
| GuildSyncBank | Bank | The guild bank: contents, requisitions and requests. |
| GuildSyncNoticeBoard | Notice Board | Guild events, officer notices and polls. |
| GuildSyncCrafting | Crafting | A work board, a crafter finder and recipes. |
| GuildSyncGames | Games | WoWdle, a WoW word a day, and a game on flights. |

## Install

1. Close the game.
2. Download the latest `GuildSync-<version>-forever.zip` from this repository's Releases.
3. Delete the old suite folders from `<game folder>/Interface/AddOns/`, then unzip every folder from the zip into it.
4. If the game marks the addons out of date, tick "Load out of date AddOns" in the AddOns list.

GuildSync must stay on. You can switch any other module off in the AddOns list on the character screen. About a
minute after login, type `/gsync selftest`: the last line should end in "0 wait, 0 fail".

## About this repository

This is the addon source as it is released. The versions come from the release tag: the `@project-version@` lines in
the TOC files are filled in when the release zip is built, so a copy taken straight from here shows a development
version in game. Changes are made in the guild's own repository and copied here with each release.

## License

MIT, see [LICENSE](LICENSE).
