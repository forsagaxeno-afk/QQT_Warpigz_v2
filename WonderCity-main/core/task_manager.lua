local task_manager = {}
local tasks = {}
local tracker = require 'core.tracker'
local utils = require 'core.utils'
local settings = require 'core.settings'
local reward_phase = require 'core.reward_phase'
local active_task = nil
local running = false
local pending_navigation_reset = false
local exit_task, entry_task, alfred_task, chest_task, kill_task, obols_task
local current_task = { name = 'Idle', status = 'Idle' } -- Default state when no task is active
local function alfred_owns_control()
    return alfred_task and alfred_task.is_busy and alfred_task.is_busy()
end
local reward_wait_task = {name = 'finish_undercity', status = 'waiting for reward chest'}
reward_wait_task.Execute = function ()
    if not utils.is_looting() then utils.stop_movement() end
    settings.orb_set_clear(true)
    reward_wait_task.status = tracker.chest_failed and 'reward opening unconfirmed; waiting for run reset'
        or (tracker.done and 'waiting for loot to finish' or 'waiting for reward chest')
end

task_manager.register_task = function (task)
    table.insert(tasks, task)
end

task_manager.release_control = function ()
    if not running then return end
    if active_task and active_task.name ~= 'alfred_running' and not alfred_owns_control() then utils.stop_movement() end
    for _, task in ipairs(tasks) do
        if task.on_cancel then task.on_cancel() end
    end
    settings.orb_set_block(false)
    settings.orb_set_clear(true)
    active_task = nil
    running = false
end

local function execute(task)
    running = true
    if active_task ~= task then
        -- A companion can acquire movement between scheduler pulses. Its
        -- active route must survive cleanup of our previously selected task.
        if active_task and active_task.name ~= 'alfred_running' and not alfred_owns_control() then utils.stop_movement() end
        if active_task and active_task.on_cancel then active_task.on_cancel() end
        settings.orb_set_clear(true)
        active_task = task
    end
    current_task = task
    task:Execute()
end

local last_call_time = -math.huge
task_manager.execute_tasks = function ()
    local current_core_time = get_time_since_inject()
    if current_core_time - last_call_time < 0.05 then
        return -- quick ej slide frames
    end
    last_call_time = current_core_time

    local world = get_current_world()
    if not world then return end
    local world_name, zone = world:get_name(), world:get_current_zone_name()
    if type(world_name) ~= 'string' or world_name == ''
        or world_name:find('Limbo', 1, true) or world_name:find('Loading', 1, true)
        or type(zone) ~= 'string' or zone == '' or zone == '[sno none]'
    then return end
    -- Entry's actor-lifetime guard must run before every task predicate:
    -- walk_kurast and Alfred otherwise scan actors before entry can guard.
    if entry_task.transition_guard_active and entry_task.transition_guard_active() then
        current_task = entry_task
        return
    end
    local transition = tracker.observe_world()
    if transition then
        if transition == 'run' or transition == 'floor' then pending_navigation_reset = true end
        for _, task in ipairs(tasks) do
            if task.reset then task.reset(transition) end
        end
        active_task = nil
    end
    if pending_navigation_reset and not alfred_owns_control() then
        BatmobilePlugin.reset('wonder_city')
        pending_navigation_reset = false
    end
    reward_phase.observe()
    if utils.player_in_undercity() and utils.exit_forced() then
        if alfred_task.is_busy and alfred_task.is_busy() then execute(alfred_task)
        else execute(exit_task) end
        return
    end
    -- Once the reward phase is positively observed, leftover beacons, portal
    -- switches and goblins must not starve chest cleanup. Alfred keeps its
    -- existing ownership until it releases control. A live boss still wins.
    if utils.player_in_undercity() and reward_phase.active() then
        if alfred_task.is_busy and alfred_task.is_busy() then
            tracker.loot_quiet_since = nil
            execute(alfred_task)
        elseif tracker.boss_alive then
            tracker.loot_quiet_since = nil
            if kill_task.shouldExecute() then execute(kill_task) else execute(reward_wait_task) end
        elseif chest_task.shouldExecute() then execute(chest_task)
        elseif tracker.done and obols_task.shouldExecute() then
            tracker.loot_quiet_since = nil
            execute(obols_task)
        elseif exit_task.shouldExecute() then execute(exit_task)
        else execute(reward_wait_task) end
        return
    end
    current_task = {name = 'Idle', status = 'Idle'}
    for _, task in ipairs(tasks) do
        if task.shouldExecute() then
            execute(task)
            break -- Execute only one task per pulse
        end
    end

    -- The if statement has been removed, and current_task is always assigned
    current_task = current_task or { name = 'Idle', status = 'Idle' }
end

task_manager.get_current_task = function ()
    return current_task
end

local task_files = {
    -- 'd4assistant',
    'alfred',
    'teleport_kurast',
    'walk_kurast',
    'enter_undercity',
    'interact_enticement',
    'loot_obols',
    'portal',
    'kill_monster',
    'goto_chest',
    'exit_undercity',
    -- 'follower',
    'explore_undercity',
    'custom_explorer',
    'idle'
}
for _, file in ipairs(task_files) do
    local task = require('tasks.' .. file)
    task_manager.register_task(task)
    if file == 'exit_undercity' then exit_task = task end
    if file == 'alfred' then alfred_task = task end
    if file == 'enter_undercity' then entry_task = task end
    if file == 'goto_chest' then chest_task = task end
    if file == 'kill_monster' then kill_task = task end
    if file == 'loot_obols' then obols_task = task end
end

return task_manager
