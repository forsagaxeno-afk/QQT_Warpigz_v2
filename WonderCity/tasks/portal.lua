local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXPLORING = 'exploring',
    RESETING = 'reseting explorer',
    INTERACTING = 'interacting with portal',
    WALKING = 'walking to portal'
}
local task = {
    name = 'portal', -- change to your choice of task name
    status = status_enum['IDLE'],
    portal_found = false,
    portal_exit = -1,
    last_interact_time = -math.huge
}
-- War Plan node "portal to the boss at max attunement": with
-- settings.rush_boss_portal the floor portal is taken from anywhere in view
-- (RUSH_PORTAL_RANGE), not only within check_distance. Logged once per run.
local RUSH_PORTAL_RANGE = 150
local rush_logged_run = nil
-- QQT_Warpigz_v3 (C6, loot_obols rule): a PortalSwitch or warp pad Batmobile
-- rejects (set_target()==false) or that we get no PROGRESS_STEP m closer to
-- in NO_PROGRESS_SECONDS is skipped for the rest of the floor.
local NO_PROGRESS_SECONDS, PROGRESS_STEP = 12, 1
local skip = {generation = nil, keys = {}}
local approach = {key = nil, best = nil, time = nil, last = nil}
local PROGRESS_GAP = 2 -- a longer gap (another task ran) starts a fresh window
local function target_key(actor)
    local pos = actor:get_position()
    return tostring(tracker.floor_generation) .. '|' .. tostring(actor:get_skin_name()) .. ':'
        .. string.format('%.0f:%.0f', pos:x(), pos:y())
end
local function is_skipped(actor)
    if skip.generation ~= tracker.floor_generation then
        skip.generation, skip.keys = tracker.floor_generation, {}
    end
    return skip.keys[target_key(actor)] == true
end
local get_portal = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local range = settings.rush_boss_portal and RUSH_PORTAL_RANGE or settings.check_distance
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        if actor:is_interactable() then
            local actor_name = actor:get_skin_name()
            if actor_name == 'X1_Undercity_PortalSwitch' and not is_skipped(actor) then
                local dist = utils.distance(local_player, actor)
                if dist <= range then
                    if settings.rush_boss_portal and dist > settings.check_distance
                        and rush_logged_run ~= tracker.undercity_start_time then
                        rush_logged_run = tracker.undercity_start_time
                        console.print(string.format('[WonderCity:portal] portal open %.0fm away - taking it (Take the boss portal as soon as it opens)', dist))
                    end
                    return actor
                end
            end
        end
    end
    return nil
end
local get_portal_warp_pad = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        if actor_name == 'X1_Undercity_WarpPad' and not is_skipped(actor) then
            local dist = utils.distance(local_player, actor)
            if dist <= settings.check_distance then
                return actor
            end
        end
    end
    return nil
end

local boss_room_scan_last_run = nil
local is_in_boss_room = function ()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == 'Healing_Well_Basic' then
            return true
        end
    end
    -- One-shot actor dump per undercity run so we can find the real healing well name
    if utils.player_in_undercity() and boss_room_scan_last_run ~= tracker.undercity_start_time then
        boss_room_scan_last_run = tracker.undercity_start_time
        local seen = {}
        for _, actor in pairs(actors_manager:get_all_actors()) do
            local name = actor:get_skin_name()
            if name and not seen[name] then
                seen[name] = true
                console.print('[WonderCity:portal] actor_scan | ' .. name)
            end
        end
    end
    return false
end

task.shouldExecute = function ()
    if not utils.player_in_undercity() or is_in_boss_room() then return false end
    return utils.player_in_undercity() and
        (get_portal() ~= nil or
        (get_portal_warp_pad() ~= nil and utils.distance(get_local_player(), get_portal_warp_pad()) > 2)
        or task.portal_found or
        task.portal_exit + 1 >= get_time_since_inject())
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    settings.orb_set_clear(true)
    local portal = get_portal()
    local warp_pad = get_portal_warp_pad()
    local target = portal
    if portal == nil then
        if task.portal_found then
            task.portal_found = false
            task.status = status_enum['RESETING']
            task.portal_exit = get_time_since_inject()
            BatmobilePlugin.reset(plugin_label)
            return
        elseif warp_pad ~= nil and utils.distance(local_player, warp_pad) > 2 then
            target = warp_pad
        end
    elseif utils.distance(local_player, portal) < 2 then
        task.portal_found = true
        utils.stop_movement()
        local now = get_time_since_inject()
        if now - task.last_interact_time < 1 then return end
        task.last_interact_time = now
        interact_object(portal)
        task.status = status_enum['INTERACTING']
        -- contact magoogle tool to ask follower to teleport?
        return
    end
    if target ~= nil then
        -- QQT_Warpigz_v3 (C6): bounded approach.
        local key, dist, now = target_key(target), utils.distance(local_player, target), get_time_since_inject()
        local why = nil
        if approach.last and now - approach.last > PROGRESS_GAP then approach.best = nil end
        approach.last = now
        if approach.key ~= key or approach.best == nil then
            approach.key, approach.best, approach.time = key, dist, now
        elseif dist < approach.best - PROGRESS_STEP then
            approach.best, approach.time = dist, now
        elseif now - approach.time >= NO_PROGRESS_SECONDS then
            why = string.format('no progress for %ds at %.0fm', NO_PROGRESS_SECONDS, dist)
        end
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.update(plugin_label)
        if why == nil and BatmobilePlugin.set_target(plugin_label, target) == false then
            why = 'Batmobile rejected the target'
        end
        if why ~= nil then
            skip.keys[key] = true
            approach.key, approach.best, approach.time = nil, nil, nil
            console.print('[WonderCity:portal] ' .. key .. ' unreachable (' .. why .. ') - skipping it on this floor')
            utils.stop_movement()
            task.status = 'portal unreachable - continuing'
            return
        end
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    end
end

-- C5: time spent yielding (Alfred, Looter) is not 'no progress' time.
task.on_yield = function (seconds)
    if approach.time then approach.time = approach.time + seconds end
end

task.reset = function ()
    approach.key, approach.best, approach.time = nil, nil, nil
    task.portal_found = false
    task.portal_exit = -1
    task.last_interact_time = -math.huge
    boss_room_scan_last_run = nil
end

return task