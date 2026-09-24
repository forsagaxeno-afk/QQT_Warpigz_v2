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

local function get_alfred_status()
    local a = get_alfred()
    if not a then return {enabled = false} end
    if type(a.get_status) ~= 'function' then return nil end
    local ok, status = pcall(a.get_status)
    return ok and type(status) == 'table' and type(status.enabled) == 'boolean' and status or nil
end

-- Tracks when our last Alfred cycle finished. Used to short-circuit the
-- Steroid restock-stickiness loop: tracker.need_trigger stays true forever
-- when restock_count > 0 can't be cleared (configured restock items with
-- nothing in stash to pull). Without this, shouldExecute fires every tick
-- on need_trigger, retriggering Alfred every ~10s for no-progress cycles
-- (observed in logzewx 31/42/43/57/58 — five rapid-fire stash cycles with
-- inventory empty). Mirrors WarPigs orchestrator's alfred_idle escape.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local generation = 0
local request_plugin, request_started, quiet_since
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2
local function live_work(status)
    return status and (status.trigger_tasks or status.external_trigger or status.running or status.pending
        or (status.teleport and not status.teleport_done and not status.teleport_failed))
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

function task.shouldExecute()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return true end -- unknown interrupts idle confirmation
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return false
    end

    if waiting_for_request(status) then return true end

    -- Yield while Alfred is busy under any caller (WarPigs preamble,
    -- other activity plugin transition). trigger_tasks is the live flag
    -- on both forks. external_trigger is optional and is absent from the
    -- supplied legacy status; teleport covers its with-teleport queue window.
    local alfred_busy = live_work(status)
    if alfred_busy then return true end

    -- Hold while we have a cycle in flight (set by Execute below).
    if get_time_since_inject() < retry_after then return true end

    if not settings.salvage then return false end

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
    if status.need_trigger and utils.is_in_helltide() then
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
end

task.cancel_pending = task.reset

return task
