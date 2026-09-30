local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local external = {
    get_status = function ()
        return {
            name            = settings.plugin_label,
            version         = settings.plugin_version,
            enabled         = settings.enabled,
            teleport        = tracker.teleport,
            teleport_done   = tracker.teleport_done,
            teleport_failed = tracker.teleport_failed,
            inventory_full  = tracker.inventory_full,
            talisman_inventory_full = tracker.talisman_inventory_full,
            inventory_count = tracker.inventory_count,
            salvage_count   = tracker.salvage_count,
            sell_count      = tracker.sell_count,
            stash_count     = tracker.stash_count,
            trigger_tasks   = tracker.trigger_tasks,
            last_reset      = tracker.last_reset,
            salvage_failed  = tracker.salvage_failed,
            salvage_done    = tracker.salvage_done,
            sell_failed     = tracker.sell_failed,
            sell_done       = tracker.sell_done,
            all_task_done   = tracker.all_task_done,
            need_repair     = tracker.need_repair,
            need_trigger    = tracker.need_trigger,
        }
    end,
    -- create_task(caller, on_done)
    -- Returns a ready-made task object to drop into your script's task list as first priority.
    -- Alfred polls inventory every 0.5s. When need_trigger is true (inventory full, repair needed, etc.)
    -- this task will intercept your task runner, hand control to Alfred, and call on_done when finished.
    --
    -- Usage:
    --   local tasks = {
    --       AlfredTheButlerPlugin.create_task('my_script', function()
    --           -- reset your script state here, called when alfred finishes
    --       end),
    --       require('tasks.my_other_task'),
    --   }
    create_task = function(caller, on_done)
        local task = { name = 'alfred', status = 'idle' }
        task.shouldExecute = function()
            if task.status == 'waiting' then return true end
            local st = external.get_status()
            return st.enabled and st.need_trigger
        end
        task.Execute = function()
            if task.status == 'idle' then
                external.trigger_tasks_with_teleport(caller, function()
                    task.status = 'idle'
                    if on_done then on_done() end
                end)
                task.status = 'waiting'
            end
        end
        return task
    end,
    pause = function (caller)
        tracker.external_caller = caller
        tracker.external_pause = true
    end,
    resume = function ()
        tracker.external_caller = nil
        tracker.external_pause = false
    end,
    trigger_tasks = function (caller, callback)
        tracker.external_caller = caller
        tracker.external_trigger = true
        if callback then
            tracker.external_trigger_callback = callback
        end
        utils.log('task triggered by ' .. tostring(caller))
    end,
    trigger_tasks_with_teleport = function (caller,callback)
        tracker.external_caller = caller
        tracker.external_trigger = true
        tracker.teleport = true
        if callback then
            tracker.external_trigger_callback = callback
        end
        utils.log('task triggered by ' .. tostring(caller))
    end,
}
return external