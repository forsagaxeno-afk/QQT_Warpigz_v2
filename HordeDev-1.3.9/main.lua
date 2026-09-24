local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local tracker = require "core.tracker"
local movement = require "core.movement"
local utils        = require "core.utils"
local meteor       = require "Meteor"
local exit_horde_task = require "tasks.exit_horde"
local start_dungeon_task = require "tasks.start_dungeon"
local enter_horde_task = require "tasks.enter_horde"

local local_player, player_position
local was_active = false
local next_revive_time = -math.huge

local function update_locals()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end

local function main_pulse()
    settings:update_settings()
    local active = settings.enabled and utils.get_keybind_state()
    if not active then
        if was_active and task_manager.stop then task_manager.stop() end
        was_active = false
        return
    end
    was_active = true
    if not local_player then return end
    local pending = tracker.reset_exit_pending or tracker.sigil_activation_pending or tracker.horde_entry_pending
    if not pending then
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
    end
    if settings.manage_orbwalker and orbwalker.get_orb_mode() ~= 3 then
        orbwalker.set_clear_toggle(true);
    end
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
    end
end

-- Set Global access for other plugins
local open_chests_task = require "tasks.open_chests"
InfernalHordesPlugin = {
    enable = function ()
        console.print('HORDE ACTIVATING')
        if task_manager.stop then task_manager.stop() end
        -- Wipe leftover run state before activating. WarPigs re-enables the
        -- plugin mid-BSK after a prior wave; without this, finished_chest_looting
        -- and the per-chest opened flags survive and the next run skips
        -- open_chests entirely (exit_horde fires the moment the player is back
        -- in BSK). fresh_run_reset() also covers the normal Library->sigil flow
        -- as a no-op because start_dungeon's reset_chest_flags() runs anyway.
        start_dungeon_task:reset()
        enter_horde_task:reset()
        exit_horde_task:reset()
        tracker.fresh_run_reset()
        -- open_chests has its own internal state machine (current_state etc.)
        -- that finishes at chest_state.FINISHED on the prior run; reset it so
        -- the SM re-enters at INIT.
        open_chests_task:reset()
        -- Stamp the enable time so the horde task's settle gate (in horde.lua's
        -- shouldExecute) can wait for world/zone to stabilize before firing
        -- the wave loop. Read by horde.shouldExecute alongside a world-name
        -- check ('BSK' substring) — both must hold before the bomber pulses.
        tracker.enable_time = get_time_since_inject()
        gui.elements.main_toggle:set(true)
        gui.elements.keybind_toggle:set(true)
        settings:update_settings()
    end,
    disable = function ()
        console.print('HORDE DEACTIVATING')
        gui.elements.main_toggle:set(false)
        gui.elements.keybind_toggle:set(false)
        settings:update_settings()
        if task_manager.stop then task_manager.stop() end
        was_active = false
    end,
    status = function ()
        return {
            ['enabled'] = gui.elements.main_toggle:get(),
            ['task'] = task_manager.get_current_task()
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
            if type(get_aether_count) == 'function' then
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
