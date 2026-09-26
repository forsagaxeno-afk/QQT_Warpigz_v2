-- Minimal external surface for cross-script queries.
-- WarPug is self-gating: Temis, a valid empty quest snapshot, and no
-- active WarPigs/Alfred work. It does not orchestrate other plugins.
-- Capture imports during WarPug startup: status() is also called from WarPigs,
-- whose current require path/cache may point at another plugin.
local settings = require 'core.settings'
local planner  = require 'core.planner'
local M = {}

function M.status()
    return {
        name    = 'WarPug',
        version = settings.plugin_version,
        enabled = settings.enabled,
        state   = planner.get_current_state(),
    }
end

return M
