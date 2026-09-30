-- QQT_Warpigz_v3 WonderCity 2.2.7 (W4, sweep S3 F4/F5): after the reward
-- chest opened, walk to reward loot the Looter wants but that lies beyond
-- its pickup distance (within reward_phase.REWARD_LOOT.RANGE m of the chest
-- or the boss), so the Looter picks it up before the exit. After a death it
-- walks back to the chest first. Bounded in reward_phase (cap from the
-- opening) and here (a target without progress for STALL s is skipped).
-- Runs only in the reward-phase branch of the task manager, before
-- exit_undercity.
local plugin_label = 'wonder_city'
local utils = require 'core.utils'
local settings = require 'core.settings'
local reward_phase = require 'core.reward_phase'

local RL = reward_phase.REWARD_LOOT
local task = {name = 'loot_reward', status = 'idle'}
local walk = {key = nil, best = nil, best_at = nil, last = nil}
local PROGRESS_GAP = 2 -- a longer gap (another task ran) starts a fresh window

task.shouldExecute = function ()
    return reward_phase.reward_loot_target() ~= nil
end

task.Execute = function ()
    local player = get_local_player()
    if not player then return end
    local target, key = reward_phase.reward_loot_target()
    if target == nil then task.status = 'idle'; return end
    local state, now = reward_phase.reward_loot_state(), get_time_since_inject()
    state.target = key
    settings.orb_set_clear(true)
    if utils.is_looting() then
        -- The Looter is picking something up: never walk it off (yield time).
        utils.stop_movement()
        walk.best_at = walk.best_at and now or nil
        task.status = 'waiting for Looter'
        return
    end
    local dist = utils.distance(player, target)
    if walk.last and now - walk.last > PROGRESS_GAP then walk.best = nil end
    walk.last = now
    if walk.key ~= key or walk.best == nil or dist < walk.best - RL.STEP then
        walk.key, walk.best, walk.best_at = key, dist, now
    elseif now - walk.best_at >= RL.STALL then
        state.skipped[key] = true
        state.tick_at = nil -- QQT_Warpigz_v3 WonderCity 2.2.8: rescan without it
        walk.key, walk.best, walk.best_at = nil, nil, nil
        console.print(string.format('[WonderCity:finish] reward loot %s: no progress for %ds at %.1fm - skipping it',
            key, RL.STALL, dist))
        utils.stop_movement()
        return
    end
    if dist <= RL.REACH then
        utils.stop_movement()
        task.status = 'waiting for Looter at reward loot'
        return
    end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    local pos = target.get_position and target:get_position() or target
    if BatmobilePlugin.set_target(plugin_label, pos) == false then
        state.skipped[key] = true
        state.tick_at = nil -- QQT_Warpigz_v3 WonderCity 2.2.8: rescan without it
        console.print('[WonderCity:finish] reward loot ' .. tostring(key) .. ': Batmobile rejected the target - skipping it')
        utils.stop_movement()
        return
    end
    BatmobilePlugin.move(plugin_label)
    task.status = key == 'chest' and 'walking back to the reward chest' or 'walking to reward loot'
end

-- C5: time spent yielding (Alfred, Looter hold) is not 'no progress' time.
task.on_yield = function (seconds)
    if walk.best_at then walk.best_at = walk.best_at + seconds end
end

task.reset = function ()
    walk.key, walk.best, walk.best_at, walk.last = nil, nil, nil, nil
end

return task
