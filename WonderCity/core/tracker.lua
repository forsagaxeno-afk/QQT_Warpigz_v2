local plugin_label = 'wonder_city'
local events = require 'core.qqt_events' -- QQT_Warpigz_v3
local settings = require 'core.settings' -- QQT_Warpigz_v3 (undercity_end timeout)
-- kept plugin label instead of waiting for update_tracker to set it

local tracker = {
    name = plugin_label,
    undercity_start_time = get_time_since_inject(),
    exit_trigger_time = nil,
    -- QQT_Warpigz_v3 WonderCity 2.2.7: when exit_undercity last CAST the exit
    -- (teleport / reset). exit_trigger_time only starts the exit delay; a
    -- trip that starts inside that delay must still resume the run (W1).
    exit_cast_time = nil,
    exit_reset = false,
    boss_trigger_time = nil,
    boss_kill_time = nil,
    boss_alive = false,
    enticement = {},
    -- QQT_Warpigz_v3: Grand Beacons set aside after a failed walk
    -- (floor-qualified key -> {until_t, count}); see interact_enticement.
    beacon_aside = {},
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
-- QQT_Warpigz_v3: the explorers stay idle for a boss only while kill_monster's
-- scan saw a live (not skipped) is_boss() enemy within this many seconds.
-- boss_trigger_time (first sight) still drives boss_delay; it no longer
-- gates exploring by itself (a dead miniboss or a revive far from the boss
-- left the floor idle until reset_timeout).
local BOSS_GATE_SECONDS = 10
tracker.boss_seen_at = nil
tracker.note_boss_seen = function ()
    tracker.boss_seen_at = get_time_since_inject()
end
tracker.boss_gate_active = function ()
    return tracker.boss_seen_at ~= nil and get_time_since_inject() - tracker.boss_seen_at <= BOSS_GATE_SECONDS
end
-- QQT_Warpigz_v3: reward-phase state survives a script reload (tracker
-- state is module-local and resets on reload; the reward chest may be gone
-- by then). Kept in one shared global, keyed by the Undercity world.
local RUN_STATE_GLOBAL, RUN_STATE_MAX_AGE = 'WonderCity_run_state', 120
local RUN_STATE_FIELDS = {'undercity_start_time', 'reward_seen', 'done', 'chest_interacted', 'chest_last_pos',
    'completion_reason', 'reward_opened_time', 'chest_failed', 'chest_first_seen', 'kill_dismissed_at',
    'floor_generation', 'enticement'}
tracker.save_run_state = function ()
    if not tracker.in_undercity or tracker.world_key == nil then return end
    local state = rawget(_G, RUN_STATE_GLOBAL)
    if type(state) ~= 'table' then state = {}; rawset(_G, RUN_STATE_GLOBAL, state) end
    state.world_key, state.saved_at = tracker.world_key, get_time_since_inject()
    for _, field in ipairs(RUN_STATE_FIELDS) do state[field] = tracker[field] end
end
local function restore_run_state(key)
    local state = rawget(_G, RUN_STATE_GLOBAL)
    if type(state) ~= 'table' or state.world_key ~= key then return false end
    -- Only a reload moments ago (never a stale state of a recycled world id).
    if type(state.saved_at) ~= 'number' or get_time_since_inject() - state.saved_at > RUN_STATE_MAX_AGE then return false end
    for _, field in ipairs(RUN_STATE_FIELDS) do
        if state[field] ~= nil then tracker[field] = state[field] end
    end
    if type(tracker.enticement) ~= 'table' then tracker.enticement = {} end
    if type(tracker.floor_generation) ~= 'number' then tracker.floor_generation = 0 end
    -- A reward chest seen before the reload counts as seen now, so its
    -- disappearance completes the reward phase (bounded, CRT-1).
    if tracker.reward_seen and not tracker.done then tracker.chest_last_seen = get_time_since_inject() end
    return true
end

tracker.reset_floor_state = function ()
    tracker.exit_trigger_time = nil
    tracker.exit_cast_time = nil -- QQT_Warpigz_v3 WonderCity 2.2.7 (W1)
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
    tracker.kill_dismissed_at = nil
    tracker.last_boss_name, tracker.last_boss_health, tracker.last_boss_at = nil, nil, nil
    tracker.boss_seen_at = nil -- QQT_Warpigz_v3
    tracker.boss_last_pos = nil -- QQT_Warpigz_v3 WonderCity 2.2.7 (W4)
end

tracker.forget_resume = function ()
    tracker.resume_key, tracker.resume_until = nil, nil
end

-- QQT_Warpigz_v3: suite event for an Undercity run that is over (left for
-- good, not for an Alfred trip that resumes it).
tracker.emit_end = function (now)
    local secs = now - (tracker.undercity_start_time or now)
    local reason = tracker.done and (tracker.completion_reason or 'reward') or nil
    if not reason then
        local limit = settings.reset_timeout
        reason = (type(limit) == 'number' and secs >= limit) and 'timeout' or 'left'
    end
    local base = tracker.run_floor_base
    events.emit('wondercity', 'undercity_end', {success = tracker.done == true, reason = reason, secs = secs,
        floors = type(base) == 'number' and tracker.floor_generation - base or nil})
    tracker.run_floor_base = nil
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
    -- QQT_Warpigz_v3: first world seen after a script reload is the Undercity
    -- we were in: resume its run (deadline, reward state) instead of a fresh run.
    if tracker.world_key == nil and inside and restore_run_state(key) then
        tracker.world_key, tracker.in_undercity = key, true
        console.print('[WonderCity:tracker] reloaded inside ' .. key .. ' — resuming the run'
            .. (tracker.done and ' (reward already opened)' or (tracker.reward_seen and ' (reward chest seen)' or '')))
        return 'resume'
    end
    local kind = inside and (tracker.in_undercity and 'floor' or 'run') or 'outside'
    if kind == 'run' and tracker.resume_key == key and tracker.resume_until and now < tracker.resume_until then
        kind = 'resume'
    end
    local left = tracker.in_undercity and not inside and tracker.world_key or nil
    tracker.world_key = key
    tracker.in_undercity = inside
    if kind == 'outside' then
        -- QQT_Warpigz_v3 WonderCity 2.2.7 (W1): keyed on the exit CAST, not on
        -- the exit delay (a Rosie trip inside the 10 s delay made the return
        -- a new run: the opened chest forgotten, the instance re-explored).
        if left and alfred_trip and tracker.exit_cast_time == nil then
            tracker.resume_key, tracker.resume_until = left, now + RESUME_WINDOW
            console.print('[WonderCity:tracker] left ' .. left .. ' for an Alfred trip — the run resumes on return')
        end
        -- Floor state belongs to the Undercity we may still come back to.
        if tracker.resume_key ~= nil then return kind end
        rawset(_G, RUN_STATE_GLOBAL, nil) -- QQT_Warpigz_v3: the run is over
        if left then tracker.emit_end(now) end -- QQT_Warpigz_v3
    end
    if inside then tracker.forget_resume() end
    if kind == 'resume' then
        -- Same Undercity world: keep the deadline, enticements and reward
        -- state; only the per-visit exit stamps start over.
        tracker.exit_trigger_time = nil
        tracker.exit_cast_time = nil -- QQT_Warpigz_v3 WonderCity 2.2.7 (W1)
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
        tracker.beacon_aside = {} -- QQT_Warpigz_v3
        tracker.run_floor_base = tracker.floor_generation - 1 -- QQT_Warpigz_v3
        events.emit('wondercity', 'undercity_start', {}) -- QQT_Warpigz_v3
    end
    return kind
end

return tracker
