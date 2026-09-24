local plugin_label = 'arkham_asylum'
-- kept plugin label instead of waiting for update_tracker to set it

local tracker = {
    name        = plugin_label,
    pit_start_time = get_time_since_inject(),
    world_key = nil,
    in_pit = false,
    generation = 0,
    exit_trigger_time = nil,
    glyph_done = false,
    glyph_trigger_time = nil,
    boss_kill_time = nil,
    boss_seen = false,
    -- Boss memory: vec3 of last known boss position. Survives player death so
    -- the bot can path back without exploring after revive.
    boss_position = nil,
    -- Set true after an observed dead boss or the glyphstone confirms a kill.
    boss_dead = false,
    -- Anchor we hold near after boss dies (boss death position, then snapped to
    -- the glyphstone once it spawns). explore_pit / kill_monster are gated by
    -- this so the bot can't wander away to chase trash.
    glyph_anchor_pos = nil,
}

tracker.reset_floor_state = function ()
    tracker.exit_trigger_time = nil
    tracker.glyph_trigger_time = nil
    tracker.glyph_done = false
    tracker.boss_kill_time = nil
    tracker.boss_seen = false
    tracker.boss_position = nil
    tracker.boss_dead = false
    tracker.glyph_anchor_pos = nil
end

tracker.reset_pit_state = function ()
    tracker.pit_start_time = get_time_since_inject()
    tracker.reset_floor_state()
end

-- Observe transitions before priority selection. Lower-priority task predicates
-- never run while town/reward tasks win, so they cannot own lifecycle cleanup.
tracker.observe_world = function ()
    local world = get_current_world()
    if not world then return nil end
    local name = world:get_name()
    local zone = world:get_current_zone_name()
    if type(name) ~= 'string' or name == ''
        or name:find('Limbo', 1, true) or name:find('Loading', 1, true)
        or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
    then return nil end
    local id = world.get_world_id and world:get_world_id() or ''
    local key = name .. ':' .. tostring(id)
    if key == tracker.world_key then return nil end
    local in_pit = name:match('^PIT_') ~= nil
    local kind = in_pit and (tracker.in_pit and 'floor' or 'run') or 'outside'
    tracker.world_key = key
    tracker.in_pit = in_pit
    tracker.generation = tracker.generation + 1
    if kind == 'run' then tracker.reset_pit_state()
    else tracker.reset_floor_state() end
    return kind
end

return tracker