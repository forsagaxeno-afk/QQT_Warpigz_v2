local utils = require "core.utils"
local settings = require "core.settings"
local tracker = require "core.tracker"
local explorer = require "core.explorer"
local enums = require "data.enums"
local loot_guard = require "core.loot_guard"

local plugin_label = "infernal_horde"
local HORDE_ZONE = "S05_BSK_Prototype02"
local EXIT_ZONE = "Kehj_Caldeum"
local LEAVE_RETRY_SECONDS, MAX_LEAVE_ATTEMPTS = 10, 3
local EXIT_TIMEOUT, OUTSIDE_SETTLE, RESET_SETTLE = 60, 2, 2

-- A missing/loading world is not evidence that Leave Dungeon completed.
local function snapshot()
    local ok, result = pcall(function()
        local player = get_local_player()
        local current_world = get_current_world()
        if not player or player:is_dead() ~= false or not current_world then return nil end
        local name = current_world:get_name()
        local zone = current_world:get_current_zone_name()
        local id = current_world:get_world_id()
        if type(name) ~= "string" or name == "" or type(zone) ~= "string" or zone == "" or id == nil then return nil end
        local lower = name:lower()
        if lower:find("limbo", 1, true) or lower:find("loading", 1, true) then return nil end
        return {player=player, zone=zone, id=id, horde=zone==HORDE_ZONE,
            outside=zone==EXIT_ZONE and not lower:find("bsk", 1, true)}
    end)
    return ok and result or nil
end

local function stop_exit_movement(player)
    if BatmobilePlugin then
        if BatmobilePlugin.is_long_path_navigating and BatmobilePlugin.is_long_path_navigating() then
            assert(BatmobilePlugin.stop_long_path(plugin_label) ~= false, "Batmobile long path did not stop.")
        end
        assert(BatmobilePlugin.pause(plugin_label) ~= false, "Batmobile did not pause.")
        assert(BatmobilePlugin.clear_target(plugin_label) ~= false, "Batmobile target did not clear.")
    end
    -- Clear the previous chest/explorer move ONCE, before channeling Leave Dungeon.
    -- Repeating request_move while the channel is active would cancel it.
    assert(pathfinder.clear_stored_path() ~= false, "Stored path did not clear.")
    assert(pathfinder.request_move(player:get_position()) ~= false, "Movement did not stop.")
end

local exit_started = false
-- Debounce for teleport_to_waypoint. The teleport is a multi-second channel
-- that gets CANCELLED if fired again before completion. shouldExecute keeps
-- returning true for the whole channel (still in BSK zone), so without this
-- guard Execute spams teleport every pulse and the channel never finishes.
-- 5s window covers the channel + brief settle on arrival.
local TELEPORT_DEBOUNCE_S = 5.0
local teleport_fired_time = nil

local exit_horde_task = {
    name = "Exit Horde",
    delay_start_time = nil,
    moved_to_center = false,
    reset_phase = nil,
    reset_error = nil,
    reset_complete = false,

    reset = function(self)
        loot_guard.reset()
        if self.explorer_before_exit ~= nil then explorer.is_task_running = self.explorer_before_exit end
        self.explorer_before_exit = nil
        self.reset_phase, self.reset_error, self.reset_complete = nil, nil, false
        self.teleport_exit_started, self.teleport_complete = false, false
        self.reset_started, self.leave_attempts, self.next_leave = nil, nil, nil
        self.outside_since, self.outside_id, self.reset_sent_at = nil, nil, nil
        self.reset_settle_since, self.reset_settle_id = nil, nil
        tracker.reset_exit_pending = false
        exit_started, teleport_fired_time = false, nil
    end,

    has_completed_teleport = function(self)
        if self.teleport_complete then return true end
        if not self.teleport_exit_started then return false end
        local s = snapshot()
        if s and s.outside then self.teleport_complete = true end
        return self.teleport_complete == true
    end,

    fail_reset = function(self, message)
        self.reset_phase = "FAULT"
        self.reset_error = message
        console.print("[exit_horde] RESET stopped: " .. message)
        -- Retain the pending task so walking/start/salvage cannot begin a new cycle.
    end,

    run_reset = function(self, current_time)
        if self.reset_error then return end
        if current_time - self.reset_started >= EXIT_TIMEOUT then
            self:fail_reset("Leave Dungeon/reset timed out. No new run was started.")
            return
        end
        local s = snapshot()
        if not s then
            self.outside_since, self.outside_id = nil, nil
            self.reset_settle_since, self.reset_settle_id = nil, nil
            return
        end
        if self.reset_sent_at then
            if not s.outside then
                self:fail_reset("Area changed during reset settling. Check the current activity.")
                return
            end
            if self.reset_settle_id ~= s.id then
                self.reset_settle_since, self.reset_settle_id = current_time, s.id
            end
            if current_time - self.reset_settle_since < RESET_SETTLE then return end
            tracker.clear_runtime_timers()
            tracker.victory_lap, tracker.victory_positions = false, nil
            tracker.locked_door_found = false
            tracker.exit_horde_start_time = nil
            tracker.exit_horde_completion_time = current_time
            tracker.horde_opened, tracker.sigil_used = false, false
            tracker.start_dungeon_time, tracker.boss_killed = nil, false
            tracker.reset_exit_pending = false
            explorer.is_task_running = self.explorer_before_exit
            self.explorer_before_exit = nil
            self.reset_phase, self.reset_complete = "DONE", true
            exit_started = false
            console.print("[exit_horde] RESET sequence finished outside Horde; next cycle released.")
            return
        end
        if s.outside then
            if self.outside_id ~= s.id then
                self.outside_since, self.outside_id = current_time, s.id
            end
            self.reset_phase = "WAIT_OUTSIDE"
            if current_time - self.outside_since < OUTSIDE_SETTLE then return end
            -- Consume before the native call: no duplicate resets after an exception.
            self.reset_sent_at = current_time
            self.reset_settle_since, self.reset_settle_id = current_time, s.id
            local ok, result = pcall(reset_all_dungeons)
            if not ok or result == false then
                self:fail_reset("Reset request failed: " .. tostring(result))
                return
            end
            self.reset_phase = "RESET_SETTLE"
            console.print("[exit_horde] Outside Horde confirmed. Reset requested; waiting before the next cycle.")
            return
        end
        self.outside_since, self.outside_id = nil, nil
        self.reset_phase = "WAIT_LEAVE"
        -- Only leave the activity we committed to. Another dungeon is not success.
        if not s.horde or current_time < self.next_leave then return end
        if self.leave_attempts >= MAX_LEAVE_ATTEMPTS then
            self:fail_reset("Leave Dungeon did not finish after three attempts. Reset was not sent.")
            return
        end
        self.leave_attempts = self.leave_attempts + 1
        self.next_leave = current_time + LEAVE_RETRY_SECONDS
        local ok, result = pcall(leave_dungeon)
        console.print(string.format("[exit_horde] Leave Dungeon attempt %d/%d", self.leave_attempts, MAX_LEAVE_ATTEMPTS))
        if not ok or result == false then
            console.print("[exit_horde] Leave Dungeon request refused: " .. tostring(result))
        end
    end,

    shouldExecute = function()
        if tracker.reset_exit_pending then return true end
        if not teleport_fired_time and not loot_guard.ready() then return false end
        local s = snapshot()
        if not s or not s.horde then return false end
        local aether_ok = true
        if type(get_aether_count) == 'function' then
            local ok, count = pcall(get_aether_count)
            if ok and type(count) == 'number' and count > 0 then
                console.print(string.format("[exit_horde] holding — player still has %d aether", count))
                aether_ok = false
            end
        end
        return utils.get_stash() ~= nil
            and tracker.finished_chest_looting
            and aether_ok
    end,

    Execute = function(self)

        local current_time = get_time_since_inject()
        if tracker.reset_exit_pending then
            self:run_reset(current_time)
            return
        end
        -- A last-moment Looter activation must not be cut off by the first
        -- native exit call. Once committed, retain the existing quiet channel.
        if not self.teleport_exit_started and not loot_guard.ready() then return end

        -- On first entry, clear stale Batmobile target from horde task
        if not exit_started then
            exit_started = true
            if BatmobilePlugin then
                BatmobilePlugin.clear_target(plugin_label)
            end
        end

        if settings.exit_mode == 1 then
            -- Teleport mode: skip walking to center / 5s wait, just leave.
            -- Stop any in-flight long_path navigation BEFORE pausing.
            -- Batmobile's main_pulse re-runs navigator.unpause+update+move
            -- every frame while long_path.navigating is true, which overrides
            -- our pause and walks the player around — that movement cancels
            -- the teleport channel.
            if BatmobilePlugin then
                if BatmobilePlugin.is_long_path_navigating
                    and BatmobilePlugin.is_long_path_navigating()
                then
                    BatmobilePlugin.stop_long_path(plugin_label)
                end
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.clear_target(plugin_label)
            end
            -- Debounce so the channel can complete instead of being
            -- re-fired every 50ms. Once the player lands in the Library,
            -- shouldExecute returns false (zone changed) and we stop.
            if teleport_fired_time
                and current_time - teleport_fired_time < TELEPORT_DEBOUNCE_S
            then
                return
            end
            console.print("Teleporting out of Horde to Library.")
            loot_guard.commit_exit()
            teleport_to_waypoint(enums.waypoints.LIBRARY)
            self.teleport_exit_started = true
            teleport_fired_time = current_time
            tracker.clear_runtime_timers()
            tracker.victory_lap = false
            tracker.victory_positions = nil
            tracker.locked_door_found = false
            tracker.exit_horde_start_time = nil
            tracker.exit_horde_completion_time = current_time
            tracker.horde_opened = false
            tracker.sigil_used = false
            tracker.start_dungeon_time = nil
            tracker.boss_killed = false
            exit_started = false
            return
        end

        -- Commit RESET across world changes. The task manager keeps this task
        -- active until the outside reset has settled; it cannot be preempted by
        -- the next Library walk, sigil activation or a new salvage cycle.
        local s = snapshot()
        if not s or not s.horde then return end
        self.reset_started, self.leave_attempts = current_time, 0
        self.next_leave = current_time + 0.5
        self.outside_since, self.outside_id, self.reset_sent_at = nil, nil, nil
        self.reset_settle_since, self.reset_settle_id = nil, nil
        self.reset_phase, self.reset_error, self.reset_complete = "STOP_MOVEMENT", nil, false
        self.explorer_before_exit = explorer.is_task_running
        explorer.is_task_running = true
        tracker.reset_exit_pending = true
        loot_guard.commit_exit()
        local ok, why = pcall(stop_exit_movement, s.player)
        if not ok then self:fail_reset("Cannot stop movement before leaving: " .. tostring(why)) end
    end
}

return exit_horde_task
