local tracker = require 'core.tracker'
local utils = require 'core.utils'
local reward_phase = {}
local LOOT_QUIET_SECONDS = 3
local REWARD_GRACE_SECONDS = 45

-- Match only actors already known to this runner. Other bosses can still be
-- recognized by the documented is_boss() API. Never retain actor handles.
local boss_names = {
    S11_Andariel_Boss_KUC = true,
    X1_Undercity_Ghost_Caster_Miniboss = true,
    X1_Undercity_Lacuni_Boss = true,
    X1_Undercity_Snake_Brute_Miniboss = true,
}

reward_phase.observe = function ()
    if not utils.player_in_undercity() then return end
    local ok, actors = pcall(actors_manager.get_all_actors)
    if not ok or type(actors) ~= 'table' then return end
    local dead_boss, alive_boss, reward_seen = false, false, false
    for _, actor in pairs(actors) do
        local read, name, boss, health = pcall(function()
            local skin = actor:get_skin_name()
            local is_boss = boss_names[skin] or (actor.is_boss and actor:is_boss())
            return skin, is_boss, is_boss and actor:get_current_health() or nil
        end)
        if not read then return end -- incomplete enumeration is not kill evidence
        if type(name) == 'string' and name:match('^X1_Undercity_Chest_Attunement') then
            reward_seen = true
        end
        if boss and type(health) == 'number' then
            if health > 0 then alive_boss = true elseif health == 0 then dead_boss = true end
        end
    end
    tracker.boss_alive = alive_boss
    if alive_boss then return end
    if dead_boss and not tracker.boss_kill_time then
        tracker.boss_kill_time = get_time_since_inject()
        console.print('[WonderCity:finish] boss death observed; waiting for reward chest')
    end
    if reward_seen and not tracker.reward_seen then
        tracker.reward_seen = true
        console.print('[WonderCity:finish] reward chest observed in all-actor list')
    end
    if (dead_boss or reward_seen) and not tracker.reward_grace_until then
        tracker.reward_grace_until = get_time_since_inject() + REWARD_GRACE_SECONDS
    end
end

reward_phase.active = function ()
    return tracker.boss_kill_time ~= nil or tracker.reward_seen or tracker.done
end

reward_phase.mark_opened = function (reason)
    tracker.done = true -- reward opened; not permission for an immediate exit
    tracker.reward_opened_time = get_time_since_inject()
    tracker.loot_quiet_since = nil
    tracker.completion_reason = reason
    console.print('[WonderCity:finish] reward opening confirmed: ' .. reason)
end

reward_phase.can_exit = function ()
    if not tracker.done then return false end
    if utils.is_looting() then
        tracker.loot_quiet_since = nil
        return false
    end
    local now = get_time_since_inject()
    tracker.loot_quiet_since = tracker.loot_quiet_since or now
    return now - tracker.loot_quiet_since >= LOOT_QUIET_SECONDS
end

return reward_phase
