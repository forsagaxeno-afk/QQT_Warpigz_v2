local plugin_label = 'arkham_asylum'

local gui          = require 'gui'
local settings     = require 'core.settings'
local task_manager = require 'core.task_manager'
local external     = require 'core.external'

local local_player, player_position
local debounce_time = nil
local debounce_timeout = 0
local next_revive_time = -math.huge

local update_locals = function  ()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end

local main_pulse = function  ()
    if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
    debounce_time = get_time_since_inject()
    settings:update_settings()
    if not settings.enabled or not settings.get_keybind_state() then
        task_manager.release_control()
        return
    end
    if not local_player or not BatmobilePlugin then return end
    local world = get_current_world()
    if not world then return end
    local world_name, zone = world:get_name(), world:get_current_zone_name()
    if type(world_name) ~= 'string' or world_name == ''
        or world_name:find('Limbo', 1, true) or world_name:find('Loading', 1, true)
        or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
    then return end
    -- if orbwalker.get_orb_mode() ~= 3 then
    --     orbwalker.set_clear_toggle(true)
    --     orbwalker.set_block_movement(true)
    -- end
    if local_player:is_dead() then
        local now = get_time_since_inject()
        if now >= next_revive_time then
            revive_at_checkpoint()
            next_revive_time = now + 1
        end
    else
        next_revive_time = -math.huge
        task_manager.execute_tasks()
    end
end

local render_pulse = function  ()
    if not (settings.get_keybind_state()) then return end
    if not local_player or not settings.enabled then return end
    local current_task = task_manager.get_current_task()
    if current_task then
        local msg = "Arkham Asylum: " .. current_task.name
        if current_task.status ~= nil then
            msg = "Arkham Asylum: " .. current_task.name .. ' (' .. current_task.status .. ')'
        end
        local x_pos = get_screen_width()/2 - (#msg * 5.5)
        local y_pos = 80
        graphics.text_2d(msg, vec2:new(x_pos, y_pos), 20, color_white(255))
    end
end

on_update(function()
    update_locals()
    main_pulse()
end)

on_render_menu(function ()
    gui.render()
end)
on_render(render_pulse)
ArkhamAsylumPlugin = external
