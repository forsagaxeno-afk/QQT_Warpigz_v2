local plugin_label = 'wonder_city'
local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local reward_phase = require 'core.reward_phase'

local INTERACT_REFIRE_COOLDOWN = 1
local INTERACT_TIMEOUT = 8
local CONFIRM_SECONDS = 1
-- CRT-1/L9 bounded waits (seconds of this task's own execution; time spent
-- yielding to Alfred is shifted out, C5):
--  * a chest that is non-interactable before our first click was opened
--    already (by hand, a companion, or before an Alfred round trip) unless
--    it unlocks: LOCKED_WAIT after an observed boss kill, else LOCKED_WAIT_UNKNOWN;
--  * our interacted chest vanished from stable scans without new loot;
--  * no approach progress at close range: interact from where we stand.
local LOCKED_WAIT, LOCKED_WAIT_UNKNOWN = 10, 30
local VANISH_WAIT = 5
local APPROACH_STALL, APPROACH_FALLBACK_RANGE, APPROACH_PROGRESS = 8, 4, 0.5
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

-- Non-interactable before our first click: wait (bounded) for an unlock.
local function locked_wait(now)
    if tracker.boss_alive then
        task.locked_since = nil
        task.status = 'waiting for reward chest to unlock (boss alive)'
        return
    end
    local limit = tracker.boss_kill_time and LOCKED_WAIT or LOCKED_WAIT_UNKNOWN
    if task.locked_since == nil then
        task.locked_since = now
        console.print(string.format('[WonderCity:chest] reward chest is not interactable before our click; '
            .. 'treating it as already opened in %ds unless it unlocks', limit))
    end
    local waited = now - task.locked_since
    if waited >= limit then
        complete(string.format('chest not interactable for %.0fs before our click (already opened)', waited))
        return
    end
    task.status = string.format('waiting for reward chest to unlock (%.0fs)', limit - waited)
end

-- Approach progress (close-range stall falls back to interacting in place).
local function approach_stalled(distance, now)
    if task.approach_best == nil or distance < task.approach_best - APPROACH_PROGRESS then
        task.approach_best, task.approach_time = distance, now
        return false
    end
    return distance <= APPROACH_FALLBACK_RANGE and now - task.approach_time >= APPROACH_STALL
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
    -- our own close-range interaction, and newly observed loot or a stable
    -- absence of VANISH_WAIT seconds.
    if not chest then
        if task.last_interact_call and task.loot_observed then
            task.loot_observed = true
            confirm('chest disappeared with new loot')
        elseif task.last_interact_call then
            clear_confirmation()
            task.missing_since = task.missing_since or now
            if now - task.missing_since >= VANISH_WAIT then
                console.print('[WonderCity:chest] interacted reward chest vanished; treating it as opened')
                complete('interacted chest vanished')
                return
            end
        else
            clear_confirmation()
        end
        task.status = tracker.done and 'reward opened; waiting for loot' or 'waiting for chest confirmation'
    else
        task.missing_since = nil
        local key = chest_key(chest)
        if not key then clear_confirmation();return end
        if task.active_key and task.active_key ~= key then task.reset() end
        task.active_key = key
        local read, distance, interactable = pcall(function()
            return utils.distance(player, chest), chest:is_interactable()
        end)
        if not read then clear_confirmation();return end
        if distance > 2 and not approach_stalled(distance, now) then
            clear_confirmation()
            BatmobilePlugin.set_target(plugin_label, chest)
            BatmobilePlugin.move(plugin_label)
            task.status = 'walking to reward chest'
            return
        end
        utils.stop_movement()
        if interactable then
            task.locked_since = nil
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
            -- may still be locked by the boss. Bounded (L9: an already opened
            -- chest stays non-interactable forever).
            settings.orb_set_clear(true)
            locked_wait(now)
        end
    end

    if not tracker.done and task.interact_time and now - task.interact_time > INTERACT_TIMEOUT then
        -- CRT-1: the host can keep an opened chest flagged interactable.
        -- Bounded completion (upstream behavior) instead of waiting for
        -- the run reset; loot still gets its quiet period before the exit.
        console.print('[WonderCity:chest] opening unconfirmed after ' .. INTERACT_TIMEOUT
            .. 's of interaction; treating the reward chest as opened')
        complete(task.loot_observed and 'interacted; new loot observed (chest stays interactable)'
            or 'interaction unconfirmed; chest stays interactable')
    end
end

-- C5: time spent yielding (e.g. to Alfred) is not waiting/progress time.
task.on_yield = function (seconds)
    for _, field in ipairs({'interact_time', 'last_interact_call', 'confirm_since', 'locked_since',
        'missing_since', 'approach_time'}) do
        if task[field] then task[field] = task[field] + seconds end
    end
end

task.reset = function ()
    task.interact_time, task.last_interact_call, task.active_key = nil, nil, nil
    task.items_before, task.loot_observed = nil, false
    task.locked_since, task.missing_since = nil, nil
    task.approach_best, task.approach_time = nil, nil
    clear_confirmation()
end

return task
