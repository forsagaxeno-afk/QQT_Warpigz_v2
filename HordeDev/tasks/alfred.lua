local plugin_label = "infernal_horde" -- change to your plugin name

local settings = require 'core.settings'
local tracker = require "core.tracker"
local utils = require "core.utils"
-- QQT_Warpigz_v3 HordeDev 2.2.9: the Horde maps, as core/horde_zones.lua
-- (this task loads with core.settings/tracker/utils only; keep both in step).
local HORDE_MAPS = {'S05_BSK_Prototype02', 'S10_BSK_Pretorment'}
local function in_horde()
    for _, zone in ipairs(HORDE_MAPS) do
        if utils.player_in_zone(zone) then return true end
    end
    return false
end
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

-- C1 / HRD-6: an unreadable status (missing get_status, throw, non-table,
-- non-boolean enabled) holds at most UNKNOWN_GRACE, then Alfred counts as
-- unavailable (not busy) with one log line.
local UNKNOWN_GRACE = 10
-- HRD-5 (needs live check): after the callback of a trip that started in the
-- Horde, give Alfred's return portal this long before other tasks may leave.
local RETURN_WINDOW = 20
local HOLD_LOG_AFTER = 60 -- C6: log (rate-limited) a hold that lasts this long
-- C1/C6: HordeDev's own request, or its needs_salvage hold, waits on a paused
-- Alfred at most this long (the bound Arkham/WonderCity/HR use).
local PAUSED_HOLD_MAX = 60
local unknown = {since = nil, logged = false}
local trip = {from_bsk = false, returning_since = nil, logged = false}
local held = {reason = nil, since = nil, logged_at = nil, paused_since = nil, paused_logged = false}

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
-- C1/C6: true once HordeDev has waited PAUSED_HOLD_MAX on a paused Alfred.
-- The window starts only while HordeDev wants Alfred (its own request or
-- needs_salvage) and lasts until a readable sample is not paused, so a request
-- retired for the pause does not open a second window. An unreadable sample
-- changes nothing (bounded separately). tracker.alfred_pause_expired lets the
-- chest task continue instead of re-pausing for an Alfred that cannot run.
local function paused_too_long(status)
    if status == nil then return tracker.alfred_pause_expired == true end
    if status.enabled ~= true or status.paused ~= true then
        held.paused_since, held.paused_logged = nil, false
        tracker.alfred_pause_expired = false
        return false
    end
    local now = get_time_since_inject()
    if not held.paused_since then
        if task.status ~= status_enum.WAITING and tracker.needs_salvage ~= true then return false end
        held.paused_since = now
    end
    tracker.alfred_pause_expired = now - held.paused_since >= PAUSED_HOLD_MAX
    return tracker.alfred_pause_expired
end
local function retire_request()
    generation = generation + 1
    clear_request()
    trip.from_bsk = false
    task.status = status_enum.IDLE
    retry_after = get_time_since_inject() + RETRY_DELAY
end
-- QQT_Warpigz_v3 owner-build: SteroidAlfred goes STUCK for good (stash full,
-- or skip_cache with a full bag; its out-of-town teleport also retries
-- forever): trigger_tasks stays true and no callback ever comes, so every
-- live-work hold below waited forever. Mirrors WarPigs' LIVE_WORK_HOLD:
-- continuous live work longer than LIVE_WORK_MAX is logged once, our request
-- is retired, that live work no longer holds the Horde (until it ends), and
-- no new trip is asked for while it lasts, and for at least TOWN_BLOCK_S.
-- tracker.alfred_town_stuck tells core/loot_guard the same.
local LIVE_WORK_MAX, TOWN_BLOCK_S = 300, 600
local live = {since = nil, seen = -math.huge, expired = false, blocked_until = -math.huge}
local function live_stuck(status)
    if not (status and status.enabled and live_work(status)) then
        live.since, live.expired, tracker.alfred_town_stuck = nil, false, nil
        return false
    end
    local now = get_time_since_inject()
    -- A sampling gap (the task did not run) starts the clock over.
    if not live.expired and now - live.seen > 5 then live.since = now end
    live.seen = now
    if live.expired then return true end
    if now - live.since < LIVE_WORK_MAX then return false end
    live.expired, live.blocked_until, tracker.alfred_town_stuck = true, now + TOWN_BLOCK_S, true
    tracker.alfred_town_block_until = live.blocked_until
    console.print(string.format("[alfred] town service busy for %ds without finishing (stash full?) — farming on without it",
        LIVE_WORK_MAX))
    if task.status == status_enum.WAITING then retire_request() end
    trip.returning_since = nil
    tracker.needs_salvage = false
    return true
end
-- Live work that still holds us (not a STUCK town service).
local function busy_work(status) return live_work(status) and not live_stuck(status) end
local function town_blocked() return live.expired or get_time_since_inject() < live.blocked_until end
task.town_blocked = town_blocked
local function waiting_for_request(status)
    if task.status ~= status_enum.WAITING then return false end
    if get_alfred() ~= request_plugin then retire_request(); return true end
    if not status or busy_work(status) then
        quiet_since = nil
        return true
    end
    if status.paused then
        -- A paused sample is not stable idle; the wait is bounded (C1/C6).
        quiet_since = nil
        if paused_too_long(status) then
            console.print(string.format("[alfred] Alfred paused for %ds with HordeDev's request pending; retiring it",
                PAUSED_HOLD_MAX))
            retire_request()
        end
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
    if trip.from_bsk and not in_horde() then
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
    if in_horde() or not tracker.has_salvaged then
        trip.returning_since = nil
        return false
    end
    local now = get_time_since_inject()
    -- C1/C5: live or unreadable Alfred work after the callback keeps the hold
    -- and does not consume the idle return window.
    if not status or (status.enabled and busy_work(status)) then
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
    trip.from_bsk, trip.returning_since = in_horde(), nil
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
    paused_too_long(status) -- C1/C6: track (or end) a paused-Alfred window
    -- Our own request in flight is reconciled regardless of use_alfred.
    if task.status == status_enum.WAITING then
        if status and not status.enabled then retire_request(); return false end
        waiting_for_request(status)
        return true, status and status.paused == true and 'waiting for a paused Alfred'
            or 'HordeDev Alfred trip in progress'
    end
    if awaiting_return(status) then return true, 'waiting for the Alfred return portal' end

    -- QQT_Warpigz_v3: never fight Alfred's movement or teleport, whoever
    -- started it and whatever 'Use alfred' says (as Reaper does). Rosie
    -- starts its own automatic town service on need_trigger regardless of
    -- HordeDev's setting; with 'Use alfred' off HordeDev used to teleport to
    -- the Library in the middle of it, the trip failed, the bag stayed full
    -- and the horde was abandoned. Only a readable, enabled, live status
    -- holds (bounded by Alfred's own service timeout and failure latch).
    if status and status.enabled and busy_work(status) then return true, 'Alfred busy' end

    -- HRD-6 / C1: the user's use_alfred choice comes before any other Alfred
    -- hold, so an odd or unreadable Alfred cannot stall waves, chests or exit.
    if not settings.use_alfred then quiet_since = nil; return false end

    if not status then quiet_since = nil; return true, 'Alfred status unreadable' end -- bounded (UNKNOWN_GRACE)
    if not status.enabled then return false end

    -- QQT_Warpigz_v3: a stuck Alfred/Rosie (failed trips latched, stash full,
    -- retry cooldown) refuses every request while it still publishes
    -- inventory_full; asking again every RETRY_DELAY held the Horde forever
    -- with no visible hold. Drop the salvage need and continue (logged once
    -- per stuck episode, C6); a recovered Alfred is asked again.
    if status.stuck == true then
        tracker.needs_salvage = false
        if not held.stuck_logged then
            held.stuck_logged = true
            console.print("[alfred] Rosie stuck: " .. tostring(status.stuck_reason or 'town service refused')
                .. "; farming on without town trips")
        end
        return false
    end
    held.stuck_logged = false

    -- QQT_Warpigz_v3 owner-build: a STUCK town service: farm on, no request.
    if town_blocked() then tracker.needs_salvage = false; return false end

    -- Hold while we have our own cycle in flight.
    if get_time_since_inject() < retry_after then return true end

    -- Horde-specific gating: don't react to need_trigger while inside BSK
    -- — exiting the horde world mid-run loses the wave. Outside BSK is
    -- fine (only fires between hordes, which is when this task's parent
    -- script wants Alfred to run anyway). tracker.needs_salvage is set
    -- explicitly by horde-exit logic and is always safe to honour.
    if tracker.needs_salvage ~= true then return false end
    -- A paused Alfred is not triggered (Execute); the wait is visible (C6) and
    -- bounded (C1): past PAUSED_HOLD_MAX HordeDev continues without it.
    if status.paused then
        if not paused_too_long(status) then return true, 'waiting for a paused Alfred' end
        if not held.paused_logged then
            held.paused_logged = true
            console.print(string.format("[alfred] Alfred paused for %ds with salvage pending; continuing without it",
                PAUSED_HOLD_MAX))
        end
        return false
    end
    return true
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
    if status.stuck == true then tracker.needs_salvage = false; return end -- QQT_Warpigz_v3

    -- Don't overwrite another caller's in-flight cycle.
    if live_work(status) then return end
    if town_blocked() then tracker.needs_salvage = false; return end -- QQT_Warpigz_v3 owner-build

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
    held.paused_since, held.paused_logged = nil, false
    tracker.alfred_pause_expired = false
    -- tracker.alfred_completed_at is kept: cancel/preempt never erases the grace.
    tracker.has_salvaged, tracker.needs_salvage = false, false
end

task.cancel_pending = task.reset

return task
