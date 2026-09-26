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
            alfred_idle = orchestrator.alfred_idle(),
            busy    = orchestrator.is_busy(),
        }
    end,
}

return external
