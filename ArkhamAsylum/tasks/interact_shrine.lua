local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to shrine',
    INTERACTING = 'interacting '
}
local task = {
    name = 'interact_shrine', -- change to your choice of task name
    status = status_enum['IDLE'],
}

local INTERACT_TIMEOUT = 5.0 -- seconds before a stuck shrine is blacklisted
local stuck_since = nil
local last_interact_time = nil
local active_key = nil
local skipped_shrines = {} -- key: "x,y" string of shrine position
-- QQT_Warpigz_v3 Arkham 2.1.3: bounded walk. An unreachable shrine (ledge,
-- other floor level, refused target) was walked to forever: the task ranks
-- above kill/explore, so the run was lost to the reset timeout. Mirrors
-- pickup_heart_of_stone's WALK_TIMEOUT, but counts only time without progress.
local WALK_NO_PROGRESS = 30.0  -- seconds without getting PROGRESS_DELTA closer
local PROGRESS_DELTA = 1.0
local MAX_TARGET_REFUSALS = 3  -- consecutive set_target == false
local MAX_Z_DELTA = 5          -- utils.distance is XY only; skip other levels
local walk = {best = nil, progress_at = nil, refusals = 0}
local function reset_walk()
    walk.best, walk.progress_at, walk.refusals = nil, nil, 0
end

local function shrine_key(actor)
    local pos = actor:get_position()
    return math.floor(pos:x() + 0.5) .. ',' .. math.floor(pos:y() + 0.5)
end

local get_closest_shrine = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local actors = actors_manager:get_ally_actors()
    local closest_shrine, closest_dist
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        -- QQT_Warpigz_v3 Arkham 2.1.3: BetrayersEyeSwitch needs is_interactable
        -- too (a used switch kept the task walking), and a shrine on another
        -- floor level (> MAX_Z_DELTA) is not a target.
        if name and (name:match('Shrine_DRLG') or name:match('BetrayersEyeSwitch'))
            and actor:is_interactable()
        then
            local ppos, spos = local_player:get_position(), actor:get_position()
            local z_ok = not (ppos and spos) or math.abs(ppos:z() - spos:z()) <= MAX_Z_DELTA
            if z_ok and not skipped_shrines[shrine_key(actor)] then
                local dist = utils.distance(local_player, actor)
                if dist < settings.check_distance and (closest_dist == nil or dist < closest_dist) then
                    closest_dist = dist
                    closest_shrine = actor
                end
            end
        end
    end
    return closest_shrine
end

task.shouldExecute = function ()
    if settings.speed_mode then return false end
    return settings.interact_shrine and
        get_closest_shrine() ~= nil and
        utils.player_in_pit()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local shrine = get_closest_shrine()
    if shrine ~= nil then
        local key = shrine_key(shrine)
        if active_key ~= key then
            stuck_since = nil
            last_interact_time = nil
            active_key = key
            reset_walk()
        end
        local dist = utils.distance(local_player, shrine)
        if dist > 2 then
            stuck_since = nil
            last_interact_time = nil
            local disable_spell = false
            if dist <= 4 then
                disable_spell = true
            end
            -- QQT_Warpigz_v3 Arkham 2.1.3: no-progress window and refused targets.
            local now = get_time_since_inject()
            if walk.best == nil or dist < walk.best - PROGRESS_DELTA then
                walk.best, walk.progress_at = dist, now
            elseif now - walk.progress_at > WALK_NO_PROGRESS then
                console.print('[interact_shrine] no progress toward shrine for ' .. WALK_NO_PROGRESS ..
                    's, blacklisting ' .. key)
                skipped_shrines[key] = true
                reset_walk()
                return
            end
            if BatmobilePlugin.set_target(plugin_label, shrine, disable_spell) == false then
                walk.refusals = walk.refusals + 1
                if walk.refusals >= MAX_TARGET_REFUSALS then
                    console.print('[interact_shrine] Batmobile refused the shrine target ' .. walk.refusals ..
                        ' times, blacklisting ' .. key)
                    skipped_shrines[key] = true
                    reset_walk()
                    return
                end
            else
                walk.refusals = 0
            end
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING']
        else
            walk.best, walk.progress_at = dist, get_time_since_inject() -- QQT_Warpigz_v3 Arkham 2.1.3
            utils.stop_movement()
            task.status = status_enum['WALKING']
            -- timeout: if shrine refuses to interact after INTERACT_TIMEOUT seconds, blacklist it
            if stuck_since == nil then
                stuck_since = get_time_since_inject()
            elseif get_time_since_inject() - stuck_since > INTERACT_TIMEOUT then
                local key = shrine_key(shrine)
                console.print('[interact_shrine] shrine stuck for ' .. INTERACT_TIMEOUT .. 's, blacklisting ' .. key)
                skipped_shrines[key] = true
                stuck_since = nil
                last_interact_time = nil
                return
            end
            local now = get_time_since_inject()
            if last_interact_time and now - last_interact_time < 1 then return end
            settings.orb_set_clear(false)
            interact_object(shrine)
            last_interact_time = now
        end
    else
        stuck_since = nil
        last_interact_time = nil
        reset_walk() -- QQT_Warpigz_v3 Arkham 2.1.3
    end
end

task.reset = function ()
    active_key = nil
    stuck_since = nil
    last_interact_time = nil
    skipped_shrines = {}
    reset_walk() -- QQT_Warpigz_v3 Arkham 2.1.3
end

-- C5: time spent yielding to Alfred is not a stuck shrine interaction.
task.on_yield = function (seconds)
    if stuck_since then stuck_since = stuck_since + seconds end
    if walk.progress_at then walk.progress_at = walk.progress_at + seconds end -- QQT_Warpigz_v3 Arkham 2.1.3
end

return task
