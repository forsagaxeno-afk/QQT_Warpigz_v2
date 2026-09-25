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

-- Another Alfred (the old AlfredTheButler / SteroidAlfredV2 folder, or a
-- later load) owns the shared globals: this copy steps aside instead of
-- running a second set of town cycles on the same saved settings.
local stepped_aside = nil   -- nil, or the reason string
local function step_aside(reason)
    if stepped_aside then return end
    stepped_aside = reason
    external.drop_request()
    tracker.manual_trigger = false
    tracker.trigger_tasks = false
    console.print('[Alfred WarPigz] WARNING: ' .. reason .. ' -- this Alfred stays idle. ' ..
        'Disable or remove the other Alfred folder and reload.')
end
local function owns_globals()
    return AlfredTheButlerPlugin == external and PLUGIN_alfred_the_butler == external
end

local was_enabled = false
local last_settings_update = -math.huge
local function main_pulse()
    if stepped_aside then return end
    if not owns_globals() then
        step_aside('another Alfred replaced AlfredTheButlerPlugin/PLUGIN_alfred_the_butler after this one loaded')
        return
    end
    -- The full settings read walks thousands of filter checkboxes; 5x/s is plenty.
    local now = get_time_since_inject()
    if now - last_settings_update >= 0.2 then
        last_settings_update = now
        settings:update_settings()
    else
        settings.enabled = gui.elements.main_toggle:get()
    end
    if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false  then
        if keybind_data:get() ~= (gui.elements.keybind_toggle:get_state() == 1) then
            keybind_data:set(gui.elements.keybind_toggle:get_state() == 1)
        end
    end

    if not settings.enabled then
        if was_enabled then
            -- Disabled mid-request: forget it so a later enable does not run a
            -- stale cycle and call a stale callback.
            -- drop_request also resumes a Batmobile this cycle paused.
            was_enabled = false
            external.drop_request()
            external.clear_stuck()
            tracker.manual_trigger = false
            tracker.trigger_tasks = false
            utils.reset_all_task()
        end
        return
    end
    was_enabled = true
    if not local_player then return end
    utils.update_tracker_count(local_player)
    -- A given-up cycle (stash full) ends once the bag no longer needs a run.
    if tracker.stuck and not tracker.need_trigger then external.clear_stuck() end

    if gui.elements.dump_items_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.dump_items_keybind:set(false)
        debounce_time = get_time_since_inject()
        utils.dump_item_info()
    end

    if gui.elements.manual_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.manual_keybind:set(false)
        debounce_time = get_time_since_inject()
        -- orbwalker.set_clear_toggle(false)
        external.resume()
        external.clear_stuck()   -- the user freed stash space: try again
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
    if stepped_aside or not settings.enabled then return end
    if gui.elements.draw_status:get() then
        drawing.draw_status()
    end
    if gui.elements.draw_stash:get() or gui.elements.draw_sell:get() or gui.elements.draw_salvage:get() then
        drawing.draw_inventory_boxes()
    end
end

local last_error_log = -math.huge
on_update(function()
    update_locals()
    local ok, err = pcall(main_pulse)
    if not ok then
        local now = get_time_since_inject()
        if now - last_error_log >= 5 then
            last_error_log = now
            console.print('[Alfred] update error: ' .. tostring(err))
        end
    end
end)
on_render_menu(function ()
    if stepped_aside then
        render_menu_header('Alfred WarPigz is idle: ' .. stepped_aside .. '. Disable the other Alfred folder and reload.')
    end
    gui.render()
    if gui.elements.dump_items_button:get() then
        utils.dump_item_info()
    elseif gui.elements.dump_tracker_button:get() then
        utils.dump_tracker_info(tracker)
    elseif gui.elements.affix_export_button:get() then
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
external.edition = 'WarPigz'
do
    -- A table from an earlier load of this same build (script reload) is
    -- replaced; any other Alfred keeps its globals and this one steps aside.
    local foreign = nil
    for _, current in ipairs({AlfredTheButlerPlugin or false, PLUGIN_alfred_the_butler or false}) do
        if current and not (type(current) == 'table' and current.edition == 'WarPigz') then foreign = current end
    end
    if foreign then
        step_aside('another Alfred is already loaded (AlfredTheButlerPlugin/PLUGIN_alfred_the_butler taken)')
    else
        PLUGIN_alfred_the_butler = external
        AlfredTheButlerPlugin = external
    end
end

-- =============================================================================
-- Alfred Global Calls API
-- Call these from any other script to interact with Alfred.
-- =============================================================================

-- --- Plugin Control ---
external.enable = function()
    gui.elements.main_toggle:set(true)
    gui.elements.keybind_toggle:set(true)
    settings:update_settings()
end
external.disable = function()
    gui.elements.main_toggle:set(false)
    gui.elements.keybind_toggle:set(false)
    settings:update_settings()
end

-- --- Stash Pull Queue ---
-- Queue an item from stash to be pulled and salvaged or sold on Alfred's next town run.
-- sno_id : number  — item SNO ID
-- action : string  — 'salvage' | 'sell'
-- returns true on success, false if args are invalid
external.queue_stash_pull = function(sno_id, action)
    if type(sno_id) ~= 'number' then return false end
    if action ~= 'salvage' and action ~= 'sell' then return false end
    table.insert(tracker.pending_pulls, { sno_id = sno_id, action = action })
    return true
end
external.get_pending_pulls = function()
    return tracker.pending_pulls
end
external.clear_pending_pulls = function()
    tracker.pending_pulls = {}
end

-- --- WarPigz item helpers ---
-- 'keep' | 'salvage' | 'sell', reason, info snapshot (sno, rarity, mythic, kind ...)
external.get_item_decision = function(item, in_talisman_bag)
    local ok, action, reason, info = pcall(utils.item_decision, item, in_talisman_bag)
    if not ok then return 'keep', 'unreadable item' end
    return ({[0] = 'keep', [1] = 'salvage', [2] = 'sell'})[action] or 'keep', reason, info
end
external.dump_items = function()
    return utils.dump_item_info()
end