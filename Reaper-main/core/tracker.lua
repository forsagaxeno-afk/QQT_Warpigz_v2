-- ============================================================
--  Reaper - core/tracker.lua
-- ============================================================

local tracker = {
    -- timing
    start_time          = 0,
    finished_time       = 0,
    chest_opened_time   = nil,
    altar_activate_time = 0,   -- get_time_since_inject() when altar was activated
    -- Live 2.1.2 (Grigoire): time of our first altar click this run. From then
    -- on the summon belongs to interact_altar, never to navigation.
    altar_interact_time = nil,

    -- per-run flags
    altar_activated         = false,
    boss_killed             = false,
    chest_opened            = false,
    belial_chest_interacted = false,  -- set when the physical Belial chest is interacted with
    just_revived            = false,  -- set by revive task, cleared by navigate_to_boss

    -- session stats
    total_kills        = 0,
    current_boss_kills = 0,

    -- C5: seconds spent yielding to Alfred (monotonic, never reset). Chest
    -- timeouts subtract it so a companion yield cannot count as no progress.
    companion_yield    = 0,
}

function tracker.reset_run()
    tracker.altar_activated         = false
    tracker.altar_activate_time     = 0
    tracker.altar_interact_time     = nil
    tracker.boss_killed             = false
    tracker.chest_opened            = false
    tracker.belial_chest_interacted = false
    tracker.just_revived            = false
    tracker.start_time              = 0
    tracker.finished_time           = 0
    tracker.chest_opened_time       = nil
end

function tracker.check_time(key, delay)
    local t = get_time_since_inject()
    if not tracker[key] then tracker[key] = t end
    return (t - tracker[key]) >= delay
end

function tracker.clear_key(key)
    tracker[key] = nil
end

return tracker
