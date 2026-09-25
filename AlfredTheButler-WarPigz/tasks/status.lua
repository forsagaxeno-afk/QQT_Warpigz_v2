local plugin_label = 'alfred_the_butler'

local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local external = require 'core.external'

local status_enum = {
    IDLE = 'Idle',
    WAITING = 'Waiting to be in town',
    FAILED = 'Alfred has failed you (successfully failed XD), please copy logs to discord channel',
    STUCK = 'Alfred is stuck, your stash is probably full!!'
}
local function waiting_status()
    return 'Waiting to be in ' .. utils.get_town().display_name
end

local task = {
    name = 'Status',
    status = status_enum['IDLE'],
}

local function all_task_done()
    local status = {
        complete = false,
        failed = false
    }

    if (tracker.sell_done or tracker.sell_failed) and
        (tracker.stash_done or tracker.stash_failed) and
        (tracker.salvage_done or tracker.salvage_failed) and
        (tracker.salvage_talisman_done or tracker.salvage_talisman_failed) and
        (tracker.repair_done or tracker.repair_failed) and
        (not tracker.teleport or tracker.teleport_done or tracker.teleport_failed)
    then
        status.complete = true
    end

    if tracker.sell_failed or
        tracker.stash_failed or
        tracker.salvage_failed or
        tracker.teleport_failed
    then
        status.failed = true
    end
    return status
end

function task.shouldExecute()
    local should_execute = false
    local status = all_task_done()
    if not utils.is_in_town() and (not tracker.teleport or tracker.teleport_done) then
        should_execute = true
    elseif settings.allow_external and tracker.external_pause then
        should_execute = true
    elseif tracker.manual_trigger and not tracker.trigger_tasks then
        should_execute = true
    elseif settings.allow_external and tracker.external_trigger and not tracker.trigger_tasks then
        should_execute = true
    elseif not tracker.trigger_tasks then
        should_execute = true
    elseif tracker.trigger_tasks and status.complete and status.failed then
        tracker.last_reset = get_time_since_inject()
        should_execute = true
    elseif tracker.trigger_tasks and status.complete then
        should_execute = true
    end
    return should_execute
end

function task.Execute()
    local local_player = get_local_player()
    if not local_player then
        return
    end

    if settings.allow_external and tracker.external_pause then
        -- Paused by another plugin: hold here, keep every request for later.
        task.status = 'Paused by ' .. tostring(tracker.pause_caller or tracker.external_caller or '?')
        return
    end

    -- Given up earlier (stash full): stay idle until the user frees space and
    -- triggers manually, or the bag no longer needs a town run.
    -- (main.lua clears tracker.stuck on those.)
    if tracker.stuck then
        task.status = status_enum['STUCK']
        return
    end

    local status = all_task_done()
    if status.complete then
        local stuck_reason = nil
        if tracker.stash_full then
            stuck_reason = 'stash full'
        elseif settings.skip_cache and tracker.inventory_full then
            stuck_reason = 'inventory full of kept caches'
        end
        if stuck_reason then
            -- End the cycle as failed (was: STUCK with trigger_tasks and
            -- external_trigger held forever, so every caller saw live work).
            utils.reset_all_task()
            -- recount now: reset cleared need_trigger, and main.lua ends
            -- the stuck state as soon as need_trigger reads false
            utils.update_tracker_count(local_player, true)
            task.teleport_trigger_time = nil
            tracker.all_task_done = true
            external.give_up(stuck_reason)
            task.status = status_enum['STUCK']
            return
        end
        utils.reset_all_task()
        task.teleport_trigger_time = nil
        tracker.manual_trigger = false
        tracker.trigger_tasks = false
        tracker.all_task_done = true
        if tracker.external_trigger then
            tracker.external_trigger = false
            tracker.external_caller = nil
            external.fire_callbacks()
        end
        -- Resume Batmobile only if Alfred paused a running Batmobile. (The old
        -- fork also forced LooteerPlugin.setSettings('looting', true) here.)
        external.release_batmobile()
    end

    if status.failed then
        if settings.failed_action == utils.failed_action_enum['LOG'] then
            if task.status ~= status_enum['FAILED'] then
                utils.dump_tracker_info(tracker)
            end
            task.status = status_enum['FAILED']
        else
            utils.reset_all_task()
            tracker.trigger_tasks = true
        end
        return
    end

    if (settings.allow_external and tracker.external_trigger) or
        tracker.need_trigger or tracker.manual_trigger
    then
        if not utils.is_in_town() then
            tracker.teleport = true
        end
        if settings.get_export_keybind_state() and task.status ~= waiting_status() and task.status ~= status_enum['FAILED'] then
            utils.export_inventory_info()
        end
        if settings.stash_socketables == utils.stash_extra_enum['ALWAYS'] or
            tracker.need_stash_socketables
        then
            tracker.stash_socketables = true
        else
            tracker.stash_socketables = false
        end
        if settings.stash_consumables == utils.stash_extra_enum['ALWAYS'] or
            tracker.need_stash_consumables
        then
            tracker.stash_boss_materials = true
        else
            tracker.stash_boss_materials = false
        end
        if settings.stash_keys == utils.stash_extra_enum['ALWAYS'] or
            tracker.need_stash_keys
        then
            tracker.stash_keys = true
            tracker.stash_sigils = settings.stash_sigils
        else
            tracker.stash_keys = false
            tracker.stash_sigils = false
        end
        tracker.stash_talisman_seal   = true
        tracker.stash_talisman_charm  = true
        -- per-rarity charm/seal rules: salvage whenever the scan found any
        tracker.salvage_talisman_seal  = (tracker.salvage_talisman_count or 0) > 0
        tracker.salvage_talisman_charm = tracker.salvage_talisman_seal
        if settings.salvage_sigils then
            tracker.salvage_sigils = true
        else
            tracker.salvage_sigils = false
        end
        if tracker.batmobile_resume == nil and BatmobilePlugin then
            tracker.batmobile_resume = not BatmobilePlugin.is_paused()
            BatmobilePlugin.pause(plugin_label)
        end
        tracker.trigger_tasks = true
        task.status = waiting_status()
    else
        task.status = status_enum['IDLE']
        tracker.last_task = task.name
    end
end

return task