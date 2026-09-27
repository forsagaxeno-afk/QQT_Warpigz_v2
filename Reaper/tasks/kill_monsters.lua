-- ============================================================
--  Reaper - tasks/kill_monsters.lua
--
--  Handles fighting — moves toward enemies and suppressor
--  orbs. When no enemy is in range, drifts back toward the
--  altar position so the orbwalker stays close to the boss.
-- ============================================================

local utils    = require "core.utils"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"
local settings = require "core.settings"
local enums    = require "data.enums"
local navigate_to_boss = require "tasks.navigate_to_boss"

local stuck_position = nil

-- QQT_Warpigz_v3: Kill Monsters is bounded. When no enemy, boss quest or
-- reward chest has been seen for NO_FIGHT_BOUND seconds after the summon,
-- the summon is dropped (altar_activated / summoned_this_run cleared) and the
-- altar is re-evaluated by interact_altar (re-summon, or its bounded wait).
-- A phantom summon used to idle Reaper here for the rest of the session.
local NO_FIGHT_BOUND = 75
local EVIDENCE_RANGE = 40
local fight = { seen_at = nil, mark = nil }

local function in_target_boss_zone()
    local boss = rotation.current()
    if not boss then return false end
    local zone = utils.get_zone()
    return utils.in_boss_zone(boss)
end

-- Returns the altar position if we can find it.
-- QQT_Warpigz_v3: otherwise the position where the altar was last seen or
-- clicked this run, then the recorded path endpoint / a non-zero seed
-- (navigate_to_boss.approach_target), else nil (no tether). The enums seed
-- alone pulled the player 12-19 m away from Andariel/Harbinger and to the
-- world origin for bosses without a seed (Butcher, Urivar).
local function get_anchor_position()
    local altar = utils.get_altar()
    if altar then
        local pos = altar:get_position()
        tracker.altar_pos = pos
        return pos
    end
    if tracker.altar_pos then return tracker.altar_pos end
    return navigate_to_boss.approach_target(rotation.current())
end

local function fight_evidence()
    if utils.boss_quest_active() then return true end
    local pp = get_player_position()
    if not pp then return true end -- unreadable is not "no fight"
    local ok, list = pcall(target_selector.get_near_target_list, pp, EVIDENCE_RANGE)
    if not ok or type(list) ~= "table" then return true end
    return next(list) ~= nil
end

-- Maximum distance from altar/anchor before pulling back toward it.
-- Keeps the player inside the boss arena instead of chasing enemies outward.
local ALTAR_TETHER = 15.0

local task = { name = "Kill Monsters" }

-- C4/RPR-10: a reset (stop, run_once, finishing) releases the movement block
-- but never forces the orbwalker clear toggle OFF: WarPigs forces clear ON at
-- the handoff and the next activity must not inherit clear OFF from Reaper.
function task.reset()
    settings.orb_set_block(false)
    fight.seen_at, fight.mark = nil, nil
end

function task.shouldExecute()
    if not in_target_boss_zone() then return false end
    if not tracker.altar_activated then return false end
    return true
end

function task.Execute()
    -- QQT_Warpigz_v3: bounded fight (see NO_FIGHT_BOUND).
    -- Counted from the first tick of this activation (altar_activate_time
    -- identifies it) or the last evidence, whichever is later.
    local t = get_time_since_inject()
    local mark = tracker.altar_activate_time or 0
    if fight.mark ~= mark or fight.seen_at == nil then fight.mark, fight.seen_at = mark, t end
    if fight_evidence() then
        fight.seen_at = t
    elseif t - fight.seen_at >= NO_FIGHT_BOUND then
        console.print(string.format(
            "[Reaper] No boss, enemies or reward chest for %ds after the summon — re-checking the altar.",
            NO_FIGHT_BOUND))
        tracker.altar_activated     = false
        tracker.altar_interact_time = nil
        tracker.summoned_this_run   = false
        fight.seen_at, fight.mark = nil, nil
        settings.orb_set_block(false)
        return
    end

    settings.orb_set_clear(true)
    settings.orb_set_block(true)

    -- Always chase suppressor orbs (need to burst them to unblock combat)
    local suppressor = utils.get_suppressor()
    if suppressor then
        pathfinder.force_move_raw(suppressor:get_position())
        return
    end

    -- Tether: if drifted too far from altar, walk back
    local anchor = get_anchor_position()
    if anchor and utils.distance_to(anchor) > ALTAR_TETHER then
        pathfinder.request_move(anchor)
        return
    end
    -- Otherwise stay put — orbwalker handles casting from current position
end

return task
