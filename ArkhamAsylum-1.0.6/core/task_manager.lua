local task_manager = {}
local tasks = {}
local tracker = require 'core.tracker'
local utils = require 'core.utils'
local settings = require 'core.settings'
local active_task = nil
local running = false
local pending_navigation_reset = false
local exit_task = nil
local alfred_task = nil
local current_task = { name = 'Idle', status = 'Idle' } -- Default state when no task is active
local function alfred_owns_control()
    return alfred_task and alfred_task.is_busy and alfred_task.is_busy()
end

task_manager.register_task = function (task)
    table.insert(tasks, task)
end

task_manager.release_control = function ()
    if running then
        -- Alfred owns its movement after the handoff; do not cancel its trip.
        if active_task and active_task.name ~= 'alfred_running' and not alfred_owns_control() then utils.stop_movement() end
        for _, task in ipairs(tasks) do
            if task.on_cancel then task.on_cancel() end
        end
        settings.orb_set_block(false)
        settings.orb_set_clear(true)
        active_task = nil
        running = false
    end
end

local function execute(task)
    running = true
    if active_task ~= task then
        if active_task and active_task.name ~= 'alfred_running'
            and not alfred_owns_control()
            and not (task.name == 'cross_traversal'
                and BatmobilePlugin.is_traversal_routing())
        then
            utils.stop_movement()
        end
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
    local transition = tracker.observe_world()
    if transition then
        if transition == 'run' or transition == 'floor' then pending_navigation_reset = true end
        for _, task in ipairs(tasks) do
            if task.reset then task.reset(transition) end
        end
        active_task = nil
    end
    if pending_navigation_reset and not alfred_owns_control() then
        BatmobilePlugin.reset('arkham_asylum')
        pending_navigation_reset = false
    end
    -- Town relocation and reward tasks must not preempt an accepted Alfred
    -- trip (including a foreign caller's trip to a different service town).
    if alfred_task.is_busy and alfred_task.is_busy() then
        execute(alfred_task)
        return
    end
    -- Deadline overrides reward, boss and traversal work as well as portals.
    if utils.player_in_pit() and utils.exit_pit_forced() then
        if alfred_task.is_busy and alfred_task.is_busy() then execute(alfred_task)
        else execute(exit_task) end
        return
    end
    current_task = { name = 'Idle', status = 'Idle' }
    for _, task in ipairs(tasks) do
        if task.shouldExecute() then
            execute(task)
            break -- Execute only one task per pulse
        end
    end

end

task_manager.get_current_task = function ()
    return current_task
end

local task_files = {
    'teleport_cerrigar',
    'd4assistant',
    -- use_burden_altar runs ABOVE consume_chorons_soul AND upgrade_glyph: the
    -- Choron's Burden Receptacle spawns post-boss and grants one extra glyph
    -- upgrade chance on interact. It must fire before upgrade_glyph (which
    -- would consume chances) and before consume_chorons_soul (which converts
    -- spare chances to XP). The altar disappears on success so shouldExecute
    -- naturally yields the chain to upgrade_glyph / consume_chorons_soul.
    'use_burden_altar',
    -- consume_chorons_soul runs ABOVE upgrade_glyph: the soul converts unspent
    -- upgrade chances into XP, so if upgrade_glyph fired first it would burn
    -- through the chances on glyphs instead.  When the soul setting is off
    -- (default) consume_chorons_soul.shouldExecute returns false immediately
    -- and upgrade_glyph proceeds normally.  Both gate on "no soul left or
    -- already maxed out" so the chain proceeds to alfred / portal / exit_pit.
    'consume_chorons_soul',
    'upgrade_glyph',
    'alfred',
    'enter_pit',
    -- cross_traversal must run before portal: when the portal is across a
    -- climb gizmo, portal task can't pathfind to it and locks the priority
    -- chain. cross_traversal preempts when portal task signals a recent
    -- pathfind failure AND a Traversal_Gizmo is interactable nearby, so the
    -- bot uses the climb instead of staring at the cliff.
    'cross_traversal',
    -- kill_boss must run above portal/explore_pit/kill_monster: once the pit
    -- guardian spawns, nothing else should be able to pull the bot away. Also
    -- handles "remembered hunt" — pathing back to the last known boss position
    -- after death/revive without exploring.
    'kill_boss',
    -- pickup_heart_of_stone runs after kill_boss (so we don't abandon a boss
    -- fight) but before portal/kill_monster/explore_pit so a present Choron's
    -- Burden carryable preempts floor descent and trash chasing. Detects from
    -- anywhere in the pit; no distance gate.
    'pickup_heart_of_stone',
    -- Descend eligible portals before normal completion handling. A finished
    -- exploration map is not proof that the Pit or Guardian fight is over.
    'portal',
    'exit_pit',
    'follower',
    'interact_shrine',
    'push_monsters',
    'kill_monster',
    'explore_pit',
    'idle'
}
for _, file in ipairs(task_files) do
    local task = require('tasks.' .. file)
    task_manager.register_task(task)
    if file == 'exit_pit' then exit_task = task end
    if file == 'alfred' then alfred_task = task end
end

return task_manager
