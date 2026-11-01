-- GuildSyncGames WhoSound.lua (S22 Task 3): the only file that calls the client's sound and CVar functions, every call
-- through M.Compat (names in Module.lua's apis.optional; q1781).
-- Play order (o2205): the global PlaySound on the Dialog channel first; C_Sound.PlaySound(kit), the kit only, only when
-- the global is missing or threw (M.Compat.Try answering ok false). A global that ran and answered falsy never falls
-- back. Replay waits (o2208): one handle in memory, held while C_Sound.IsPlaying(handle) or until
-- SOUNDKIT_FINISHED(handle); with no handle (a play that returned none) forceNoDuplicates is the only guard.
-- The sound settings (gate A item 4): Sound_EnableAllSound plus the channel in use, Sound_EnableDialog with the global,
-- FALLBACK_CVAR with C_Sound; read through C_CVar.GetCVarBool (the global is not in the dump), only out of combat, literal
-- names only; an unknown answer fails open (o2210).
-- Reasons cross as codes ("no sound", "in combat", "sound off", "still playing"); Who.lua turns them into sentences.

local _, ns = ...

if not ns.M then return end
local M = ns.M

-- The enable CVar of the slider the C_Sound fallback plays on; set from the probe (Task 9, gate A item 4).
local FALLBACK_CVAR = "Sound_EnableSFX"

local handle -- the last play's sound handle, nil when none is held

local function has(path) return GuildSync.Compat.Has(path) end

-- Fails closed: anything but a plain false (missing, nil, a secret) counts as combat (S-f2).
local function inCombat() return M.Compat.call("InCombatLockdown") ~= false end

-- The shipped switch on, and a play call the client has.
function ns.WhoAvailable()
  local WC = ns.WhoCore
  if type(WC) ~= "table" or WC.ENABLED ~= true then return false end
  return has("PlaySound") or has("C_Sound.PlaySound")
end

-- on, why: false only when a read answers false; GetCVarBool missing or answering nil is on.
function ns.WhoSoundOn()
  if inCombat() then return false, "in combat" end
  if M.Compat.call("C_CVar.GetCVarBool", "Sound_EnableAllSound") == false then return false, "sound off" end
  if has("PlaySound") then
    if M.Compat.call("C_CVar.GetCVarBool", "Sound_EnableDialog") == false then return false, "sound off" end
  elseif M.Compat.call("C_CVar.GetCVarBool", FALLBACK_CVAR) == false then
    return false, "sound off"
  end
  return true
end

function ns.WhoPlaying()
  if handle == nil then return false end
  local ran, playing = M.Compat.Try("C_Sound.IsPlaying", handle)
  if not ran then return true end -- no IsPlaying: held until SOUNDKIT_FINISHED
  if playing ~= true then handle = nil end
  return playing == true
end

function ns.WhoPlay(kit)
  if not ns.WhoAvailable() then return nil, "no sound" end
  if M.Demo() then return nil, "demo" end -- S-f1: demo plays nothing
  local on, why = ns.WhoSoundOn()
  if not on then return nil, why end
  if ns.WhoPlaying() then return false, "still playing" end
  local ran, success, h = M.Compat.Try("PlaySound", kit, "Dialog", true, true)
  if not ran then
    ran, success, h = M.Compat.Try("C_Sound.PlaySound", kit)
    -- R-f2: the fallback asks for no finish event, so without IsPlaying its handle would never clear
    if not has("C_Sound.IsPlaying") then h = nil end
  end
  if not ran or not success then return success, "no sound" end
  handle = h
  return true
end

function ns.OnWhoEvent(event, h)
  if event == "SOUNDKIT_FINISHED" and handle ~= nil and h == handle then
    handle = nil
    -- A-f8: redraw so "Playing..." goes; ns.WhoTab looked up now, its Refresh draws only while the game is shown
    if ns.WhoTab then M.Safe(ns.WhoTab.Refresh) end
  end
end
