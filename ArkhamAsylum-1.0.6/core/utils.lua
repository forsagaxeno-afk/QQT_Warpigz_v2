local tracker = require 'core.tracker'
-- Captured at load (no cycle: settings only needs gui). A require inside a
-- function would resolve in the CALLER's module context if another plugin
-- ever reached it through an exported API (shared QQT module cache).
local settings = require 'core.settings'

local plugin_label = 'arkham_asylum'
local utils    = {
    settings = {},
}
-- True once the pit reset timer has expired. Higher-priority movement tasks
-- (portal, cross_traversal) consult this and yield so exit_pit can run.
-- Without the yield, force_move / interact spam keeps the player moving and
-- cancels the teleport_to_waypoint channel every frame.
utils.exit_pit_forced = function ()
    if not tracker.pit_start_time then return false end
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
    BatmobilePlugin.stop_long_path(plugin_label)
    BatmobilePlugin.clear_target(plugin_label)
    BatmobilePlugin.pause(plugin_label)
end

-- C3 hand-off (disable, WarPigs release, Alfred taking over). The new
-- BatmobilePlugin.release is owner-aware: it stops only Arkham's own long
-- route/goal/traversal routing, pauses, restores the default explorer
-- priority (ARK-8) and never clears the native path a companion may own.
-- companion_owns: Alfred (or an unknown Alfred) owns control right now; an
-- older Batmobile without release() then only loses Arkham's autonomous
-- long route (ARK-5), never the target/pause a companion may rely on.
utils.release_movement = function (companion_owns)
    if not BatmobilePlugin then return end
    if type(BatmobilePlugin.release) == 'function' then
        BatmobilePlugin.release(plugin_label)
        return
    end
    if companion_owns then
        if type(BatmobilePlugin.is_long_path_navigating) ~= 'function'
            or BatmobilePlugin.is_long_path_navigating()
        then
            BatmobilePlugin.stop_long_path(plugin_label)
        end
        return
    end
    utils.stop_movement()
    if type(BatmobilePlugin.set_priority) == 'function' then
        BatmobilePlugin.set_priority(plugin_label, 'direction')
    end
end

-- Bounded Looter yield shared by upgrade_glyph and the Alfred trip start
-- (ARK-4: both yield to Looter the same way). True while Looter has been
-- continuously busy for less than max_hold seconds; afterwards the caller
-- proceeds (one log line per busy episode) so a Looter stuck in approach
-- retries cannot hold the Pit (C6). A gap in sampling starts a new episode.
local looter = {since = nil, seen = -math.huge, logged = false}
utils.looter_hold = function (max_hold, what)
    local now = get_time_since_inject()
    if not utils.is_looting() then
        looter.since, looter.logged = nil, false
        return false
    end
    if looter.since == nil or now - looter.seen > 2 then
        looter.since, looter.logged = now, false
    end
    looter.seen = now
    if now - looter.since < max_hold then return true end
    if not looter.logged then
        looter.logged = true
        console.print(string.format('[arkham] Looter busy for %.0fs — %s proceeds (bounded Looter yield)',
            now - looter.since, tostring(what or 'task')))
    end
    return false
end

return utils
