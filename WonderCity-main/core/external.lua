local gui = require 'gui'
local settings = require 'core.settings'
local task_manager = require 'core.task_manager'
local tracker = require 'core.tracker'

local external = {
    get_status = function ()
        local current_task = task_manager.get_current_task()
        local msg
        if current_task.status ~= nil then
            msg = "Current Task: " .. current_task.name .. ' (' .. current_task.status .. ')'
        else
            msg = "Current Task: " .. current_task.name
        end
        return {
            name            = settings.plugin_label,
            version         = settings.plugin_version,
            enabled         = settings.enabled and settings.get_keybind_state(),
            task            = msg,
            boss_dead_observed = tracker.boss_kill_time ~= nil,
            reward_seen = tracker.reward_seen,
            reward_opened = tracker.done,
            reward_failed = tracker.chest_failed,
            completion_reason = tracker.completion_reason,
        }
    end,
    enable = function ()
        gui.elements.main_toggle:set(true)
        gui.elements.keybind_toggle:set(true)
        settings.update_settings()  -- refresh settings.enabled immediately
    end,
    disable = function ()
        task_manager.release_control()
        gui.elements.main_toggle:set(false)
        gui.elements.keybind_toggle:set(false)
        settings.update_settings()
    end,
}
return external
