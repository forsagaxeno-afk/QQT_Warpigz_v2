local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local tracker = require "core.tracker"
local movement = require "core.movement"
local utils        = require "core.utils"
local loot_guard   = require "core.loot_guard"
local meteor       = require "Meteor"
local exit_horde_task = require "tasks.exit_horde"
local start_dungeon_task = require "tasks.start_dungeon"
local enter_horde_task = require "tasks.enter_horde"
local open_chests_task = require "tasks.open_chests"
local alfred_task = require "tasks.alfred"
local warplan = require "core.warplan"
local HORDE_ZONE = "S05_BSK_Prototype02"

local local_player, player_position
local was_active = false
local next_revive_time = -math.huge
local dead_since = nil -- HRD-4: death while a transaction is pending

local function update_locals()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end

-- C2 / HRD-1 / HRD-4: the fault of any run phase, or nil. A chest fault is
-- terminal (exit_horde leaves on its own); the transaction faults below are
-- latched until a restart (`latched_only`).
local function current_fault(latched_only)
    if tracker.chest_fault and not latched_only then return "chests: " .. tostring(tracker.chest_fault) end
    if exit_horde_task.reset_phase == "FAULT" then return "exit: " .. tostring(exit_horde_task.reset_error) end
    if start_dungeon_task.activation_phase == "FAULT" then return "entry: " .. tostring(start_dungeon_task.activation_error) end
    if enter_horde_task.entry_phase == "FAULT" then return "entry: " .. tostring(enter_horde_task.entry_error) end
    return nil
end

-- Transaction pending across worlds (RESET, sigil activation, portal entry).
local function transaction_pending()
    return tracker.reset_exit_pending or tracker.sigil_activation_pending or tracker.horde_entry_pending
end

-- C2 / CRT-2: committed to a horde (entry, run, chests, exit/RESET or an
-- Alfred trip HordeDev started). Idle, walking or town is not a run.
local function run_in_progress()
    if transaction_pending() then return true end
    -- F-H1: horde_opened / sigil_used are compass-entry flags; in War Plan
    -- mode a stale pair (outside BSK) is not a run.
    if (tracker.horde_opened or tracker.sigil_used) and not warplan.active() then return true end
    if alfred_task.trip_in_progress and alfred_task.trip_in_progress() then return true end
    local chest_state = open_chests_task.current_state
    if chest_state ~= nil and chest_state ~= "INIT" and not tracker.finished_chest_looting then return true end
    return utils.player_in_zone(HORDE_ZONE)
end

-- R8: an enable() while main_toggle is already on and a healthy run is in
-- progress (WarPigs re-asserting ownership, a re-enable after a hotkey pause)
-- keeps that run. A latched fault still gets the full restart, as in stop_run.
-- F-H3: only where the run actually is: a pending transaction, the player
-- inside the Horde, or HordeDev's own Alfred trip. Stale horde_opened /
-- sigil_used / has_entered with the player outside BSK and nothing pending
-- take the full reset (as at 86340d4). A switch to War Plan entry never keeps
-- a compass/portal transaction.
local function keep_run_on_enable(mode)
    if not gui.elements.main_toggle:get() then return false end
    -- A finished War Plan run is never kept (its chest/exit flags would skip
    -- the next horde's chests).
    if warplan.completed then return false end
    local own_trip = alfred_task.trip_in_progress ~= nil and alfred_task.trip_in_progress()
    if not (transaction_pending() or own_trip or utils.player_in_zone(HORDE_ZONE)) then return false end
    if mode == 'warplan' and (tracker.sigil_activation_pending or tracker.horde_entry_pending) then return false end
    return current_fault(transaction_pending()) == nil
end

-- Same wipe as a fresh enable(): every transaction, fault and chest flag.
local function reset_run_state()
    start_dungeon_task:reset()
    enter_horde_task:reset()
    exit_horde_task:reset()
    tracker.fresh_run_reset()
    open_chests_task:reset()
    warplan.reset_run()
end

-- F-H2: a HordeDev whose main toggle was on at load must not start the
-- compass / Library chain before WarPigs decides (enable() or disable()) when
-- WarPigs is loaded and enabled. Bounded: after WARPIGS_DECIDE_S without a
-- decision (WarPigs adopted the running plugin) it runs as configured.
-- Standalone (no WarPigs, or WarPigs off) is unchanged.
local WARPIGS_DECIDE_S = 5
local WARPIGS_WAIT_TASK, WARPIGS_WAIT_TEXT = "Waiting for WarPigs", "waiting for WarPigs to take over (up to 5 s)"
local session = {enabled_by_api = false, gate_done = false, gate_since = nil}

local function warpigs_enabled()
    local wp = WarPigsPlugin
    if type(wp) ~= 'table' or type(wp.status) ~= 'function' then return false end
    local ok, st = pcall(wp.status)
    return ok and type(st) == 'table' and st.enabled == true
end

local function waiting_for_warpigs()
    if session.gate_done then return false end
    if session.enabled_by_api or not warpigs_enabled() then
        session.gate_done = true
        return false
    end
    local now = get_time_since_inject()
    if not session.gate_since then
        session.gate_since = now
        console.print(string.format(
            "[HordeDev] Main toggle on at load with WarPigs enabled; waiting up to %ds for WarPigs before acting",
            WARPIGS_DECIDE_S))
    end
    if now - session.gate_since < WARPIGS_DECIDE_S then return true end
    session.gate_done = true
    console.print(string.format("[HordeDev] No enable/disable from WarPigs within %ds; running as configured",
        WARPIGS_DECIDE_S))
    return false
end

-- C2 hold: a companion hold (Alfred/Looter), else the visible idle state.
local function hold_text()
    local hold = alfred_task.hold_reason or loot_guard.hold_reason()
    if hold then return hold end
    local current = task_manager.get_current_task()
    return type(current) == 'table' and current.hold or nil
end

-- HRD-4: a latched fault ("restart HordeDev") is cleared by any stop: the GUI
-- toggle / keybind off edge and disable(). A healthy pending transaction
-- survives a pause and resumes when re-activated; a chest fault is restarted
-- too unless its exit transaction is already running.
local function stop_run()
    local fault = current_fault(transaction_pending())
    if task_manager.stop then task_manager.stop() end
    if fault then
        console.print("[HordeDev] Clearing latched fault on stop: " .. fault)
        reset_run_state()
    end
end

-- HRD-4: death during a pending transaction. Revive (the snapshot of a dead
-- player is nil, so the transaction cannot progress) and do not count the
-- dead time toward its timeout.
local function pending_player_dead()
    local ok, dead = pcall(function()
        local world = get_current_world()
        local name = world and world:get_name()
        if type(name) ~= 'string' or name:lower():find("limbo", 1, true) or name:lower():find("loading", 1, true) then
            return false
        end
        return local_player:is_dead() == true
    end)
    return ok and dead
end

local function extend_pending_deadlines(dt)
    if exit_horde_task.reset_started then exit_horde_task.reset_started = exit_horde_task.reset_started + dt end
    if start_dungeon_task.started then start_dungeon_task.started = start_dungeon_task.started + dt end
    if enter_horde_task.started then enter_horde_task.started = enter_horde_task.started + dt end
end

local function main_pulse()
    settings:update_settings()
    local active = settings.enabled and utils.get_keybind_state()
    if not active then
        if was_active then stop_run() end
        was_active = false
        return
    end
    was_active = true
    if not local_player then return end
    if waiting_for_warpigs() then
        movement.stop()
        if task_manager.hold then task_manager.hold(WARPIGS_WAIT_TASK, WARPIGS_WAIT_TEXT) end
        return
    end
    local pending = transaction_pending()
    if not pending then
        dead_since = nil
        local world = get_current_world()
        local name = world and world:get_name()
        if not world or not player_position or type(name) ~= 'string'
            or name:lower():find("limbo", 1, true) or name:lower():find("loading", 1, true) then
            movement.stop()
            return
        end
        if local_player:is_dead() then
            movement.stop()
            local now = get_time_since_inject()
            if now >= next_revive_time then
                next_revive_time = now + 1
                revive_at_checkpoint()
            end
            return
        end
        next_revive_time = -math.huge
    elseif pending_player_dead() then
        local now = get_time_since_inject()
        if not dead_since then
            dead_since = now
            console.print("[HordeDev] Player dead during a pending transaction; reviving at checkpoint")
        end
        if now >= next_revive_time then
            next_revive_time = now + 1
            revive_at_checkpoint()
        end
        return
    elseif dead_since then
        extend_pending_deadlines(get_time_since_inject() - dead_since)
        dead_since = nil
        next_revive_time = -math.huge
    end
    if settings.manage_orbwalker and orbwalker.get_orb_mode() ~= 3 then
        orbwalker.set_clear_toggle(true);
    end
    -- F-H1: HordeDev never goes to a new horde by itself after a War Plan
    -- run; when the player is in one again (the next War Plan teleport),
    -- that horde gets a fresh run instead of the finished run's flags.
    if warplan.completed and warplan.active() and warplan.inside_bsk() then
        console.print("[HordeDev] In a new Horde after the completed War Plan run; starting its run")
        if task_manager.stop then task_manager.stop() end
        reset_run_state()
        tracker.enable_time = get_time_since_inject()
    end
    warplan.update(open_chests_task.current_state)
    task_manager.execute_tasks()
end

local function render_pulse()
    if not local_player or not player_position or not (settings.enabled and utils.get_keybind_state() ) then return end
    local current_task = task_manager.get_current_task()
    if current_task then
        local px, py, pz = player_position:x(), player_position:y(), player_position:z()
        local draw_pos = vec3:new(px, py - 2, pz + 3)
        graphics.text_3d("Current Task: " .. current_task.name, draw_pos, 14, color_white(255))
        local aether_count = 0
        if type(get_aether_count) == 'function' then
            local ok, count = pcall(get_aether_count)
            if ok and type(count) == 'number' then aether_count = count end
        end
        local aether_pos = vec3:new(px, py - 2, pz + 2)
        graphics.text_3d("Aether: " .. tostring(aether_count), aether_pos, 14, color_white(255))
        if current_task.chest_error then
            graphics.text_3d("Chests: " .. current_task.chest_error, vec3:new(px, py - 2, pz + 1), 14, color_white(255))
        end
        local entry_status=current_task.activation_error or current_task.entry_error or current_task.activation_phase or current_task.entry_phase
        if entry_status then
            graphics.text_3d("Entry: "..entry_status,vec3:new(px,py-2,pz+1),14,color_white(255))
        end
        if current_task.reset_phase then
            graphics.text_3d("Exit: " .. (current_task.reset_error or current_task.reset_phase),
                vec3:new(px, py - 2, pz + 1), 14, color_white(255))
        end
        -- C6: a companion hold (Alfred/Looter) is visible, not a silent stall;
        -- so are the War Plan and WarPigs waits (F-H1/F-H2).
        local hold = hold_text()
        if hold then
            graphics.text_3d("Hold: " .. hold, vec3:new(px, py - 2, pz), 14, color_white(255))
        end
    end
end

-- Set Global access for other plugins
InfernalHordesPlugin = {
    -- F-H1: enable(opts); opts.entry == 'warplan' selects War Plan entry (the
    -- War Plan teleport already entered the Horde: no compass, no Library,
    -- one run). enable() without options is the compass/farming mode.
    enable = function (opts)
        local mode = type(opts) == 'table' and opts.entry == 'warplan' and 'warplan' or 'compass'
        console.print('HORDE ACTIVATING' .. (mode == 'warplan' and ' (War Plan entry)' or ''))
        session.enabled_by_api = true
        if keep_run_on_enable(mode) then
            -- R8: already on and inside a healthy run: re-assert, never reset.
            console.print('[HordeDev] enable() during a run in progress; keeping the current run')
        else
            if task_manager.stop then task_manager.stop() end
            -- Wipe leftover run state before activating. WarPigs re-enables the
            -- plugin mid-BSK after a prior wave; without this, finished_chest_looting
            -- and the per-chest opened flags survive and the next run skips
            -- open_chests entirely (exit_horde fires the moment the player is back
            -- in BSK). fresh_run_reset() also covers the normal Library->sigil flow
            -- as a no-op because start_dungeon's reset_chest_flags() runs anyway.
            -- open_chests has its own internal state machine (current_state etc.)
            -- that finishes at chest_state.FINISHED on the prior run; reset it so
            -- the SM re-enters at INIT.
            reset_run_state()
            -- Stamp the enable time so the horde task's settle gate (in horde.lua's
            -- shouldExecute) can wait for world/zone to stabilize before firing
            -- the wave loop. Read by horde.shouldExecute alongside a world-name
            -- check ('BSK' substring) — both must hold before the bomber pulses.
            tracker.enable_time = get_time_since_inject()
        end
        warplan.set_mode(mode)
        gui.elements.main_toggle:set(true)
        -- R8 (as Arkham's ARK-7): 'Use keybind' with no key bound could never
        -- pass the gate, so WarPigs re-enabled (and reset) HordeDev every tick.
        local key = gui.elements.keybind_toggle
        if not settings.external_control and settings.use_keybind
            and type(key.get_key) == 'function' and key:get_key() == 0x0A
        then
            console.print("[HordeDev] 'Use keybind' is on but no key is bound; running under external control")
        end
        settings.external_control = true
        gui.elements.keybind_toggle:set(true)
        settings:update_settings()
    end,
    disable = function ()
        console.print('HORDE DEACTIVATING')
        settings.external_control = false
        gui.elements.main_toggle:set(false)
        gui.elements.keybind_toggle:set(false)
        settings:update_settings()
        stop_run()
        was_active = false
        warplan.set_mode('compass') -- F-H1: disable() resets the entry mode
    end,
    -- C2 additive fields: in_run (committed to a horde), fault (latched fault
    -- message or nil), alfred_trip (HordeDev's own Alfred round trip), hold
    -- (companion hold reason, else the visible War Plan / WarPigs wait, or
    -- nil), exit_pending (R7: the Leave/RESET or Teleport exit is actively in
    -- progress, including its Looter hold), entry_mode ('warplan' |
    -- 'compass', F-H1), last_result ('completed' after a War Plan exit).
    status = function ()
        -- HRD-7: execution is gated on the keybind too (like Arkham/WonderCity).
        local enabled = gui.elements.main_toggle:get() and utils.get_keybind_state()
        return {
            ['enabled'] = enabled,
            ['task'] = task_manager.get_current_task(),
            ['in_run'] = run_in_progress(),
            ['fault'] = current_fault(),
            ['alfred_trip'] = alfred_task.trip_in_progress ~= nil and alfred_task.trip_in_progress() or false,
            ['hold'] = hold_text(),
            ['exit_pending'] = enabled == true and exit_horde_task.exit_pending ~= nil
                and exit_horde_task:exit_pending() == true,
            ['entry_mode'] = warplan.mode(),
            ['last_result'] = warplan.last_result,
        }
    end,
    getState = function ()
        local current = task_manager.get_current_task()
        if current then
            if current.name == "Walking to Horde" then
                return "WALKING_TO_HORDE"
            end
            if current.name == "Infernal Horde" and tracker.interacting_pylon then
                return "INTERACTING_PYLON"
            end
            if current.name == "Open Chests" then
                return "OPENING_CHESTS"
            end
            if current.name == "Exit Horde" then
                return "EXITING_HORDE"
            end
        end
        return "IDLE"
    end,
    -- True once HordeDev is committed to leaving BSK. WarPigs uses this to
    -- delay disabling HordeDev when the player leaves BSK temporarily for
    -- a mid-run salvage trip (Alfred TPs to town → player exits BSK →
    -- disable_when would fire too early without this guard).
    --
    -- Gate: current task must be "Exit Horde" for CHESTS_DONE_HOLD_S seconds.
    -- exit_horde.shouldExecute requires player_in_zone(BSK) AND stash visible
    -- AND finished_chest_looting=true (tasks/exit_horde.lua:49-53), so we're
    -- looking at the strongest possible "we're done with chests" signal — the
    -- task that runs only after every chest has been resolved AND the player
    -- is at the post-boss stash. The hold filters out single-tick blips where
    -- some other task briefly preempts (e.g. alfred kicking in for salvage)
    -- before exit_horde re-takes the queue.
    --
    -- Why not gate on chest flags directly: open_chests can reach FINISHED
    -- prematurely (indexing skip in try_next_chest, chest-not-found give-up)
    -- which flips finished_chest_looting=true after only the first chest. The
    -- exit_horde task gate is harder to spoof — it requires the boss-room
    -- stash actor, which only appears once the wave is fully complete.
    --
    -- WarPigs reports a prolonged defer as a diagnostic; it keeps this
    -- ownership gate until the pending transaction actually completes.
    chests_done = (function()
        local CHESTS_DONE_HOLD_S = 2.0
        local first_seen = nil
        return function()
            -- Do not let an orchestrator disable us as soon as Leave Dungeon
            -- changes the zone; RESET still has to run outside the activity.
            if tracker.reset_exit_pending or tracker.sigil_activation_pending or tracker.horde_entry_pending then
                first_seen = nil
                return false
            end
            local exit_complete = exit_horde_task.reset_complete
                or (exit_horde_task.has_completed_teleport and exit_horde_task:has_completed_teleport())
            if exit_complete and tracker.finished_chest_looting and not tracker.horde_opened then
                return true
            end
            local current = task_manager.get_current_task()
            local in_exit_horde = current and current.name == "Exit Horde"
            if not in_exit_horde then
                first_seen = nil
                return false
            end
            -- Belt-and-braces: don't signal done while the player still holds
            -- any aether. exit_horde.shouldExecute also gates on this, so
            -- reaching "Exit Horde" task normally implies aether==0, but this
            -- guard survives any future path that bypasses shouldExecute.
            -- After a terminal chest fault (HRD-1), or a War Plan horde without
            -- a chest room (F-H1), the aether is unspendable.
            if type(get_aether_count) == 'function' and not tracker.chest_fault and not tracker.chests_skipped then
                local ok, count = pcall(get_aether_count)
                if ok and type(count) == 'number' and count > 0 then
                    first_seen = nil
                    return false
                end
            end
            first_seen = first_seen or get_time_since_inject()
            return (get_time_since_inject() - first_seen) >= CHESTS_DONE_HOLD_S
        end
    end)(),
    getSettings = function (setting)
        return settings[setting]
    end,
    setSettings = function (setting, value)
        return settings.set_setting(setting, value)
    end,
}

on_update(function()
    update_locals()
    meteor.initialize()
    main_pulse()
end)

on_render_menu(gui.render)
on_render(render_pulse)
