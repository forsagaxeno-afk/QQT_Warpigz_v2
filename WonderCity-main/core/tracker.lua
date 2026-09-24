local plugin_label = 'wonder_city'
-- kept plugin label instead of waiting for update_tracker to set it

local tracker = {
    name = plugin_label,
    undercity_start_time = get_time_since_inject(),
    exit_trigger_time = nil,
    exit_reset = false,
    boss_trigger_time = nil,
    boss_kill_time = nil,
    boss_alive = false,
    enticement = {},
    done = false,
    chest_failed = false,
    reward_seen = false,
    reward_opened_time = nil,
    loot_quiet_since = nil,
    completion_reason = nil,
    reward_grace_until = nil,
    world_key = nil,
    in_undercity = false,
    floor_generation = 0,
}

tracker.reset_floor_state = function ()
    tracker.exit_trigger_time = nil
    tracker.exit_reset = false
    tracker.boss_trigger_time = nil
    tracker.boss_kill_time = nil
    tracker.boss_alive = false
    tracker.done = false
    tracker.chest_failed = false
    tracker.reward_seen = false
    tracker.reward_opened_time = nil
    tracker.loot_quiet_since = nil
    tracker.completion_reason = nil
    tracker.reward_grace_until = nil
end

tracker.observe_world = function ()
    local world = get_current_world()
    if not world then return nil end
    local name, zone = world:get_name(), world:get_current_zone_name()
    if type(name) ~= 'string' or name == ''
        or name:find('Limbo', 1, true) or name:find('Loading', 1, true)
        or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
    then return nil end
    local key = name .. ':' .. tostring(world.get_world_id and world:get_world_id() or '') .. ':' .. zone
    if tracker.world_key == key then return nil end
    local inside = zone:match('X1_Undercity_') ~= nil
    local kind = inside and (tracker.in_undercity and 'floor' or 'run') or 'outside'
    tracker.world_key = key
    tracker.in_undercity = inside
    tracker.floor_generation = tracker.floor_generation + 1
    tracker.reset_floor_state()
    if kind == 'run' then
        tracker.undercity_start_time = get_time_since_inject()
        tracker.enticement = {}
    end
    return kind
end

return tracker
