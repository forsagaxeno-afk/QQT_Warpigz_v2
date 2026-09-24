local plugin_label = "infernal_horde" -- change to your plugin name

local settings = require 'core.settings'
local tracker = require "core.tracker"
-- need use_alfred to enable
-- settings.use_alfred = true

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

local function complete(token)
    if token ~= generation or task.status ~= status_enum.WAITING or get_alfred() ~= request_plugin then return end
    tracker.has_salvaged = true
    tracker.needs_salvage = false
    task.status = status_enum['IDLE']
    clear_request()
    retry_after = -math.huge
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

function task.shouldExecute()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return true end -- unknown interrupts idle confirmation
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return false
    end

    if waiting_for_request(status) then return true end

    -- Yield while Alfred is busy under any caller.
    local alfred_busy = live_work(status)
    if alfred_busy then return true end

    -- Hold while we have our own cycle in flight.
    if get_time_since_inject() < retry_after then return true end

    if not settings.use_alfred then return false end

    -- Horde-specific gating: don't react to need_trigger while inside BSK
    -- — exiting the horde world mid-run loses the wave. Outside BSK is
    -- fine (only fires between hordes, which is when this task's parent
    -- script wants Alfred to run anyway). tracker.needs_salvage is set
    -- explicitly by horde-exit logic and is always safe to honour.
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

    -- Don't overwrite another caller's in-flight cycle.
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

function task.reset()
    generation = generation + 1
    clear_request()
    retry_after = -math.huge
    task.status = status_enum['IDLE']
    tracker.has_salvaged, tracker.needs_salvage = false, false
end

task.cancel_pending = task.reset

return task
