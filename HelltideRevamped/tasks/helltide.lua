local utils = require "core.utils"
local tracker = require "core.tracker"
local settings = require "core.settings"
local enums = require "data.enums"
local perf = require "core.perf"
local helltide_explorer = require "core.helltide_explorer"
local zone_overrides = require "data.zone_overrides"
local chest_targets = require "core.chest_targets"
local recovery = require "core.recovery"
local loot_guard = require "core.loot_guard"
-- Warplan / Farm mode and the Farm-mode Pandemonium rupture machine. Stored
-- on tracker (no new file-level locals: this chunk is at LuaJIT's limit).
tracker.hr_mode = require "core.hr_mode"
tracker.tear_event = require "core.hr_tear_event"
tracker.hr_cinder_run = require "core.hr_cinder_run" -- QQT_Warpigz_v3 (Q4): cinder run (Hell's Prize gate)
tracker.hr_watch = require "core.hr_watch" -- QQT_Warpigz_v3 3.3.3: bounds for the target walks, kills and events

local found_chest = nil
local found_chest_position = nil -- cached position so we can navigate even when actor unloads
local found_silent_chest_position = nil
local found_ore = nil
local found_herb = nil

-- Remembered chests: chests we saw but couldn't afford at the time
-- Key: "name_x_y" to deduplicate, Value: { name, cost, position (vec3), discovered_at }
local remembered_chests = {}
local remembered_chest_target = nil -- the key of the chest we're currently navigating to
local remembered_chest_long_path_started = false -- true after navigate_long_path fires once; prevents repeated expensive A* calls
local remembered_chest_long_path_ok = false      -- true if navigate_long_path succeeded (false = fell back to navigate_to)

-- "Unreachable from here" handling: when a chest is close in XY distance but
-- pathfinding can't route to it (e.g. blocked by a ledge — pathfinder fails
-- and any partial path scores worse than staying put because everything
-- moves AWAY from the chest), we temporarily blacklist the chest. The bot
-- returns to EXPLORE_HELLTIDE patrol and naturally moves elsewhere; once the
-- blacklist expires, the chest can be re-targeted from a different angle.
local chest_temp_blacklist = {}                    -- key -> expiry timestamp
local chest_blacklist_data = {}                    -- key -> {pos, expiry, name} for debug rendering
local CHEST_BLACKLIST_DURATION   = 60.0            -- seconds to skip a stuck chest
local CHEST_STUCK_WINDOW         = 12.0            -- no progress for this long = stuck
local CHEST_STUCK_PROGRESS       = 4.0             -- meters of distance reduction = "progress"
local CHEST_STUCK_RANGE          = 60.0            -- only stuck-detect when this close
                                                   -- (raised 35→60: 41u-away chest behind a ledge
                                                   -- oscillated indefinitely without entering the
                                                   -- 35u radius — the no-progress test is the real
                                                   -- "stuck on geometry" signal, distance gate just
                                                   -- needs to be wide enough to catch ledge cases)
-- Micro-partial detector: when the pathfinder repeatedly returns a 2-node
-- limit_partial for the same chest target, A* couldn't get close to the goal
-- in its time budget — almost always means the target is on the other side
-- of an unwalkable boundary (cliff/wall) with no traversal nearby. Faster
-- than the 12s no-progress detector for this specific failure mode.
local CHEST_MICROPARTIAL_THRESHOLD = 20            -- consecutive bad pathfinds before blacklist
local CHEST_MICROPARTIAL_PLEN_MAX  = 2             -- plen at or below this counts as "bad"
-- Once we're physically at the chest, we're channeling, not "stuck on geometry".
-- Suppress the no-progress / micro-partial blacklisters in this radius so a
-- monster interrupting the open animation doesn't wipe a reachable chest.
local CHEST_INTERACT_RANGE         = 6             -- meters: treat as "in interaction"
local CHEST_STUCK_COMBAT_RANGE     = 10            -- meters: refresh stuck window if a hostile is this close
-- When monsters are blocking a chest interaction, force orbwalker clear ON for
-- this long (overrides the >149-cinders gate) so they actually get killed.
-- Re-asserted every tick we still see blocking combat.
local CHEST_COMBAT_FORCE_CLEAR_DURATION = 5.0
-- Hard cap on consecutive combat-blocked time at a chest before we blacklist.
-- Without this, the combat-refresh branch can stall forever if the rotation
-- can't actually clear the mob (broken spec, glyph stone area, etc.).
local CHEST_COMBAT_BLOCK_LIMIT     = 25.0
local _chest_stuck_key      = nil
local _chest_stuck_t        = 0
local _chest_stuck_dist     = math.huge
local _chest_combat_block_t = nil    -- when combat first blocked the current chest
-- Micro-partial counter state (per-chest)
local _chest_micropartial_count   = 0
local _chest_micropartial_last_id = 0
local chest_interact_attempts = {}
local CHEST_INTERACT_ATTEMPT_LIMIT = 6

-- Long-path recall watchdogs (mirror Arkham kill_boss "remembered hunt"): single-
-- shot navigate_long_path used to permanently fall back to non-paused set_target
-- for the whole trip. With Batmobile not paused, navigator hijacks the custom
-- target with explorer frontier picks whenever A* fails, so the bot ping-pongs
-- between the chest and frontiers ~46u away until the trap detector gives up
-- the zone (logzewx: 60s trapped + helltide abandoned). Fix: pause Batmobile,
-- retry long-path every 2s, and blacklist the chest if either watchdog trips.
-- One table (not four locals): this chunk is at LuaJIT's 200-local limit and
-- move_to_remembered_chest was over the 50-upvalue margin.
local RECALL = {
    LONG_PATH_RETRY  = 2.0,  -- seconds between navigate_long_path attempts
    FAIL_THRESHOLD   = 3,    -- consecutive long_path returns=false → blacklist
    NO_PROGRESS_SECS = 25,   -- best-dist not improved by DELTA in this long → blacklist
    PROGRESS_DELTA   = 2.0,  -- meters of improvement to count as progress
    -- QQT_Warpigz_v3 3.3.3: within CHEST_INTERACT_RANGE but no closer than
    -- 2 m for this long (Batmobile refuses the chest cell): interact from
    -- here; the attempt limit then bounds it (the band had no bound).
    BAND_STALL_S     = 3.0,
    BAND_PROGRESS    = 0.5,
    OVERRIDE_PARK_S  = 45,   -- zone-override entry reached, no buff: release to search
}
local _recall_long_path_target   = nil
local _recall_path_issue_time    = -math.huge
local _recall_fail_count         = 0
local _recall_best_dist          = nil
local _recall_progress_time      = nil

local function recall_state_reset()
    _recall_long_path_target = nil
    _recall_path_issue_time  = -math.huge
    _recall_fail_count       = 0
    _recall_best_dist        = nil
    _recall_progress_time    = nil
end

local function chest_stuck_reset()
    _chest_stuck_key  = nil
    _chest_stuck_t    = 0
    _chest_stuck_dist = math.huge
    _chest_micropartial_count   = 0
    _chest_micropartial_last_id = 0
    _chest_combat_block_t       = nil
    recall_state_reset()
end

-- Farm-chest state: when a nearby chest needs <50 more cinders we stay in its 30-unit
-- circle killing monsters instead of wandering away.
local farm_chest_entry = nil  -- { name, cost, position } of the chest we're farming near

-- Farm-cinders roam patrol: evenly-spaced ring of points around the chest.
-- Cycled through when no monsters are visible, replacing Batmobile free-roam
-- which oscillates on its own backtrack path.
local farm_roam_points   = {}   -- array of vec3
local farm_roam_idx      = 1    -- which point we're heading to next
local farm_roam_built_for = nil -- chest pos used to build current ring (vec3 key)
local FARM_ROAM_RADIUS   = 22   -- ring radius in meters
local FARM_ROAM_COUNT    = 8    -- evenly-spaced points on the ring
local FARM_ROAM_ARRIVE   = 6    -- meters: close enough to advance to next point

local function build_farm_roam(chest_pos)
    farm_roam_points = {}
    for i = 0, FARM_ROAM_COUNT - 1 do
        local angle = (i / FARM_ROAM_COUNT) * 2 * math.pi
        local tx = chest_pos:x() + math.cos(angle) * FARM_ROAM_RADIUS
        local ty = chest_pos:y() + math.sin(angle) * FARM_ROAM_RADIUS
        local pt = vec3:new(tx, ty, chest_pos:z())
        pt = utility.set_height_of_valid_position(pt)
        farm_roam_points[#farm_roam_points + 1] = pt
    end
    -- Start at the point closest to the player to avoid a long initial run
    local player_pos = get_player_position()
    local best_i, best_d = 1, math.huge
    for i, pt in ipairs(farm_roam_points) do
        local d = player_pos:dist_to(pt)
        if d < best_d then best_i, best_d = i, d end
    end
    farm_roam_idx      = best_i
    farm_roam_built_for = chest_pos
end

local plugin_label = "helltide_revamped"
local movement_owned = false
local native_movement_owned = false

local function native_move(pos)
    native_movement_owned = true
    pathfinder.request_move(pos)
end

-- Throttle BatmobilePlugin.update+move to 10fps.
-- Batmobile has its own 50ms internal timeout, so calling at 16fps runs it every call.
-- Capping at 10fps halves the path-following CPU cost with no perceptible navigation loss.
-- Pass force=true immediately after set_target so the new path starts right away.
local bm_pulse_time     = -math.huge
local BM_PULSE_INTERVAL = 0.1  -- 10fps

local function bm_pulse(force)
    if not BatmobilePlugin then return end
    local now = get_time_since_inject()
    if not force and (now - bm_pulse_time) < BM_PULSE_INTERVAL then
        perf.inc("bm_pulse_throttled")
        return
    end
    bm_pulse_time = now
    movement_owned = true
    perf.inc(force and "bm_pulse_forced" or "bm_pulse_normal")
    perf.start("bm_pulse")
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
    perf.stop("bm_pulse", force and "force=true" or "force=false")
end

local was_dead = false
local ni = 1
local last_target_ni = nil -- track which waypoint we last sent to Batmobile to avoid redundant set_target calls
local WAYPOINT_LOOKAHEAD = 5 -- skip ahead 5 waypoints (~20m) so Batmobile gets a real long-distance target
local WAYPOINT_ARRIVAL_DIST = 8 -- consider waypoints "reached" within 8m — prevents stalling on exact points
local WAYPOINT_MAX_DIST = 50 -- if target waypoint is further than this, re-snap to nearest
local PATROL_STUCK_TIMEOUT = 5 -- seconds without progress before switching to free explore
local patrol_stuck_time = nil
local patrol_stuck_pos = nil
local patrol_free_explore = false
local patrol_free_explore_start = nil -- time when we entered free-explore mode

-- Patrol unreachable-waypoint detection (mirrors the chest-unreachability fix).
-- Two signals make a waypoint "unreachable" without waiting on the 5s stuck timer:
--   1) BatmobilePlugin.set_target returns false → waypoint sits in the failed_target
--      cooldown zone (25u radius from a previous partial-path no-progress give-up).
--   2) get_last_pathfind keeps returning plen<=2 limit_partial against this waypoint
--      → A* can't get within ~1m of it in its time budget (cliff/wall, no traversal).
-- Both signals advance ni by WAYPOINT_LOOKAHEAD; after PATROL_SKIP_TO_FREE_EXPLORE
-- consecutive skips we drop into FREE_EXPLORE so Batmobile's frontier explorer
-- (the same code path that makes ArkhamAsylum smooth) takes over.
local PATROL_MICROPARTIAL_THRESHOLD = 20 -- consecutive plen<=2 limit_partial pathfinds
local PATROL_MICROPARTIAL_PLEN_MAX  = 2
local PATROL_MICROPARTIAL_GOAL_TOL  = 3  -- meters: covers the ±1.5 randomize_waypoint jitter
local PATROL_SKIP_TO_FREE_EXPLORE   = 3  -- consecutive unreachable waypoints before falling back
local _patrol_micropartial_count   = 0
local _patrol_micropartial_last_id = 0
local _patrol_micropartial_ni      = nil
local _patrol_skip_count           = 0   -- consecutive ni skips this stuck-cluster

local CHEST_INTERACT_COOLDOWN  = 4.0   -- seconds between interact_object calls on the same chest
local last_chest_interact_time = -math.huge -- ensures first interact fires immediately

-- After a chest opens, hold position briefly so the player stays on top of the
-- drops while Looteer / pickup logic runs.  Without this, the state machine
-- transitions back to EXPLORE_HELLTIDE on the next tick and Batmobile drags
-- the player off the loot pile.
local CHEST_POST_OPEN_PAUSE = 3.0
local last_chest_open_time  = -math.huge
-- Cinder snapshot at interact time so we can verify success after the hold:
-- if cinders dropped, the open went through; if unchanged, the channel was
-- interrupted and we need to retry.
local pre_interact_cinders  = nil

-- Zone-exit recovery: when the player walks out of the helltide boundary
-- we navigate back instead of letting search_helltide teleport away.
local returning_to_helltide = false  -- true while navigating back to zone
local last_in_zone_pos      = nil    -- last confirmed in-zone position (used as return target)

-- Experimental-explorer arming: don't hand control to the grid-based explorer until
-- the player has actually engaged something in the zone.  After a teleport (search_helltide
-- or revive) the player spawns at the town's edge where helltide_explorer's grid covers
-- areas Batmobile can't reach, leaving the bot stuck.  Patrol the waypoints first; arm
-- on the first kill_monsters target, disarm on every fresh zone (re-)entry and on reset.
local experimental_armed       = false
local was_in_helltide_for_arm  = false  -- tracks the previous-tick is_in_helltide() value

-- Override-zone end-of-helltide latch.  The walk-to-entry guard (see Execute)
-- exists to drag the player to the helltide hot spot after WarPigs drops them
-- in an override zone like Skov_Celestia without the buff yet.  But once the
-- buff has been seen in that zone, a subsequent buff drop means the helltide
-- *ended* there, not "haven't entered yet" — re-walking to entry sends us
-- 4000+u to a dead zone and Batmobile stalls on a partial path while spike
-- traps shred HP.  Latch the first buff sighting in the override zone; once
-- set, suppress the entry-walk and let shouldExecute hand off to
-- search_helltide so it can teleport us to town and find the next zone.
-- Cleared whenever zone_overrides.get_current() returns nil (we left the
-- override zone) and on plugin reset.
local override_buff_seen       = false

-- Trap-recovery escalation: when Batmobile signals giving_up (60s of trapped
-- state with no escape), abandon this zone and let search_helltide pick a new
-- one.  Tracked so we don't fire the bail-out repeatedly on consecutive ticks.
local force_zone_change = false  -- HR sets when Batmobile gives up; cleared on reset/zone-change

-- No-waypoints fallback: WarPigs (and potentially other external triggers) can
-- teleport us into a Helltide zone whose `region` prefix isn't in
-- `enums.helltide_tps` (e.g. `Skov_Celestia`).  In that case
-- `check_and_load_waypoints()` is a no-op, `tracker.waypoints` stays empty,
-- and the state machine pingpongs INIT ↔ EXPLORE_HELLTIDE.  When detected, we
-- fall back to the experimental_explorer's grid-coverage so we can still farm
-- the zone with no waypoint file.  Cleared on reset / zone re-entry.
local no_waypoint_region        = false
local no_waypoint_logged_zone   = nil   -- last zone string we logged the fallback for, to dedup spam


local TRAVERSAL_RECOVERY_TIMEOUT  = 10 -- seconds in free-explore before clearing traversal blacklist (increased: Batmobile now handles traversals via partial paths + destination-aware selection)
local TRAVERSAL_RECOVERY_COOLDOWN = 20 -- minimum seconds between recovery attempts
local traversal_recovery_time = nil    -- wall-clock of last triggered recovery

-- Descent lock: when stranded on a platform with a down-traversal nearby, recovery
-- drives the player straight to that traversal. Batmobile's select_target() rejects
-- traversals more than 3m off the player's Z, so we must target it ourselves and
-- call interact_object once close — Batmobile's last_trav stays nil under a custom
-- target, so its built-in interaction at line 539 of navigator.lua never fires.
local DESCENT = {
    TIMEOUT          = 15, -- seconds before giving up on a descent
    Z_DELTA          = 2,  -- min Z drop to consider a traversal "down"
    DONE_DROP        = 3,  -- player Z drop that confirms descent succeeded
    MAX_DIST         = 30, -- max XY dist to consider a down-traversal
    INTERACT_RANGE   = 3,  -- distance at which to interact_object the gizmo
    INTERACT_COOLDOWN = 1, -- min seconds between interact_object calls
}
local descent_actor      = nil         -- traversal gizmo we're descending through
local descent_start_z    = nil         -- player Z when descent started
local descent_until      = nil         -- wall-clock safety timeout
local descent_approach   = nil         -- vec3 walkable approach node
local descent_last_set   = -math.huge  -- last time we (re-)asserted approach as target
local descent_last_inter = -math.huge  -- last interact_object call time

-- ============================================================
-- Movement helpers: BatmobilePlugin with pathfinder fallback
-- ============================================================

local function move_to(target, disable_spell)
    if BatmobilePlugin then
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.set_target(plugin_label, target, disable_spell or false)
        bm_pulse(true)
    else
        local pos = target
        if type(target) ~= "userdata" or (target.get_position and target:get_position()) then
            if target.get_position then
                pos = target:get_position()
            end
        end
        native_move(pos)
    end
end

-- Returns true if the target was accepted by Batmobile, false if rejected
-- (waypoint sits inside Batmobile's failed_target cooldown zone). Callers
-- use the return value to advance ni / fall back to free-explore instead of
-- pinning patrol on an unreachable waypoint.
local function patrol_move(waypoint)
    if BatmobilePlugin then
        BatmobilePlugin.resume(plugin_label)
        local accepted = BatmobilePlugin.set_target(plugin_label, waypoint, false)
        bm_pulse(true)
        return accepted ~= false
    else
        native_move(waypoint)
        return true
    end
end

-- Navigate long-range: Batmobile resumed so it handles traversals + pathfinding
-- If Batmobile can't path to the target (unreachable, e.g. on a cliff), enter
-- free-explore mode so Batmobile discovers traversals on its own.
local navigate_to_stuck_time = nil
local navigate_to_free_explore = false -- when true, don't set custom target
local navigate_to_free_explore_start = nil -- time when we entered free-explore
local navigate_to_free_explore_target = nil -- caller's target when we entered free-explore;
                                             -- if it shifts >FREE_EXPLORE_RETARGET_DIST while we're stuck
                                             -- (helltide_explorer skipped a node), exit free-explore so
                                             -- the new target is actually attempted
local FREE_EXPLORE_RETARGET_DIST = 10

local try_traversal_recovery  -- forward declaration; defined after reset_navigate_state
local trav_blacklist = {} -- shared by recovery and traversal selection below

local navigate_to_debug_time = 0
local navigate_to_start_pos = nil -- position when stuck timer started
local navigate_to_last_target = nil -- last target passed to set_target; avoid redundant calls that clear Batmobile's path
local navigate_to_last_set_time = -math.huge -- wall-clock of last set_target call
local NAVIGATE_TO_DIVERGE_COOLDOWN = 2.0 -- seconds before re-asserting same target after bm_diverged (limits A* spam on unreachable targets)
-- Track consecutive re-assertions after bm_diverged without the player getting closer.
-- Fires helltide_explorer.report_intermediate_fail() after this many failed re-asserts.
local navigate_to_reassert_fails = 0
local navigate_to_reassert_last_dist = nil
local NAVIGATE_TO_REASSERT_LIMIT = 4  -- ~8s of re-assertion with no progress → skip node
local NAVIGATE_TO_REASSERT_PROGRESS = 8 -- metres closer to target required to reset the counter

local function navigate_to(target)
    perf.start("navigate_to")
    if BatmobilePlugin then
        BatmobilePlugin.resume(plugin_label)
        local now = get_time_since_inject()
        local player_pos = get_player_position()

        -- Throttled debug every 1s
        local should_log = settings.debug_log and (now - navigate_to_debug_time > 1) -- QQT_Warpigz_v3 2.6.4
        if should_log then
            navigate_to_debug_time = now
            local stuck_elapsed = navigate_to_stuck_time and (now - navigate_to_stuck_time) or 0
            local moved = navigate_to_start_pos and player_pos:dist_to(navigate_to_start_pos) or 0
            console.print(string.format("[NAV] mode=%s stuck=%.1fs moved=%.1f paused=%s done=%s",
                navigate_to_free_explore and "FREE_EXPLORE" or "CUSTOM_TARGET",
                stuck_elapsed, moved,
                tostring(BatmobilePlugin.is_paused()),
                tostring(BatmobilePlugin.is_done())))
        end

        if navigate_to_free_explore then
            -- Track how long we've been in free-explore
            if navigate_to_free_explore_start == nil then
                navigate_to_free_explore_start = now
            end

            -- Caller-target-changed exit: if helltide_explorer skipped its stuck node and
            -- is now asking for a different intermediate, the old free-explore session is
            -- chasing the wrong goal. Drop free-explore so the next normal-mode tick
            -- routes to the new target. Without this, navigate_to ignores caller updates
            -- until the player physically moves >15m, leaving Batmobile thrashing on its
            -- own (unreachable) frontier picks.
            if not (descent_actor ~= nil) and navigate_to_free_explore_target ~= nil then
                local target_pos_check = target
                if type(target) == "userdata" and target.get_position then
                    target_pos_check = target:get_position()
                end
                if target_pos_check and target_pos_check.dist_to then
                    local shift = navigate_to_free_explore_target:dist_to(target_pos_check)
                    if shift > FREE_EXPLORE_RETARGET_DIST then
                        console.print(string.format(
                            "[NAV] FREE_EXPLORE: caller target shifted %.1fm — exiting to retry new target",
                            shift))
                        navigate_to_free_explore         = false
                        navigate_to_free_explore_start   = nil
                        navigate_to_free_explore_target  = nil
                        navigate_to_stuck_time           = nil
                        navigate_to_start_pos            = nil
                        descent_actor    = nil
                        descent_start_z  = nil
                        descent_until    = nil
                        descent_approach = nil
                        -- Fall through to normal mode below
                        goto free_explore_exited
                    end
                end
            end

            -- Active descent: drive the player to a known down-traversal and interact
            -- with it directly. Lock prevents re-entry into try_traversal_recovery and
            -- keeps the approach-node target re-asserted if Batmobile drifts.
            if descent_actor ~= nil then
                local zdrop = (descent_start_z or player_pos:z()) - player_pos:z()
                if zdrop >= DESCENT.DONE_DROP then
                    console.print(string.format(
                        "[TRAVERSAL RECOVERY] Descent confirmed (z drop %.1fm) — exiting free-explore",
                        zdrop))
                    descent_actor    = nil
                    descent_start_z  = nil
                    descent_until    = nil
                    descent_approach = nil
                    navigate_to_free_explore        = false
                    navigate_to_stuck_time          = nil
                    navigate_to_start_pos           = nil
                    navigate_to_free_explore_start  = nil
                    navigate_to_free_explore_target = nil
                    perf.stop("navigate_to")
                    return
                elseif descent_until ~= nil and now > descent_until then
                    console.print("[TRAVERSAL RECOVERY] Descent timed out — releasing lock")
                    descent_actor    = nil
                    descent_start_z  = nil
                    descent_until    = nil
                    descent_approach = nil
                else
                    local trav_pos = descent_actor:get_position()
                    if trav_pos and player_pos:dist_to(trav_pos) <= DESCENT.INTERACT_RANGE
                        and (now - descent_last_inter) >= DESCENT.INTERACT_COOLDOWN
                    then
                        descent_last_inter = now
                        console.print(string.format(
                            "[TRAVERSAL RECOVERY] Interacting with down-traversal %s",
                            descent_actor:get_skin_name()))
                        interact_object(descent_actor)
                    elseif descent_approach ~= nil then
                        local bm_current = BatmobilePlugin.get_target and BatmobilePlugin.get_target()
                        local diverged = bm_current == nil
                            or bm_current:dist_to(descent_approach) > 2
                        if diverged and (now - descent_last_set) >= 1.0 then
                            descent_last_set = now
                            BatmobilePlugin.set_target(plugin_label, descent_approach, false)
                        end
                    end
                end
            end

            bm_pulse()

            -- If stuck in free-explore too long, clear traversal blacklist so Batmobile
            -- can use a nearby traversal to escape the platform
            if now - navigate_to_free_explore_start > TRAVERSAL_RECOVERY_TIMEOUT then
                if try_traversal_recovery(now) then
                    navigate_to_free_explore_start = now  -- reset so we don't spam-call
                end
            end

            -- Check if player has actually moved significantly from where we got stuck
            if navigate_to_start_pos and player_pos:dist_to(navigate_to_start_pos) > 15 then
                console.print("[NAV] Moved >15 units in free explore, re-trying target")
                navigate_to_free_explore = false
                navigate_to_stuck_time = nil
                navigate_to_start_pos = nil
                navigate_to_free_explore_start = nil
                navigate_to_free_explore_target = nil
                descent_actor    = nil
                descent_start_z  = nil
                descent_until    = nil
                descent_approach = nil
            end
            perf.stop("navigate_to")
            return
        end
        ::free_explore_exited::

        -- Normal mode: set custom target only when it changes to avoid clearing Batmobile's
        -- active path on every frame (which forces a costly find_path call each time).
        local target_pos = target
        if type(target) == "userdata" and target.get_position then
            target_pos = target:get_position()
        end
        -- Also re-set if Batmobile has drifted to a different internal target.
        -- This happens when Batmobile reaches the goal and the explorer picks a new frontier:
        -- navigate_to_last_target still equals the original position so target_changed is false,
        -- but Batmobile is now driving toward the frontier instead of our desired target.
        -- Rate-limit re-assertion on diverge: pathfind failures also cause bm_diverged (Batmobile
        -- picks a fallback after failing), and hammering set_target resets pathfind_fail_count to 0
        -- every frame, causing continuous 350ms A* runs.  Only re-assert on diverge after a cooldown.
        local bm_current = BatmobilePlugin.get_target and BatmobilePlugin.get_target()
        local bm_diverged = bm_current == nil or bm_current:dist_to(target_pos) > 2
        local diverge_ready = (now - navigate_to_last_set_time) >= NAVIGATE_TO_DIVERGE_COOLDOWN
        -- Threshold >6 (not >1) so small intermediate drifts from AltClick movement don't
        -- bypass the diverge cooldown — each click moves the player ~4-6m which shifts the
        -- cached intermediate, but that shouldn't count as a genuinely new target.
        local target_changed = navigate_to_last_target == nil
            or navigate_to_last_target:dist_to(target_pos) > 6
            or (bm_diverged and diverge_ready)
        if target_changed then
            navigate_to_last_target = target_pos
            navigate_to_last_set_time = now
            -- Re-assertion failure tracking: when Batmobile diverged (pathfind fail) and we
            -- re-assert the helltide_explorer intermediate, count how many times we do this
            -- without the player getting meaningfully closer to the target.  After
            -- NAVIGATE_TO_REASSERT_LIMIT re-asserts with no real progress, tell helltide_explorer
            -- to skip the node so we don't oscillate forever on an unreachable intermediate.
            -- "target_changed due to diverge" = bm_diverged AND we had a previous target
            -- (navigate_to_reassert_last_dist ~= nil).  First-time calls are excluded.
            if bm_diverged and diverge_ready and navigate_to_reassert_last_dist ~= nil then
                local dist_now = player_pos:dist_to(target_pos)
                if navigate_to_reassert_last_dist - dist_now < NAVIGATE_TO_REASSERT_PROGRESS then
                    navigate_to_reassert_fails = navigate_to_reassert_fails + 1
                    console.print(string.format(
                        "[NAV] reassert fail #%d/%d dist=%.1f (was %.1f, need -%dm progress)",
                        navigate_to_reassert_fails, NAVIGATE_TO_REASSERT_LIMIT,
                        dist_now, navigate_to_reassert_last_dist, NAVIGATE_TO_REASSERT_PROGRESS))
                    if navigate_to_reassert_fails >= NAVIGATE_TO_REASSERT_LIMIT then
                        console.print(string.format(
                            "[NAV] intermediate unreachable after %d re-asserts (dist=%.1f) — skipping explorer node",
                            navigate_to_reassert_fails, dist_now))
                        navigate_to_reassert_fails = 0
                        navigate_to_reassert_last_dist = nil
                        helltide_explorer.report_intermediate_fail()
                        perf.stop("navigate_to")
                        return
                    end
                else
                    navigate_to_reassert_fails = 0
                end
                navigate_to_reassert_last_dist = dist_now
            else
                -- Genuine target change (not a diverge re-assert) — reset counter
                if not bm_diverged then
                    navigate_to_reassert_fails = 0
                end
                navigate_to_reassert_last_dist = player_pos:dist_to(target_pos)
            end
            BatmobilePlugin.set_target(plugin_label, target, false)
        end
        bm_pulse(target_changed)

        -- Detect stuck by actual position change (not speed — speed spikes from failed pathing)
        if navigate_to_stuck_time == nil then
            navigate_to_stuck_time = now
            navigate_to_start_pos = player_pos
        else
            local dist_moved = player_pos:dist_to(navigate_to_start_pos)
            if dist_moved > 5 then
                -- Actually made real progress (not just drift), reset timer
                navigate_to_stuck_time = now
                navigate_to_start_pos = player_pos
            elseif now - navigate_to_stuck_time > 4 then
                -- Hasn't moved >5 units in 4 seconds — stuck
                console.print(string.format("[NAV] Stuck 4s (moved only %.1f), switching to FREE_EXPLORE", dist_moved))
                BatmobilePlugin.clear_target(plugin_label)
                navigate_to_free_explore = true
                navigate_to_free_explore_target = navigate_to_last_target -- capture before clearing
                navigate_to_stuck_time = nil
                navigate_to_last_target = nil
                -- Keep navigate_to_start_pos so free explore can detect when we've moved away
            end
        end
    else
        local pos = target
        if target.get_position then
            pos = target:get_position()
        end
        native_move(pos)
    end
    perf.stop("navigate_to")
end

-- Reset navigate_to state (call when switching away from navigate_to usage)
local function reset_navigate_state()
    navigate_to_stuck_time = nil
    navigate_to_start_pos = nil
    navigate_to_free_explore = false
    navigate_to_free_explore_start = nil
    navigate_to_free_explore_target = nil
    navigate_to_last_target = nil
    navigate_to_last_set_time = -math.huge
    navigate_to_reassert_fails = 0
    navigate_to_reassert_last_dist = nil
    descent_actor    = nil
    descent_start_z  = nil
    descent_until    = nil
    descent_approach = nil
end

-- Traversal recovery: called when the player has been stuck in free-explore mode
-- for TRAVERSAL_RECOVERY_TIMEOUT seconds without moving.  Clears Batmobile's
-- traversal blacklist + failed-target so a nearby traversal can be selected.
-- If a DOWN-traversal exists nearby, engages a descent lock that drives the
-- player to it directly (Batmobile's select_target rejects traversals more
-- than 3m off the player's Z, so we have to do it ourselves).  Otherwise falls
-- back to clearing the target and letting Batmobile pick.  Returns true if
-- recovery was triggered.
try_traversal_recovery = function(now)
    -- Already locked into a descent — let the free-explore branch keep driving it
    if descent_actor ~= nil then
        return false
    end
    if traversal_recovery_time and now - traversal_recovery_time < TRAVERSAL_RECOVERY_COOLDOWN then
        return false
    end
    if not BatmobilePlugin then return false end

    -- Stamp the cooldown FIRST so a crash below can never cause a spam-loop
    traversal_recovery_time = now

    console.print("[TRAVERSAL RECOVERY] Stuck on platform — clearing traversal blacklist + failed-target")
    if BatmobilePlugin.clear_traversal_blacklist then
        BatmobilePlugin.clear_traversal_blacklist(plugin_label)
    end
    trav_blacklist = {}  -- also clear helltide's own traversal blacklist

    -- Classify nearby traversals by Z-delta to player. A DOWN-traversal (more
    -- than DESCENT.Z_DELTA below player) is the escape route from an
    -- isolated platform; track the nearest one separately so we can drive to
    -- it even when select_target's ±3m Z filter would reject it.
    local actors = actors_manager:get_all_actors()
    local player_pos = get_player_position()
    local player_z = player_pos:z()
    local nearest_down      = nil
    local nearest_down_dist = math.huge
    local nearest_any       = nil
    local nearest_any_dist  = math.huge
    for _, actor in pairs(actors) do
        if actor:get_skin_name():match('[Tt]raversal_Gizmo') then
            local tpos = actor:get_position()
            local d = utils.distance_to(tpos)
            if d < nearest_any_dist then
                nearest_any = actor
                nearest_any_dist = d
            end
            if (player_z - tpos:z()) > DESCENT.Z_DELTA
                and d < DESCENT.MAX_DIST
                and d < nearest_down_dist
            then
                nearest_down = actor
                nearest_down_dist = d
            end
        end
    end

    BatmobilePlugin.resume(plugin_label)

    if nearest_down ~= nil then
        local tpos = nearest_down:get_position()
        local approach = BatmobilePlugin.get_closeby_node
            and BatmobilePlugin.get_closeby_node(plugin_label, tpos, 3)
            or nil
        console.print(string.format(
            "[TRAVERSAL RECOVERY] Down-traversal %s dist=%.1f drop=%.1fm — engaging descent lock%s",
            nearest_down:get_skin_name(),
            nearest_down_dist,
            player_z - tpos:z(),
            approach and "" or " (no walkable approach found, targeting gizmo pos)"))
        descent_actor      = nearest_down
        descent_start_z    = player_z
        descent_until      = now + DESCENT.TIMEOUT
        descent_approach   = approach or tpos
        descent_last_set   = now
        descent_last_inter = -math.huge
        BatmobilePlugin.set_target(plugin_label, descent_approach, false)
    elseif nearest_any ~= nil and nearest_any_dist < 50 then
        console.print(string.format(
            "[TRAVERSAL RECOVERY] Nearest traversal %s dist=%.1f (no down-traversal in range) — clearing target, letting Batmobile self-route via select_target",
            nearest_any:get_skin_name(), nearest_any_dist))
        -- Do NOT set_target to the raw gizmo position: it is a non-walkable cell, so
        -- pathfinding fails, the traversal area gets blacklisted in explorer.visited,
        -- and failed_target is set — undoing the recovery.
        -- clear_target lets navigator.move()'s "no target" branch call select_target(),
        -- which uses get_closeby_node() to find a proper walkable approach cell.
        BatmobilePlugin.clear_target(plugin_label)
    else
        console.print("[TRAVERSAL RECOVERY] No traversal nearby — resetting Batmobile movement (exploration preserved)")
        BatmobilePlugin.reset_movement(plugin_label)
    end
    bm_pulse(true)

    return true
end

local function clear_movement()
    reset_navigate_state()
    -- The patrol goal is dropped below, so patrol must re-issue it when it
    -- resumes (after a Looter/Alfred yield a paused Batmobile without a goal
    -- never moves and the 5 s patrol-stuck timer would fire instead).
    last_target_ni = nil
    if BatmobilePlugin and movement_owned then
        if BatmobilePlugin.stop_long_path then BatmobilePlugin.stop_long_path(plugin_label) end
        BatmobilePlugin.clear_target(plugin_label)
        BatmobilePlugin.pause(plugin_label)
    end
    movement_owned = false
    if native_movement_owned then
        if not loot_guard.companion_may_own_movement() then
            pathfinder.clear_stored_path()
        end
        native_movement_owned = false
    end
end

-- Mark a chest as just-opened: stamps the post-open pause timer and pauses
-- Batmobile so the player doesn't drift off the drops.  Execute() honors the
-- timer at the top of its tick and short-circuits movement until it expires.
-- Also stops any active long-path navigation: Batmobile's main_pulse drives
-- navigator.update/move autonomously while long_path.navigating is true,
-- which keeps repathing during our hold and pulls the player away from the
-- chest (logzewx: pathfinding to (2975.5,-1289) every 100ms despite HR not
-- calling bm_pulse — that's main_pulse driving long_path navigation).
local function mark_chest_opened()
    last_chest_open_time = get_time_since_inject()
    if BatmobilePlugin then
        if BatmobilePlugin.stop_long_path then
            BatmobilePlugin.stop_long_path(plugin_label)
        end
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.clear_target(plugin_label)
    end
    reset_navigate_state()
end

-- ============================================================

local helltide_state = {
    INIT = "INIT",
    EXPLORE_HELLTIDE = "EXPLORE_HELLTIDE",
    MOVING_TO_TRAVERSAL = "MOVING_TO_TRAVERSAL",
    MOVING_TO_PYRE = "MOVING_TO_PYRE",
    INTERACT_PYRE = "INTERACT_PYRE",
    STAY_NEAR_PYRE = "STAY_NEAR_PYRE",
    MOVING_TO_HELLTIDE_CHEST = "MOVING_TO_HELLTIDE_CHEST",
    MOVING_TO_SILENT_CHEST = "MOVING_TO_SILENT_CHEST",
    MOVING_TO_ORE = "MOVING_TO_ORE",
    MOVING_TO_HERB = "MOVING_TO_HERB",
    MOVING_TO_SHRINE = "MOVING_TO_SHRINE",
    MOVING_TO_CHAOS_RIFT = "MOVING_TO_CHAOS_RIFT",
    INTERACT_CHAOS_RIFT = "INTERACT_CHAOS_RIFT",
    STAY_NEAR_CHAOS_RIFT = "STAY_NEAR_CHAOS_RIFT",
    CHASE_GOBLIN = "CHASE_GOBLIN",
    KILL_MONSTERS = "KILL_MONSTERS",
    MOVING_TO_REMEMBERED_CHEST = "MOVING_TO_REMEMBERED_CHEST",
    FARM_CHEST_CINDERS = "FARM_CHEST_CINDERS",
    BACK_TO_TOWN = "BACK_TO_TOWN",
    RETURN_TO_HELLTIDE = "RETURN_TO_HELLTIDE",
    MOVING_TO_MAIDEN = "MOVING_TO_MAIDEN",
    AT_MAIDEN = "AT_MAIDEN",
    -- Pandemonium ruptures (Farm mode, core/hr_tear_event.lua)
    MOVING_TO_RIFT = "MOVING_TO_RIFT",
    RIFT_KILL_GUARDS = "RIFT_KILL_GUARDS",
    RIFT_WAIT_OPEN = "RIFT_WAIT_OPEN",
    RIFT_CLOSE_TEARS = "RIFT_CLOSE_TEARS",
    RIFT_STAY_ACTIVE = "RIFT_STAY_ACTIVE",
    RIFT_OPEN_CHEST = "RIFT_OPEN_CHEST",
    RIFT_WAIT_REALMWALKER = "RIFT_WAIT_REALMWALKER",
    RIFT_KILL_REALMWALKER = "RIFT_KILL_REALMWALKER",
    RIFT_ENTER_CHAMBER = "RIFT_ENTER_CHAMBER",
    CHAMBER_START_RITUAL = "CHAMBER_START_RITUAL",
    CHAMBER_CLOSE_TEARS = "CHAMBER_CLOSE_TEARS",
    CHAMBER_STAY_ACTIVE = "CHAMBER_STAY_ACTIVE",
    CHAMBER_EXIT = "CHAMBER_EXIT",
}

-- ── Maiden state (do_maiden setting) ────────────────────────────────────────
-- Tunables and module-local state for the maiden lock-on. The actual helper
-- functions (find_maiden_altar, should_do_maiden) are defined further down —
-- AFTER get_cached_actors — because Lua resolves forward references to locals
-- as nil-globals at function-definition time.
--
-- Mechanic the bot mirrors (per user spec):
--   * 3 altars exist at the maiden site
--   * Insert 1 heart at any altar → that altar disappears (or goes
--     non-interactable). Walk to next altar, insert, repeat.
--   * After all 3 hearts placed (across all players in the pile) the maiden
--     boss spawns. Stay in the lock zone, kill her + adds, then resume
--     inserting once altars come back.
-- We do NOT cap hearts inserted by us. We just chase any interactable altar
-- in range. Combat happens inside the lock zone whenever there's no altar to
-- interact with.
-- (One table instead of seven file-level locals: this chunk is close to
-- LuaJIT's 200-local limit.)
local MAIDEN = {
    ARRIVE_DIST   = 6,     -- meters: switch from MOVING_TO_MAIDEN to AT_MAIDEN
    LOCK_RADIUS   = 12,    -- meters: drift further than this and we re-pin
    KILL_RADIUS   = 15,    -- meters: only kill monsters within this of altar
    INTERACT_DIST = 5,     -- meters: interact with altar within this range
    ALTAR_SEARCH  = 14,    -- meters: walk to interactable altars within this range
    INSERT_WAIT   = 3.0,   -- seconds: charge time before checking heart drop
}
MAIDEN.INSERT_RETRY = MAIDEN.INSERT_WAIT + 1.5 -- allow the charge and confirmation grace
local maiden_pos                       = nil   -- vec3 of the active altar (set on entry)
local maiden_pre_insert_heart_count    = nil   -- snapshot before interact_object
local maiden_insert_attempt_t          = nil   -- get_time_since_inject of last interact
local maiden_last_log_t                = 0

local function maiden_reset_cycle()
    maiden_pre_insert_heart_count = nil
    maiden_insert_attempt_t       = nil
end

-- get_maiden_pos / find_maiden_altar / should_do_maiden are declared as forward
-- locals here so check_events and the state handlers can see them. Bodies live
-- in the [maiden helpers — bodies] block below get_cached_actors so they can
-- scan actors via the shared cache.
local get_maiden_pos
local find_maiden_altar
local should_do_maiden

-- Cached actor list: get_all_actors() is expensive, share one snapshot across all
-- find_closest_target() and scan_and_remember_chests() calls within the same frame.
local cached_actors = nil
local cached_actors_time = 0
local ACTOR_CACHE_TTL = 1.0

local function get_cached_actors()
    local now = get_time_since_inject()
    if cached_actors == nil or now - cached_actors_time >= ACTOR_CACHE_TTL then
        perf.inc("actor_cache_miss")
        perf.start("get_all_actors")
        cached_actors = chest_targets.collect(actors_manager, loot_manager)
        perf.stop("get_all_actors")
        cached_actors_time = now
    else
        perf.inc("actor_cache_hit")
    end
    return cached_actors
end

-- QQT_Warpigz_v3: the learned chest atlas (core/hr_atlas.lua) scans this
-- cached snapshot; the web dashboard reads the remembered chests and target.
tracker.hr_get_actors = get_cached_actors
-- QQT_Warpigz_v3: + the legacy direct chest target (overlay / dashboard target card).
tracker.hr_get_remembered = function() return remembered_chests, remembered_chest_target, found_chest, found_chest_position end

-- ── [maiden helpers — bodies] ──────────────────────────────────────────────
-- Forward-declared above (alongside the maiden tunables/state). Bodies live
-- here so they can see the local `get_cached_actors` defined just above.
-- Scan cached actors for the closest INTERACTABLE maiden altar within range.
-- The is_interactable filter is essential: after a heart is inserted the
-- altar may linger in the actor list briefly with interactable=false; without
-- the filter we'd repeatedly try to interact with a spent altar.
find_maiden_altar = function(max_dist)
    local target_skin = enums.maiden_altar_skin
    if not target_skin then return nil end
    local actors = get_cached_actors()
    local player_pos = get_player_position()
    local best, best_dist = nil, math.huge
    local target_skin_lc = string.lower(target_skin)
    for _, actor in pairs(actors) do
        local skin = actor:get_skin_name()
        if skin and string.lower(skin) == target_skin_lc then
            local ok_i, interactable = pcall(function() return actor:is_interactable() end)
            if ok_i and interactable then
                local d = player_pos:dist_to(actor:get_position())
                if d < best_dist and d <= (max_dist or math.huge) then
                    best, best_dist = actor, d
                end
            end
        end
    end
    return best, best_dist
end

-- Returns the maiden altar position to route to, or nil if unsupported.
-- Order:
--   1. Pinned `maiden_pos` (set on entry into MOVING_TO_MAIDEN/AT_MAIDEN) while
--      we're within 200u — keeps us locked on the chosen site even when its
--      altars momentarily go non-interactable (heart inserted, boss spawning).
--   2. Hardcoded zone coord if within 200u of player — canonical pile is
--      effectively "right here", commit to it without scanning.
--   3. Zone-wide actor scan for the closest INTERACTABLE altar — covers zones
--      where the active pile differs from the canonical coord.
--   4. Hardcoded zone coord as last fallback (may be nil for unsupported zones).
get_maiden_pos = function()
    local world = get_current_world()
    if not world then return nil end
    local zname = world:get_current_zone_name()
    if not zname then return nil end
    local hardcoded = enums.maiden_positions and enums.maiden_positions[zname] or nil
    if maiden_pos and utils.distance_to(maiden_pos) < 200 then
        return maiden_pos
    end
    if hardcoded and utils.distance_to(hardcoded) < 200 then
        return hardcoded
    end
    local altar = find_maiden_altar()
    if altar then return altar:get_position() end
    return hardcoded
end

-- Single source of truth for "should we be doing maiden right now?"
-- Used by check_events to enter, and by AT_MAIDEN to know when to release.
should_do_maiden = function()
    if not settings.do_maiden then return false, "setting off" end
    if not tracker.hr_mode.allow_maiden() then return false, "warplan mode" end
    if not utils.is_in_helltide() then return false, "not in helltide" end
    if not get_maiden_pos() then return false, "no maiden pos for zone" end
    -- Heart-count check: get_helltide_coin_hearts may not exist on older hosts.
    -- If the helper is unavailable, we can still drive the maiden lock-on (the
    -- altar interact will just no-op without hearts), but we treat 0 hearts as
    -- "don't bother" to avoid pinning the player at the altar with nothing to do.
    local hearts_fn = _G.get_helltide_coin_hearts
    if hearts_fn then
        local ok, hearts = pcall(hearts_fn)
        if ok and (hearts == nil or hearts <= 0) then
            return false, "no hearts"
        end
    end
    -- Cinder threshold: when set > 0, stop doing maiden once cinders >= threshold
    -- so the bot can spend those cinders before continuing to farm.
    if settings.maiden_disable_cinders and settings.maiden_disable_cinders > 0 then
        local cinders = get_helltide_coin_cinders()
        if cinders >= settings.maiden_disable_cinders then
            return false, "cinder threshold reached (" .. cinders .. ">=" .. settings.maiden_disable_cinders .. ")"
        end
    end
    return true, nil
end



local _fct_cache = {}          -- pattern -> { result, time }
local FCT_CACHE_TTL = 1.0      -- seconds before re-scanning actors for the same pattern

local function invalidate_fct_cache()
    _fct_cache = {}
end

local function find_closest_target(name)
    perf.inc("find_closest_target")
    local now = get_time_since_inject()
    local cached = _fct_cache[name]
    if cached and now - cached.time < FCT_CACHE_TTL then
        return cached.result
    end

    local actors = get_cached_actors()
    local closest_target = nil
    local closest_distance = math.huge

    for _, actor in pairs(actors) do
        local entry = chest_targets.read(actor)
        if entry and entry.skin:match(name) then
            local actor_pos = entry.position
            local distance = utils.distance_to(actor_pos)
            if distance < closest_distance then
                closest_target = actor
                closest_distance = distance
            end
        end
    end

    _fct_cache[name] = { result = closest_target, time = now }
    return closest_target
end

local function find_closest_waypoint_index(waypoints)
    local index = nil
    local closest_coordinate = 10000

    for i, coordinate in ipairs(waypoints) do
        local d = utils.distance_to(coordinate)
        if d < closest_coordinate then
            closest_coordinate = d
            index = i
        end
    end
    return index
end

local function load_waypoints(file)
    if file == "menestad" then
        tracker.waypoints = require("waypoints.menestad")
        console.print("Loaded waypoints: menestad")
    elseif file == "marowen" then
        tracker.waypoints = require("waypoints.marowen")
        console.print("Loaded waypoints: marowen")
    elseif file == "ironwolfs" then
        tracker.waypoints = require("waypoints.ironwolfs")
        console.print("Loaded waypoints: ironwolfs")
    elseif file == "wejinhani" then
        tracker.waypoints = require("waypoints.wejinhani")
        console.print("Loaded waypoints: wejinhani")
    elseif file == "jirandai" then
        tracker.waypoints = require("waypoints.jirandai")
        console.print("Loaded waypoints: jirandai")
    else
        console.print("No waypoints loaded")
    end
end

-- Returns true when a region match was found and waypoints were loaded.
-- False means the current zone has no waypoint file (caller should fall back
-- to grid-coverage exploration instead of bouncing INIT ↔ EXPLORE_HELLTIDE).
local function check_and_load_waypoints()
    tracker.waypoints = {}
    tracker.waypoints_zone = nil -- QQT_Warpigz_v3
    for _, tp in ipairs(enums.helltide_tps) do
        if utils.player_in_region(tp.region) then
            load_waypoints(tp.file)
            tracker.confirmed_helltide_tp = tp
            -- QQT_Warpigz_v3: the loop's zone (core/hr_roads.lua, core/hr_fence.lua).
            tracker.waypoints_zone = tp.name
            return true
        end
    end
    return false
end

local function randomize_waypoint(waypoint, max_offset)
    max_offset = max_offset or 1.5
    local random_x = math.random() * max_offset * 2 - max_offset
    local random_y = math.random() * max_offset * 2 - max_offset

    local randomized_point = vec3:new(
        waypoint:x() + random_x,
        waypoint:y() + random_y,
        waypoint:z()
    )

    randomized_point = utility.set_height_of_valid_position(randomized_point)
    if utility.is_point_walkeable(randomized_point) then
        return randomized_point
    else
        return waypoint
    end
end

-- Build a dedup key from chest name + approximate position (rounded to 1m)
local function chest_key(name, pos)
    return chest_targets.key(name, pos)
end

-- Remember a chest we can see but can't afford
local function remember_chest(name, cost, actor)
    local pos = actor:get_position()
    local key = chest_key(name, pos)
    if remembered_chests[key] then
        -- QQT_Warpigz_v3: seen again (a chest reset drops chests not seen since).
        remembered_chests[key].seen_at = get_time_since_inject()
        return -- already known
    end
    remembered_chests[key] = {
        name = name,
        cost = cost,
        position = pos,
        discovered_at = get_time_since_inject(),
        seen_at = get_time_since_inject(), -- QQT_Warpigz_v3
    }
    console.print(string.format("[CHEST REMEMBER] %s (cost: %d cinders) at (%.1f, %.1f, %.1f) — saving location for a later approach",
        name, cost, pos:x(), pos:y(), pos:z()))
end

-- Scan nearby actors for unaffordable chests and remember them
local last_chest_scan_time = -math.huge
local CHEST_SCAN_TTL = 2.0
local function scan_and_remember_chests()
    if not settings.helltide_chest then return end
    local now = get_time_since_inject()
    if now - last_chest_scan_time < CHEST_SCAN_TTL then
        perf.inc("chest_scan_skip")
        return
    end
    last_chest_scan_time = now
    perf.start("scan_remember_chests")
    local current_cinders = get_helltide_coin_cinders()
    local actors = get_cached_actors()

    for _, actor in pairs(actors) do
        local entry = chest_targets.read(actor)
        if entry and entry.interactable then
            local name, cost = chest_targets.classify(entry.skin, enums.chest_types)
            if name and (current_cinders < cost or utils.distance_to(entry.position) > WAYPOINT_MAX_DIST
                or tracker.hr_cinder_run.saving()) then -- QQT_Warpigz_v3 (Q4): saving: remember for the run
                remember_chest(name, cost, actor)
            end
        end
    end
    perf.stop("scan_remember_chests")
end

local function allow_chest_interaction(name, position)
    local key = chest_key(name, position)
    local attempts = chest_interact_attempts[key] or 0
    if attempts >= CHEST_INTERACT_ATTEMPT_LIMIT then
        local expiry = get_time_since_inject() + CHEST_BLACKLIST_DURATION
        chest_temp_blacklist[key] = expiry
        chest_blacklist_data[key] = {pos = position, expiry = expiry, name = name}
        chest_interact_attempts[key] = nil
        console.print(string.format("[CHEST RETRY LIMIT] %s did not open after %d attempts; skipping for %.0fs",
            name, attempts, CHEST_BLACKLIST_DURATION))
        return false
    end
    chest_interact_attempts[key] = attempts + 1
    return true
end

local REMEMBERED_CHEST_MAX_DIST = 150

-- Check if we can now afford any remembered chest within range — returns key + entry of cheapest affordable one
local function find_affordable_remembered_chest()
    local current_cinders = get_helltide_coin_cinders()
    local best_key, best_entry = nil, nil

    local now = get_time_since_inject()
    for key, entry in pairs(remembered_chests) do
        -- Skip chests temporarily blacklisted as "unreachable from current angle".
        local bl = chest_temp_blacklist[key]
        if bl then
            if bl > now then
                goto continue
            end
            chest_temp_blacklist[key] = nil  -- expired
            chest_blacklist_data[key] = nil
        end
        if current_cinders >= entry.cost and utils.distance_to(entry.position) <= REMEMBERED_CHEST_MAX_DIST
            and tracker.hr_cinder_run.allows(entry.name) then -- QQT_Warpigz_v3 (Q4)
            if not best_entry or entry.cost < best_entry.cost then
                best_key = key
                best_entry = entry
            end
        end
        ::continue::
    end

    return best_key, best_entry
end

-- Prioritize-traversals tracking
-- trav_blacklist is declared before recovery so both paths share the same table.
local TRAV_BLACKLIST_TIMEOUT = 30 -- seconds before a blacklisted traversal can be targeted again
local trav_scan_time = 0          -- last time we ran the actor scan for traversals
local TRAV_SCAN_TTL = 1.0         -- only scan actors for traversals once per second
local trav_target_pos = nil       -- vec3 position of the traversal we're navigating to
local trav_target_str = nil       -- unique key for the target traversal
local trav_start_time = nil       -- time when we started navigating to this traversal
local trav_start_pos = nil        -- player position when we started (for crossing detection)
local trav_got_close = false      -- true once player came within 5 units of the traversal
local TRAV_NAV_TIMEOUT = 20       -- seconds before giving up on reaching a traversal

-- Kill monster tracking
local km_unreachable = {}
local KM_UNREACHABLE_TIMEOUT = 30
local km_nav_map = {}  -- per-position progress tracking: key -> {time, dist}

-- Micro-partial detector (mirrors the patrol_micropartial pattern). When A*
-- returns `limit_partial` with plen<=2 against the same enemy for N consecutive
-- pathfinds, the target is behind unwalkable terrain — mark it unreachable
-- without waiting the full 5s distance-stall timeout.
local KM_MICROPARTIAL_THRESHOLD = 20  -- consecutive bad pathfinds against the same target (~1.5-2s at 80ms tick)
local KM_MICROPARTIAL_PLEN_MAX  = 2
local KM_MICROPARTIAL_GOAL_TOL  = 3   -- meters: enemy can drift slightly while we re-pathfind
local _km_micropartial_count    = 0
local _km_micropartial_last_id  = 0
local _km_micropartial_key      = nil  -- nav_key of the target the counter belongs to

local function km_is_unreachable(pos)
    local now = get_time_since_inject()
    local key = math.floor(pos:x()) .. ',' .. math.floor(pos:y())
    if km_unreachable[key] and now - km_unreachable[key] > KM_UNREACHABLE_TIMEOUT then
        km_unreachable[key] = nil
    end
    return km_unreachable[key] ~= nil
end

local km_target_cache = nil
local km_cache_valid = false  -- separate flag: cache populated (result may be nil)
local km_target_cache_time = 0
local KM_TARGET_CACHE_TTL = 1.0  -- increased from 0.3; nil result was never cached before

local function km_mark_unreachable(pos)
    local key = math.floor(pos:x()) .. ',' .. math.floor(pos:y())
    km_unreachable[key] = get_time_since_inject()
    km_cache_valid = false  -- invalidate so next call re-scans without the now-unreachable enemy
    console.print(string.format("[KILL MONSTERS] Marked unreachable: (%.1f, %.1f)", pos:x(), pos:y()))
end

local function get_kill_target()
    local now = get_time_since_inject()
    if km_cache_valid and now - km_target_cache_time < KM_TARGET_CACHE_TTL then
        perf.inc("km_cache_hit")
        return km_target_cache
    end
    km_cache_valid = false
    perf.inc("km_cache_miss")
    perf.start("get_kill_target")
    local player_pos = get_player_position()
    local enemies = target_selector.get_near_target_list(player_pos, 50)
    local closest_enemy, closest_enemy_dist
    local closest_elite, closest_elite_dist
    local closest_champ, closest_champ_dist
    local closest_boss, closest_boss_dist

    for _, enemy in pairs(enemies) do
        local enemy_pos = enemy:get_position()
        if math.abs(player_pos:z() - enemy_pos:z()) > 12 then goto continue end
        -- QQT_Warpigz_v3 3.3.3: + a target hr_watch ignores (no damage, no progress)
        if km_is_unreachable(enemy_pos) or tracker.hr_watch.km_ignored(enemy, now) then goto continue end
        local health = enemy:get_current_health()
        if health <= 1 then goto continue end
        local dist = utils.distance_to(enemy)
        if enemy:is_boss() and (closest_boss_dist == nil or dist < closest_boss_dist) then
            closest_boss = enemy
            closest_boss_dist = dist
        end
        if dist <= 50 then
            if closest_enemy_dist == nil or dist < closest_enemy_dist then
                closest_enemy = enemy
                closest_enemy_dist = dist
            end
            if enemy:is_elite() and (closest_elite_dist == nil or dist < closest_elite_dist) then
                closest_elite = enemy
                closest_elite_dist = dist
            end
            if enemy:is_champion() and (closest_champ_dist == nil or dist < closest_champ_dist) then
                closest_champ = enemy
                closest_champ_dist = dist
            end
        end
        ::continue::
    end
    -- Rarity floor: drop tiers below the user's selection so we don't route
    -- to plain trash when they only want elites/champions/bosses.
    -- 0=All, 1=Rare+ (elite floor), 2=Champion+ (champion floor), 3=Boss only.
    local rarity = settings.kill_monsters_rarity or 0
    local result
    if rarity >= 3 then
        result = closest_boss
    elseif rarity == 2 then
        result = closest_boss or closest_champ
    elseif rarity == 1 then
        result = closest_boss or closest_champ or closest_elite
    else
        result = closest_boss or closest_champ or closest_elite or closest_enemy
    end
    perf.stop("get_kill_target")
    km_target_cache = result
    km_cache_valid = true  -- mark valid even when result is nil (no targets found)
    km_target_cache_time = get_time_since_inject()
    return result
end

-- Movement / actor helpers for the Farm-mode rupture machine.
tracker.tear_event.bind({
    move_to = move_to,
    clear_movement = clear_movement,
    get_actors = get_cached_actors,
    get_kill_target = get_kill_target,
})

local last_chest_diagnostic = -math.huge
local unknown_chest_skins = {}
local function log_chest_diagnostics()
    if not settings.draw_chest_status then return end
    local now = get_time_since_inject()
    if now - last_chest_diagnostic < 5 then return end
    last_chest_diagnostic = now
    local cinders = get_helltide_coin_cinders()
    local known, interactable, affordable, in_range, blocked = 0, 0, 0, 0, 0
    for _, actor in pairs(get_cached_actors()) do
        local entry = chest_targets.read(actor)
        -- QQT_Warpigz_v3: the Season 15 Helltide event skins are unknown; each
        -- *Helltide*Event* / *_Event_* skin is logged once per session.
        local lskin = entry and entry.skin:lower()
        if lskin and (lskin:find("_event_", 1, true) or (lskin:find("helltide", 1, true) and lskin:find("event", 1, true)))
            and not unknown_chest_skins[entry.skin] then
            unknown_chest_skins[entry.skin] = true
            console.print(string.format("[EVENT SKIN] skin=%s interactable=%s dist=%.1f",
                entry.skin, tostring(entry.interactable), utils.distance_to(entry.position)))
        end
        if entry then
            local name, cost = chest_targets.classify(entry.skin, enums.chest_types)
            if name then
                known = known + 1
                if entry.interactable then interactable = interactable + 1 end
                if cinders >= cost then affordable = affordable + 1 end
                if utils.distance_to(entry.position) <= WAYPOINT_MAX_DIST then in_range = in_range + 1 end
                local expiry = chest_temp_blacklist[chest_key(name, entry.position)]
                if expiry and expiry > now then blocked = blocked + 1 end
            else
                local skin = entry.skin:lower()
                if (skin:find("helltide", 1, true) or skin:find("rewardgizmo", 1, true))
                    and not unknown_chest_skins[entry.skin] then
                    unknown_chest_skins[entry.skin] = true
                    console.print(string.format("[CHEST UNKNOWN] skin=%s interactable=%s dist=%.1f; no known cost, ignored",
                        entry.skin, tostring(entry.interactable), utils.distance_to(entry.position)))
                end
            end
        end
    end
    console.print(string.format("[CHEST SCAN] enabled=%s cinders=%d known=%d interactable=%d affordable=%d within50m=%d blacklisted=%d",
        tostring(settings.helltide_chest), cinders, known, interactable, affordable, in_range, blocked))
end

local function check_events(self)
    local target -- reusable local for caching find_closest_target results
    log_chest_diagnostics()

    -- Priority 0: Maiden — overrides everything else when the user opts in.
    -- Stays in the maiden loop until heart count hits 0, the cinder threshold
    -- is reached, or the user toggles off. Boss-fight kill_monsters happens
    -- INSIDE the AT_MAIDEN state (lock radius enforced) so we don't lose the pin.
    do
        local ok, why = should_do_maiden()
        if ok then
            local mpos = get_maiden_pos()
            if mpos then
                if utils.distance_to(mpos) <= MAIDEN.ARRIVE_DIST then
                    -- Already at the altar — go straight into the pinned loop.
                    if self.current_state ~= helltide_state.AT_MAIDEN then
                        console.print("[MAIDEN] Already at altar — entering AT_MAIDEN")
                        maiden_pos = mpos
                        maiden_reset_cycle()
                    end
                    self.current_state = helltide_state.AT_MAIDEN
                else
                    if self.current_state ~= helltide_state.MOVING_TO_MAIDEN
                        and self.current_state ~= helltide_state.AT_MAIDEN
                    then
                        console.print(string.format(
                            "[MAIDEN] Routing to altar at (%.1f,%.1f,%.1f) dist=%.1f",
                            mpos:x(), mpos:y(), mpos:z(), utils.distance_to(mpos)))
                        maiden_pos = mpos
                        maiden_reset_cycle()
                    end
                    self.current_state = helltide_state.MOVING_TO_MAIDEN
                end
                return
            end
        elseif self.current_state == helltide_state.AT_MAIDEN
            or self.current_state == helltide_state.MOVING_TO_MAIDEN
        then
            -- Was doing maiden, now condition is gone — release back to explore.
            console.print("[MAIDEN] Releasing maiden lock — " .. (why or "?"))
            maiden_pos = nil
            maiden_reset_cycle()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end

    -- Priority 0b (Farm mode only): Pandemonium ruptures before chests.
    -- Warplan / external enable never enters a rupture (core/hr_mode.lua).
    if tracker.tear_event.check_events(self, helltide_state) then
        return
    end

    -- Priority 1: Cinder chests when player can afford one
    if settings.helltide_chest then
        local current_cinders = get_helltide_coin_cinders()
        -- QQT_Warpigz_v3: Farm-mode smart chest order (core/hr_chest_order.lua).
        -- true: a chest was chosen; false: none is allowed now (the plain
        -- selection below would ignore the cinder plan); nil: off or failed,
        -- the plain selection runs (Warplan / WarPigs always).
        local smart = self:hr_smart_chests()
        if smart == true then return end
        if smart == nil then
            local now_bl = get_time_since_inject()
            local selected = chest_targets.select(get_cached_actors(), enums.chest_types,
                get_player_position(), current_cinders, WAYPOINT_MAX_DIST, function(entry)
                    if not tracker.hr_cinder_run.allows(entry.name) then return true end -- QQT_Warpigz_v3 (Q4)
                    local key = chest_key(entry.name, entry.position)
                    local expiry = chest_temp_blacklist[key]
                    if expiry and expiry > now_bl then return true end
                    chest_temp_blacklist[key] = nil
                    chest_blacklist_data[key] = nil
                    return false
                end)
            if selected then
                found_chest = selected.name
                found_chest_position = selected.position
                pre_interact_cinders = nil
                last_chest_interact_time = -math.huge
                tracker.clear_key("chest_drop_time")
                chest_stuck_reset()
                remembered_chests[chest_key(found_chest, found_chest_position)] = nil
                console.print(string.format("[HELLTIDE CHEST] Detected %s at dist=%.1f cinders=%d/%d",
                    found_chest, utils.distance_to(found_chest_position), current_cinders, selected.cost))
                self.current_state = helltide_state.MOVING_TO_HELLTIDE_CHEST
                return
            end

            -- Scan for unaffordable chests in range and remember them
            scan_and_remember_chests()

            -- Check if we can now afford a previously remembered chest and navigate back
            local rkey, rentry = find_affordable_remembered_chest()
            if rkey and rentry then
                console.print(string.format("[CHEST RECALL] Now have enough cinders (%d/%d) for %s — navigating back to (%.1f, %.1f)",
                    current_cinders, rentry.cost, rentry.name, rentry.position:x(), rentry.position:y()))
                rentry.interacted, rentry.pre_cinders = nil, nil -- QQT_Warpigz_v3: this trip's own interaction
                remembered_chest_target = rkey
                remembered_chest_long_path_started = false
                remembered_chest_long_path_ok = false
                chest_stuck_reset()
                self.current_state = helltide_state.MOVING_TO_REMEMBERED_CHEST
                return
            end
        end

        -- Check if a nearby remembered chest needs fewer cinders than the threshold — if so, stay and farm monsters
        -- QQT_Warpigz_v3: Warplan only. In Farm mode this parked the bot at a
        -- chest for minutes (ring roam, no time bound, tears only within the
        -- pass-by distance) instead of hunting tears; Farm has the Smart farm goal.
        if not farm_chest_entry and settings.farm_cinder_threshold > 0 and not tracker.hr_mode.is_farm() then
            for key, entry in pairs(remembered_chests) do
                local shortfall = entry.cost - current_cinders
                if shortfall > 0 and shortfall < settings.farm_cinder_threshold and utils.distance_to(entry.position) <= 50
                    and tracker.hr_cinder_run.allows(entry.name) then -- QQT_Warpigz_v3 (Q4)
                    console.print(string.format("[FARM CHEST] %s needs only %d more cinders (%d/%d) — staying to farm",
                        entry.name, shortfall, current_cinders, entry.cost))
                    farm_chest_entry = entry
                    remembered_chests[key] = nil  -- actively farming it now
                    clear_movement()
                    self.current_state = helltide_state.FARM_CHEST_CINDERS
                    return
                end
            end
        end
    end

    -- Priority 2: Prioritize traversals (between chests and kill monsters)
    -- Scan is throttled to once per second to avoid iterating all actors every frame
    if settings.prioritize_traversals then
        local now = get_time_since_inject()
        if now - trav_scan_time >= TRAV_SCAN_TTL then
            trav_scan_time = now
            local actors = get_cached_actors()
            local player_pos_z = get_player_position():z()
            for _, actor in pairs(actors) do
                local name = actor:get_skin_name()
                if name:match('[Tt]raversal_Gizmo') then
                    local pos = actor:get_position()
                    local trav_dist = utils.distance_to(pos)
                    local z_diff = math.abs(pos:z() - player_pos_z)
                    -- Mirror Batmobile's own z-diff constraint: only route to traversals
                    -- on the same level (z_diff <= 3).  FreeClimb_Up gizmos sit at the
                    -- bottom of a ladder — if the player is already at the top (z_diff > 3)
                    -- Batmobile will never select them, so skip them here too.
                    if z_diff > 3 then
                        console.print(string.format("[TRAVERSAL] Skipped %s dist=%.1f z_diff=%.1f (too high)", name, trav_dist, z_diff))
                        goto continue_trav
                    end
                    local key = math.floor(pos:x()) .. ',' .. math.floor(pos:y()) .. ',' .. math.floor(pos:z())
                    local blacklisted_at = trav_blacklist[key]
                    if blacklisted_at and now - blacklisted_at <= TRAV_BLACKLIST_TIMEOUT then
                        console.print(string.format("[TRAVERSAL] Skipped %s dist=%.1f — blacklisted %.0fs ago", name, trav_dist, now - blacklisted_at))
                    elseif trav_dist >= 30 then
                        console.print(string.format("[TRAVERSAL] Skipped %s dist=%.1f — too far (>=30)", name, trav_dist))
                    elseif (blacklisted_at == nil or now - blacklisted_at > TRAV_BLACKLIST_TIMEOUT)
                        and trav_dist < 30
                    then
                        console.print(string.format("[TRAVERSAL] Targeting %s dist=%.1f pos=(%.1f,%.1f,%.1f)",
                            name, utils.distance_to(pos), pos:x(), pos:y(), pos:z()))
                        trav_target_pos = pos
                        trav_target_str = key
                        trav_start_time = now
                        trav_start_pos = get_player_position()
                        trav_got_close = false
                        self.current_state = helltide_state.MOVING_TO_TRAVERSAL
                        return
                    end
                end
                ::continue_trav::
            end
        end
    end

    -- Priority 3: Kill monsters when enabled
    if settings.kill_monsters then
        local km_target = get_kill_target()
        -- QQT_Warpigz_v3: Farm: plain monsters are passed by while the patrol moves on (core/hr_mode.lua km_hold).
        if km_target and tracker.hr_mode.km_skip(km_target, get_time_since_inject()) then km_target = nil end
        if km_target then
            -- Arm the experimental explorer the first time we see a monster in this zone:
            -- means the patrol successfully walked us into populated terrain and grid
            -- exploration is now safe to engage.
            if settings.experimental_explorer and not experimental_armed then
                experimental_armed = true
                console.print(string.format(
                    "[EXPLORER] First monster encountered (dist=%.1f) — arming experimental explorer",
                    utils.distance_to(km_target)))
            end
            self.current_state = helltide_state.KILL_MONSTERS
            return
        end
    end

    -- Priority 4: Nearby events / interactables while patrolling
    -- QQT_Warpigz_v3: reach from core/hr_mode.lua (Warplan 12 m; Farm 'Event
    -- radius', fenced to the learned Helltide area).
    if settings.event and utils.do_events() and not tracker.hr_mode.skip_local_events() then
        target = find_closest_target("S04_Helltide_Prop_SoulSyphon_01_Dyn")
        if target and target:is_interactable() and tracker.hr_mode.event_in_reach(target, utils.distance_to(target))
            and self:hr_event_engage(target, "S04_Helltide_Prop_SoulSyphon_01_Dyn") then
            self.current_state = helltide_state.MOVING_TO_PYRE
            return
        end
        target = find_closest_target("S04_Helltide_FlamePillar_Switch_Dyn")
        if target and target:is_interactable() and tracker.hr_mode.event_in_reach(target, utils.distance_to(target))
            and self:hr_event_engage(target, "S04_Helltide_FlamePillar_Switch_Dyn") then
            self.current_state = helltide_state.MOVING_TO_PYRE
            return
        end
    end

    if settings.chaos_rift and tracker.hr_mode.allow_chaos_rift() then
        target = find_closest_target("S10_ChaosRiftChoiceGizmo")
        if target and not self:hr_watch_skipped(target) and target:is_interactable() and utils.distance_to(target) < 16 then
            self.current_state = helltide_state.MOVING_TO_CHAOS_RIFT
            return
        end
    end

    if settings.silent_chest and utils.have_whispering_key() then
        target = find_closest_target("Hell_Prop_Chest_Rare_Locked")
        if target and not self:hr_watch_skipped(target) and target:is_interactable() and utils.distance_to(target) < 12 then
            found_silent_chest_position = target:get_position()
            console.print(string.format("[SILENT CHEST] Detected at dist=%.1f pos=(%.1f,%.1f,%.1f)",
                utils.distance_to(target), found_silent_chest_position:x(), found_silent_chest_position:y(), found_silent_chest_position:z()))
            self.current_state = helltide_state.MOVING_TO_SILENT_CHEST
            return
        end
    end

    if settings.ore then
        target = find_closest_target("HarvestNode_Ore")
        if target and not self:hr_watch_skipped(target) and target:is_interactable() and utils.distance_to(target) < 12 and utils.check_z_distance(target, 2.5) then
            found_ore = target
            self.current_state = helltide_state.MOVING_TO_ORE
            return
        end
    end

    if settings.herb then
        target = find_closest_target("HarvestNode_Herb")
        if target and not self:hr_watch_skipped(target) and target:is_interactable() and utils.distance_to(target) < 12 and utils.check_z_distance(target, 2.5) then
            found_herb = target
            self.current_state = helltide_state.MOVING_TO_HERB
            return
        end
    end

    if settings.shrine then
        target = find_closest_target("Shrine_")
        if target and not self:hr_watch_skipped(target) and target:is_interactable() and utils.distance_to(target) < 8 then
            self.current_state = helltide_state.MOVING_TO_SHRINE
            return
        end
    end

    if settings.goblin then
        target = find_closest_target("treasure_goblin")
        if target and not self:hr_watch_skipped(target) and target:get_current_health() > 1 then
            self.current_state = helltide_state.CHASE_GOBLIN
            return
        end
    end

    -- Periodic summary when nothing triggered — reveals blind spots
    if not self._last_check_events_debug then self._last_check_events_debug = 0 end
    local now_ce = get_time_since_inject()
    if settings.debug_log and now_ce - self._last_check_events_debug > 5 then
        self._last_check_events_debug = now_ce
        local cinders = get_helltide_coin_cinders()
        local rem_count = 0
        if remembered_chests then
            for _ in pairs(remembered_chests) do rem_count = rem_count + 1 end
        end
        console.print(string.format(
            "[CHECK_EVENTS] No action | cinders=%d | kill=%s | trav=%s | events=%s | remembered=%d",
            cinders,
            tostring(settings.kill_monsters),
            tostring(settings.prioritize_traversals),
            tostring(settings.event and utils.do_events()),
            rem_count))
    end
end

local helltide_task = {
    name = "Explore Helltide",
    current_state = helltide_state.INIT,

    shouldExecute = function()
        -- Explicitly excluded zones: let search_helltide teleport us away instead.
        if zone_overrides.is_excluded_zone() then return false end
        -- Also keep running when we've wandered out but helltide is still active.
        -- Zone-override case (WarPigs auto-TP into a non-canonical zone): take
        -- ownership during the helltide hour even before the buff lands so we
        -- can walk to the entry vec3 instead of letting search_helltide fly us
        -- back to a known town and undo the WarPigs teleport.
        local now = get_time_since_inject()
        if utils.is_in_helltide() then
            tracker.helltide_seen_at, tracker.return_expired_logged = now, nil
            return true
        end
        -- Farm mode Deathtoll Chamber run: the chamber instance has no
        -- helltide buff; keep the tick while the hour is still active.
        if utils.helltide_active() and tracker.tear_event.holds_zone(tracker.hr_task_state) then
            return true
        end
        -- Live report: HR "stopped and searched for a helltide in the middle
        -- of a helltide". Walking over the zone edge, a cellar or a buff-list
        -- refresh drops the buff for a moment; without this grace the very
        -- next tick went to search_helltide, which reset HR and teleported
        -- away before Execute could notice "left the zone" and walk back.
        -- Keep the tick for 15 s after the buff was last seen (hour still
        -- active) and while walking back for at most 90 s (bounded, logged).
        if utils.helltide_active() and tracker.helltide_seen_at
            and now - tracker.helltide_seen_at < 15 then
            return true
        end
        if returning_to_helltide and utils.helltide_active() then
            if now - (tracker.return_started_at or now) < 90 then return true end
            if not tracker.return_expired_logged then
                tracker.return_expired_logged = true
                console.print("[HELLTIDE] Could not walk back into the helltide zone within 90s — searching for a helltide")
            end
        end
        -- Override-zone clause: claim the tick before the buff lands so we
        -- can walk to the entry vec3. Once `override_buff_seen` latches, a
        -- subsequent buff drop = helltide ended in this zone — release the
        -- tick to search_helltide so it can TP to town and find the next
        -- active helltide instead of looping on the entry walk.
        return zone_overrides.get_current() ~= nil and utils.helltide_active() and not override_buff_seen
    end,

    Execute = function(self)
        perf.report()
        perf.inc("state_" .. self.current_state)
        perf.start("hr_tick")
        self.name = "Explore Helltide (" .. self.current_state .. ")"
        tracker.hr_task_state = self.current_state
        local lp = get_local_player()
        if not lp then return end
        if recovery.revive_if_dead(lp) then
            was_dead = true
            clear_movement()
            tracker.tear_event.release_holds("death") -- QQT_Warpigz_v3 (Q2)
            return
        elseif was_dead then
            was_dead = false
            console.print("[HelltideRevamped] Revived — resetting Batmobile movement (exploration preserved)")
            if BatmobilePlugin then
                BatmobilePlugin.reset_movement(plugin_label)
                BatmobilePlugin.resume(plugin_label)
            end
            -- Death may have left orbwalker clear off (e.g. cinder gate flipped
            -- it during the run, or another plugin disabled it). Reassert ON
            -- after revive so post-revive trash actually gets cleared.
            settings.orb_set_clear(true)
        end

        -- QQT_Warpigz_v3 (Q2): an engaged tear pauses Rosie's pickup first.
        tracker.tear_event.sync_holds(self.current_state)
        -- QQT_Warpigz_v3 (C6): bounded, see loot_hold below.
        if self:loot_hold(lp) then
            clear_movement()
            self:note_hold("waiting for Looter to finish")
            return
        end

        -- HLT-5: WarPigs can drop HR straight into a helltide, so search's
        -- reset never runs; start every HR session with a clean Batmobile
        -- explorer (the previous activity's visited/backtrack/frontiers).
        if not self._bm_session_reset then
            self._bm_session_reset = true
            if BatmobilePlugin and BatmobilePlugin.reset then
                console.print("[HelltideRevamped] New session — resetting Batmobile exploration")
                BatmobilePlugin.reset(plugin_label)
            end
        end

        settings.apply_cinder_orb_gate()

        local now = get_time_since_inject()

        -- Zone-override walk-to-entry guard.  When WarPigs (or another external
        -- trigger) drops us into a zone like Skov_Celestia where the standard
        -- waypoint patrol can't run, we first walk to the override's entry vec3
        -- so the helltide buff applies and there's something for Batmobile to
        -- free-explore.  Once the buff is up, fall through to the normal flow
        -- (which then hits the no_waypoint_region fallback).
        -- Cache the result: world+zone don't change mid-session so re-checking
        -- get_current_world() every tick is wasted overhead.
        if not self._override_cache_time or (now - self._override_cache_time) > 5 then
            self._override_cache       = zone_overrides.get_current()
            self._override_cache_time  = now
        end
        local override = self._override_cache
        -- Latch / clear: track buff sightings tied to the override zone so we
        -- can distinguish "haven't entered yet" from "helltide ended here".
        if override == nil then
            override_buff_seen = false
        elseif utils.is_in_helltide() then
            override_buff_seen = true
        end
        -- Walk-to-entry guard: only fire on the *first* approach, before the
        -- buff has ever been seen in this override zone.  Skipping it after
        -- `override_buff_seen` lets buff-drop fall through to the standard
        -- left-zone / search_helltide flow instead of stalling on a 4 km
        -- partial path back to the entry vec3.
        if override and not utils.is_in_helltide() and not override_buff_seen then
            local lp_pos = lp and lp:get_position()
            local dist = lp_pos and lp_pos:dist_to(override.entry) or math.huge
            if dist > 5 then
                if not self._override_walk_logged then
                    console.print(string.format(
                        '[HELLTIDE] zone override active for "%s/%s" — walking to entry (%.1f,%.1f,%.1f), dist=%.1f',
                        override.world_name, override.zone_name,
                        override.entry:x(), override.entry:y(), override.entry:z(), dist))
                    self._override_walk_logged = true
                end
                if BatmobilePlugin then
                    BatmobilePlugin.pause(plugin_label)
                    BatmobilePlugin.set_target(plugin_label, override.entry, false)
                    bm_pulse(true)
                else
                    native_move(override.entry)
                end
                return
            end
            -- Reached the entry but buff still not applied.  Park here instead
            -- of wandering off — the buff usually appears within a second or
            -- two of standing in the right cell.
            self._override_walk_logged = false
            -- QQT_Warpigz_v3 3.3.3: bounded. No buff after OVERRIDE_PARK_S at
            -- the entry (no Helltide here this hour): the latch releases the
            -- zone to search_helltide instead of parking until minute 55.
            self._override_park_at = self._override_park_at or now
            if now - self._override_park_at >= RECALL.OVERRIDE_PARK_S then
                console.print(string.format("[HELLTIDE] Zone override entry reached but no Helltide buff for %ds — searching for a helltide",
                    RECALL.OVERRIDE_PARK_S))
                self._override_park_at = nil
                override_buff_seen = true
                return
            end
            clear_movement()
            if BatmobilePlugin then
                BatmobilePlugin.pause(plugin_label)
            end
            return
        end
        -- Buff is up, no override, or helltide ended here (latch tripped) —
        -- clear the walk-logged flag so a future override re-entry logs cleanly.
        self._override_walk_logged = false

        -- Post-chest-open hold: keep the player parked on the loot for
        -- CHEST_POST_OPEN_PAUSE seconds so Looteer can pick everything up
        -- before Batmobile heads off to the next waypoint.  Re-clear the
        -- target every tick so any path queued before the open can't slip
        -- through and drag the player away.
        if get_time_since_inject() - last_chest_open_time < CHEST_POST_OPEN_PAUSE then
            clear_movement()
            if BatmobilePlugin then
                -- Defensive: stop_long_path every tick so a long-path session
                -- left over from a prior remembered-chest navigation can't
                -- keep driving Batmobile's autonomous main_pulse and pull
                -- the player off the chest mid-channel.
                if BatmobilePlugin.stop_long_path then
                    BatmobilePlugin.stop_long_path(plugin_label)
                end
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.clear_target(plugin_label)
            end
            return
        end

        -- Track last confirmed in-zone position
        local in_ht_now = utils.is_in_helltide()
        if in_ht_now then
            last_in_zone_pos = lp and lp:get_position() or last_in_zone_pos
        end

        -- Experimental-explorer disarm on (re-)entry: every false→true transition of
        -- is_in_helltide means a teleport just placed us at a fresh spawn point.  Force
        -- waypoint patrol until the next kill_monsters target arms the grid explorer.
        if in_ht_now and not was_in_helltide_for_arm then
            if experimental_armed then
                console.print("[EXPLORER] (Re-)entered helltide zone — disarming experimental explorer; resuming waypoint patrol until first monster")
            end
            experimental_armed = false
            -- Fresh zone: clear any leftover trap-recovery state from the prior zone
            -- so detection starts with a clean sliding window.
            if BatmobilePlugin and BatmobilePlugin.clear_giving_up then
                BatmobilePlugin.clear_giving_up(plugin_label)
            end
            force_zone_change = false
            tracker.abandoning_zone = nil
            -- Re-evaluate the no-waypoint fallback for the new zone — the next
            -- INIT pass will set it back to true if this zone also has no
            -- waypoint file, or leave it false for a known-region zone.
            no_waypoint_region = false
            no_waypoint_logged_zone = nil
        end
        was_in_helltide_for_arm = in_ht_now

        -- Trap-recovery escalation: Batmobile's navigator declares giving_up
        -- when it's been confined to a small bbox for 60s+ (e.g. descended
        -- into a dead-end chamber, can't get back up).  Bail out of this zone
        -- entirely: teleport to Cerrigar (drops the helltide buff) and tell
        -- search_helltide to skip the cached zone — otherwise it would
        -- immediately TP us back to the dead-end zone we just escaped.
        if not force_zone_change
            and BatmobilePlugin and BatmobilePlugin.is_giving_up
            and BatmobilePlugin.is_giving_up()
        then
            console.print("[HELLTIDE] Batmobile gave up after 60s trapped — abandoning zone, teleporting to home town to find a different helltide")
            force_zone_change = true
            -- Wipe trap state on the Batmobile side so the next zone doesn't
            -- inherit the giving_up flag (would cause an immediate re-bail).
            if BatmobilePlugin.clear_giving_up then
                BatmobilePlugin.clear_giving_up(plugin_label)
            end
            -- Reset everything for a clean start in the new zone
            experimental_armed = false
            if settings.experimental_explorer then
                helltide_explorer.reset()
            end
            reset_navigate_state()
            -- Tell search_helltide to skip the cached helltide zone (the one
            -- we just gave up on) and cycle through the others.
            tracker.skip_cached_zone = true
            -- QQT_Warpigz_v3: search restarts its scan from SEARCHING (its
            -- WAITING_FOR_TELEPORT from our arrival here is stale and would
            -- teleport straight back into the abandoned zone).
            tracker.search_restart = true
            -- HLT-3: this recovery owns the trip out; no Alfred with-teleport
            -- round trip may start from inside the trap (see back_to_town).
            tracker.abandoning_zone = true
            -- Configured idle-town waypoint (same one search_helltide uses
            -- between helltides).  Drops the helltide buff so
            -- search_helltide.shouldExecute starts firing.
            teleport_to_waypoint(settings.town_waypoint)
            self._town_tp_at = now
            self.current_state = helltide_state.BACK_TO_TOWN
            return
        end

        -- Detect leaving the zone mid-session (buff lost but hour still active → walk back, don't teleport)
        if not in_ht_now and utils.helltide_active()
            and self.current_state ~= helltide_state.RETURN_TO_HELLTIDE
            and self.current_state ~= helltide_state.BACK_TO_TOWN
            and not tracker.tear_event.holds_zone(self.current_state) then
            console.print(string.format("[HELLTIDE] Left helltide zone at (%.1f,%.1f) — navigating back via backtrack",
                lp and lp:get_position():x() or 0, lp and lp:get_position():y() or 0))
            self:hr_left_zone(lp and lp:get_position()) -- QQT_Warpigz_v3: learned fence, chest trip cancelled
            if settings.experimental_explorer then
                helltide_explorer.mark_active_unreachable()
            end
            returning_to_helltide = true
            tracker.return_started_at = now
            reset_navigate_state()
            self.current_state = helltide_state.RETURN_TO_HELLTIDE
        end

        -- HLT-1: only a hard need (inventory_full/need_repair, or the local
        -- item count when Alfred publishes no inventory view) sends HR to
        -- town here; advisory need_trigger/restock never starts a trip from
        -- inside a helltide (tasks/alfred.lua, R12). Unreadable status holds at most ~10 s (C1)
        -- and a foreign Alfred pause at most PAUSED_HOLD_MAX (alfred_paused_skip).
        local needs_salvage = false
        -- QQT_Warpigz_v3: nor while Alfred/Rosie refuses or failed the trip
        -- (stuck, utils.alfred_town_blocked): farm on with full bags.
        if settings.salvage and not tracker.has_salvaged and not tracker.alfred_paused_skip
            and not utils.alfred_town_blocked() then
            local available = utils.alfred_available()
            if available == nil then clear_movement(); self:note_hold("Alfred status unreadable"); return end
            if available then
                needs_salvage = utils.is_inventory_full()
                if needs_salvage == nil then clear_movement(); self:note_hold("Alfred status unreadable"); return end
            end
        end
        -- C5/L11: credit any time the state handlers did not run before they
        -- run again (the town hand-off branches below are yields themselves).
        if not tracker.has_salvaged and not needs_salvage then self:credit_yield(now) end
        -- QQT_Warpigz_v3 3.3.3: the walk-to-a-target states are bounded.
        if not tracker.has_salvaged and not needs_salvage and self:hr_watch_tick(now) then return end
        if tracker.has_salvaged then
            self:return_from_salvage()
        elseif needs_salvage then
            self:back_to_town()
        elseif tracker.tear_event.poll(self, helltide_state) then
            -- Farm mode: a rupture pre-empted monsters / chest recall (or a
            -- rupture state was dropped because the mode became warplan).
        elseif tracker.tear_event.is_rift_state(self.current_state) then
            tracker.tear_event.execute(self, helltide_state)
        elseif self.current_state == helltide_state.INIT then
            self:initiate_waypoints()
        elseif self.current_state == helltide_state.EXPLORE_HELLTIDE then
            self:explore_helltide()
        elseif self.current_state == helltide_state.MOVING_TO_TRAVERSAL then
            self:move_to_traversal()
        elseif self.current_state == helltide_state.MOVING_TO_PYRE then
            self:move_to_pyre()
        elseif self.current_state == helltide_state.INTERACT_PYRE then
            self:interact_pyre()
        elseif self.current_state == helltide_state.STAY_NEAR_PYRE then
            self:stay_near_pyre()
        elseif self.current_state == helltide_state.MOVING_TO_SILENT_CHEST then
            self:move_to_silent_chest()
        elseif self.current_state == helltide_state.MOVING_TO_HELLTIDE_CHEST then
            self:move_to_helltide_chest()
        elseif self.current_state == helltide_state.MOVING_TO_ORE then
            self:move_to_ore()
        elseif self.current_state == helltide_state.MOVING_TO_HERB then
            self:move_to_herb()
        elseif self.current_state == helltide_state.MOVING_TO_SHRINE then
            self:move_to_shrine()
        elseif self.current_state == helltide_state.CHASE_GOBLIN then
            self:chase_goblin()
        elseif self.current_state == helltide_state.KILL_MONSTERS then
            perf.start("kill_monsters")
            self:kill_monsters()
            perf.stop("kill_monsters")
        elseif self.current_state == helltide_state.MOVING_TO_REMEMBERED_CHEST then
            self:move_to_remembered_chest()
        elseif self.current_state == helltide_state.FARM_CHEST_CINDERS then
            self:farm_chest_cinders()
        elseif self.current_state == helltide_state.MOVING_TO_CHAOS_RIFT then
            self:move_to_chaos_rift()
        elseif self.current_state == helltide_state.INTERACT_CHAOS_RIFT then
            self:interact_chaos_rift()
        elseif self.current_state == helltide_state.STAY_NEAR_CHAOS_RIFT then
            self:stay_near_chaos_rift()
        elseif self.current_state == helltide_state.BACK_TO_TOWN then
            self:back_to_town()
        elseif self.current_state == helltide_state.RETURN_TO_HELLTIDE then
            self:return_to_helltide()
        elseif self.current_state == helltide_state.MOVING_TO_MAIDEN then
            self:move_to_maiden()
        elseif self.current_state == helltide_state.AT_MAIDEN then
            self:at_maiden()
        end
        perf.stop("hr_tick", "state=" .. tostring(self.current_state))
    end,

    initiate_waypoints = function(self)
        local matched = check_and_load_waypoints()
        if not matched then
            -- Unknown region (no waypoint file).  We can't run waypoint patrol or the
            -- grid-coverage explorer (it builds its bbox from the waypoints), so
            -- mark the session as "let Batmobile free-explore" and stop bouncing
            -- INIT ↔ EXPLORE_HELLTIDE.  check_events still drives interactables
            -- (chests/ore/herbs/shrine/goblin/pyre/monsters) via actor scans —
            -- only the wander-between-events movement source changes.
            no_waypoint_region = true
            local zname = get_current_world() and get_current_world():get_current_zone_name() or "?"
            if no_waypoint_logged_zone ~= zname then
                console.print('[HELLTIDE] no waypoint file for zone "' .. tostring(zname) ..
                    '" — falling back to Batmobile free-explore for this session')
                no_waypoint_logged_zone = zname
            end
        else
            no_waypoint_region = false
        end
        last_target_ni = nil
        self.current_state = helltide_state.EXPLORE_HELLTIDE
    end,

    return_to_helltide = function(self)
        -- Back in zone: blacklist the exit direction so experimental explorer avoids it,
        -- clear nav state, resume normal exploration.
        if utils.is_in_helltide() then
            self:hr_left_confirm(true) -- QQT_Warpigz_v3
            console.print("[HELLTIDE] Back in helltide zone — blacklisting exit node, resuming exploration")
            if settings.experimental_explorer then
                helltide_explorer.mark_active_unreachable()
            end
            returning_to_helltide = false
            reset_navigate_state()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Still outside — navigate toward last known in-zone position using the
        -- existing backtrack path; Batmobile keeps all exploration state intact.
        self:hr_left_confirm(false) -- QQT_Warpigz_v3: a confirmed exit is learned now
        if last_in_zone_pos then
            navigate_to(last_in_zone_pos)
        elseif BatmobilePlugin then
            -- No reference point yet — let Batmobile backtrack on its own
            BatmobilePlugin.resume(plugin_label)
            bm_pulse()
        end
    end,

    move_to_traversal = function(self)
        if not trav_target_pos then
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local now = get_time_since_inject()
        local player_pos = get_player_position()
        local dist = utils.distance_to(trav_target_pos)

        -- Track once we're within interaction range (matches Batmobile's interact threshold)
        if not trav_got_close and dist < 3 then
            trav_got_close = true
            console.print("[TRAVERSAL] Reached traversal, waiting for crossing")
        end

        -- Crossing detected: z changed from start (ladder) or player teleported away (portal)
        local z_crossed = trav_start_pos and math.abs(player_pos:z() - trav_start_pos:z()) > 2
        local portal_crossed = trav_got_close and dist > 20
        if z_crossed or portal_crossed then
            console.print(string.format("[TRAVERSAL] Crossed (z_diff=%.1f got_close=%s dist=%.1f) — blacklisting source + nearby return traversals for %ds",
                trav_start_pos and math.abs(player_pos:z() - trav_start_pos:z()) or 0,
                tostring(trav_got_close), dist, TRAV_BLACKLIST_TIMEOUT))
            -- Blacklist the source traversal we just crossed
            trav_blacklist[trav_target_str] = now
            -- Blacklist any traversal near the player's NEW position (the "return" traversal on
            -- the other side) so we don't immediately route back through the same crossing.
            local actors = get_cached_actors()
            for _, actor in pairs(actors) do
                if actor:get_skin_name():match('[Tt]raversal_Gizmo') then
                    local apos = actor:get_position()
                    if player_pos:dist_to(apos) < 10 then
                        local akey = math.floor(apos:x()) .. ',' .. math.floor(apos:y()) .. ',' .. math.floor(apos:z())
                        trav_blacklist[akey] = now
                        console.print(string.format("[TRAVERSAL] Blacklisting return traversal at (%.0f,%.0f,%.0f)",
                            apos:x(), apos:y(), apos:z()))
                    end
                end
            end
            trav_target_pos = nil
            trav_target_str = nil
            trav_start_time = nil
            trav_start_pos = nil
            trav_got_close = false
            reset_navigate_state()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Timeout — traversal is unreachable from current position
        if now - trav_start_time > TRAV_NAV_TIMEOUT then
            console.print(string.format("[TRAVERSAL] Timeout (%.0fs, dist=%.1f) — blacklisting traversal",
                TRAV_NAV_TIMEOUT, dist))
            trav_blacklist[trav_target_str] = now
            trav_target_pos = nil
            trav_target_str = nil
            trav_start_time = nil
            trav_start_pos = nil
            trav_got_close = false
            reset_navigate_state()
            -- Use reset_movement (not just clear_target) so Batmobile's post-traversal
            -- escape state (trav_escape_pos) is cleared.  Without this, every subsequent
            -- pathfind failure is treated as an escape-nudge toward the unreachable escape
            -- point rather than blacklisting the area and picking a fresh target.
            if BatmobilePlugin then
                BatmobilePlugin.reset_movement(plugin_label)
            else
                clear_movement()
            end
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Throttled debug
        if not self._last_trav_debug then self._last_trav_debug = 0 end
        if settings.debug_log and now - self._last_trav_debug > 2 then
            self._last_trav_debug = now
            local elapsed = now - trav_start_time
            local z_diff = trav_start_pos and math.abs(player_pos:z() - trav_start_pos:z()) or 0
            console.print(string.format("[TRAVERSAL] dist=%.1f elapsed=%.1fs z_diff=%.1f got_close=%s player=(%.1f,%.1f,%.1f)",
                dist, elapsed, z_diff, tostring(trav_got_close),
                player_pos:x(), player_pos:y(), player_pos:z()))
        end

        -- Let Batmobile route to the traversal autonomously.
        -- set_target() with the exact gizmo position fails (non-walkable cell).
        -- Batmobile's select_target() uses get_closeby_node() to find a walkable
        -- approach node — this only works when is_custom_target=false.
        if BatmobilePlugin then
            -- HLT-9: the patrol waypoint is still Batmobile's custom goal on
            -- entry; drop it once per traversal target so select_target runs.
            if self._trav_cleared_for ~= trav_start_time then
                self._trav_cleared_for = trav_start_time
                BatmobilePlugin.clear_target(plugin_label)
            end
            BatmobilePlugin.resume(plugin_label)
            bm_pulse()
        end
    end,

    explore_helltide = function(self)
        if #tracker.waypoints == 0 and not no_waypoint_region then
            -- Truly empty (not yet initialised) — head back to INIT to load.
            self.current_state = helltide_state.INIT
            return
        end

        local now = get_time_since_inject()
        local CHECK_EVENTS_TTL = 1.0
        if not self._last_check_events_time or now - self._last_check_events_time >= CHECK_EVENTS_TTL then
            self._last_check_events_time = now
            perf.start("check_events")
            check_events(self)
            perf.stop("check_events")
        end
        if self.current_state ~= helltide_state.EXPLORE_HELLTIDE then
            last_target_ni = nil
            patrol_free_explore = false
            patrol_stuck_time = nil
            patrol_stuck_pos = nil
            _patrol_skip_count = 0
            _patrol_micropartial_count   = 0
            _patrol_micropartial_last_id = 0
            _patrol_micropartial_ni      = nil
            self._last_check_events_time = nil
            invalidate_fct_cache()
            return
        end

        -- EXPERIMENTAL EXPLORER: score-based grid coverage of the full zone.
        -- Gated on `experimental_armed` so we don't hand control to the grid explorer
        -- until the player has reached populated terrain (first kill_monsters target).
        -- Until armed, fall through to the waypoint patrol below.
        --
        -- NOTE: navigate_long_path was tried here but conflicted with navigator.move's
        -- own replan logic — bm_pulse drove navigator.move which kept firing find_path
        -- on the same target, hitting the time cap repeatedly.  The long_path module
        -- assumes it's the sole driver of navigator state (main.lua's debug handler);
        -- co-driving from HR breaks that contract.  Reverted to navigate_to.
        -- No-waypoints fallback: hand off to Batmobile's own explorer.  Done
        -- BEFORE the experimental_explorer block because that block depends on
        -- waypoints to build its grid (build_grid bails if #waypoints == 0).
        if no_waypoint_region then
            if BatmobilePlugin then
                BatmobilePlugin.resume(plugin_label)
                bm_pulse()
            end
            return
        end
        if settings.experimental_explorer and experimental_armed then
            local player_pos = get_player_position()
            helltide_explorer.init()
            local target = helltide_explorer.get_target(player_pos)
            if target then
                navigate_to(target)
            else
                -- Just arrived at a node; Batmobile free-roams briefly while next node is selected
                if BatmobilePlugin then
                    BatmobilePlugin.resume(plugin_label)
                    bm_pulse()
                end
            end
            return
        end

        local total = #tracker.waypoints
        local player_pos = get_player_position()
        now = get_time_since_inject()

        -- FREE EXPLORE MODE: Batmobile explores autonomously (like ArkhamAsylum)
        if patrol_free_explore then
            -- Track how long we've been in free-explore
            if patrol_free_explore_start == nil then
                patrol_free_explore_start = now
            end

            if BatmobilePlugin then
                BatmobilePlugin.resume(plugin_label)
                bm_pulse()
            end

            -- Check if we've moved significantly — time to re-snap to waypoints
            local dist_from_stuck = patrol_stuck_pos and player_pos:dist_to(patrol_stuck_pos) or 0
            -- Throttled debug
            if not self._last_patrol_debug then self._last_patrol_debug = 0 end
            if settings.debug_log and now - self._last_patrol_debug > 2 then
                self._last_patrol_debug = now
                console.print(string.format("[PATROL] FREE_EXPLORE | moved=%.1f stuck_for=%.1fs | player=(%.1f,%.1f)",
                    dist_from_stuck, now - patrol_free_explore_start, player_pos:x(), player_pos:y()))
                if BatmobilePlugin then
                    console.print(string.format("[PATROL] Batmobile: done=%s paused=%s",
                        tostring(BatmobilePlugin.is_done()), tostring(BatmobilePlugin.is_paused())))
                end
            end

            -- If stuck in free-explore too long, player is likely on a platform after a
            -- traversal.  Clear the traversal blacklist so Batmobile can find a way back.
            if now - patrol_free_explore_start > TRAVERSAL_RECOVERY_TIMEOUT then
                if try_traversal_recovery(now) then
                    patrol_free_explore_start = now  -- reset so we don't spam-call
                end
            end

            if dist_from_stuck > 15 then
                console.print("[PATROL] Moved >15 from stuck pos, resuming waypoint patrol")
                patrol_free_explore = false
                patrol_stuck_time = nil
                patrol_stuck_pos = nil
                patrol_free_explore_start = nil
                last_target_ni = nil -- force re-snap
                -- Made it out of the dead cluster — reset skip streak so a
                -- single later rejection doesn't re-trigger free-explore.
                _patrol_skip_count = 0
                _patrol_micropartial_count = 0
                _patrol_micropartial_last_id = 0
                _patrol_micropartial_ni = nil
            end
            return
        end

        -- WAYPOINT PATROL MODE
        -- On first entry or after interaction, snap to nearest and look ahead
        if last_target_ni == nil then
            local nearest = find_closest_waypoint_index(tracker.waypoints)
            if nearest then
                ni = nearest + WAYPOINT_LOOKAHEAD
                if ni > total then ni = 1 end
                if settings.debug_log then console.print(string.format("[PATROL] Init: nearest=%d, targeting ni=%d/%d", nearest, ni, total)) end -- QQT_Warpigz_v3 2.6.4
            end
        end

        -- Check distance to our current target waypoint — advance when close
        local dist_to_target = utils.distance_to(tracker.waypoints[ni])
        if dist_to_target < WAYPOINT_ARRIVAL_DIST then
            local old_ni = ni
            ni = ni + WAYPOINT_LOOKAHEAD
            if ni > total then ni = 1 end
            if settings.debug_log then console.print(string.format("[PATROL] Arrived (dist=%.1f < %d), advancing ni %d -> %d", dist_to_target, WAYPOINT_ARRIVAL_DIST, old_ni, ni)) end -- QQT_Warpigz_v3 2.6.4
            patrol_stuck_time = nil
            patrol_stuck_pos = nil
            -- Genuine progress: clear unreachable-waypoint streak counters.
            _patrol_skip_count = 0
            _patrol_micropartial_count = 0
            _patrol_micropartial_last_id = 0
            _patrol_micropartial_ni = nil
        end

        -- If target waypoint is too far, re-snap to nearest
        dist_to_target = utils.distance_to(tracker.waypoints[ni])
        if dist_to_target > WAYPOINT_MAX_DIST then
            local nearest = find_closest_waypoint_index(tracker.waypoints)
            if nearest then
                local old_ni = ni
                ni = nearest + WAYPOINT_LOOKAHEAD
                if ni > total then ni = 1 end
                -- If even the re-snapped waypoint is far, just use nearest
                if utils.distance_to(tracker.waypoints[ni]) > WAYPOINT_MAX_DIST then
                    ni = nearest
                end
            end
        end

        -- Stuck detection: if player hasn't moved >5 units in PATROL_STUCK_TIMEOUT, switch to free explore
        if patrol_stuck_time == nil then
            patrol_stuck_time = now
            patrol_stuck_pos = player_pos
        else
            local dist_moved = player_pos:dist_to(patrol_stuck_pos)
            if dist_moved > 5 then
                patrol_stuck_time = now
                patrol_stuck_pos = player_pos
            elseif now - patrol_stuck_time > PATROL_STUCK_TIMEOUT then
                console.print(string.format("[PATROL] Stuck %ds (moved %.1f), switching to FREE_EXPLORE",
                    PATROL_STUCK_TIMEOUT, dist_moved))
                if BatmobilePlugin then
                    BatmobilePlugin.reset_movement(plugin_label)
                end
                patrol_free_explore = true
                patrol_free_explore_start = now  -- track entry time for traversal recovery
                -- Keep patrol_stuck_pos so free explore knows where we got stuck
                last_target_ni = nil
                return
            end
        end

        -- Local helper: advance ni by WAYPOINT_LOOKAHEAD and reset per-waypoint
        -- detection state. Used by both unreachable-detection paths below.
        local function advance_ni(reason)
            local old_ni = ni
            ni = ni + WAYPOINT_LOOKAHEAD
            if ni > total then ni = 1 end
            console.print(string.format("[PATROL] %s — advancing ni %d -> %d (skip #%d)",
                reason, old_ni, ni, _patrol_skip_count))
            last_target_ni = nil  -- force fresh set_target on next tick
            _patrol_micropartial_count = 0
            _patrol_micropartial_last_id = 0
            _patrol_micropartial_ni = nil
        end

        local function fallback_to_free_explore(reason)
            console.print(string.format("[PATROL] %s — switching to FREE_EXPLORE", reason))
            _patrol_skip_count = 0
            _patrol_micropartial_count = 0
            _patrol_micropartial_last_id = 0
            _patrol_micropartial_ni = nil
            if BatmobilePlugin then
                BatmobilePlugin.reset_movement(plugin_label)
            end
            patrol_free_explore = true
            patrol_free_explore_start = now
            last_target_ni = nil
        end

        -- Send target to Batmobile only when ni changes
        if ni ~= last_target_ni then
            local wp = tracker.waypoints[ni]
            if settings.debug_log then console.print(string.format("[PATROL] New target ni=%d dist=%.1f pos=(%.1f,%.1f,%.1f)", ni, utils.distance_to(wp), wp:x(), wp:y(), wp:z())) end -- QQT_Warpigz_v3 2.6.4
            last_target_ni = ni
            local accepted = patrol_move(randomize_waypoint(wp))
            if not accepted then
                -- Waypoint sits in Batmobile's failed_target zone (25u from a
                -- previous partial-path give-up). Skip ahead; if multiple
                -- consecutive waypoints are blocked we're inside the dead
                -- cluster — let Batmobile's frontier explorer find a way out.
                _patrol_skip_count = _patrol_skip_count + 1
                if _patrol_skip_count >= PATROL_SKIP_TO_FREE_EXPLORE then
                    fallback_to_free_explore(string.format(
                        "%d consecutive waypoint rejections", _patrol_skip_count))
                else
                    advance_ni("set_target rejected (failed_target zone)")
                end
                return
            end
            _patrol_skip_count = 0
            _patrol_micropartial_count = 0
            _patrol_micropartial_last_id = 0
            _patrol_micropartial_ni = ni
        else
            -- Same target, keep moving
            local wp = tracker.waypoints[ni]

            -- Micro-partial detector (mirrors remembered-chest unreachability):
            -- A* repeatedly returning a 2-node limit_partial against this waypoint
            -- means it sits behind unwalkable terrain with no traversal in range.
            -- Skip ahead immediately rather than waiting for the 5s stuck timer.
            if BatmobilePlugin and BatmobilePlugin.get_last_pathfind then
                local pf = BatmobilePlugin.get_last_pathfind()
                if pf and pf.call_id ~= _patrol_micropartial_last_id then
                    _patrol_micropartial_last_id = pf.call_id
                    if _patrol_micropartial_ni ~= ni then
                        _patrol_micropartial_ni    = ni
                        _patrol_micropartial_count = 0
                    end
                    local goal_match = math.abs(pf.goal_x - wp:x()) < PATROL_MICROPARTIAL_GOAL_TOL
                                       and math.abs(pf.goal_y - wp:y()) < PATROL_MICROPARTIAL_GOAL_TOL
                    if goal_match
                       and pf.status == "limit_partial"
                       and pf.plen <= PATROL_MICROPARTIAL_PLEN_MAX
                    then
                        _patrol_micropartial_count = _patrol_micropartial_count + 1
                        if _patrol_micropartial_count >= PATROL_MICROPARTIAL_THRESHOLD then
                            console.print(string.format(
                                "[PATROL] ni=%d unreachable (%d consecutive plen<=%d limit_partial pathfinds)",
                                ni, _patrol_micropartial_count, PATROL_MICROPARTIAL_PLEN_MAX))
                            _patrol_skip_count = _patrol_skip_count + 1
                            if _patrol_skip_count >= PATROL_SKIP_TO_FREE_EXPLORE then
                                fallback_to_free_explore(string.format(
                                    "%d consecutive unreachable waypoints", _patrol_skip_count))
                            else
                                advance_ni("micro-partial pathfinds")
                            end
                            return
                        end
                    else
                        _patrol_micropartial_count = 0
                    end
                end
            end

            if not self._last_patrol_debug then self._last_patrol_debug = 0 end
            if settings.debug_log and now - self._last_patrol_debug > 2 then
                self._last_patrol_debug = now
                local player_speed = get_local_player():get_current_speed()
                local stuck_elapsed = patrol_stuck_time and (now - patrol_stuck_time) or 0
                console.print(string.format("[PATROL] ni=%d dist=%.1f speed=%.1f stuck=%.0fs player=(%.1f,%.1f) wp=(%.1f,%.1f)",
                    ni, utils.distance_to(wp), player_speed, stuck_elapsed, player_pos:x(), player_pos:y(), wp:x(), wp:y()))
                if BatmobilePlugin then
                    console.print(string.format("[PATROL] Batmobile: done=%s paused=%s",
                        tostring(BatmobilePlugin.is_done()), tostring(BatmobilePlugin.is_paused())))
                end
            end

            if BatmobilePlugin then
                bm_pulse()
            else
                patrol_move(tracker.waypoints[ni])
            end
        end
    end,

    -- QQT_Warpigz_v3: the event actor check_events engaged (self._event_skin
    -- at self._event_pos), not merely the closest pyre or pillar of either
    -- skin: with the Farm reach (up to 80 m) a spent pyre nearby would pull
    -- the bot away. The walk and the whole event are bounded
    -- (hr_mode.EVENT_WALK_MAX / EVENT_STAY_MAX); given up, it is skipped.
    move_to_pyre = function(self)
        local pyre = self:hr_event_target()
        if pyre and self:hr_event_timeout(tracker.hr_mode.EVENT_WALK_MAX, "[HELLTIDE] Event not reached in %ds — skipping it") then
            pyre = nil
        end
        if pyre then
            local dist = utils.distance_to(pyre)
            if dist > 2 then
                move_to(pyre, dist <= 4)
                return
            else
                self.current_state = helltide_state.INTERACT_PYRE
            end
        else
            clear_movement()
            self:hr_event_done()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    interact_pyre = function(self)
        local pyre = self:hr_event_target()
        -- QQT_Warpigz_v3: an interaction that never takes is bounded too.
        if pyre and self:hr_event_timeout(tracker.hr_mode.EVENT_STAY_MAX, "[HELLTIDE] Event still running after %ds — moving on") then
            pyre = nil
        end
        if pyre then
            if pyre:is_interactable() then
                interact_object(pyre)
            else
                self.current_state = helltide_state.STAY_NEAR_PYRE
            end
        else
            clear_movement()
            self:hr_event_done()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    stay_near_pyre = function(self)
        local pyre = self:hr_event_target()
        if pyre and self:hr_event_timeout(tracker.hr_mode.EVENT_STAY_MAX, "[HELLTIDE] Event still running after %ds — moving on") then
            pyre = nil
        end
        -- QQT_Warpigz_v3 3.3.3: a spent pyre / pillar stays listed after its
        -- event; no monster near it for EVENT_QUIET_S ends the stay (it
        -- parked the bot for the whole 240 s cap).
        if pyre and not pyre:is_interactable()
            and tracker.hr_watch.event_quiet(pyre:get_position(), get_time_since_inject()) then
            console.print(string.format("[HELLTIDE] Event over (no monster near it for %ds) — moving on",
                tracker.hr_watch.C.EVENT_QUIET_S))
            self:hr_event_skip()
            pyre = nil
        end
        if pyre then
            if pyre:is_interactable() then
                self.current_state = helltide_state.INTERACT_PYRE
            elseif utils.distance_to(pyre) > 1 then
                move_to(pyre, true)
                return
            end
        else
            clear_movement()
            self:hr_event_done()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    hr_event_target = function(self)
        if not self._event_skin or not self._event_pos then
            return find_closest_target("S04_Helltide_Prop_SoulSyphon_01_Dyn") or find_closest_target("S04_Helltide_FlamePillar_Switch_Dyn")
        end
        return chest_targets.at_position(get_cached_actors(), self._event_skin, self._event_pos)
    end,

    hr_event_done = function(self)
        self._event_skin, self._event_pos, self._event_at = nil, nil, nil
    end,

    -- check_events: engage an event unless it was given up on recently.
    hr_event_engage = function(self, target, skin)
        local pos = target:get_position()
        local now = get_time_since_inject()
        local key = skin .. math.floor(pos:x()) .. ',' .. math.floor(pos:y())
        local skip = self._event_skip and self._event_skip[key]
        if skip and skip > now then return false end
        self._event_skin, self._event_pos, self._event_at = skin, pos, now
        tracker.hr_watch.event_reset() -- QQT_Warpigz_v3 3.3.3
        return true
    end,

    -- The engaged event's time is up (limit seconds since it was chosen):
    -- logged, skipped for hr_mode.EVENT_SKIP_S, true.
    hr_event_timeout = function(self, limit, fmt)
        if not self._event_at or get_time_since_inject() - self._event_at <= limit then return false end
        console.print(string.format(fmt, limit))
        self:hr_event_skip()
        return true
    end,

    hr_event_skip = function(self)
        if self._event_skin and self._event_pos then
            self._event_skip = self._event_skip or {}
            local key = self._event_skin .. math.floor(self._event_pos:x()) .. ',' .. math.floor(self._event_pos:y())
            self._event_skip[key] = get_time_since_inject() + tracker.hr_mode.EVENT_SKIP_S
        end
    end,

    -- ── Maiden states ──────────────────────────────────────────────────────
    move_to_maiden = function(self)
        -- Re-evaluate gating every tick so a setting toggle / heart depletion
        -- releases us mid-route instead of finishing the walk first.
        local ok, why = should_do_maiden()
        if not ok then
            console.print("[MAIDEN] Releasing during route — " .. (why or "?"))
            maiden_pos = nil
            maiden_reset_cycle()
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end
        if not maiden_pos then maiden_pos = get_maiden_pos() end
        if not maiden_pos then
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end
        local dist = utils.distance_to(maiden_pos)
        if dist <= MAIDEN.ARRIVE_DIST then
            console.print(string.format("[MAIDEN] Arrived at altar (dist=%.1f) — entering AT_MAIDEN", dist))
            maiden_reset_cycle()
            self.current_state = helltide_state.AT_MAIDEN
            return
        end
        navigate_to(maiden_pos)
    end,

    at_maiden = function(self)
        -- Release condition (setting off / out of hearts / cinder threshold reached)
        local ok, why = should_do_maiden()
        if not ok then
            console.print("[MAIDEN] Releasing pin — " .. (why or "?"))
            maiden_pos = nil
            maiden_reset_cycle()
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        if not maiden_pos then maiden_pos = get_maiden_pos() end
        if not maiden_pos then
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local now = get_time_since_inject()
        local dist_to_pos = utils.distance_to(maiden_pos)

        -- Heart count helper (gracefully handle absence on older hosts).
        local hearts_fn = _G.get_helltide_coin_hearts
        local current_hearts = nil
        if hearts_fn then
            local ok_h, h = pcall(hearts_fn)
            if ok_h then current_hearts = h end
        end

        -- Find any nearby altar that's currently interactable. Per spec: 3
        -- altars exist; inserting into one makes it disappear / go non-
        -- interactable. We chase whichever is closest until none remain.
        local altar, altar_dist = find_maiden_altar(MAIDEN.ALTAR_SEARCH)

        -- Periodic state log (every 3s) so we can see what the bot's doing.
        if now - maiden_last_log_t > 3 then
            maiden_last_log_t = now
            console.print(string.format(
                "[MAIDEN] dist_to_pos=%.1f hearts=%s altar=%s in_flight=%s",
                dist_to_pos, tostring(current_hearts),
                altar and string.format("%.1f", altar_dist) or "none",
                maiden_insert_attempt_t and "yes" or "no"))
        end

        -- Lock enforcement: kill_monsters / dodge / knockback can drag the
        -- player out of the maiden site. Snap back BEFORE anything else when
        -- we're outside the lock radius — but ONLY measure against maiden_pos,
        -- not the altar (an altar that just spawned far is not a reason to
        -- abandon the lock).
        if dist_to_pos > MAIDEN.LOCK_RADIUS then
            if maiden_insert_attempt_t ~= nil then
                console.print("[MAIDEN] Drifted out of lock radius mid-insert — re-locking")
                maiden_insert_attempt_t       = nil
                maiden_pre_insert_heart_count = nil
            end
            navigate_to(maiden_pos)
            return
        end

        -- ── Heart insertion ────────────────────────────────────────────────
        -- Insert state machine. Skip when out of hearts (let combat / idle
        -- handle the rest of the tick). When we have hearts AND see an
        -- interactable altar, walk to it / interact / wait for the host's
        -- heart count to drop (= confirmation the insert took).
        local can_insert = (current_hearts == nil or current_hearts > 0)

        if maiden_insert_attempt_t ~= nil then
            -- Attempt in flight — wait for the heart count to drop or timeout.
            local elapsed = now - maiden_insert_attempt_t
            local before  = maiden_pre_insert_heart_count
            if before ~= nil and current_hearts ~= nil and current_hearts < before then
                console.print(string.format(
                    "[MAIDEN] Heart inserted (hearts %s -> %s)",
                    tostring(before), tostring(current_hearts)))
                maiden_insert_attempt_t       = nil
                maiden_pre_insert_heart_count = nil
            elseif elapsed >= MAIDEN.INSERT_RETRY then
                console.print(string.format(
                    "[MAIDEN] Insert attempt timed out after %.1fs — retrying", elapsed))
                maiden_insert_attempt_t       = nil
                maiden_pre_insert_heart_count = nil
            else
                -- Hold position during the charge window so the interact
                -- channel completes cleanly. Past the charge window, allow
                -- natural movement (combat / next altar walk).
                if elapsed < MAIDEN.INSERT_WAIT then
                    if BatmobilePlugin then BatmobilePlugin.pause(plugin_label) end
                    clear_movement()
                end
                return
            end
        end

        if can_insert and altar then
            if altar_dist <= MAIDEN.INTERACT_DIST then
                -- In range — start a new insert attempt.
                maiden_pre_insert_heart_count = current_hearts
                maiden_insert_attempt_t       = now
                console.print(string.format(
                    "[MAIDEN] Interacting with altar (dist=%.1f, hearts_before=%s)",
                    altar_dist, tostring(current_hearts)))
                interact_object(altar)
                if BatmobilePlugin then BatmobilePlugin.pause(plugin_label) end
                clear_movement()
                return
            else
                -- Altar visible but not close enough — walk to it. Caps at
                -- MAIDEN.LOCK_RADIUS via the early return above so we can't
                -- stray into the next zone chasing an outlier altar.
                navigate_to(altar:get_position())
                return
            end
        end

        -- ── Combat / pinning ───────────────────────────────────────────────
        -- No interactable altar OR no hearts to insert. Kill nearby monsters
        -- inside the lock zone, or idle on maiden_pos.
        local km_target = nil
        if settings.kill_monsters then
            km_target = get_kill_target()
            if km_target then
                local km_dist_to_pos = maiden_pos:dist_to(km_target:get_position())
                if km_dist_to_pos > MAIDEN.KILL_RADIUS then
                    km_target = nil  -- outside lock zone — ignore
                end
            end
        end

        if km_target then
            settings.orb_set_clear(true)
            local cur_dist = utils.distance_to(km_target)
            if cur_dist > 2 then
                if BatmobilePlugin then
                    BatmobilePlugin.pause(plugin_label)
                    BatmobilePlugin.set_target(plugin_label, km_target)
                    bm_pulse(false)
                else
                    native_move(km_target:get_position())
                end
            else
                if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            end
            return
        end

        -- Drift back to altar position if we're past the arrive threshold,
        -- otherwise idle so the navigator doesn't oscillate on micro-movement.
        if dist_to_pos > MAIDEN.ARRIVE_DIST then
            navigate_to(maiden_pos)
        else
            if BatmobilePlugin then
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.clear_target(plugin_label)
            end
            clear_movement()
        end
    end,

    move_to_silent_chest = function(self)
        if not found_silent_chest_position then
            console.print("[SILENT CHEST] No position data, returning to patrol")
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local dist_to_saved = utils.distance_to(found_silent_chest_position)

        -- Too far — give up
        if dist_to_saved > WAYPOINT_MAX_DIST then
            console.print(string.format("[SILENT CHEST] Too far (%.0f > %d), giving up", dist_to_saved, WAYPOINT_MAX_DIST))
            found_silent_chest_position = nil
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Try to find the actual actor
        local chest = find_closest_target("Hell_Prop_Chest_Rare_Locked")
        if chest and chest:is_interactable() then
            found_silent_chest_position = chest:get_position()
            local chest_dist = utils.distance_to(chest)

            if self:hr_chest_reach("silent", chest_dist) then -- QQT_Warpigz_v3 3.3.3: was chest_dist <= 2
                interact_object(chest)
                mark_chest_opened()
                self:hr_on_opened('silent', found_silent_chest_position) -- QQT_Warpigz_v3: stats
                found_silent_chest_position = nil
                clear_movement()
                return
            elseif chest_dist <= 6 then
                move_to(chest, chest_dist <= 4)
                return
            else
                navigate_to(chest)
                return
            end
        end

        -- Actor not loaded — navigate to cached position
        if dist_to_saved > 2 then
            navigate_to(found_silent_chest_position)
            return
        end

        -- At position but actor not loaded — wait with timeout
        if not tracker.check_time("chest_drop_time", 8) then
            return
        end

        console.print("[SILENT CHEST] Timed out waiting for actor, giving up")
        tracker.clear_key('chest_drop_time')
        found_silent_chest_position = nil
        clear_movement()
        self.current_state = helltide_state.EXPLORE_HELLTIDE
    end,

    move_to_helltide_chest = function(self)
        if not found_chest or not found_chest_position then
            console.print("[HELLTIDE CHEST] No chest data, returning to patrol")
            found_chest = nil
            found_chest_position = nil
            pre_interact_cinders = nil
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        if pre_interact_cinders == nil and not utils.check_cinders(found_chest) then
            local key = chest_key(found_chest, found_chest_position)
            remembered_chests[key] = {name = found_chest, cost = enums.chest_types[found_chest],
                position = found_chest_position, discovered_at = get_time_since_inject()}
            found_chest, found_chest_position = nil, nil
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local has_batmobile = BatmobilePlugin ~= nil
        local dist_to_saved = utils.distance_to(found_chest_position)

        -- Too far or drifting away — give up and resume patrol
        if dist_to_saved > WAYPOINT_MAX_DIST then
            console.print(string.format("[HELLTIDE CHEST] %s too far (%.0f > %d), giving up", found_chest, dist_to_saved, WAYPOINT_MAX_DIST))
            found_chest = nil
            found_chest_position = nil
            pre_interact_cinders = nil
            chest_stuck_reset()
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Stuck-near-unreachable detection: mirrors move_to_remembered_chest logic.
        -- If we're within CHEST_STUCK_RANGE but haven't closed CHEST_STUCK_PROGRESS
        -- meters in CHEST_STUCK_WINDOW seconds, the chest is likely on a cliff or
        -- behind a wall we can't path through. Blacklist it and resume patrol.
        local now_t = get_time_since_inject()
        local hkey  = chest_key(found_chest, found_chest_position)
        if _chest_stuck_key ~= hkey then
            _chest_stuck_key      = hkey
            _chest_stuck_t        = now_t
            _chest_stuck_dist     = dist_to_saved
            _chest_combat_block_t = nil
        elseif dist_to_saved <= CHEST_INTERACT_RANGE then
            -- At the chest — channeling, not stuck. Refresh the window so
            -- monster-interrupted opens don't blacklist a reachable chest.
            _chest_stuck_t    = now_t
            _chest_stuck_dist = dist_to_saved
            -- If a hostile is interrupting the channel, force orbwalker clear
            -- ON (overrides the >149-cinders gate) so combat actually clears
            -- them — otherwise we sit there getting hit and never opening.
            -- Cap the total combat-blocked time so a permanent block (mob
            -- chain right on top of the chest) eventually blacklists it.
            local kt = get_kill_target()
            if kt and utils.distance_to(kt) <= CHEST_STUCK_COMBAT_RANGE then
                settings.force_orb_clear_for(CHEST_COMBAT_FORCE_CLEAR_DURATION)
                if not _chest_combat_block_t then _chest_combat_block_t = now_t end
                if (now_t - _chest_combat_block_t) >= CHEST_COMBAT_BLOCK_LIMIT then
                    console.print(string.format(
                        "[HELLTIDE CHEST] %s combat-blocked at chest %.1fs (cap %.1fs) — blacklisting %.0fs and resuming patrol",
                        found_chest, now_t - _chest_combat_block_t, CHEST_COMBAT_BLOCK_LIMIT, CHEST_BLACKLIST_DURATION))
                    chest_temp_blacklist[hkey] = now_t + CHEST_BLACKLIST_DURATION
                    chest_blacklist_data[hkey] = {pos = found_chest_position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = found_chest}
                    found_chest = nil
                    found_chest_position = nil
                    pre_interact_cinders = nil
                    chest_stuck_reset()
                    clear_movement()
                    self.current_state = helltide_state.EXPLORE_HELLTIDE
                    return
                end
            else
                _chest_combat_block_t = nil
            end
        elseif dist_to_saved <= _chest_stuck_dist - CHEST_STUCK_PROGRESS then
            _chest_stuck_t        = now_t
            _chest_stuck_dist     = dist_to_saved
            _chest_combat_block_t = nil
        elseif dist_to_saved <= CHEST_STUCK_RANGE
                and (now_t - _chest_stuck_t) >= CHEST_STUCK_WINDOW then
            local kt = get_kill_target()
            if kt and utils.distance_to(kt) <= CHEST_STUCK_COMBAT_RANGE then
                -- Combat near the player is blocking progress, not geometry.
                -- Force orbwalker clear ON (overrides the cinder gate) and
                -- refresh the window so we don't blacklist a reachable chest
                -- just because a monster intercepted us en route. Hard cap
                -- via _chest_combat_block_t so we don't loop forever.
                settings.force_orb_clear_for(CHEST_COMBAT_FORCE_CLEAR_DURATION)
                if not _chest_combat_block_t then _chest_combat_block_t = now_t end
                if (now_t - _chest_combat_block_t) >= CHEST_COMBAT_BLOCK_LIMIT then
                    console.print(string.format(
                        "[HELLTIDE CHEST] %s combat-blocked en route %.1fs (cap %.1fs) — blacklisting %.0fs and resuming patrol",
                        found_chest, now_t - _chest_combat_block_t, CHEST_COMBAT_BLOCK_LIMIT, CHEST_BLACKLIST_DURATION))
                    chest_temp_blacklist[hkey] = now_t + CHEST_BLACKLIST_DURATION
                    chest_blacklist_data[hkey] = {pos = found_chest_position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = found_chest}
                    found_chest = nil
                    found_chest_position = nil
                    pre_interact_cinders = nil
                    chest_stuck_reset()
                    clear_movement()
                    self.current_state = helltide_state.EXPLORE_HELLTIDE
                    return
                end
                _chest_stuck_t    = now_t
                _chest_stuck_dist = dist_to_saved
            else
                console.print(string.format(
                    "[HELLTIDE CHEST] Stuck near %s (dist=%.1f, no >%.1fm progress in %.1fs) — blacklisting %.0fs and resuming patrol",
                    found_chest, dist_to_saved, CHEST_STUCK_PROGRESS, now_t - _chest_stuck_t, CHEST_BLACKLIST_DURATION))
                chest_temp_blacklist[hkey] = now_t + CHEST_BLACKLIST_DURATION
                chest_blacklist_data[hkey] = {pos = found_chest_position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = found_chest}
                found_chest = nil
                found_chest_position = nil
                pre_interact_cinders = nil
                chest_stuck_reset()
                clear_movement()
                self.current_state = helltide_state.EXPLORE_HELLTIDE
                return
            end
        end

        -- Throttled debug
        if not self._last_hchest_debug then self._last_hchest_debug = 0 end
        local now = get_time_since_inject()
        if settings.debug_log and now - self._last_hchest_debug > 2 then
            self._last_hchest_debug = now
            local player_pos = get_player_position()
            local speed = get_local_player():get_current_speed()
            console.print(string.format("[HELLTIDE CHEST] %s | dist_to_pos=%.1f | speed=%.1f | player=(%.1f,%.1f) target=(%.1f,%.1f)",
                found_chest, dist_to_saved, speed,
                player_pos:x(), player_pos:y(), found_chest_position:x(), found_chest_position:y()))
            if has_batmobile then
                console.print(string.format("[HELLTIDE CHEST] Batmobile: done=%s paused=%s",
                    tostring(BatmobilePlugin.is_done()), tostring(BatmobilePlugin.is_paused())))
            end
        end

        -- Cinder-decrement check: if we snapshotted cinders at the last
        -- interact and they've dropped, the chest opened (game charged us)
        -- even if the actor briefly stays interactable for one more tick.
        -- Catches cases where :is_interactable() lags by a frame.
        if pre_interact_cinders ~= nil
            and get_helltide_coin_cinders() < pre_interact_cinders
        then
            console.print(string.format(
                "[HELLTIDE CHEST] %s opened (cinders %d→%d) — holding %.1fs for loot",
                found_chest, pre_interact_cinders,
                get_helltide_coin_cinders(), CHEST_POST_OPEN_PAUSE))
            pre_interact_cinders = nil
            mark_chest_opened()
            self:hr_on_opened(found_chest, found_chest_position, nil, hkey) -- QQT_Warpigz_v3
            found_chest = nil
            found_chest_position = nil
            last_chest_interact_time = -math.huge
            tracker.clear_key('chest_drop_time')
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Try to find the actual actor
        local chest = chest_targets.at_position(get_cached_actors(), found_chest, found_chest_position)
        if chest then
            if not chest:is_interactable() then
                -- Chest exists but is no longer interactable — it opened successfully.
                -- Re-stamp the post-open pause from THIS moment (the actual open) so
                -- the full CHEST_POST_OPEN_PAUSE window covers loot drop time, not
                -- just whatever's left after the open animation.
                console.print(string.format("[HELLTIDE CHEST] %s opened (no longer interactable) — holding %.1fs for loot", found_chest, CHEST_POST_OPEN_PAUSE))
                pre_interact_cinders = nil
                mark_chest_opened()
                -- QQT_Warpigz_v3: counted only when we interacted with it.
                self:hr_on_opened(found_chest, found_chest_position,
                    {interacted = last_chest_interact_time > -math.huge}, hkey)
                found_chest = nil
                found_chest_position = nil
                last_chest_interact_time = -math.huge
                tracker.clear_key('chest_drop_time')
                self.current_state = helltide_state.EXPLORE_HELLTIDE
                return
            end

            found_chest_position = chest:get_position()
            local chest_dist = utils.distance_to(chest)

            if self:hr_chest_reach(hkey, chest_dist) then -- QQT_Warpigz_v3 3.3.3: was chest_dist <= 2
                -- Throttle interact calls so we don't restart the open animation timer.
                -- Stay in MOVING_TO_HELLTIDE_CHEST until the chest becomes non-interactable
                -- (opened) or disappears — handled by the paths below.
                -- Cooldown lines up with CHEST_POST_OPEN_PAUSE (3s) + 1s buffer so
                -- that if cinders didn't drop after the hold, the very next tick
                -- past cooldown retries the interact (channel was interrupted).
                local now = get_time_since_inject()
                if now - last_chest_interact_time >= CHEST_INTERACT_COOLDOWN then
                    if not allow_chest_interaction(found_chest, found_chest_position) then
                        found_chest, found_chest_position, pre_interact_cinders = nil, nil, nil
                        clear_movement()
                        self.current_state = helltide_state.EXPLORE_HELLTIDE
                        return
                    end
                    last_chest_interact_time = now
                    pre_interact_cinders = get_helltide_coin_cinders()
                    console.print(string.format(
                        "[HELLTIDE CHEST] Interacting with %s (cinders=%d, will verify drop)",
                        found_chest, pre_interact_cinders))
                    interact_object(chest)
                    mark_chest_opened()
                end
                return
            elseif chest_dist <= 6 then
                -- Close range: actor is directly reachable, use pause for precision
                move_to(chest, chest_dist <= 4)
                return
            else
                navigate_to(chest)
                return
            end
        end

        -- Actor not loaded — navigate to cached position (may need traversal)
        if dist_to_saved > 2 then
            navigate_to(found_chest_position)
            return
        end

        -- At the position but actor still not loaded — wait with timeout
        if not tracker.check_time("chest_drop_time", 8) then
            return
        end

        console.print(string.format("[HELLTIDE CHEST] Timed out waiting for %s actor, giving up", found_chest))
        tracker.clear_key('chest_drop_time')
        found_chest = nil
        found_chest_position = nil
        pre_interact_cinders = nil
        clear_movement()
        self.current_state = helltide_state.EXPLORE_HELLTIDE
    end,

    move_to_remembered_chest = function(self)
        local entry = remembered_chests[remembered_chest_target]
        if not entry then
            console.print("[CHEST RECALL] Remembered chest no longer valid, resuming patrol")
            remembered_chest_target = nil
            if BatmobilePlugin and BatmobilePlugin.stop_long_path then
                BatmobilePlugin.stop_long_path(plugin_label)
            end
            clear_movement()
            recall_state_reset()
            if BatmobilePlugin then BatmobilePlugin.resume(plugin_label) end
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Check we can still afford it
        local current_cinders = get_helltide_coin_cinders()
        if current_cinders < entry.cost then
            -- QQT_Warpigz_v3: our own interaction paid for it: it opened.
            if entry.interacted and entry.pre_cinders and current_cinders <= entry.pre_cinders - entry.cost then
                console.print(string.format("[CHEST RECALL] %s opened (cinders %d->%d)", entry.name, entry.pre_cinders, current_cinders))
                self:hr_on_opened(entry.name, entry.position, entry, remembered_chest_target)
            end
            console.print(string.format("[CHEST RECALL] Cinders dropped below %d, aborting return to %s", entry.cost, entry.name))
            remembered_chests[remembered_chest_target] = nil
            remembered_chest_target = nil
            if BatmobilePlugin and BatmobilePlugin.stop_long_path then
                BatmobilePlugin.stop_long_path(plugin_label)
            end
            clear_movement()
            recall_state_reset()
            if BatmobilePlugin then BatmobilePlugin.resume(plugin_label) end
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local dist = utils.distance_to(entry.position)
        -- QQT_Warpigz_v3: a better chest (a Mystery seen, a chest reset) may
        -- replace a smart-order target; never next to the chest (channel).
        if entry.smart and dist > 25 and self:hr_reconsider() then return end
        local has_batmobile = BatmobilePlugin ~= nil
        local long_path_active = has_batmobile
            and BatmobilePlugin.is_long_path_navigating
            and BatmobilePlugin.is_long_path_navigating()

        -- Stuck-near-unreachable detection: if we've been close (≤ CHEST_STUCK_RANGE)
        -- but distance hasn't decreased by CHEST_STUCK_PROGRESS in CHEST_STUCK_WINDOW
        -- seconds, the chest is likely blocked by a ledge/wall and the pathfinder
        -- keeps failing. Temporarily blacklist and patrol — a different approach
        -- angle later will probably find a route.
        local now_t = get_time_since_inject()
        if _chest_stuck_key ~= remembered_chest_target then
            _chest_stuck_key  = remembered_chest_target
            _chest_stuck_t    = now_t
            _chest_stuck_dist = dist
            _chest_micropartial_count   = 0
            _chest_micropartial_last_id = 0
            _chest_combat_block_t       = nil
        elseif entry.route and entry.route.mode ~= 'offroad' then
            -- QQT_Warpigz_v3: road and backtrack legs have their own watchdog
            -- (core/hr_roads.lua); the chest may get farther meanwhile.
            _chest_stuck_t    = now_t
            _chest_stuck_dist = dist
        elseif dist <= CHEST_INTERACT_RANGE then
            -- At the chest — channeling, not stuck. Refresh the window so
            -- monster-interrupted opens don't blacklist a reachable chest.
            -- Also clear the micro-partial counter (no pathfinding happens
            -- at this range, but be defensive against stale counts).
            _chest_stuck_t            = now_t
            _chest_stuck_dist         = dist
            _chest_micropartial_count = 0
            -- If a hostile is interrupting the channel, force orbwalker clear
            -- ON (overrides the >149-cinders gate) and cap total combat-blocked
            -- time so we eventually blacklist instead of standing here forever.
            local kt = get_kill_target()
            if kt and utils.distance_to(kt) <= CHEST_STUCK_COMBAT_RANGE then
                settings.force_orb_clear_for(CHEST_COMBAT_FORCE_CLEAR_DURATION)
                if not _chest_combat_block_t then _chest_combat_block_t = now_t end
                if (now_t - _chest_combat_block_t) >= CHEST_COMBAT_BLOCK_LIMIT then
                    console.print(string.format(
                        "[CHEST RECALL] %s combat-blocked at chest %.1fs (cap %.1fs) — blacklisting %.0fs and resuming patrol",
                        entry.name, now_t - _chest_combat_block_t, CHEST_COMBAT_BLOCK_LIMIT, CHEST_BLACKLIST_DURATION))
                    chest_temp_blacklist[remembered_chest_target] = now_t + CHEST_BLACKLIST_DURATION
                    chest_blacklist_data[remembered_chest_target] = {pos = entry.position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = entry.name}
                    if has_batmobile and BatmobilePlugin.stop_long_path then
                        BatmobilePlugin.stop_long_path(plugin_label)
                    end
                    clear_movement()
                    remembered_chest_target = nil
                    chest_stuck_reset()
                    self.current_state = helltide_state.EXPLORE_HELLTIDE
                    return
                end
            else
                _chest_combat_block_t = nil
            end
        elseif dist <= _chest_stuck_dist - CHEST_STUCK_PROGRESS then
            -- Made meaningful progress; reset the window.
            _chest_stuck_t        = now_t
            _chest_stuck_dist     = dist
            _chest_combat_block_t = nil
        elseif dist <= CHEST_STUCK_RANGE
                and (now_t - _chest_stuck_t) >= CHEST_STUCK_WINDOW then
            local kt = get_kill_target()
            if kt and utils.distance_to(kt) <= CHEST_STUCK_COMBAT_RANGE then
                -- Combat near the player is blocking progress, not geometry.
                -- Force orbwalker clear ON (overrides the cinder gate); hard
                -- cap via _chest_combat_block_t so we don't refresh forever.
                settings.force_orb_clear_for(CHEST_COMBAT_FORCE_CLEAR_DURATION)
                if not _chest_combat_block_t then _chest_combat_block_t = now_t end
                if (now_t - _chest_combat_block_t) >= CHEST_COMBAT_BLOCK_LIMIT then
                    console.print(string.format(
                        "[CHEST RECALL] %s combat-blocked en route %.1fs (cap %.1fs) — blacklisting %.0fs and resuming patrol",
                        entry.name, now_t - _chest_combat_block_t, CHEST_COMBAT_BLOCK_LIMIT, CHEST_BLACKLIST_DURATION))
                    chest_temp_blacklist[remembered_chest_target] = now_t + CHEST_BLACKLIST_DURATION
                    chest_blacklist_data[remembered_chest_target] = {pos = entry.position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = entry.name}
                    if has_batmobile and BatmobilePlugin.stop_long_path then
                        BatmobilePlugin.stop_long_path(plugin_label)
                    end
                    clear_movement()
                    remembered_chest_target = nil
                    chest_stuck_reset()
                    self.current_state = helltide_state.EXPLORE_HELLTIDE
                    return
                end
                _chest_stuck_t    = now_t
                _chest_stuck_dist = dist
            elseif entry.route and self:hr_offroad_stuck(entry) then
                -- QQT_Warpigz_v3: back to the road, then another way to the
                -- chest (core/hr_roads.lua, at most 3); blacklisted after that.
                _chest_stuck_t    = now_t
                _chest_stuck_dist = dist
            else
                console.print(string.format(
                    "[CHEST RECALL] Stuck near %s (dist=%.1f, no >%.1fm progress in %.1fs) — blacklisting %.0fs and resuming patrol",
                    entry.name, dist, CHEST_STUCK_PROGRESS, now_t - _chest_stuck_t, CHEST_BLACKLIST_DURATION))
                chest_temp_blacklist[remembered_chest_target] = now_t + CHEST_BLACKLIST_DURATION
                chest_blacklist_data[remembered_chest_target] = {pos = entry.position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = entry.name}
                self:hr_trip_failed(entry, remembered_chest_target, 'stuck') -- QQT_Warpigz_v3
                if has_batmobile and BatmobilePlugin.stop_long_path then
                    BatmobilePlugin.stop_long_path(plugin_label)
                end
                clear_movement()
                remembered_chest_target = nil
                chest_stuck_reset()
                self.current_state = helltide_state.EXPLORE_HELLTIDE
                return
            end
        end

        -- Micro-partial detector: pathfinder consistently returning a 2-node
        -- limit_partial for this chest goal means A* couldn't get close in its
        -- time budget — almost always a cliff/wall with no traversal nearby.
        -- Catches the failure ~1.5s before the 12s no-progress timer fires.
        if has_batmobile and BatmobilePlugin.get_last_pathfind then
            local pf = BatmobilePlugin.get_last_pathfind()
            if pf and pf.call_id ~= _chest_micropartial_last_id then
                _chest_micropartial_last_id = pf.call_id
                local goal_match = math.abs(pf.goal_x - entry.position:x()) < 3
                                   and math.abs(pf.goal_y - entry.position:y()) < 3
                if goal_match
                   and pf.status == "limit_partial"
                   and pf.plen <= CHEST_MICROPARTIAL_PLEN_MAX
                then
                    _chest_micropartial_count = _chest_micropartial_count + 1
                    if _chest_micropartial_count >= CHEST_MICROPARTIAL_THRESHOLD then
                        console.print(string.format(
                            "[CHEST RECALL] %s unreachable (%d consecutive plen<=%d limit_partial pathfinds, dist=%.1f) — blacklisting %.0fs and resuming patrol",
                            entry.name, _chest_micropartial_count, CHEST_MICROPARTIAL_PLEN_MAX, dist, CHEST_BLACKLIST_DURATION))
                        chest_temp_blacklist[remembered_chest_target] = now_t + CHEST_BLACKLIST_DURATION
                        chest_blacklist_data[remembered_chest_target] = {pos = entry.position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = entry.name}
                        self:hr_trip_failed(entry, remembered_chest_target, 'stuck') -- QQT_Warpigz_v3
                        if has_batmobile and BatmobilePlugin.stop_long_path then
                            BatmobilePlugin.stop_long_path(plugin_label)
                        end
                        clear_movement()
                        remembered_chest_target = nil
                        chest_stuck_reset()
                        self.current_state = helltide_state.EXPLORE_HELLTIDE
                        return
                    end
                else
                    _chest_micropartial_count = 0
                end
            end
        end

        -- Give up if chest has drifted beyond the max range (player moved away during navigation)
        -- QQT_Warpigz_v3: a road route (patrol loop) is bounded by the loop instead.
        if dist > REMEMBERED_CHEST_MAX_DIST and not entry.route then
            console.print(string.format("[CHEST RECALL] %s is too far (%.0f), forgetting it", entry.name, dist))
            self:hr_trip_failed(entry, remembered_chest_target, 'far') -- QQT_Warpigz_v3: not picked again at once
            remembered_chests[remembered_chest_target] = nil
            remembered_chest_target = nil
            if has_batmobile and BatmobilePlugin.stop_long_path then
                BatmobilePlugin.stop_long_path(plugin_label)
            end
            clear_movement()
            recall_state_reset()
            if has_batmobile then BatmobilePlugin.resume(plugin_label) end
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Throttled debug logging
        if not self._last_recall_debug then self._last_recall_debug = 0 end
        local now = get_time_since_inject()
        if settings.debug_log and now - self._last_recall_debug > 2 then
            self._last_recall_debug = now
            local player_pos = get_player_position()
            local player_speed = get_local_player():get_current_speed()
            console.print(string.format("[CHEST RECALL] %s | dist=%.1f | speed=%.1f | cinders=%d/%d | long_path=%s",
                entry.name, dist, player_speed, current_cinders, entry.cost, tostring(long_path_active)))
            console.print(string.format("[CHEST RECALL] player=(%.1f,%.1f) target=(%.1f,%.1f)",
                player_pos:x(), player_pos:y(), entry.position:x(), entry.position:y()))
            if has_batmobile then
                console.print(string.format("[CHEST RECALL] Batmobile: done=%s paused=%s",
                    tostring(BatmobilePlugin.is_done()), tostring(BatmobilePlugin.is_paused())))
            end
        end

        -- QQT_Warpigz_v3: road route: along the patrol loop until the hand-off
        -- (core/hr_roads.lua); the last stretch uses the recall below.
        if entry.route and self:hr_road_step(entry, dist) then return end

        -- Close range: stop long path and use precision nav
        if dist < 15 then
            if has_batmobile and BatmobilePlugin.stop_long_path then
                BatmobilePlugin.stop_long_path(plugin_label)
            end

            local chest = chest_targets.at_position(get_cached_actors(), entry.name, entry.position)
            -- QQT_Warpigz_v3: a learned spot takes any chest of its kind (the
            -- regular gear type rotates at the same place).
            if not chest and entry.predicted then chest = self:hr_spot_chest(entry) end
            if chest then
                -- Chest exists but is no longer interactable — open succeeded.
                -- Only now is it safe to drop the remembered entry; previously
                -- we wiped on the first interact_object call, which lost the
                -- chest whenever a monster interrupted the channel.
                if not chest:is_interactable() then
                    console.print(string.format("[CHEST RECALL] %s opened (no longer interactable) — holding %.1fs for loot", entry.name, CHEST_POST_OPEN_PAUSE))
                    mark_chest_opened()
                    self:hr_on_opened(entry.name, chest:get_position(), entry, remembered_chest_target) -- QQT_Warpigz_v3
                    if settings.experimental_explorer then
                        helltide_explorer.mark_chest_opened(chest:get_position())
                    end
                    remembered_chests[remembered_chest_target] = nil
                    remembered_chest_target = nil
                    last_chest_interact_time = -math.huge
                    tracker.clear_key("remembered_chest_timeout")
                    recall_state_reset()
                    self.current_state = helltide_state.EXPLORE_HELLTIDE
                    return
                end

                local chest_dist = utils.distance_to(chest)
                if self:hr_chest_reach(remembered_chest_target, chest_dist) then -- QQT_Warpigz_v3 3.3.3: was <= 2
                    -- Throttled interact — same pattern as move_to_helltide_chest.
                    -- Stay in MOVING_TO_REMEMBERED_CHEST until the chest goes
                    -- non-interactable (handled above) so a monster-interrupted
                    -- channel just retries instead of giving up the entry.
                    local now = get_time_since_inject()
                    if now - last_chest_interact_time >= CHEST_INTERACT_COOLDOWN then
                        if not allow_chest_interaction(entry.name, entry.position) then
                            remembered_chest_target = nil
                            clear_movement()
                            self.current_state = helltide_state.EXPLORE_HELLTIDE
                            return
                        end
                        last_chest_interact_time = now
                        console.print(string.format("[CHEST RECALL] Opening remembered %s", entry.name))
                        -- QQT_Warpigz_v3: counted as opened (stats) once it is spent or paid.
                        entry.interacted = true
                        entry.pre_cinders = entry.pre_cinders or current_cinders
                        interact_object(chest)
                        mark_chest_opened()
                    end
                    return
                elseif chest_dist <= 6 then
                    move_to(chest, chest_dist <= 4)
                    return
                else
                    navigate_to(chest)
                    return
                end
            end

            -- QQT_Warpigz_v3: a learned (predicted) spot without a chest this
            -- time (2 s within 15 m: the actor list is cached for 1 s): one
            -- miss for the atlas, then the next target.
            if entry.predicted and tracker.check_time("remembered_chest_timeout", 2) then
                self:hr_predicted_miss(entry)
                return
            end

            -- Close but actor not found — chest may have despawned
            if not tracker.check_time("remembered_chest_timeout", 6) then
                navigate_to(entry.position)
                return
            end

            console.print(string.format("[CHEST RECALL] %s not found at saved location, removing", entry.name))
            remembered_chests[remembered_chest_target] = nil
            remembered_chest_target = nil
            tracker.clear_key("remembered_chest_timeout")
            clear_movement()
            recall_state_reset()
            if has_batmobile then BatmobilePlugin.resume(plugin_label) end
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Far away: use long path with retry + watchdogs (mirrors Arkham kill_boss
        -- remembered_hunt). Pausing Batmobile is essential — without pause, the
        -- navigator overrides our custom target with explorer-picked frontiers
        -- whenever A* fails on the goal, and HR re-asserts the target each tick,
        -- producing a ping-pong that never makes progress.
        if has_batmobile and BatmobilePlugin.navigate_long_path and BatmobilePlugin.is_long_path_navigating then
            BatmobilePlugin.pause(plugin_label)

            -- No-progress watchdog: track best-ever distance to chest. If it
            -- doesn't shrink by RECALL.PROGRESS_DELTA in RECALL.NO_PROGRESS_SECS,
            -- the chest is unreachable from the current side — blacklist and
            -- yield to patrol.
            if _recall_best_dist == nil
                or dist < _recall_best_dist - RECALL.PROGRESS_DELTA
            then
                _recall_best_dist     = dist
                _recall_progress_time = now_t
            end
            if _recall_progress_time
                and (now_t - _recall_progress_time) > RECALL.NO_PROGRESS_SECS
            then
                console.print(string.format(
                    "[CHEST RECALL] no progress toward %s for %ds (best=%.1f cur=%.1f) — blacklisting %.0fs and resuming patrol",
                    entry.name, RECALL.NO_PROGRESS_SECS, _recall_best_dist, dist, CHEST_BLACKLIST_DURATION))
                chest_temp_blacklist[remembered_chest_target] = now_t + CHEST_BLACKLIST_DURATION
                chest_blacklist_data[remembered_chest_target] = {pos = entry.position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = entry.name}
                self:hr_trip_failed(entry, remembered_chest_target, 'stuck') -- QQT_Warpigz_v3
                if BatmobilePlugin.stop_long_path then
                    BatmobilePlugin.stop_long_path(plugin_label)
                end
                clear_movement()
                BatmobilePlugin.resume(plugin_label)
                remembered_chest_target = nil
                chest_stuck_reset()
                self.current_state = helltide_state.EXPLORE_HELLTIDE
                return
            end

            -- (Re)issue navigate_long_path: first attempt, target drift, or
            -- long-path session ended (completed/failed) and retry interval
            -- elapsed. Failure-count guard blacklists after RECALL.FAIL_THRESHOLD
            -- consecutive returns=false (target genuinely unreachable from here).
            local need_repath = false
            if _recall_long_path_target == nil then
                need_repath = (now_t - _recall_path_issue_time) > RECALL.LONG_PATH_RETRY
            elseif _recall_long_path_target:dist_to(entry.position) > 3 then
                need_repath = true
            elseif not long_path_active
                and (now_t - _recall_path_issue_time) > RECALL.LONG_PATH_RETRY
            then
                need_repath = true
            end
            if need_repath then
                movement_owned = true
                local ok = BatmobilePlugin.navigate_long_path(plugin_label, entry.position)
                _recall_path_issue_time = now_t
                if ok then
                    _recall_long_path_target = vec3:new(entry.position:x(), entry.position:y(), entry.position:z())
                    _recall_fail_count = 0
                    console.print(string.format("[CHEST RECALL] Long path started to %s (%.1f,%.1f)",
                        entry.name, entry.position:x(), entry.position:y()))
                else
                    _recall_long_path_target = nil
                    _recall_fail_count = _recall_fail_count + 1
                    console.print(string.format(
                        "[CHEST RECALL] long_path to %s failed (#%d/%d)",
                        entry.name, _recall_fail_count, RECALL.FAIL_THRESHOLD))
                    if _recall_fail_count >= RECALL.FAIL_THRESHOLD then
                        console.print(string.format(
                            "[CHEST RECALL] %d consecutive long_path failures — blacklisting %s for %.0fs and resuming patrol",
                            RECALL.FAIL_THRESHOLD, entry.name, CHEST_BLACKLIST_DURATION))
                        chest_temp_blacklist[remembered_chest_target] = now_t + CHEST_BLACKLIST_DURATION
                        chest_blacklist_data[remembered_chest_target] = {pos = entry.position, expiry = now_t + CHEST_BLACKLIST_DURATION, name = entry.name}
                        self:hr_trip_failed(entry, remembered_chest_target, 'stuck') -- QQT_Warpigz_v3
                        if BatmobilePlugin.stop_long_path then
                            BatmobilePlugin.stop_long_path(plugin_label)
                        end
                        clear_movement()
                        BatmobilePlugin.resume(plugin_label)
                        remembered_chest_target = nil
                        chest_stuck_reset()
                        self.current_state = helltide_state.EXPLORE_HELLTIDE
                        return
                    end
                end
            end
            -- Drive whichever long-path session is active (or just-issued).
            bm_pulse(true)
        else
            navigate_to(entry.position)
        end
    end,

    farm_chest_cinders = function(self)
        -- QQT_Warpigz_v3: never in Farm mode (a mode switch mid-farm releases it).
        if farm_chest_entry and tracker.hr_mode.is_farm() then
            remembered_chests[chest_key(farm_chest_entry.name, farm_chest_entry.position)] = farm_chest_entry
            farm_chest_entry = nil
            clear_movement()
        end
        if not farm_chest_entry then
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local current_cinders = get_helltide_coin_cinders()
        local chest_pos = farm_chest_entry.position
        local dist_to_chest = utils.distance_to(chest_pos)
        local now = get_time_since_inject()

        -- Can now afford it — hand off to the normal chest-open flow
        if current_cinders >= farm_chest_entry.cost then
            console.print(string.format("[FARM CHEST] Now affordable (%d/%d) — moving to open %s",
                current_cinders, farm_chest_entry.cost, farm_chest_entry.name))
            found_chest = farm_chest_entry.name
            found_chest_position = chest_pos
            farm_chest_entry = nil
            tracker.clear_key("farm_chest_gone")
            clear_movement()
            self.current_state = helltide_state.MOVING_TO_HELLTIDE_CHEST
            return
        end

        -- When close, verify chest actor still exists (may have despawned or been opened by another)
        if dist_to_chest <= 20 then
            local chest_actor = chest_targets.at_position(get_cached_actors(), farm_chest_entry.name, farm_chest_entry.position)
            if chest_actor and chest_actor:is_interactable() then
                tracker.clear_key("farm_chest_gone")
            else
                if not tracker.check_time("farm_chest_gone", 8) then
                    -- Still within grace window — keep farming
                else
                    console.print(string.format("[FARM CHEST] %s not found within 20m for 8s — resuming patrol",
                        farm_chest_entry.name))
                    farm_chest_entry = nil
                    tracker.clear_key("farm_chest_gone")
                    clear_movement()
                    self.current_state = helltide_state.EXPLORE_HELLTIDE
                    return
                end
            end
        end

        -- Throttled debug
        if not self._last_farm_debug then self._last_farm_debug = 0 end
        if settings.debug_log and now - self._last_farm_debug > 3 then
            self._last_farm_debug = now
            local km_target = get_kill_target()
            console.print(string.format("[FARM CHEST] %s | need %d more cinders (%d/%d) | dist_to_chest=%.1f | has_target=%s",
                farm_chest_entry.name, farm_chest_entry.cost - current_cinders,
                current_cinders, farm_chest_entry.cost, dist_to_chest, tostring(km_target ~= nil)))
        end

        -- If outside 35-unit circle, navigate back in.
        -- 35 (not 50) gives enough buffer so that by the time the player actually
        -- stops and re-routes, they haven't drifted far past the intended boundary.
        if dist_to_chest > 35 then
            navigate_to(chest_pos)
            return
        end

        -- Inside circle: kill monsters, or free-roam to find them
        settings.orb_set_clear(true)
        local km_target = get_kill_target()
        if km_target then
            local cur_dist = utils.distance_to(km_target)
            local target_pos = km_target:get_position()
            if cur_dist > 2 then
                if BatmobilePlugin then
                    BatmobilePlugin.pause(plugin_label)
                    local accepted = BatmobilePlugin.set_target(plugin_label, km_target)
                    if accepted == false then
                        km_mark_unreachable(target_pos)
                    else
                        bm_pulse(true)
                    end
                else
                    native_move(target_pos)
                end
            else
                if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            end
        else
            -- No monsters — cycle through evenly-spaced ring patrol around the chest.
            -- Batmobile free-roam would oscillate on its own backtrack path (same corridor
            -- back-and-forth); explicit ring waypoints cover all directions systematically.
            if farm_roam_built_for ~= chest_pos or #farm_roam_points == 0 then
                build_farm_roam(chest_pos)
            end
            local roam_target = farm_roam_points[farm_roam_idx]
            local player_pos  = get_player_position()
            if player_pos:dist_to(roam_target) <= FARM_ROAM_ARRIVE then
                farm_roam_idx = (farm_roam_idx % FARM_ROAM_COUNT) + 1
                roam_target   = farm_roam_points[farm_roam_idx]
                console.print(string.format("[FARM CHEST] No monsters — roam patrol point %d/%d",
                    farm_roam_idx, FARM_ROAM_COUNT))
            end
            navigate_to(roam_target)
        end
    end,

    move_to_ore = function(self)
        if found_ore and found_ore:is_interactable() then
            local dist = utils.distance_to(found_ore)
            if dist >= 2 then
                move_to(found_ore, dist <= 4)
                return
            end
            interact_object(found_ore)
        else
            found_ore = nil
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    move_to_herb = function(self)
        if found_herb and found_herb:is_interactable() then
            local dist = utils.distance_to(found_herb)
            if dist >= 2 then
                move_to(found_herb, dist <= 4)
                return
            end
            interact_object(found_herb)
        else
            found_herb = nil
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    move_to_shrine = function(self)
        local shrine = find_closest_target("Shrine_")
        if shrine and shrine:is_interactable() then
            local dist = utils.distance_to(shrine)
            if dist > 2 then
                move_to(shrine, dist <= 4)
                return
            else
                interact_object(shrine)
            end
        else
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    chase_goblin = function(self)
        local goblin = find_closest_target("treasure_goblin")
        if goblin and goblin:get_current_health() > 1 then
            if utils.distance_to(goblin) > 2 then
                move_to(goblin, false) -- never disable spells chasing goblins
                return
            end
        else
            if not tracker.check_time("goblin_drop_time", 4) then
                return
            end
            tracker.clear_key('goblin_drop_time')
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    kill_monsters = function(self)
        settings.orb_set_clear(true)
        local local_player = get_local_player()
        if not local_player then
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local target = get_kill_target()
        -- QQT_Warpigz_v3: Farm: not parked in one spot by a stream of plain
        -- monsters; the patrol moves on (core/hr_mode.lua km_hold, logged there).
        if target and tracker.hr_mode.km_hold(get_time_since_inject(), get_player_position(), target) then
            target = nil
        end
        if not target then
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            console.print("[KILL MONSTERS] No targets, resuming patrol")
            _km_micropartial_count = 0
            _km_micropartial_last_id = 0
            _km_micropartial_key = nil
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        local target_pos = target:get_position()
        local cur_dist = utils.distance_to(target)

        -- QQT_Warpigz_v3 3.3.3: a target that takes no damage and gets no
        -- closer (immune, out of reach, pacing behind a wall) is ignored for
        -- a while; at <= 2 m it had no bound at all.
        if tracker.hr_watch.km_no_effect(target, get_time_since_inject(), cur_dist) then
            console.print(string.format("[KILL MONSTERS] No damage and no progress on the target for %ds — ignoring it for %ds",
                tracker.hr_watch.C.KM_NO_EFFECT_S, tracker.hr_watch.C.KM_IGNORE_S))
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            self.current_state = helltide_state.EXPLORE_HELLTIDE
            return
        end

        -- Per-position progress tracking: timer persists across target switches
        -- so a monster that's intermittently targeted still accumulates time toward the unreachable timeout
        local nav_key = math.floor(target_pos:x()) .. ',' .. math.floor(target_pos:y())
        local now = get_time_since_inject()
        local nav = km_nav_map[nav_key]
        if not nav then
            -- QQT_Warpigz_v3 3.3.3 (audit): drop stale cells (the map grew all
            -- Helltide long and credit_yield walks all of it).
            for key, old in pairs(km_nav_map) do
                if now - old.time > 10 then km_nav_map[key] = nil end
            end
            km_nav_map[nav_key] = { time = now, dist = cur_dist }
        elseif cur_dist < nav.dist - 2 then
            nav.dist = cur_dist
            nav.time = now
        elseif now - nav.time > 5 then
            km_nav_map[nav_key] = nil
            km_mark_unreachable(target_pos)
            _km_micropartial_count = 0
            _km_micropartial_last_id = 0
            _km_micropartial_key = nil
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            return
        end

        -- Reset micro-partial counter on target switch so a fresh enemy starts clean
        if _km_micropartial_key ~= nav_key then
            _km_micropartial_key = nav_key
            _km_micropartial_count = 0
            _km_micropartial_last_id = 0
        end

        if cur_dist > 2 then
            perf.inc("km_target_far")
            if BatmobilePlugin then
                -- Use pause (not resume) so the long-path navigator state is frozen
                -- while fighting — long_path.navigating stays true, path resumes after combat.
                BatmobilePlugin.pause(plugin_label)
                perf.start("km_set_target")
                local accepted = BatmobilePlugin.set_target(plugin_label, target)
                perf.stop("km_set_target", string.format("dist=%.1f", cur_dist))
                if accepted == false then
                    perf.inc("km_set_target_rejected")
                    km_mark_unreachable(target_pos)
                    km_nav_map[nav_key] = nil
                    _km_micropartial_count = 0
                    _km_micropartial_last_id = 0
                    _km_micropartial_key = nil
                    BatmobilePlugin.clear_target(plugin_label)
                    return
                end
                -- Micro-partial detector: A* returning plen<=2 limit_partial against
                -- the same enemy for ~20 consecutive pathfinds = behind unwalkable
                -- terrain. Catches "ledge geometry" cases ~3s faster than the 5s
                -- distance-stall timeout above. Mirrors patrol_micropartial.
                if BatmobilePlugin.get_last_pathfind then
                    local pf = BatmobilePlugin.get_last_pathfind()
                    if pf and pf.call_id ~= _km_micropartial_last_id then
                        _km_micropartial_last_id = pf.call_id
                        local goal_match = math.abs(pf.goal_x - target_pos:x()) < KM_MICROPARTIAL_GOAL_TOL
                                           and math.abs(pf.goal_y - target_pos:y()) < KM_MICROPARTIAL_GOAL_TOL
                        if goal_match
                           and pf.status == "limit_partial"
                           and pf.plen <= KM_MICROPARTIAL_PLEN_MAX
                        then
                            _km_micropartial_count = _km_micropartial_count + 1
                            if _km_micropartial_count >= KM_MICROPARTIAL_THRESHOLD then
                                console.print(string.format(
                                    "[KILL MONSTERS] Micro-partial threshold hit (n=%d plen<=%d) — marking unreachable",
                                    _km_micropartial_count, KM_MICROPARTIAL_PLEN_MAX))
                                km_mark_unreachable(target_pos)
                                km_nav_map[nav_key] = nil
                                _km_micropartial_count = 0
                                _km_micropartial_last_id = 0
                                _km_micropartial_key = nil
                                BatmobilePlugin.clear_target(plugin_label)
                                return
                            end
                        else
                            _km_micropartial_count = 0
                        end
                    end
                end
                -- Respect the 10Hz throttle: enemies don't move fast enough that
                -- 100ms of nav staleness affects targeting, but each forced pulse
                -- runs the full Batmobile update+move (~30ms avg, 140ms+ peak per
                -- logzewx).  set_target above already updates the target every tick;
                -- the throttled pulse keeps the active path running without re-doing
                -- the heavy explorer.update + find_path on every kill_monsters tick.
                perf.start("km_bm_pulse")
                bm_pulse(false)
                perf.stop("km_bm_pulse", string.format("dist=%.1f", cur_dist))
            else
                native_move(target_pos)
            end
        else
            perf.inc("km_target_close")
            km_nav_map[nav_key] = nil  -- reached target, clear tracking entry
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
        end
    end,

    move_to_chaos_rift = function(self)
        local chaos_rift = find_closest_target("S10_ChaosRiftChoiceGizmo")
        if chaos_rift then
            local dist = utils.distance_to(chaos_rift)
            if dist > 2 then
                move_to(chaos_rift, dist <= 4)
                return
            else
                self.current_state = helltide_state.INTERACT_CHAOS_RIFT
            end
        else
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    interact_chaos_rift = function(self)
        local chaos_rift = find_closest_target("S10_ChaosRiftChoiceGizmo")
        if chaos_rift then
            if chaos_rift:is_interactable() then
                interact_object(chaos_rift)
            else
                self.current_state = helltide_state.STAY_NEAR_CHAOS_RIFT
            end
        else
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    stay_near_chaos_rift = function(self)
        local chaos_rift = find_closest_target("S10_ChaosRiftChoiceGizmo") or find_closest_target("S10_ChaosRiftPortal") or find_closest_target("MarkerLocation_BSK_Occupied")
        if chaos_rift then
            if chaos_rift:is_interactable() then
                self.current_state = helltide_state.INTERACT_CHAOS_RIFT
            elseif utils.distance_to(chaos_rift) > 1 then
                move_to(chaos_rift, true)
                return
            end
        else
            -- Chaos rift finished but wait for loot
            if not tracker.check_time("chaos_rift_loot_time", 4) then
                return
            end
            tracker.clear_key('chaos_rift_loot_time')
            clear_movement()
            self.current_state = helltide_state.EXPLORE_HELLTIDE
        end
    end,

    back_to_town = function(self)
        clear_movement()
        if self.current_state == helltide_state.BACK_TO_TOWN then
            -- HLT-3: Batmobile give-up recovery owns this trip. The buff still
            -- present means the waypoint channel was interrupted (damage):
            -- keep clearing the mobs and re-fire it (6 s channel debounce).
            -- Salvage waits until we are out: an Alfred with-teleport trip
            -- from here would portal straight back into the trap.
            -- QQT_Warpigz_v2 (2.2.1, live rc.13): once the trip reached town
            -- the recovery is over. Coming back (search found the same, only
            -- active Helltide) starts a fresh session instead of teleporting
            -- out again in an endless town <-> Helltide loop.
            if not utils.is_in_helltide() then
                self._abandon_reached_town = true
            elseif self._abandon_reached_town then
                console.print("[HELLTIDE] Back in the Helltide after the trap recovery — starting fresh")
                self._abandon_reached_town = nil
                tracker.abandoning_zone = nil
                force_zone_change = false
                self.current_state = helltide_state.INIT
                return
            end
            if utils.is_in_helltide() then
                settings.force_orb_clear_for(5)
                local now = get_time_since_inject()
                if now - (self._town_tp_at or -math.huge) >= 6 and not utils.is_teleporting() then
                    console.print("[HELLTIDE] Still in the abandoned zone — re-firing the town teleport")
                    teleport_to_waypoint(settings.town_waypoint)
                    self._town_tp_at = now
                end
            end
            return
        end
        if settings.salvage then
            tracker.needs_salvage = true
        end
    end,

    return_from_salvage = function(self)
        if not tracker.check_time("salvage_return_time", 3) then
            return
        end
        tracker.has_salvaged = false
        tracker.clear_key('salvage_return_time')
        self.current_state = helltide_state.EXPLORE_HELLTIDE
    end,

    -- C5/L11/CRT-4: seconds in which the state handlers did not run (Looter
    -- or Alfred yield, another HR task, loading, revive) never count toward a
    -- no-progress/stuck/timeout window that blacklists or abandons a target.
    -- Only a real gap is credited; ordinary ticks are far below 0.5 s. The
    -- geometry detectors themselves are unchanged.
    credit_yield = function(self, now)
        local last = self._handlers_ran_at
        self._handlers_ran_at = now
        local why = self.hold_reason -- QQT_Warpigz_v3: named in the resume log
        self.hold_reason, self._hold_since = nil, nil
        local gap = last and (now - last) or 0
        if gap < 0.5 then return end
        _chest_stuck_t = _chest_stuck_t + gap
        if _chest_combat_block_t then _chest_combat_block_t = _chest_combat_block_t + gap end
        if _recall_progress_time then _recall_progress_time = _recall_progress_time + gap end
        if trav_start_time then trav_start_time = trav_start_time + gap end
        if patrol_stuck_time then patrol_stuck_time = patrol_stuck_time + gap end
        if patrol_free_explore_start then patrol_free_explore_start = patrol_free_explore_start + gap end
        for _, nav in pairs(km_nav_map) do nav.time = nav.time + gap end
        -- Rupture timers (cap, approach, wait-open, Realmwalker, ...) too.
        tracker.tear_event.credit_yield(gap)
        tracker.hr_watch.credit(gap) -- QQT_Warpigz_v3 3.3.3
        for _, key in ipairs({"chest_drop_time", "remembered_chest_timeout", "farm_chest_gone"}) do
            if tracker[key] then tracker[key] = tracker[key] + gap end
        end
        -- A companion may have pulled the player away meanwhile: measure the
        -- chest's progress from here, never from the pre-yield distance.
        local pos
        if self.current_state == helltide_state.MOVING_TO_HELLTIDE_CHEST then
            pos = found_chest_position
        elseif self.current_state == helltide_state.MOVING_TO_REMEMBERED_CHEST then
            local entry = remembered_chest_target and remembered_chests[remembered_chest_target]
            pos = entry and entry.position
            -- QQT_Warpigz_v3: the road route's no-progress window too.
            if entry and entry.route and tracker.hr_roads then tracker.hr_roads.credit(entry.route, gap) end
        end
        if pos and _chest_stuck_key then
            local d = utils.distance_to(pos)
            if d > _chest_stuck_dist then _chest_stuck_dist = d end
        end
        if gap >= 5 then
            -- QQT_Warpigz_v3: name the hold ("Looter", or its hold reason).
            why = why and (why:find("Looter", 1, true) and " (Looter)" or (" (" .. why .. ")")) or ""
            console.print(string.format("[HELLTIDE] Resumed after %.1fs yield%s — stuck/no-progress windows paused meanwhile",
                gap, why))
        end
    end,

    -- QQT_Warpigz_v3 (C6, live 12-39 s waits): the in-Helltide Looter hold
    -- has its own bound, like search_helltide's loot_hold. Rosie keeps busy
    -- set across drops, so drops it wants but cannot take (~18 s each) added
    -- up to one long freeze. The window restarts whenever the bag item count
    -- rises (a Mystery chest drop picked up item by item is never cut off);
    -- after 15 s of continuous busy without a new item HR farms on until
    -- busy drops (logged once). The yield is still credited (C5).
    -- QQT_Warpigz_v3 (night audit R5): busy drops for a frame between two
    -- drops, which re-armed the window (and ended a cap) on every drop: 49 s
    -- continuous waits with 4 untakeable drops. The window and the cap now
    -- end only after 2 s without busy (Rosie's own per-episode pickup budget
    -- then rests such drops, so its busy really drops).
    loot_hold = function(self, lp)
        local now = get_time_since_inject()
        -- QQT_Warpigz_v3 2.6.4 (sweep H2, item loss): time in which this task
        -- did not run (a Rosie trip, a revive, another task) is credited to
        -- the window. After a trip the first busy tick read "busy 40 s without
        -- progress" and HR walked off the drops at the portal spot.
        local seen = self._loot_seen_at
        self._loot_seen_at = now
        local gap = seen and now - seen or 0
        if gap >= 0.5 then
            if self._loot_since then self._loot_since = self._loot_since + gap end
            if self._loot_quiet then self._loot_quiet = self._loot_quiet + gap end
        end
        if not loot_guard.busy() then
            self._loot_quiet = self._loot_quiet or now
            if now - self._loot_quiet >= 2 then
                self._loot_since, self._loot_items, self._loot_capped = nil, nil, nil
            end
            return false
        end
        self._loot_quiet = nil
        local items = lp and lp:get_item_count() or 0
        if not self._loot_since or items > (self._loot_items or items) then
            self._loot_since, self._loot_capped = now, nil
        end
        self._loot_items = items
        if self._loot_capped then return false end
        if now - self._loot_since < 15 then return true end
        self._loot_capped = true
        console.print(string.format("[HELLTIDE] Looter busy %.0fs without progress — farming on", now - self._loot_since))
        return false
    end,

    -- C6: a companion hold is published as hold_reason (see main.lua
    -- status().hold) and logged once a minute while it lasts over a minute.
    note_hold = function(self, reason)
        local now = get_time_since_inject()
        if self.hold_reason ~= reason then
            self.hold_reason, self._hold_since, self._hold_logged = reason, now, now
        end
        if now - (self._hold_logged or now) >= 60 then
            self._hold_logged = now
            console.print(string.format("[HELLTIDE] Holding for %.0fs: %s", now - (self._hold_since or now), reason))
        end
    end,

    -- C3/C4: deterministic hand-off on every exit path this task owns.
    -- Batmobile.release drops our route, goal, traversal routing and
    -- priority (owner-aware, never the native path a companion may own);
    -- the orbwalker goes back to block OFF / clear ON.
    release_movement = function(self)
        if BatmobilePlugin and BatmobilePlugin.release then
            BatmobilePlugin.release(plugin_label)
            movement_owned = false
        end
        clear_movement()
        settings.orb_release()
        tracker.tear_event.release_holds("stopped") -- QQT_Warpigz_v3 (Q2)
    end,

    suspend = function(self)
        self:release_movement()
    end,

    cancel_pending = function(self)
        self:reset(true)
        self:release_movement()
    end,

    -- reset() clears most of this file's run state. It is split into two
    -- ordered halves because QQT's LuaJIT runtime rejects any function that
    -- captures more than 60 upvalues (and this chunk is already at the
    -- 200-local limit, so the halves live in this table). The order of
    -- every assignment and call is unchanged.
    reset_run_state_first = function(self)
        ni = 1
        last_target_ni = nil
        patrol_free_explore = false
        patrol_free_explore_start = nil
        patrol_stuck_time = nil
        patrol_stuck_pos = nil
        traversal_recovery_time = nil
        trav_blacklist = {}
        trav_target_pos = nil
        trav_target_str = nil
        trav_start_time = nil
        trav_start_pos = nil
        trav_got_close = false
        self.current_state = helltide_state.INIT
        tracker.has_salvaged = false
        tracker.needs_salvage = false
        found_chest = nil
        found_chest_position = nil
        last_chest_interact_time = -math.huge
        tracker.clear_key('chest_drop_time')
        found_silent_chest_position = nil
        found_ore = nil
        found_herb = nil
        remembered_chests = {}
        remembered_chest_target = nil
        remembered_chest_long_path_started = false
        remembered_chest_long_path_ok = false
        recall_state_reset()
    end,

    reset_run_state_second = function(self)
        returning_to_helltide = false
        last_in_zone_pos      = nil
        experimental_armed    = false
        was_in_helltide_for_arm = false
        override_buff_seen    = false
        force_zone_change     = false
        no_waypoint_region    = false
        no_waypoint_logged_zone = nil
        farm_chest_entry    = nil
        tracker.clear_key("farm_chest_gone")
        farm_roam_points    = {}
        farm_roam_idx       = 1
        farm_roam_built_for = nil
        km_unreachable = {}
        km_nav_map = {}
        km_target_cache = nil
        km_cache_valid = false
        cached_actors = nil
        cached_actors_time = 0
        last_chest_diagnostic = -math.huge
        unknown_chest_skins = {}
        invalidate_fct_cache()
        last_chest_scan_time = -math.huge
        chest_temp_blacklist = {}
        chest_blacklist_data = {}
        chest_interact_attempts = {}
        chest_stuck_reset()
        pre_interact_cinders = nil
        last_chest_open_time = -math.huge
        self._last_check_events_time = nil
        self._override_cache = nil
        self._override_cache_time = nil
        self._override_walk_logged = false
        self._override_park_at = nil -- QQT_Warpigz_v3 3.3.3
        self._band = nil
        tracker.waypoints = {}
        tracker.waypoints_zone = nil -- QQT_Warpigz_v3
        tracker.clear_key("remembered_chest_timeout")
        tracker.clear_key("salvage_return_time")
        maiden_pos = nil
        maiden_reset_cycle()
        helltide_explorer.reset()
        tracker.tear_event.on_reset()
        tracker.hr_watch.reset() -- QQT_Warpigz_v3 3.3.3
        if tracker.hr_chest_order then tracker.hr_chest_order.on_reset() end -- QQT_Warpigz_v3
        clear_movement()
    end,

    reset = function(self, preserve_external)
        self:reset_run_state_first()
        self:reset_run_state_second()
        if BatmobilePlugin and not preserve_external then
            BatmobilePlugin.reset(plugin_label)
        end
        -- HLT-5: a cancelled session (preserve_external) resets Batmobile on
        -- its next first tick instead.
        self._bm_session_reset = not preserve_external
        self._handlers_ran_at = nil
        self.hold_reason, self._hold_since, self._hold_logged = nil, nil, nil
        self._loot_since, self._loot_items, self._loot_capped, self._loot_quiet = nil, nil, nil, nil -- QQT_Warpigz_v3
        self._loot_seen_at = nil -- QQT_Warpigz_v3 2.6.4
        self._town_tp_at = nil
        self._abandon_reached_town = nil
        self._trav_cleared_for = nil
        self._hr_reconsider_at = nil -- QQT_Warpigz_v3
        self._hr_exit = nil -- QQT_Warpigz_v3
        self._event_skin, self._event_pos, self._event_at, self._event_skip = nil, nil, nil, nil -- QQT_Warpigz_v3
        tracker.abandoning_zone = nil
    end,

    -- ── QQT_Warpigz_v3: smart farm (Farm mode) ───────────────────────────
    -- Separate functions keep the upvalues of check_events and
    -- move_to_remembered_chest (both near the LuaJIT margin) unchanged. The
    -- logic lives in core/hr_chest_order.lua, hr_roads.lua, hr_atlas.lua,
    -- hr_fence.lua and hr_stats.lua (reached through tracker).

    -- QQT_Warpigz_v3 3.3.3: interact with chest `key` now? At 2 m, or
    -- inside CHEST_INTERACT_RANGE once the bot stopped getting closer for
    -- RECALL.BAND_STALL_S. The 2-6 m band refreshed the stuck window with
    -- no bound of its own: a chest cell Batmobile refuses parked the bot.
    hr_chest_reach = function(self, key, d)
        if d <= 2 then
            self._band = nil
            return true
        end
        local band = self._band
        if d > CHEST_INTERACT_RANGE then
            if band and band.key == key then self._band = nil end
            return false
        end
        local now = get_time_since_inject()
        if not band or band.key ~= key or now < band.t then
            self._band = {key = key, best = d, t = now}
            return false
        end
        if d < band.best - RECALL.BAND_PROGRESS then
            band.best, band.t = d, now
            return false
        end
        if now - band.t < RECALL.BAND_STALL_S then return false end
        if not band.logged then
            band.logged = true
            console.print(string.format("[HELLTIDE CHEST] Out of reach closer than %.1fm — interacting from here", d))
        end
        return true
    end,

    -- QQT_Warpigz_v3 3.3.3: a target given up by hr_watch_tick.
    hr_watch_skipped = function(self, target)
        local watch, now = tracker.hr_watch, get_time_since_inject()
        if watch.skipped(watch.key(target), now) then return true end
        -- (review) a chaos rift given up as a whole
        local ok, skin = pcall(function() return target:get_skin_name() end)
        return ok and type(skin) == "string" and skin:find("ChaosRift", 1, true) ~= nil
            and watch.skipped("chaos rift", now)
    end,

    -- QQT_Warpigz_v3 3.3.3: the ore / herb / shrine / goblin / silent chest /
    -- chaos rift walks had no bound (a target Batmobile refuses, or an
    -- interaction that never takes, held the state forever). true: given up.
    hr_watch_tick = function(self, now)
        local watch, st, S = tracker.hr_watch, self.current_state, helltide_state
        if not watch.LIMITS[st] then
            watch.clear()
            return false
        end
        local target, what
        if st == S.MOVING_TO_ORE then target, what = found_ore, "ore"
        elseif st == S.MOVING_TO_HERB then target, what = found_herb, "herb"
        elseif st == S.MOVING_TO_SHRINE then target, what = find_closest_target("Shrine_"), "shrine"
        elseif st == S.CHASE_GOBLIN then target, what = find_closest_target("treasure_goblin"), "goblin"
        elseif st == S.MOVING_TO_SILENT_CHEST then
            target, what = find_closest_target("Hell_Prop_Chest_Rare_Locked"), "silent chest"
        else target, what = find_closest_target("S10_ChaosRiftChoiceGizmo"), "chaos rift" end
        local key = watch.key(target, what)
        -- (review) the chaos rift states are watched as one: a fixed key (the
        -- gizmo is gone while STAY_NEAR waits); the gizmo's own key is skipped too.
        local gizmo_key
        if watch.GROUP[st] then gizmo_key, key = target and key or nil, what end
        local hp
        if st == S.CHASE_GOBLIN and target then
            local ok, h = pcall(function() return target:get_current_health() end)
            hp = ok and h or nil
        end
        local why = watch.watch(st, key, now, get_player_position(), hp)
        if not why then return false end
        console.print(string.format("[HELLTIDE] Giving up on the %s (%s) — skipping it for %ds",
            what, why, watch.C.SKIP_S))
        watch.skip(key, now)
        watch.skip(gizmo_key, now)
        watch.clear()
        found_ore, found_herb, found_silent_chest_position = nil, nil, nil
        clear_movement()
        self.current_state = S.EXPLORE_HELLTIDE
        return true
    end,

    -- Inputs of core/hr_chest_order.lua pick().
    hr_smart_ctx = function(self, now)
        return {
            actors = get_cached_actors(),
            remembered = remembered_chests,
            blacklisted = function(key)
                local expiry = chest_temp_blacklist[key]
                return expiry ~= nil and expiry > now
            end,
            key_of = chest_key,
            player = get_player_position(),
            cinders = get_helltide_coin_cinders(),
            current = remembered_chest_target,
            now = now,
        }
    end,

    -- check_events Priority 1. true: a chest was chosen (state set); false:
    -- none is allowed now; nil: the smart order is off or failed.
    hr_smart_chests = function(self)
        local order = tracker.hr_chest_order
        if not order or not order.enabled() then return nil end
        scan_and_remember_chests()
        local now = get_time_since_inject()
        local ok, pick = pcall(order.pick, self:hr_smart_ctx(now))
        if not ok then
            order.note_error(pick)
            return nil
        end
        if not pick then return false end
        self:hr_commit_pick(pick, now)
        return true
    end,

    hr_commit_pick = function(self, pick, now)
        if settings.map_pin and pick.position and utility and utility.set_map_pin
            and self._hr_pinned ~= pick.key then
            self._hr_pinned = pick.key
            pcall(utility.set_map_pin, pick.position)
        end
        if pick.kind == 'visible' and (pick.distance or math.huge) <= WAYPOINT_MAX_DIST then
            found_chest = pick.name
            found_chest_position = pick.position
            pre_interact_cinders = nil
            last_chest_interact_time = -math.huge
            tracker.clear_key("chest_drop_time")
            chest_stuck_reset()
            remembered_chests[pick.key] = nil
            console.print(string.format("[HELLTIDE CHEST] %s %s at dist=%.1f cinders=%d/%d (smart order, class %d)",
                pick.opportunistic and "On the way:" or "Detected", pick.name, pick.distance or 0,
                get_helltide_coin_cinders(), pick.cost, pick.class or -1))
            self.current_state = helltide_state.MOVING_TO_HELLTIDE_CHEST
            return
        end
        local entry = remembered_chests[pick.key]
        if not entry then
            entry = {name = pick.name, cost = pick.cost, position = pick.position, discovered_at = now, seen_at = now}
            remembered_chests[pick.key] = entry
        end
        entry.predicted = pick.predicted or nil
        entry.spot = pick.spot
        entry.route = pick.route
        entry.smart = true
        entry.interacted, entry.pre_cinders = nil, nil -- this trip's own interaction
        remembered_chest_target = pick.key
        remembered_chest_long_path_started = false
        remembered_chest_long_path_ok = false
        chest_stuck_reset()
        console.print(string.format("[CHEST ORDER] Going to %s%s at %.0fm (class %d, %s)", pick.name,
            pick.predicted and " (learned spot)" or "", pick.distance or 0, pick.class or -1,
            pick.route and string.format("road %.0fm + %.0fm off-road", pick.route.road or 0, pick.route.offroad or 0)
                or "direct"))
        self.current_state = helltide_state.MOVING_TO_REMEMBERED_CHEST
    end,

    -- While walking to a smart-order target (every 2 s): switch when the
    -- order says so (better class, reset); hysteresis in hr_chest_order.
    hr_reconsider = function(self)
        local order = tracker.hr_chest_order
        if not order or not order.enabled() then return false end
        local now = get_time_since_inject()
        if self._hr_reconsider_at and now - self._hr_reconsider_at < 2 and now >= self._hr_reconsider_at then
            return false
        end
        self._hr_reconsider_at = now
        local ok, pick = pcall(order.pick, self:hr_smart_ctx(now))
        if not ok then
            order.note_error(pick)
            return false
        end
        if not pick or pick.key == remembered_chest_target then return false end
        console.print(string.format("[CHEST ORDER] Switching to %s (class %d)", pick.name, pick.class or -1))
        if BatmobilePlugin and BatmobilePlugin.stop_long_path then BatmobilePlugin.stop_long_path(plugin_label) end
        clear_movement()
        recall_state_reset()
        remembered_chest_target = nil
        self:hr_commit_pick(pick, now)
        return true
    end,

    -- A chest trip ended with an open (entry.interacted, or nil entry: the
    -- cinders were paid). Stats, the atlas spot, the learned road exit.
    hr_on_opened = function(self, name, pos, entry, key)
        local order = tracker.hr_chest_order
        if order and key then pcall(order.release, key) end
        if entry and not entry.interacted then return end -- spent before we got there
        local stats, atlas, roads = tracker.hr_stats, tracker.hr_atlas, tracker.hr_roads
        if stats then pcall(stats.on_chest_opened, name, enums.chest_types[name] or 0, pos) end -- QQT_Warpigz_v3: + pos
        if atlas and pos and name ~= 'silent' then pcall(atlas.mark_opened, pos, name) end
        if roads and entry and entry.route then pcall(roads.on_success, entry.route, pos, name) end
    end,

    -- A smart-order chest trip failed: not picked again at once (60 s
    -- blacklist, released); a trip that got stuck also marks the chest's
    -- 4 m cell bad (3 in a Helltide: skipped until it decays, core/hr_roads.lua).
    hr_trip_failed = function(self, entry, key, kind)
        if not entry or not entry.smart or not key then return end
        local expiry = get_time_since_inject() + CHEST_BLACKLIST_DURATION
        chest_temp_blacklist[key] = expiry
        chest_blacklist_data[key] = {pos = entry.position, expiry = expiry, name = entry.name}
        local order, roads = tracker.hr_chest_order, tracker.hr_roads
        if order then pcall(order.release, key) end
        if roads and kind == 'stuck' then pcall(roads.record_bad, entry.position) end
    end,

    -- The chest at a learned spot: any Helltide chest of the spot's kind
    -- (Mystery / regular) within 4 m; the entry takes its name and cost.
    hr_spot_chest = function(self, entry)
        local kind_of = tracker.hr_cinder_run.kind -- QQT_Warpigz_v3 (Q4): prize / mystery / regular
        local want = kind_of(entry.name)
        local px, py = entry.position:x(), entry.position:y()
        for _, actor in pairs(get_cached_actors()) do
            local e = chest_targets.read(actor)
            if e then
                local name, cost = chest_targets.classify(e.skin, enums.chest_types)
                if name and kind_of(name) == want then
                    local dx, dy = e.position:x() - px, e.position:y() - py
                    if dx * dx + dy * dy <= 16 then
                        entry.name, entry.cost = name, cost
                        return actor
                    end
                end
            end
        end
        return nil
    end,

    hr_predicted_miss = function(self, entry)
        local atlas, order = tracker.hr_atlas, tracker.hr_chest_order
        if atlas then pcall(atlas.mark_miss, entry.spot or entry.position) end
        if order then pcall(order.release, remembered_chest_target) end
        console.print(string.format("[CHEST ORDER] No %s at the learned spot this time — next target", entry.name))
        remembered_chests[remembered_chest_target] = nil
        remembered_chest_target = nil
        tracker.clear_key("remembered_chest_timeout")
        if BatmobilePlugin and BatmobilePlugin.stop_long_path then BatmobilePlugin.stop_long_path(plugin_label) end
        clear_movement()
        recall_state_reset()
        if BatmobilePlugin then BatmobilePlugin.resume(plugin_label) end
        self.current_state = helltide_state.EXPLORE_HELLTIDE
    end,

    -- Road leg of a route (core/hr_roads.lua). true: this tick walked the road.
    hr_road_step = function(self, entry, dist)
        local roads, route = tracker.hr_roads, entry.route
        if not roads or type(route) ~= 'table' or route.mode == 'offroad' then return false end
        if route.mode == 'road' and dist < 20 then
            route.mode = 'offroad' -- the road passes the chest: finish directly
            return false
        end
        local ok, goal = pcall(roads.next_goal, route, get_player_position(), get_time_since_inject())
        if not ok or route.failed or (goal == nil and route.mode ~= 'offroad') then
            console.print(string.format("[ROADS] Road route to %s dropped (%s) — direct navigation",
                entry.name, tostring(ok and (route.failed or 'no road goal') or goal)))
            entry.route = nil
            chest_stuck_reset()
            return false
        end
        if goal == nil then
            console.print(string.format("[ROADS] Leaving the road for %s (%.0fm off-road)", entry.name, route.offroad or 0))
            chest_stuck_reset()
            return false
        end
        if BatmobilePlugin and BatmobilePlugin.stop_long_path and BatmobilePlugin.is_long_path_navigating
            and BatmobilePlugin.is_long_path_navigating() then
            BatmobilePlugin.stop_long_path(plugin_label)
        end
        navigate_to(goal)
        return true
    end,

    -- Stuck off the road: back to the road and another exit (true), or
    -- false (the caller blacklists as before).
    hr_offroad_stuck = function(self, entry)
        local roads = tracker.hr_roads
        if not roads or type(entry.route) ~= 'table' then return false end
        local ok, backtrack = pcall(roads.stuck_offroad, entry.route, get_player_position())
        if not ok or not backtrack then return false end
        console.print(string.format("[ROADS] Stuck near %s — back to the road, trying another way (%d/%d)",
            entry.name, #(entry.route.tried or {}), roads.MAX_EXITS))
        if BatmobilePlugin and BatmobilePlugin.stop_long_path then BatmobilePlugin.stop_long_path(plugin_label) end
        recall_state_reset()
        return true
    end,

    -- The Helltide buff dropped while the hour runs ("Left helltide zone").
    -- QQT_Warpigz_v3 (night review): one buff read can miss (a buff-list
    -- refresh), so nothing is learned yet: the drop is only recorded, and
    -- hr_left_confirm acts once the buff stayed away for 3 s. A flicker just
    -- interrupts the trip, as before.
    hr_left_zone = function(self, pos)
        local ex = {pos = pos, at = get_time_since_inject()}
        local order = tracker.hr_chest_order
        if order and order.enabled() then
            if self.current_state == helltide_state.MOVING_TO_REMEMBERED_CHEST and remembered_chest_target then
                ex.key = remembered_chest_target
                local e = remembered_chests[ex.key]
                ex.name, ex.cpos = e and e.name, e and e.position
            elseif self.current_state == helltide_state.MOVING_TO_HELLTIDE_CHEST and found_chest and found_chest_position then
                ex.key, ex.name, ex.cpos = chest_key(found_chest, found_chest_position), found_chest, found_chest_position
            end
        end
        self._hr_exit = ex
    end,

    -- RETURN_TO_HELLTIDE tick (back: the buff is back). A confirmed exit: the
    -- fence learns the spot; a smart-order chest trip that led out is not
    -- tried again for 3 minutes, and after 2 such trips in a Helltide not at
    -- all in that Helltide (core/hr_chest_order.lua on_left).
    hr_left_confirm = function(self, back)
        local ex = self._hr_exit
        if not ex then return end
        local now = get_time_since_inject()
        if back then
            self._hr_exit = nil
            if not ex.done then
                console.print(string.format("[HELLTIDE] Helltide buff back after %.1fs — a buff flicker, not counted as leaving the zone",
                    math.max(0, now - ex.at)))
            end
            return
        end
        if ex.done or (now - ex.at < 3 and now >= ex.at) then return end
        ex.done = true
        local fence, order = tracker.hr_fence, tracker.hr_chest_order
        if fence and ex.pos then pcall(fence.on_left, ex.pos) end
        if not ex.key or not order then return end
        local expiry = now + 180
        chest_temp_blacklist[ex.key] = expiry
        chest_blacklist_data[ex.key] = {pos = ex.cpos, expiry = expiry, name = ex.name}
        pcall(order.release, ex.key)
        local okn, n, dropped = pcall(order.on_left, ex.key)
        if okn and dropped then
            console.print(string.format("[CHEST ORDER] The trip to %s left the Helltide %d times — skipping it for the rest of this Helltide",
                tostring(ex.name), n))
        else
            console.print(string.format("[CHEST ORDER] The trip to %s left the Helltide — skipping it for 180s", tostring(ex.name)))
        end
    end,
}

on_render(function()
    -- Farm boundary circle (always drawn when active)
    if farm_chest_entry then
        graphics.circle_3d(farm_chest_entry.position, 50, color_green(150))
    end

    if not settings.draw_chest_status then return end

    local now_r = get_time_since_inject()

    local function chest_label(pos, top_line, bot_line, circle_color, text_color)
        graphics.circle_3d(pos, 3, circle_color)
        local lp = vec3:new(pos:x(), pos:y(), pos:z() + 2.5)
        graphics.text_3d(top_line, lp, 13, text_color)
        if bot_line then
            local lp2 = vec3:new(pos:x(), pos:y(), pos:z() + 1.2)
            graphics.text_3d(bot_line, lp2, 11, text_color)
        end
    end

    -- ACTIVE: chest being moved to right now
    if found_chest_position then
        local label = found_chest or "chest"
        chest_label(found_chest_position, "ACTIVE", label, color_orange(220), color_orange(255))
    end

    -- SILENT: silent chest being moved to
    if found_silent_chest_position then
        chest_label(found_silent_chest_position, "SILENT", nil, color_white(200), color_white(255))
    end

    -- FARMING: chest we are farming cinders near (label + separate from the boundary circle)
    if farm_chest_entry then
        local need = farm_chest_entry.cost - get_helltide_coin_cinders()
        chest_label(farm_chest_entry.position, "FARMING", string.format("need %d cinders", math.max(0, need)), color_green(220), color_green(255))
    end

    -- REMEMBERED / RECALLING
    for key, entry in pairs(remembered_chests) do
        if key == remembered_chest_target then
            chest_label(entry.position, "RECALLING", entry.name, color_yellow(220), color_yellow(255))
        else
            chest_label(entry.position, "REMEMBERED", string.format("%d cinders", entry.cost), color_white(160), color_white(200))
        end
    end

    -- BLACKLISTED
    for key, data in pairs(chest_blacklist_data) do
        local remaining = data.expiry - now_r
        if remaining > 0 then
            local name_short = data.name or "chest"
            chest_label(data.pos, "BLACKLISTED", string.format("%s (%.0fs)", name_short, remaining), color_red(220), color_red(255))
        else
            chest_blacklist_data[key] = nil
        end
    end
end)

return helltide_task
