-- if true then return end

local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local tracker      = require "core.tracker"

local local_player, player_position
local was_enabled = false

local function update_locals()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end

local function main_pulse()
    settings:update_settings()
    if not settings.enabled then
        if was_enabled then task_manager.stop() end
        was_enabled = false
        return
    end
    was_enabled = true
    local world = get_current_world()
    local world_name = world and world:get_name()
    if not local_player or not player_position or type(world_name) ~= 'string'
        or world_name:lower():find("limbo", 1, true)
        or world_name:lower():find("loading", 1, true) then
        local task = task_manager.get_current_task()
        if task and task.suspend then task:suspend() end
        return
    end
    task_manager.execute_tasks()
end

local function render_pulse()
    if not local_player or not player_position or not settings.enabled then return end
    local current_task = task_manager.get_current_task()
    if current_task then
        local px, py, pz = player_position:x(), player_position:y(), player_position:z()
        local draw_pos = vec3:new(px, py - 2, pz + 3)
        graphics.text_3d("Current Task: " .. current_task.name, draw_pos, 14, color_white(255))
    end
end

-- Set Global access for other plugins
HelltideRevampedPlugin = {
    enable = function ()
        console.print('HELLTIDE REVAMPED ACTIVATING')
        -- HLT-7: an external enable edge marks a fresh arrival, so search
        -- gives the buff a short grace instead of teleporting away at once.
        if gui.elements.main_toggle and not gui.elements.main_toggle:get() then
            tracker.external_enable_at = get_time_since_inject()
        end
        if gui.elements.main_toggle then gui.elements.main_toggle:set(true) end
        -- HR doesn't currently expose a keybind_toggle GUI element, but guard
        -- the access so an external orchestrator (WarPigs) doesn't crash on
        -- repeat enables when the symbol is absent.
        if gui.elements.keybind_toggle then gui.elements.keybind_toggle:set(true) end
        settings:update_settings()
    end,
    disable = function ()
        console.print('HELLTIDE REVAMPED DEACTIVATING')
        if gui.elements.main_toggle then gui.elements.main_toggle:set(false) end
        if gui.elements.keybind_toggle then gui.elements.keybind_toggle:set(false) end
        settings:update_settings()
        task_manager.stop()
        was_enabled = false
    end,
    status = function ()
        local task = task_manager.get_current_task()
        return {
            ['enabled'] = gui.elements.main_toggle:get(),
            ['task'] = task,
            -- C6: why HR is holding for a companion (Looter/Alfred), else nil.
            ['hold'] = type(task) == 'table' and task.hold_reason or nil,
        }
    end,
    getSettings = function (setting)
        return settings[setting]
    end,
    setSettings = function (setting, value)
        return settings.set_setting(setting, value)
    end,
    getState = function()
        local task = task_manager.get_current_task()
        return task and task.current_state or nil
    end,
}

on_update(function()
    update_locals()
    main_pulse()
end)

on_render_menu(gui.render)
on_render(render_pulse)
