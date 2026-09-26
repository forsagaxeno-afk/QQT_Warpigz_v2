-- Release movement only after HordeDev has issued it. Native sigil/exit
-- transactions retain their own one-shot stopping and quiet-period rules.
local explorer = require 'core.explorer'
local loot_guard = require 'core.loot_guard'
local M = {}
local owned, batmobile_owned = false, false
function M.claim(using_batmobile)
    owned = true
    batmobile_owned = batmobile_owned or using_batmobile == true
end
function M.stop()
    if not owned then return end
    if batmobile_owned and BatmobilePlugin then
        -- C3: owner-aware release when Batmobile provides it.
        if BatmobilePlugin.release then
            BatmobilePlugin.release('infernal_horde')
        else
            if BatmobilePlugin.stop_long_path then BatmobilePlugin.stop_long_path('infernal_horde') end
            if BatmobilePlugin.clear_target then BatmobilePlugin.clear_target('infernal_horde') end
            if BatmobilePlugin.pause then BatmobilePlugin.pause('infernal_horde') end
        end
    end
    if explorer.clear_path_and_target then explorer:clear_path_and_target() end
    explorer.is_task_running = true
    if not loot_guard.companion_may_own_movement() and pathfinder and pathfinder.clear_stored_path then
        pathfinder.clear_stored_path()
    end
    owned, batmobile_owned = false, false
end
return M
