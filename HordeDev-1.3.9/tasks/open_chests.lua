local utils = require "core.utils"
local settings = require "core.settings"
local enums = require "data.enums"
local tracker = require "core.tracker"
local explorer = require "core.explorer"
local town_salvage_task = require "tasks.town_salvage"
local loot_guard = require "core.loot_guard"

-- Reference the position from horde.lua
local horde_boss_room_position = vec3:new(-36.17675, -36.3222, 2.200)

-- Batmobile pause-mode movement for chest navigation
local plugin_label = "infernal_horde"
local movement = require "core.movement"
local bm_pulse_time = -math.huge
local BM_PULSE_INTERVAL = 0.1

local function bm_pulse(force)
    if not BatmobilePlugin then return end
    local now = get_time_since_inject()
    if not force and (now - bm_pulse_time) < BM_PULSE_INTERVAL then return end
    bm_pulse_time = now
    movement.claim(true)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
end

local function move_to(pos)
    movement.claim(BatmobilePlugin ~= nil)
    if not settings.aggresive_movement and BatmobilePlugin then
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.set_target(plugin_label, pos, false)
        bm_pulse(true)
    else
        explorer:set_custom_target(pos)
        explorer:move_to_target()
    end
end

local chest_state = {
    INIT = "INIT",
    MOVING_TO_AETHER = "MOVING_TO_AETHER",
    COLLECTING_AETHER = "COLLECTING_AETHER",
    MOVING_TO_CENTER = "MOVING_TO_CENTER",
    SELECTING_CHEST = "SELECTING_CHEST",
    MOVING_TO_CHEST = "MOVING_TO_CHEST",
    OPENING_CHEST = "OPENING_CHEST",
    WAITING_FOR_VFX = "WAITING_FOR_VFX",
    WAITING_FOR_LOOT = "WAITING_FOR_LOOT",
    FINISHED = "FINISHED",
    PAUSED_FOR_SALVAGE = "PAUSED_FOR_SALVAGE",
    FAULT = "FAULT",
}

-- Order chests are tried in.  TALISMAN sits first so when the WarPlans bonus
-- chest is enabled and present, it's opened before GA / selected.  Each entry's
-- inclusion is gated by the matching predicate in `chest_enabled` below.
local chest_order = {"TALISMAN", "GREATER_AFFIX", "SELECTED"}

-- Predicates matching chest_order entries.  When false, the picker skips that
-- entry — keeps the order static while letting the user opt-out of any chest.
local function chest_enabled(name)
    if name == "TALISMAN" then
        return settings.always_open_talisman_chest
            and not tracker.talisman_chest_opened
    elseif name == "GREATER_AFFIX" then
        return settings.always_open_ga_chest
            and not tracker.ga_chest_opened
    elseif name == "SELECTED" then
        return true  -- always tried as the final fallback
    end
    return false
end

-- Returns the index of the next chest_order entry that's enabled, starting at
-- `from` (1-based). When exhausted, return the past-the-end index so callers
-- cannot repeatedly select the same failed final chest.
local function next_enabled_index(from)
    for i = from, #chest_order do
        if chest_enabled(chest_order[i]) then return i end
    end
    return #chest_order + 1
end

local function aether_count()
    if type(get_aether_count) ~= "function" then return nil end
    local ok, count = pcall(get_aether_count)
    return ok and type(count) == "number" and count or nil
end

local function clear_chest_timers()
    for _, key in ipairs({"request_move_to_chest", "chest_opening_time", "chest_vfx_wait", "chest_loot_wait",
        "wait_for_talisman_loot_delay", "wait_for_ga_loot_delay", "wait_for_normal_loot_delay", "gold_chest_timer"}) do
        tracker.clear_key(key)
    end
end

local open_chests_task
open_chests_task = {
    name = "Open Chests",
    current_state = chest_state.INIT,
    current_chest_type = "MATERIALS",
    current_chest_index = 1,
    failed_attempts = 0,
    max_attempts = 15,
    state_before_pause = nil,
    
    shouldExecute = function()
        local in_correct_zone = utils.player_in_zone("S05_BSK_Prototype02")
    
        if not in_correct_zone then
            return false
        end
    
        -- Once the chest sequence starts, keep its completion checks running
        -- even if the gold actor unloads immediately after being opened.
        if open_chests_task.current_state ~= chest_state.INIT then
            return not tracker.finished_chest_looting or not loot_guard.ready()
        end
        local gold_chest_exists = utils.get_chest(enums.chest_types["GOLD"]) ~= nil
    
        if not gold_chest_exists then
            return false
        end
    
        return not tracker.finished_chest_looting
    end,
    
    Execute = function(self)

        explorer.is_task_running = true -- state handlers own movement, including loot waits
        local current_time = get_time_since_inject()
        console.print("Current state: " .. self.current_state)
    
        if self.current_state == chest_state.INIT then
            self:init_chest_opening()
        elseif tracker.has_salvaged then
            self:return_from_salvage()
        elseif self.current_state == chest_state.PAUSED_FOR_SALVAGE then
            self:waiting_for_salvage()
        elseif self.current_state == chest_state.FINISHED then
            self:finish_chest_opening()
        elseif self.current_state == chest_state.MOVING_TO_AETHER then
            self:move_to_aether()
        elseif self.current_state == chest_state.COLLECTING_AETHER then
            self:collect_aether()
        elseif self.current_state == chest_state.MOVING_TO_CENTER then
            self:move_to_center()
        elseif self.current_state == chest_state.SELECTING_CHEST then
            self:select_chest()
        elseif self.current_state == chest_state.MOVING_TO_CHEST then
            self:move_to_chest()
        elseif self.current_state == chest_state.OPENING_CHEST then
            self:open_chest()
        elseif self.current_state == chest_state.WAITING_FOR_VFX then
            self:wait_for_vfx()
        elseif self.current_state == chest_state.WAITING_FOR_LOOT then
            self:wait_for_loot()
        end
    end,

    return_from_salvage = function(self)
        if not tracker.check_time("salvage_return_time", 6) then
            console.print("Waiting before resuming chest opening")
            return
        end
        town_salvage_task:reset()
        console.print("Resume chest opening")
        tracker.salvage_return_time = nil
        tracker.has_salvaged = false
        self.current_state = chest_state.MOVING_TO_CHEST
        return
    end,

    waiting_for_salvage = function(self)
        console.print("Need salvage. Setting tracker.needs_salvage to start salvage task")
        tracker.needs_salvage = true
        return
    end,

    init_chest_opening = function(self)
        console.print("Initializing chest opening")
        console.print("settings.always_open_talisman_chest: " .. tostring(settings.always_open_talisman_chest))
        console.print("settings.always_open_ga_chest: " .. tostring(settings.always_open_ga_chest))
        console.print("tracker.ga_chest_opened: " .. tostring(tracker.ga_chest_opened))
        console.print("tracker.talisman_chest_opened: " .. tostring(tracker.talisman_chest_opened))
        console.print("settings.selected_chest_type: " .. tostring(settings.selected_chest_type))

        -- Always set self.selected_chest_type
        local chest_type_map = {"MATERIALS", "GOLD"}
        self.selected_chest_type = chest_type_map[(settings.selected_chest_type or 0) + 1]

        -- Pick the first enabled chest in chest_order.  TALISMAN sits at index
        -- 1; if its toggle is off (or already opened), the picker skips ahead
        -- to GA, then SELECTED.
        self.current_chest_index = next_enabled_index(1)
        local picked = chest_order[self.current_chest_index]
        if picked == "SELECTED" then
            self.current_chest_type = self.selected_chest_type
        else
            self.current_chest_type = picked
        end

        console.print("self.selected_chest_type: " .. tostring(self.selected_chest_type))
        console.print("self.current_chest_type: " .. tostring(self.current_chest_type))

        -- Wait for boss loots to drop before moving
        if not tracker.check_time("aether_drop_wait", settings.boss_kill_delay) then
            console.print("waiting for boss loot")
            return
        end
        
        -- Reset flag if boss loot triggered alfred
        tracker.has_salvaged = false
        self.current_state = chest_state.MOVING_TO_AETHER
        self.failed_attempts = 0
    end,

    move_to_aether = function(self)
        local aether_bomb = utils.get_aether_actor()
        if aether_bomb then
            if utils.distance_to(aether_bomb) > 2 then
                move_to(aether_bomb:get_position())
            else
                self.current_state = chest_state.COLLECTING_AETHER
            end
        else
            console.print("No aether bomb found")
            self.current_state = chest_state.SELECTING_CHEST
        end
    end,

    collect_aether = function(self)
        local aether_bomb = utils.get_aether_actor()
        if aether_bomb then
            interact_object(aether_bomb)
            self.current_state = chest_state.MOVING_TO_CENTER
        else
            console.print("No aether bomb found to collect")
            self.current_state = chest_state.MOVING_TO_CENTER
        end
    end,

    move_to_center = function(self)
        if utils.distance_to(horde_boss_room_position) > 2 then
            console.print("Moving to center position.")
            move_to(horde_boss_room_position)
        else
            self.current_state = chest_state.SELECTING_CHEST
            console.print("Reached Central Room Position.")
        end
    end,

    select_chest = function(self)
        console.print("Selecting chest")
        console.print("Current self.selected_chest_type: " .. tostring(self.selected_chest_type))
        console.print("Current self.current_chest_type: " .. tostring(self.current_chest_type))
        local chest_type_map = {"MATERIALS", "GOLD"}
        self.selected_chest_type = chest_type_map[settings.selected_chest_type + 1]
        console.print("New self.selected_chest_type: " .. tostring(self.selected_chest_type))
        -- Priority order: TALISMAN > GREATER_AFFIX > SELECTED.  Each is taken
        -- only when its toggle is on, the chest hasn't been opened this run,
        -- and the actor is actually present in the room.
        if chest_enabled("TALISMAN") and utils.get_chest(enums.chest_types["TALISMAN"]) then
            self.current_chest_index = 1
            self.current_chest_type  = "TALISMAN"
        elseif chest_enabled("GREATER_AFFIX") and utils.get_chest(enums.chest_types["GREATER_AFFIX"]) then
            self.current_chest_index = 2
            self.current_chest_type  = "GREATER_AFFIX"
        else
            self.current_chest_index = 3
            self.current_chest_type  = self.selected_chest_type
        end
        console.print("Final self.current_chest_type: " .. tostring(self.current_chest_type))
        self.current_state = chest_state.MOVING_TO_CHEST
    end,

    move_to_chest = function(self)
        if self.current_chest_type == nil then
            console.print("Error: current_chest_type is nil")
            self:try_next_chest()
            return
        end
    
        console.print("Attempting to find " .. self.current_chest_type .. " chest")
        local chest = utils.get_chest(enums.chest_types[self.current_chest_type])
        
        if chest then
            self.chest_not_found_attempts = 0 -- Reset the counter when chest is found
            if utils.distance_to(chest) > 2 then
                if tracker.check_time("request_move_to_chest", 0.15) then
                    console.print(string.format("Moving to %s chest", self.current_chest_type))
                    move_to(chest:get_position())
                    tracker.clear_key("request_move_to_chest")

                    self.move_attempts = (self.move_attempts or 0) + 1
                    if self.move_attempts >= settings.chest_move_attempts then
                        console.print("Failed to reach chest after multiple attempts")
                        self:try_next_chest()
                        return
                    end
                end
            else
                self.current_state = chest_state.OPENING_CHEST
                self.move_attempts = 0  -- Reset the counter when we successfully reach the chest
            end
        else
            console.print("Chest not found")
            self.chest_not_found_attempts = (self.chest_not_found_attempts or 0) + 1
            if self.chest_not_found_attempts >= 15 then
                console.print("Failed to find chest after 15 attempts")
                self:try_next_chest()
            else
                console.print("Attempt " .. self.chest_not_found_attempts .. " of 15 to find chest")
                self.current_state = chest_state.MOVING_TO_CHEST -- Stay in this state to retry
            end
        end
    end,

    open_chest = function(self)
        if tracker.check_time("chest_opening_time", settings.open_chest_delay) then
            -- Add check for GREATER_AFFIX chest type and full inventory
            console.print("Current self.current_chest_type: " .. tostring(self.current_chest_type))
            console.print("Current self.selected_chest_type: " .. tostring(self.selected_chest_type))
            if settings.salvage then
                local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
                if settings.use_alfred and alfred then
                    if type(alfred.get_status) ~= 'function' then return end
                    local ok, status = pcall(alfred.get_status)
                    if not ok or type(status) ~= 'table' or type(status.enabled) ~= 'boolean' then return end
                    if status.enabled and type(status.need_trigger) ~= 'boolean' then return end
                    if (status.enabled and status.need_trigger) then
                        self.state_before_pause = self.current_state
                        self.current_state = chest_state.PAUSED_FOR_SALVAGE
                        return
                    end
                else
                    local full = utils.is_inventory_full()
                    if full == nil then return end -- unreadable external inventory owner
                    if full then
                        self.state_before_pause = self.current_state
                        self.current_state = chest_state.PAUSED_FOR_SALVAGE
                        return
                    end
                end
            end
            local chest = utils.get_chest(enums.chest_types[self.current_chest_type])
            if chest then
                if not chest:is_interactable() then self:try_next_chest(false); return end
                self.pre_interact_aether = aether_count()
                self.pre_interact_chest = chest
                tracker.clear_key("chest_opening_time")
                tracker.clear_key("chest_vfx_wait")
                local try_open_chest = interact_object(chest)
                console.print("Chest interaction result: " .. tostring(try_open_chest))
                self.current_state = chest_state.WAITING_FOR_VFX
            else
                console.print("Chest not found when trying to open")
                self:try_next_chest()
                -- Log all nearby actors to help debug
                local actors = actors_manager:get_all_actors()
                for _, actor in pairs(actors) do
                    if actor:get_skin_name():match("Chest") then
                        console.print("Found chest: " .. actor:get_skin_name() .. ", Distance: " .. utils.distance_to(actor))
                    end
                end
                -- Keep the next-chest state chosen above; disappearance is not
                -- evidence that the remaining chest types were opened.
            end
        end
    end,

    wait_for_vfx = function(self)
        if not tracker.check_time("chest_vfx_wait", 1) then return end
        local chest = utils.get_chest(enums.chest_types[self.current_chest_type])
        local count = aether_count()
        local charged = self.pre_interact_aether ~= nil and count ~= nil and count < self.pre_interact_aether
        local spent = chest ~= nil and not chest:is_interactable()
        -- Global coin/light VFX can belong to another chest. Prefer payment or
        -- the attempted chest becoming spent; missing actors are not success.
        if charged or spent then
            self.failed_attempts = 0
            self:try_next_chest(true)
            return
        end
        tracker.clear_key("chest_vfx_wait")
        self.failed_attempts = self.failed_attempts + 1
        if self.failed_attempts >= self.max_attempts then
            self:try_next_chest(false)
        else
            self.current_state = chest_state.OPENING_CHEST
        end
    end,

    fail_chests = function(self, message)
        self.chest_error = message
        self.current_state = chest_state.FAULT
        tracker.finished_chest_looting = false
        console.print("[open_chests] " .. message)
    end,

    try_next_chest = function(self, was_successful)
        clear_chest_timers()
        self.move_attempts, self.chest_not_found_attempts = 0, 0
        local previous = self.current_chest_type
        if was_successful then
            movement.stop()
            loot_guard.reset()
            self.last_opened_type = previous
            if previous == "TALISMAN" then tracker.talisman_chest_opened = true
            elseif previous == "GREATER_AFFIX" then tracker.ga_chest_opened = true
            elseif previous == "GOLD" then tracker.gold_chest_opened = true end
            if previous == self.selected_chest_type then tracker.selected_chest_opened = true end
        end

        if previous == "TALISMAN" or previous == "GREATER_AFFIX" then
            self.current_chest_index = next_enabled_index((self.current_chest_index or 0) + 1)
            local next_type = chest_order[self.current_chest_index]
            self.current_chest_type = next_type == "SELECTED" and self.selected_chest_type or next_type
            if not self.current_chest_type then self.current_state = chest_state.FINISHED; return end
        elseif not was_successful then
            local remaining = aether_count()
            if remaining == nil then
                self:fail_chests("Cannot verify remaining aether after a failed chest. Check the host aether API before restarting.")
                return
            end
            if remaining > 0 and previous ~= "GOLD" then
                -- Spend the remainder with the existing gold chest after the
                -- selected chest is unavailable or no longer affordable.
                self.current_chest_type = "GOLD"
            elseif remaining ~= nil and remaining > 0 then
                self:fail_chests("Gold chest could not be opened; aether remains. Check the chest and restart when ready.")
                return
            else
                self.current_state = chest_state.FINISHED
                return
            end
        end
        self.failed_attempts = 0
        self.current_state = was_successful and chest_state.WAITING_FOR_LOOT or chest_state.MOVING_TO_CHEST
    end,

    wait_for_loot = function(self)
        local looter_ready = loot_guard.ready()
        local optional = self.last_opened_type == "TALISMAN" or self.last_opened_type == "GREATER_AFFIX"
        local delay = optional and settings.wait_loot_delay or settings.wait_loot_delay / 2
        if not tracker.check_time("chest_loot_wait", delay) then return end
        if not looter_ready then return end
        tracker.clear_key("chest_loot_wait")
        if optional then
            self.current_state = chest_state.MOVING_TO_CHEST
        else
            local remaining = aether_count()
            if remaining == nil then return end
            if remaining > 0 then
                -- Keep spending while the selected repeatable chest is usable.
                -- Failure falls back to gold; never announce completion while
                -- the exit task is blocked by unspent aether.
                self.current_state = chest_state.MOVING_TO_CHEST
            else
                self.current_state = chest_state.FINISHED
            end
        end
    end,

    finish_chest_opening = function(self)
        if not loot_guard.ready() then return end
        local remaining = aether_count()
        if remaining == nil then return end
        if remaining > 0 then
            if self.current_chest_type == "GOLD" then
                self:fail_chests("Chest sequence ended with unspent aether. Check the gold chest before leaving.")
            else
                self.current_chest_type = "GOLD"
                self.current_state = chest_state.MOVING_TO_CHEST
            end
            return
        end
        tracker.finished_chest_looting = true
        console.print("[open_chests] Chest sequence finished; exit may proceed.")
    end,

    reset = function(self)
        loot_guard.reset()
        self.current_state = chest_state.INIT
        self.current_chest_type = "MATERIALS"
        self.failed_attempts = 0
        self.current_chest_index = 1
        self.move_attempts, self.chest_not_found_attempts = 0, 0
        self.pre_interact_aether, self.pre_interact_chest = nil, nil
        self.last_opened_type, self.chest_error, self.state_before_pause = nil, nil, nil
        clear_chest_timers()
        tracker.clear_key("aether_drop_wait")
        tracker.clear_key("salvage_return_time")
        tracker.finished_chest_looting = false

        tracker.ga_chest_opened = false
        tracker.talisman_chest_opened = false
        tracker.selected_chest_opened = false
        tracker.gold_chest_opened = false
        console.print("Reset open_chests_task and related tracker flags")
    end,
}

return open_chests_task
