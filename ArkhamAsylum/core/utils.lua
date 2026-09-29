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
-- QQT_Warpigz_v3 Arkham 2.1.3: the third-party Navigator looter (docs/THIRD_PARTY_APIS.md):
-- a busy Scavenger holds the same loot waits as a busy Looter.
local function scavenger_busy()
    local s = Scavenger
    -- QQT_Warpigz_v3 Arkham 2.1.4: Rosie's Scavenger stand-in (`_rosie=true`, published
    -- while Worldstone runs) is Rosie's pickup, already read through the Looter.
    if type(s) ~= 'table' or rawget(s, '_rosie') == true or type(s.is_busy) ~= 'function' then return false end
    local ok, busy = pcall(s.is_busy)
    return ok and busy == true
end
utils.scavenger_busy = scavenger_busy
utils.is_looting = function ()
    if scavenger_busy() then return true end -- QQT_Warpigz_v3 Arkham 2.1.3
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
-- QQT_Warpigz_v3: the busy episode (since) stays shared, so the in-pit
-- pickup yield, the glyph upgrade and the Alfred trip never stack their
-- bounds; each caller logs its own "proceeds" line once per episode.
local looter = {since = nil, seen = -math.huge, logged = {}}
utils.looter_hold = function (max_hold, what)
    local now = get_time_since_inject()
    if not utils.is_looting() then
        looter.since = nil
        if next(looter.logged) ~= nil then looter.logged = {} end
        return false
    end
    if looter.since == nil or now - looter.seen > 2 then
        looter.since, looter.logged = now, {}
    end
    looter.seen = now
    if now - looter.since < max_hold then return true end
    local key = tostring(what or 'task')
    if not looter.logged[key] then
        looter.logged[key] = true
        console.print(string.format('[arkham] Looter busy for %.0fs — %s proceeds (bounded Looter yield)',
            now - looter.since, tostring(what or 'task')))
    end
    return false
end

-- QQT_Warpigz_v3 Arkham 2.1.5 (sweep 2026-09-28 A3 / S2 F4): the exit only waited
-- for drops inside Rosie's own pickup distance (2 m shipped default), so a
-- boss Mythic/Legendary 2-5 m from the glyphstone stayed behind. The boss
-- pile: a drop within PILE_RADIUS of the anchor, rarity >= 5, that Rosie
-- wants regardless of distance (evaluate_item(item, true)) but not from where
-- the player stands (evaluate_item(item, false)). Rosie's radius is never
-- widened (that pulls the player off Navigator/Worldstone routes). `keep`
-- (a key) is still returned once in Rosie's range: the walk to it goes on
-- until the pickup had its chance. Returns item, key, position or nil.
local PILE_RADIUS, PILE_MIN_RARITY = 12, 5
local function pile_key(item, pos)
    local ok, id = pcall(function() return item:get_id() end)
    if ok and type(id) == 'number' then return 'id' .. id end
    return string.format('%d_%d', math.floor(pos:x()), math.floor(pos:y()))
end
utils.boss_pile_drop = function (anchor, visited, keep)
    local looter = LooteerPlugin
    if anchor == nil or type(looter) ~= 'table' or type(looter.evaluate_item) ~= 'function' then return nil end
    if type(looter.get_enabled) == 'function' then
        local ok, enabled = pcall(looter.get_enabled)
        if not ok or enabled ~= true then return nil end
    end
    local ok, item, key, pos = pcall(function()
        local me = get_player_position()
        local best, best_key, best_pos, best_d = nil, nil, nil, math.huge
        for _, it in pairs(actors_manager.get_all_items() or {}) do
            local ipos = it:get_position()
            if ipos and utils.distance(ipos, anchor) <= PILE_RADIUS then
                local k = pile_key(it, ipos)
                local info = it.get_item_info and it:get_item_info() or nil
                local rarity = info and info.get_rarity and info:get_rarity() or nil
                if not (visited and visited[k]) and type(rarity) == 'number' and rarity >= PILE_MIN_RARITY
                    and looter.evaluate_item(it, true) == true
                    and (k == keep or looter.evaluate_item(it, false) ~= true)
                then
                    local d = me and utils.distance(ipos, me) or 0
                    if k == keep then d = -1 end
                    if d < best_d then best, best_key, best_pos, best_d = it, k, ipos, d end
                end
            end
        end
        return best, best_key, best_pos
    end)
    if not ok then return nil end
    return item, key, pos
end

-- QQT_Warpigz_v3: a SilentRaven Whisper claim (its own auto-fire or keybind,
-- or a queued request) owns Temis movement and clicks until it finishes,
-- bounded by SilentRaven (100 s run, 120 s pause). Town steps (walks,
-- interactions, the teleport out of Temis) wait; a paused queued request
-- does not hold them.
utils.raven_claim_active = function ()
    local raven = SilentRavenPlugin or PLUGIN_silent_raven
    if type(raven) ~= 'table' or type(raven.get_status) ~= 'function' then return false end
    local ok, s = pcall(raven.get_status)
    return ok and type(s) == 'table' and s.enabled == true
        and (s.running == true or (s.pending == true and s.paused ~= true))
end

return utils
