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
    loot_start = get_time_since_inject(),
    loot_timeout = 3,
    debounce_time = -1,
    debounce_timeout = 3
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
local reset = function ()
    -- Completion belongs to this caller's state; never pause the companion.
    if floor_has_loot() then
        task.loot_start = get_time_since_inject()
        task.status = status_enum['LOOTING']
    else
        task.status = status_enum['IDLE']
    end
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
    local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function ()
        if token == generation and task.status == status_enum.WAITING and get_alfred() == a then reset() end
    end)
    if ok and accepted == false then
        if token == generation and task.status == status_enum.WAITING then retire_request() end
        return false
    end
    -- A throwing call may already have queued work. Reserve this generation
    -- until callback or stable readable idle reconciles the uncertain result.
    if not ok then return false end
    return true -- legacy nil is an accepted request, not a rejection
end

task.shouldExecute = function ()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return true end -- unknown interrupts idle confirmation
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return false
    end

    -- Hold while we have our own cycle in flight or floor-loot to grab.
    if waiting_for_request(status)
        or get_time_since_inject() < retry_after
        or task.status == status_enum['LOOTING']
    then
        return true
    end

    -- Yield while Alfred is busy for any caller. trigger_tasks is the
    -- live flag (both forks); external_trigger is the queued window
    -- Some forks expose external_trigger; the supplied legacy source does not.
    -- Its with-teleport trigger does expose teleport immediately.
    local alfred_busy = live_work(status)
    if alfred_busy then return true end

    -- need_trigger is the documented Steroid signal AND the unified
    -- AlfredTheButler-main signal. WonderCity has zone-specific gating
    -- AND a restock-stickiness escape (last cycle just finished + only
    -- sticky flags set → skip; see HelltideRevamped for the same shape).
    if status.need_trigger then
        local now = get_time_since_inject()
        local cycle_just_completed = last_completion_at
            and (now - last_completion_at) < STUCK_NEED_TRIGGER_GRACE
        local sticky_only = cycle_just_completed
            and not status.inventory_full
            and not status.need_repair
        if not sticky_only then
            local in_uc = utils.player_in_undercity()
            local in_sno_none = utils.player_in_zone('[sno none]')
            if in_uc then
                if status.inventory_full then return true end
            elseif not in_sno_none then
                return true
            end
        end
    end

    return false
end

task.Execute = function ()
    local status = get_alfred_status()
    if not status then quiet_since = nil; return end
    if not status.enabled then
        if task.status == status_enum.WAITING then retire_request() end
        return
    end
    -- Forced cleanup paths can execute this task without shouldExecute().
    if task.status == status_enum.WAITING then waiting_for_request(status); return end
    if status.paused or get_time_since_inject() < retry_after then return end

    -- Don't overwrite another caller's in-flight cycle (WarPigs handoff).
    local alfred_busy = live_work(status)
    if alfred_busy then
        return
    end

    if task.status == status_enum['IDLE'] then
        if BatmobilePlugin and type(BatmobilePlugin.pause) == 'function' then
            BatmobilePlugin.pause(plugin_label)
        end
        trigger_alfred()
    elseif task.status == status_enum['LOOTING'] and get_time_since_inject() > task.loot_start + task.loot_timeout then
        task.status = status_enum['IDLE']

    end
end

task.is_busy = function ()
    local status = get_alfred_status()
    if not status then return true end
    if not status.enabled then return false end
    return task.status == status_enum.WAITING or task.status == status_enum.LOOTING
        or live_work(status) or false
end

task.on_cancel = function ()
    generation = generation + 1
    clear_request()
    retry_after = -math.huge
    task.status = status_enum.IDLE
    task.debounce_time = -math.huge
    last_completion_at = nil
end
task.reset = function (transition)
    if type(transition) ~= 'string' then task.on_cancel() end
end

return task
