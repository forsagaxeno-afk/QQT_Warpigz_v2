local tracker = require 'core.tracker'
local settings = require 'core.settings'

local utils    = {
    settings = {},
}
utils.player_in_zone = function (zname)
    local world = get_current_world()
    return world ~= nil and world:get_current_zone_name() == zname
end
utils.player_in_undercity = function ()
    local world = get_current_world()
    local zone = world and world:get_current_zone_name()
    return zone ~= nil and zone:match('X1_Undercity_') ~= nil
end
-- QQT_Warpigz_v3 WonderCity 2.2.4: the third-party Navigator looter (docs/THIRD_PARTY_APIS.md):
-- a busy Scavenger holds the same loot waits as a busy Looter.
local function scavenger_busy()
    local s = Scavenger
    if type(s) ~= 'table' or type(s.is_busy) ~= 'function' then return false end
    local ok, busy = pcall(s.is_busy)
    return ok and busy == true
end
utils.scavenger_busy = scavenger_busy
utils.is_looting = function ()
    if scavenger_busy() then return true end -- QQT_Warpigz_v3 WonderCity 2.2.4
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
-- QQT_Warpigz_v3: positive, readable evidence that the Looter is picking
-- something up right now (C5 yield). Unlike is_looting() an unreadable or
-- unknown contract is NOT busy here: this gates a movement hold.
utils.looter_busy_known = function ()
    if scavenger_busy() then return true end -- QQT_Warpigz_v3 WonderCity 2.2.4
    local looter = LooteerPlugin
    if type(looter) ~= 'table' then return false end
    local ok, value
    if type(looter.get_enabled) == 'function' then
        ok, value = pcall(looter.get_enabled)
        if not ok or value ~= true then return false end
    end
    if type(looter.is_actively_looting) == 'function' then
        ok, value = pcall(looter.is_actively_looting)
        if ok and type(value) == 'boolean' then return value end
    end
    if type(looter.is_idle) == 'function' then
        ok, value = pcall(looter.is_idle)
        if ok and type(value) == 'boolean' then return not value end
    end
    if type(looter.getSettings) == 'function' then
        ok, value = pcall(looter.getSettings, 'looting')
        return ok and value == true
    end
    return false
end
-- Use get_all_actors() — the brazier and entrance portal are not in the ally
-- list, so get_ally_actors() silently returned nil and the task stuck on idle.
utils.get_spirit_brazier = function ()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        if actor_name == 'Aubrie_Test_Undercity_Crafter' then
            return actor
        end
    end
    return nil
end
utils.get_entrance_portal = function ()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        -- Skip is_interactable() — calling it on every actor in the world
        -- during the post-Accept zone transition crashes the game on stale
        -- actor objects. Skin name is unique enough to identify the portal.
        local actor_name = actor:get_skin_name()
        if actor_name == 'Portal_Dungeon_Undercity' then
            return actor
        end
    end
    return nil
end
utils.get_undercity_chest = function ()
    -- The reward chest is a gizmo; it need not be present in the ally list.
    -- Return read validity separately so a failed scan cannot confirm opening.
    local ok, actors = pcall(actors_manager.get_all_actors)
    if not ok or type(actors) ~= 'table' then return nil, false end
    for _, actor in pairs(actors) do
        local read, actor_name = pcall(function() return actor:get_skin_name() end)
        if not read then return nil, false end
        if type(actor_name) == 'string' and actor_name:match('^X1_Undercity_Chest_Attunement') then
            return actor, true
        end
    end
    return nil, true
end
utils.get_enticement_count = function ()
    local count = 0
    for name, state in pairs(tracker.enticement) do
        -- QQT_Warpigz_v3: an unreachable (skipped) switch is not an interacted one.
        if state == true and name:match('SpiritHearth_Switch') then
            count = count + 1
        end
    end
    return count
end
utils.get_closest_enticement = function (ignore_interacted)
    local local_player = get_local_player()
    if not local_player then return end
    local actors = actors_manager:get_ally_actors()
    local closest_enticement, closest_dist
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        local found = false
        if name and
            (name:match('X1_Undercity_Enticements_SpiritBeaconSwitch') or
            (name:match('SpiritHearth_Switch') and
            utils.get_enticement_count() < settings.max_enticement))
        then
            local actor_pos = actor:get_position()
            local enticement_str = utils.enticement_key(name, actor_pos)
            local dist = utils.distance(local_player, actor)
            -- QQT_Warpigz_v3: a Grand Beacon set aside (tracker.beacon_aside)
            -- waits out its pause; it is never dropped for the floor.
            local aside = tracker.beacon_aside and tracker.beacon_aside[enticement_str]
            if dist <= settings.check_distance and
                (tracker.enticement[enticement_str] == nil or ignore_interacted) and
                (aside == nil or get_time_since_inject() >= aside.until_t) and
                (closest_dist == nil or dist < closest_dist)
            then
                closest_dist = dist
                closest_enticement = actor
            end
        end
    end
    return closest_enticement
end
utils.distance = function (a, b)
    if a.get_position then a = a:get_position() end
    if b.get_position then b = b:get_position() end
    local dx = math.abs(a:x() - b:x())
    local dy = math.abs(a:y() - b:y())
    return math.max(dx, dy) + (math.sqrt(2) - 1) * math.min(dx, dy)
end

utils.enticement_key = function (name, pos)
    return tostring(tracker.floor_generation) .. '|' .. name .. ':' .. tostring(pos:x()) .. ':' .. tostring(pos:y())
end
utils.exit_forced = function ()
    local now = get_time_since_inject()
    if tracker.reward_grace_until and now < tracker.reward_grace_until then return false end
    return tracker.undercity_start_time + settings.reset_timeout < now
end
utils.stop_movement = function ()
    if not BatmobilePlugin then return end
    BatmobilePlugin.stop_long_path('wonder_city')
    BatmobilePlugin.clear_target('wonder_city')
    BatmobilePlugin.pause('wonder_city')
    utils.own_long_path = false
end
-- WCY-5: true after walk_kurast started a Batmobile long route. Batmobile's
-- main pulse drives such a route on its own until it is stopped.
utils.own_long_path = false
-- Stops only the long route WonderCity started (never a route another
-- plugin or companion claimed since); target and pause are left alone.
utils.stop_own_long_path = function ()
    if not utils.own_long_path then return end
    utils.own_long_path = false
    local bat = BatmobilePlugin
    if not bat or type(bat.stop_long_path) ~= 'function' then return end
    if type(bat.is_long_path_navigating) == 'function' and not bat.is_long_path_navigating() then return end
    local owner = type(bat.get_owner) == 'function' and bat.get_owner() or nil
    if owner ~= nil and owner ~= 'wonder_city' then return end
    bat.stop_long_path('wonder_city')
end
-- C3/WCY-5/WCY-8: hand Batmobile back. BatmobilePlugin.release is
-- owner-aware (stops our long route, drops our goal and traversal routing,
-- pauses, restores the default explorer priority, never clears the native
-- path a companion may own). Older Batmobile: the previous sequence, or only
-- our own long route while a companion (Alfred) owns movement.
utils.release_movement = function (companion_owns)
    local bat = BatmobilePlugin
    if not bat then return end
    if type(bat.release) == 'function' then
        utils.own_long_path = false
        bat.release('wonder_city')
        return
    end
    if companion_owns then utils.stop_own_long_path() else utils.stop_movement() end
    if type(bat.set_priority) == 'function' then bat.set_priority('wonder_city', 'direction') end
end

-- QQT_Warpigz_v3: a SilentRaven Whisper claim (its own auto-fire or keybind,
-- or a queued request) owns Temis movement and clicks until it finishes,
-- bounded by SilentRaven (100 s run, 120 s pause). The town steps (brazier
-- walk, home-town teleport out of Temis) wait; a paused queued request does
-- not hold them.
utils.raven_claim_active = function ()
    local raven = SilentRavenPlugin or PLUGIN_silent_raven
    if type(raven) ~= 'table' or type(raven.get_status) ~= 'function' then return false end
    local ok, s = pcall(raven.get_status)
    return ok and type(s) == 'table' and s.enabled == true
        and (s.running == true or (s.pending == true and s.paused ~= true))
end

return utils
