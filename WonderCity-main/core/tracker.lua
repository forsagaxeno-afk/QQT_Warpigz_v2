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
    -- Last time/position the reward chest was in the actor list (CRT-1).
    chest_last_seen = nil,
    chest_last_pos = nil,
    chest_gone_since = nil,
    chest_gone_checked = nil,
    -- R14 evidence that a never-clicked, non-interactable reward chest was
    -- opened already (kept on a resume): when the chest was first seen, our
    -- own interaction, a burst of new loot next to it, a boss kill observed
    -- as an alive -> dead transition, and the last boss seen (diagnostics).
    chest_first_seen = nil,
    chest_interacted = nil,
    chest_loot_seen = nil,
    chest_loot_checked = nil,
    chest_items_base = nil,
    chest_loot_recent = nil,
    boss_kill_seen = nil,
    boss_alive_at = nil,
    last_boss_name = nil,
    last_boss_health = nil,
    last_boss_at = nil,
    world_key = nil,
    in_undercity = false,
    floor_generation = 0,
    -- CRT-1/L9: world key of the Undercity we left during an Alfred trip
    -- (without exit_undercity having started). Coming back to that same
    -- world within RESUME_WINDOW is a 'resume': run deadline, enticements
    -- and reward state (an opened chest) are kept. A new entry (Open Portal
    -- click) forgets it, so a fresh instance is never mistaken for it.
    resume_key = nil,
    resume_until = nil,
}
local RESUME_WINDOW = 300

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
    tracker.chest_last_seen = nil
    tracker.chest_last_pos = nil
    tracker.chest_gone_since = nil
    tracker.chest_gone_checked = nil
    tracker.chest_first_seen = nil
    tracker.chest_interacted = nil
    tracker.chest_loot_seen = nil
    tracker.chest_loot_checked = nil
    tracker.chest_items_base = nil
    tracker.chest_loot_recent = nil
    tracker.boss_kill_seen, tracker.boss_alive_at = nil, nil
    tracker.last_boss_name, tracker.last_boss_health, tracker.last_boss_at = nil, nil, nil
end

tracker.forget_resume = function ()
    tracker.resume_key, tracker.resume_until = nil, nil
end

-- alfred_trip: an Alfred trip is in flight (own request or Alfred busy).
tracker.observe_world = function (alfred_trip)
    local world = get_current_world()
    if not world then return nil end
    local name, zone = world:get_name(), world:get_current_zone_name()
    if type(name) ~= 'string' or name == ''
        or name:find('Limbo', 1, true) or name:find('Loading', 1, true)
        or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
    then return nil end
    local key = name .. ':' .. tostring(world.get_world_id and world:get_world_id() or '') .. ':' .. zone
    if tracker.world_key == key then return nil end
    local now = get_time_since_inject()
    local inside = zone:match('X1_Undercity_') ~= nil
    local kind = inside and (tracker.in_undercity and 'floor' or 'run') or 'outside'
    if kind == 'run' and tracker.resume_key == key and tracker.resume_until and now < tracker.resume_until then
        kind = 'resume'
    end
    local left = tracker.in_undercity and not inside and tracker.world_key or nil
    tracker.world_key = key
    tracker.in_undercity = inside
    if kind == 'outside' then
        if left and alfred_trip and tracker.exit_trigger_time == nil then
            tracker.resume_key, tracker.resume_until = left, now + RESUME_WINDOW
            console.print('[WonderCity:tracker] left ' .. left .. ' for an Alfred trip — the run resumes on return')
        end
        -- Floor state belongs to the Undercity we may still come back to.
        if tracker.resume_key ~= nil then return kind end
    end
    if inside then tracker.forget_resume() end
    if kind == 'resume' then
        -- Same Undercity world: keep the deadline, enticements and reward
        -- state; only the per-visit exit stamps start over.
        tracker.exit_trigger_time = nil
        tracker.exit_reset = false
        tracker.loot_quiet_since = nil
        console.print('[WonderCity:tracker] back in ' .. key .. ' — resuming the run')
        return kind
    end
    tracker.floor_generation = tracker.floor_generation + 1
    tracker.reset_floor_state()
    if kind == 'run' then
        tracker.undercity_start_time = now
        tracker.enticement = {}
    end
    return kind
end

return tracker
