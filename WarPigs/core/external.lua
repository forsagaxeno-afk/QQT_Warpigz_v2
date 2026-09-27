local gui      = require 'gui'
local settings = require 'core.settings'
local orchestrator = require 'core.orchestrator'

local external = {
    enable  = function()
        gui.elements.main_toggle:set(true)
        settings:update_settings()
    end,
    disable = function()
        gui.elements.main_toggle:set(false)
        settings:update_settings()
        return orchestrator.release_all()
    end,
    status  = function()
        local enabled = gui.elements.main_toggle:get() and settings.get_keybind_state()
        return {
            name    = settings.plugin_label,
            version = settings.plugin_version,
            enabled = enabled,
            manages_whispers = enabled and settings.manage_whispers == true,
            -- QQT_Warpigz_v3 (Q8): while WarPigs manages Whispers its own
            -- Temis check runs only between activities, so a Helltide night
            -- claimed nothing. It delegates a ready reward to a town trip's
            -- return leg (Rosie hands off to SilentRaven) and to
            -- SilentRaven's claim trip whenever its own Whisper request and
            -- teleport sequence are idle. Additive.
            whisper_handoff = enabled and settings.manage_whispers == true and orchestrator.whisper_handoff_ok(),
            -- QQT_Warpigz_v3 (Q8): while WarPigs manages Whispers, an activity
            -- it enabled is on (its own Whisper slot stays closed; SilentRaven
            -- claims a Temis stop of it while WarPigs delegates). Additive.
            activity_on = enabled and settings.manage_whispers == true and orchestrator.activity_on(),
            alfred_idle = orchestrator.alfred_idle(),
            busy    = orchestrator.is_busy(),
        }
    end,
}

return external
