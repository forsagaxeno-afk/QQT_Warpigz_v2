local tracker = require 'core.tracker'

local utils    = {
    settings = {},
}
-- True once the pit reset timer has expired. Higher-priority movement tasks
-- (portal, cross_traversal) consult this and yield so exit_pit can run.
-- Without the yield, force_move / interact spam keeps the player moving and
-- cancels the teleport_to_waypoint channel every frame.
utils.exit_pit_forced = function ()
    if not tracker.pit_start_time then return false end
    local settings = require 'core.settings'
    if not settings.reset_timeout then return false end
    return tracker.pit_start_time + settings.reset_timeout < get_time_since_inject()
end
utils.player_in_zone = function (zname)
    local world = get_current_world()
    return world ~= nil and world:get_current_zone_name() == zname
end
utils.player_in_pit = function ()
    local world = get_current_world()
    if not world then return false end
    local name = world:get_name()
    return name ~= nil and name:match("^PIT_") ~= nil
end
utils.is_looting = function ()
    local looter = LooteerPlugin
    if not looter then return false end
    local function read(fn, ...)
        if type(fn) ~= 'function' then return false, nil end
        return pcall(fn, ...)
    end
    -- Modern contracts expose booleans. A failed/invalid read is not idle.
    if type(looter.get_enabled) == 'function' then
        local ok, enabled = read(looter.get_enabled)
        if not ok or type(enabled) ~= 'boolean' then return true end
        if not enabled then return false end
    end
    local modern_unknown = false
    if type(looter.is_actively_looting) == 'function' then
        local ok, active = read(looter.is_actively_looting)
        if ok and type(active) == 'boolean' then return active end
        modern_unknown = true
    end
    if type(looter.is_idle) == 'function' then
        local ok, idle = read(looter.is_idle)
        if ok and type(idle) == 'boolean' then return not idle end
        modern_unknown = true
    end
    -- A second explicit modern status can resolve an unavailable first one.
    -- Legacy nil must not turn an unreadable modern owner into idle.
    if modern_unknown then return true end
    if type(looter.getSettings) == 'function' then
        if type(looter.get_enabled) ~= 'function' then
            local ok, enabled = read(looter.getSettings, 'enabled')
            if not ok then return true end
            -- Legacy nil means stored false only when no modern status owns
            -- this decision. A failed modern read was held above.
            if enabled == false or enabled == nil then return false end
            if enabled ~= true then return true end
        end
        local ok, active = read(looter.getSettings, 'looting')
        if not ok then return true end
        if active == false or active == nil then return false end
        return true
    end
    return true -- no readable ownership contract
end
utils.get_glyph_upgrade_gizmo = function ()
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        if actor_name == 'Gizmo_Paragon_Glyph_Upgrade' then
            return actor
        end
    end
    return nil
end
utils.distance = function (a, b)
    if a.get_position then a = a:get_position() end
    if b.get_position then b = b:get_position() end
    local dx = math.abs(a:x() - b:x())
    local dy = math.abs(a:y() - b:y())
    return math.max(dx, dy) + (math.sqrt(2) - 1) * math.min(dx, dy)
end

-- Pause only suppresses exploration; Batmobile long paths also have an
-- autonomous driver. Stop that driver before a channel or movement handoff.
utils.stop_movement = function ()
    if not BatmobilePlugin then return end
    BatmobilePlugin.stop_long_path('arkham_asylum')
    BatmobilePlugin.clear_target('arkham_asylum')
    BatmobilePlugin.pause('arkham_asylum')
end

return utils
