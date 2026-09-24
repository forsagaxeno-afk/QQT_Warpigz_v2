local plugin_label = "infernal_horde" -- change to your plugin name

local settings = require 'core.settings'
local tracker = require "core.tracker"
local utils = require "core.utils"
-- need use_alfred to enable
-- settings.use_alfred = true

local status_enum = {
    IDLE = 'idle',
    WAITING = 'waiting for alfred to complete',
}
local task = {
    name = 'alfred_running', -- change to your choice of task name
    status = status_enum['IDLE'],
    hold_reason = nil, -- C6: why this task currently holds the queue (status text)
}

local HORDE_ZONE = "S05_BSK_Prototype02"
-- C1 / HRD-6: an unreadable status (missing get_status, throw, non-table,
-- non-boolean enabled) holds at most UNKNOWN_GRACE, then Alfred counts as
-- unavailable (not busy) with one log line.
local UNKNOWN_GRACE = 10
-- HRD-5 (needs live check): after the callback of a trip that started in the
-- Horde, give Alfred's return portal this long before other tasks may leave.
local RETURN_WINDOW = 20
local HOLD_LOG_AFTER = 60 -- C6: log (rate-limited) a hold that lasts this long
local unknown = {since = nil, logged = false}
local trip = {from_bsk = false, returning_since = nil, logged = false}
local held = {reason = nil, since = nil, logged_at = nil}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

local function get_alfred_status()
    local a = get_alfred()
    if not a then unknown.since, unknown.logged = nil, false; return {enabled = false} end
    local ok, status = false, nil
    if type(a.get_status) == 'function' then ok, status = pcall(a.get_status) end
    if ok and type(status) == 'table' and type(status.enabled) == 'boolean' then
        unknown.since, unknown.logged = nil, false
        return status
    end
    local now = get_time_since_inject()
    unknown.since = unknown.since or now
    if now - unknown.since < UNKNOWN_GRACE then return nil end
    if not unknown.logged then
        unknown.logged = true
        console.print(string.format("[alfred] Alfred status unreadable for %ds; treating Alfred as unavailable", UNKNOWN_GRACE))
    end
    return {enabled = false, unavailable = true}
end

local generation = 0
local request_plugin, request_started, quiet_since
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2
-- C1 canonical live-work predicate (copied per plugin). A teleport latched
-- after a finished or failed trip is not live work.
local function live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
local function clear_request()
    request_plugin, request_started, quiet_since = nil, nil, nil
end
local function retire_request()
    generation = generation + 1
    clear_request()
    trip.from_bsk = false
    task.status = status_enum.IDLE
    retry_after = get_time_since_inject() + RETRY_DELAY
end
local function waiting_for_request(status)
    if task.status ~= status_enum.WAITING then return false end
    if get_alfred() ~= request_plugin then retire_request(); return true end
    if not status or live_work(status) or status.paused then
        quiet_since = nil
        return true
    end
    -- Legacy trigger calls return nil and do not expose their queued flag.
    -- Allow pickup first, then require stable idle before retiring a lost callback.
    local now = get_time_since_inject()
    if now - (request_started or now) < PICKUP_WINDOW then return true end
    quiet_since = quiet_since or now
    if now - quiet_since >= QUIET_WINDOW then retire_request() end
    return true
end

local function complete(token)
    if token ~= generation or task.status ~= status_enum.WAITING or get_alfred() ~= request_plugin then return end
    local now = get_time_since_inject()
    tracker.has_salvaged = true
    tracker.needs_salvage = false
    -- C1 sticky grace: advisory flags cannot re-trigger right after this cycle.
    tracker.alfred_completed_at = now
    task.status = status_enum['IDLE']
    clear_request()
    retry_after = -math.huge
    -- HRD-5: a mid-Horde trip whose callback arrives while the player is still
    -- outside the Horde has not returned yet; see awaiting_return().
    if trip.from_bsk and not utils.player_in_zone(HORDE_ZONE) then
        trip.returning_since, trip.logged = now, false
    end
    trip.from_bsk = false
end

-- HRD-5 (needs live check): hold the queue for a bounded return window so
-- walking_to_horde/town tasks do not teleport away from a paused Horde run
-- while Alfred's return portal may still be coming. Live Alfred work after the
-- callback is held separately (live_work). After the window the chest run is
-- reported as a fault (status().fault) instead of stalling silently.
local function awaiting_return(status)
    if not trip.returning_since then return false end
    if utils.player_in_zone(HORDE_ZONE) or not tracker.has_salvaged then
        trip.returning_since = nil
        return false
    end
    local now = get_time_since_inject()
    -- C1/C5: live or unreadable Alfred work after the callback keeps the hold
    -- and does not consume the idle return window.
    if not status or (status.enabled and live_work(status)) then
        trip.returning_since = now
        return true
    end
    if not trip.logged then
        trip.logged = true
        console.print(string.format("[alfred] Alfred callback arrived outside the Horde (teleport=%s done=%s failed=%s); holding up to %ds for its return portal",
            tostring(status and status.teleport), tostring(status and status.teleport_done),
            tostring(status and status.teleport_failed), RETURN_WINDOW))
    end
    if now - trip.returning_since < RETURN_WINDOW then return true end
    trip.returning_since = nil
    local message = "Alfred trip ended outside the Horde; the chest run could not be resumed."
    console.print("[alfred] " .. message)
    if not tracker.finished_chest_looting then
        tracker.chest_fault = tracker.chest_fault or message
        tracker.finished_chest_looting = true
    end
    return false
end

local function trigger_alfred()
    local a = get_alfred()
    if not a or type(a.trigger_tasks_with_teleport) ~= 'function' then
        retry_after = get_time_since_inject() + RETRY_DELAY
        return false
    end
    generation = generation + 1
    local token = generation
    task.status = status_enum.WAITING
    request_plugin, request_started, quiet_since = a, get_time_since_inject(), nil
    trip.from_bsk, trip.returning_since = utils.player_in_zone(HORDE_ZONE), nil
    local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function() complete(token) end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request() end
        return false
    end
    -- A throwing call may already have queued work. Reserve this generation
    -- until callback or stable readable idle reconciles the uncertain result.
    if not ok then return false end
    return true -- legacy nil is an accepted request, not a rejection
end

local function decide()
    local status = get_alfred_status()
    -- Our own request in flight is reconciled regardless of use_alfred.
    if task.status == status_enum.WAITING then
        if status and not status.enabled then retire_request(); return false end
        waiting_for_request(status)
        return true, 'HordeDev Alfred trip in progress'
    end
    if awaiting_return(status) then return true, 'waiting for the Alfred return portal' end

    -- HRD-6 / C1: the user's use_alfred choice comes before any Alfred hold,
    -- so an odd or unreadable Alfred cannot stall waves, chests or exit.
    if not settings.use_alfred then quiet_since = nil; return false end

    if not status then quiet_since = nil; return true, 'Alfred status unreadable' end -- bounded (UNKNOWN_GRACE)
    if not status.enabled then return false end

    -- Yield while Alfred is busy under any caller.
    if live_work(status) then return true, 'Alfred busy' end

    -- Hold while we have our own cycle in flight.
    if get_time_since_inject() < retry_after then return true end

    -- Horde-specific gating: don't react to need_trigger while inside BSK
    -- — exiting the horde world mid-run loses the wave. Outside BSK is
    -- fine (only fires between hordes, which is when this task's parent
    -- script wants Alfred to run anyway). tracker.needs_salvage is set
    -- explicitly by horde-exit logic and is always safe to honour.
    if tracker.needs_salvage ~= true then return false end
    -- A paused Alfred is not triggered (Execute); report the wait (C6).
    return true, status.paused and 'waiting for a paused Alfred' or nil
end

function task.shouldExecute()
    local run, reason = decide()
    local now = get_time_since_inject()
    task.hold_reason = reason
    if reason ~= held.reason then held.reason, held.since, held.logged_at = reason, now, nil end
    if reason and now - held.since >= HOLD_LOG_AFTER
        and (not held.logged_at or now - held.logged_at >= HOLD_LOG_AFTER) then
        held.logged_at = now
        console.print(string.format("[alfred] HordeDev held for %ds: %s", math.floor(now - held.since), reason))
    end
    return run
end

function task.Execute()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return
    end
    -- Forced cleanup paths can execute this task without shouldExecute().
    if task.status == status_enum.WAITING then waiting_for_request(status); return end
    if trip.returning_since or not settings.use_alfred or not tracker.needs_salvage then return end
    if status.paused or get_time_since_inject() < retry_after then return end

    -- Don't overwrite another caller's in-flight cycle.
    if live_work(status) then return end

    if task.status == status_enum['IDLE'] then
        trigger_alfred()
    end
end

-- C2: true while an Alfred round trip HordeDev started is in flight
-- (request pending/running, or the bounded return window after its callback).
function task.trip_in_progress()
    return task.status == status_enum.WAITING or trip.returning_since ~= nil
end

function task.reset()
    generation = generation + 1
    clear_request()
    retry_after = -math.huge
    task.status = status_enum['IDLE']
    task.hold_reason = nil
    trip.from_bsk, trip.returning_since = false, nil
    -- tracker.alfred_completed_at is kept: cancel/preempt never erases the grace.
    tracker.has_salvaged, tracker.needs_salvage = false, false
end

task.cancel_pending = task.reset

return task
