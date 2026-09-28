local plugin_label = 'wonder_city' -- change to your plugin name

local utils    = require 'core.utils'
local settings = require 'core.settings'

local status_enum = {
    IDLE = 'idle',
    TELEPORTING = 'teleporting',
    WAITING = 'waiting '
}
local task = {
    name = 'teleport_kurast', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = -1,
    -- Live report: "TPs to the entrance 5 times in a row". The channel plus
    -- the loading screen outlast 3 s, so a retry fired after the cast ended
    -- but before the zone changed and restarted the trip. 8 s covers both
    -- (the suite's other waypoint debounces use 6-8 s).
    debounce_timeout = 8
}
-- QQT_Warpigz_v3 WonderCity 2.2.6: casts are counted per trip. A channel cut
-- by a hit or a pickup used to re-cast every 8 s forever and silently; now
-- each cast is logged and after MAX_CASTS undelivered casts it backs off.
task.max_casts = 4
task.backoff_timeout = 60
task.casts = 0
task.backoff_until = nil
local function log(msg) console.print('[' .. plugin_label .. ' ' .. task.name .. '] ' .. msg) end
local function teleport_with_debounce()
    local local_player = get_local_player()
    if not local_player then return end
    if local_player:get_active_spell_id() == 186139 then
        task.status = status_enum['TELEPORTING']
        return
    end
    local now = get_time_since_inject()
    -- QQT_Warpigz_v3 WonderCity 2.2.6: the old Limbo/Loading guard sat after
    -- the debounce and was unreachable (main.lua/task_manager return first);
    -- kept as a plain no-cast guard ahead of any counting.
    local world = get_current_world()
    local world_name = world and world:get_name()
    if type(world_name) ~= 'string' or world_name:find('Limbo', 1, true) or world_name:find('Loading', 1, true) then
        task.status = status_enum['WAITING'] .. 'for the loading screen'
        return
    end
    if task.backoff_until then
        if now < task.backoff_until then
            task.status = status_enum['WAITING'] .. string.format('%.2f', task.backoff_until - now) .. 's (back-off)'
            return
        end
        task.backoff_until = nil
        task.casts = 0
    end
    task.status = status_enum['WAITING'] ..
        string.format('%.2f', task.debounce_time + task.debounce_timeout - now) .. 's'
    if task.debounce_time + task.debounce_timeout > now then return end
    if task.casts >= task.max_casts then
        task.backoff_until = now + task.backoff_timeout
        log(string.format('%d casts to %s did not arrive — backing off %d s', task.casts,
            tostring(settings.town_zone), task.backoff_timeout))
        return
    end
    task.casts = task.casts + 1
    task.debounce_time = now
    log(string.format('cast %d to %s from %s', task.casts, tostring(settings.town_zone),
        tostring(world and world:get_current_zone_name())))
    utils.stop_movement()
    teleport_to_waypoint(settings.town_waypoint)
    task.status = status_enum['TELEPORTING']
    BatmobilePlugin.reset(plugin_label)
end
local function clear_trip()
    task.debounce_time = -math.huge
    task.casts = 0
    task.backoff_until = nil
end
task.shouldExecute = function ()
    -- QQT_Warpigz_v3 WonderCity 2.2.6: arriving in town ends the trip.
    if task.casts > 0 and utils.player_in_zone(settings.town_zone) then clear_trip() end
    return not utils.player_in_zone(settings.town_zone) and
        not utils.player_in_zone('[sno none]') and
        not utils.player_in_undercity()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    -- QQT_Warpigz_v3: never stop SilentRaven's walk or teleport out of Temis
    -- while it claims a Whisper reward.
    if (utils.raven_claim_active and utils.raven_claim_active()) then task.status = status_enum['WAITING'] .. 'for SilentRaven'; return end
    teleport_with_debounce()
end

-- QQT_Warpigz_v3 WonderCity 2.2.6: task_manager calls reset(transition) on
-- every tracker world key change. An 'outside' key seen mid-trip (an
-- intermediate world/zone before town) must not wipe the debounce or the
-- count, or the next 50 ms pulse casts again. Town arrival, Undercity
-- transitions and a bare reset() still clear everything.
task.reset = function (transition)
    if transition == 'outside' and not utils.player_in_zone(settings.town_zone) then return end
    clear_trip()
end

return task