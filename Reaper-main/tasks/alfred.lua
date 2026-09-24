-- ============================================================
--  Reaper - tasks/alfred.lua
--  Yields to Alfred butler plugin when he needs to work.
--  Fork-aware: SteroidAlfredButler vs AlfredTheButler-main.
-- ============================================================

local plugin_label = "Reaper"
local settings     = require "core.settings"
local tracker      = require "core.tracker"
local navigate_to_boss = require "tasks.navigate_to_boss"
local interact_altar = require "tasks.interact_altar"

local status_enum = {
    IDLE    = "idle",
    WAITING = "waiting for alfred to complete",
}

local task = {
    name   = "alfred_running",
    status = status_enum.IDLE,
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

local function get_alfred_status()
    local a = get_alfred()
    if a then
        if type(a.get_status) ~= "function" then return {enabled=true, status_unknown=true} end
        local ok, status = pcall(a.get_status)
        if not ok or type(status) ~= "table" or type(status.enabled) ~= "boolean" then
            return {enabled=true, status_unknown=true}
        end
        return status
    end
    return {enabled = false}
end

-- Tracks last cycle completion for restock-stickiness escape. See
-- HelltideRevamped/tasks/alfred.lua for the full rationale.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local generation = 0
local request_plugin, request_started, quiet_since
local retry_after = -math.huge
local RETRY_DELAY, PICKUP_WINDOW, QUIET_WINDOW = 5, 8, 2

local function is_busy(status)
    return status.status_unknown or status.trigger_tasks or status.external_trigger
        or status.running or status.pending or status.paused
        or (status.teleport and not status.teleport_done and not status.teleport_failed)
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
    if is_busy(status) then quiet_since = nil; return true end
    -- The legacy API accepts a request with nil and omits its queue flag.
    -- Never infer completion from that return value. If its callback is lost,
    -- allow pickup and require a fresh stable idle observation before retry.
    local now = get_time_since_inject()
    if now - request_started < PICKUP_WINDOW then return true end
    quiet_since = quiet_since or now
    if now - quiet_since >= QUIET_WINDOW then retire_request() end
    return true
end

function task.reset()
    generation = generation + 1
    clear_request()
    task.status = status_enum.IDLE
    last_completion_at = nil
    retry_after = -math.huge
end

local function trigger_alfred()
    local a = get_alfred()
    if not a or type(a.trigger_tasks_with_teleport) ~= "function" then
        retry_after = get_time_since_inject() + RETRY_DELAY
        return false
    end
    generation = generation + 1
    local token = generation
    task.status = status_enum.WAITING
    request_plugin, request_started, quiet_since = a, get_time_since_inject(), nil
    -- Reaper did not acquire an Alfred pause, so it cannot resume one.
    local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function()
        if token ~= generation or task.status ~= status_enum.WAITING or get_alfred() ~= a then return end
        -- A callback only releases our wait. It must not pause an unrelated
        -- caller's cycle, even if the callback was delayed by a transition.
        task.status = status_enum.IDLE
        clear_request()
        retry_after = -math.huge
        last_completion_at = get_time_since_inject()
    end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request() end
        return false
    end
    -- A host method can enqueue before throwing. Keep its request reserved
    -- until a callback or stable readable idle reconciles that uncertainty.
    if not ok then return false end
    return true
end

function task.shouldExecute()
    local status = get_alfred_status()
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return false
    end

    if waiting_for_request(status) then return true end

    -- Yield while Alfred is busy under any caller.
    if is_busy(status) then return true end

    if not settings.use_alfred then return false end
    if get_time_since_inject() < retry_after then return true end

    -- Start maintenance between runs; a live boss/chest sequence owns the dungeon.
    if tracker.altar_activated or tracker.chest_opened_time then return false end

    -- need_trigger is the unified signal across both forks. Restock-
    -- stickiness escape: skip if last cycle just completed and only
    -- restock/stash-extras flags are sticky (see HelltideRevamped).
    if status.need_trigger then
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

    -- AlfredTheButler-main-only legacy fallback path: when the upstream
    -- get_status() shape was thinner the original Reaper code reacted
    -- to individual flags directly. Keep it gated behind PLUGIN_alfred_the_butler
    -- which only exists on the legacy fork.
    if PLUGIN_alfred_the_butler then
        if status.inventory_full or
            (status.restock_count and status.restock_count > 0) or
            status.need_repair
        then
            return true
        end
    end

    return false
end

function task.Execute()
    -- Stop our autonomous route before handing movement to Alfred. If Alfred
    -- is already busy, navigation_owner drops our stale claim without touching it.
    navigate_to_boss.reset()
    interact_altar.reset()
    settings.orb_set_block(false)
    local status = get_alfred_status()
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return
    end

    if waiting_for_request(status) then return end
    if is_busy(status) or not settings.use_alfred or get_time_since_inject() < retry_after then return end

    -- Don't overwrite another caller's in-flight cycle.
    if task.status == status_enum.IDLE then
        trigger_alfred()
    end
end

return task
