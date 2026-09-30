local plugin_label = 'alfred_the_butler'

local gui          = require 'gui'
local utils        = require 'core.utils'
local settings     = require 'core.settings'
local task_manager = require 'core.task_manager'
local tracker      = require 'core.tracker'
local external     = require 'core.external'
local drawing      = require 'core.drawing'

local local_player
local debounce_time = nil
local debounce_timeout = 1
local keybind_data = checkbox:new(false, get_hash(plugin_label .. '_keybind_data'))
if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false then
    gui.elements.keybind_toggle:set(keybind_data:get())
end

local function update_locals()
    local_player = get_local_player()
end

local function main_pulse()
    settings:update_settings()
    if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false  then
        if keybind_data:get() ~= (gui.elements.keybind_toggle:get_state() == 1) then
            keybind_data:set(gui.elements.keybind_toggle:get_state() == 1)
        end
    end

    if not local_player or not settings.enabled then return end
    utils.update_tracker_count(local_player)

    if gui.elements.manual_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.manual_keybind:set(false)
        debounce_time = get_time_since_inject()
        -- orbwalker.set_clear_toggle(false)
        external.resume()
        utils.reset_all_task()
        tracker.manual_trigger = true
        if not utils.is_in_town() then
            tracker.teleport = true
        end
    end

    if gui.elements.dump_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.dump_keybind:set(false)
        debounce_time = get_time_since_inject()
        utils.dump_tracker_info(tracker)
    end

    if not (settings.get_keybind_state() or tracker.external_trigger or tracker.manual_trigger) then
        return
    end

    task_manager.execute_tasks()
end

local function render_pulse()
    if not settings.enabled then return end
    if gui.elements.draw_status:get() then
        drawing.draw_status()
    end
    if gui.elements.draw_stash:get() or gui.elements.draw_sell:get() or gui.elements.draw_salvage:get() then
        drawing.draw_inventory_boxes()
    end
end

on_update(function()
    update_locals()
    main_pulse()
end)
on_render_menu(function ()
    gui.render()
    if gui.elements.affix_export_button:get() then
        utils.export_filters(gui.elements,false)
    elseif gui.elements.affix_import_button:get() then
        if gui.elements.affix_import_name:get() ~= '' then
            utils.import_filters(gui.elements)
        else
            utils.log('no import file name')
        end
    end
end)
on_render(render_pulse)

-- incase for some reason settings is not set for utils
if not utils.settings then
    utils.settings = settings
end
PLUGIN_alfred_the_butler = external
AlfredTheButlerPlugin = external

-- =============================================================================
-- Alfred Global Calls API
-- Call these from any other script to interact with Alfred.
-- =============================================================================

-- --- Plugin Control ---
AlfredTheButlerPlugin.enable = function()
    gui.elements.main_toggle:set(true)
    gui.elements.keybind_toggle:set(true)
    settings:update_settings()
end
AlfredTheButlerPlugin.disable = function()
    gui.elements.main_toggle:set(false)
    gui.elements.keybind_toggle:set(false)
    settings:update_settings()
end

-- --- Stash Pull Queue ---
-- Queue an item from stash to be pulled and salvaged or sold on Alfred's next town run.
-- sno_id : number  — item SNO ID
-- action : string  — 'salvage' | 'sell'
-- returns true on success, false if args are invalid
AlfredTheButlerPlugin.queue_stash_pull = function(sno_id, action)
    if type(sno_id) ~= 'number' then return false end
    if action ~= 'salvage' and action ~= 'sell' then return false end
    table.insert(tracker.pending_pulls, { sno_id = sno_id, action = action })
    return true
end
AlfredTheButlerPlugin.get_pending_pulls = function()
    return tracker.pending_pulls
end
AlfredTheButlerPlugin.clear_pending_pulls = function()
    tracker.pending_pulls = {}
end