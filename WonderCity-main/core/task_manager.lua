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
-- C5: when the alfred task became the active task (WonderCity yielding
-- control to Alfred). That time is not progress time for any stuck window.
local yield_started = nil
-- C6: the forced reset-timeout exit waits for a known live Alfred cycle at
-- most FORCED_ALFRED_HOLD_MAX seconds (an unreadable status never holds it).
local FORCED_ALFRED_HOLD_MAX = 120
local forced_hold = {since = nil, logged = false}
local function alfred_owns_control(known_only)
    return alfred_task and alfred_task.is_busy and alfred_task.is_busy(known_only)
end
local REWARD_WAIT_LOG_AFTER = 60
local reward_wait_task = {name = 'finish_undercity', status = 'waiting for reward chest', since = nil, logged = false}
reward_wait_task.Execute = function ()
    if not utils.is_looting() then utils.stop_movement() end
    settings.orb_set_clear(true)
    -- CRT-1: a reward chest we saw that vanished (opened elsewhere or
    -- replaced) completes the reward phase after a bounded absence.
    if reward_phase.chest_vanished() then
        reward_phase.mark_opened('reward chest vanished without our interaction')
    end
    reward_wait_task.status = tracker.chest_failed and 'reward opening unconfirmed; waiting for run reset'
        or (tracker.done and 'waiting for loot to finish' or 'waiting for reward chest')
    -- C6: a boss kill without any visible chest waits for the run timeout;
    -- say so once per run.
    local now = get_time_since_inject()
    if tracker.done then
        reward_wait_task.since = nil
    else
        reward_wait_task.since = reward_wait_task.since or now
        if now - reward_wait_task.since >= REWARD_WAIT_LOG_AFTER and not reward_wait_task.logged then
            reward_wait_task.logged = true
            console.print(string.format('[WonderCity:finish] no reward chest to open for %.0fs; waiting for the run timeout (%ds)',
                now - reward_wait_task.since, settings.reset_timeout))
        end
    end
end
reward_wait_task.reset = function ()
    reward_wait_task.since, reward_wait_task.logged = nil, false
end

task_manager.register_task = function (task)
    table.insert(tasks, task)
end

task_manager.release_control = function ()
    if not running then return end
    -- C3/WCY-5/WCY-8: always hand Batmobile back, also while Alfred owns
    -- control. BatmobilePlugin.release is owner-aware (a route or goal Alfred
    -- claimed stays untouched, the native path is never cleared); without it
    -- WonderCity's own autonomous long route is still stopped.
    utils.release_movement((active_task and active_task.name == 'alfred_running') or alfred_owns_control())
    for _, task in ipairs(tasks) do
        if task.on_cancel then task.on_cancel() end
    end
    settings.orb_set_block(false)
    settings.orb_set_clear(true)
    active_task = nil
    yield_started = nil
    running = false
end

local function execute(task)
    running = true
    if active_task ~= task then
        local now = get_time_since_inject()
        if active_task == alfred_task and yield_started then
            -- C5: shift chest/obols/enticement/walk windows by the yield.
            local yielded = now - yield_started
            if yielded > 0 then
                for _, t in ipairs(tasks) do
                    if t.on_yield then t.on_yield(yielded) end
                end
            end
        end
        yield_started = task == alfred_task and now or nil
        -- A companion can acquire movement between scheduler pulses. Its
        -- active route must survive cleanup of our previously selected task;
        -- only what WonderCity owns is handed back (WCY-5: its autonomous
        -- long route; owner-aware C3 release when Batmobile offers it).
        if active_task and active_task.name ~= 'alfred_running' and not alfred_owns_control() then utils.stop_movement()
        elseif active_task then utils.release_movement(true) end
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
    local transition = tracker.observe_world(alfred_owns_control()
        or (alfred_task.own_trip ~= nil and alfred_task.own_trip()))
    if transition then
        -- 'resume' (same Undercity after an Alfred trip, CRT-1) keeps state.
        if transition == 'run' or transition == 'floor' then pending_navigation_reset = true end
        for _, task in ipairs(tasks) do
            if task.reset then task.reset(transition) end
        end
        reward_wait_task.reset()
        active_task = nil
        yield_started = nil
    end
    if pending_navigation_reset and not alfred_owns_control() then
        BatmobilePlugin.reset('wonder_city')
        pending_navigation_reset = false
    end
    reward_phase.observe()
    if utils.player_in_undercity() and utils.exit_forced() then
        -- Only positive Alfred evidence may hold the deadline (WCY-6), and
        -- only for a bounded time.
        local now = get_time_since_inject()
        if alfred_owns_control(true) and (forced_hold.since == nil or now - forced_hold.since < FORCED_ALFRED_HOLD_MAX) then
            forced_hold.since = forced_hold.since or now
            execute(alfred_task)
        else
            if forced_hold.since and not forced_hold.logged then
                forced_hold.logged = true
                console.print(string.format('[WonderCity] run timeout: Alfred busy for %.0fs — exiting anyway',
                    now - forced_hold.since))
            end
            execute(exit_task)
        end
        return
    end
    forced_hold.since, forced_hold.logged = nil, false
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

-- C2 provider fields for WonderCityPlugin.get_status(). Local state and host
-- globals only (no require, no Alfred/Looter calls).
task_manager.get_run_status = function ()
    local inside = utils.player_in_undercity()
    local alfred_trip = alfred_task ~= nil and alfred_task.own_trip ~= nil and alfred_task.own_trip() or false
    local committed = not inside and entry_task ~= nil and entry_task.committed ~= nil
        and entry_task.committed() or false
    local run_trip = alfred_trip and alfred_task.run_trip ~= nil and alfred_task.run_trip() or false
    return {
        alfred_trip = alfred_trip,
        in_run = inside or committed or run_trip,
        committed_entry = committed,
    }
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
