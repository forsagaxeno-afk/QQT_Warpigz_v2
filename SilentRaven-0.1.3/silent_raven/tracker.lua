-- core/tracker.lua  --  runtime state for the FSM and external API

local M = {
    -- FSM state name; nil means idle / no run in flight.
    state               = nil,
    state_t             = nil,

    -- True between trigger and DONE/FAILED.  Other scripts poll this
    -- via SilentRavenPlugin.get_status().running and yield while true.
    running             = false,

    -- 'auto' (in-town autofire), 'external', 'external+tp'.
    last_reason         = '',

    -- External-trigger queue (set by external.lua, consumed on next tick).
    external_trigger    = false,
    external_caller     = nil,
    external_callback   = nil,
    teleport_required   = false,

    -- Pause state (external.pause / external.resume).
    managed_by          = nil,
    paused              = false,
    paused_by           = nil,

    -- Per-attempt state.
    attempts            = 0,
    interacts_fired     = 0,
    last_interact_t     = nil,
    interact_npc        = nil,

    -- TP recast debounce stamp.  Separate from last_interact_t so the
    -- two clocks can't stomp each other.
    tp_last_cast_t      = nil,

    -- Per-zone latch -- once a turn-in succeeds in a zone, don't auto-fire
    -- again until the player leaves and re-enters that zone.  Without this
    -- we'd loop forever once the bounty quest wasn't immediately re-issued.
    last_zone_handled   = nil,
    last_observed_zone  = nil,

    -- Cached "is a turn-in ready?".  Refreshed by throttled scan in main.
    ready               = false,
    last_ready_check_t  = 0,

    -- Last terminal result for status display: 'success', 'failed', or nil.
    last_result         = nil,
    last_result_t       = 0,

    -- All-task-done flag in the Alfred sense: true between a finished run
    -- and the next trigger.  Lets callers detect callback-firing from a
    -- one-shot poll if they didn't pass a callback.
    all_task_done       = false,
}

M.reset_run = function ()
    M.state             = nil
    M.state_t           = nil
    M.running           = false
    M.attempts          = 0
    M.interacts_fired   = 0
    M.last_interact_t   = nil
    M.interact_npc      = nil
    M.tp_last_cast_t    = nil
    M.external_trigger  = false
    M.external_caller   = nil
    M.external_callback = nil
    M.teleport_required = false
    M.last_pick_entry   = nil
    M.walk_intermediate = nil
    M.movement_owned    = false
    M.claim_sent        = false
    M.claim_before      = nil
    M.continuation_guard = nil
    M.confirm_since     = nil
    M.run_started_t     = nil
    M.paused            = false
    M.paused_by         = nil
end

-- Reset before invoking the callback: reentrant status/cancel cannot finish twice.
M.finish = function(result)
    local callback = M.external_callback
    M.last_result = result
    M.last_result_t = (get_time_since_inject and get_time_since_inject()) or 0
    M.all_task_done = true
    M.reset_run()
    if callback then pcall(callback, result) end
end

-- Unknown/loading zones cannot manufacture a new visit.
M.observe_zone = function(zone)
    if type(zone) ~= 'string' or zone == '' or zone == '[sno none]' or zone == 'Limbo' then return end
    if M.last_observed_zone and M.last_observed_zone ~= zone then
        M.last_zone_handled = nil
    end
    M.last_observed_zone = zone
end

return M
