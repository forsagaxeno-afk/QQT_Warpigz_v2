local settings = require "core.settings"
local task_manager = {}
local tasks = {}
local tracker = require "core.tracker"
local movement = require "core.movement"
local warplan = require "core.warplan"
local exit_task, start_task, enter_task
local current_task = { name = "Idle" } -- Default state when no task is active
-- F-H1/F-H2: named idle states (no movement, teleport or item use); `hold`
-- is published as InfernalHordesPlugin.status().hold.
local idle_states = {}
local function idle_state(name, hold)
    local state = idle_states[name]
    if not state then
        state = { name = name, hold = hold, Execute = function() end }
        idle_states[name] = state
    end
    return state
end
local finished_time = 0

function task_manager.set_finished_time(time)
    finished_time = time
end

function task_manager.get_finished_time()
    return finished_time
end

function task_manager.register_task(task)
    table.insert(tasks, task)
end

local function activate(task)
    if current_task ~= task and movement.stop then movement.stop() end
    current_task = task or { name = "Idle" }
    if task then task:Execute() end
end

local last_call_time = 0.0
function task_manager.execute_tasks()
    local current_core_time = get_time_since_inject()
    if current_core_time - last_call_time < 0.1 then
        return -- quick ej slide frames
    end

    last_call_time = current_core_time

    -- A RESET is a multi-world transaction. Do not start walking, consume a
    -- compass or initiate salvage between Leave Dungeon and the actual reset.
    if tracker.reset_exit_pending then
        activate(exit_task)
        return
    end

    -- F-H1: War Plan entry never runs a compass or portal transaction.
    local war_plan = tracker.entry_mode == 'warplan'

    -- A pending Consume Sigil dialog / entry owns the queue across loading.
    -- Actor scans and walking must not steal confirmation or interrupt entry.
    if tracker.sigil_activation_pending and not war_plan then
        activate(start_task)
        return
    end
    if tracker.horde_entry_pending and not war_plan then
        activate(enter_task)
        return
    end

    for _, task in ipairs(tasks) do
        if task.shouldExecute() then
            activate(task)
            return
        end
    end
    -- F-H1: outside BSK a War Plan run idles visibly until the War Plan
    -- teleport lands it in the Horde, and after its exit it stays done.
    if war_plan and not warplan.inside_bsk() then
        if warplan.completed then
            activate(idle_state(warplan.DONE_TASK, nil))
        else
            warplan.note_wait()
            activate(idle_state(warplan.WAIT_TASK, warplan.WAIT_TEXT))
        end
        return
    end
    activate(nil)
end

-- F-H2: a named, visible idle state chosen by main.lua.
function task_manager.hold(name, hold)
    activate(idle_state(name, hold))
end

function task_manager.stop()
    if movement.stop then movement.stop() end
    for _, task in ipairs(tasks) do
        if task.cancel_pending then task:cancel_pending() end
    end
    current_task = { name = "Idle" }
end

function task_manager.get_current_task()
    return current_task
end

local task_files = { "alfred", "town_salvage" , "walking_to_horde", "open_chests" , "exit_horde" ,"start_dungeon", "enter_horde", "horde" }
for _, file in ipairs(task_files) do
    local task = require("tasks." .. file)
    if file == "exit_horde" then exit_task = task end
    if file == "start_dungeon" then start_task = task end
    if file == "enter_horde" then enter_task = task end
    task_manager.register_task(task)
end

return task_manager