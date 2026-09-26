local plugin_label = 'batmobile'
-- kept plugin label instead of waiting for update_tracker to set it
local navigator  = require 'core.navigator'
local explorer   = require 'core.explorer'
local tracker    = require 'core.tracker'
local utils      = require 'core.utils'
local long_path  = require 'core.long_path'
local pathfinder = require 'core.pathfinder'

local external = {
    name          = plugin_label
}

-- Ownership.  Batmobile is one shared navigator; every plugin used to write
-- tracker.external_caller and nothing read it, so a disabled plugin's goal,
-- long route or traversal routing steered the next plugin (live L10: Temis
-- `paused=true custom=true` pathfinding to a stale Arkham target).  Callers
-- are compared case-insensitively ('Reaper' and 'reaper' are one plugin).
local own = {
    target     = nil,          -- caller that last claimed the navigator goal
    pause      = nil,          -- caller of the last pause/resume/release
    pause_time = -math.huge,   -- time of the last explicit pause()
    priority   = nil,          -- caller that set a non-default explorer priority
}
-- Goal owner is mirrored into the tracker so the periodic [NAV STATE] perf
-- line shows who is steering (diagnoses stale-owner reports from live logs).
local function set_goal_owner(who)
    own.target = who
    tracker.movement_owner = who
end
-- The navigator samples trap positions for a paused caller only while that
-- caller drives its own long route (navigator.paused_trap_active).
local function set_pause_owner(who)
    own.pause = who
    navigator.pause_owner = who
end
local KEEP_PAUSE_WINDOW = 0.25  -- pause() then navigate_long_path() in one tick
local LOG_INTERVAL = 5          -- release/takeover diagnostics, per caller
local loading_logged = false
local last_log = {}
local function log_limited(key, message, interval)
    local now = get_time_since_inject()
    if last_log[key] ~= nil and now - last_log[key] < (interval or LOG_INTERVAL) then return end
    last_log[key] = now
    console.print(message)
end
local function default_priority()
    return explorer.default_priority or 'direction'
end
local function norm(caller)
    return string.lower(tostring(caller))
end
-- True while the navigator still works toward a caller's goal: a custom
-- target, a traversal route or escape that will restore one, or a long route.
local function holds_caller_goal()
    return navigator.is_custom_target == true or navigator.trav_final_target ~= nil
        or (navigator.post_trav_target ~= nil and navigator.post_trav_target.is_custom == true)
        or long_path.navigating
end
-- An explicit new goal claim (set_target, navigate_long_path,
-- try_traversal_route) by another caller replaces the previous owner's goal
-- or route: drop it (and its traversal routing / failed-target zone) before
-- acting.  move/update/resume never drop it (note_foreign).
local function drop_foreign(who, action)
    local route_owner = long_path.navigating and long_path.owner or nil
    local foreign_route = route_owner ~= nil and route_owner ~= who
    local foreign_goal = own.target ~= nil and own.target ~= who and holds_caller_goal()
    if not foreign_route and not foreign_goal then return false end
    log_limited('drop:' .. who, string.format('[batmobile] %s by %s: dropping movement left by %s',
        action, who, tostring(route_owner or own.target)))
    if long_path.navigating and route_owner ~= who then long_path.stop_navigation() end
    navigator.release_movement(true)
    set_goal_owner(nil)
    return true
end
-- move/resume by a different caller never drop the owner's goal or route: a
-- closed-source companion (Alfred, Looteer) driving Batmobile under its own
-- name would otherwise ping-pong the activity's goal every tick.  Only an
-- explicit claim (set_target, navigate_long_path, try_traversal_route)
-- replaces it, and the owner's release() clears it.  Logged (rate-limited)
-- so a live log shows the companion conflict.
local FOREIGN_LOG_INTERVAL = 30
local function note_foreign(who, action)
    local owner = long_path.navigating and long_path.owner or nil
    if owner == nil and holds_caller_goal() then owner = own.target end
    if owner == nil or owner == who then return end
    log_limited('foreign:' .. who, string.format(
        '[batmobile] %s by %s: goal of %s kept (replaced only by a new goal claim or its release)',
        action, who, owner), FOREIGN_LOG_INTERVAL)
end
-- World change / teleport resets explorer, trap and traversal state
-- (navigator.observe_world) and drops routes planned for the old world.
-- main.lua's pulse usually sees the change first; the navigator's world
-- generation lets goal/priority ownership follow that reset too (a stale
-- owner showed up in get_owner() and the [NAV STATE] owner= field).  A goal
-- set during the loading screen survives the reset and keeps its owner.
local world_generation = 0
local function sync_world()
    if navigator.world_generation == world_generation then return end
    world_generation = navigator.world_generation
    if not navigator.is_custom_target then set_goal_owner(nil) end
    own.priority = nil
end
local function observe_world()
    long_path.observe_world()
    sync_world()
end
-- Host world/actor data is incomplete while loading: external update/move
-- follow main.lua's guard instead of scanning/pathing on it.  One log line
-- per loading episode.
local function loading_skip(what, caller)
    if not utils.player_loading() then
        loading_logged = false
        return false
    end
    navigator.note_loading()
    if not loading_logged then
        loading_logged = true
        console.print('[batmobile] ' .. what .. ' by ' .. tostring(caller) ..
            ' skipped while the world is loading; explorer scans resume after the load')
    end
    return true
end
external.is_done = function ()
    return navigator.is_done()
end
external.is_paused = function ()
    return navigator.paused
end
external.pause = function (caller)
    if caller == nil then
        utils.log(2,'pause called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'pause called by ' .. tostring(caller))
    set_pause_owner(norm(caller))
    own.pause_time = get_time_since_inject()
    navigator.pause()
end
external.resume = function (caller)
    if caller == nil then
        utils.log(2,'resume called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'resume called by ' .. tostring(caller))
    local who = norm(caller)
    observe_world()
    -- Another caller's goal is kept (see note_foreign); the owner's release()
    -- or a new claim replaces it.
    note_foreign(who, 'resume')
    set_pause_owner(who)
    navigator.unpause()
end
external.reset = function (caller)
    if caller == nil then
        utils.log(2,'reset called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'reset called by ' .. tostring(caller))
    long_path.stop_navigation()
    navigator.reset()
    -- Full wipe: no explorer map of a previously left world comes back.
    navigator.world_cache = nil
    explorer.priority = default_priority()
    set_goal_owner(nil)
    own.priority = nil
end
-- reset_movement: clears movement/pathfinding state only; exploration history
-- (visited, backtrack, frontier) is preserved.  Use for mid-session interruptions.
external.reset_movement = function (caller)
    if caller == nil then
        utils.log(2,'reset_movement called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'reset_movement called by ' .. tostring(caller))
    long_path.stop_navigation()
    navigator.reset_movement()
    set_goal_owner(nil)
end
external.move = function (caller)
    if caller == nil then
        utils.log(2,'move called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'move called by ' .. tostring(caller))
    if loading_skip('move', caller) then return end
    observe_world()
    note_foreign(norm(caller), 'move')
    tracker.bench_start("total_move")
    local start_move = os.clock()
    navigator.move()
    tracker.timer_move = os.clock() - start_move
    tracker.bench_stop("total_move")
    tracker.bench_report()
end
external.update = function (caller)
    if caller == nil then
        utils.log(2,'update called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'update called by ' .. tostring(caller))
    if loading_skip('update', caller) then return end
    observe_world()
    tracker.bench_start("total_update")
    local start_update = os.clock()
    navigator.update()
    tracker.timer_update = os.clock() - start_update
    tracker.bench_stop("total_update")
end
external.set_target = function(caller, target, disable_spell)
    if caller == nil then
        utils.log(2,'set_target called with no caller')
        return false
    end
    tracker.external_caller = caller
    utils.log(2, 'set_target called by ' .. tostring(caller))
    local who = norm(caller)
    observe_world()
    drop_foreign(who, 'set_target')
    local accepted, detail = navigator.set_target(target, disable_spell)
    if accepted then set_goal_owner(who) end
    return accepted, detail
end
external.clear_target = function (caller)
    if caller == nil then
        utils.log(2,'clear_target called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'clear_target called by ' .. tostring(caller))
    navigator.clear_target()
end
external.get_backtrack = function(caller)
    if caller == nil then
        utils.log(2,'get_backtrack called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'get_backtrack called by ' .. tostring(caller))
    return explorer.backtrack
end
external.set_priority = function(caller, priority)
    if caller == nil then
        utils.log(2,'set_priority called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'set_priority called by ' .. tostring(caller) .. ' to priortize ' .. tostring(priority))
    explorer.set_priority(priority)
    own.priority = explorer.priority ~= default_priority() and norm(caller) or nil
end

-- Find a path without normal distance-scaled caps.
-- Returns path (array of vec3 nodes) or nil on failure.
-- Prints a result line to console automatically.
external.find_long_path = function(caller, target)
    if caller == nil then
        utils.log(2, 'find_long_path called with no caller')
        return nil
    end
    tracker.external_caller = caller
    utils.log(2, 'find_long_path called by ' .. tostring(caller))
    local player = get_local_player()
    if not player then return nil end
    local start = player:get_position()
    return long_path.find_long_path(start, target)
end

-- Find an uncapped path to target and immediately start walking it.
-- Returns true if path was found and navigation started, false otherwise.
external.navigate_long_path = function(caller, target)
    if caller == nil then
        utils.log(2, 'navigate_long_path called with no caller')
        return false
    end
    tracker.external_caller = caller
    utils.log(2, 'navigate_long_path called by ' .. tostring(caller))
    local who = norm(caller)
    observe_world()
    drop_foreign(who, 'navigate_long_path')
    -- pause() immediately followed by navigate_long_path() (HR recall,
    -- Arkham portal/anchor/orb/kill tasks) means the caller drives the route
    -- with move(): keep its pause.  Other callers (Reaper LONG_PATHING) rely
    -- on the historical unpause + autonomous drive in main.lua.
    local keep_pause = navigator.paused and own.pause == who
        and (get_time_since_inject() - own.pause_time) <= KEEP_PAUSE_WINDOW
    local started = long_path.navigate_to(target, keep_pause)
    if started then
        long_path.owner = who
        set_goal_owner(who)
    end
    return started
end

-- True while long path navigation is actively driving the navigator.
-- Auto-stops (returns false) at the goal — also for paused callers, whose
-- route main.lua never finishes — and when the navigator's target was cleared
-- externally (e.g. post-traversal-cross in attempt_escape) while navigating
-- was still true — this leaves navigator.target=nil every frame and the
-- caller stalls because it trusts this flag as "still in progress". Clearing
-- the flag lets callers retry navigate_long_path immediately.
external.is_long_path_navigating = function()
    local player = long_path.navigating and get_local_player() or nil
    if player ~= nil and long_path.reached_goal(player:get_position()) then
        console.print('[LONG PATH] Reached target (query) — stopping so the caller sees completion')
        long_path.stop_navigation()
        return false
    end
    if long_path.navigating and navigator.target == nil
        and not long_path.is_traversal_pending() then
        console.print('[LONG PATH] target cleared externally while navigating — auto-stopping so caller can repath')
        long_path.stop_navigation()
        return false
    end
    return long_path.navigating
end

-- Find a walkable, reachable approach node within max_dist of target.
-- Used by callers that need to path to an actor whose mesh sits on a non-walkable tile
-- (e.g. portals, gizmos). Returns vec3 of an approach node, or nil if nothing reachable.
external.get_closeby_node = function(caller, target, max_dist)
    if caller == nil then
        utils.log(2, 'get_closeby_node called with no caller')
        return nil
    end
    tracker.external_caller = caller
    if target == nil then return nil end
    if target.get_position then target = target:get_position() end
    return navigator.get_closeby_node(target, max_dist or 3)
end

-- Engage traversal routing if a usable Traversal_Gizmo is within 30 units.
-- Returns true if a traversal was engaged (caller should yield to nav until
-- crossing completes), false otherwise. Sets navigator.last_trav internally,
-- so subsequent BatmobilePlugin.update + move calls drive the crossing.
external.try_traversal_route = function(caller)
    if caller == nil then
        utils.log(2, 'try_traversal_route called with no caller')
        return false
    end
    tracker.external_caller = caller
    local local_player = get_local_player()
    if local_player == nil then return false end
    local who = norm(caller)
    observe_world()
    drop_foreign(who, 'try_traversal_route')
    local routed = navigator.try_traversal_route(local_player, local_player:get_position())
    if routed then set_goal_owner(who) end
    return routed and true or false
end

-- Returns true while navigator is mid-traversal-crossing (last_trav set).
-- cross_traversal task uses this to keep priority until the crossing finishes.
external.is_traversal_routing = function()
    return navigator.last_trav ~= nil
end

-- Stop long path navigation and clear the navigator target.
external.stop_long_path = function(caller)
    if caller == nil then
        utils.log(2, 'stop_long_path called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'stop_long_path called by ' .. tostring(caller))
    long_path.stop_navigation()
end

-- Returns the navigator's current target (vec3 or nil).
external.get_target = function()
    return navigator.target
end

-- Returns the navigator's current path (array of vec3, may be empty).
external.get_path = function()
    return navigator.path
end

-- Returns a snapshot of the most recent find_path call:
--   { call_id, status, plen, goal_x, goal_y }
-- call_id is monotonic — callers can detect "is this a new pathfind since I
-- last looked?" by comparing against a remembered id. Used by HR's remembered-
-- chest micro-partial detector to spot consistent A* failure on the same goal.
external.get_last_pathfind = function()
    return pathfinder.last_pathfind
end

-- Clear the traversal blacklist and failed-target state so previously crossed
-- traversals can be selected again.  Call this when the player is stuck on a
-- platform after a traversal and normal exploration has stalled.
external.clear_traversal_blacklist = function(caller)
    if caller == nil then
        utils.log(2, 'clear_traversal_blacklist called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'clear_traversal_blacklist called by ' .. tostring(caller))
    navigator.blacklisted_trav      = {}
    navigator.trav_delay            = nil
    navigator.failed_target         = nil
    navigator.failed_target_time    = -1
    navigator.failed_target_radius  = 15
    -- The 60 s global suppression set after a custom target's partial->full
    -- path is a traversal blacklist too; leaving it made every consumer's
    -- traversal recovery a silent no-op for up to a minute.
    navigator.all_trav_blocked_until = 0
end

-- Trap-recovery query.  Returns true once the navigator has been stuck in a
-- small bbox for TRAP_GIVEUP_TIMEOUT (60s) without escaping.  Calling plugin
-- (HelltideRevamped) should teleport the player away and call clear_giving_up
-- to reset the state for the new zone.
external.is_giving_up = function()
    return navigator.giving_up
end

-- Returns true while the navigator is actively running its escape routine
-- (cleared in-zone frontiers, routing to a traversal).  HR can use this to
-- avoid issuing competing set_target calls during recovery.
external.is_trapped = function()
    return navigator.trapped
end

-- Resets all trap-detection state (sample history, escape counter, giving_up
-- flag).  Call this after teleporting / leaving the trapped area so the next
-- zone starts with a fresh sliding window.
external.clear_giving_up = function(caller)
    if caller == nil then
        utils.log(2, 'clear_giving_up called with no caller')
        return
    end
    tracker.external_caller = caller
    utils.log(2, 'clear_giving_up called by ' .. tostring(caller))
    navigator.clear_trap_state()
end

-- Deterministic hand-off (C3).  Stops the caller's long route, drops its
-- goal plus all traversal-routing state (last_trav, trav_delay,
-- trav_final_target, escape/post-traversal goal, partial-path tracker),
-- pauses Batmobile and restores the default explorer priority.  Owned by
-- that caller: a route or goal another plugin claimed since, or a resume by
-- another caller, is left alone.  Never clears the native pathfinder path
-- (a companion may own movement).  The caller's failed-target zone and 60 s
-- portal-ledge traversal block survive a plain release (same plugin
-- resuming after a yield); another plugin claiming the navigator drops
-- them.  Exploration history is kept; reset() is the full wipe.
external.release = function (caller)
    if caller == nil then
        utils.log(2, 'release called with no caller')
        return false
    end
    tracker.external_caller = caller
    sync_world()
    local who = norm(caller)
    local route_owner = long_path.navigating and long_path.owner or nil
    local foreign_route = route_owner ~= nil and route_owner ~= who
    local foreign_goal = own.target ~= nil and own.target ~= who and holds_caller_goal()
    local foreign_resume = own.pause ~= nil and own.pause ~= who and not navigator.paused
    local changed = long_path.navigating or navigator.target ~= nil or navigator.last_trav ~= nil
        or navigator.trav_escape_pos ~= nil or not navigator.paused
    if long_path.navigating and not foreign_route then long_path.stop_navigation() end
    if not foreign_route and not foreign_goal then
        navigator.release_movement(false)
        set_goal_owner(nil)
        if not foreign_resume then
            set_pause_owner(who)
            navigator.pause()
        end
    end
    if own.priority == nil or own.priority == who then
        if explorer.priority ~= default_priority() then changed = true end
        explorer.priority = default_priority()
        own.priority = nil
    end
    if foreign_route or foreign_goal then
        log_limited('release:' .. who, '[batmobile] release by ' .. who .. ': movement now owned by ' ..
            tostring(route_owner or own.target) .. ' left untouched')
    elseif changed then
        log_limited('release:' .. who, '[batmobile] released by ' .. who ..
            (foreign_resume and ' (kept resume by ' .. tostring(own.pause) .. ')' or ''))
    end
    return true
end

-- Current movement owner (normalized caller of the active long route or of
-- the last accepted goal), or nil.
external.get_owner = function ()
    sync_world()
    if long_path.navigating and long_path.owner ~= nil then return long_path.owner end
    return own.target
end

return external