local gui = require 'gui'

-- War plan table actor skin name. Update this constant once confirmed in-game
-- (use the debug/actor-dump tools — look for an actor near the war plan board
-- in Temis). When blank, WarPug relies on warplan.is_ready() being true
-- already; otherwise the bounded approach phase waits without clicking.
local TABLE_ACTOR_NAME = 'Warplans_Vendor'

local settings = {
    plugin_label     = gui.plugin_label,
    plugin_version   = gui.plugin_version,
    -- Runtime values populated by update_settings()
    enabled          = false,
    table_actor_name = TABLE_ACTOR_NAME,
    reroll_click_x   = 0,
    reroll_click_y   = 0,
    reroll_set       = false,
    reroll_confirm_x = 0,
    reroll_confirm_y = 0,
    confirm_set      = false,
    show_click_points = false,
    verbose_logs     = false,
}

settings.update_settings = function()
    settings.enabled           = gui.elements.main_toggle:get()
    settings.show_click_points = gui.elements.show_click_points:get()
    settings.verbose_logs      = gui.elements.verbose_logs:get()

    -- Resolve the captured relative (0..1) coords against the live screen
    -- size each tick. QQT mouse input uses game-client coordinates.
    local sw = get_screen_width()
    local sh = get_screen_height()
    local p  = gui.positions
    settings.reroll_set = p.reroll_set and gui.valid_position(p.reroll_rx, p.reroll_ry) and sw > 0 and sh > 0
    settings.confirm_set = p.confirm_set and gui.valid_position(p.confirm_rx, p.confirm_ry) and sw > 0 and sh > 0
    settings.reroll_click_x = settings.reroll_set and math.floor(p.reroll_rx * sw) or 0
    settings.reroll_click_y = settings.reroll_set and math.max(1, math.floor(p.reroll_ry * sh)) or 0
    settings.reroll_confirm_x = settings.confirm_set and math.floor(p.confirm_rx * sw) or 0
    settings.reroll_confirm_y = settings.confirm_set and math.max(1, math.floor(p.confirm_ry * sh)) or 0
end

return settings
