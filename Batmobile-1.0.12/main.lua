local plugin_label = 'batmobile'

local gui          = require 'gui'
local settings     = require 'core.settings'
local external     = require 'core.external'
local drawing      = require 'core.drawing'
local utils        = require 'core.utils'
local tracker      = require 'core.tracker'
local navigator    = require 'core.navigator'
local long_path    = require 'core.long_path'
local mhelp        = require 'core.movement_helpers'

local local_player
local debounce_time = nil
local debounce_timeout = 1
local next_revive_time = -1
local freeroam_last = nil
local draw_keybind_data = checkbox:new(false, get_hash(plugin_label .. '_draw_keybind_data'))
local move_keybind_data = checkbox:new(false, get_hash(plugin_label .. '_move_keybind_data'))
if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false then
    gui.elements.draw_keybind_toggle:set(draw_keybind_data:get())
    gui.elements.move_keybind_toggle:set(move_keybind_data:get())
end

local function update_locals()
    local_player = get_local_player()
    if local_player then
        mhelp.observe_buffs(local_player)
    end
end

local function main_pulse()
    local loading = utils.player_loading()
    if loading then
        -- extend last_update so that it doesnt trigger unstuck straight after loading
        navigator.last_update = get_time_since_inject() + 5
    end
    settings:update_settings()
    local freeroam = gui.elements.freeroam_keybind_toggle:get_state() == 1
    -- A new manual toggle is an explicit resume. Merely leaving the toggle
    -- on must not erase an external pause on every autonomous update.
    if freeroam and freeroam_last == false then navigator.unpause() end
    freeroam_last = freeroam
    if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false  then
        if draw_keybind_data:get() ~= (gui.elements.draw_keybind_toggle:get_state() == 1) then
            draw_keybind_data:set(gui.elements.draw_keybind_toggle:get_state() == 1)
        end
        if move_keybind_data:get() ~= (gui.elements.move_keybind_toggle:get_state() == 1) then
            move_keybind_data:set(gui.elements.move_keybind_toggle:get_state() == 1)
        end
    end
    if gui.elements.reset_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.reset_keybind:set(false)
        debounce_time = get_time_since_inject()
        long_path.stop_navigation()
        navigator.reset()
    end
    -- Host world/actor data is incomplete while loading. Keep settings/reset
    -- responsive, but never pathfind, cast, or request movement in this state.
    if loading then return end
    if local_player and local_player:is_dead() then
        long_path.stop_navigation()
        local now = get_time_since_inject()
        if gui.elements.freeroam_keybind_toggle:get_state() == 1 and now >= next_revive_time then
            revive_at_checkpoint()
            next_revive_time = now + 1
        end
        return  -- revive is asynchronous; wait for an alive actor next tick
    end
    next_revive_time = -1
    if gui.elements.long_path_set_target:get_state() == 1 then
        gui.elements.long_path_set_target:set(false)
        long_path.set_target()
        if long_path.pinned_target then
            local p = long_path.pinned_target
            gui.long_path_target_str = string.format("(%.1f, %.1f, %.1f)", p:x(), p:y(), p:z())
        end
    end
    if gui.elements.long_path_set_target_cursor:get_state() == 1 then
        gui.elements.long_path_set_target_cursor:set(false)
        long_path.set_target_cursor()
        if long_path.pinned_target then
            local p = long_path.pinned_target
            gui.long_path_target_str = string.format("(%.1f, %.1f, %.1f) [cursor]", p:x(), p:y(), p:z())
        end
    end
    if gui.elements.long_path_test:get_state() == 1 then
        gui.elements.long_path_test:set(false)
        long_path.test_path()
    end
    -- Keep GUI state in sync
    gui.long_path_navigating = long_path.navigating
    -- Long path navigation: drive navigator independently of freeroam toggle
    if long_path.navigating and not navigator.paused then
        if not local_player or local_player:is_dead() then
            long_path.stop_navigation()
        else
            local cur = utils.normalize_node(local_player:get_position())
            -- Reached target: navigator consumed the path and is at the goal
            if not long_path.is_traversal_pending() and navigator.target ~= nil
                and utils.distance(cur, navigator.target) <= 1 then
                console.print("[LONG PATH] Reached target!")
                long_path.navigating  = false
                long_path.active_path = nil
                navigator.clear_target()
            elseif not long_path.is_traversal_pending()
                and navigator.target == nil and #navigator.path == 0 then
                console.print("[LONG PATH] Navigation complete")
                long_path.navigating  = false
                long_path.active_path = nil
            else
                local start_update = os.clock()
                navigator.update()
                tracker.timer_update = os.clock() - start_update
                local start_move = os.clock()
                navigator.move()
                tracker.timer_move = os.clock() - start_move
            end
        end
    end
    if local_player and not long_path.navigating and not navigator.paused
        and freeroam then
        local start_update = os.clock()
        navigator.update()
        tracker.timer_update = os.clock() - start_update
        local start_move = os.clock()
        navigator.move()
        tracker.timer_move = os.clock() - start_move
    end
end

local function render_pulse()
    if not local_player then return end
    if not settings.draw then return end
    drawing.draw_nodes(local_player)
end

on_update(function()
    update_locals()
    main_pulse()
end)

on_render_menu(function ()
    gui.render()
end)
on_render(render_pulse)
BatmobilePlugin = external
