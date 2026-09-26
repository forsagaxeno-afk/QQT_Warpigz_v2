local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'

local status_enum = {
    IDLE = 'idle',
    WAITING = 'waiting for alfred to complete',
    LOOTING = 'looting stuff on floor'
}
local task = {
    name = 'alfred_running', -- change to your choice of task name
    status = status_enum['IDLE'],
    -- Why the task is holding (shown next to the status; nil = no hold).
    note = nil,
    loot_start = get_time_since_inject(),
    loot_timeout = 3,
    debounce_time = -1,
    debounce_timeout = 3
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

local floor_has_loot = function ()
    local ok, present = pcall(function()
        return loot_manager.any_item_around(get_player_position(), 30, true, true)
    end)
    return not ok or present == true -- unreadable floor still gets a brief loot window
end

local teleport_with_debounce = function ()
    if task.debounce_time + task.debounce_timeout > get_time_since_inject() then return end
    task.debounce_time = get_time_since_inject()
    teleport_to_waypoint(settings.town_waypoint)
end

-- Tracks last cycle completion for restock-stickiness escape. See
-- HelltideRevamped/tasks/alfred.lua for the full rationale.
-- WCY-1: a task switch (on_cancel) never erases it; the grace expires by itself.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local generation = 0
local request_plugin, request_started, quiet_since
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2
-- Bounded holds (C6). A paused Alfred with hard work cannot self-start;
-- after PAUSED_HOLD_MAX we continue without it. A with-teleport trip started
-- inside an Undercity whose callback lands in town waits RETURN_WINDOW for
-- the return portal. WCY-9: after FAILED_BEFORE_GRACE failed/cancelled
-- results in a row the sticky grace applies anyway (no hot retry loop).
local PAUSED_HOLD_MAX, RETURN_WINDOW, HOLD_LOG_AFTER, FAILED_BEFORE_GRACE = 60, 30, 60, 3
local trip = {from_run = false, return_until = nil, live_seen = false, failures = 0, result_logged = false,
    paused_since = nil, paused_logged = false, wait_paused_since = nil,
    hold = nil, hold_since = nil, hold_logged = -math.huge, advisory_logged = -math.huge}

-- C1 canonical live-work predicate (a latched teleport after a finished or
-- failed trip is not live work).
local function live_work(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
-- C1 hard need; need_trigger alone (restock/stash extras) is advisory.
local function hard_need(s)
    return s.inventory_full == true or s.need_repair == true
end
-- Suite policy (round 5; the same reading as ArkhamAsylum's
-- warpigs_advisory_idle): while WarPigs is loaded and its status() reports
-- enabled == true, WarPigs services advisory-only flags (need_trigger without
-- inventory_full/need_repair: restock/stash extras) once per Temis visit, and
-- WonderCity never starts an Alfred trip for them, whatever alfred_idle says.
-- F-C1 waited only for alfred_idle (WarPigs' 20 s grace), so a sticky flag
-- still cost a Kurast trip at every Undercity start. Hard needs are
-- unchanged. WarPigs absent, disabled, without status(), throwing or
-- returning a non-table: standalone rules.
local function warpigs_advisory_idle()
    local wp = WarPigsPlugin
    if type(wp) ~= 'table' or type(wp.status) ~= 'function' then return false end
    local ok, st = pcall(wp.status)
    return ok and type(st) == 'table' and st.enabled == true
end
-- Status text + one rate-limited log line for any hold longer than a minute.
local function note_hold(reason)
    local now = get_time_since_inject()
    if reason ~= trip.hold then trip.hold, trip.hold_since = reason, now end
    task.note = reason
    if reason and now - trip.hold_since >= HOLD_LOG_AFTER and now - trip.hold_logged >= HOLD_LOG_AFTER then
        trip.hold_logged = now
        console.print(string.format('[WonderCity:alfred] holding for %.0fs: %s', now - trip.hold_since, reason))
    end
end
-- A paused Alfred with hard work: hold (true) up to PAUSED_HOLD_MAX. Paused
-- without hard work is idle for us: we never own Alfred's pause (C1).
local function paused_hold(status)
    if not (status.paused and hard_need(status)) then
        trip.paused_since, trip.paused_logged = nil, false
        return false
    end
    local now = get_time_since_inject()
    trip.paused_since = trip.paused_since or now
    if now - trip.paused_since < PAUSED_HOLD_MAX then return true end
    if not trip.paused_logged then
        trip.paused_logged = true
        console.print(string.format('[WonderCity:alfred] Alfred paused with inventory/repair work for %.0fs — continuing without it',
            now - trip.paused_since))
    end
    return false
end
-- Any observed live -> idle edge is a finished cycle (ours or a foreign
-- caller's): advisory flags get the same sticky grace either way.
local function observe_cycle(status)
    if status.enabled and live_work(status) then
        trip.live_seen = true
    elseif trip.live_seen then
        trip.live_seen = false
        last_completion_at = get_time_since_inject()
    end
end
-- C1/WCY-6: an unreadable status (throws, non-table, non-boolean enabled)
-- holds like busy for at most UNKNOWN_HOLD seconds, then Alfred counts as
-- unavailable (not busy) with one log line until it reads again.
local UNKNOWN_HOLD = 10
local UNAVAILABLE = {enabled = false, unavailable = true}
local unknown = {since = nil, logged = false}
local function get_alfred_status()
    local a = get_alfred()
    if not a then unknown.since = nil; return {enabled = false} end
    local status
    if type(a.get_status) == 'function' then
        local ok, s = pcall(a.get_status)
        if ok and type(s) == 'table' and type(s.enabled) == 'boolean' then status = s end
    end
    if status then
        if unknown.logged then console.print('[WonderCity:alfred] Alfred status readable again') end
        unknown.since, unknown.logged = nil, false
        observe_cycle(status)
        return status
    end
    local now = get_time_since_inject()
    unknown.since = unknown.since or now
    if now - unknown.since < UNKNOWN_HOLD then return nil end
    if not unknown.logged then
        unknown.logged = true
        console.print(string.format('[WonderCity:alfred] Alfred status unreadable for %.0fs — treating Alfred as unavailable',
            now - unknown.since))
    end
    return UNAVAILABLE
end

local function clear_request()
    request_plugin, request_started, quiet_since = nil, nil, nil
    trip.wait_paused_since = nil
end
-- completed: the request most likely finished (lost legacy callback), so
-- advisory flags get the same sticky grace as a completed cycle (WCY-1).
local function retire_request(completed)
    generation = generation + 1
    clear_request()
    task.status = status_enum.IDLE
    retry_after = get_time_since_inject() + RETRY_DELAY
    if completed then last_completion_at = get_time_since_inject() end
end
local function waiting_for_request(status)
    if task.status ~= status_enum.WAITING then return false end
    if get_alfred() ~= request_plugin then retire_request(false); return true end
    if not status or live_work(status) then
        quiet_since = nil
        return true
    end
    local now = get_time_since_inject()
    if status.paused then
        -- A paused sample is not stable idle. Bounded: a pause that outlives
        -- PAUSED_HOLD_MAX retires the request (C6).
        quiet_since = nil
        trip.wait_paused_since = trip.wait_paused_since or now
        if now - trip.wait_paused_since >= PAUSED_HOLD_MAX then
            console.print(string.format('[WonderCity:alfred] Alfred paused for %.0fs with our request pending — retiring it',
                now - trip.wait_paused_since))
            retire_request(false)
        end
        return true
    end
    trip.wait_paused_since = nil
    -- Legacy trigger calls return nil and do not expose their queued flag.
    -- Allow pickup first, then require stable idle before retiring a lost callback.
    if now - (request_started or now) < PICKUP_WINDOW then return true end
    quiet_since = quiet_since or now
    if now - quiet_since >= QUIET_WINDOW then retire_request(true) end
    return true
end
local reset = function ()
    -- Completion belongs to this caller's state; never pause the companion.
    local now = get_time_since_inject()
    if floor_has_loot() then
        task.loot_start = now
        task.status = status_enum['LOOTING']
    else
        task.status = status_enum['IDLE']
    end
    -- A with-teleport trip from inside a run whose callback lands in town
    -- still owns the return leg (C2 alfred_trip), bounded by RETURN_WINDOW.
    trip.return_until = trip.from_run and not utils.player_in_undercity() and now + RETURN_WINDOW or nil
    trip.from_run, trip.failures = false, 0
    clear_request()
    retry_after = -math.huge
    last_completion_at = now
end
-- WCY-9 (host result semantics unverified): a failed/cancelled result is not
-- a completed cycle. Retry after RETRY_DELAY without the sticky grace.
local function failed_cycle(result)
    trip.failures = trip.failures + 1
    trip.from_run = false
    console.print(string.format('[WonderCity:alfred] Alfred reported %s for our cycle — retry in %ds (%d in a row)',
        tostring(result), RETRY_DELAY, trip.failures))
    retire_request(trip.failures >= FAILED_BEFORE_GRACE)
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
    trip.from_run, trip.return_until = utils.player_in_undercity(), nil
    request_plugin, request_started, quiet_since = a, get_time_since_inject(), nil
    local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function (result)
        -- Rosie reports a table {success = bool, reason = string|nil, request_id}.
        if type(result) == 'table' then
            result = result.success == false and ('failed: ' .. tostring(result.reason or '?')) or nil
        end
        if result ~= nil and not trip.result_logged then
            trip.result_logged = true -- one-time diagnostic of the host's callback argument
            console.print('[WonderCity:alfred] Alfred completion callback result=' .. tostring(result))
        end
        if token == generation and task.status == status_enum.WAITING and get_alfred() == a then
            if result == false or result == 'failed' or result == 'cancelled'
                or (type(result) == 'string' and result:find('failed: ', 1, true) == 1) then failed_cycle(result)
            else reset() end
        end
    end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request(false) end
        return false
    end
    -- A throwing call may already have queued work. Reserve this generation
    -- until callback or stable readable idle reconciles the uncertain result.
    if not ok then return false end
    return true -- legacy nil is an accepted request, not a rejection
end

-- Own with-teleport trip back in town before its return portal (bounded).
local function return_pending()
    if trip.return_until == nil then return false end
    if utils.player_in_undercity() then trip.return_until = nil; return false end
    if get_time_since_inject() >= trip.return_until then
        trip.return_until = nil
        console.print(string.format('[WonderCity:alfred] no Alfred return portal within %ds — continuing in town', RETURN_WINDOW))
        return false
    end
    return true
end

-- Should a NEW request start now (no own request, no live work)?
-- need_trigger is the documented Steroid signal AND the unified
-- AlfredTheButler-main signal. WonderCity has zone-specific gating AND a
-- restock-stickiness escape (last cycle just finished + only advisory flags
-- set → skip; see HelltideRevamped for the same shape).
local function wants_trigger(status)
    if not status.need_trigger then return false end
    local now = get_time_since_inject()
    local cycle_just_completed = last_completion_at
        and (now - last_completion_at) < STUCK_NEED_TRIGGER_GRACE
    if cycle_just_completed and not hard_need(status) then return false end
    if utils.player_in_undercity() then return status.inventory_full and true or false end
    if not hard_need(status) and warpigs_advisory_idle() then
        -- F-C1: not a hold (the route continues); one line per minute at most.
        if now - trip.advisory_logged >= HOLD_LOG_AFTER then
            trip.advisory_logged = now
            console.print('[WonderCity:alfred] advisory Alfred restock skipped: WarPigs is enabled and services it in Temis')
        end
        return false
    end
    return not utils.player_in_zone('[sno none]')
end

task.shouldExecute = function ()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return true end -- unknown interrupts idle confirmation (bounded)
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request(false) end
        return false
    end

    -- Hold while we have our own cycle in flight or floor-loot to grab.
    if waiting_for_request(status)
        or get_time_since_inject() < retry_after
        or task.status == status_enum['LOOTING']
        or return_pending()
    then
        return true
    end

    -- Yield while Alfred is busy for any caller. trigger_tasks is the
    -- live flag (both forks); external_trigger is the queued window
    -- Some forks expose external_trigger; the supplied legacy source does not.
    -- Its with-teleport trigger does expose teleport immediately.
    if live_work(status) then return true end

    if not wants_trigger(status) then
        trip.paused_since, trip.paused_logged = nil, false
        return false
    end
    if status.paused then return paused_hold(status) end
    return true
end

task.Execute = function ()
    local status = get_alfred_status()
    if not status then quiet_since = nil; note_hold('Alfred status unreadable'); return end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request(false) end
        note_hold(nil)
        return
    end
    -- Forced cleanup paths can execute this task without shouldExecute().
    if task.status == status_enum.WAITING then
        waiting_for_request(status)
        note_hold(task.status == status_enum.WAITING and (status.paused and 'Alfred paused with our request pending'
            or 'waiting for our Alfred cycle') or nil)
        return
    end
    -- The post-cycle loot window always ends, whatever Alfred reports now.
    if task.status == status_enum['LOOTING'] then
        if get_time_since_inject() > task.loot_start + task.loot_timeout then task.status = status_enum['IDLE'] end
        note_hold(nil)
        return
    end
    if return_pending() then note_hold('waiting for the Alfred return portal'); return end
    if status.paused then
        note_hold(hard_need(status) and 'Alfred paused with inventory/repair work' or nil)
        return
    end
    if get_time_since_inject() < retry_after then note_hold(nil); return end

    -- Don't overwrite another caller's in-flight cycle (WarPigs handoff).
    if live_work(status) then
        note_hold('Alfred busy with another caller')
        return
    end
    note_hold(nil)

    if task.status == status_enum['IDLE'] then
        if BatmobilePlugin and type(BatmobilePlugin.pause) == 'function' then
            BatmobilePlugin.pause(plugin_label)
        end
        trigger_alfred()
    end
end

-- known_only: count only positive evidence (own request/loot window or C1
-- live work). The forced reset-timeout exit uses it so an unreadable status
-- can never block it (WCY-6).
task.is_busy = function (known_only)
    local status = get_alfred_status()
    if not status then return not known_only end
    if not status.enabled then return false end
    return task.status == status_enum.WAITING or task.status == status_enum.LOOTING
        or live_work(status) or false
end

-- C2 alfred_trip: WonderCity's own Alfred round trip is in progress (request
-- in flight, post-callback loot window, or a with-teleport return not yet
-- back in the Undercity). Local state only; safe from the exported get_status.
task.own_trip = function ()
    if task.status == status_enum.WAITING or task.status == status_enum.LOOTING then return true end
    return return_pending()
end
-- The own trip belongs to an Undercity run (started inside, or its return
-- leg is still pending).
task.run_trip = function ()
    return task.own_trip() and (trip.from_run or trip.return_until ~= nil)
end

task.on_cancel = function ()
    generation = generation + 1
    clear_request()
    retry_after = -math.huge
    task.status = status_enum.IDLE
    task.debounce_time = -math.huge
    trip.from_run, trip.return_until = false, nil
    task.note = nil
    -- last_completion_at (and a running paused-hold window) are kept:
    -- preemption/cancel must not re-arm a sticky need_trigger (WCY-1) or
    -- restart a bounded hold.
end
task.reset = function (transition)
    -- Alfred's own town/return trip changes worlds while its callback is
    -- still valid. Explicit cancellation/reset invalidates that callback.
    if type(transition) ~= 'string' then task.on_cancel() end
end

return task
