local settings = require "core.settings"
local task_manager = {}
local tasks = {}
local current_task = { name = "Idle" } -- Default state when no task is active
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

local last_call_time = 0.0
function task_manager.execute_tasks()
    local current_core_time = get_time_since_inject()
    -- if current_core_time - last_call_time < 0.2 then
    --     return -- quick ej slide frames
    -- end

    last_call_time = current_core_time

    local selected = nil
    for _, task in ipairs(tasks) do
        if task.shouldExecute() then
            selected = task
            break
        end
    end
    if current_task ~= selected and current_task and current_task.suspend then
        current_task:suspend()
    end
    current_task = selected or { name = "Idle" }
    if selected then selected:Execute() end
end

function task_manager.stop()
    if current_task and current_task.suspend then current_task:suspend() end
    for _, task in ipairs(tasks) do
        if task.cancel_pending then task:cancel_pending() end
    end
    current_task = { name = "Idle" }
end

function task_manager.get_current_task()
    return current_task
end

local task_files = { "alfred", "helltide", "search_helltide"}
for _, file in ipairs(task_files) do
    local task = require("tasks." .. file)
    task_manager.register_task(task)
end

return task_manager