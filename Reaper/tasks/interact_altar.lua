-- ============================================================
--  Reaper - tasks/interact_altar.lua
--
--  Finds the summoning altar inside the boss zone and
--  interacts with it to spawn the boss.
--  Success = the altar disappears from the actor list, or stops
--  being interactable, after a click on an interactable altar.
--  QQT_Warpigz_v3: retries are bounded (clicks that leave the altar
--  interactable, a listed altar that never becomes interactable),
--  a non-interactable altar is never clicked, and a summon that is
--  still committed after a death hands straight back to the fight.
-- ============================================================

local utils        = require "core.utils"
local enums        = require "data.enums"
local explorerlite = require "core.explorerlite"
local tracker      = require "core.tracker"
local rotation     = require "core.boss_rotation"
local settings     = require "core.settings"
local navigation_owner = require "core.navigation_owner"
local events       = require "core.qqt_events" -- QQT_Warpigz_v3


local plugin_label = 'reaper'

-- ---- Unstuck helpers ----
local last_pos          = nil
local last_move_time    = 0
local stuck_threshold   = 3
local last_unstuck_time = 0
local unstuck_cooldown  = 3
local unstuck_start     = 0
local unstuck_timeout   = 5

local last_interact_time = 0
local INTERACT_COOLDOWN  = 2.0  -- seconds between interact attempts

-- QQT_Warpigz_v3: bounds. A click that leaves the altar interactable did not
-- summon (no key in the bags, pool counter drifted, wrong tier). After
-- MAX_FAILED_CLICKS such clicks or CLICK_BOUND_SECS since the first one a
-- manual rotation resyncs its pools once (0 runs left for the tier: skip the
-- boss; stock left: one more bound, then skip); an external run fails at
-- once (rotation.failed, so C2 reports 'failed'). A listed altar that is not
-- interactable is never clicked; it gets NOT_READY_BOUND to re-arm.
local MAX_FAILED_CLICKS = 5
local CLICK_BOUND_SECS  = 30
local NOT_READY_BOUND   = 30
local COMMIT_RANGE      = 15   -- post-death hand-over range (Kill Monsters' tether)
local attempt = { clicks = 0, since = nil, phase = 0, not_ready_since = nil }

local function check_if_stuck()
    local pos = get_player_position()
    local t   = os.time()
    if last_pos and utils.distance_to(last_pos) < 0.1 then
        if t - last_move_time > stuck_threshold then
            if t - last_unstuck_time >= unstuck_cooldown then
                last_unstuck_time = t
                return true
            end
        end
    else
        last_move_time = t
    end
    last_pos = pos
    return false
end

-- -------------------------------------------------------
-- shouldExecute
-- -------------------------------------------------------
local task = { name = "Interact Altar" }

local function any_chest_visible()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return false end
    for _, a in pairs(actors) do
        local ok, inter = pcall(function() return a:is_interactable() end)
        if ok and inter then
            local n = a:get_skin_name()
            if type(n) == "string" then
                if n:find("^EGB_Chest") or n:find("^Chest_Boss")
                    or n:find("^Boss_WT_Belial_") then
                    return true
                end
            end
        end
    end
    return false
end

local function clear_attempt()
    attempt.clicks, attempt.since, attempt.phase, attempt.not_ready_since = 0, nil, 0, nil
end

-- QQT_Warpigz_v3: status text while a bound runs (C6 display in main.lua).
function task.status_text()
    local t = get_time_since_inject()
    if attempt.not_ready_since then
        return string.format("altar not interactable yet (%ds/%ds)",
            math.floor(t - attempt.not_ready_since), NOT_READY_BOUND)
    end
    if attempt.clicks > 1 and tracker.altar_interact_time then
        return string.format("altar not accepting summon (%d/%d)", attempt.clicks - 1, MAX_FAILED_CLICKS)
    end
    return nil
end

function task.reset()
    navigation_owner.release()
    clear_attempt()
    last_interact_time = 0
    last_pos = nil
    last_move_time = 0
    last_unstuck_time = 0
    unstuck_start = 0
end

function task.shouldExecute()
    -- Hard lockout: under an external rotation, once consume_run has fired
    -- the altar is done forever for this run. Belt-and-suspenders against any
    -- code path (chest reappear, navigate_to_boss confusion, etc.) that
    -- might otherwise let it re-trigger.
    if rotation.external and rotation.external_consumed then
        return false
    end

    -- Time elapsed is never evidence of a kill. Keep the fight active
    -- until the reward chest is observed and opened by open_chest.
    if tracker.altar_activated then return false end

    local boss = rotation.current()
    if not boss then return false end

    local zone = utils.get_zone()
    local in_zone = utils.in_boss_zone(boss)
    if not in_zone then return false end

    -- Boss chest already visible — boss is already dead, skip
    local actors = actors_manager.get_all_actors()
    if type(actors) == "table" then
        for _, actor in pairs(actors) do
            local ok, inter = pcall(function() return actor:is_interactable() end)
            if ok and inter then
                local name = actor:get_skin_name()
                if type(name) == "string" then
                    if name:find("^EGB_Chest") or name:find("^Boss_WT_Belial_")
                            or name:find("^Chest_Boss") then
                        return false
                    end
                end
            end
        end
    end

    -- Brief pause after a chest open before re-activating
    if tracker.chest_opened_time then
        if os.time() < tracker.chest_opened_time + 6 then return false end
    end

    -- Keep running while this run's click waits for the altar to react.
    -- QQT_Warpigz_v3: only the per-run tracker stamp counts; the module-level
    -- last_interact_time survives reset_run and made a stale click of the
    -- previous run look like a fresh summon.
    if tracker.altar_interact_time then return true end

    return utils.get_altar() ~= nil
end

-- QQT_Warpigz_v3: the summon of this run is committed (see core/tracker.lua).
local function mark_summoned(t)
    if BatmobilePlugin then BatmobilePlugin.stop_long_path(plugin_label) end
    tracker.altar_activated     = true
    tracker.altar_activate_time = t
    tracker.altar_interact_time = nil
    tracker.summoned_this_run   = true
    tracker.summon_zone         = utils.get_zone()
    last_interact_time = 0
    clear_attempt()
    local boss = rotation.current() -- QQT_Warpigz_v3: suite event
    events.emit('reaper', 'boss_summoned', {boss = boss and boss.id, label = boss and boss.label})
end

-- QQT_Warpigz_v3: bounded give-up (see the constants above).
local function give_up(reason, t, may_resync)
    local boss = rotation.current()
    if may_resync and not rotation.external and attempt.phase == 0 and boss then
        rotation.resync_pools()
        local tier = boss.key_tier or boss.run_type or "lair"
        local runs = rotation.runs_for_tier(tier)
        if runs > 0 then
            console.print(string.format("[Reaper] %s — inventory still has %d %s run(s); one more try.",
                reason, runs, tier))
            attempt.phase, attempt.clicks, attempt.since = 1, 0, t
            return
        end
    end
    console.print(string.format("[Reaper] %s — skipping %s.", reason, tostring(boss and boss.label)))
    if BatmobilePlugin then BatmobilePlugin.stop_long_path(plugin_label) end
    rotation.advance(reason)
    tracker.reset_run()
    task.reset()
end

local function remember_altar(altar)
    local ok, pos = pcall(function() return altar:get_position() end)
    if ok and pos then tracker.altar_pos = pos end
end

-- Walk to the altar (Batmobile long path when far). Returns true while moving.
local function approach(altar)
    local dist = utils.distance_to(altar)
    if dist <= 2.5 then return false end
    if BatmobilePlugin and dist > 15 then
        navigation_owner.claim()
        if not BatmobilePlugin.is_long_path_navigating() then
            console.print(string.format("[Reaper] Altar at dist=%.1f — starting long path.", dist))
            local ok = BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
            if ok then navigation_owner.route_started() end
            if not ok then
                console.print("[Reaper] Long path failed — using direct move.")
                pathfinder.request_move(altar:get_position())
            end
        else
            BatmobilePlugin.update(plugin_label)
            BatmobilePlugin.move(plugin_label)
        end
    else
        if BatmobilePlugin and BatmobilePlugin.is_long_path_navigating() then
            BatmobilePlugin.stop_long_path(plugin_label)
        end
        pathfinder.request_move(altar:get_position())
    end
    return true
end

function task.Execute()
    settings.orb_set_clear(true)

    local t     = get_time_since_inject()
    local altar, readable = utils.get_altar()
    if readable == false then return end -- unavailable actor stream is not activation
    if altar then remember_altar(altar) end
    local interactable = altar ~= nil and utils.is_interactable(altar)

    -- Altar gone after an interact attempt — success. Live 2.1.2 (Grigoire):
    -- the altar can also stay listed but stop being interactable once the
    -- boss spawns; that is the same success, not a reason to click again.
    -- QQT_Warpigz_v3: only a click of this run counts (tracker stamp, cleared
    -- by reset_run/revive), and only interactable altars are ever clicked.
    local clicked = tracker.altar_interact_time ~= nil
    if clicked and not interactable then
        console.print(altar and "[Reaper] Altar no longer interactable — activated successfully."
            or "[Reaper] Altar gone — activated successfully.")
        mark_summoned(t)
        return
    end
    if not altar then return end

    if not interactable then
        -- QQT_Warpigz_v3: after a death inside the same lair the summon is
        -- still live (boss up, altar spent): walk back and fight.
        if tracker.summon_committed(utils.get_zone()) then
            attempt.not_ready_since = nil
            if utils.distance_to(altar) <= COMMIT_RANGE then
                console.print("[Reaper] Summon still active after respawn — back to the fight.")
                mark_summoned(t)
                return
            end
            approach(altar)
            return
        end
        -- Never click a spent altar (a phantom 'success' idled Reaper in
        -- Kill Monsters for the rest of the session). Wait, bounded, for it
        -- to re-arm.
        attempt.not_ready_since = attempt.not_ready_since or t
        if t - attempt.not_ready_since >= NOT_READY_BOUND then
            give_up("Altar did not become interactable", t, false)
            return
        end
        approach(altar)
        return
    end
    attempt.not_ready_since = nil

    -- ---- Unstuck logic ----
    if check_if_stuck() then
        if unstuck_start == 0 then
            unstuck_start = t
        elseif t - unstuck_start > unstuck_timeout then
            unstuck_start = 0
            return
        end
        local ut = explorerlite.find_unstuck_target()
        if ut then
            explorerlite:set_custom_target(ut)
            utils.try_movement_spell(ut)
            pathfinder.force_move_raw(ut)
        end
        return
    else
        unstuck_start = 0
    end

    if approach(altar) then return end

    -- Close enough — stop any active long path before interacting
    if BatmobilePlugin and BatmobilePlugin.is_long_path_navigating() then
        BatmobilePlugin.stop_long_path(plugin_label)
    end

    -- Enforce cooldown between attempts
    if (t - last_interact_time) < INTERACT_COOLDOWN then return end

    -- QQT_Warpigz_v3: every click after the first one of a bound means the
    -- previous click left the altar interactable (no summon).
    if not clicked then clear_attempt() end
    if attempt.clicks >= MAX_FAILED_CLICKS or (attempt.since and t - attempt.since >= CLICK_BOUND_SECS) then
        give_up("Altar did not accept the summon (no key?)", t, true)
        return
    end

    console.print("[Reaper] Interacting with altar.")
    interact_object(altar)
    last_interact_time = t
    attempt.clicks = attempt.clicks + 1
    attempt.since = attempt.since or t
    tracker.altar_interact_time = tracker.altar_interact_time or t
end

return task
