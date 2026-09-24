-- ============================================================
--  Reaper - tasks/open_chest.lua
--
--  Phases:
--    MAIN          → walk to EGB/Belial chest, interact
--    WAIT_GONE     → wait for main chest to despawn (up to WAIT_GONE_SECS)
--                    if it never despawns = out of keys/husks → stop
--    WAIT_COMPLETE → brief pause to loot, then consume_run + reset for next cycle
--
--  EGB/boss reward-chest consumption is the completion signal.
-- ============================================================

local utils     = require "core.utils"
local tracker   = require "core.tracker"
local rotation  = require "core.boss_rotation"
local settings  = require "core.settings"

-- ---- Config ----
local CHEST_INTERACT_COOLDOWN = 0.5  -- min seconds between EGB chest interact attempts
local WAIT_GONE_SECS          = 10   -- if chest still here after this → out of mats
local WAIT_COMPLETE_SECS      = 3    -- pause after chest before next run
local OUT_OF_MATS_RETRIES     = 3    -- times chest can fail to despawn before stopping

-- ---- State ----
local phase              = "IDLE"
local phase_start        = 0
local phase_yield        = 0    -- tracker.companion_yield when the phase began (C5)
local last_interact_time = 0
local last_chest_pos     = nil
local no_despawn_count   = 0    -- counts consecutive failures to despawn

local function set_phase(p)
    phase       = p
    phase_start = os.time()
    phase_yield = tracker.companion_yield or 0
    console.print("[Chest] Phase: " .. p)
end

-- C5: time spent yielding to Alfred never counts toward the despawn timeout
-- (three timeouts abandon the run as "out of keys/husks").
local function phase_elapsed()
    return os.time() - phase_start - ((tracker.companion_yield or 0) - phase_yield)
end

local function cooldown_ok()
    return (get_time_since_inject() - last_interact_time) >= CHEST_INTERACT_COOLDOWN
end

-- ---- Actor finders ----
local function find_egb_chest()
    local ok, actors = pcall(actors_manager.get_all_actors)
    if not ok or type(actors) ~= "table" then return nil, false end
    local best, best_dist, readable = nil, math.huge, true
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors) do
        local valid, name, pos = pcall(function()
            if not a:is_interactable() then return nil end
            local n = a:get_skin_name()
            if type(n) ~= "string" then error("unreadable actor name") end
            if n:find("^EGB_Chest") or n:find("^Boss_WT_Belial_") or n:find("^Chest_Boss") then
                return n, a:get_position()
            end
        end)
        if not valid then readable = false
        elseif name then
            if not pos then readable = false
            else
                local position_ok, d = pcall(function() return pp and pp:dist_to(pos) or 0 end)
                if not position_ok then readable = false
                elseif d < best_dist then best, best_dist = a, d end
            end
        end
    end
    return best, best ~= nil or readable
end

local function in_target_boss_zone()
    local boss = rotation.current()
    if not boss then return false end
    local zone = utils.get_zone()
    return utils.in_boss_zone(boss)
end

-- ---- Stuck helpers ----
local last_pos = nil
local last_move_t = 0

local function check_stuck()
    local pos = get_player_position()
    local t   = os.time()
    if last_pos and utils.distance_to(last_pos) < 0.1 then
        if t - last_move_t > 20 then
            if t - last_move_t >= 30 then last_move_t = t; return true end
        end
    else
        last_move_t = t
    end
    last_pos = pos
    return false
end

local function try_movement_spell(target)
    local lp = get_local_player()
    if not lp then return end
    for _, sid in ipairs({288106,358761,355606,1663206,1871821,337031}) do
        if lp:is_spell_ready(sid) then
            if cast_spell.position(sid, target, 3.0) then return end
        end
    end
end

-- -------------------------------------------------------
local task = { name = "Open Chest" }

function task.reset()
    phase = "IDLE"
    phase_start = 0
    phase_yield = tracker.companion_yield or 0
    last_interact_time = 0
    last_chest_pos = nil
    no_despawn_count = 0
    last_pos = nil
    last_move_t = 0
end

function task.shouldExecute()
    if not in_target_boss_zone() then
        if phase ~= "IDLE" then
            set_phase("IDLE")
            no_despawn_count = 0
        end
        return false
    end
    -- Active mid-sequence
    if phase == "WAIT_GONE" or phase == "WAIT_COMPLETE" then
        return true
    end
    -- Trigger on EGB/boss chest visibility
    return find_egb_chest() ~= nil
end

function task.Execute()
    settings.orb_set_block(false)
    -- Stuck recovery
    if check_stuck() then
        local pos = get_player_position()
        if pos then
            try_movement_spell(pos)
            pathfinder.force_move_raw(pos)
        end
        return
    end

    -- ---- IDLE / MAIN: find and open the EGB chest ----
    if phase == "IDLE" or phase == "MAIN" then
        local chest = find_egb_chest()
        if not chest then return end

        local dist = utils.distance_to(chest:get_position())
        if dist > 2.5 then
            pathfinder.request_move(chest:get_position())
            return
        end

        if not cooldown_ok() then return end

        interact_object(chest)
        last_interact_time = get_time_since_inject()
        tracker.chest_opened_time = os.time()
        last_chest_pos = chest:get_position()

        -- Signal Belial chest UI task
        local n = chest:get_skin_name()
        if type(n) == "string" and n:find("^Boss_WT_Belial_") then
            tracker.belial_chest_interacted = true
            console.print("[Chest] Belial chest interacted – signalling UI task.")
            if not settings.belial_chest_enabled then
                -- RPR-8: nothing confirms the Ritual of Lies dialog, so the chest
                -- stays closed and the bounded retry below fails this run.
                console.print("[Chest] Belial chest sequence is OFF (Reaper > Belial Chest) — the reward dialog will not be confirmed.")
            end
        end

        set_phase("WAIT_GONE")
        return
    end

    -- ---- WAIT_GONE: wait for chest to despawn ----
    if phase == "WAIT_GONE" then
        local chest, readable = find_egb_chest()
        if not readable then return end

        if chest == nil then
            -- Chest gone – run is complete (no theme chest to chase any more).
            no_despawn_count = 0
            set_phase("WAIT_COMPLETE")
            return
        end

        if phase_elapsed() < WAIT_GONE_SECS then return end

        -- Chest still here after timeout
        no_despawn_count = no_despawn_count + 1
        console.print(string.format("[Chest] Chest didn't despawn (%d/%d) – out of keys/husks?",
            no_despawn_count, OUT_OF_MATS_RETRIES))

        if no_despawn_count >= OUT_OF_MATS_RETRIES then
            no_despawn_count = 0
            local boss = rotation.current()

            -- Re-verify actual inventory before declaring out of keys/husks.
            -- Chest may have failed to despawn due to lag or a missed interact.
            -- BUT: external (orchestrator-injected) rotations are explicit
            -- one-shots — never extend the run from inventory, even if the
            -- chest is misbehaving. Otherwise the altar can re-fire.
            if boss and not rotation.external then
                rotation.resync_pools()
                local tier = boss.key_tier or boss.run_type or "lair"
                local has_stock = rotation.runs_for_tier(tier) > 0
                if has_stock then
                    console.print(string.format(
                        "[Chest] Chest still present but inventory has %s stock for %s — retrying open.",
                        tier, boss.label))
                    set_phase("MAIN")
                    return
                end
            end

            console.print("[Chest] Chest didn't despawn after retries — out of required key/husks for this boss, skipping.")
            rotation.advance("Reward chest remained closed after retries")
            tracker.reset_run()
            set_phase("IDLE")
        else
            -- Try interacting again
            if cooldown_ok() then
                interact_object(chest)
                last_interact_time = get_time_since_inject()
            end
            set_phase("WAIT_GONE")
        end
        return
    end

    -- ---- WAIT_COMPLETE: brief pause to loot, then start next run ----
    if phase == "WAIT_COMPLETE" then
        -- A single actor-list gap can occur during a loading/update frame.
        -- Require the chest to remain gone throughout the loot pause.
        local chest, readable = find_egb_chest()
        if chest or not readable then set_phase("WAIT_GONE"); return end
        -- RPR-6: let the Looter collect the boss drops before this run ends
        -- (the next step is a town or next-boss teleport). Polled from the
        -- start so its quiet window overlaps the pause; bounded in utils.
        local loot_ok = utils.loot_ready()
        if phase_elapsed() < WAIT_COMPLETE_SECS then return end
        if not loot_ok then return end
        local boss = rotation.current()
        console.print(string.format("[Chest] Run complete — boss=%s  run_type=%s",
            tostring(boss and boss.id), tostring(boss and boss.run_type)))
        tracker.chest_opened = true
        rotation.consume_run()
        tracker.reset_run()
        set_phase("IDLE")
        last_chest_pos = nil
        return
    end
end

return task
