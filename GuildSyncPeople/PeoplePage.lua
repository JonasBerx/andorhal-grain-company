-- GuildSyncPeople: the People page (run r-20261018-o696, plan Task 7; NOTES-o696.md "My profile (rp-6)").
-- The page is My profile only (PeopleProfile.lua: the profile and the "Your characters" card): no tabs, list, filter
-- or search; the guild's people are on the hub's Roster, whose member panel carries People's section.
-- Every ns.* function is looked up at call time (f10, crosscheck G4).

local _, ns = ...
if not ns.M then return end

local S = {}

function ns.BuildPage(frame)
  S.profile = ns.BuildProfile(frame)
  S.characters = ns.BuildCharacters(frame)
  S.profile.characters = S.characters -- the one Save sends the card's pick and hidden set too
  -- the hub runs refresh right after build
end

function ns.RefreshPage()
  if S.profile then S.profile:Refresh() end
  if S.characters then S.characters.Refresh() end
end
