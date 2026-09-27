local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local ignore_list = {}
local prority_list = {
    ['X1_Undercity_Chest_Goblin'] = true,
    ['X1_Undercity_Treasure_Goblin'] = true,
}

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to enemy',
    WAITING = 'waiting for boss delay',
}
local task = {
    name = 'kill_monster', -- change to your choice of task name
    status = status_enum['IDLE'],
}
-- QQT_Warpigz_v3 (C6): a boss or goblin Batmobile cannot reach is skipped for
-- SKIP_SECONDS (Batmobile rejected set_target, or no PROGRESS_STEP m of
-- progress in NO_PROGRESS_SECONDS while farther than ENGAGE_RANGE) so the
-- explorer can find the real route; then it is allowed again. While a boss
-- was first sighted on this floor, a live boss is re-acquired up to
-- BOSS_REACQUIRE_RANGE (a revive at the checkpoint walks back to it).
local SCAN_RANGE, BOSS_REACQUIRE_RANGE, ENGAGE_RANGE = 50, 150, 10
local NO_PROGRESS_SECONDS, PROGRESS_STEP, SKIP_SECONDS = 12, 1, 25
local skip_until = {}
local progress = {key = nil, best = nil, time = nil, last = nil}
-- Only time this task actually executes counts: a gap (death, another task)
-- longer than PROGRESS_GAP starts a fresh window.
local PROGRESS_GAP = 2
local function skipped(name, now)
    local until_t = skip_until[name]
    return until_t ~= nil and now < until_t
end
local get_closest_enemies = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = get_player_position()
    local now = get_time_since_inject()
    local enemies = target_selector.get_near_target_list(player_pos, SCAN_RANGE)
    local closest_enemy, closest_enemy_dist
    local closest_elite, closest_elite_dist
    local closest_champ, closest_champ_dist
    local closest_boss, closest_boss_dist
    local closest_priority, closest_priority_dist
    for _, enemy in pairs(enemies) do
        local name = enemy:get_skin_name()
        local health = enemy:get_current_health()
        if not ignore_list[name] and health > 0 then
            local dist = utils.distance(player_pos, enemy)
            local skip = skipped(name, now)
            if settings.chase_goblin and prority_list[name] and not skip and
                (closest_priority_dist == nil or dist < closest_priority_dist)
            then
                closest_priority = enemy
                closest_priority_dist = dist
            end
            if enemy:is_boss() and not skip and
                (closest_boss_dist == nil or dist < closest_boss_dist)
            then
                closest_boss = enemy
                closest_boss_dist = dist
            end
            if health > 1 and dist <= settings.check_distance then
                if closest_enemy_dist == nil or dist < closest_enemy_dist then
                    closest_enemy = enemy
                    closest_enemy_dist = dist
                end
                if enemy:is_elite() and
                    (closest_elite_dist == nil or dist < closest_elite_dist)
                then
                    closest_elite = enemy
                    closest_elite_dist = dist
                end
                if enemy:is_champion() and
                    (closest_champ_dist == nil or dist < closest_champ_dist)
                then
                    closest_champ = enemy
                    closest_champ_dist = dist
                end
            end
        end
    end
    if closest_boss == nil and tracker.boss_trigger_time ~= nil then
        for _, enemy in pairs(target_selector.get_near_target_list(player_pos, BOSS_REACQUIRE_RANGE)) do
            local name = enemy:get_skin_name()
            if not ignore_list[name] and not skipped(name, now) and enemy:get_current_health() > 0
                and enemy:is_boss() then
                local dist = utils.distance(player_pos, enemy)
                if dist <= BOSS_REACQUIRE_RANGE and (closest_boss_dist == nil or dist < closest_boss_dist) then
                    closest_boss, closest_boss_dist = enemy, dist
                end
            end
        end
    end
    if closest_boss ~= nil then tracker.note_boss_seen() end
    return closest_enemy, closest_elite, closest_champ, closest_boss, closest_priority
end

local function give_up(name, why)
    skip_until[name] = get_time_since_inject() + SKIP_SECONDS
    progress.key, progress.best, progress.time = nil, nil, nil
    tracker.boss_seen_at = nil -- the explorers may look for the real route now
    console.print(string.format('[WonderCity:kill] %s unreachable (%s) - exploring for %ds before trying it again',
        tostring(name), why, SKIP_SECONDS))
    utils.stop_movement()
    task.status = 'target unreachable - exploring'
end

local bosses = {
    ['S11_Andariel_Boss_KUC'] = 'S11_Andariel_Boss_KUC',
    ['X1_Undercity_Ghost_Caster_Miniboss'] = 'X1_Undercity_Ghost_Caster_Miniboss',
    ['X1_Undercity_Lacuni_Boss'] = 'X1_Undercity_Lacuni_Boss',
    ['X1_Undercity_Snake_Brute_Miniboss'] = 'X1_Undercity_Snake_Brute_Miniboss',
}

task.shouldExecute = function ()
    local _, _, _, boss, priority = get_closest_enemies()
    local target = boss or priority
    return target ~= nil and
        utils.player_in_undercity()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local _, _, _, boss, priority = get_closest_enemies()
    local target = boss or priority

    if target and target:is_boss() and
        tracker.boss_trigger_time == nil
    then
        tracker.boss_trigger_time = get_time_since_inject()
    end

    if tracker.boss_trigger_time ~= nil and
        tracker.boss_trigger_time + settings.boss_delay > get_time_since_inject()
    then
        utils.stop_movement()
        settings.orb_set_clear(false)
        task.status = status_enum['WAITING']
        progress.key, progress.best, progress.time = nil, nil, nil
        return
    end
    settings.orb_set_clear(true)

    local dist = target and utils.distance(local_player, target)
    if target and dist > 1 then
        -- QQT_Warpigz_v3 (C6): bounded approach (see give_up).
        local name, now = target:get_skin_name(), get_time_since_inject()
        if dist > ENGAGE_RANGE then
            if progress.last and now - progress.last > PROGRESS_GAP then progress.best = nil end
            progress.last = now
            if progress.key ~= name or progress.best == nil then
                progress.key, progress.best, progress.time = name, dist, now
            elseif dist < progress.best - PROGRESS_STEP then
                progress.best, progress.time = dist, now
            elseif now - progress.time >= NO_PROGRESS_SECONDS then
                give_up(name, string.format('no progress for %ds at %.0fm', NO_PROGRESS_SECONDS, dist))
                return
            end
        else
            progress.key, progress.best, progress.time = nil, nil, nil -- engaged
        end
        if BatmobilePlugin.set_target(plugin_label, target) == false and dist > ENGAGE_RANGE then
            give_up(name, 'Batmobile rejected the target')
            return
        end
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    else
        progress.key, progress.best, progress.time = nil, nil, nil
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
    end
end

-- C5: time spent yielding (Alfred, Looter) is not 'no progress' time.
task.on_yield = function (seconds)
    if progress.time then progress.time = progress.time + seconds end
end

task.reset = function ()
    skip_until = {}
    progress.key, progress.best, progress.time = nil, nil, nil
end

return task