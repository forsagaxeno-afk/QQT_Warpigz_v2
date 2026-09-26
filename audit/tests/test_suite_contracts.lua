-- Independent integration-contract regressions. Run in plain Lua 5.4 with
-- SUITE_ROOT set to the suite directory. No game, companion plugin, or network.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local failures, checks = {}, 0
local plugins = {
    'ArkhamAsylum-1.0.6', 'WonderCity-main', 'HelltideRevamped-0.4',
    'HordeDev-1.3.9', 'Reaper-main',
}

local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end

local function alfred_task(plugin, options)
    options = options or {}
    local state = {
        now = 100, calls = 0, pauses = 0, resumes = 0, callbacks = {},
        status = {enabled = true, paused = options.paused == true, need_trigger = true},
    }
    if options.busy then
        state.status.trigger_tasks = true
        state.status.external_trigger = true
        state.status.external_caller = options.caller
    end
    local settings = {
        enabled = options.enabled ~= false, salvage = true, use_alfred = true,
        return_for_loot = true, town_zone = 'TEST_TOWN', town_waypoint = 1,
        orb_set_block = function() end,
    }
    local tracker = {needs_salvage = true, has_salvaged = false}
    local alfred = {
        get_status = function() return state.status end,
        pause = function() state.pauses = state.pauses + 1 end,
        resume = function() state.resumes = state.resumes + 1 end,
    }
    local function trigger(caller, callback)
        state.calls = state.calls + 1
        state.callbacks[#state.callbacks + 1] = callback
        if options.synchronous then
            state.status.need_trigger = false
            state.status.trigger_tasks = false
            state.status.external_trigger = false
            state.status.external_caller = caller
            callback()
        else
            state.status.trigger_tasks = true
            state.status.external_caller = caller
        end
    end
    alfred.trigger_tasks = trigger
    alfred.trigger_tasks_with_teleport = trigger
    local utils = {
        player_in_zone = function(zone) return zone == 'TEST_TOWN' end,
        is_in_helltide = function() return true end,
        player_in_pit = function() return false end,
        player_in_undercity = function() return false end,
    }
    local modules = {['core.settings'] = settings, ['core.tracker'] = tracker,
        ['core.utils'] = utils,
        ['tasks.navigate_to_boss'] = {reset = function() end},
        ['tasks.interact_altar'] = {reset = function() end}}
    local env = setmetatable({
        require = function(name) return assert(modules[name], 'unexpected dependency: ' .. name) end,
        AlfredTheButlerPlugin = alfred,
        PLUGIN_alfred_the_butler = nil,
        BatmobilePlugin = {pause = function() end, stop_long_path = function() end,
            clear_target = function() end, reset_movement = function() end},
        get_time_since_inject = function() return state.now end,
        get_player_position = function() return {} end,
        get_local_player = function() return {get_position = function() return {} end} end,
        teleport_to_waypoint = function() end,
        loot_manager = {any_item_around = function() return false end},
        console = {print = function() end},
    }, {__index = _G})
    env._G = env
    local task = assert(loadfile(root .. '/' .. plugin .. '/tasks/alfred.lua', 't', env))()
    return task, state, settings, tracker
end

for _, plugin in ipairs(plugins) do
    check(plugin .. ' module loading preserves a foreign Alfred cycle', function()
        local _, state = alfred_task(plugin, {busy = true, caller = 'WarPigs'})
        assert(state.pauses == 0 and state.resumes == 0 and state.calls == 0,
            'loading a task mutated the active companion')
    end)
    check(plugin .. ' yields unnamed active Alfred cycle', function()
        local task, state = alfred_task(plugin, {busy = true, enabled = false})
        assert(task.shouldExecute(), 'the active companion should hold the activity queue')
        task:Execute()
        assert(state.calls == 0, 'a live cycle with external_caller=nil was overwritten')
    end)
    check(plugin .. ' preserves paused but live foreign Alfred cycle', function()
        local task, state = alfred_task(plugin, {busy = true, paused = true,
            caller = 'WarPigs', enabled = false})
        assert(task.shouldExecute(), 'queued/live companion work must hold even when paused')
        task:Execute()
        assert(state.calls == 0, 'a paused foreign cycle was replaced')
    end)
    check(plugin .. ' accepts synchronous Alfred completion', function()
        local task, state = alfred_task(plugin, {synchronous = true, enabled = false})
        assert(task.shouldExecute(), 'service request must be runnable')
        task:Execute()
        assert(state.calls == 1, 'service must be triggered once')
        assert(task.status ~= 'waiting for alfred to complete',
            'WAITING overwrote the synchronous completion callback')
        assert(state.pauses == 0, 'completion callback parked companion service loop')
    end)
    check(plugin .. ' ignores callback from cancelled Alfred session', function()
        local task, state = alfred_task(plugin, {enabled = false})
        assert(task.shouldExecute(), 'service request must be runnable')
        task:Execute()
        assert(#state.callbacks == 1, 'expected a captured completion callback')
        assert(type(task.reset) == 'function', 'no task reset to invalidate old callbacks')
        task:reset()
        state.status.external_caller = 'WarPigs'
        state.status.trigger_tasks = true
        local prior_pauses, prior_status = state.pauses, task.status
        state.callbacks[1]()
        assert(state.pauses == prior_pauses, 'obsolete callback paused new owner')
        assert(task.status == prior_status, 'obsolete callback changed new local session')
    end)
end

for _, plugin in ipairs(plugins) do
    check(plugin .. ' task manager clears expired current task', function()
        local now = 100
        local tasks = {}
        local stub = {enabled = true, observe_world = function() return false end,
            player_in_pit = function() return false end, exit_pit_forced = function() return false end,
            player_in_undercity = function() return false end, exit_forced = function() return false end,
            stop_movement = function() end, orb_set_block = function() end,
            orb_set_clear = function() end}
        local env = setmetatable({
            get_time_since_inject = function() return now end,
            get_current_world = function() return {
                get_current_zone_name = function() return 'TEST_TOWN' end,
                get_name = function() return 'Sanctuary' end,
            } end,
            require = function(name)
                if name == 'core.reward_phase' then
                    -- This fixture represents an idle town with no observed
                    -- dungeon reward phase; retain the original task assertion.
                    return {observe = function() end, active = function() return false end,
                        can_exit = function() return false end}
                end
                if name:match('^tasks%.') then
                    local task = {name = name, shouldExecute = function() return false end,
                        Execute = function() end}
                    tasks[#tasks + 1] = task
                    return task
                end
                return stub
            end,
            console = {print = function() end},
        }, {__index = _G})
        env._G = env
        local manager = assert(loadfile(root .. '/' .. plugin .. '/core/task_manager.lua', 't', env))()
        assert(tasks[1], 'manager must load its tasks')
        tasks[1].shouldExecute = function() return true end
        manager.execute_tasks()
        assert(manager.get_current_task() == tasks[1], 'active task was not selected')
        tasks[1].shouldExecute = function() return false end
        now = now + 1
        manager.execute_tasks()
        assert(manager.get_current_task() ~= tasks[1], 'current_task retained a task that no longer runs')
    end)
end

for _, plugin in ipairs({'ArkhamAsylum-1.0.6', 'WonderCity-main'}) do
    check(plugin .. ' ignores disabled Looteer stale busy flag', function()
        local enabled = false
        local env = setmetatable({
            require = function() return {} end,
            LooteerPlugin = {getSettings = function(name)
                if name == 'looting' then return true end
                -- The supplied Looteer v2 getter represents false as nil.
                if name == 'enabled' and enabled then return true end
                return nil
            end},
        }, {__index = _G})
        env._G = env
        local utils = assert(loadfile(root .. '/' .. plugin .. '/core/utils.lua', 't', env))()
        assert(not utils.is_looting(), 'disabled companion retained a stale looting=true')
        enabled = true
        assert(utils.is_looting(), 'enabled companion actively looting must still receive priority')
    end)
end

check('Horde teleport completion survives subsequent task selection', function()
    local state = {now = 100, zone = 'S05_BSK_Prototype02', world = 'BSK', id = 42,
        teleports = 0, town_runs = 0}
    local position = {}
    local player = {is_dead = function() return false end, get_position = function() return position end}
    local world = {get_name = function() return state.world end,
        get_current_zone_name = function() return state.zone end,
        get_world_id = function() return state.id end}
    local modules = {
        ['core.settings'] = {enabled = true, exit_mode = 1, update_settings = function() end},
        ['core.explorer'] = {is_task_running = false},
        ['core.movement'] = {stop = function() end},
        ['core.utils'] = {get_stash = function() return {} end,
            get_keybind_state = function() return true end,
            player_in_zone = function(zone) return state.zone == zone end},
        ['data.enums'] = {waypoints = {LIBRARY = 99}},
        Meteor = {initialize = function() end},
    }
    local function toggle() return {get = function() return true end, set = function() end} end
    modules.gui = {elements = {main_toggle = toggle(), keybind_toggle = toggle()}, render = function() end}
    for _, name in ipairs({'alfred', 'town_salvage', 'walking_to_horde', 'open_chests',
        'start_dungeon', 'enter_horde', 'horde'}) do
        modules['tasks.' .. name] = {name = name, reset = function() end,
            shouldExecute = function()
                return name == 'walking_to_horde' and state.zone == 'Kehj_Caldeum'
            end,
            Execute = function() state.town_runs = state.town_runs + 1 end}
    end
    local env = setmetatable({
        get_time_since_inject = function() return state.now end,
        get_current_world = function() return world end,
        get_local_player = function() return player end,
        get_aether_count = function() return 0 end,
        teleport_to_waypoint = function() state.teleports = state.teleports + 1 end,
        pathfinder = {clear_stored_path = function() end, request_move = function() end},
        console = {print = function() end},
        on_update = function() end, on_render = function() end, on_render_menu = function() end,
    }, {__index = _G})
    env._G = env
    env.require = function(name)
        if not modules[name] then
            modules[name] = assert(loadfile(root .. '/HordeDev-1.3.9/' .. name:gsub('%.', '/') .. '.lua', 't', env))()
        end
        return modules[name]
    end
    local tracker = env.require('core.tracker')
    tracker.finished_chest_looting, tracker.horde_opened = true, true
    local manager = env.require('core.task_manager')
    assert(loadfile(root .. '/HordeDev-1.3.9/main.lua', 't', env))()
    manager.execute_tasks()
    assert(state.teleports == 1, 'exit task must issue the waypoint request')
    env.InfernalHordesPlugin.chests_done()
    state.now = 103
    manager.execute_tasks()
    env.InfernalHordesPlugin.chests_done()
    state.now, state.zone, state.world, state.id = 106, 'Kehj_Caldeum', 'Sanctuary', 43
    manager.execute_tasks() -- Horde updates before the orchestrator observes arrival.
    env.InfernalHordesPlugin.chests_done()
    state.now = 109
    manager.execute_tasks()
    assert(state.town_runs > 0, 'another task must have replaced Exit Horde')
    assert(env.InfernalHordesPlugin.chests_done(),
        'confirmed teleport exit lost completion evidence after Library task selection')
    env.InfernalHordesPlugin.enable()
    assert(not env.InfernalHordesPlugin.chests_done(), 'new run inherited prior exit completion')
end)


for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
print(string.format('Suite contracts: %d checks, %d failures', checks, #failures))
assert(#failures == 0, 'suite integration contract failures')
