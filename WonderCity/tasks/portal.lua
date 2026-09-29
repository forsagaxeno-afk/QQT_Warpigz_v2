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
-- QQT_Warpigz_v3 (C6): a PortalSwitch or warp pad Batmobile rejects
-- (set_target()==false) or that we get no PROGRESS_STEP m closer to in
-- NO_PROGRESS_SECONDS is set aside while the explorer moves on, then tried
-- again. It is the floor's only way down, so it is never dropped for the
-- rest of the floor (live: "failed to leave floor 1"): Batmobile rejects any
-- goal within 15-25 m of a path it just failed for 15 s, and a fight or a
-- detour around a wall easily costs 12 s without getting 1 m closer; the
-- old floor-long skip turned either into a floor that could not be left.
-- The pause grows per attempt: SKIP_BASE, 2x, ... up to SKIP_MAX seconds.
local NO_PROGRESS_SECONDS, PROGRESS_STEP = 12, 1
local SKIP_BASE, SKIP_MAX = 20, 60
local skip = {generation = nil, keys = {}}
local approach = {key = nil, best = nil, time = nil, last = nil}
local PROGRESS_GAP = 2 -- a longer gap (another task ran) starts a fresh window
-- QQT_Warpigz_v3 WonderCity 2.2.7 (W2, sweep S3 F1/F2): a warp pad whose
-- PortalSwitch (within PAD_SWITCH_RANGE m) is locked (Grand Beacon floor)
-- no longer pulls the player back to it (pad <-> explorer thrash). The
-- floor exit seen within check_distance is remembered per floor (skip.exit)
-- and, once it is open again (the switch reads interactable, or out of view
-- a Grand Beacon of this floor was lit) and no enticement is in reach, the
-- player walks back to it instead of wandering until it passes by again.
local PAD_SWITCH_RANGE = 4
local function floor_skip()
    if skip.generation ~= tracker.floor_generation then
        skip.generation, skip.keys, skip.exit = tracker.floor_generation, {}, nil
    end
    return skip
end
local function target_key(actor)
    if actor.get_position == nil then -- a remembered exit position (W2)
        return tostring(tracker.floor_generation) .. '|exit:' .. string.format('%.0f:%.0f', actor:x(), actor:y())
    end
    local pos = actor:get_position()
    return tostring(tracker.floor_generation) .. '|' .. tostring(actor:get_skin_name()) .. ':'
        .. string.format('%.0f:%.0f', pos:x(), pos:y())
end
local function is_skipped(actor)
    local entry = floor_skip().keys[target_key(actor)]
    return entry ~= nil and get_time_since_inject() < entry.until_t
end
-- QQT_Warpigz_v3: set the target aside for a growing pause (see SKIP_BASE).
local function set_aside(key)
    local entry = skip.keys[key] or {count = 0}
    entry.count = entry.count + 1
    local pause = math.min(SKIP_BASE * 2 ^ (entry.count - 1), SKIP_MAX)
    entry.until_t = get_time_since_inject() + pause
    skip.keys[key] = entry
    return pause, entry.count
end
-- QQT_Warpigz_v3 WonderCity 2.2.7 (W2): the PortalSwitch next to a pad.
local function pad_switch(pad, actors)
    local pp = pad:get_position()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == 'X1_Undercity_PortalSwitch'
            and utils.distance(pp, actor) <= PAD_SWITCH_RANGE then
            return actor
        end
    end
    return nil
end
local function remember_exit(actor, open, dist)
    if dist > settings.check_distance then return end
    local state = floor_skip()
    state.exit = state.exit or {}
    state.exit.pos, state.exit.open = actor:get_position(), open
end
local get_portal = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local range = settings.rush_boss_portal and RUSH_PORTAL_RANGE or settings.check_distance
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        if actor_name == 'X1_Undercity_PortalSwitch' then
            local open = actor:is_interactable() == true
            local dist = utils.distance(local_player, actor)
            remember_exit(actor, open, dist) -- QQT_Warpigz_v3 WonderCity 2.2.7 (W2)
            if open and not is_skipped(actor) and dist <= range then
                if settings.rush_boss_portal and dist > settings.check_distance
                    and rush_logged_run ~= tracker.undercity_start_time then
                    rush_logged_run = tracker.undercity_start_time
                    console.print(string.format('[WonderCity:portal] portal open %.0fm away - taking it (Take the boss portal as soon as it opens)', dist))
                end
                return actor
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
                -- QQT_Warpigz_v3 WonderCity 2.2.7 (W2): a pad whose switch is
                -- locked (Grand Beacon not lit yet) is not a way down now, and
                -- pad and switch are set aside as a pair (harness B7: the pad
                -- alone pulled the player back to a switch set aside, 104
                -- portal <-> explorer switches in 15 s).
                local switch = pad_switch(actor, actors)
                local open = switch == nil or (switch:is_interactable() == true and not is_skipped(switch))
                if switch == nil then remember_exit(actor, nil, dist) end
                if open then return actor end
            end
        end
    end
    return nil
end
-- QQT_Warpigz_v3 WonderCity 2.2.7 (W2): a Grand Beacon of this floor lit.
local function beacon_lit()
    local prefix = tostring(tracker.floor_generation) .. '|X1_Undercity_Enticements_SpiritBeaconSwitch'
    for key, state in pairs(tracker.enticement) do
        if state == true and type(key) == 'string' and key:sub(1, #prefix) == prefix then return true end
    end
    return false
end
-- The remembered floor exit to walk back to (a position), or nil.
local function exit_recall()
    local state = floor_skip()
    local exit = state.exit
    if exit == nil then return nil end
    local player = get_local_player()
    if not player or utils.distance(player, exit.pos) <= settings.check_distance then return nil end
    local visible = nil
    for _, actor in pairs(actors_manager:get_ally_actors()) do
        if actor:get_skin_name() == 'X1_Undercity_PortalSwitch' and utils.distance(exit.pos, actor) <= PAD_SWITCH_RANGE then
            visible = actor
            break
        end
    end
    local now = get_time_since_inject()
    for _, entry in pairs(state.keys) do
        if now < entry.until_t then return nil end -- the exit (pad/switch) is set aside: explore meanwhile
    end
    local open
    if visible then open = visible:is_interactable() == true
    else open = exit.open ~= false or beacon_lit() end
    if not open or utils.get_closest_enticement() ~= nil then return nil end
    if exit.logged ~= true then
        exit.logged = true
        console.print(string.format('[WonderCity:portal] floor exit open - walking back to it (%.0fm)',
            utils.distance(player, exit.pos)))
    end
    return exit.pos
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
        or exit_recall() ~= nil or -- QQT_Warpigz_v3 WonderCity 2.2.7 (W2)
        task.portal_found or
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
        else
            target = exit_recall() -- QQT_Warpigz_v3 WonderCity 2.2.7 (W2)
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
            local pause, attempt = set_aside(key) -- QQT_Warpigz_v3: never for the whole floor
            approach.key, approach.best, approach.time = nil, nil, nil
            console.print(string.format('[WonderCity:portal] %s unreachable (%s) - exploring for %ds before trying it again (attempt %d)',
                key, why, pause, attempt))
            utils.stop_movement()
            task.status = 'portal unreachable - exploring'
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