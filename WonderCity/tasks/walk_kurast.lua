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

-- Stuck watchdog: if the player hasn't moved meaningfully for STUCK_WINDOW_S
-- while this task is the active executor, re-teleport to the town waypoint
-- to recover. Covers two failure modes seen in the wild:
--   1) Temis long-path: navigator reports navigating=true but A* is not
--      progressing (or we end up >5m from target with no movement).
--   2) Kurast waypoint follow: BatmobilePlugin gets caught on geometry and
--      can't reach the next path[] waypoint.
local STUCK_THRESHOLD_M    = 1.5
-- QQT_Warpigz_v3 WonderCity 2.2.6: 12 -> 20 s. Batmobile blacklists a failed
-- goal for 15 s (navigator failed_target_cooldown) and refuses set_target
-- near it meanwhile; a 12 s window re-teleported on a single give-up.
local STUCK_WINDOW_S       = 20.0
local RECOVERY_COOLDOWN_S  = 15.0
-- Live report: "TPs to the entrance 5 times in a row, then starts the run".
-- Standing still right after arrival (loading, route calculation, a
-- companion moving the player) re-armed the watchdog, and each recovery
-- teleported back to the same waypoint. At most MAX_RECOVERIES re-teleports
-- without real progress in between; after that the walk continues and the
-- stall is logged once.
local MAX_RECOVERIES       = 2
-- QQT_Warpigz_v3 WonderCity 2.2.6 (Undercity teleport storm review): the cap
-- never engaged for a stall away from the landing. The landing itself is a
-- move of > 1.5 m, and it reset `recoveries`, as did task.reset on every
-- world-key change: one re-teleport every ~20 s without bound (joint repro:
-- 5 casts, a permanent block 16-20). Now at most MAX_RECOVERIES re-teleports
-- per RECOVERY_WINDOW_S (rolling, kept across task.reset); the count clears
-- only when the walk really passed the stall point (Kurast: 3+ path nodes
-- beyond it; long path: STALL_PASSED_M closer to the target).
local RECOVERY_WINDOW_S    = 300
local STALL_PASSED_NODES   = 3
local STALL_PASSED_M       = 10
-- A drive Batmobile refuses (set_target false: inside its failed-goal radius
-- during the cooldown) is not stall time, up to REFUSED_CREDIT_MAX s per stall.
local REFUSED_CREDIT_MAX   = 30
-- No Batmobile drive during our own waypoint channel (a move cancels it).
local CAST_SPELL, CAST_CAP_S = 186139, 15
task.last_pos          = nil
task.last_pos_time     = 0
task.last_recovery     = -999
task.recoveries        = 0
task.recovery_times    = {}
task.stall             = nil  -- {key = path index} or {dist = m to the long-path target}
task.refused_credit    = 0
task.cast_since        = nil
task.last_exec         = nil

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

-- The walk got past the recorded stall: a new stall may recover again.
local function passed_stall(player_pos)
    local st = task.stall
    if not st then return false end
    if st.key then
        local k = closest_path_key(player_pos)
        return k ~= nil and k >= st.key + STALL_PASSED_NODES
    end
    local target = settings.town_long_path_target
    return st.dist ~= nil and target ~= nil and utils.distance(player_pos, target) <= st.dist - STALL_PASSED_M
end

local function reset_progress()
    task.last_pos      = nil
    task.last_pos_time = 0
end

-- Returns true if recovery fired (caller should bail out of the rest of
-- Execute for this tick).
local function watchdog(player_pos)
    local now = get_time_since_inject()
    local lp = get_local_player()
    local casting = lp and lp:get_active_spell_id() == 186139
    if task.stall and passed_stall(player_pos) then
        -- QQT_Warpigz_v3 WonderCity 2.2.6: only passing the stall point ends
        -- a stall episode (a landing or a walk back to it does not).
        task.stall, task.recovery_times, task.recoveries = nil, {}, 0
        task.recovery_cap_logged = nil
    end
    if task.last_pos == nil or casting
        or utils.distance(task.last_pos, player_pos) > STUCK_THRESHOLD_M
    then
        task.refused_credit = 0
        task.last_pos      = player_pos
        task.last_pos_time = now
        return false
    end
    if now - task.last_pos_time < STUCK_WINDOW_S then return false end
    if now - task.last_recovery < RECOVERY_COOLDOWN_S then return false end
    if recent_recoveries(now) >= MAX_RECOVERIES then
        if not task.recovery_cap_logged then
            task.recovery_cap_logged = true
            console.print(string.format(
                '[wonder_city walk_kurast] still not moving after %d re-teleports — no further teleports, walking on',
                task.recoveries))
        end
        return false
    end
    task.recovery_times[#task.recovery_times + 1] = now
    task.recoveries = #task.recovery_times
    task.last_recovery = now
    if settings.town_long_path_target then
        task.stall = {dist = utils.distance(player_pos, settings.town_long_path_target)}
    else
        task.stall = {key = closest_path_key(player_pos)}
    end
    console.print(string.format(
        '[wonder_city walk_kurast] stuck %.1fs near (%.1f,%.1f) — re-teleporting to town waypoint',
        now - task.last_pos_time, player_pos:x(), player_pos:y()))
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

-- Pick the "destination" position used to detect arrival in shouldExecute.
-- For long-path towns it's the configured target; for waypoint towns it's
-- the second-to-last waypoint (matches original behavior).
local function destination_proxy()
    if settings.town_long_path_target then
        return settings.town_long_path_target
    end
    return path[#path-1]
end

task.shouldExecute = function ()
    local local_player = get_local_player()
    if not local_player then return false end
    local player_pos = local_player:get_position()
    local brazier = utils.get_spirit_brazier()
    local portal = utils.get_entrance_portal()
    -- Yield at the same distance Execute considers "arrived" — otherwise the
    -- distance window (LONG_PATH_ARRIVED-1, LONG_PATH_ARRIVED] makes
    -- shouldExecute return true while Execute does nothing, blocking
    -- enter_undercity from taking over and walking the last few meters to
    -- the brazier.
    return utils.player_in_zone(settings.town_zone) and
        player_pos:x() ~= 0 and player_pos:y() ~= 0 and
        portal == nil and
        (brazier == nil and utils.distance(player_pos, destination_proxy()) > LONG_PATH_ARRIVED)
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
            reset_progress()
            return
        end
        if watchdog(player_pos) then return end
        if channelling(local_player, now) then return end -- QQT_Warpigz_v3 WonderCity 2.2.6
        BatmobilePlugin.resume(plugin_label)
        if not BatmobilePlugin.is_long_path_navigating() then
            if (now - task.last_long_path_attempt) < LONG_PATH_RETRY then return end
            task.last_long_path_attempt = now
            -- WCY-5: remember the autonomous route is ours to stop.
            if BatmobilePlugin.navigate_long_path(plugin_label, target) then utils.own_long_path = true end
        end
        task.status = status_enum['WALKING']
        return
    end

    -- Kurast (default): follow recorded data/path.lua waypoints sequentially.
    if watchdog(player_pos) then return end
    if channelling(local_player, now) then return end -- QQT_Warpigz_v3 WonderCity 2.2.6
    BatmobilePlugin.pause(plugin_label)
    local closest_key = closest_path_key(player_pos)
    if closest_key == nil then return end
    if path[closest_key+1] ~= nil then
        -- QQT_Warpigz_v3 WonderCity 2.2.6: a node Batmobile refuses (inside
        -- its failed-goal radius during the cooldown) is skipped for the next
        -- ones; if all are refused, that time is not stall time (bounded).
        local accepted = false
        local last = math.min(closest_key + 6, #path)
        for k = math.min(closest_key + 2, #path), last do
            if BatmobilePlugin.set_target(plugin_label, path[k]) ~= false then accepted = true; break end
        end
        if not accepted then
            if task.last_pos and task.refused_credit < REFUSED_CREDIT_MAX then
                task.refused_credit = task.refused_credit + dt
                task.last_pos_time = task.last_pos_time + dt
            end
            task.status = 'waiting for Batmobile (goal refused)'
            return
        end
    elseif path[closest_key] ~= nil and
        utils.distance(path[closest_key], player_pos) < 30
    then
        BatmobilePlugin.set_target(plugin_label, path[closest_key])
    else
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
        reset_progress()
        return
    end
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['WALKING']
end

-- C5: a preempted walk (Alfred, entry, ...) starts a fresh stuck window.
task.on_cancel = function ()
    reset_progress()
end

task.reset = function ()
    reset_progress()
    task.last_long_path_attempt = -math.huge
    -- QQT_Warpigz_v3 WonderCity 2.2.6: the recovery count, its stall point and
    -- cooldown survive a world-key change (rolling RECOVERY_WINDOW_S instead).
    task.refused_credit, task.cast_since, task.last_exec = 0, nil, nil
end

return task