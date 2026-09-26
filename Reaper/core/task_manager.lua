-- ============================================================
--  Reaper - core/task_manager.lua
-- ============================================================

-- Bind dependencies while Reaper is loading. External callers (WarPigs,
-- WarMachine) may invoke reset_all under a different plugin's require context.
local tracker        = require "core.tracker"
local utils          = require "core.utils"
local settings       = require "core.settings"
local task_manager   = {}
local tasks          = {}
local current_task   = { name = "Idle" }
local last_call_time = 0.0
local predicate_errors = {}

function task_manager.register_task(task)
    table.insert(tasks, task)
end

-- C4: Kill Monsters is the only task that blocks orbwalker movement. Any
-- switch away from it (revive, Alfred, navigation, idle) releases the block.
local function leave_task(next_task)
    if current_task ~= next_task and current_task.name == "Kill Monsters" then
        settings.orb_set_block(false)
    end
end

function task_manager.execute_tasks()
    local t = get_time_since_inject()
    if t - last_call_time < 0.1 then return end
    last_call_time = t

    for _, task in ipairs(tasks) do
        local ok, should = pcall(task.shouldExecute)
        if not ok and predicate_errors[task] ~= tostring(should) then
            console.print("[Reaper] Task condition error in '" .. task.name .. "': " .. tostring(should))
            predicate_errors[task] = tostring(should)
        elseif ok then
            predicate_errors[task] = nil
        end
        if ok and should then
            leave_task(task)
            current_task = task
            local ok2, err = pcall(task.Execute, task)
            if not ok2 then
                console.print("[Reaper] Task error in '" .. task.name .. "': " .. tostring(err))
            end
            return
        end
    end
    leave_task(nil)
    current_task = { name = "Idle" }
end

function task_manager.get_current_task()
    return current_task
end

function task_manager.reset_all()
    for _, task in ipairs(tasks) do
        if task.reset then
            local ok, err = pcall(task.reset)
            if not ok then console.print("[Reaper] Reset error in " .. task.name .. ": " .. tostring(err)) end
        end
    end
    tracker.reset_run()
    utils.reset_boss_quest_tracking()
    utils.reset_loot_guard()
    last_call_time = 0
    current_task = { name = "Idle" }
end

-- Priority order (first = highest)
local task_files = {
    "revive",           -- handle death before anything else
    "alfred",           -- yield to Alfred when needed
    "dungeon_reset",    -- reset dungeons every N runs (between boss zones)
    "belial_chest",     -- handle Belial chest UI before generic chest task
    "navigate_to_boss", -- teleport + walk to entrance
    "interact_altar",   -- summon boss
    "open_chest",       -- reward handling must precede the persistent combat task
    "kill_monsters",    -- fight
}

for _, f in ipairs(task_files) do
    local task = require("tasks." .. f)
    task_manager.register_task(task)
end

return task_manager
