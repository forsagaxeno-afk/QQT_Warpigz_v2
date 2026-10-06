local gui = require 'gui'
local settings = require 'core.settings'
local task_manager = require 'core.task_manager'

local external = {
    get_status = function ()
        local current_task = task_manager.get_current_task()
        local msg
        if current_task.status ~= nil then
            msg = "Current Task: " .. current_task.name .. ' (' .. current_task.status .. ')'
        else
            msg = "Current Task: " .. current_task.name
        end
        if current_task.note then msg = msg .. ' - ' .. current_task.note end
        -- C2 (additive): alfred_trip = Arkham's own Alfred round trip in
        -- progress; in_run = inside/committed to a Pit run; committed_entry =
        -- pit opened / portal being entered but not yet inside.
        local run = task_manager.get_run_status()
        local enabled = settings.enabled and settings.get_keybind_state()
        return {
            name            = settings.plugin_label,
            version         = settings.plugin_version,
            enabled         = enabled,
            task            = msg,
            alfred_trip     = run.alfred_trip,
            in_run          = run.in_run,
            committed_entry = run.committed_entry,
            -- QQT_Warpigz_v3 Arkham 2.1.5 (C-boss): hold automatic town trips
            -- (Rosie) while a live boss is near or the glyph upgrade is pending.
            boss_fight      = enabled == true and run.boss_fight == true,
        }
    end,
    enable = function ()
        gui.elements.main_toggle:set(true)
        settings.enabled = true
        if not settings.external_control and gui.elements.use_keybind:get()
            and gui.elements.keybind_toggle:get_key() == 0x0A
        then
            console.print("[arkham] 'Use keybind' is on but no key is bound — running under external control")
        end
        settings.external_control = true
        gui.elements.keybind_toggle:set(true)
    end,
    disable = function ()
        task_manager.release_control()
        settings.enabled = false
        settings.external_control = false
        gui.elements.main_toggle:set(false)
        gui.elements.keybind_toggle:set(false)
    end,
}
return external