local plugin_label = 'wonder_city'
local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local reward_phase = require 'core.reward_phase'

local INTERACT_REFIRE_COOLDOWN = 1
local INTERACT_TIMEOUT = 8
local CONFIRM_SECONDS = 1
local task = {name = 'goto_chest', status = 'idle'}

local function item_ids()
    local ok, items = pcall(actors_manager.get_all_items)
    if not ok or type(items) ~= 'table' then return nil end
    local ids = {}
    for _, item in pairs(items) do
        local read, id = pcall(function() return item:get_id() end)
        if not read or type(id) ~= 'number' then return nil end
        ids[id] = true
    end
    return ids
end

local function has_new_loot()
    if not task.items_before then return false end
    local current = item_ids()
    if not current then return false end
    for id in pairs(current) do
        if not task.items_before[id] then return true end
    end
    return false
end

local function chest_key(chest)
    local ok, key = pcall(function()
        if chest.get_id then
            local id = chest:get_id()
            if type(id) == 'number' then return tostring(id) end
        end
        local pos = chest:get_position()
        return chest:get_skin_name() .. ':' .. tostring(pos:x()) .. ':' .. tostring(pos:y())
    end)
    return ok and key or nil
end

local function complete(reason)
    reward_phase.mark_opened(reason)
    task.reset()
    task.status = 'reward opened; waiting for loot'
    utils.stop_movement()
    settings.orb_set_clear(true)
end

local function confirm(reason)
    if task.confirm_reason ~= reason then
        task.confirm_reason = reason
        task.confirm_since = get_time_since_inject()
    elseif get_time_since_inject() - task.confirm_since >= CONFIRM_SECONDS then
        complete(reason)
    end
end

local function clear_confirmation()
    task.confirm_reason, task.confirm_since = nil, nil
end

task.shouldExecute = function ()
    return utils.player_in_undercity() and not tracker.done and not tracker.chest_failed
        and (utils.get_undercity_chest() ~= nil or task.last_interact_call ~= nil)
end

task.Execute = function ()
    local player = get_local_player()
    if not player or not utils.player_in_undercity() then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    local now = get_time_since_inject()
    local chest, scan_ok = utils.get_undercity_chest()
    if not scan_ok then clear_confirmation();task.status = 'waiting for valid chest scan';return end
    if task.last_interact_call and has_new_loot() then task.loot_observed = true end

    -- A single empty actor list is not an opened chest. Disappearance requires
    -- our own close-range interaction, newly observed loot and a stable read.
    if not chest then
        if task.last_interact_call and task.loot_observed then
            task.loot_observed = true
            confirm('chest disappeared with new loot')
        else
            clear_confirmation()
        end
        task.status = tracker.done and 'reward opened; waiting for loot' or 'waiting for chest confirmation'
    else
        local key = chest_key(chest)
        if not key then clear_confirmation();return end
        if task.active_key and task.active_key ~= key then task.reset() end
        task.active_key = key
        local read, distance, interactable = pcall(function()
            return utils.distance(player, chest), chest:is_interactable()
        end)
        if not read then clear_confirmation();return end
        if distance > 2 then
            clear_confirmation()
            BatmobilePlugin.set_target(plugin_label, chest)
            BatmobilePlugin.move(plugin_label)
            task.status = 'walking to reward chest'
            return
        end
        utils.stop_movement()
        if interactable then
            task.interact_time = task.interact_time or now
            clear_confirmation()
            settings.orb_set_clear(false)
            if not task.last_interact_call or now - task.last_interact_call >= INTERACT_REFIRE_COOLDOWN then
                if not task.last_interact_call then task.items_before = item_ids() end
                console.print('[WonderCity:chest] interact_object dist=' .. string.format('%.2f', distance))
                interact_object(chest)
                task.last_interact_call = now
            end
            task.status = 'interacting with reward chest'
        elseif task.last_interact_call then
            settings.orb_set_clear(true)
            confirm('interacted chest no longer interactable')
            task.status = tracker.done and 'reward opened; waiting for loot' or 'confirming reward chest'
        else
            -- A closed/non-interactable object seen before our first click
            -- may still be locked by the boss; never count it as a reward.
            task.status = 'waiting for reward chest to unlock'
        end
    end

    if not tracker.done and task.interact_time and now - task.interact_time > INTERACT_TIMEOUT then
        console.print('[WonderCity:chest] opening unconfirmed; waiting for configured run reset')
        tracker.chest_failed = true
        task.reset()
        settings.orb_set_clear(true)
        task.status = 'reward opening unconfirmed'
    end
end

task.reset = function ()
    task.interact_time, task.last_interact_call, task.active_key = nil, nil, nil
    task.items_before, task.loot_observed = nil, false
    clear_confirmation()
end

return task
