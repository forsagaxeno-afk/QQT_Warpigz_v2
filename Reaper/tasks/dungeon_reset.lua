-- ============================================================
--  Reaper - tasks/dungeon_reset.lua
--
--  After every N completed runs (configurable), calls
--  reset_all_dungeons() then navigates back to the current
--  boss to start fresh.
--
--  Why: some dungeons accumulate temporary state or actors
--  over many runs. Periodic resets keep things clean.
-- ============================================================

local utils    = require "core.utils"
local settings = require "core.settings"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"
local enums = require "data.enums"

local STATE = {
    IDLE      = "IDLE",
    RESETTING = "RESETTING",
    WAITING   = "WAITING",
}

local state       = STATE.IDLE
local state_start = 0
-- RPR-11: the baseline is per session. run_once/enable/stop all call
-- reset_all(), so re-arming it there meant WarPigs one-shots never reached
-- the interval. main.lua runs a due reset in town before a run finishes.
local runs_at_last_reset = 0

local function now() return get_time_since_inject() end

local task = { name = "Dungeon Reset" }

function task.reset()
    state = STATE.IDLE
    state_start = 0
end

function task.shouldExecute()
    -- Feature disabled
    if not settings.dungeon_reset_enabled then return false end
    if settings.dungeon_reset_interval <= 0 then return false end

    if state ~= STATE.IDLE then return true end
    -- Never interrupt a live fight or unfinished chest sequence.
    if tracker.altar_activated or tracker.chest_opened_time then return false end

    -- Check if we've hit the interval
    local runs_since_reset = tracker.total_kills - runs_at_last_reset
    return runs_since_reset >= settings.dungeon_reset_interval
end

function task.Execute()
    local t = now()

    if state == STATE.IDLE then
        if enums.is_boss_zone(utils.get_zone()) then
            if not utils.loot_ready() then return end -- RPR-6: Looter first (bounded)
            teleport_to_waypoint(settings.town_waypoint)
            state = "LEAVING"
            state_start = t
            return
        end
        state       = STATE.RESETTING
        state_start = t
        console.print(string.format(
            "[Reaper] Dungeon reset triggered after %d runs.",
            tracker.total_kills - runs_at_last_reset
        ))
        reset_all_dungeons()
        runs_at_last_reset = tracker.total_kills
        return
    end

    if state == "LEAVING" then
        if utils.get_zone() == settings.town_zone then
            state = STATE.IDLE -- next pulse performs the reset outside the dungeon
        elseif t - state_start >= 20 then
            teleport_to_waypoint(settings.town_waypoint)
            state_start = t
        end
        return
    end

    if state == STATE.RESETTING then
        -- Give the API call a moment to process
        if (t - state_start) >= 2.0 then
            state       = STATE.WAITING
            state_start = t
            console.print("[Reaper] Dungeon reset complete. Resuming rotation.")
        end
        return
    end

    if state == STATE.WAITING then
        -- Brief pause before handing back to navigate_to_boss
        if (t - state_start) >= 1.0 then
            state = STATE.IDLE
        end
        return
    end
end

return task
