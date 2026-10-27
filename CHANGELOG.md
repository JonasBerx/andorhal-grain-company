# Changelog

## 0.14.0

### GuildSync

- What's new: after an update, one panel lists what changed in the addons you run. Open it again on the Modules
  page, What's new.
- Guildmates: the Modules page shows who in the guild runs the suite, which version and modules, and when each was
  last heard.
- /gsync versions now works for everyone.
- One search box at the top of the GuildSync window finds guildmates, alts, guild log lines, your professions and
  modules.

### People

- The Roster card and hovers show a member's Annals title and points, when Annals is on.

### Annals

- Annals gives People's card each member's title and the points the whole guild can see.
- New achievements for your own track: A Coin for the Company and A Purse for the Company (hold 100 and 1,000 gold)
  and Every Capital.
- A new secret achievement in Odd Jobs.
- Opening a card near the bottom scrolls it into view.
- Achievements draw faster: "Also in the guild" is built only for the card you open.

### Kill on Sight

- A list dated more than 15 minutes ahead is refused; the import line says whether it goes to the guild.
- /kos reset (officers) clears the list so the next one is taken.
- One member can no longer flood sightings or offers: limits per sender, and real sightings stay visible.
- Names and places on the page and in chat drop hidden direction characters. The paste window imports on Enter and
  shows refusals.

### Raids

- The GuildSync search box finds upcoming raids by name, team, day or a signed-up character, and a click selects the
  raid.
- Each raid gets a Pulls tab: who was in the group at every boss pull, at some, and who signed up but never came (mark
  them in /recap).
- /gsraids pulls lists the last five boss pulls this character saw; pulls are kept up to 35 days on the character and
  never sent.
- A Ready tab on tonight's raid: at the ready check every raider's buffs (flask, elixirs, food, world buffs) and fire
  resistance in one table.
- Missing to raid chat fills the chat box with who is missing what; Ask again asks the raid once more. Nothing is sent
  in combat.
- Pulls: a raider who signed up on one character and came on another of their own counts as present, not a no-show.
- The Pulls tab shows a boss pull as soon as combat ends, without choosing the raid again.
- The Ready header says how many answers came from names no longer on the raid roster.

### Bank

- A new Gold tab shows the bank's gold: each bank character, the guild bank, and recent gold in and out.
- Gold sent by mail names the guild member when the game lets the addon read it.
- Bank characters set a minimum per item, and Contents shows what is running low and a Raid night list.
- The Post requisition button fills in a requisition for the amount that is short.
- The search box at the top of the GuildSync window finds bank items by name, with how many and who holds them, and
  open requisitions.

### Notice Board

- Officers' notices and polls now reach every guildmate with the addon.
- Votes reach everyone and keep counting after the voter logs off.
- Officers can post officers-only notices that only officers receive.
- In demo anyone sees the officer view of the forms. Nothing is sent or saved.
- Notices and polls refuse the pipe character and tabs.
- The board saved by 0.2 is cleared once on first load.
- The GuildSync search box finds guild events, notices and polls. Officers-only notices show only to officers.
- Events in the search box also match their type and day, like dungeon, wed or tomorrow.

### Crafting

- A new Cooldowns tab shows whose transmutes, Mooncloth and Salt Shaker are ready, and when the others will be.
- Your own cooldowns are read out of combat and kept for every character on your account, so an alt shows after you
  log out.
- The GuildSync search box finds crafters and recipes, with whose cooldown is ready, and a click opens them on the
  Crafting page.
- Crafting now needs GuildSync 0.14.0 or later.

### Games

- New module Games: small games in the GuildSync window. Grain, its play money, is never gold and is never traded.
- WoWdle: a WoW word of 5 or 6 letters a day, the same for the whole guild, in six tries. Share fills the guild chat
  box with your grid.
- WoWdle keeps your stats and streak and shows today's results from the guild. Practice plays random WoW words that
  are not shared.
- Harvest: your field grows grain while you are logged in, AFK too. Spend it on a Ghoul farmhand, Sharper scythes and
  a Plague-proof granary.
- Harvest sends trade caravans for 1 to 8 hours: they come back with more grain, or Defias bandits take some, also
  while you are logged out.
- Kodo races: a race every full hour. Bet 5 to 200 grain on one of six kodos until the start, watch it run, and watch
  missed races again.
- Vendor price: pick which of two items sells to a vendor for more. Ten pairs a day for the whole guild pay grain;
  Endless runs to the first miss.
- Company: a cosmetic store (titles, name colours, badges, field decorations), the guild's granary projects and a
  weekly grain lottery.
- Guild boards show harvests, race winners, scores and streaks, never the WoWdle letters or the Vendor price items.
- A guildmate's Games results come only from that guildmate: their row shows once you were online together after they
  last changed it.
- Results that cannot be true are left out, and officers can hide a player from every Games board, the granary and the
  lottery.
- An officer draws the weekly lottery on Sunday evening, so everyone sees one winner. Until then the tab says the draw
  waits for an officer.
- On a flight path Games offers the game you played last, once per flight. Turn it off with Ask on flights.
- Before 4 November the days are previews; grain and boards start fresh at launch. /gsync demo shows every tab with a
  made-up guild.
- Kodo races: Skip to result on a replay; the finished race shows places (1st to 6th); a greyed Bet on says when bets
  open.
- Harvest: a greyed Buy rank says how much grain it needs.
- The flight prompt says when the next race's bets open instead of saying it takes bets too early.
- Vendor price: a full Today in the guild list ends with "and N more".
- WoWdle: when a day carries over, "next word in" counts to that day's end.
- Company: a green line after Hide and Unhide, and tooltips on the pager and on cut names.
- Company: group buttons that fit at 760 x 480, and your paid lottery win shown at the smallest size.
- Kodo races run on the whole explored Barrens map: six numbered kodos follow the Gold Road north from Thousand
  Needles past Camp Taurajo and the Crossroads.
- Your kodo is framed in gold. At the default window size the race view leaves out the Last race and Biggest wins
  boards; a taller window brings them back.

## 0.13.0

- Andorhal Grain Company is now one download that holds GuildSync, People, Annals, Kill on Sight, Raids, Bank,
  Notice Board and Crafting.
- GuildSync must stay on. You can switch any other module off in the AddOns list on the character screen.
- Type /gsync selftest about a minute after login to check that everything works.
