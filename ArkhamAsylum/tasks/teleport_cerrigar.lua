local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require 'core.utils'
local settings = require 'core.settings'

local status_enum = {
    IDLE = 'idle',
    TELEPORTING = 'teleporting',
    WAITING = 'waiting '
}
local task = {
    name = 'teleport_cerrigar', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = -1,
    -- QQT_Warpigz_v3 Arkham 2.1.3: 3 s re-cast in the gap between the end of
    -- the channel and the loading screen (WonderCity 2.1.1 "5 teleports in a
    -- row"). 8 s covers channel plus loading, as teleport_kurast.
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
    -- QQT_Warpigz_v3 Arkham 2.1.3: a loading screen after the cast is the trip
    -- still arriving (ported from WonderCity teleport_kurast); every loading
    -- pulse re-arms the debounce, so no cast lands right after it ends.
    local world = get_current_world()
    local world_name = world and world:get_name()
    if type(world_name) ~= 'string' or world_name:find('Limbo', 1, true) or world_name:find('Loading', 1, true) then
        task.debounce_time = get_time_since_inject()
        return
    end
    if task.debounce_time + task.debounce_timeout > get_time_since_inject() then return end
    task.debounce_time = get_time_since_inject()
    utils.stop_movement()
    teleport_to_waypoint(settings.town_waypoint)
    task.status = status_enum['TELEPORTING']
    BatmobilePlugin.reset(plugin_label)
end
task.shouldExecute = function ()
    return not utils.player_in_zone(settings.town_zone) and
        not utils.player_in_pit() and
        not utils.player_in_zone('[sno none]')
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

task.reset = function ()
    task.debounce_time = -math.huge
end

return task