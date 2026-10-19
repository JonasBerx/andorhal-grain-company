-- GuildSyncBank reagent data: the fixed list of common reagents and materials item entry matches names against first
-- (bank/brief.md I20, memory #m37). Shape: { { id = itemId, name = "..." }, ... }.
-- Empty until the source of the item ids is settled (brief Open 6): no id is guessed.

local _, ns = ...
if not ns.M then return end

ns.REAGENTS = {}
