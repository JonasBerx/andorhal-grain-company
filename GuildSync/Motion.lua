-- GuildSync Motion.lua: ns.Kit.Motion (frozen API 10, M.Kit.Motion through Api.lua): FadeIn, FadeOut, Slide and Pop on
-- one AnimationGroup per frame per kind, built at first use and reused, and the hub's Animations setting.
-- Each answers true (playing), false (finished at once, or left untouched) or nil (not a frame); onFinish(frame) runs
-- exactly once whatever the answer (never for nil).
-- At once, with the end state: Animations off, combat (Compat.HoldForCombat), a protected frame, or a missing method or
-- a throw. A protected frame in combat is left untouched. Combat starting stops every running motion the same way.
-- Every path ends a run through close(run); no other code applies an end state.

local _, ns = ...

local Compat = ns.Compat

local MODULE = "Core" -- errors here are recorded as the hub's own
local FADE, SLIDE, POP = 0.2, 0.25, 0.15 -- seconds
local KINDS = { "FadeIn", "FadeOut", "Slide", "Pop" }
local POP_FROM = 0.85 -- Pop's starting scale (a Scale animation is transient: the frame's own scale never changes)

local current = setmetatable({}, { __mode = "k" }) -- current[group] = the run that group is playing, or nil
local cache = setmetatable({}, { __mode = "k" }) -- cache[frame][kind] = { group, anims }, built at first use
-- An onFinish that starts its own motion again must not loop without end: closing[frame] counts the onFinish calls
-- running on that frame (nested when motions finish at once), and a stop retries at most MAX_ROUNDS times. Past
-- either bound the run still gets its end state, but its onFinish is not run.
local closing = setmetatable({}, { __mode = "k" })
local MAX_DEPTH, MAX_ROUNDS = 5, 5

-- Rule 1: anything but a plain false is protected (nil, a secret, a throw); no IsProtected method reads as not.
local function protected(frame)
  if type(frame.IsProtected) ~= "function" then return false end
  local good, p = pcall(frame.IsProtected, frame)
  return not good or Compat.Plain(p) ~= false
end

local function endState(run)
  local f = run.frame
  if run.kind == "FadeIn" or run.kind == "Pop" then
    f:Show()
    f:SetAlpha(1)
  elseif run.kind == "FadeOut" then
    f:Hide()
    f:SetAlpha(1)
  end -- Slide: a Translation never moves the anchor, so nothing to set
end

-- Rule 2: the one close path. onFinish runs last, after the run is detached and done, so an onFinish that starts a new
-- motion on the same frame finds nothing to stop for this run (rules 3 and 4). A throw in onFinish is recorded, never
-- raised, so a stop loop or a new motion goes on.
local function close(run)
  if not run or run.done then return end
  run.done = true
  if not (protected(run.frame) and Compat.HoldForCombat()) then pcall(endState, run) end
  local f = run.frame
  if type(run.onFinish) == "function" and (closing[f] or 0) < MAX_DEPTH then
    closing[f] = (closing[f] or 0) + 1
    ns.Safe(MODULE, run.onFinish, f) -- never raises, so the count always comes back down
    closing[f] = closing[f] > 1 and closing[f] - 1 or nil
  end
end

-- Rules 4 and 5: detach first (an OnStop fired inside Stop finds no run), then stop, then close.
local function stop(group)
  local run = current[group]
  current[group] = nil
  pcall(group.Stop, group)
  close(run)
end

-- Stops what pick() answers until it answers nothing: an onFinish run by a stop may start a new motion, and that one
-- is stopped too.
local function stopWhile(pick)
  local rounds = 0
  local playing = pick()
  while #playing > 0 do
    rounds = rounds + 1
    for _, group in ipairs(playing) do
      local run = current[group]
      if run then
        if rounds > MAX_ROUNDS then run.onFinish = nil end -- a restarting onFinish ends here
        stop(group)
      end
    end
    playing = pick()
  end
end

local function closeCurrent(group)
  local run = current[group]
  current[group] = nil
  close(run)
end

local function anim(group, kind, duration, smoothing)
  local a = group:CreateAnimation(kind)
  a:SetDuration(duration)
  if type(a.SetSmoothing) ~= "function" then error("no SetSmoothing") end
  a:SetSmoothing(smoothing)
  return a
end

local BUILD = {
  FadeIn = function(g)
    local a = anim(g, "Alpha", FADE, "OUT")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    return { a }
  end,
  FadeOut = function(g)
    local a = anim(g, "Alpha", FADE, "IN")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    return { a }
  end,
  Slide = function(g) -- a jump to the offset, then the move back to the anchor; offsets are set at each start
    local jump = anim(g, "Translation", 0, "NONE")
    jump:SetOrder(1)
    local move = anim(g, "Translation", SLIDE, "OUT")
    move:SetOrder(2)
    return { jump, move }
  end,
  Pop = function(g)
    local a = anim(g, "Scale", POP, "OUT")
    a:SetOrigin("CENTER", 0, 0)
    a:SetScaleFrom(POP_FROM, POP_FROM)
    a:SetScaleTo(1, 1)
    return { a }
  end,
}

-- Rule 3: the group for frame and kind, built once; its scripts close the run current when they fire. A build that
-- fails stays failed (the entry is kept), so no later call makes another group.
local function groupFor(frame, kind)
  local byKind = cache[frame] or {}
  cache[frame] = byKind
  local entry = byKind[kind]
  if not entry then
    if type(frame.CreateAnimationGroup) ~= "function" then return nil end
    entry = { failed = true }
    byKind[kind] = entry
    local g = frame:CreateAnimationGroup()
    if type(g) ~= "table" or type(g.Play) ~= "function" or type(g.Stop) ~= "function" then return nil end
    entry.group, entry.anims = g, BUILD[kind](g) -- a throw leaves the entry failed
    g:SetScript("OnFinished", function() closeCurrent(g) end)
    g:SetScript("OnStop", function() closeCurrent(g) end)
    entry.failed = false
  end
  if not entry.failed then return entry end
end

-- Readies the frame for the play: shown for FadeIn and Pop; Slide's offsets for this call.
local function prepare(frame, kind, entry, dx, dy)
  if kind == "FadeIn" or kind == "Pop" then
    frame:Show()
  elseif kind == "Slide" then
    entry.anims[1]:SetOffset(dx, dy)
    entry.anims[2]:SetOffset(-dx, -dy)
  end
end

local function Enabled() return ns.DB().settings.animations ~= false end

-- Stops every motion running on frame; asHidden first turns each run into a FadeOut, so it ends hidden at alpha 1.
local function stopFrame(frame, asHidden)
  stopWhile(function()
    local playing, byKind = {}, cache[frame] or {}
    for _, kind in ipairs(KINDS) do
      local entry = byKind[kind]
      local run = entry and not entry.failed and current[entry.group]
      if run then
        if asHidden then run.kind = "FadeOut" end
        playing[#playing + 1] = entry.group
      end
    end
    return playing
  end)
end

local function start(frame, kind, onFinish, dx, dy)
  if type(frame) ~= "table" then return nil end
  stopFrame(frame)
  local run = { frame = frame, kind = kind, onFinish = onFinish, done = false }
  if not Enabled() or Compat.HoldForCombat() or protected(frame) then
    close(run) -- close leaves a protected frame in combat untouched
    return false
  end
  local good, entry = pcall(groupFor, frame, kind)
  if not good or not entry or not pcall(prepare, frame, kind, entry, tonumber(dx) or 0, tonumber(dy) or 0) then
    close(run)
    return false
  end
  current[entry.group] = run
  if not pcall(entry.group.Play, entry.group) then
    current[entry.group] = nil
    close(run)
    return false
  end
  return true
end

ns.Kit.Motion = {
  FadeIn = function(frame, onFinish) return start(frame, "FadeIn", onFinish) end,
  FadeOut = function(frame, onFinish) return start(frame, "FadeOut", onFinish) end,
  Slide = function(frame, dx, dy, onFinish) return start(frame, "Slide", onFinish, dx, dy) end, -- from (dx, dy) to its anchor
  Pop = function(frame, onFinish) return start(frame, "Pop", onFinish) end,
  Enabled = Enabled,
  SetEnabled = function(on) ns.DB().settings.animations = on and true or false end, -- hub-private (Window.lua)
  -- hub-private (Window.lua, Toast.lua): every motion on frame ends in its own end state; no other Show, Hide or SetAlpha
  Stop = function(frame)
    if type(frame) == "table" then stopFrame(frame) end
  end,
  -- hub-private: every motion on frame ends hidden at alpha 1, then the frame itself does too (a FadeIn the game
  -- stopped first may have re-shown it), except a protected frame in combat, which is left untouched
  Hide = function(frame)
    if type(frame) ~= "table" then return end
    stopFrame(frame, true)
    if not (protected(frame) and Compat.HoldForCombat()) then
      ns.Safe(MODULE, frame.Hide, frame) -- a throw is recorded under the hub, never dropped
      ns.Safe(MODULE, frame.SetAlpha, frame, 1)
    end
  end,
}

-- ---------- combat (own frame, as Toast.lua) ----------

local function onCombat()
  stopWhile(function()
    local playing = {}
    for group in pairs(current) do playing[#playing + 1] = group end
    return playing
  end)
end

local events = Compat.CreateFrame("Frame")
if events then
  pcall(events.RegisterEvent, events, "PLAYER_REGEN_DISABLED")
  events:SetScript("OnEvent", function(...) ns.Safe(MODULE, onCombat, ...) end)
end
