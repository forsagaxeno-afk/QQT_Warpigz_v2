-- if true then return end

local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local tracker      = require "core.tracker"
local hr_mode      = require "core.hr_mode"
local activity_lease = require "core.activity_lease" -- QQT_Warpigz_v3
local utils        = require "core.utils"            -- QQT_Warpigz_v3

-- QQT_Warpigz_v3: smart farm, stats, overlay, web dashboard and the live
-- Helltide zone. Reached through tracker by the tasks (tasks/helltide.lua is
-- at LuaJIT's local limit); none of them needs WarPigs.
tracker.hr_clock       = require "core.hr_clock"
tracker.hr_store       = require "core.hr_store"
tracker.hr_json        = require "core.hr_json"
tracker.hr_stats       = require "core.hr_stats"
tracker.hr_cinder_plan = require "core.hr_cinder_plan"
tracker.hr_atlas       = require "core.hr_atlas"
tracker.hr_fence       = require "core.hr_fence"
tracker.hr_roads       = require "core.hr_roads"
tracker.hr_chest_order = require "core.hr_chest_order"
tracker.hr_overlay     = require "core.hr_overlay"
tracker.hr_dashboard   = require "core.hr_dashboard"
tracker.hr_live        = require "core.hr_live"
-- The plugin folder is read from this plugin's own package.path, once, here.
tracker.hr_store.resolve_root()
-- A completed tear event counts in the stats (core/hr_tear_event.lua).
if tracker.tear_event then
    tracker.tear_event.on_complete = function() tracker.hr_stats.on_tear_done() end
end

local local_player, player_position
local was_enabled = false

local function update_locals()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end

-- QQT_Warpigz_v3: one protected call per feature. A failing feature is
-- switched off for the session with one log line (no console spam).
local smart_off = {}
local function guarded(name, fn, ...)
    if smart_off[name] or type(fn) ~= 'function' then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        smart_off[name] = true
        console.print('[HelltideRevamped] ' .. name .. ' is off for this session: ' .. tostring(err))
    end
end

local function smart_tick()
    local now = get_time_since_inject()
    local okc, cinders = pcall(get_helltide_coin_cinders)
    if not okc or type(cinders) ~= 'number' then cinders = nil end
    local in_ht = utils.is_in_helltide()
    guarded('learned chest atlas', tracker.hr_atlas.tick, now, in_ht)
    guarded('stats', tracker.hr_stats.tick, now, cinders, in_ht, tracker.hr_atlas.current_zone())
    guarded('Helltide fence', tracker.hr_fence.tick, now, in_ht, player_position)
    guarded('road routing', tracker.hr_roads.tick, now)
    guarded('live Helltide zone', tracker.hr_live.tick, now)
    guarded('web dashboard', tracker.hr_dashboard.tick, now, player_position, in_ht)
    if gui.request_forget then
        gui.request_forget = false
        guarded('forget learned data', tracker.hr_atlas.forget)
    end
    if gui.request_reset_stats then
        gui.request_reset_stats = false
        guarded('reset all-time stats', tracker.hr_stats.reset_alltime)
    end
end

-- Switched off (menu, disable(), a caller unticking): save what changed.
local function smart_flush()
    tracker.hr_flush_pending = nil
    guarded('stats', tracker.hr_stats.flush, get_time_since_inject())
    guarded('learned chest atlas', tracker.hr_atlas.flush)
end

local function main_pulse()
    settings:update_settings()
    if not settings.enabled then
        if was_enabled then task_manager.stop() end
        if was_enabled or tracker.hr_flush_pending then smart_flush() end -- QQT_Warpigz_v3
        -- Unticked (by the user or a caller): the next manual enable runs
        -- the GUI-selected mode again.
        hr_mode.set_external(false)
        was_enabled = false
        activity_lease.release('HelltideRevampedPlugin') -- QQT_Warpigz_v3
        return
    end
    was_enabled = true
    -- QQT_Warpigz_v3: standalone (WarPigs off) with another activity plugin
    -- enabled: hold instead of teleporting against it.
    if activity_lease.check('HelltideRevampedPlugin',
        function(msg) console.print('[HelltideRevamped] ' .. msg) end)
    then
        local task = task_manager.get_current_task()
        if task and task.suspend then task:suspend() end
        return
    end
    local world = get_current_world()
    local world_name = world and world:get_name()
    if not local_player or not player_position or type(world_name) ~= 'string'
        or world_name:lower():find("limbo", 1, true)
        or world_name:lower():find("loading", 1, true) then
        local task = task_manager.get_current_task()
        if task and task.suspend then task:suspend() end
        return
    end
    smart_tick() -- QQT_Warpigz_v3
    task_manager.execute_tasks()
end

local function render_pulse()
    if not local_player or not player_position or not settings.enabled then return end
    -- QQT_Warpigz_v3: stats overlay (text rebuilt every 0.5 s, protected).
    tracker.hr_overlay.render(get_time_since_inject(), player_position)
    if activity_lease.reason then -- QQT_Warpigz_v3
        graphics.text_3d("HelltideRevamped: " .. activity_lease.reason,
            vec3:new(player_position:x(), player_position:y() - 2, player_position:z() + 3), 14, color_white(255))
        return
    end
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
        -- An external caller (WarPigs War Plan) always runs Warplan mode.
        hr_mode.set_external(true)
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
        hr_mode.set_external(false)
        if was_enabled then tracker.hr_flush_pending = true end -- QQT_Warpigz_v3: saved on our next tick
        was_enabled = false
    end,
    -- An orchestrator that takes over an HR that is already on (WarPigs
    -- adoption: HR's Enable was saved on, or the user left it on) never calls
    -- enable(); it marks HR as externally driven here instead, so the
    -- effective mode is Warplan exactly as after enable(). Ignored while HR
    -- is off (main_pulse clears the flag on every disabled tick anyway).
    set_external = function (on)
        if on and not (gui.elements.main_toggle and gui.elements.main_toggle:get()) then
            return false
        end
        hr_mode.set_external(on)
        return true
    end,
    status = function ()
        local task = task_manager.get_current_task()
        return {
            ['enabled'] = gui.elements.main_toggle:get(),
            ['task'] = task,
            -- C6: why HR is holding for a companion (Looter/Alfred), else nil.
            ['hold'] = type(task) == 'table' and task.hold_reason or nil,
            -- 'warplan' | 'farm' (external enable always reports 'warplan').
            ['mode'] = hr_mode.effective(),
            -- QQT_Warpigz_v3 (additive): session cinder numbers.
            ['stats'] = tracker.hr_stats.summary(),
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
