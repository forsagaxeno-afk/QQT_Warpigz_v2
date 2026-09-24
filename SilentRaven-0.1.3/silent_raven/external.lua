-- Public bridge API v2. Queue ownership lasts until exactly one completion.
local settings = require 'silent_raven.settings'
local tracker = require 'silent_raven.tracker'
local whispers = require 'silent_raven.whispers'
local coordination = require 'silent_raven.coordination'
local external = {}
local function caller_valid(caller) return type(caller) == 'string' and caller ~= '' end

function external.get_status()
    return {
        api_version = 2, name = settings.plugin_label,
        version = settings.plugin_version, author = settings.plugin_author,
        enabled = settings.enabled, running = tracker.running,
        pending = tracker.external_trigger, owner = tracker.external_caller,
        managed_by = tracker.managed_by, ready = tracker.ready,
        last_reason = tracker.last_reason, last_result = tracker.last_result,
        last_result_t = tracker.last_result_t, all_task_done = tracker.all_task_done,
        state = tracker.state, attempts = tracker.attempts,
        last_zone_handled = tracker.last_zone_handled,
        last_observed_zone = tracker.last_observed_zone,
        paused = tracker.paused, paused_by = tracker.paused_by,
        -- Companion SilentRaven is waiting for (own-run yield or auto-fire
        -- admission), or nil. Informational; additive.
        hold_reason = tracker.current_hold((get_time_since_inject and get_time_since_inject()) or 0),
    }
end
function external.is_available() return settings.enabled == true end

function external.set_managed(caller, enabled)
    if not caller_valid(caller) then return false, 'invalid_caller' end
    if tracker.managed_by and tracker.managed_by ~= caller then return false, 'managed' end
    if enabled then
        if tracker.running or tracker.external_trigger then
            if tracker.external_caller ~= caller then return false, 'busy' end
        end
        tracker.managed_by = caller
        return true, 'managed'
    end
    if tracker.external_caller == caller and (tracker.running or tracker.external_trigger) then
        return false, 'busy'
    end
    tracker.managed_by = nil
    return true, 'released'
end

function external.pause(caller)
    if not caller_valid(caller) then return false, 'invalid_caller' end
    if tracker.managed_by and tracker.managed_by ~= caller then return false, 'managed' end
    if tracker.paused_by and tracker.paused_by ~= caller then return false, 'paused' end
    if (tracker.running or tracker.external_trigger) and tracker.external_caller ~= caller then
        return false, 'busy'
    end
    tracker.paused, tracker.paused_by = true, caller
    return true
end
function external.resume(caller)
    if not tracker.paused then return true end
    if tracker.paused_by ~= caller then return false, 'not_owner' end
    tracker.paused, tracker.paused_by = false, nil
    return true
end

local function queue(caller, callback, with_tp, guard)
    if not caller_valid(caller) then return false, 'invalid_caller' end
    if callback ~= nil and type(callback) ~= 'function' then return false, 'invalid_callback' end
    if guard ~= nil and type(guard) ~= 'function' then return false, 'invalid_guard' end
    if not settings.enabled then return false, 'disabled' end
    if tracker.managed_by and tracker.managed_by ~= caller then return false, 'managed' end
    if with_tp and tracker.managed_by then return false, 'managed_no_teleport' end
    if tracker.running or tracker.external_trigger then return false, 'busy' end
    if tracker.paused then return false, 'paused' end
    local allowed, reason = coordination.can_start(caller)
    if not allowed then return false, reason end
    if not with_tp and not whispers.in_whisper_town() then return false, 'not_temis' end
    tracker.continuation_guard = guard
    tracker.external_caller, tracker.external_callback = caller, callback
    tracker.teleport_required, tracker.external_trigger = with_tp, true
    tracker.all_task_done = false
    return true, 'queued'
end
function external.trigger_tasks(caller, callback, guard) return queue(caller, callback, false, guard) end
function external.trigger_tasks_with_teleport(caller, callback) return queue(caller, callback, true) end

function external.cancel(caller, preserve_navigation)
    if not caller_valid(caller) or tracker.external_caller ~= caller then
        return false, 'not_owner'
    end
    if not tracker.running and not tracker.external_trigger then return false, 'idle' end
    -- Recheck the live guard even during a master stop: movement ownership
    -- can change between the last FSM tick and this API call. Explicit false
    -- is reserved for an owner that just verified companions are idle; its
    -- own revocation guard may already be false during a master stop.
    if tracker.continuation_guard and preserve_navigation == nil then
        local ok, allowed = pcall(tracker.continuation_guard)
        if not ok or allowed ~= true then preserve_navigation = true end
    end
    -- Pending requests never owned movement or an NPC panel. ESC only closes
    -- a panel that is observably open: with nothing open (panel timeout, or
    -- after accept closed it) D4 would open the game menu for every plugin.
    if tracker.running and preserve_navigation ~= true then
        if (tracker.interacts_fired > 0 or tracker.claim_sent) and whispers.reward_panel_open() == true then
            whispers.send_escape()
        end
        if tracker.movement_owned then whispers.stop_movement() end
    end
    tracker.finish('cancelled')
    return true, 'cancelled'
end
function external.check_version(input)
    if type(input) ~= 'string' then return false end
    local cur, want = {}, {}
    for n in settings.plugin_version:gmatch('%d+') do cur[#cur + 1] = tonumber(n) end
    for n in input:gmatch('%d+') do want[#want + 1] = tonumber(n) end
    if #want == 0 then return false end
    for i = 1, math.max(#cur, #want) do
        if (cur[i] or 0) > (want[i] or 0) then return true end
        if (cur[i] or 0) < (want[i] or 0) then return false end
    end
    return true
end
return external
