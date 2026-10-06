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
        local alfred_idle = nil
        if enabled then alfred_idle = orchestrator.alfred_idle() end
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
            -- QQT_Warpigz_v3 1.1.7: read only while WarPigs is on (its only
            -- consumer, WarPug, checks enabled first). alfred_idle() runs the
            -- bounded-hold clocks and logs; activity plugins poll status() on
            -- every pulse, so an off WarPigs no longer runs them.
            alfred_idle = alfred_idle,
            busy    = orchestrator.is_busy(),
        }
    end,
    -- QQT_Warpigz_v3 (3.3.0): a side-effect-free status for observers (the
    -- WarRoom dashboard). status() runs alfred_idle(), which starts / clears
    -- WarPigs' own bounded-hold clocks and logs, and is_busy() asks
    -- SilentRaven / WarPug (and can log once); peek() only reads WarPigs'
    -- own state: busy = an activity WarPigs enabled is on.
    peek    = function()
        return {
            name    = settings.plugin_label,
            version = settings.plugin_version,
            enabled = gui.elements.main_toggle:get() and settings.get_keybind_state(),
            busy    = orchestrator.activity_on(),
            -- QQT_Warpigz_v3 1.1.11: seconds left in a suspended turn-in, or nil.
            turn_in_suspended_s = orchestrator.turn_in_suspended_left(),
        }
    end,
}

return external
