local plugin_label = 'wonder_city' -- change to your plugin name

local utils    = require 'core.utils'
local settings = require 'core.settings'
local path     = require 'data.path'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to spirit brazier',
    WAITING_RAVEN = 'waiting for SilentRaven', -- QQT_Warpigz_v3 WonderCity 2.2.4
}
local task = {
    name = 'walk_kurast', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = -1,
    debounce_timeout = 3,
    last_long_path_attempt = -999,
}

local LONG_PATH_RETRY    = 2.0  -- seconds between navigate_long_path retries on failure
local LONG_PATH_ARRIVED  = 5.0  -- meters from target to consider arrived

-- Stuck watchdog: if the walk makes no progress for STUCK_WINDOW_S while this
-- task is the active executor, re-teleport to the town waypoint to recover.
-- Covers two failure modes seen in the wild:
--   1) Temis long-path: navigator reports navigating=true but A* is not
--      progressing (or we end up >5m from target with no movement).
--   2) Kurast waypoint follow: BatmobilePlugin gets caught on geometry and
--      can't reach the next path[] waypoint.
-- QQT_Warpigz_v3 WonderCity 2.2.6 (review round 2026-09-28 16:30): progress,
-- not displacement. A goal flipping between two tied path points moved the
-- player 0.7 m back and forth (J1 freeze), and any oscillation wider than
-- 1.5 m hid a stall from a displacement watchdog. Progress is the monotonic
-- path index of the walk (Kurast) or a PROGRESS_M drop of the distance to the
-- destination (both modes).
local PROGRESS_M           = 2.0
-- 2.2.6: 12 -> 20 s. Batmobile blacklists a failed goal for 15 s
-- (navigator failed_target_cooldown) and refuses set_target near it
-- meanwhile; a 12 s window re-teleported on a single give-up.
local STUCK_WINDOW_S       = 20.0
local RECOVERY_COOLDOWN_S  = 15.0
-- Live report: "TPs to the entrance 5 times in a row, then starts the run".
-- At most MAX_RECOVERIES re-teleports per walk (2.2.6: the landing and a
-- world-key change no longer reset the count; it also stays within a rolling
-- RECOVERY_WINDOW_S across walks cut by a town trip). Once capped, the walk
-- hands off to Batmobile's long path to the destination (another route than
-- the recorded one) instead of re-driving the blocked node; logged once.
local MAX_RECOVERIES       = 2
local RECOVERY_WINDOW_S    = 300
local STALL_PASSED_NODES   = 3
-- A drive Batmobile refuses (set_target false: inside its failed-goal radius
-- during the cooldown) is not stall time, up to REFUSED_CREDIT_MAX s per stall.
local REFUSED_CREDIT_MAX   = 30
-- No Batmobile drive during our own waypoint channel (a move cancels it), nor
-- in the first RECOVERY_QUIET_S after our recovery cast (the host may report
-- the cast a pulse late).
local CAST_SPELL, CAST_CAP_S, RECOVERY_QUIET_S = 186139, 15, 1.5
task.last_recovery     = -999
task.recoveries        = 0
task.recovery_times    = {}
task.stall             = nil  -- {key = walk index at the recovery}
task.capped            = false
task.refused_credit    = 0
task.cast_since        = nil
task.last_exec         = nil
task.walk_idx          = nil
task.best_dist         = nil
task.progress_time     = nil

-- Pick the "destination" position used to detect arrival in shouldExecute.
-- For long-path towns it's the configured target; for waypoint towns it's
-- the second-to-last waypoint (matches original behavior).
local function destination_proxy()
    if settings.town_long_path_target then
        return settings.town_long_path_target
    end
    return path[#path-1]
end

local function recent_recoveries(now)
    local kept = {}
    for _, t in ipairs(task.recovery_times) do
        if now >= t and now - t < RECOVERY_WINDOW_S then kept[#kept + 1] = t end
    end
    task.recovery_times = kept
    task.recoveries = #kept
    return #kept
end

local function closest_path_key(player_pos)
    local best, key = nil, nil
    for k, point in ipairs(path) do
        local d = utils.distance(player_pos, point)
        if best == nil or d < best then best, key = d, k end
    end
    return key
end

-- 2.2.6: monotonic progress index of this walk. The closest point may flip
-- between two tied path points (octile distance); the walk index only moves
-- forward, and restarts only when the player is well behind it (a landing
-- at the town waypoint, a return from a town trip).
local function walk_index(player_pos)
    local k = closest_path_key(player_pos)
    if k == nil then return task.walk_idx end
    if task.walk_idx == nil or k < task.walk_idx - STALL_PASSED_NODES then
        task.walk_idx = k
        return k, true
    end
    if k > task.walk_idx then
        task.walk_idx = k
        return k, true
    end
    return task.walk_idx, false
end

local function reset_progress()
    task.best_dist, task.progress_time, task.refused_credit = nil, nil, 0
end

-- The walk is over (arrived, the brazier or the portal is there, a new run):
-- its recoveries and stall no longer count against the next walk.
local function end_walk()
    if task.stall or task.capped or #task.recovery_times > 0 or task.walk_idx then
        task.stall, task.capped, task.recovery_times, task.recoveries = nil, false, {}, 0
        task.recovery_cap_logged, task.long_fallback_logged = nil, nil
        task.walk_idx = nil
        if task.long_fallback and utils.own_long_path then
            utils.own_long_path = false
            BatmobilePlugin.stop_long_path(plugin_label)
        end
        task.long_fallback = false
    end
    reset_progress()
end

-- Returns true if recovery fired (caller should bail out of the rest of
-- Execute for this tick).
local function watchdog(player_pos, advanced)
    local now = get_time_since_inject()
    local lp = get_local_player()
    local casting = lp and lp:get_active_spell_id() == CAST_SPELL
    if task.stall and task.stall.key and task.walk_idx
        and task.walk_idx >= math.min(task.stall.key + STALL_PASSED_NODES, #path - 1)
    then
        -- 2.2.6: only walking past the stall point ends a stall episode
        -- (a landing or a walk back to it does not).
        task.stall, task.capped, task.recovery_times, task.recoveries = nil, false, {}, 0
        task.recovery_cap_logged = nil
    end
    local dist = utils.distance(player_pos, destination_proxy())
    if task.progress_time == nil or casting or advanced
        or (task.best_dist ~= nil and dist <= task.best_dist - PROGRESS_M)
    then
        task.refused_credit = 0
        task.best_dist = dist
        task.progress_time = now
        return false
    end
    if now - task.progress_time < STUCK_WINDOW_S then return false end
    if now - task.last_recovery < RECOVERY_COOLDOWN_S then return false end
    if task.capped or recent_recoveries(now) >= MAX_RECOVERIES then
        if not task.capped then
            task.capped = true
            console.print(string.format(
                '[wonder_city walk_kurast] still not moving after %d re-teleports — no further teleports; handing the walk to Batmobile\'s long path',
                task.recoveries))
        end
        return false
    end
    task.recovery_times[#task.recovery_times + 1] = now
    task.recoveries = #task.recovery_times
    task.last_recovery = now
    task.stall = {key = task.walk_idx}
    console.print(string.format(
        '[wonder_city walk_kurast] stuck %.1fs near (%.1f,%.1f) — re-teleporting to town waypoint (%d/%d)',
        now - task.progress_time, player_pos:x(), player_pos:y(), task.recoveries, MAX_RECOVERIES))
    utils.own_long_path = false
    BatmobilePlugin.stop_long_path(plugin_label)
    BatmobilePlugin.clear_target(plugin_label)
    BatmobilePlugin.reset(plugin_label)
    teleport_to_waypoint(settings.town_waypoint)
    reset_progress()
    return true
end

-- QQT_Warpigz_v3 WonderCity 2.2.6: our own recovery (or any) waypoint
-- channel: no pause/set_target/move/resume/navigate_long_path, which would
-- cancel it (as exit_undercity). Bounded to CAST_CAP_S per channel.
local function channelling(local_player, now)
    if now >= task.last_recovery and now - task.last_recovery < RECOVERY_QUIET_S then
        task.status = 'waiting for the teleport channel'
        return true
    end
    local ok, spell = pcall(function() return local_player:get_active_spell_id() end)
    if ok and spell == CAST_SPELL then
        task.cast_since = task.cast_since or now
        if now - task.cast_since < CAST_CAP_S then
            task.status = 'waiting for the teleport channel'
            return true
        end
        return false
    end
    task.cast_since = nil
    return false
end

-- Batmobile's autonomous long path to `target` (Temis mode, and Kurast once
-- the re-teleports are capped).
local function drive_long_path(target, now)
    BatmobilePlugin.resume(plugin_label)
    if not BatmobilePlugin.is_long_path_navigating() then
        if (now - task.last_long_path_attempt) < LONG_PATH_RETRY then return end
        task.last_long_path_attempt = now
        -- WCY-5: remember the autonomous route is ours to stop.
        if BatmobilePlugin.navigate_long_path(plugin_label, target) then utils.own_long_path = true end
    end
    task.status = status_enum['WALKING']
end

task.shouldExecute = function ()
    local local_player = get_local_player()
    if not local_player then return false end
    local player_pos = local_player:get_position()
    local brazier = utils.get_spirit_brazier()
    local portal = utils.get_entrance_portal()
    local in_town = utils.player_in_zone(settings.town_zone)
    -- Yield at the same distance Execute considers "arrived" — otherwise the
    -- distance window (LONG_PATH_ARRIVED-1, LONG_PATH_ARRIVED] makes
    -- shouldExecute return true while Execute does nothing, blocking
    -- enter_undercity from taking over and walking the last few meters to
    -- the brazier.
    local walking = in_town and
        player_pos:x() ~= 0 and player_pos:y() ~= 0 and
        portal == nil and
        (brazier == nil and utils.distance(player_pos, destination_proxy()) > LONG_PATH_ARRIVED)
    -- 2.2.6: in town and done walking (arrived / brazier / portal): the
    -- walk's recoveries do not count against the next one.
    if in_town and not walking then end_walk() end
    return walking
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = local_player:get_position()

    -- QQT_Warpigz_v3 WonderCity 2.2.4: hold while SilentRaven claims (the same
    -- hold as teleport_kurast / enter_undercity): no own long path or waypoint
    -- walk, a running own route is stopped, and the stuck watchdog does not
    -- count the claim. The claim itself is bounded by SilentRaven.
    if utils.raven_claim_active and utils.raven_claim_active() then
        if utils.own_long_path then
            utils.own_long_path = false
            BatmobilePlugin.stop_long_path(plugin_label)
        end
        if task.status ~= status_enum['WAITING_RAVEN'] then
            BatmobilePlugin.clear_target(plugin_label)
            task.status = status_enum['WAITING_RAVEN']
        end
        reset_progress()
        return
    end
    if task.status == status_enum['WAITING_RAVEN'] then task.status = status_enum['IDLE'] end
    local now = get_time_since_inject()
    local dt = task.last_exec and now - task.last_exec or 0
    if dt < 0 or dt > 1 then dt = 0 end
    task.last_exec = now

    -- Temis (or any town with a long_path_target): hand navigation off to
    -- BatmobilePlugin's uncapped A* and let it drive. No recorded waypoints.
    if settings.town_long_path_target then
        local target = settings.town_long_path_target
        if utils.distance(player_pos, target) <= LONG_PATH_ARRIVED then
            utils.own_long_path = false
            BatmobilePlugin.stop_long_path(plugin_label)
            BatmobilePlugin.clear_target(plugin_label)
            task.status = status_enum['IDLE']
            end_walk()
            return
        end
        if watchdog(player_pos, false) then return end
        if channelling(local_player, now) then return end -- QQT_Warpigz_v3 WonderCity 2.2.6
        drive_long_path(target, now)
        return
    end

    -- Kurast (default): follow recorded data/path.lua waypoints sequentially.
    local idx, advanced = walk_index(player_pos)
    if watchdog(player_pos, advanced) then return end
    if channelling(local_player, now) then return end -- QQT_Warpigz_v3 WonderCity 2.2.6
    if idx == nil then return end
    -- 2.2.6: capped -> another route: Batmobile's long path to the destination.
    if task.capped then
        if not task.long_fallback then
            task.long_fallback = true
            BatmobilePlugin.clear_target(plugin_label)
            task.last_long_path_attempt = -math.huge
        end
        drive_long_path(destination_proxy(), now)
        return
    end
    BatmobilePlugin.pause(plugin_label)
    local goal = nil
    if path[idx+2] ~= nil then goal = path[idx+2]
    elseif path[idx+1] ~= nil then goal = path[idx+1]
    elseif path[idx] ~= nil and utils.distance(path[idx], player_pos) < 30 then goal = path[idx]
    end
    if goal == nil then
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
        reset_progress()
        return
    end
    -- 2.2.6: one goal (the walk index's), no skipping: an accepted farther
    -- node clears Batmobile's failed-goal blacklist and re-drives the blocked
    -- one. A refused goal (Batmobile's 15 s cooldown) is not stall time.
    if BatmobilePlugin.set_target(plugin_label, goal) == false then
        if task.progress_time and task.refused_credit < REFUSED_CREDIT_MAX then
            task.refused_credit = task.refused_credit + dt
            task.progress_time = task.progress_time + dt
        end
        task.status = 'waiting for Batmobile (goal refused)'
        return
    end
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['WALKING']
end

-- C5: a preempted walk (Alfred, entry, ...) starts a fresh stuck window.
task.on_cancel = function ()
    reset_progress()
    if task.long_fallback and utils.own_long_path then
        utils.own_long_path = false
        BatmobilePlugin.stop_long_path(plugin_label)
    end
    task.long_fallback = false
end

task.reset = function (transition)
    reset_progress()
    task.last_long_path_attempt = -math.huge
    task.cast_since, task.last_exec = nil, nil
    -- 2.2.6: the recovery count, its stall point and cooldown survive the
    -- world-key changes of one walk (a landing, a town trip); a new run ends
    -- the walk.
    if transition == 'run' then end_walk() end
end

return task
