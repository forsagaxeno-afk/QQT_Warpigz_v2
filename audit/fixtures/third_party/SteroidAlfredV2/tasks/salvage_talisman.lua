local plugin_label = 'alfred_the_butler'

local utils      = require 'core.utils'
local settings   = require 'core.settings'
local tracker    = require 'core.tracker'
local explorerlite = require 'core.explorerlite'
local base_task  = require 'tasks.base'

local task = base_task.new_task()
local status_enum = {
    IDLE         = 'Idle',
    EXECUTE      = 'Salvaging talismans',
    MOVING       = 'Moving to Occultist',
    INTERACTING  = 'Interacting with Occultist',
    RESETTING    = 'Re-trying talisman salvage',
    FAILED       = 'Failed to salvage talisman',
}

local function has_talismans_to_salvage()
    local player = get_local_player()
    if not player then return false end
    local items = player:get_talisman_items()
    console.print('[salvage_talisman] has_talismans_to_salvage: found ' .. tostring(#items) .. ' talisman items')
    for _, item in pairs(items) do
        local name = item:get_name()
        local item_type = utils.get_item_type(item)
        local should = utils.should_salvage_talisman(item)
        console.print('[salvage_talisman]   item=' .. tostring(name) .. ' type=' .. tostring(item_type) .. ' should_salvage=' .. tostring(should))
        if should then return true end
    end
    return false
end

local extension = {}
function extension.get_npc()
    return utils.get_npc(utils.npc_enum['OCCULTIST'])
end
function extension.move()
    local npc = extension.get_npc()
    local raw = (npc and npc:get_position()) or utils.get_npc_location('OCCULTIST')
    local npc_location = utils.compute_move_target(raw)
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, npc_location)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(npc_location)
        explorerlite:move_to_target()
    end
end
function extension.interact()
    local npc = extension.get_npc()
    if npc then interact_vendor(npc) end
end
function extension.execute()
    local player = get_local_player()
    if not player then return end
    tracker.last_task = task.name
    for _, item in pairs(player:get_talisman_items()) do
        if utils.should_salvage_talisman(item) then
            loot_manager.salvage_specific_item(item)
        end
    end
end
function extension.reset()
    local player = get_local_player()
    if not player then return end
    local npc = extension.get_npc()
    local new_position = (npc and npc:get_position()) or utils.get_npc_location('OCCULTIST') or vec3:new(0, 0, 0)
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, new_position)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(new_position)
        explorerlite:move_to_target()
    end
end
function extension.is_done()
    return not has_talismans_to_salvage()
end
function extension.done()
    if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
    tracker.salvage_talisman_done = true
end
function extension.failed()
    if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
    tracker.salvage_talisman_failed = true
end
function extension.is_in_vendor_screen()
    return loot_manager:is_in_vendor_screen()
end

task.name = 'salvage_talisman'
task.extension = extension
task.status_enum = status_enum

task.shouldExecute = function()
    if tracker.trigger_tasks == false then
        task.retry = 0
    end
    if utils.is_in_town() and
        tracker.trigger_tasks and
        not tracker.salvage_talisman_done and
        not tracker.salvage_talisman_failed and
        (tracker.salvage_done or tracker.salvage_failed)
    then
        if not (tracker.salvage_talisman_seal or tracker.salvage_talisman_charm) then
            tracker.salvage_talisman_done = true
            return false
        end
        if task.check_status(task.status_enum['FAILED']) then
            task.set_status(task.status_enum['IDLE'])
        end
        return true
    end
    return false
end

return task
