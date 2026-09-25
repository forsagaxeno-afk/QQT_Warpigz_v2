local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'

-- Public API (globals AlfredTheButlerPlugin / PLUGIN_alfred_the_butler).
-- Field and function names are the SteroidAlfredV2 ones; WarPigz adds the
-- fields the suite's plugins read (paused, paused_by, external_caller,
-- external_trigger, pending, running, restock_count, owner).
local external = {}

local function add_callback(callback)
    if type(callback) ~= 'function' then return end
    local list = tracker.external_trigger_callbacks
    if type(list) ~= 'table' then list = {}; tracker.external_trigger_callbacks = list end
    list[#list + 1] = callback
    tracker.external_trigger_callback = callback
end

-- Runs (once) and clears every callback waiting on the finished cycle.
-- result is nil for a finished cycle and 'failed' for a cycle Alfred gave up
-- (stash full); callers that ignore the argument see the old behaviour.
function external.fire_callbacks(result)
    local list = tracker.external_trigger_callbacks
    tracker.external_trigger_callbacks = {}
    tracker.external_trigger_callback = nil
    if type(list) ~= 'table' then return 0 end
    for _, callback in ipairs(list) do
        local ok, err = pcall(callback, result)
        if not ok then utils.log('external callback failed: ' .. tostring(err)) end
    end
    return #list
end

-- Resumes Batmobile if (and only if) Alfred paused a running Batmobile for
-- the current cycle; always forgets that note.
function external.release_batmobile()
    local resume = tracker.batmobile_resume
    tracker.batmobile_resume = nil
    if resume == true and type(BatmobilePlugin) == 'table' and type(BatmobilePlugin.resume) == 'function' then
        pcall(BatmobilePlugin.resume, 'alfred_the_butler')
        return true
    end
    return false
end

-- Forget a pending request without running its callbacks (Alfred disabled).
function external.drop_request()
    tracker.external_trigger = false
    tracker.external_trigger_callbacks = {}
    tracker.external_trigger_callback = nil
    if not tracker.external_pause then tracker.external_caller = nil end
    external.release_batmobile()
end

-- Stash full (or caches kept with a full bag): end the cycle as failed
-- instead of holding trigger_tasks forever. Every waiting caller gets
-- callback('failed') once; Alfred then reports stuck=true, publishes
-- need_trigger=false and refuses triggers until the user clears it (manual
-- trigger, disable/enable) or the bag no longer needs a town run.
function external.give_up(reason)
    tracker.stuck = true
    tracker.stuck_reason = reason
    tracker.trigger_tasks = false
    tracker.manual_trigger = false
    tracker.external_trigger = false
    if not tracker.external_pause then tracker.external_caller = nil end
    utils.log('cycle given up: ' .. tostring(reason) .. ' (free stash space, then use the manual trigger)')
    external.release_batmobile()
    return external.fire_callbacks('failed')
end

function external.clear_stuck()
    tracker.stuck = false
    tracker.stuck_reason = nil
end

function external.get_status()
    local live = tracker.trigger_tasks == true
    local stuck = tracker.stuck == true
    local requested = tracker.external_trigger == true or tracker.manual_trigger == true
    return {
        name            = settings.plugin_label,
        version         = settings.plugin_version,
        enabled         = settings.is_enabled(),
        paused          = tracker.external_pause == true,
        paused_by       = tracker.external_pause and tracker.pause_caller or nil,
        external_caller = tracker.external_caller,
        owner           = tracker.external_caller,
        external_trigger = tracker.external_trigger == true,
        pending         = requested and not live,
        running         = live,
        teleport        = tracker.teleport,
        teleport_done   = tracker.teleport_done,
        teleport_failed = tracker.teleport_failed,
        inventory_full  = tracker.inventory_full,
        talisman_inventory_full = tracker.talisman_inventory_full,
        inventory_count = tracker.inventory_count,
        talisman_count  = tracker.talisman_count,
        salvage_count   = tracker.salvage_count,
        salvage_talisman_count = tracker.salvage_talisman_count,
        sell_count      = tracker.sell_count,
        stash_count     = tracker.stash_count,
        restock_count   = 0,   -- this fork does not restock
        trigger_tasks   = tracker.trigger_tasks,
        last_reset      = tracker.last_reset,
        salvage_failed  = tracker.salvage_failed,
        salvage_done    = tracker.salvage_done,
        sell_failed     = tracker.sell_failed,
        sell_done       = tracker.sell_done,
        stash_full      = tracker.stash_full == true or tracker.stuck_reason == 'stash full',
        all_task_done   = tracker.all_task_done,
        need_repair     = tracker.need_repair,
        -- a stuck Alfred cannot serve the need: callers must not hand off
        need_trigger    = tracker.need_trigger == true and not stuck,
        stuck           = stuck,
        stuck_reason    = tracker.stuck_reason,
        item_db_version = utils.classify.db.version,
    }
end

-- create_task(caller, on_done): a task object for the caller's task list
-- (first priority). When need_trigger is set it hands control to Alfred and
-- calls on_done once Alfred finished.
function external.create_task(caller, on_done)
    local task = { name = 'alfred', status = 'idle' }
    task.shouldExecute = function()
        local st = external.get_status()
        if task.status == 'waiting' then
            if st.enabled then return true end
            task.status = 'idle'   -- Alfred was disabled: the callback will never come
            return false
        end
        return st.enabled and st.need_trigger and not st.stuck
    end
    task.Execute = function()
        if task.status == 'idle' then
            local accepted = external.trigger_tasks_with_teleport(caller, function(result)
                task.status = 'idle'
                if on_done then on_done(result) end
            end)
            if accepted ~= false then task.status = 'waiting' end
        end
    end
    return task
end

function external.pause(caller)
    tracker.pause_caller = caller
    tracker.external_pause = true
    if not tracker.external_trigger then tracker.external_caller = caller end
    return true
end

function external.resume(caller)
    local was = tracker.pause_caller
    tracker.external_pause = false
    tracker.pause_caller = nil
    if not tracker.external_trigger and (tracker.external_caller == was or tracker.external_caller == caller) then
        tracker.external_caller = nil
    end
    return true
end

local function trigger(caller, callback, teleport)
    if not settings.is_enabled() or settings.allow_external == false then
        utils.log('trigger by ' .. tostring(caller) .. ' refused (Alfred disabled)')
        return false
    end
    if tracker.stuck then
        utils.log('trigger by ' .. tostring(caller) .. ' refused (stuck: ' .. tostring(tracker.stuck_reason) .. ')')
        return false
    end
    tracker.external_caller = caller
    tracker.external_trigger = true
    if teleport then tracker.teleport = true end
    add_callback(callback)
    utils.log('task triggered by ' .. tostring(caller))
    return true
end

function external.trigger_tasks(caller, callback)
    return trigger(caller, callback, false)
end

function external.trigger_tasks_with_teleport(caller, callback)
    return trigger(caller, callback, true)
end

return external
