-- GuildSyncExpeditions StoryData.lua: the storyline "The Andorhal Ledger", ns.StoryData (slice S).
--   ns.StoryData[c] -> { name, region, ending, reward, steps }  6 chapters in order
--   reward: { grain, salvage = { tier, n }, title } or { chain = region }
--   steps[s] -> { title, text, place, giver, level, hours, danger, kind, gear = { code, ... } or nil (paid only on a step before a chapter's last) }, or { title, text, place, giver, capstone = true }
-- Pure data, no ns.M guard (like Words.lua). The words are Jonas's (d2112): change none of them here.
-- Levels, hours and danger: economy.md section 3. Rewards: section 8. Danger: 1 Safe, 2 Risky, 3 Dangerous.

local _, ns = ...

ns.StoryData = {
  { name = "Open for Business", region = "tirisfal",
    ending = [[That mill can be made to pay, so here are your wages. You can call yourself a Company hand now, for what that's worth.]],
    reward = { grain = 100, salvage = { tier = 1, n = 6 }, title = "company-hand" },
    steps = {
      { title = [[Stock the Tent]], place = "Brill", giver = "Anya", level = 1, hours = 4, danger = 1, kind = "Scout", gear = { "o1", "e1", "i1" },
        text = [[The Andorhal Grain Company has reopened at Brill, and so far that means one tent with a hole in it. I keep the gate and you keep the followers, so the errands are yours. Send someone round the abandoned farms for canvas and rope.]] },
      { title = [[Bad Debts]], place = "Solliden Farmstead", giver = "Anya", level = 2, hours = 4, danger = 1, kind = "Scout",
        text = [[Our last wagon is at Solliden, where the Scarlets have been hauling firewood in it. They took it off one of our drivers and haven't paid a copper since. Get our people over there and bring it home.]] },
      { title = [[Torn Pages]], place = "Brill", giver = "Anya", level = 2, hours = 8, danger = 1, kind = "Scout",
        text = [[The old ledger was still under the wagon seat. Every week is there except the one when the Cult got into the silos, and those pages have been torn out. The clerks kept a second set of books at Brill, so one of ours can go through what's left of them.]] },
      { title = [[The Nearest Mill]], place = "Agamand Mills", giver = "Anya", level = 3, hours = 8, danger = 2, kind = "Raid",
        text = [[No copy turned up, and that can wait. Nobody gets paid without flour. Agamand Mills is the nearest with its wheels still on, and I want someone up there counting what's broken and what's walking around in it.]] },
    } },
  { name = "The Agamand Will", region = "tirisfal",
    ending = [[Our people tell me Devlin's last words were 'Ask your gatekeeper who she let in.' The dead will say anything. Keep his blade, and with our banner on the Mills the camp will need more tents.]],
    reward = { chain = "tirisfal" },
    steps = {
      { title = [[Notice to Quit]], place = "Agamand Mills", giver = "Anya", level = 4, hours = 8, danger = 2, kind = "Raid",
        text = [[Our scout says the wheels still turn at Agamand Mills and the yard is full of ghouls. They've had the place rent free since the plague. Send our people to clear the yard. They can read the notice aloud first if it makes them feel better.]] },
      { title = [[The Missing Page]], place = "Agamand Mills", giver = "Anya", level = 5, hours = 8, danger = 2, kind = "Scout",
        text = [[With the yard clear, our people got into the mill office and found old Agamand's will. It says the mills were sold a week before the plague to Corvin Ashgrave, the Company's own factor. The page with the heir's name is gone. Have someone go through the house until it turns up.]] },
      { title = [[Next of Kin]], place = "Agamand Mills", giver = "Anya", level = 6, hours = 8, danger = 2, kind = "Scout",
        text = [[The page turned up under a floorboard. The heir is Devlin Agamand. Being dead is no bar to owning property. Being Scourge is. Someone needs to find out whether he still has a mind of his own.]] },
      { title = [[Under New Management]], place = "Agamand Mills", giver = "Anya", level = 7, hours = 24, danger = 3, kind = "Raid",
        text = [[Our people looked in on Devlin Agamand and came back a finger short. He's Scourge, so once he stops walking the mills have no owner. The family crypt is where he went to ground, with what's left of the household. Send our best to settle the estate.]] },
    } },
  { name = "Short Delivery", region = "silverpine",
    ending = [[You may as well hear it from me. The Cult came to the silo gate with forged papers under Ashgrave's seal, and I signed them in myself. I have watched the gate ever since.]],
    reward = { grain = 150, salvage = { tier = 2, n = 12 }, title = "road-warden" },
    steps = {
      { title = [[Short Delivery]], place = "The Sepulcher", giver = "Anya", level = 6, hours = 8, danger = 2, kind = "Scout",
        text = [[The first wagons of Agamand flour left for the Sepulcher last week. The Sepulcher has signed for nothing. Have our people walk the Silverpine road and find out where they stopped.]] },
      { title = [[Teeth Marks]], place = "The Sepulcher", giver = "Anya", level = 7, hours = 8, danger = 2, kind = "Scout",
        text = [[South of the Sepulcher our people found the wagons in a ditch, with the sides ripped off and the oxen eaten. The bite marks in the oak are a hand wide, which is a good deal bigger than any gnoll. Get someone on the tracks before it rains.]] },
      { title = [[Who Was Buying]], place = "Ambermill", giver = "Anya", level = 7, hours = 8, danger = 2, kind = "Scout",
        text = [[The tracks gave out in the hills. The sacks have done better, and are on sale at Ambermill with our stamp still on them. Send someone in quietly to learn who is buying.]] },
      { title = [[Gone Missing]], place = "Ambermill", giver = "Anya", level = 8, hours = 24, danger = 3, kind = "Raid",
        text = [[Nailed to the camp gate at Brill, in Anya's writing: "Gone down the Silverpine road to Ambermill. Someone else can watch the gate. Do not send anyone after me." Below it, one of the Company hands has added: "She took every arrow in camp and she went alone. Send someone to bring her back."]] },
    } },
  { name = "Arugal's Last Pupil", region = "silverpine",
    ending = [[His account is closed. Keep the fang off that worgen master, and tell the hands to put up the rest of the camp.]],
    reward = { chain = "silverpine" },
    steps = {
      { title = [[Arugal's Last Pupil]], place = "Ambermill", giver = "Anya", level = 8, hours = 8, danger = 2, kind = "Scout",
        text = [[You've heard it now and I won't say it twice. The buyer at Ambermill is an apprentice out of Dalaran, the last pupil Arugal had. One of ours can find out what a mage wants with all that flour.]] },
      { title = [[Feeding Time]], place = "Pyrewood Village", giver = "Anya", level = 8, hours = 8, danger = 2, kind = "Raid",
        text = [[That apprentice has been mixing plagued grain into the sacks and feeding it to the worgen at Pyrewood, to see what it does to them. He keeps notes. Have our people burn the troughs and bring me the notebook.]] },
      { title = [[The Torn Pages]], place = "Ambermill", giver = "Anya", level = 9, hours = 8, danger = 2, kind = "Scout",
        text = [[His notes say he bought the pages torn out of our ledger and paid for them in our own grain. I don't need to see those pages to know Ashgrave's name is on every one. They're locked up at Ambermill, so send someone to bring them here.]] },
      { title = [[Paid in Full]], place = "Pyrewood Village", giver = "Anya", level = 9, hours = 24, danger = 3, kind = "Raid",
        text = [[I've written out the apprentice's bill and it comes to two pages. He has run to Pyrewood and is hiding behind the master of the pack he's been feeding. Send our best to collect.]] },
    } },
  { name = "The Charter", region = "tirisfal",
    ending = [[He was here, and he ran to Arugal. The charter is signed. The Dark Lady says she keeps finding the throne room dirty, so our people will be going back.]],
    reward = { grain = 200, salvage = { tier = 2, n = 20 }, title = "charter-bearer" },
    steps = {
      { title = [[A Petition]], place = "Ruins of Lordaeron", giver = "Anya", level = 8, hours = 8, danger = 2, kind = "Raid",
        text = [[We can't sell a single sack in the Dark Lady's lands without her charter. I sent the petition and she sent back a list of conditions. The first is the Scourge in the courtyard at the Ruins of Lordaeron, so send someone who won't embarrass us.]] },
      { title = [[Unfinished Business]], place = "Ruins of Lordaeron", giver = "Anya", level = 8, hours = 8, danger = 2, kind = "Scout",
        text = [[According to the torn pages, Ashgrave came to Lordaeron to buy a pardon, the week it fell. They don't say who was selling. Our people know the way to the ruins by now, so have them go through what's left of the court offices.]] },
      { title = [[Below the Throne]], place = "Ruins of Lordaeron", giver = "Anya", level = 8, hours = 8, danger = 2, kind = "Scout",
        text = [[By the time he got there nobody was left to sign a pardon. His trail ends in the old palace cellars, below the throne room. Send someone down with a lantern and a sack for whatever he left behind.]] },
      { title = [[Ruins of Lordaeron (first clear)]], place = "Ruins of Lordaeron", giver = "Anya", capstone = true,
        text = [[There are stairs from the cellars up to the throne room, and something is still walking around at the top of them. The Dark Lady's last condition is that it stops. Whoever you send should look for any sign of Ashgrave on the way through.]] },
    } },
  { name = "The Last Entry", region = "silverpine",
    ending = [[Ashgrave is gone, and the last entry in his book says there is still grain in the silos at Andorhal. Get your boots. We're going home.]],
    reward = { grain = 225, salvage = { tier = 2, n = 30 }, title = "keeper-ledger" },
    steps = {
      { title = [[The Road South]], place = "Pyrewood Village", giver = "Anya", level = 10, hours = 8, danger = 2, kind = "Scout",
        text = [[Ashgrave reached Shadowfang Keep alive and Arugal took him in. Arugal doesn't take anyone in for free. Our people can ask around Pyrewood what it cost him.]] },
      { title = [[A Debt Collected]], place = "Pyrewood Village", giver = "Anya", level = 10, hours = 8, danger = 2, kind = "Raid",
        text = [[It cost him grain. He paid in Company sacks, cart after cart, and the last of them are stacked in a barn at Pyrewood with our stamp on them. Arugal has had enough of our grain, so have our people burn the barn.]] },
      { title = [[The Keep]], place = "Shadowfang Keep", giver = "Anya", level = 10, hours = 8, danger = 2, kind = "Scout",
        text = [[I've spent a long time looking at gates, and the front one at Shadowfang Keep is no use to anybody. The wolves have it. Have our people walk the walls until they find another way in.]] },
      { title = [[Shadowfang Keep (first clear)]], place = "Shadowfang Keep", giver = "Anya", capstone = true,
        text = [[The last of our books went into the keep with Ashgrave, and Arugal's worgen stand between us and the pair of them. Our people know the way in now. I want the man if he's still breathing and the book either way.]] },
    } },
}
