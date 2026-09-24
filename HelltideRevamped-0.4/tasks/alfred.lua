local plugin_label = "helltide_revamped" -- change to your plugin name

local settings = require 'core.settings'
local tracker = require "core.tracker"
local utils = require "core.utils"
-- need use_alfred to enable
-- settings.salvage = true

local status_enum = {
    IDLE = 'idle',
    WAITING = 'waiting for alfred to complete',
}
local task = {
    name = 'alfred_running', -- change to your choice of task name
    status = status_enum['IDLE']
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

-- Tracks when our last Alfred cycle finished. Used to short-circuit the
-- Steroid restock-stickiness loop: tracker.need_trigger stays true forever
-- when restock_count > 0 can't be cleared (configured restock items with
-- nothing in stash to pull). Without this, shouldExecute fires every tick
-- on need_trigger, retriggering Alfred every ~10s for no-progress cycles
-- (observed in logzewx 31/42/43/57/58 — five rapid-fire stash cycles with
-- inventory empty). Mirrors WarPigs orchestrator's alfred_idle escape.
-- Never cleared by a reset or task switch: the grace expires by itself.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local generation = 0
local request_plugin, request_started, quiet_since
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2
-- C1/C6 bounds: an unreadable status holds like busy for UNKNOWN_HOLD, then
-- Alfred counts as unavailable; a pause HR does not own holds HR's own hard
-- request for PAUSED_HOLD_MAX, then HR farms on without Alfred.
local UNKNOWN_HOLD, PAUSED_HOLD_MAX = 10, 60
-- The unknown-since stamp is shared with core/utils.lua via tracker (one
-- grace for both readers, never two sequential holds).
local watch = {live_seen = false, paused_since = nil, paused_logged = false,
    hold_since = nil, hold_logged = nil}
-- C6: every hold this task imposes on the farm is published as
-- task.hold_reason (HelltideRevampedPlugin.status().hold) and logged once a
-- minute while it lasts over a minute. A live Alfred trip is not bounded
-- here: Alfred owns movement for its whole duration.
local HOLD_LOG_AFTER = 60
local function note_hold(reason)
    local now = get_time_since_inject()
    if reason ~= task.hold_reason then
        task.hold_reason, watch.hold_since, watch.hold_logged = reason, now, now
    end
    if reason and now - watch.hold_logged >= HOLD_LOG_AFTER then
        watch.hold_logged = now
        console.print(string.format('[HelltideRevamped] holding for %.0fs: %s', now - watch.hold_since, reason))
    end
end
-- C1 canonical live-work predicate (a teleport latched after a finished or
-- failed trip is not live work).
local function live_work(s)
    return s and (s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true))
end
-- Hard need (inventory/repair) may wait on a pause; advisory flags never do.
-- A legacy provider that exposes only need_trigger keeps it as its signal.
local function hard_need(s)
    if s.inventory_full == true or s.need_repair == true then return true end
    return s.need_trigger == true and s.inventory_full == nil and s.need_repair == nil
end
-- Any observed live -> idle edge is a finished cycle (ours or a foreign
-- caller's): advisory flags get the same sticky grace either way.
local function observe_cycle(status)
    if status.enabled and live_work(status) then
        watch.live_seen = true
    elseif watch.live_seen then
        watch.live_seen = false
        last_completion_at = get_time_since_inject()
    end
end
local function get_alfred_status()
    local a = get_alfred()
    if not a then tracker.alfred_unknown_since, tracker.alfred_unknown_logged = nil, nil; return {enabled = false} end
    local status
    if type(a.get_status) == 'function' then
        local ok, s = pcall(a.get_status)
        if ok and type(s) == 'table' and type(s.enabled) == 'boolean' then status = s end
    end
    if status then
        tracker.alfred_unknown_since, tracker.alfred_unknown_logged = nil, nil
        observe_cycle(status)
        return status
    end
    local now = get_time_since_inject()
    tracker.alfred_unknown_since = tracker.alfred_unknown_since or now
    if now - tracker.alfred_unknown_since < UNKNOWN_HOLD then return nil end
    if not tracker.alfred_unknown_logged then
        tracker.alfred_unknown_logged = true
        console.print(string.format('[HelltideRevamped] Alfred status unreadable for %.0fs — treating Alfred as unavailable',
            now - tracker.alfred_unknown_since))
    end
    return {enabled = false, unavailable = true}
end
-- A pause HR never owns: hold only while HR's own hard request is queued,
-- bounded; afterwards tracker.alfred_paused_skip lets the farm continue.
local function paused_hold(status)
    if not status.paused then
        watch.paused_since, watch.paused_logged = nil, false
        tracker.alfred_paused_skip = nil
        return false
    end
    if not (tracker.needs_salvage or (task.status == status_enum.WAITING and hard_need(status))) then
        return false
    end
    local now = get_time_since_inject()
    watch.paused_since = watch.paused_since or now
    if now - watch.paused_since < PAUSED_HOLD_MAX then return true end
    if not watch.paused_logged then
        watch.paused_logged = true
        console.print(string.format('[HelltideRevamped] Alfred paused by another plugin for %.0fs with our town request pending — farming on without Alfred',
            now - watch.paused_since))
    end
    tracker.needs_salvage = false
    tracker.alfred_paused_skip = true
    return false
end
local function clear_request()
    request_plugin, request_started, quiet_since = nil, nil, nil
end
local function retire_request()
    generation = generation + 1
    clear_request()
    task.status = status_enum.IDLE
    retry_after = get_time_since_inject() + RETRY_DELAY
end
local function waiting_for_request(status)
    if task.status ~= status_enum.WAITING then return false end
    if get_alfred() ~= request_plugin then retire_request(); return true end
    -- C1: a paused Alfred without hard work is idle for us (HR never owns
    -- its pause); with hard work it holds, bounded by paused_hold().
    if not status or live_work(status) or paused_hold(status) then
        quiet_since = nil
        return true
    end
    -- Legacy trigger calls return nil and do not expose their queued flag.
    -- Allow pickup first, then require stable idle before retiring a lost callback.
    local now = get_time_since_inject()
    if now - (request_started or now) < PICKUP_WINDOW then return true end
    quiet_since = quiet_since or now
    if now - quiet_since >= QUIET_WINDOW then
        retire_request()
        -- A lost callback most likely means a finished cycle: same grace.
        last_completion_at = now
    end
    return true
end

local function reset(token)
    if token ~= generation or task.status ~= status_enum.WAITING or get_alfred() ~= request_plugin then return end
    -- Completion updates HR state only. Both supplied Alfred forks can park
    -- indefinitely if a callback introduces an external pause.
    tracker.has_salvaged = true
    tracker.needs_salvage = false
    task.status = status_enum['IDLE']
    clear_request()
    retry_after = -math.huge
    last_completion_at = get_time_since_inject()
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
    local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function() reset(token) end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request() end
        return false
    end
    -- A throwing call may already have queued work. Reserve this generation
    -- until callback or stable readable idle reconciles the uncertain result.
    if not ok then return false end
    return true -- legacy nil is an accepted request, not a rejection
end

-- Returns whether this task takes the tick, plus the hold reason (C6).
local function decide()
    local status = get_alfred_status()
    if not status then
        quiet_since = nil -- unknown interrupts idle confirmation
        -- C1: HR's own setting first. An unreadable Alfred (bounded in
        -- get_alfred_status) holds only a salvage session or our own request.
        return settings.salvage or task.status == status_enum.WAITING, 'Alfred status unreadable'
    end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return false
    end

    if waiting_for_request(status) then return true, 'waiting for our Alfred trip' end

    -- Yield while Alfred is busy under any caller (WarPigs preamble,
    -- other activity plugin transition). trigger_tasks is the live flag
    -- on both forks. external_trigger is optional and is absent from the
    -- supplied legacy status; teleport covers its with-teleport queue window.
    local alfred_busy = live_work(status)
    if alfred_busy then return true, 'Alfred busy' end

    -- Hold while we have a cycle in flight (set by Execute below).
    if get_time_since_inject() < retry_after then return true, 'Alfred retry delay' end

    if not settings.salvage then return false end

    -- C1: a pause HR does not own is idle for HR unless our own hard town
    -- request is queued; that hold is bounded (paused_hold).
    if paused_hold(status) then return true, 'Alfred paused by another plugin with our town request pending' end
    if status.paused then return false end

    -- Steroid's documented integration (README §create_task) reacts to
    -- need_trigger directly. We apply two gates on top:
    --
    -- (1) Activity-scope gate: only react when actually farming
    --     (utils.is_in_helltide() — buff present). Without this, when
    --     helltide ends mid-hour (minute >=55) or the buff drops between
    --     zones, HR alfred.lua would keep firing on persistent need_trigger
    --     and bounce the player town↔portal for the 5min off-window.
    --     tracker.needs_salvage below still handles "HR transitioned to
    --     BACK_TO_TOWN explicitly" (set in helltide.lua:back_to_town), so
    --     the legitimate end-of-helltide salvage flow is unaffected.
    --     Steroid's own Status task self-triggers on tracker.need_trigger
    --     (status.lua:121) when no external script is driving — so
    --     genuine inventory_full / need_repair work isn't lost, it just
    --     stops going through our channel during the off-window.
    -- (2) Restock-stickiness escape: skip if our last cycle finished
    --     within STUCK_NEED_TRIGGER_GRACE and only restock/stash-extras
    --     flags are sticky (no inventory_full, no need_repair) — the
    --     prior cycle couldn't clear it, re-running won't either.
    --     Any observed cycle completion (ours or a foreign caller's) and a
    --     lost callback start the same grace (observe_cycle/waiting_for_request).
    -- The legacy fork publishes restock work as restock_count instead of
    -- need_trigger; it is advisory as well (HLT-2), so it takes this path.
    -- HLT-3: while the Batmobile give-up recovery leaves the zone, a
    -- with-teleport trip would portal back into the trap — never start one.
    local advisory = status.need_trigger == true
        or (AlfredTheButlerPlugin == nil and type(status.restock_count) == 'number' and status.restock_count > 0)
    if tracker.abandoning_zone then return false end
    if advisory and utils.is_in_helltide() then
        local now = get_time_since_inject()
        local cycle_just_completed = last_completion_at
            and (now - last_completion_at) < STUCK_NEED_TRIGGER_GRACE
        if cycle_just_completed
            and not status.inventory_full
            and not status.need_repair
        then
            -- stuck need_trigger — skip
        else
            return true
        end
    end

    -- Legacy back_to_town signal set in helltide.lua:back_to_town. Kept
    -- so the original "transitioning to BACK_TO_TOWN → run Alfred" path
    -- still fires. With need_trigger above this is partially redundant
    -- on Steroid but harmless.
    if tracker.needs_salvage then return true end

    return false
end

function task.shouldExecute()
    local run, reason = decide()
    note_hold(run and reason or nil)
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
    if status.paused or get_time_since_inject() < retry_after then return end

    -- Every busy cycle belongs to the caller that started it, including
    -- hosts that do not publish external_caller. Do not replace its callback.
    local alfred_busy = live_work(status)
    if task.status == status_enum['IDLE']
        and alfred_busy
    then
        return
    end

    if task.status == status_enum['IDLE'] then
        trigger_alfred()
    end
end

-- Invalidate callbacks when HR is disabled, without changing another caller's
-- Alfred state. Re-enabling may wait for that existing cycle to finish.
function task.reset()
    generation = generation + 1
    clear_request()
    retry_after = -math.huge
    task.status = status_enum['IDLE']
    tracker.has_salvaged = false
    tracker.needs_salvage = false
    -- A new session re-evaluates a foreign pause from scratch. The sticky
    -- grace (last_completion_at) is kept on purpose (C1: cancel never erases it).
    watch.paused_since, watch.paused_logged = nil, false
    tracker.alfred_paused_skip = nil
    note_hold(nil)
end

task.cancel_pending = task.reset

return task
