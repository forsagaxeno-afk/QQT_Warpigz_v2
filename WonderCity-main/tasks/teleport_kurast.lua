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
local function teleport_with_debounce()
    local local_player = get_local_player()
    if not local_player then return end
    if local_player:get_active_spell_id() == 186139 then
        task.status = status_enum['TELEPORTING']
        return
    else
        task.status = status_enum['WAITING'] ..
        string.format('%.2f', task.debounce_time + task.debounce_timeout - get_time_since_inject()) .. 's'
    end
    if task.debounce_time + task.debounce_timeout > get_time_since_inject() then return end
    -- A loading screen after the cast is the trip still arriving.
    local world = get_current_world()
    local world_name = world and world:get_name()
    if type(world_name) ~= 'string' or world_name:find('Limbo', 1, true) or world_name:find('Loading', 1, true) then
        task.debounce_time = get_time_since_inject()
        return
    end
    task.debounce_time = get_time_since_inject()
    utils.stop_movement()
    teleport_to_waypoint(settings.town_waypoint)
    task.status = status_enum['TELEPORTING']
    BatmobilePlugin.reset(plugin_label)
end
task.shouldExecute = function ()
    return not utils.player_in_zone(settings.town_zone) and
        not utils.player_in_zone('[sno none]') and
        not utils.player_in_undercity()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    teleport_with_debounce()
end

task.reset = function () task.debounce_time = -math.huge end

return task